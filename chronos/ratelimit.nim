#               Chronos Rate Limiter
#            (c) Copyright 2022-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

{.push raises: [].}

import ../chronos
import timer

export timer

type
  ReplenishMode* = enum
    # Strict mode allows replenish tokens only after the fill duration has elapsed.
    Strict

    # For better utilization of available tokens and tolerate burst periods.
    # Balanced mode allows minting tokens based on elapsed time in between consuming of tokens up to budget capacity.
    Balanced

  BucketWaiter = object
    future: Future[void]
    value: int
    alreadyConsumed: int

  TokenBucket* = ref object
    budget: int
    budgetCapacity: int
    lastUpdate: Moment
    fillDuration: Duration
    workFuture: Future[void]
    pendingRequests: seq[BucketWaiter]
    manuallyReplenished: AsyncEvent
    replenishMode: ReplenishMode

func fullPeriodElapsed(bucket: TokenBucket, currentTime: Moment): bool =
  return currentTime - bucket.lastUpdate >= bucket.fillDuration

proc calcUpdateStrict(bucket: TokenBucket, currentTime: Moment): tuple[budget: int, lastUpdate: Moment] =
  if bucket.fillDuration == default(Duration):
    # with zero fillDuration we only allow manual replenish till capacity
    return (min(bucket.budgetCapacity, bucket.budget), bucket.lastUpdate)

  if not fullPeriodElapsed(bucket, currentTime):
    return (bucket.budget, bucket.lastUpdate)

  return (bucket.budgetCapacity, currentTime)

proc calcUpdateBalanced(bucket: TokenBucket, currentTime: Moment): tuple[budget: int, lastUpdate: Moment]  =
  if bucket.fillDuration == default(Duration):
    # with zero fillDuration we only allow manual replenish till capacity
    return (min(bucket.budgetCapacity, bucket.budget), bucket.lastUpdate)

  if currentTime <= bucket.lastUpdate:
    # don't allow backward timing
    return (bucket.budget, bucket.lastUpdate)

  let timeDelta = currentTime - bucket.lastUpdate
  let capacity = bucket.budgetCapacity
  let periodNs = bucket.fillDuration.nanoseconds.int64
  let deltaNs = timeDelta.nanoseconds.int64

  # How many whole tokens could be produced by the elapsed time.
  let possibleTokens = int((deltaNs * capacity.int64) div periodNs)
  if possibleTokens <= 0:
    return (bucket.budget, bucket.lastUpdate)

  let budgetLeft = capacity - bucket.budget
  if budgetLeft <= 0:
    # Bucket already full the entire elapsed time: burn the elapsed time
    # so we do not accumulate implicit credit and do not allow over budgeting
    return (capacity, currentTime)

  let toAdd = min(possibleTokens, budgetLeft)

  # Advance lastUpdate only by the fraction of time actually “spent” to mint toAdd tokens.
  # (toAdd / capacity) * period = time used
  let usedNs = (periodNs * toAdd.int64) div capacity.int64
  let newbudget = bucket.budget + toAdd
  var newLastUpdate = bucket.lastUpdate + nanoseconds(usedNs)
  if toAdd == budgetLeft and possibleTokens > budgetLeft:
    # We hit the capacity; discard leftover elapsed time to prevent multi-call burst inflation
    newLastUpdate = currentTime

  return (newbudget, newLastUpdate)

proc calcUpdate(bucket: TokenBucket, currentTime: Moment): tuple[budget: int, lastUpdate: Moment] =
  if bucket.replenishMode == ReplenishMode.Strict:
    return bucket.calcUpdateStrict(currentTime)
  else:
    return bucket.calcUpdateBalanced(currentTime)

proc update(bucket: TokenBucket, currentTime: Moment) =
  let (newBudget, newLastUpdate) = bucket.calcUpdate(currentTime)
  bucket.budget = newBudget
  bucket.lastUpdate = newLastUpdate

proc tryConsume*(bucket: TokenBucket, tokens: int, now = Moment.now()): bool =
  ## If `tokens` are available, consume them,
  ## Otherwise, return false.

  if bucket.budget >= tokens:
    # If bucket is full, consider this point as period start, drop silent periods before
    if bucket.budget == bucket.budgetCapacity:
      bucket.lastUpdate = now
    bucket.budget -= tokens
    return true

  bucket.update(now)

  if bucket.budget >= tokens:
    bucket.budget -= tokens
    return true
  else:
    return false

proc worker(bucket: TokenBucket) {.async.} =
  while bucket.pendingRequests.len > 0:
    bucket.manuallyReplenished.clear()
    template waiter: untyped = bucket.pendingRequests[0]

    if bucket.tryConsume(waiter.value):
      waiter.future.complete()
      bucket.pendingRequests.delete(0)
    else:
      waiter.value -= bucket.budget
      waiter.alreadyConsumed += bucket.budget
      bucket.budget = 0

      let eventWaiter = bucket.manuallyReplenished.wait()
      if bucket.fillDuration.milliseconds > 0:
        let
          nextCycleValue = float(min(waiter.value, bucket.budgetCapacity))
          budgetRatio = nextCycleValue.float / bucket.budgetCapacity.float
          timeToTarget = int(budgetRatio * bucket.fillDuration.milliseconds.float) + 1
          #TODO this will create a timer for each blocked bucket,
          #which may cause performance issue when creating many
          #buckets
          sleeper = sleepAsync(milliseconds(timeToTarget))
        await sleeper or eventWaiter
        sleeper.cancelSoon()
        eventWaiter.cancelSoon()
      else:
        await eventWaiter

  bucket.workFuture = nil

proc consume*(bucket: TokenBucket, tokens: int, now = Moment.now()): Future[void] =
  ## Wait for `tokens` to be available, and consume them.

  let retFuture = newFuture[void]("TokenBucket.consume")
  if isNil(bucket.workFuture) or bucket.workFuture.finished():
    if bucket.tryConsume(tokens, now):
      retFuture.complete()
      return retFuture

  proc cancellation(udata: pointer) =
    for index in 0..<bucket.pendingRequests.len:
      if bucket.pendingRequests[index].future == retFuture:
        bucket.budget += bucket.pendingRequests[index].alreadyConsumed
        bucket.pendingRequests.delete(index)
        if index == 0:
          bucket.manuallyReplenished.fire()
        break
  retFuture.cancelCallback = cancellation

  bucket.pendingRequests.add(BucketWaiter(future: retFuture, value: tokens))

  if isNil(bucket.workFuture) or bucket.workFuture.finished():
    bucket.workFuture = worker(bucket)

  return retFuture

proc replenish*(bucket: TokenBucket, tokens: int, now = Moment.now()) =
  ## Add `tokens` to the budget (capped to the bucket capacity)
  bucket.budget += tokens
  bucket.update(now)
  bucket.manuallyReplenished.fire()

proc getAvailableCapacity*(
    bucket: TokenBucket, currentTime: Moment = Moment.now()
): tuple[budget: int, budgetCapacity: int, lastUpdate: Moment] =
  let (assumedBudget, assumedLastUpdate) = bucket.calcUpdate(currentTime)
  return (assumedBudget, bucket.budgetCapacity, assumedLastUpdate)

proc new*(
  T: type[TokenBucket],
  budgetCapacity: int,
  fillDuration: Duration = 1.seconds,
  replenishMode: ReplenishMode = ReplenishMode.Balanced): T =

  ## Create a TokenBucket
  T(
    budget: budgetCapacity,
    budgetCapacity: budgetCapacity,
    fillDuration: fillDuration,
    lastUpdate: Moment.now(),
    manuallyReplenished: newAsyncEvent(),
    replenishMode: replenishMode
  )

proc setState*(bucket: TokenBucket, budget: int, lastUpdate: Moment) =
  bucket.budget = budget
  bucket.lastUpdate = lastUpdate

func `$`*(b: TokenBucket): string {.inline.} =
  if isNil(b):
    return "nil"
  return $b.budgetCapacity & "/" & $b.fillDuration

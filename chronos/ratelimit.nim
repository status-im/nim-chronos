#               Chronos Rate Limiter
#            (c) Copyright 2022-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

{.push raises: [Defect].}

import ../chronos
import timer

export timer

type
  BucketWaiter = object
    future: Future[void]
    value: int
    alreadyConsumed: int

  TokenBucket* = ref object
    budget: int
    budgetCap: int
    lastUpdate: Moment
    fillPerMs: int
    workFuture: Future[void]
    pendingRequests: seq[BucketWaiter]
    manuallyReplenished: AsyncEvent

proc update(bucket: TokenBucket) =
  let
    currentTime = Moment.now()
    timeDelta = milliseconds(currentTime - bucket.lastUpdate).int
    replenished = bucket.fillPerMs * timeDelta

  bucket.lastUpdate += timeDelta.milliseconds
  bucket.budget = min(bucket.budgetCap, bucket.budget + replenished)

proc tryConsume*(bucket: TokenBucket, tokens: int): bool =
  ## If `tokens` are available, consume them,
  ## Otherwhise, return false.

  bucket.update()

  if bucket.budget >= tokens:
    bucket.budget -= tokens
    true
  else:
    false

proc worker(bucket: TokenBucket) {.async.} =
  defer: bucket.workFuture = nil

  while bucket.pendingRequests.len > 0:
    bucket.manuallyReplenished.clear()
    template waiter: untyped = bucket.pendingRequests[0]

    if bucket.tryConsume(waiter.value):
      waiter.future.complete()
      bucket.pendingRequests.delete(0)
      continue

    waiter.value -= bucket.budget
    waiter.alreadyConsumed.inc(bucket.budget)
    bucket.budget = 0

    let eventWaiter = bucket.manuallyReplenished.wait()
    if bucket.fillPerMs > 0:
      let
        nextCycleValue = min(waiter.value, bucket.budgetCap)
        timeToZero = (nextCycleValue div bucket.fillPerMs) + 1
        sleeper = sleepAsync(milliseconds(timeToZero))
      await sleeper or eventWaiter
      sleeper.cancel()
      eventWaiter.cancel()
    else:
      await eventWaiter

proc consume*(bucket: TokenBucket, tokens: int): Future[void] =
  ## Wait for `tokens` to be available, and consume them.

  let retFuture = newFuture[void]("TokenBucket.consume")
  if isNil(bucket.workFuture):
    if bucket.tryConsume(tokens):
      retFuture.complete()
      return retFuture

  bucket.pendingRequests.add(BucketWaiter(future: retFuture, value: tokens))
  if isNil(bucket.workFuture):
    bucket.workFuture = worker(bucket)

  proc cancellation(udata: pointer) =
    for index in 0..<bucket.pendingRequests.len:
      if bucket.pendingRequests[index].future == retFuture:
        bucket.budget.inc(bucket.pendingRequests[index].alreadyConsumed)
        bucket.pendingRequests.delete(index)
        if index == 0:
          bucket.manuallyReplenished.fire()
        break
  retFuture.cancelCallback = cancellation
  return retFuture

proc replenish*(bucket: TokenBucket, tokens: int) =
  ## Add `tokens` to the budget (capped to the bucket capacity)
  bucket.budget += tokens
  bucket.update()
  bucket.manuallyReplenished.fire()

proc new*(
  T: type[TokenBucket],
  budgetCap, fillPerMs: int): T =
  ## Create a TokenBucket
  T(
    budget: budgetCap,
    budgetCap: budgetCap,
    fillPerMs: fillPerMs,
    lastUpdate: Moment.now(),
    manuallyReplenished: newAsyncEvent()
  )

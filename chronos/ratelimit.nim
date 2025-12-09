#               Chronos Rate Limiter
#            (c) Copyright 2022-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

{.push raises: [].}

import std/math
import ../chronos
import ./timer

export timer

type
  ReplenishMode* = enum
    Continuous
      # Tokens are continuously replenished at a rate of
      #`capacity / fillDuration`, up to the configured capacity
    Discrete
      # Up to `capacity` tokens are replenished once every `fillDuration`, in
      # discrete steps, such that at the beginning of every `fillDuration`
      # period, there are `capacity` tokens available

  BucketWaiter = object
    future: Future[void]
    needed, consumed: int

  TokenBucket* = ref object
    ## This implements the standard [token bucket](https://en.wikipedia.org/wiki/Token_bucket)
    ## algorithm used for rate limiting and traffic shaping.
    ##
    ## Functionality:
    ## - `capacity` is the maximum number of tokens the bucket can hold.
    ## - `budget` is the current available tokens (<= capacity).
    ## - Tokens are added over time according to `fillDuration` and
    ##   `replenishMode`:
    ##     * Continuous: tokens accrue continuously at rate = capacity / fillDuration.
    ##     * Discrete: up to `capacity` tokens are added once per fillDuration period.
    ## - `consume(tokens)` waits (async) until `tokens` are available and then
    ##   consumes them. Pending consumers are queued in `pendingRequests` and
    ##   receive freshly minted tokens with priority.
    ## - `replenish(tokens)` allows manual token injection and wakes waiters.
    ##
    ## Notes:
    ## - The implementation gives priority to queued waiters over adding tokens
    ##   to `budget`, which ensures fairness for waiting consumers.
    ## - When `fillDuration` is zero (default Duration), automatic replenishment
    ##   is disabled and `replenish()` must be used to advance the bucket.

    budget: int
    capacity: int
    lastUpdate: Moment
    fillDuration: Duration
    workFuture: Future[void]
    pendingRequests: seq[BucketWaiter]
    manuallyReplenished: AsyncEvent
    replenishMode: ReplenishMode

proc refill(bucket: TokenBucket, tokens: int) =
  # Refill the bucket with the given amount of tokens, as happens during a
  # manual replenish or because time passed. The queue is given priority and any
  # remaining tokens, up to the configured capacity, are added to the budget of
  # available tokens.
  var tokens = tokens
  while tokens > 0 and bucket.pendingRequests.len > 0:
    template req0(): untyped =
      bucket.pendingRequests[0]

    let n = min(req0.needed, tokens)

    req0.needed -= n
    req0.consumed += n
    tokens -= n

    if req0.needed == 0:
      req0.future.complete()
      bucket.pendingRequests.delete(0)

  # Whatever budget remains gets capped by the capacity and kept for bursts
  bucket.budget = min(bucket.capacity, bucket.budget + tokens)

proc mint(bucket: TokenBucket, currentTime: Moment): int =
  # Mint new tokens based on the passing of time, as determined by the last mint
  # and the given timestamp.
  #
  # This function updates the latest timestamp but does not update the budget
  # or enforce capacity.
  if currentTime <= bucket.lastUpdate or bucket.fillDuration == default(Duration):
    0
  else:
    let
      # How much time passed since the last mint?
      diff = currentTime - bucket.lastUpdate # seconds
      # How many times would the bucket have been filled in this time?
      periods = diff.nanoseconds().float / bucket.fillDuration.nanoseconds().float

    case bucket.replenishMode
    of ReplenishMode.Continuous:
      let
        # How many tokens were minted in this time?.
        tokens = int(bucket.capacity.float * periods)
        # How much time is needed to mint that many tokens, after taking into
        # account the rounding?
        tokenTime =
          tokens.float / bucket.capacity.float * bucket.fillDuration.nanoseconds().float

      # Update the last update time based on the actual number of tokens that
      # were minted so that rounding error does not accumulate across mints
      bucket.lastUpdate = bucket.lastUpdate + nanoseconds(int64(tokenTime))
      tokens
    of ReplenishMode.Discrete:
      # How many full periods passed?
      let periods = int(periods)

      # Update the time based on the number full fill durations so that the
      # update always happens at a regular offset from the start time. This means
      # that if no update happens during a period, the tokens from that period
      # are lost.
      bucket.lastUpdate += periods * bucket.fillDuration
      bucket.capacity * periods

proc update(bucket: TokenBucket, currentTime: Moment) =
  let newTokens = bucket.mint(currentTime)
  bucket.refill(newTokens)

proc tryConsume*(bucket: TokenBucket, tokens: int, now = Moment.now()): bool =
  ## If `tokens` are available, consume them,
  ## Otherwise, return false.

  # Refill bucket in case time has passed, there are new tokens available and
  # requests can be satisfied. Notably, queued requests consume freshly minted
  # tokens with priority.
  bucket.update(now)

  if bucket.budget >= tokens:
    bucket.budget -= tokens
    true
  else:
    false

proc worker(bucket: TokenBucket) {.async: (raises: [CancelledError]).} =
  while true:
    bucket.manuallyReplenished.clear()

    let now = Moment.now()

    # `update` clears out any pending requests whose needs have been satisfied
    # by the passing of time
    bucket.update(now)

    if bucket.pendingRequests.len == 0:
      break

    # If there are remaining requests, it means that any new tokens were
    # consumed and we must wait for new tokens to arrive - we will thus sleep
    # for the amount of time it would take to mint the amount of tokens missing
    # for the first queued request and try again.
    let
      needed = bucket.pendingRequests[0].needed

      # How many periods must we wait for enough capacity to become available?
      periods = needed.float / bucket.capacity.float
      waitTime =
        case bucket.replenishMode
        of ReplenishMode.Continuous:
          nanoseconds(int64(periods * bucket.fillDuration.nanoseconds.float))
        of ReplenishMode.Discrete:
          nanoseconds(int64(ceil(periods) * bucket.fillDuration.nanoseconds.float))

      sleeper = sleepAsync(bucket.lastUpdate + waitTime - now)
      waiter = bucket.manuallyReplenished.wait()
    await sleeper or waiter

    sleeper.cancelSoon()
    waiter.cancelSoon()

  bucket.workFuture = nil

proc consume*(
    bucket: TokenBucket, tokens: int, now = Moment.now()
): Future[void] {.async: (raises: [CancelledError], raw: true).} =
  ## Wait for `tokens` to be available, and consume them.
  ##
  ## If the requested amount of tokens exceeds the capacity of the bucket, the
  ## wait will last as long as it takes to mint a sufficient amount of tokens.
  let retFuture = newFuture[void]("TokenBucket.consume")

  if bucket.tryConsume(tokens, now):
    retFuture.complete()
    return retFuture

  proc cancellation(udata: pointer) =
    for index in 0 ..< bucket.pendingRequests.len:
      if bucket.pendingRequests[index].future == retFuture:
        let recovered = bucket.pendingRequests[index].consumed
        bucket.pendingRequests.delete(index)

        if recovered > 0:
          # When a request is cancelled, it might already have received some
          # tokens -
          bucket.refill(recovered)

        if index == 0:
          bucket.manuallyReplenished.fire()
        break

  retFuture.cancelCallback = cancellation

  # When queueing the first item, there might still be budget available but
  # because tryConsume above failed, it is less than what was asked for.
  # In the case that this is not the first queued request, the budget will be
  # empty since all freshly minted tokens go towards emptying the queue.
  bucket.pendingRequests.add(
    BucketWaiter(
      future: retFuture, needed: tokens - bucket.budget, consumed: bucket.budget
    )
  )

  bucket.budget = 0

  if bucket.fillDuration != default(Duration) and
      (isNil(bucket.workFuture) or bucket.workFuture.finished()):
    bucket.workFuture = worker(bucket)

  retFuture

proc replenish*(bucket: TokenBucket, tokens: int, now = Moment.now()) =
  ## Add `tokens` to the budget (capped to the bucket capacity)
  bucket.refill(tokens)
  if bucket.replenishMode == ReplenishMode.Continuous:
    bucket.lastUpdate = now

  bucket.manuallyReplenished.fire()

proc getAvailableCapacity*(
    bucket: TokenBucket, currentTime: Moment = Moment.now()
): int =
  bucket.update(currentTime)

  bucket.budget

proc new*(
    T: type[TokenBucket],
    capacity: int,
    fillDuration: Duration = 1.seconds,
    startTime: Moment = Moment.now(),
    mode: static[ReplenishMode] = Continuous,
): T =
  ## Initialize a new token bucket with the given parameters - over time, the
  ## bucket will guarantee that tokens are given out at a rate capped to
  ## `capacity / fillDuration` tokens/s.
  ##
  ## When `fillDuration` is 0, the token bucket must be manually replenished
  ## with tokens to progress.
  T(
    budget: capacity,
    capacity: capacity,
    fillDuration: fillDuration,
    lastUpdate: startTime,
    manuallyReplenished: newAsyncEvent(),
    replenishMode: mode,
  )

func `$`*(b: TokenBucket): string {.inline.} =
  if isNil(b):
    return "nil"
  $b.capacity & "/" & $b.fillDuration

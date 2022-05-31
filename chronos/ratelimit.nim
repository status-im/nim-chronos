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
  TokenBucket* = object
    budget: int
    budgetCap: int
    lastUpdate: Moment
    fillPerMs: int

proc update(bucket: var TokenBucket) =
  let
    currentTime = Moment.now()
    timeDelta = milliseconds(currentTime - bucket.lastUpdate).int
    replenished = bucket.fillPerMs * timeDelta

  bucket.lastUpdate += timeDelta.milliseconds
  bucket.budget = min(bucket.budgetCap, bucket.budget + replenished)

proc tryConsume*(bucket: var TokenBucket, tokens: int): bool =
  ## If `tokens` are available, consume them,
  ## Otherwhise, return false.

  bucket.update()

  if bucket.budget >= tokens:
    bucket.budget -= tokens
    true
  else:
    false

proc consume*(bucket: var TokenBucket, tokens: int): Future[void] =
  ## Wait for `tokens` to be available, and consume them.
  ##
  ## `tokens` is not limited to the bucket cap
  doAssert(bucket.fillPerMs > 0, "consume is only available on autofilled buckets")

  if bucket.tryConsume(tokens):
    result = newFuture[void]("TokenBucket.consume")
    result.complete()
    return result

  bucket.budget -= tokens
  let timeToZero = milliseconds((-bucket.budget) div bucket.fillPerMs)
  return sleepAsync(timeToZero)

proc replenish*(bucket: var TokenBucket, tokens: int) =
  ## Add `tokens` to the budget (capped to the bucket capacity)
  bucket.budget += tokens
  bucket.update()

proc init*(
  T: type[TokenBucket],
  budgetCap, fillPerMs: int): T =
  ## Create a TokenBucket
  T(
    budget: budgetCap,
    budgetCap: budgetCap,
    fillPerMs: fillPerMs,
    lastUpdate: Moment.now()
  )

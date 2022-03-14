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
  RateCounter* = object
    budget: int64
    budgetCap: int64
    lastUpdate: Moment

  RateCounterRef* = ref RateCounter

  RateCost* = distinct int64

proc update(rc: var RateCounter) =
  let
    currentTime = Moment.now()
    timeDelta = nanoseconds(currentTime - rc.lastUpdate)

  rc.lastUpdate = currentTime
  rc.budget = min(rc.budgetCap, rc.budget + timeDelta)

proc operationsPerSecond*(ops: float): RateCost =
  ## Create a RateCost from an allowed number of 
  ## operations per second
  const budgetPerSecond = 1.seconds.nanoseconds.float

  RateCost(budgetPerSecond / ops)

proc timeBudgetPerSecond*(time, budget: Duration): RateCost =
  ## Create a RateCost from a time budget per second.
  runnableExamples:
    let start = Moment.now()
    # expensive computation
    let cost = timeBudgetPerSecond(
      Moment.now() - start,
      300.milliseconds # Allow 300 milliseconds of
                       # computation per second
    )
  let
    timeAsUs = time.nanoseconds.float
    budgetAsUs = budget.nanoseconds.float
    budgetUsed = timeAsUs / budgetAsUs
    allowedPerSeconds = 1.float / budgetUsed
  operationsPerSecond(allowedPerSeconds)

proc tryConsume*(rc: var RateCounter, cost: RateCost): bool =
  ## If there is still budget left, remove cost from the budget
  ## Otherwise, return false
  rc.update()
  if rc.budget >= 0:
    rc.budget -= int64(cost)
    true
  else:
    false

proc consume*(rc: var RateCounter, cost: RateCost): Future[void] =
  ## Wait until some budget is available, then substract cost
  ## from it

  # Manual async because of var argument
  rc.update()
  rc.budget -= int64(cost)

  if rc.budget >= 0:
    result = newFuture[void]("RateCounter.consume")
    result.complete()
    return result
  else:
    return sleepAsync(nanoseconds(-rc.budget))

proc init*(T: typedesc[RateCounter], cap: Duration): T =
  ## Create a RateCounter.
  ## The RateCounter will be smoothed out over the
  ## duration of `cap`.
  ##
  ## Example: RateCounter.init(10.seconds)
  ## 10 seconds worth of budget could be used instantly
  T(
    budget: cap.nanoseconds,
    budgetCap: cap.nanoseconds,
    lastUpdate: Moment.now()
  )

proc new*(T: typedesc[RateCounterRef], cap: Duration): T =
  T(
    budget: cap.nanoseconds,
    budgetCap: cap.nanoseconds,
    lastUpdate: Moment.now()
  )

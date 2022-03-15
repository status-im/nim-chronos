#                Chronos Test Suite
#            (c) Copyright 2022-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)
import unittest
import ../chronos
import ../chronos/ratelimit

suite "RateLimiter test suite":
  test "Sync test":
    var counter = RateCounter.init(2.seconds)

    check:
      # Use up the 2 seconds budget
      counter.tryConsume(operationsPerSecond(2)) == true
      counter.tryConsume(operationsPerSecond(2)) == true
      counter.tryConsume(operationsPerSecond(1)) == true
      counter.tryConsume(operationsPerSecond(1)) == true

      # Out of budget, should fail
      counter.tryConsume(operationsPerSecond(2)) == false

  test "Async test":
    var
      counter = RateCounter.init(1.seconds)
      toWait: seq[Future[void]]

    check counter.consume(operationsPerSecond(1000)).completed

    # Exhaust budget
    while counter.tryConsume(operationsPerSecond(1000)):
      discard

    for i in 0..<150:
      toWait.add(counter.consume(operationsPerSecond(100)))

    check counter.tryConsume(operationsPerSecond(1)) == false

    let start = Moment.now()
    waitFor(allFutures(toWait))
    let duration = Moment.now() - start
    # 150 with 100 op/seconds should take
    # 1.5 seconds
    check:
      duration > 1400.milliseconds
      duration < 1600.milliseconds

  test "Ref version":
    let counter = RateCounter.new(2.seconds)

    check:
      # Use up the 2 seconds budget
      counter[].consume(operationsPerSecond(2)).completed
      counter[].tryConsume(operationsPerSecond(2)) == true
      counter[].tryConsume(operationsPerSecond(1)) == true
      counter[].tryConsume(operationsPerSecond(1)) == true

      # Out of budget, should fail
      counter[].tryConsume(operationsPerSecond(2)) == false

  test "Time Budget Per Second":
    var counter = RateCounter.init(1.seconds)

    check:
      # Use start budget
      counter.tryConsume(timeBudgetPerSecond(10.milliseconds, 30.milliseconds)) == true
      counter.tryConsume(timeBudgetPerSecond(10.milliseconds, 30.milliseconds)) == true
      counter.tryConsume(timeBudgetPerSecond(10.milliseconds, 30.milliseconds)) == true

      counter.tryConsume(timeBudgetPerSecond(10.milliseconds, 30.milliseconds)) == true
      counter.tryConsume(timeBudgetPerSecond(10.milliseconds, 30.milliseconds)) == false

  test "TokensPerSecond":
    var counter = RateCounter.init(1.seconds)

    check:
      # Use start budget
      counter.tryConsume(tokensPerSecond(10, 30)) == true
      counter.tryConsume(tokensPerSecond(10, 30)) == true
      counter.tryConsume(tokensPerSecond(10, 30)) == true

      counter.tryConsume(tokensPerSecond(10, 30)) == true
      counter.tryConsume(tokensPerSecond(10, 30)) == false
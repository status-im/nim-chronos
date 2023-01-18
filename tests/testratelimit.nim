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

suite "Token Bucket":
  test "Sync test":
    var bucket = TokenBucket.new(1000, 1.milliseconds)
    check:
      bucket.tryConsume(800) == true
      bucket.tryConsume(200) == true

      # Out of budget
      bucket.tryConsume(100) == false
    waitFor(sleepAsync(10.milliseconds))
    check:
      bucket.tryConsume(800) == true
      bucket.tryConsume(200) == true

      # Out of budget
      bucket.tryConsume(100) == false

  test "Async test":
    var bucket = TokenBucket.new(1000, 500.milliseconds)
    check: bucket.tryConsume(1000) == true

    var toWait = newSeq[Future[void]]()
    for _ in 0..<15:
      toWait.add(bucket.consume(100))

    let start = Moment.now()
    waitFor(allFutures(toWait))
    let duration = Moment.now() - start

    check: duration in 700.milliseconds .. 1100.milliseconds

  test "Over budget async":
    var bucket = TokenBucket.new(100, 10.milliseconds)
    # Consume 10* the budget cap
    let beforeStart = Moment.now()
    waitFor(bucket.consume(1000).wait(1.seconds))
    when not defined(macosx):
      # CI's macos scheduler is so jittery that this tests sometimes takes >500ms
      # the test will still fail if it's >1 seconds
      check Moment.now() - beforeStart in 90.milliseconds .. 150.milliseconds

  test "Sync manual replenish":
    var bucket = TokenBucket.new(1000, 0.seconds)
    check:
      bucket.tryConsume(1000) == true
      bucket.tryConsume(1000) == false
    bucket.replenish(2000)
    check:
      bucket.tryConsume(1000) == true
      # replenish is capped to the bucket max
      bucket.tryConsume(1000) == false

  test "Async manual replenish":
    var bucket = TokenBucket.new(10 * 150, 0.seconds)
    check:
      bucket.tryConsume(10 * 150) == true
      bucket.tryConsume(1000) == false
    var toWait = newSeq[Future[void]]()
    for _ in 0..<150:
      toWait.add(bucket.consume(10))

    let lastOne = bucket.consume(10)

    # Test cap as well
    bucket.replenish(1000000)
    waitFor(allFutures(toWait).wait(10.milliseconds))

    check: not lastOne.finished()

    bucket.replenish(10)
    waitFor(lastOne.wait(10.milliseconds))

  test "Async cancellation":
    var bucket = TokenBucket.new(100, 0.seconds)
    let
      fut1 = bucket.consume(20)
      futBlocker = bucket.consume(1000)
      fut2 = bucket.consume(50)

    waitFor(fut1.wait(10.milliseconds))
    waitFor(sleepAsync(10.milliseconds))
    check:
      futBlocker.finished == false
      fut2.finished == false

    futBlocker.cancel()
    waitFor(fut2.wait(10.milliseconds))

  test "Very long replenish":
    var bucket = TokenBucket.new(7000, 1.hours)
    check bucket.tryConsume(7000)
    check bucket.tryConsume(1) == false

    # With this setting, it takes 514 milliseconds
    # to tick one. Check that we can eventually
    # consume, even if we update multiple time
    # before that
    let start = Moment.now()
    while Moment.now() - start >= 514.milliseconds:
      check bucket.tryConsume(1) == false
      waitFor(sleepAsync(10.milliseconds))

    check bucket.tryConsume(1) == false

  test "Short replenish":
    var bucket = TokenBucket.new(15000, 1.milliseconds)
    check bucket.tryConsume(15000)
    check bucket.tryConsume(1) == false

    waitFor(sleepAsync(1.milliseconds))
    check bucket.tryConsume(15000) == true

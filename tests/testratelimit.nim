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
    var bucket = TokenBucket.init(1000, 1000)
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
    var bucket = TokenBucket.init(1000, 1)
    check: bucket.tryConsume(1000) == true

    var toWait = newSeq[Future[void]]()
    for _ in 0..<150:
      toWait.add(bucket.consume(10))

    let start = Moment.now()
    waitFor(allFutures(toWait))
    let duration = Moment.now() - start

    check: duration in 1400.milliseconds .. 1600.milliseconds

  test "Manual replenish":
    var bucket = TokenBucket.init(1000, 0)
    check:
      bucket.tryConsume(1000) == true
      bucket.tryConsume(1000) == false
    bucket.replenish(2000)
    check:
      bucket.tryConsume(1000) == true
      bucket.tryConsume(1000) == false

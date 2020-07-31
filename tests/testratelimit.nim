#                Chronos Test Suite
#            (c) Copyright 2020-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)
import unittest, os
import ../chronos/[ratelimit, timer]

suite "RateLimiter test suite":
  test "Single subject allow/reject test":
    var limiter = RateLimiter.init()
    limiter.newRateCounter("/some/resource", 100.milliseconds, 5)

    var success = 0
    var failure = 0
    for i in 0 ..< 100:
      if limiter.checkRate("/some/resource"):
        inc(success)
      else:
        inc(failure)

    check success == 5
    check failure == 95

    # Sleeping for 200 milliseconds for sure
    os.sleep(200)
    success = 0
    failure = 0

    for i in 0 ..< 100:
      if limiter.checkRate("/some/resource"):
        inc(success)
      else:
        inc(failure)

    check success == 5
    check failure == 95

  test "Consumers allow/reject test":
    var limiter = RateLimiter.init()
    limiter.newRateCounter("/some/resource", 100.milliseconds, 5)

    var success = @[0, 0, 0, 0, 0, 0]
    var failure = @[0, 0, 0, 0, 0, 0]

    for i in 0 ..< 100:
      if limiter.checkRate("/some/resource", "client1"):
        inc(success[0])
      else:
        inc(failure[0])

    for i in 0 ..< 100:
      if limiter.checkRate("/some/resource", "client2"):
        inc(success[1])
      else:
        inc(failure[1])

    for i in 0 ..< 100:
      if limiter.checkRate("/some/resource", "client3"):
        inc(success[2])
      else:
        inc(failure[2])

    check:
      success[0] == 5
      success[1] == 5
      success[2] == 5
      failure[0] == 95
      failure[1] == 95
      failure[2] == 95

    # Sleeping for 200 milliseconds for sure
    os.sleep(200)

    for i in 0 ..< 100:
      if limiter.checkRate("/some/resource", "client1"):
        inc(success[3])
      else:
        inc(failure[3])

    for i in 0 ..< 100:
      if limiter.checkRate("/some/resource", "client2"):
        inc(success[4])
      else:
        inc(failure[4])

    for i in 0 ..< 100:
      if limiter.checkRate("/some/resource", "client3"):
        inc(success[5])
      else:
        inc(failure[5])

    check:
      success[3] == 5
      success[4] == 5
      success[5] == 5
      failure[3] == 95
      failure[4] == 95
      failure[5] == 95

  test "Combination of subject and consumers accept/reject test":
    var limiter = RateLimiter.init()
    limiter.newRateCounter("/some/resource/consumers", 100.milliseconds, 5)
    limiter.newRateCounter("/some/resource", 1.seconds, 300)

    var success = @[0, 0, 0, 0]
    var failure = @[0, 0, 0, 0]

    for i in 0 ..< 100:
      let chk1 = limiter.checkRate("/some/resource/consumers", "client1")
      let chk2 = limiter.checkRate("/some/resource")
      if chk1 and chk2:
        inc(success[0])
      else:
        inc(failure[0])

    for i in 0 ..< 100:
      let chk1 = limiter.checkRate("/some/resource/consumers", "client2")
      let chk2 = limiter.checkRate("/some/resource")
      if chk1 and chk2:
        inc(success[1])
      else:
        inc(failure[1])

    for i in 0 ..< 100:
      let chk1 = limiter.checkRate("/some/resource/consumers", "client3")
      let chk2 = limiter.checkRate("/some/resource")
      if chk1 and chk2:
        inc(success[2])
      else:
        inc(failure[2])

    for i in 0 ..< 100:
      let chk1 = limiter.checkRate("/some/resource/consumers", "client4")
      let chk2 = limiter.checkRate("/some/resource")
      if chk1 and chk2:
        inc(success[3])
      else:
        inc(failure[3])

    check:
      success[0] == 5
      success[1] == 5
      success[2] == 5
      success[3] == 0
      failure[0] == 95
      failure[1] == 95
      failure[2] == 95
      failure[3] == 100

  test "removeCounter() test":
    var limiter = RateLimiter.init()
    limiter.newRateCounter("/some/resource", 100.milliseconds, 5)

    var success = 0
    var failure = 0
    for i in 0 ..< 100:
      if limiter.checkRate("/some/resource"):
        inc(success)
      else:
        inc(failure)

    check success == 5
    check failure == 95

    limiter.removeCounter("/some/resource")
    success = 0
    failure = 0

    for i in 0 ..< 100:
      if limiter.checkRate("/some/resource"):
        inc(success)
      else:
        inc(failure)

    check success == 5
    check failure == 95

  test "removeRate() test":
    var limiter = RateLimiter.init()
    limiter.newRateCounter("/some/resource", 100.milliseconds, 5)

    var success = 0
    var failure = 0
    for i in 0 ..< 100:
      if limiter.checkRate("/some/resource"):
        inc(success)
      else:
        inc(failure)

    check success == 5
    check failure == 95

    limiter.removeRate("/some/resource")
    success = 0
    failure = 0

    for i in 0 ..< 100:
      if limiter.checkRate("/some/resource"):
        inc(success)
      else:
        inc(failure)

    check success == 100
    check failure == 0

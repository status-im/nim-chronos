#                Chronos Test Suite
#            (c) Copyright 2022-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

{.used.}

import unittest2
import ../chronos
import ../chronos/ratelimit

suite "Token Bucket":
  test "Sync test":
    var bucket = TokenBucket.new(1000, 1.milliseconds)
    let
      start = Moment.now()
      fullTime = start + 1.milliseconds
    check:
      bucket.tryConsume(800, start) == true
      bucket.tryConsume(200, start) == true

      # Out of budget
      bucket.tryConsume(100, start) == false
      bucket.tryConsume(800, fullTime) == true
      bucket.tryConsume(200, fullTime) == true

      # Out of budget
      bucket.tryConsume(100, fullTime) == false

  test "Async test":
    var bucket = TokenBucket.new(1000, 1000.milliseconds)
    check: bucket.tryConsume(1000) == true

    var toWait = newSeq[Future[void]]()
    for _ in 0..<15:
      toWait.add(bucket.consume(100))

    let start = Moment.now()
    waitFor(allFutures(toWait))
    let duration = Moment.now() - start

    check: duration in 1400.milliseconds .. 2200.milliseconds

  test "Over budget async":
    var bucket = TokenBucket.new(100, 100.milliseconds)
    # Consume 10* the budget cap
    let beforeStart = Moment.now()
    waitFor(bucket.consume(1000).wait(5.seconds))
    check Moment.now() - beforeStart in 900.milliseconds .. 2200.milliseconds

  test "Sync manual replenish":
    var bucket = TokenBucket.new(1000, 0.seconds)
    let start = Moment.now()
    check:
      bucket.tryConsume(1000, start) == true
      bucket.tryConsume(1000, start) == false
    bucket.replenish(2000)
    check:
      bucket.tryConsume(1000, start) == true
      # replenish is capped to the bucket max
      bucket.tryConsume(1000, start) == false

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

    futBlocker.cancelSoon()
    waitFor(fut2.wait(10.milliseconds))

  test "Very long replenish":
    var bucket = TokenBucket.new(7000, 1.hours)
    let start = Moment.now()
    check bucket.tryConsume(7000, start)
    check bucket.tryConsume(1, start) == false

    # With this setting, it takes 514 milliseconds
    # to tick one. Check that we can eventually
    # consume, even if we update multiple time
    # before that
    var fakeNow = start
    while fakeNow - start < 514.milliseconds:
      check bucket.tryConsume(1, fakeNow) == false
      fakeNow += 30.milliseconds

    check bucket.tryConsume(1, fakeNow) == true

  test "Short replenish":
    var bucket = TokenBucket.new(15000, 1.milliseconds)
    let start = Moment.now()
    check bucket.tryConsume(15000, start)
    check bucket.tryConsume(1, start) == false

    check bucket.tryConsume(15000, start + 1.milliseconds) == true

  # Edge-case: ensure only one refill can occur for the same timestamp even if
  # multiple tryConsume calls are made that would otherwise appear to have large
  # elapsed time credit. This prevents multi-call burst inflation at a single time.
  test "No double refill at same timestamp":
    var bucket = TokenBucket.new(10, 100.milliseconds)
    let t0 = Moment.now()
    # Consume from full so lastUpdate is stamped at t0
    check bucket.tryConsume(5, t0) == true  # budget now 5
    # Long idle period (simulate large elapsed time)
    let idle = t0 + 5.seconds
    # First large request triggers an update + refill limited by space (5)
    check bucket.tryConsume(6, idle) == true  # budget after = 4 (5 minted -> 10 then -6)
    # Second request at the SAME timestamp cannot refill again
    check bucket.tryConsume(5, idle) == false
    # Prove only 4 remain: consuming 4 succeeds, then 1 more fails at same timestamp
    check bucket.tryConsume(4, idle) == true
    check bucket.tryConsume(1, idle) == false

  # Edge-case fairness: partial usage should only mint up to available space, not
  # more than cap, and leftover elapsed time is burned once cap is reached.
  test "Refill limited by available space":
    var bucket = TokenBucket.new(10, 100.milliseconds)
    let t0 = Moment.now()
    # Spend a portion (from full) -> lastUpdate = t0, budget 4
    check bucket.tryConsume(6, t0) == true
    # Mid-period small consume without triggering update (still before refill point)
    let mid = t0 + 50.milliseconds
    check bucket.tryConsume(1, mid) == true  # budget 3
    # At the 100ms boundary request more than remaining budget to force update
    let boundary = t0 + 100.milliseconds
    # Space is 7; even though 100ms elapsed corresponds to 10 possible tokens,
    # only 7 are minted and leftover elapsed time credit is discarded.
    check bucket.tryConsume(6, boundary) == true  # leaves 4
    # A second consume at identical boundary timestamp cannot mint more than residual
    check bucket.tryConsume(5, boundary) == false
    # After another 40ms, at most floor(40/100 * 10)=4 tokens accrue; request 4 succeeds
    let late = boundary + 40.milliseconds
    check bucket.tryConsume(4, late) == true  # should deplete
    # A subsequent call at the same timestamp may mint remaining fractional time credit (fair catch-up)
    # so a small consume can still succeed.
    check bucket.tryConsume(1, late) == true

  test "Strict replenish mode does not refill before period elapsed":
    var bucket = TokenBucket.new(10, 100.milliseconds, ReplenishMode.Strict)
    let t0 = Moment.now()
    # Spend a portion (from full) -> lastUpdate = t0, budget 10
    check bucket.tryConsume(9, t0) == true # leaves 1

    var cap = bucket.getAvailableCapacity(t0)
    check cap.budget == 1
    check cap.lastUpdate == t0
    check cap.budgetCapacity == 10

    let mid = t0 + 50.milliseconds

    cap = bucket.getAvailableCapacity(mid)
    check cap.budget == 1
    check cap.lastUpdate == t0
    check cap.budgetCapacity == 10

    check bucket.tryConsume(2, mid) == false  # no update before period boundary passed, budget 1

    let boundary = t0 + 100.milliseconds

    cap = bucket.getAvailableCapacity(boundary)
    check cap.budget == 10
    check cap.lastUpdate == boundary
    check cap.budgetCapacity == 10

    check bucket.tryConsume(2, boundary) == true  # ok, we passed the period boundary now, leaves 8

  test "Balanced high-rate single-token 10/10ms over 40ms":
    # Capacity 10, fillDuration 10ms (1 token/ms). Only 1-token requests are made
    # at specific timestamps within 0–40ms (4 full periods). We verify that no
    # more than 50 tokens can be consumed in total and that per-batch accept/reject
    # counts and lastUpdate values match expectations.
    var bucket = TokenBucket.new(10, 10.milliseconds)
    let t0 = Moment.now()
    let t5 = t0 + 5.milliseconds
    let t10 = t0 + 10.milliseconds
    let t12 = t0 + 12.milliseconds
    let t20 = t0 + 20.milliseconds
    let t30 = t0 + 30.milliseconds
    let t31 = t0 + 31.milliseconds
    let t40 = t0 + 40.milliseconds

    proc attempt(count: int, now: Moment): tuple[accepted, rejected: int] =
      var acc = 0
      var rej = 0
      for _ in 0..<count:
        if bucket.tryConsume(1, now):
          inc acc
        else:
          inc rej
      (acc, rej)

    # 0ms: 12 attempts -> accept 10, reject 2; budget ends 0; LU=0ms (consume-from-full)
    var r = attempt(12, t0)
    check r.accepted == 10
    check r.rejected == 2
    var cap = bucket.getAvailableCapacity(t0)
    check cap.budget == 0
    check cap.lastUpdate == t0

    # 5ms: 7 attempts -> mint 5 then accept 5, reject 2; budget 0; LU=5ms
    r = attempt(7, t5)
    check r.accepted == 5
    check r.rejected == 2
    cap = bucket.getAvailableCapacity(t5)
    check cap.budget == 0
    check cap.lastUpdate == t5

    # 10ms: 15 attempts -> mint 5 then accept 5, reject 10; budget 0; LU=10ms
    r = attempt(15, t10)
    check r.accepted == 5
    check r.rejected == 10
    cap = bucket.getAvailableCapacity(t10)
    check cap.budget == 0
    check cap.lastUpdate == t10

    # 12ms: 3 attempts -> mint 2 then accept 2, reject 1; budget 0; LU=12ms
    r = attempt(3, t12)
    check r.accepted == 2
    check r.rejected == 1
    cap = bucket.getAvailableCapacity(t12)
    check cap.budget == 0
    check cap.lastUpdate == t12

    # 20ms: 25 attempts -> mint 8 then accept 8, reject 17; budget 0; LU=20ms
    r = attempt(25, t20)
    check r.accepted == 8
    check r.rejected == 17
    cap = bucket.getAvailableCapacity(t20)
    check cap.budget == 0
    check cap.lastUpdate == t20

    # 30ms: 9 attempts -> mint 10 then accept 9, budget ends 1; LU=30ms
    r = attempt(9, t30)
    check r.accepted == 9
    check r.rejected == 0
    cap = bucket.getAvailableCapacity(t30)
    check cap.budget == 1
    check cap.lastUpdate == t30

    # 31ms: 3 attempts -> mint 1 then accept 2, reject 1; budget 0; LU=31ms
    r = attempt(3, t31)
    check r.accepted == 2
    check r.rejected == 1
    cap = bucket.getAvailableCapacity(t31)
    check cap.budget == 0
    check cap.lastUpdate == t31

    # 40ms: 20 attempts -> mint 9 then accept 9, reject 11; budget 0; LU=40ms
    r = attempt(20, t40)
    check r.accepted == 9
    check r.rejected == 11
    cap = bucket.getAvailableCapacity(t40)
    check cap.budget == 0
    check cap.lastUpdate == t40

    # Totals across 0–40ms window
    let totalAccepted = 10 + 5 + 5 + 2 + 8 + 9 + 2 + 9
    let totalRejected = 2 + 2 + 10 + 1 + 17 + 0 + 1 + 11
    check totalAccepted == 50
    check totalRejected == 44

  test "Balanced high-rate single-token 10/10ms over 40ms (advancing time)":
    # Variant of the high-rate test where each tryConsume occurs at a timestamp that
    # advances by ~1ms when possible, simulating a more realistic stream of requests.
    # We still demand more than can be provided to ensure rejections, and we verify
    # that across 0–40ms only 50 tokens can be accepted.
    var bucket = TokenBucket.new(10, 10.milliseconds)
    let t0 = Moment.now()

    var accepted = 0
    var rejected = 0
    # Perform 94 attempts; for the first 41 attempts we increase the timestamp by 1ms
    # per attempt (up to t0+40ms). After that, we keep attempting at t0+40ms to
    # simulate concurrent bursts at the end of the window.
    for i in 0..<94:
      let ts = t0 + min(i, 40).milliseconds
      if bucket.tryConsume(1, ts):
        inc accepted
      else:
        inc rejected

    # At most 10 (initial) + 40 (minted over 40ms) can be accepted
    check accepted == 50
    check rejected == 44

    let t40 = t0 + 40.milliseconds
    let cap = bucket.getAvailableCapacity(t40)
    # All available tokens within the window should have been consumed by our attempts
    check cap.budget == 0

  # Balanced-mode scenario reproductions and timeline validation
  test "Balanced Scenario 1 timeline":
    # Capacity 10, fillDuration 1s, per-token time 100ms
    var bucket = TokenBucket.new(10, 1.seconds)

    let t0 = Moment.now()
    let t200 = t0 + 200.milliseconds
    let t600 = t0 + 600.milliseconds
    let t650 = t0 + 650.milliseconds
    let t1000 = t0 + 1000.milliseconds
    let t1200 = t0 + 1200.milliseconds
    let t1800 = t0 + 1800.milliseconds
    let t2100 = t0 + 2100.milliseconds
    let t2600 = t0 + 2600.milliseconds
    let t3000 = t0 + 3000.milliseconds

    # 1) t=0ms: consume 7 from full -> LU set to t0, budget 3
    check bucket.tryConsume(7, t0) == true
    var cap = bucket.getAvailableCapacity(t0)
    check cap.budget == 3
    check cap.lastUpdate == t0

    # 2) t=200ms: request 5 -> mint 2, then consume -> budget 0, LU=200ms
    check bucket.tryConsume(5, t200) == true
    cap = bucket.getAvailableCapacity(t200)
    check cap.budget == 0
    check cap.lastUpdate == t200

    # 3) t=650ms: request 3 -> mint 4 (to t600), then consume -> budget 1, LU=600ms
    check bucket.tryConsume(3, t650) == true
    cap = bucket.getAvailableCapacity(t600)
    check cap.budget == 1
    check cap.lastUpdate == t600

    # 4) t=1000ms: availability check only (does not mutate); expected 4 minted -> budget 5, LU=1000ms
    cap = bucket.getAvailableCapacity(t1000)
    check cap.budget == 5
    check cap.lastUpdate == t1000

    # 5) t=1200ms: request 6 -> net minted since LU to here totals 6 -> budget ends 1, LU=1200ms
    check bucket.tryConsume(6, t1200) == true
    cap = bucket.getAvailableCapacity(t1200)
    check cap.budget == 1
    check cap.lastUpdate == t1200

    # 6) t=1800ms: request 5 -> mint 6 then consume -> budget 2, LU=1800ms
    check bucket.tryConsume(5, t1800) == true
    cap = bucket.getAvailableCapacity(t1800)
    check cap.budget == 2
    check cap.lastUpdate == t1800

    # 7) t=2100ms: request 10 -> mint 3 to reach 5, still insufficient -> false, LU=2100ms
    check bucket.tryConsume(10, t2100) == false
    cap = bucket.getAvailableCapacity(t2100)
    check cap.budget == 5
    check cap.lastUpdate == t2100

    # 8) t=2600ms: enough time for 5 more -> reach full and then consume 10 -> budget 0, LU=2600ms
    check bucket.tryConsume(10, t2600) == true
    cap = bucket.getAvailableCapacity(t2600)
    check cap.budget == 0
    check cap.lastUpdate == t2600

    # 9) t=3000ms: availability check -> mint 4 -> budget 4, LU=3000ms
    cap = bucket.getAvailableCapacity(t3000)
    check cap.budget == 4
    check cap.lastUpdate == t3000

  test "Balanced: idle while full burns time":
    # Capacity 5, fillDuration 1s, per-token time 200ms
    var bucket = TokenBucket.new(5, 1.seconds)
    let t0 = Moment.now()
    let t2_5 = t0 + 2500.milliseconds
    # Consume 1 after long idle at full -> LU set to now
    check bucket.tryConsume(1, t2_5) == true
    var cap = bucket.getAvailableCapacity(t2_5)
    check cap.budget == 4
    check cap.lastUpdate == t2_5
    # 100ms later is below per-token time -> no mint
    let t2_6 = t0 + 2600.milliseconds
    cap = bucket.getAvailableCapacity(t2_6)
    check cap.budget == 4
    check cap.lastUpdate == t2_5

  test "Balanced: large jump clamps to capacity and LU=now when capped":
    # Capacity 8, fillDuration 4s, per-token time 0.5s
    var bucket = TokenBucket.new(8, 4.seconds)
    let t0 = Moment.now()
    # Spend 6 from full so LU = t0, budget = 2
    check bucket.tryConsume(6, t0) == true

    let t5 = t0 + 5.seconds
    # Availability check: should reach cap and set LU to t5 (hit-cap path burns leftover time)
    var cap2 = bucket.getAvailableCapacity(t5)
    check cap2.budget == 8
    check cap2.lastUpdate == t5

    # Consume 3 slightly later; update will also clamp and set LU to now, then consume from full
    let t5_2 = t0 + 5200.milliseconds
    check bucket.tryConsume(3, t5_2) == true
    cap2 = bucket.getAvailableCapacity(t5_2)
    check cap2.budget == 5
    check cap2.lastUpdate == t5_2

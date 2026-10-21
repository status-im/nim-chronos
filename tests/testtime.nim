#                Chronos Test Suite
#            (c) Copyright 2018-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)
import unittest2
import ../chronos, ../chronos/timer
import ../chronos/unittest2/asynctests

{.used.}

static:
  doAssert Moment.high - Moment.low == Duration.high
  doAssert Moment.low.epochSeconds == 0
  doAssert Moment.low.epochNanoSeconds == 0

suite "Asynchronous timers & steps test suite":
  const timersCount = 10

  proc timersTest(timeout: Duration): Future[Duration] {.async.} =
    proc timeWorker(time: Duration): Future[Duration] {.async.} =
      var st = Moment.now()
      await sleepAsync(time)
      var et = Moment.now()
      result = et - st

    var workers = newSeq[Future[Duration]](timersCount)
    for i in 0..<timersCount:
      workers[i] = timeWorker(timeout)
    await allFutures(workers)
    var sum: Duration
    for i in 0..<timersCount:
      sum += workers[i].read()
    result = sum div 10'i64

  asyncTest "Timer reliability test [asyncTimer]":
    check fseconds(1.0).fseconds() == 1.0

    let a = Moment.now()
    await sleepAsync(1000.milliseconds)
    let b = Moment.now()
    let d = b - a
    check:
      (d >= 1000.milliseconds) and (d <= 3000.milliseconds)
      (d.fseconds() >= 1.0) and (d.fseconds() <= 3.0)

  test $timersCount & " timers with 10ms timeout":
    let res = waitFor(timersTest(10.milliseconds))
    check (res >= 10.milliseconds) and (res <= 100.milliseconds)

  test $timersCount & " timers with 100ms timeout":
    let res = waitFor(timersTest(100.milliseconds))
    check (res >= 100.milliseconds) and (res <= 1000.milliseconds)

  test $timersCount & " timers with 1000ms timeout":
    let res = waitFor(timersTest(1000.milliseconds))
    check (res >= 1000.milliseconds) and (res <= 5000.milliseconds)

  test "Timer stringification test":
    check:
      $weeks(1) == "1w"
      $days(1) == "1d"
      $hours(1) == "1h"
      $minutes(1) == "1m"
      $seconds(1) == "1s"
      $milliseconds(1) == "1ms"
      $microseconds(1) == "1us"
      $nanoseconds(1) == "1ns"
      $(weeks(1) + days(1)) == "1w1d"
      $(days(1) + hours(1)) == "1d1h"
      $(hours(1) + minutes(1)) == "1h1m"
      $(minutes(1) + seconds(1)) == "1m1s"
      $(seconds(1) + milliseconds(1)) == "1s1ms"
      $(milliseconds(1) + microseconds(1)) == "1ms1us"
      $nanoseconds(1_000_000_000) == "1s"
      $nanoseconds(1_900_000_000) == "1s900ms"
      $nanoseconds(1_000_900_000) == "1s900us"
      $nanoseconds(1_000_000_900) == "1s900ns"
      $nanoseconds(1_800_700_000) == "1s800ms700us"
      $nanoseconds(1_800_000_600) == "1s800ms600ns"
      nanoseconds(1_800_000_600).toString(0) == ""
      nanoseconds(1_800_000_600).toString(1) == "1s"
      nanoseconds(1_800_000_600).toString(2) == "1s800ms"

  test "Asynchronous steps test":
    var fut1 = stepsAsync(1)
    var fut2 = stepsAsync(2)
    var fut3 = stepsAsync(3)

    check:
      fut1.completed() == false
      fut2.completed() == false
      fut3.completed() == false

    # We need `fut` because `stepsAsync` do not power `poll()` anymore.
    block:
      var fut {.used.} = sleepAsync(50.milliseconds)
      poll()

    check:
      fut1.completed() == true
      fut2.completed() == false
      fut3.completed() == false

    block:
      var fut {.used.} = sleepAsync(50.milliseconds)
      poll()

    check:
      fut2.completed() == true
      fut3.completed() == false

    block:
      var fut {.used.} = sleepAsync(50.milliseconds)
      poll()

    check:
      fut3.completed() == true

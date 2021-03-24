#                Chronos Test Suite
#            (c) Copyright 2018-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)
import std/os
import unittest2
import ../chronos, ../chronos/timer

when defined(nimHasUsed): {.used.}

suite "Asynchronous timers & steps test suite":
  const TimersCount = 10

  proc timeWorker(time: Duration): Future[Duration] {.async.} =
    var st = Moment.now()
    await sleepAsync(time)
    var et = Moment.now()
    result = et - st

  proc waitAll[T](futs: seq[Future[T]]): Future[void] =
    var counter = len(futs)
    var retFuture = newFuture[void]("waitAll")
    proc cb(udata: pointer) =
      dec(counter)
      if counter == 0:
        retFuture.complete()
    for fut in futs:
      fut.addCallback(cb)
    return retFuture

  proc test(timeout: Duration): Future[Duration] {.async.} =
    var workers = newSeq[Future[Duration]](TimersCount)
    for i in 0..<TimersCount:
      workers[i] = timeWorker(timeout)
    await waitAll(workers)
    var sum: Duration
    for i in 0..<TimersCount:
      var time = workers[i].read()
      sum = sum + time
    result = sum div 10'i64

  proc testTimer(): bool =
    let a = Moment.now()
    waitFor(sleepAsync(1000.milliseconds))
    let b = Moment.now()
    let d = b - a
    result = (d >= 1000.milliseconds) and (d <= 3000.milliseconds)
    if not result:
      echo d

  test "Timer reliability test [" & asyncTimer & "]":
    check testTimer() == true
  test $TimersCount & " timers with 10ms timeout":
    var res = waitFor(test(10.milliseconds))
    check (res >= 10.milliseconds) and (res <= 100.milliseconds)
  test $TimersCount & " timers with 100ms timeout":
    var res = waitFor(test(100.milliseconds))
    check (res >= 100.milliseconds) and (res <= 1000.milliseconds)
  test $TimersCount & " timers with 1000ms timeout":
    var res = waitFor(test(1000.milliseconds))
    check (res >= 1000.milliseconds) and (res <= 5000.milliseconds)
  test "Asynchronous steps test":
    var futn1 = stepsAsync(-1)
    var fut0 = stepsAsync(0)
    var fut1 = stepsAsync(1)
    var fut2 = stepsAsync(2)
    var fut3 = stepsAsync(3)
    check:
      futn1.completed() == true
      fut0.completed() == true
      fut1.completed() == false
      fut2.completed() == false
      fut3.completed() == false
    poll()
    check:
      fut1.completed() == true
      fut2.completed() == false
      fut3.completed() == false
    poll()
    check:
      fut2.completed() == true
      fut3.completed() == false
    poll()
    check:
      fut3.completed() == true

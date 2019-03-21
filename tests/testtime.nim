#                Chronos Test Suite
#            (c) Copyright 2018-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

import os, unittest
import ../chronos, ../chronos/timer

const TimersCount = 10

proc timeWorker(time: int): Future[int] {.async.} =
  var st = fastEpochTime()
  await sleepAsync(time)
  var et = fastEpochTime()
  result = int(et - st)

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

proc test(timeout: int): Future[int64] {.async.} =
  var workers = newSeq[Future[int]](TimersCount)
  for i in 0..<TimersCount:
    workers[i] = timeWorker(timeout)
  await waitAll(workers)
  var sum = 0'i64
  for i in 0..<TimersCount:
    var time = workers[i].read()
    sum = sum + time
  result = sum div 10'i64

proc testTimer(): bool =
  var a1 = fastEpochTime()
  var a2 = fastEpochTimeNano()
  waitFor(sleepAsync(1000))
  var b1 = fastEpochTime()
  var b2 = fastEpochTimeNano()
  var r1 = (b1 - a1) >= uint64(1 * 1_000)
  var r2 = (b2 - a2) >= uint64(1 * 1_000_000_000)
  result = r1 and r2

when isMainModule:
  suite "Asynchronous timers test suite":
    test "Timer reliability test [" & asyncTimer & "]":
      check testTimer() == true
    test $TimersCount & " timers with 10ms timeout":
      var res = waitFor(test(10))
      check (res >= 10) and (res <= 100)
    test $TimersCount & " timers with 100ms timeout":
      var res = waitFor(test(100))
      check (res >= 100) and (res <= 1000)
    test $TimersCount & " timers with 1000ms timeout":
      var res = waitFor(test(1000))
      check (res >= 1000) and (res <= 5000)

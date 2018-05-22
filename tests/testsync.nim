#              Asyncdispatch2 Test Suite
#                 (c) Copyright 2018
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

import strutils, net, unittest, os
import ../asyncdispatch2

var testLockResult = ""
var testEventResult = ""
var testQueue1Result = 0
var testQueue2Result = 0

proc testLock(n: int, lock: AsyncLock) {.async.} =
  await lock.acquire()
  testLockResult = testLockResult & $n
  lock.release()

proc test1(): string =
  var lock = newAsyncLock()
  lock.own()
  discard testLock(0, lock)
  discard testLock(1, lock)
  discard testLock(2, lock)
  discard testLock(3, lock)
  discard testLock(4, lock)
  discard testLock(5, lock)
  discard testLock(6, lock)
  discard testLock(7, lock)
  discard testLock(8, lock)
  discard testLock(9, lock)
  lock.release()
  ## There must be exactly 20 poll() calls
  for i in 0..<20:
    poll()
  result = testLockResult

proc testEvent(n: int, ev: AsyncEvent) {.async.} =
  await ev.wait()
  testEventResult = testEventResult & $n

proc test2(): string =
  var event = newAsyncEvent()
  event.clear()
  discard testEvent(0, event)
  discard testEvent(1, event)
  discard testEvent(2, event)
  discard testEvent(3, event)
  discard testEvent(4, event)
  discard testEvent(5, event)
  discard testEvent(6, event)
  discard testEvent(7, event)
  discard testEvent(8, event)
  discard testEvent(9, event)
  event.fire()
  ## There must be exactly 2 poll() calls
  poll()
  poll()
  result = testEventResult

proc task1(aq: AsyncQueue[int]) {.async.} =
  var item1 = await aq.get()
  var item2 = await aq.get()
  testQueue1Result = item1 + item2

proc task2(aq: AsyncQueue[int]) {.async.} =
  await aq.put(1000)
  await aq.put(2000)

proc test3(): int =
  var queue = newAsyncQueue[int](1)
  discard task1(queue)
  discard task2(queue)
  ## There must be exactly 2 poll() calls
  poll()
  poll()
  result = testQueue1Result

const testsCount = 1000
const queueSize = 10

proc task3(aq: AsyncQueue[int]) {.async.} =
  for i in 1..testsCount:
    var item = await aq.get()
    testQueue2Result -= item

proc task4(aq: AsyncQueue[int]) {.async.} =
  for i in 1..testsCount:
    await aq.put(i)
    testQueue2Result += i

proc test4(): int =
  var queue = newAsyncQueue[int](queueSize)
  waitFor(task3(queue) and task4(queue))
  result = testQueue2Result

when isMainModule:
  suite "Asynchronous sync primitives test suite":
    test "AsyncLock() behavior test":
      check test1() == "0123456789"
    test "AsyncEvent() behavior test":
      check test2() == "0123456789"
    test "AsyncQueue() behavior test":
      check test3() == 3000
    test "AsyncQueue() many iterations test":
      check test4() == 0

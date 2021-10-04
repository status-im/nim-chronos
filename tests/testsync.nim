#                Chronos Test Suite
#            (c) Copyright 2018-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)
import unittest2
import ../chronos

when defined(nimHasUsed): {.used.}

suite "Asynchronous sync primitives test suite":
  var testLockResult {.threadvar.}: string
  var testEventResult {.threadvar.}: string
  var testQueue1Result = 0
  var testQueue2Result = 0
  var testQueue3Result = 0

  proc testLock(n: int, lock: AsyncLock) {.async.} =
    await lock.acquire()
    testLockResult = testLockResult & $n
    lock.release()

  proc test1(): string =
    var lock = newAsyncLock()
    waitFor lock.acquire()
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

  proc testFlag(): Future[bool] {.async.} =
    var lock = newAsyncLock()
    var futs: array[4, Future[void]]
    futs[0] = lock.acquire()
    futs[1] = lock.acquire()
    futs[2] = lock.acquire()
    futs[3] = lock.acquire()

    proc checkFlags(b0, b1, b2, b3, b4: bool): bool =
      (lock.locked == b0) and
        (futs[0].finished == b1) and (futs[1].finished == b2) and
        (futs[2].finished == b3) and (futs[3].finished == b4)

    if not(checkFlags(true, true, false, false ,false)):
      return false

    lock.release()
    if not(checkFlags(true, true, false, false, false)):
      return false
    await sleepAsync(10.milliseconds)
    if not(checkFlags(true, true, true, false, false)):
      return false

    lock.release()
    if not(checkFlags(true, true, true, false, false)):
      return false
    await sleepAsync(10.milliseconds)
    if not(checkFlags(true, true, true, true, false)):
      return false

    lock.release()
    if not(checkFlags(true, true, true, true, false)):
      return false
    await sleepAsync(10.milliseconds)
    if not(checkFlags(true, true, true, true, true)):
      return false

    lock.release()
    if not(checkFlags(false, true, true, true, true)):
      return false
    await sleepAsync(10.milliseconds)
    if not(checkFlags(false, true, true, true, true)):
      return false

    return true

  proc testNoAcquiredRelease(): Future[bool] {.async.} =
    var lock = newAsyncLock()
    var res = false
    try:
      lock.release()
    except AsyncLockError:
      res = true
    return res

  proc testDoubleRelease(): Future[bool] {.async.} =
    var lock = newAsyncLock()
    var fut0 = lock.acquire()
    var fut1 = lock.acquire()
    var res = false
    asyncSpawn fut0
    asyncSpawn fut1
    lock.release()
    try:
      lock.release()
    except AsyncLockError:
      res = true
    return res

  proc testBehaviorLock(n1, n2, n3: Duration): Future[seq[int]] {.async.} =
    var stripe: seq[int]

    proc task(lock: AsyncLock, n: int, timeout: Duration) {.async.} =
      await lock.acquire()
      stripe.add(n * 10)
      await sleepAsync(timeout)
      lock.release()
      await lock.acquire()
      stripe.add(n * 10 + 1)
      await sleepAsync(timeout)
      lock.release()

    var lock = newAsyncLock()
    var fut1 = task(lock, 1, n1)
    var fut2 = task(lock, 2, n2)
    var fut3 = task(lock, 3, n3)
    await allFutures(fut1, fut2, fut3)
    result = stripe

  proc testCancelLock(n1, n2, n3: Duration,
                      cancelIndex: int): Future[seq[int]] {.async.} =
    var stripe: seq[int]

    proc task(lock: AsyncLock, n: int, timeout: Duration) {.async.} =
      await lock.acquire()
      stripe.add(n * 10)
      await sleepAsync(timeout)
      lock.release()

      await lock.acquire()
      stripe.add(n * 10 + 1)
      await sleepAsync(timeout)
      lock.release()

    var lock = newAsyncLock()
    var fut1 = task(lock, 1, n1)
    var fut2 = task(lock, 2, n2)
    var fut3 = task(lock, 3, n3)
    if cancelIndex == 2:
      fut2.cancel()
    else:
      fut3.cancel()
    await allFutures(fut1, fut2, fut3)
    result = stripe


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
    ## There must be exactly 1 poll() call
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
    waitFor(allFutures(task3(queue), task4(queue)))
    result = testQueue2Result

  proc task51(aq: AsyncQueue[int]) {.async.} =
    var item1 = await aq.popFirst()
    var item2 = await aq.popLast()
    var item3 = await aq.get()
    testQueue3Result = item1 - item2 + item3

  proc task52(aq: AsyncQueue[int]) {.async.} =
    await aq.put(100)
    await aq.addLast(1000)
    await aq.addFirst(2000)

  proc test5(): int =
    var queue = newAsyncQueue[int](3)
    discard task51(queue)
    discard task52(queue)
    poll()
    poll()
    result = testQueue3Result

  proc test6(): bool =
    var queue = newAsyncQueue[int]()
    queue.putNoWait(1)
    queue.putNoWait(2)
    queue.putNoWait(3)
    queue.putNoWait(4)
    queue.putNoWait(5)
    queue.clear()
    result = (len(queue) == 0)

  proc test7(): bool =
    var queue = newAsyncQueue[int]()
    var arr1 = @[1, 2, 3, 4, 5]
    var arr2 = @[2, 2, 2, 2, 2]
    var arr3 = @[1, 2, 3, 4, 5]
    queue.putNoWait(1)
    queue.putNoWait(2)
    queue.putNoWait(3)
    queue.putNoWait(4)
    queue.putNoWait(5)
    var index = 0
    for item in queue.items():
      result = (item == arr1[index])
      inc(index)

    if not result: return

    queue[0] = 2

    result = (queue[0] == 2)

    if not result: return

    for item in queue.mitems():
      item = 2

    index = 0
    for item in queue.items():
      result = (item == arr2[index])
      inc(index)

    if not result: return

    queue[0] = 1
    queue[1] = 2
    queue[2] = 3
    queue[3] = 4
    queue[^1] = 5

    for i, item in queue.pairs():
      result = (item == arr3[i])

  proc test8(): bool =
    var q0 = newAsyncQueue[int]()
    q0.putNoWait(1)
    q0.putNoWait(2)
    q0.putNoWait(3)
    q0.putNoWait(4)
    q0.putNoWait(5)
    result = ($q0 == "[1, 2, 3, 4, 5]")
    if not result: return

    var q1 = newAsyncQueue[string]()
    q1.putNoWait("1")
    q1.putNoWait("2")
    q1.putNoWait("3")
    q1.putNoWait("4")
    q1.putNoWait("5")
    result = ($q1 == "[\"1\", \"2\", \"3\", \"4\", \"5\"]")

  proc test9(): bool =
    var q = newAsyncQueue[int]()
    q.putNoWait(1)
    q.putNoWait(2)
    q.putNoWait(3)
    q.putNoWait(4)
    q.putNoWait(5)
    result = (5 in q and not(6 in q))

  test "AsyncLock() behavior test":
    check:
      test1() == "0123456789"
      waitFor(testBehaviorLock(10.milliseconds,
                               20.milliseconds,
                               50.milliseconds)) == @[10, 20, 30, 11, 21, 31]
      waitFor(testBehaviorLock(50.milliseconds,
                               20.milliseconds,
                               10.milliseconds)) == @[10, 20, 30, 11, 21, 31]
  test "AsyncLock() cancellation test":
    check:
      waitFor(testCancelLock(10.milliseconds,
                             20.milliseconds,
                             50.milliseconds, 2)) == @[10, 30, 11, 31]
      waitFor(testCancelLock(50.milliseconds,
                             20.milliseconds,
                             10.milliseconds, 3)) == @[10, 20, 11, 21]
  test "AsyncLock() flag consistency test":
    check waitFor(testFlag()) == true
  test "AsyncLock() double release test":
    check waitFor(testDoubleRelease()) == true
  test "AsyncLock() non-acquired release test":
    check waitFor(testNoAcquiredRelease()) == true
  test "AsyncEvent() behavior test":
    check test2() == "0123456789"
  test "AsyncQueue() behavior test":
    check test3() == 3000
  test "AsyncQueue() many iterations test":
    check test4() == 0
  test "AsyncQueue() addLast/addFirst/popLast/popFirst test":
    check test5() == 1100
  test "AsyncQueue() clear test":
    check test6() == true
  test "AsyncQueue() iterators/assignments test":
    check test7() == true
  test "AsyncQueue() representation test":
    check test8() == true
  test "AsyncQueue() contains test":
    check test9() == true
  test "AsyncEventBus() awaitable primitives test":
    const TestsCount = 10
    var bus = newAsyncEventBus()
    var flag = ""

    proc waiter(bus: AsyncEventBus) {.async.} =
      for i in 0 ..< TestsCount:
        let payload = await bus.waitEvent(string, "event")
        flag = flag & payload

    proc sender(bus: AsyncEventBus) {.async.} =
      for i in 0 ..< (TestsCount + (TestsCount div 2)):
        await bus.emitWait("event", $i)

    waitFor allFutures(waiter(bus), sender(bus))
    check flag == "0123456789"
  test "AsyncEventBus() waiters test":
    var bus = newAsyncEventBus()
    let fut11 = bus.waitEvent(int, "event")
    let fut12 = bus.waitEvent(int, "event")
    let fut13 = bus.waitEvent(int, "event")
    let fut21 = bus.waitEvent(string, "event")
    let fut22 = bus.waitEvent(string, "event")
    let fut23 = bus.waitEvent(string, "event")
    bus.emit("event", 65535)
    check:
      fut11.done() == true
      fut12.done() == true
      fut13.done() == true
      fut21.finished() == false
      fut22.finished() == false
      fut23.finished() == false
    bus.emit("event", "data")
    check:
      fut21.done() == true
      fut22.done() == true
      fut23.done() == true
  test "AsyncEventBus() subscribers test":
    const TestsCount = 10
    var bus = newAsyncEventBus()
    var flagInt = 0
    var flagStr = ""
    proc eventIntCallback(bus: AsyncEventBus,
                          payload: EventPayload[int]) {.async.} =
      flagInt = payload.get()
    proc eventStrCallback(bus: AsyncEventBus,
                          payload: EventPayload[string]) {.async.} =
      flagStr = payload.get()

    let key1 = bus.subscribe("event", eventIntCallback)
    let key2 = bus.subscribe("event", eventStrCallback)

    proc test() {.async.} =
      check:
        flagInt == 0
        flagStr == ""
      for i in 0 ..< TestsCount:
        await bus.emitWait("event", i)
        check:
          flagInt == i
          flagStr == ""
      flagInt = 0
      for i in 0 ..< TestsCount:
        await bus.emitWait("event", $i)
        check:
          flagInt == 0
          flagStr == $i
      flagInt = 0
      flagStr = ""
      bus.unsubscribe(key1)
      for i in 0 ..< TestsCount:
        await bus.emitWait("event", i)
        check:
          flagInt == 0
          flagStr == ""
      flagInt = 0
      flagStr = ""
      bus.unsubscribe(key2)
      for i in 0 ..< TestsCount:
        await bus.emitWait("event", $i)
        check:
          flagInt == 0
          flagStr == ""
    waitFor(test())
  test "AsyncEventBus() waiters for all events test":
    var bus = newAsyncEventBus()
    let fut11 = bus.waitAllEvents()
    let fut12 = bus.waitAllEvents()
    bus.emit("intevent", 65535)
    check:
      fut11.done() == true
      fut12.done() == true
    let event11 = fut11.read()
    let event12 = fut12.read()
    check:
      event11.event() == "intevent"
      event12.event() == "intevent"
      event11.get(int) == 65535
      event12.get(int) == 65535

    let fut21 = bus.waitAllEvents()
    let fut22 = bus.waitAllEvents()
    bus.emit("strevent", "hello")
    check:
      fut21.done() == true
      fut22.done() == true
    let event21 = fut21.read()
    let event22 = fut22.read()
    check:
      event21.event() == "strevent"
      event22.event() == "strevent"
      event21.get(string) == "hello"
      event22.get(string) == "hello"
  test "AsyncEventBus() subscribers to all events test":
    const TestsCount = 10
    var
      bus = newAsyncEventBus()
      flagInt = 0
      flagStr = ""

    proc eventCallback(bus: AsyncEventBus, event: AwaitableEvent) {.async.} =
      case event.event()
      of "event1":
        flagStr = ""
        flagInt = event.get(int)
      of "event2":
        flagInt = 0
        flagStr = event.get(string)
      else:
        flagInt = -1
        flagStr = "error"

    proc test() {.async.} =
      let key = bus.subscribeAll(eventCallback)
      for i in 0 ..< TestsCount:
        await bus.emitWait("event1", i)
        check:
          flagStr == ""
          flagInt == i
        await bus.emitWait("event2", $i)
        check:
          flagStr == $i
          flagInt == 0

      bus.unsubscribe(key)

      flagInt = high(int)
      flagStr = "empty"
      for i in 0 ..< TestsCount:
        await bus.emitWait("event1", i)
        check:
          flagStr == "empty"
          flagInt == high(int)
        await bus.emitWait("event2", $i)
        check:
          flagStr == "empty"
          flagInt == high(int)

    waitFor(test())

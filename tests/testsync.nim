#                Chronos Test Suite
#            (c) Copyright 2018-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)
import unittest2
import ../chronos, ../chronos/unittest2/asynctests
import std/sequtils

{.used.}

suite "Asynchronous sync primitives test suite":
  const testsCount = 1000
  const queueSize = 10

  test "AsyncLock() behavior test":
    let lock = newAsyncLock()
    var lockResult: string

    proc testLock(n: int, lock: AsyncLock) {.async.} =
      await lock.acquire()
      lockResult.add $n
      lock.release()

    waitFor lock.acquire()
    for i in 0 ..< 10:
      discard testLock(i, lock)

    lock.release()
    ## There must be exactly 20 poll() calls
    for i in 0..<20:
      poll()
    check lockResult == "0123456789"

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

      let lock = newAsyncLock()
      var fut1 = task(lock, 1, n1)
      var fut2 = task(lock, 2, n2)
      var fut3 = task(lock, 3, n3)
      await allFutures(fut1, fut2, fut3)
      result = stripe

    check waitFor(testBehaviorLock(10.milliseconds, 20.milliseconds, 50.milliseconds)) ==
      @[10, 20, 30, 11, 21, 31]
    check waitFor(testBehaviorLock(50.milliseconds, 20.milliseconds, 10.milliseconds)) ==
      @[10, 20, 30, 11, 21, 31]

  asyncTest "AsyncLock() cancellation test":
    proc testCancelLock(
        n1, n2, n3: Duration, cancelIndex: int
    ): Future[seq[int]] {.async.} =
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

      let lock = newAsyncLock()
      var fut1 = task(lock, 1, n1)
      var fut2 = task(lock, 2, n2)
      var fut3 = task(lock, 3, n3)
      if cancelIndex == 2:
        fut2.cancelSoon()
      else:
        fut3.cancelSoon()
      await allFutures(fut1, fut2, fut3)
      result = stripe

    check (await testCancelLock(10.milliseconds, 20.milliseconds, 50.milliseconds, 2)) ==
      @[10, 30, 11, 31]
    check (await testCancelLock(50.milliseconds, 20.milliseconds, 10.milliseconds, 3)) ==
      @[10, 20, 11, 21]

  asyncTest "AsyncLock() flag consistency test":
    let lock = newAsyncLock()
    let futs = [lock.acquire(), lock.acquire(), lock.acquire(), lock.acquire()]

    check:
      lock.locked
      futs[0].finished
      not futs[1].finished
      not futs[2].finished
      not futs[3].finished

    lock.release()
    check:
      lock.locked
      futs[0].finished
      not futs[1].finished
      not futs[2].finished
      not futs[3].finished
    await sleepAsync(10.milliseconds)
    check:
      lock.locked
      futs[0].finished
      futs[1].finished
      not futs[2].finished
      not futs[3].finished

    lock.release()
    check:
      lock.locked
      futs[0].finished
      futs[1].finished
      not futs[2].finished
      not futs[3].finished
    await sleepAsync(10.milliseconds)
    check:
      lock.locked
      futs[0].finished
      futs[1].finished
      futs[2].finished
      not futs[3].finished

    lock.release()
    check:
      lock.locked
      futs[0].finished
      futs[1].finished
      futs[2].finished
      not futs[3].finished
    await sleepAsync(10.milliseconds)
    check:
      lock.locked
      futs[0].finished
      futs[1].finished
      futs[2].finished
      futs[3].finished

    lock.release()
    check:
      not lock.locked
      futs[0].finished
      futs[1].finished
      futs[2].finished
      futs[3].finished
    await sleepAsync(10.milliseconds)
    check:
      not lock.locked
      futs[0].finished
      futs[1].finished
      futs[2].finished
      futs[3].finished

  test "AsyncLock() double release test":
    let lock = newAsyncLock()
    waitFor lock.acquire()
    lock.release()
    expect AsyncLockError:
      lock.release()

  test "AsyncLock() non-acquired release test":
    let lock = newAsyncLock()
    expect AsyncLockError:
      lock.release()

  test "AsyncEvent() behavior test":
    var event = newAsyncEvent()
    var eventResult = new(string)

    proc testEvent(n: int, ev: AsyncEvent, res: ref string) {.async.} =
      await ev.wait()
      res[] = res[] & $n

    event.clear()
    for i in 0 .. 9:
      discard testEvent(i, event, eventResult)
    event.fire()
    ## There must be exactly 1 poll() call
    poll()
    check eventResult[] == "0123456789"

  test "AsyncQueue() behavior test":
    var queue = newAsyncQueue[int](1)
    var queueResult = new(int)

    proc task1(aq: AsyncQueue[int], res: ref int) {.async.} =
      var item1 = await aq.get()
      var item2 = await aq.get()
      res[] = item1 + item2

    proc task2(aq: AsyncQueue[int]) {.async.} =
      await aq.put(1000)
      await aq.put(2000)

    discard task1(queue, queueResult)
    discard task2(queue)
    ## There must be exactly 2 poll() calls
    poll()
    poll()
    check queueResult[] == 3000

  asyncTest "AsyncQueue() many iterations test":
    var queue = newAsyncQueue[int](queueSize)
    var sum = new(int)

    proc task3(aq: AsyncQueue[int], res: ref int) {.async.} =
      for i in 1 .. testsCount:
        res[] -= await aq.get()

    proc task4(aq: AsyncQueue[int], res: ref int) {.async.} =
      for i in 1 .. testsCount:
        await aq.put(i)
        res[] += i

    var fut3 = task3(queue, sum)
    var fut4 = task4(queue, sum)
    await allFutures(fut3, fut4)
    check sum[] == 0

  test "AsyncQueue() addLast/addFirst/popLast/popFirst test":
    var queue = newAsyncQueue[int](3)
    var queueResult = new(int)

    proc task51(aq: AsyncQueue[int], res: ref int) {.async.} =
      var item1 = await aq.popFirst()
      var item2 = await aq.popLast()
      var item3 = await aq.get()
      res[] = item1 - item2 + item3

    proc task52(aq: AsyncQueue[int]) {.async.} =
      await aq.put(100)
      await aq.addLast(1000)
      await aq.addFirst(2000)

    discard task51(queue, queueResult)
    discard task52(queue)
    poll()
    poll()
    check queueResult[] == 1100

  test "AsyncQueue() clear test":
    var queue = newAsyncQueue[int]()
    queue.putNoWait(1)
    queue.putNoWait(2)
    queue.putNoWait(3)
    queue.putNoWait(4)
    queue.putNoWait(5)
    queue.clear()
    check len(queue) == 0

  test "AsyncQueue() iterators/assignments test":
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
      check item == arr1[index]
      inc(index)

    queue[0] = 2
    check queue[0] == 2

    for item in queue.mitems():
      item = 2

    index = 0
    for item in queue.items():
      check item == arr2[index]
      inc(index)

    queue[0] = 1
    queue[1] = 2
    queue[2] = 3
    queue[3] = 4
    queue[^1] = 5

    for i, item in queue.pairs():
      check item == arr3[i]

  test "AsyncQueue() representation test":
    var q0 = newAsyncQueue[int]()
    q0.putNoWait(1)
    q0.putNoWait(2)
    q0.putNoWait(3)
    q0.putNoWait(4)
    q0.putNoWait(5)
    check $q0 == "[1, 2, 3, 4, 5]"

    var q1 = newAsyncQueue[string]()
    q1.putNoWait("1")
    q1.putNoWait("2")
    q1.putNoWait("3")
    q1.putNoWait("4")
    q1.putNoWait("5")
    check $q1 == "[\"1\", \"2\", \"3\", \"4\", \"5\"]"

  test "AsyncQueue() contains test":
    var q = newAsyncQueue[int]()
    q.putNoWait(1)
    q.putNoWait(2)
    q.putNoWait(3)
    q.putNoWait(4)
    q.putNoWait(5)
    check:
      5 in q
      not (6 in q)

  test "AsyncEventQueue() behavior test":
    let eventQueue = newAsyncEventQueue[int]()
    let key = eventQueue.register()
    eventQueue.emit(100)
    eventQueue.emit(200)
    eventQueue.emit(300)

    let dataFut1 = eventQueue.waitEvents(key)
    check:
      dataFut1.finished() == true
      dataFut1.read() == @[100, 200, 300]

    let dataFut2 = eventQueue.waitEvents(key)
    check:
      dataFut2.finished() == false
    eventQueue.emit(400)
    eventQueue.emit(500)
    poll()
    check:
      dataFut2.finished() == true
      dataFut2.read() == @[400, 500]

    waitFor eventQueue.closeWait()

  test "AsyncEventQueue() concurrency test":
    let eventQueue = newAsyncEventQueue[int]()
    let key0 = eventQueue.register()
    let key1 = eventQueue.register()
    eventQueue.emit(100)
    let key2 = eventQueue.register()
    eventQueue.emit(200)
    eventQueue.emit(300)
    let key3 = eventQueue.register()
    eventQueue.emit(400)
    eventQueue.emit(500)
    eventQueue.emit(600)
    let key4 = eventQueue.register()
    eventQueue.emit(700)
    eventQueue.emit(800)
    eventQueue.emit(900)
    eventQueue.emit(1000)
    let key5 = eventQueue.register()
    let key6 = eventQueue.register()

    let dataFut1 = eventQueue.waitEvents(key1)
    let dataFut2 = eventQueue.waitEvents(key2)
    let dataFut3 = eventQueue.waitEvents(key3)
    let dataFut4 = eventQueue.waitEvents(key4)
    let dataFut5 = eventQueue.waitEvents(key5)
    let dataFut6 = eventQueue.waitEvents(key6)
    check:
      dataFut1.finished() == true
      dataFut1.read() == @[100, 200, 300, 400, 500, 600, 700, 800, 900, 1000]
      dataFut2.finished() == true
      dataFut2.read() == @[200, 300, 400, 500, 600, 700, 800, 900, 1000]
      dataFut3.finished() == true
      dataFut3.read() == @[400, 500, 600, 700, 800, 900, 1000]
      dataFut4.finished() == true
      dataFut4.read() == @[700, 800, 900, 1000]
      dataFut5.finished() == false
      dataFut6.finished() == false

    eventQueue.emit(2000)
    poll()
    let dataFut0 = eventQueue.waitEvents(key0)
    check:
      dataFut5.finished() == true
      dataFut5.read() == @[2000]
      dataFut6.finished() == true
      dataFut6.read() == @[2000]
      dataFut0.finished() == true
      dataFut0.read() == @[100, 200, 300, 400, 500, 600, 700, 800, 900, 1000, 2000]

    waitFor eventQueue.closeWait()

  test "AsyncEventQueue() specific number test":
    let eventQueue = newAsyncEventQueue[int]()
    let key = eventQueue.register()

    let dataFut1 = eventQueue.waitEvents(key, 1)
    eventQueue.emit(100)
    eventQueue.emit(200)
    eventQueue.emit(300)
    eventQueue.emit(400)
    check dataFut1.finished() == false
    poll()
    check:
      dataFut1.finished() == true
      dataFut1.read() == @[100]

    let dataFut2 = eventQueue.waitEvents(key, 2)
    check:
      dataFut2.finished() == true
      dataFut2.read() == @[200, 300]

    let dataFut3 = eventQueue.waitEvents(key, 5)
    check dataFut3.finished() == false
    eventQueue.emit(500)
    eventQueue.emit(600)
    eventQueue.emit(700)
    eventQueue.emit(800)
    check dataFut3.finished() == false
    poll()
    check:
      dataFut3.finished() == true
      dataFut3.read() == @[400, 500, 600, 700, 800]

    let dataFut4 = eventQueue.waitEvents(key, -1)
    check dataFut4.finished() == false
    eventQueue.emit(900)
    eventQueue.emit(1000)
    eventQueue.emit(1100)
    eventQueue.emit(1200)
    eventQueue.emit(1300)
    eventQueue.emit(1400)
    eventQueue.emit(1500)
    eventQueue.emit(1600)
    check dataFut4.finished() == false
    poll()
    check:
      dataFut4.finished() == true
      dataFut4.read() == @[900, 1000, 1100, 1200, 1300, 1400, 1500, 1600]

    waitFor eventQueue.closeWait()

  test "AsyncEventQueue() register()/unregister() test":
    var emptySeq: seq[int]
    let eventQueue = newAsyncEventQueue[int]()
    let key1 = eventQueue.register()

    let dataFut1 = eventQueue.waitEvents(key1, 1)
    check dataFut1.finished() == false
    eventQueue.unregister(key1)
    check dataFut1.finished() == false
    poll()
    check:
      dataFut1.finished() == true
      dataFut1.read() == emptySeq

    let key2 = eventQueue.register()
    let dataFut2 = eventQueue.waitEvents(key2, 5)
    check dataFut2.finished() == false
    eventQueue.emit(100)
    eventQueue.emit(200)
    eventQueue.emit(300)
    eventQueue.emit(400)
    eventQueue.emit(500)
    check dataFut2.finished() == false
    eventQueue.unregister(key2)
    poll()
    check:
      dataFut2.finished() == true
      dataFut2.read() == emptySeq

    let key3 = eventQueue.register()
    let dataFut3 = eventQueue.waitEvents(key3, 5)
    check dataFut3.finished() == false
    eventQueue.emit(100)
    eventQueue.emit(200)
    eventQueue.emit(300)
    check dataFut3.finished() == false
    poll()
    eventQueue.unregister(key3)
    eventQueue.emit(400)
    check dataFut3.finished() == false
    poll()
    check:
      dataFut3.finished() == true
      dataFut3.read() == @[100, 200, 300]

    waitFor eventQueue.closeWait()

  test "AsyncEventQueue() garbage collection test":
    let eventQueue = newAsyncEventQueue[int]()
    let key1 = eventQueue.register()
    check len(eventQueue) == 0
    eventQueue.emit(100)
    eventQueue.emit(200)
    eventQueue.emit(300)
    check len(eventQueue) == 3
    let key2 = eventQueue.register()
    eventQueue.emit(400)
    eventQueue.emit(500)
    eventQueue.emit(600)
    eventQueue.emit(700)
    check len(eventQueue) == 7
    let key3 = eventQueue.register()
    eventQueue.emit(800)
    eventQueue.emit(900)
    eventQueue.emit(1000)
    eventQueue.emit(1100)
    eventQueue.emit(1200)
    check len(eventQueue) == 12
    let dataFut1 = eventQueue.waitEvents(key1)
    check:
      dataFut1.finished() == true
      dataFut1.read() == @[
        100, 200, 300, 400, 500, 600, 700, 800, 900, 1000, 1100, 1200
      ]
      len(eventQueue) == 9

    let dataFut3 = eventQueue.waitEvents(key3)
    check:
      dataFut3.finished() == true
      dataFut3.read() == @[800, 900, 1000, 1100, 1200]
      len(eventQueue) == 9

    let dataFut2 = eventQueue.waitEvents(key2)
    check:
      dataFut2.finished() == true
      dataFut2.read() == @[400, 500, 600, 700, 800, 900, 1000, 1100, 1200]
      len(eventQueue) == 0

    waitFor eventQueue.closeWait()

  asyncTest "AsyncEventQueue() 1,000,000 of events to 10 clients test":
    let eventQueue = newAsyncEventQueue[int]()
    var keys = @[
      eventQueue.register(),
      eventQueue.register(),
      eventQueue.register(),
      eventQueue.register(),
      eventQueue.register(),
      eventQueue.register(),
      eventQueue.register(),
      eventQueue.register(),
      eventQueue.register(),
      eventQueue.register(),
    ]

    proc clientTask(
        queue: AsyncEventQueue[int], key: EventQueueKey
    ): Future[seq[int]] {.async.} =
      var events: seq[int]
      while true:
        let res = await queue.waitEvents(key)
        if len(res) == 0:
          break
        events.add(res)
      queue.unregister(key)
      return events

    var futs = @[
      clientTask(eventQueue, keys[0]),
      clientTask(eventQueue, keys[1]),
      clientTask(eventQueue, keys[2]),
      clientTask(eventQueue, keys[3]),
      clientTask(eventQueue, keys[4]),
      clientTask(eventQueue, keys[5]),
      clientTask(eventQueue, keys[6]),
      clientTask(eventQueue, keys[7]),
      clientTask(eventQueue, keys[8]),
      clientTask(eventQueue, keys[9]),
    ]

    for i in 1 .. 1_000_000:
      if (i mod 1000) == 0:
        # Give some CPU for clients.
        await sleepAsync(0.milliseconds)
      eventQueue.emit(i)

    await eventQueue.closeWait()

    await allFutures(futs)
    for index in 0 ..< len(futs):
      let fut = futs[index]
      check fut.finished() == true
      let data = fut.read()
      var counter = 1
      for item in data:
        check item == counter
        inc(counter)
      futs[index] = nil

  asyncTest "AsyncEventQueue() one consumer limits test":
    let eventQueue = newAsyncEventQueue[int](4)
    check len(eventQueue) == 0
    eventQueue.emit(100)
    eventQueue.emit(200)
    eventQueue.emit(300)
    eventQueue.emit(400)
    # There no consumers, so all the items should be discarded
    check len(eventQueue) == 0
    let key1 = eventQueue.register()
    check len(eventQueue) == 0
    eventQueue.emit(500)
    eventQueue.emit(600)
    eventQueue.emit(700)
    eventQueue.emit(800)
    # So exact `limit` number of items added, consumer should receive all of
    # them.
    check len(eventQueue) == 4
    let dataFut1 = eventQueue.waitEvents(key1)
    check:
      dataFut1.finished() == true
      dataFut1.read() == @[500, 600, 700, 800]
      len(eventQueue) == 0

    eventQueue.emit(900)
    eventQueue.emit(1000)
    eventQueue.emit(1100)
    eventQueue.emit(1200)
    check len(eventQueue) == 4
    # Overfilling queue
    eventQueue.emit(1300)
    # Because overfill for single consumer happend, whole queue should become
    # empty.
    check len(eventQueue) == 0
    eventQueue.emit(1400)
    eventQueue.emit(1500)
    eventQueue.emit(1600)
    eventQueue.emit(1700)
    eventQueue.emit(1800)
    check len(eventQueue) == 0
    let errorFut1 = eventQueue.waitEvents(key1)
    check errorFut1.finished() == true
    expect AsyncEventQueueFullError:
      discard await errorFut1
    # There should be no items because consumer was overflowed.
    check len(eventQueue) == 0
    eventQueue.unregister(key1)
    # All items should be garbage collected after unregister.
    check len(eventQueue) == 0
    await eventQueue.closeWait()

  asyncTest "AsyncEventQueue() many consumers limits test":
    let eventQueue = newAsyncEventQueue[int](4)
    block:
      let key1 = eventQueue.register()
      eventQueue.emit(100)
      check len(eventQueue) == 1
      let key2 = eventQueue.register()
      eventQueue.emit(200)
      check len(eventQueue) == 2
      let key3 = eventQueue.register()
      eventQueue.emit(300)
      check len(eventQueue) == 3
      let key4 = eventQueue.register()
      eventQueue.emit(400)
      check len(eventQueue) == 4
      let key5 = eventQueue.register()
      eventQueue.emit(500)
      # At this point consumer with `key1` is overfilled, so after `emit()`
      # queue length should be decreased by one item.
      # So queue should look like this: [200, 300, 400, 500]
      check len(eventQueue) == 4
      eventQueue.emit(600)
      # At this point consumers with `key2` is overfilled, so after `emit()`
      # queue length should be decreased by one item.
      # So queue should look like this: [300, 400, 500, 600]
      check len(eventQueue) == 4
      eventQueue.emit(700)
      # At this point consumers with `key3` is overfilled, so after `emit()`
      # queue length should be decreased by one item.
      # So queue should look like this: [400, 500, 600, 700]
      check len(eventQueue) == 4
      eventQueue.emit(800)
      # At this point consumers with `key4` is overfilled, so after `emit()`
      # queue length should be decreased by one item.
      # So queue should look like this: [500, 600, 700, 800]
      check len(eventQueue) == 4
      # Consumer with key5 is not overfilled.
      let dataFut5 = eventQueue.waitEvents(key5)
      check:
        dataFut5.finished() == true
        dataFut5.read() == @[500, 600, 700, 800]
      # No more items should be left because all other consumers are overfilled.
      check len(eventQueue) == 0
      eventQueue.unregister(key5)
      check len(eventQueue) == 0

      let dataFut2 = eventQueue.waitEvents(key2)
      check dataFut2.finished() == true
      expect AsyncEventQueueFullError:
        discard dataFut2.read()
      check len(eventQueue) == 0
      eventQueue.unregister(key2)
      check len(eventQueue) == 0

      let dataFut4 = eventQueue.waitEvents(key4)
      check dataFut4.finished() == true
      expect AsyncEventQueueFullError:
        discard dataFut4.read()
      check len(eventQueue) == 0
      eventQueue.unregister(key4)
      check len(eventQueue) == 0

      let dataFut3 = eventQueue.waitEvents(key3)
      check dataFut3.finished() == true
      expect AsyncEventQueueFullError:
        discard dataFut3.read()
      check len(eventQueue) == 0
      eventQueue.unregister(key3)
      check len(eventQueue) == 0

      let dataFut1 = eventQueue.waitEvents(key1)
      check dataFut1.finished() == true
      expect AsyncEventQueueFullError:
        discard dataFut1.read()
      check len(eventQueue) == 0
      eventQueue.unregister(key1)
      check len(eventQueue) == 0

    block:
      let key1 = eventQueue.register()
      eventQueue.emit(100)
      check len(eventQueue) == 1
      let key2 = eventQueue.register()
      eventQueue.emit(200)
      check len(eventQueue) == 2
      let key3 = eventQueue.register()
      eventQueue.emit(300)
      check len(eventQueue) == 3
      let key4 = eventQueue.register()
      eventQueue.emit(400)
      check len(eventQueue) == 4
      let key5 = eventQueue.register()
      eventQueue.emit(500)
      # At this point consumer with `key1` is overfilled, so after `emit()`
      # queue length should be decreased by one item.
      # So queue should look like this: [200, 300, 400, 500]
      check len(eventQueue) == 4
      eventQueue.emit(600)
      # At this point consumer with `key2` is overfilled, so after `emit()`
      # queue length should be decreased by one item.
      # So queue should look like this: [300, 400, 500, 600]
      check len(eventQueue) == 4
      eventQueue.emit(700)
      # At this point consumer with `key3` is overfilled, so after `emit()`
      # queue length should be decreased by one item.
      # So queue should look like this: [400, 500, 600, 700]
      check len(eventQueue) == 4
      eventQueue.emit(800)
      # At this point consumers with `key4` is overfilled, so after `emit()`
      # queue length should be decreased by one item.
      # So queue should look like this: [500, 600, 700, 800]
      check len(eventQueue) == 4
      eventQueue.emit(900)
      # At this point all consumers are overfilled, so after `emit()`
      # queue length should become 0.
      check len(eventQueue) == 0
      eventQueue.emit(1000)
      eventQueue.emit(1100)
      eventQueue.emit(1200)
      eventQueue.emit(1300)
      eventQueue.emit(1400)
      eventQueue.emit(1500)
      eventQueue.emit(1600)
      eventQueue.emit(1700)
      eventQueue.emit(1800)
      eventQueue.emit(1900)
      # No more events should be accepted.
      check len(eventQueue) == 0

      let dataFut1 = eventQueue.waitEvents(key1)
      check dataFut1.finished() == true
      expect AsyncEventQueueFullError:
        discard dataFut1.read()
      check len(eventQueue) == 0
      eventQueue.unregister(key1)
      check len(eventQueue) == 0

      let dataFut2 = eventQueue.waitEvents(key2)
      check dataFut2.finished() == true
      expect AsyncEventQueueFullError:
        discard dataFut2.read()
      check len(eventQueue) == 0
      eventQueue.unregister(key2)
      check len(eventQueue) == 0

      let dataFut3 = eventQueue.waitEvents(key3)
      check dataFut3.finished() == true
      expect AsyncEventQueueFullError:
        discard dataFut3.read()
      check len(eventQueue) == 0
      eventQueue.unregister(key3)
      check len(eventQueue) == 0

      let dataFut4 = eventQueue.waitEvents(key4)
      check dataFut4.finished() == true
      expect AsyncEventQueueFullError:
        discard dataFut4.read()
      check len(eventQueue) == 0
      eventQueue.unregister(key4)
      check len(eventQueue) == 0

      let dataFut5 = eventQueue.waitEvents(key5)
      check dataFut5.finished() == true
      expect AsyncEventQueueFullError:
        discard dataFut5.read()
      check len(eventQueue) == 0
      eventQueue.unregister(key5)
      check len(eventQueue) == 0
    await eventQueue.closeWait()

  asyncTest "AsyncEventQueue() slow and fast consumer test":
    let
      eventQueue = newAsyncEventQueue[int](1)
      fastConsumer = eventQueue.register()
      slowConsumer = eventQueue.register()
      slowFut = eventQueue.waitEvents(slowConsumer)

    for i in 0 ..< 1000:
      eventQueue.emit(i)
      let fastData {.used.} = await eventQueue.waitEvents(fastConsumer)

    check len(eventQueue) == 0
    await allFutures(slowFut)
    check len(eventQueue) == 0
    expect AsyncEventQueueFullError:
      discard slowFut.read()

    check len(eventQueue) == 0
    eventQueue.unregister(fastConsumer)
    check len(eventQueue) == 0
    eventQueue.unregister(slowConsumer)
    check len(eventQueue) == 0
    await eventQueue.closeWait()

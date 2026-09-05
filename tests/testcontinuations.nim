#                Chronos Test Suite
#            (c) Copyright 2026-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)
import unittest2
import ../chronos, ../chronos/config

{.push raises: [], gcsafe.}
{.used.}

suite "Continuation scheduling test suite":
  type Trace = seq[string]

  proc runTest(
      cb: proc (
          trace: ptr Trace
        ): Future[void].Raising([CancelledError]) {.raises: [], gcsafe.}
  ): Trace =
    var trace: Trace
    waitFor noCancel cb(addr trace)
    trace

  proc competitorCb(udata: pointer) =
    cast[ptr Trace](udata)[].add "competitor"

  proc observerCb(udata: pointer) =
    cast[ptr Trace](udata)[].add "observer"

  proc observerCb2(udata: pointer) =
    cast[ptr Trace](udata)[].add "observer2"

  proc testValueReturn(): Trace =
    proc producer(
        trace: ptr Trace): Future[int] {.async: (raises: [CancelledError]).} =
      await sleepAsync(ZeroDuration)
      callSoon(competitorCb, trace)
      trace[].add "producer returns"
      42

    proc consumer(trace: ptr Trace) {.async: (raises: [CancelledError]).} =
      let v = await producer(trace)
      trace[].add "consumer returns " & $v

    runTest consumer

  proc testFailingReturn(): Trace =
    proc producer(
        trace: ptr Trace
    ): Future[int] {.async: (raises: [CancelledError, ValueError]).} =
      await sleepAsync(ZeroDuration)
      callSoon(competitorCb, trace)
      trace[].add "producer raising"
      raise newException(ValueError, "err")

    proc consumer(trace: ptr Trace) {.async: (raises: [CancelledError]).} =
      try:
        discard await producer(trace)
      except ValueError:
        trace[].add "consumer caught"

    runTest consumer

  proc testCancellation(): Trace =
    proc inner(trace: ptr Trace) {.async: (raises: [CancelledError]).} =
      try:
        await sleepAsync(10.minutes)
      except CancelledError as exc:
        callSoon(competitorCb, trace)
        trace[].add "inner cancelled"
        raise exc

    proc outer(trace: ptr Trace) {.async: (raises: [CancelledError]).} =
      try:
        await inner(trace)
      except CancelledError as exc:
        trace[].add "outer cancelled"
        raise exc

    var trace: Trace
    let fut = outer(addr trace)
    waitFor cancelAndWait(fut)
    trace

  proc testNested(): Trace =
    proc bottom(
        trace: ptr Trace): Future[int] {.async: (raises: [CancelledError]).} =
      await sleepAsync(ZeroDuration)
      callSoon(competitorCb, trace)
      trace[].add "bottom returns"
      1

    proc mid(
        trace: ptr Trace): Future[int] {.async: (raises: [CancelledError]).} =
      let v = await bottom(trace)
      trace[].add "mid returns"
      v + 1

    proc top(trace: ptr Trace) {.async: (raises: [CancelledError]).} =
      let v = await mid(trace)
      trace[].add "top returns " & $v

    runTest top

  proc testObserverReturn(): Trace =
    proc producer(
        trace: ptr Trace): Future[int] {.async: (raises: [CancelledError]).} =
      await sleepAsync(ZeroDuration)
      callSoon(competitorCb, trace)
      trace[].add "producer returns"
      7

    proc consumer(trace: ptr Trace) {.async: (raises: [CancelledError]).} =
      let fut = producer(trace)
      fut.addCallback(observerCb, trace)
      let v = await fut
      trace[].add "consumer returns " & $v

    runTest consumer

  proc testObserverRaise(): Trace =
    proc producer(
        trace: ptr Trace
    ): Future[int] {.async: (raises: [CancelledError, ValueError]).} =
      await sleepAsync(ZeroDuration)
      callSoon(competitorCb, trace)
      trace[].add "producer raising"
      raise newException(ValueError, "err")

    proc consumer(trace: ptr Trace) {.async: (raises: [CancelledError]).} =
      let fut = producer(trace)
      fut.addCallback(observerCb, trace)
      try:
        discard await fut
      except ValueError:
        trace[].add "consumer caught"

    runTest consumer

  proc testMultipleWaiters(): Trace =
    proc produce(
        trace: ptr Trace): Future[int] {.async: (raises: [CancelledError]).} =
      await sleepAsync(ZeroDuration)
      trace[].add "produced"
      42

    var trace: Trace
    let shared = produce(addr trace)

    proc subA(trace: ptr Trace) {.async: (raises: [CancelledError]).} =
      discard await shared
      trace[].add "subA"

    proc subB(trace: ptr Trace) {.async: (raises: [CancelledError]).} =
      discard await shared
      trace[].add "subB"

    proc strainA(trace: ptr Trace) {.async: (raises: [CancelledError]).} =
      await subA(trace)
      trace[].add "strainA"

    proc strainB(trace: ptr Trace) {.async: (raises: [CancelledError]).} =
      await subB(trace)
      trace[].add "strainB"

    waitFor noCancel allFutures(strainA(addr trace), strainB(addr trace))
    trace

  proc testManualSyncWakeup(): Trace =
    let fut = Future[void].Raising([CancelledError])
      .init("", {FutureFlag.SyncContinuations})

    proc producer(trace: ptr Trace) {.async: (raises: [CancelledError]).} =
      await fut
      trace[].add "producer returns"

    proc consumer(trace: ptr Trace) {.async: (raises: [CancelledError]).} =
      let w = producer(trace)
      callSoon(competitorCb, trace)
      fut.complete()
      await w

    runTest consumer

  proc testManualWakeup(): Trace =
    let fut = Future[void].Raising([CancelledError]).init()

    proc producer(trace: ptr Trace) {.async: (raises: [CancelledError]).} =
      await fut
      trace[].add "producer returns"

    proc consumer(trace: ptr Trace) {.async: (raises: [CancelledError]).} =
      let w = producer(trace)
      callSoon(competitorCb, trace)
      fut.complete()
      await w

    runTest consumer

  proc testCallbackOrder(): Trace =
    let fut = Future[void].Raising([CancelledError]).init()

    proc producer(trace: ptr Trace) {.async: (raises: [CancelledError]).} =
      await fut
      trace[].add "producer returns"

    proc consumer(trace: ptr Trace) {.async: (raises: [CancelledError]).} =
      fut.addCallback(observerCb, trace)
      let w = producer(trace)
      fut.addCallback(observerCb2, trace)
      fut.complete()
      await w

    runTest consumer

  proc testAddToComplete(): Trace =
    let fut = Future[void].Raising([CancelledError]).init()

    proc consumer(trace: ptr Trace) {.async: (raises: [CancelledError]).} =
      fut.complete()
      callSoon(competitorCb, trace)
      fut.addCallback(observerCb, trace)
      await sleepAsync(ZeroDuration)
      trace[].add "consumer returns"

    runTest consumer

  proc testWaitFor(): Trace =
    proc producer(trace: ptr Trace) {.async: (raises: []).} =
      await noCancel sleepAsync(ZeroDuration)
      callSoon(competitorCb, trace)
      trace[].add "producer returns"

    var trace: Trace
    waitFor producer(addr trace)
    trace.add "waitFor done"
    waitFor noCancel sleepAsync(ZeroDuration)
    trace

  proc testOrFirstFails(): Trace =
    proc first(
        trace: ptr Trace
    ): Future[void] {.async: (raises: [CancelledError, ValueError]).} =
      await sleepAsync(ZeroDuration)
      trace[].add "fut1 fails"
      raise newException(ValueError, "err")

    proc second(
        trace: ptr Trace,
        fut1: Future[void].Raising([CancelledError, ValueError])
    ) {.async: (raises: [CancelledError]).} =
      try: await fut1
      except ValueError: discard
      trace[].add "fut2 completes"

    proc consumer(trace: ptr Trace) {.async: (raises: [CancelledError]).} =
      let
        fut1 = first(trace)
        fut2 = second(trace, fut1)
      try:
        await (fut1 or fut2)
        trace[].add "or: completed"
      except ValueError:
        trace[].add "or: failed"

    runTest consumer

  proc testRaceFirstWins(): Trace =
    proc first(
        trace: ptr Trace): Future[int] {.async: (raises: [CancelledError]).} =
      await sleepAsync(ZeroDuration)
      trace[].add "first completes"
      1

    proc second(
        trace: ptr Trace,
        fut1: Future[int].Raising([CancelledError])
    ): Future[int] {.async: (raises: [CancelledError]).} =
      discard await fut1
      trace[].add "second completes"
      2

    proc consumer(trace: ptr Trace) {.async: (raises: [CancelledError]).} =
      let
        fut1 = first(trace)
        fut2 = second(trace, fut1)
        res = await race(fut1, fut2)
      if res == FutureBase(fut1):
        trace[].add "race: first"
      else:
        trace[].add "race: second"

    runTest consumer

  proc testOneFirstWins(): Trace =
    proc first(
        trace: ptr Trace): Future[int] {.async: (raises: [CancelledError]).} =
      await sleepAsync(ZeroDuration)
      trace[].add "first completes"
      1

    proc second(
        trace: ptr Trace,
        fut1: Future[int].Raising([CancelledError])
    ): Future[int] {.async: (raises: [CancelledError]).} =
      discard await fut1
      trace[].add "second completes"
      2

    proc consumer(trace: ptr Trace) {.async: (raises: [CancelledError]).} =
      let
        fut1 = first(trace)
        fut2 = second(trace, fut1)
        res = await one(fut1, fut2)
      if FutureBase(res) == FutureBase(fut1):
        trace[].add "one: first"
      else:
        trace[].add "one: second"

    runTest consumer

  proc testAsyncEventOrder(): Trace =
    let event = newAsyncEvent()

    proc waiterA(trace: ptr Trace) {.async: (raises: [CancelledError]).} =
      await event.wait()
      trace[].add "waiter A"

    proc waiterB(trace: ptr Trace) {.async: (raises: [CancelledError]).} =
      await event.wait()
      trace[].add "waiter B"

    proc consumer(trace: ptr Trace) {.async: (raises: [CancelledError]).} =
      let
        a = waiterA(trace)
        b = waiterB(trace)
      event.fire()
      await allFutures(a, b)

    runTest consumer

  test "Simple flow not interrupted test":
    when chronosSyncContinuations:
      check:
        testValueReturn() ==
          @["producer returns", "consumer returns 42", "competitor"]
        testFailingReturn() ==
          @["producer raising", "consumer caught", "competitor"]
    else:
      check:
        testValueReturn() ==
          @["producer returns", "competitor", "consumer returns 42"]
        testFailingReturn() ==
          @["producer raising", "competitor", "consumer caught"]

  test "Cancellation not interrupted test":
    when chronosSyncContinuations:
      check testCancellation() ==
        @["inner cancelled", "outer cancelled", "competitor"]
    else:
      check testCancellation() ==
        @["inner cancelled", "competitor", "outer cancelled"]

  test "Nested flow not interrupted test":
    when chronosSyncContinuations:
      check testNested() ==
        @["bottom returns", "mid returns", "top returns 2", "competitor"]
    else:
      check testNested() ==
        @["bottom returns", "competitor", "mid returns", "top returns 2"]

  test "Observer deferred test":
    when chronosSyncContinuations:
      check:
        testObserverReturn() ==
          @["producer returns", "consumer returns 7", "competitor", "observer"]
        testObserverRaise() ==
          @["producer raising", "consumer caught", "competitor", "observer"]
    else:
      check:
        testObserverReturn() ==
          @["producer returns", "competitor", "observer", "consumer returns 7"]
        testObserverRaise() ==
          @["producer raising", "competitor", "observer", "consumer caught"]

  test "Multiple waiters test":
    when chronosSyncContinuations:
      check testMultipleWaiters() ==
        @["produced", "subA", "strainA", "subB", "strainB"]
    else:
      check testMultipleWaiters() ==
        @["produced", "subA", "subB", "strainA", "strainB"]

  test "Manual wakeup not interrupted test":
    when chronosSyncContinuations:
      check testManualSyncWakeup() == @["producer returns", "competitor"]
    else:
      check testManualSyncWakeup() == @["competitor", "producer returns"]

  test "Manual wakeup interruptible test":
    check testManualWakeup() == @["competitor", "producer returns"]

  test "Callback order test":
    check testCallbackOrder() == @["observer", "producer returns", "observer2"]

  test "Add callback to completed future test":
    check testAddToComplete() == @["competitor", "observer", "consumer returns"]

  test "waitFor includes callbacks test":
    check testWaitFor() == @["producer returns", "competitor", "waitFor done"]

  test "Combinators order test":
    check:
      testOrFirstFails() ==
        @["fut1 fails", "fut2 completes", "or: failed"]
      testRaceFirstWins() ==
        @["first completes", "second completes", "race: first"]
      testOneFirstWins() ==
        @["first completes", "second completes", "one: first"]

  test "AsyncEvent order test":
    check testAsyncEventOrder() == @["waiter A", "waiter B"]

  proc testCallSoonIteration(): Trace =
    var trace: Trace

    proc tick(udata: pointer) =
      let active = cast[ptr bool](udata)
      if active[]:
        trace.add "tick"
        callSoon(tick, udata)

    proc timer(active: ptr bool) {.async: (raises: [CancelledError]).} =
      await sleepAsync(ZeroDuration)
      trace.add "timer"

    var active = true
    callSoon(tick, addr active)
    let timerFut = timer(addr active)
    for i in 0 ..< 3:
      poll()
    active = false
    waitFor noCancel timerFut
    waitFor noCancel sleepAsync(ZeroDuration)
    trace

  test "callSoon order test":
    check testCallSoonIteration() == @["tick", "tick", "timer", "tick"]

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

  when chronosSyncContinuations:
    test "Simple flow not interrupted test":
      check:
        testValueReturn() ==
          @["producer returns", "consumer returns 42", "competitor"]
        testFailingReturn() ==
          @["producer raising", "consumer caught", "competitor"]

    test "Cancellation not interrupted test":
      check testCancellation() ==
        @["inner cancelled", "outer cancelled", "competitor"]

    test "Nested flow not interrupted test":
      check testNested() ==
        @["bottom returns", "mid returns", "top returns 2", "competitor"]

    test "Observer deferred test":
      check:
        testObserverReturn() ==
          @["producer returns", "observer", "consumer returns 7", "competitor"]
        testObserverRaise() ==
          @["producer raising", "observer", "consumer caught", "competitor"]

    test "Manual wakeup interruptible test":
      check testManualWakeup() == @["competitor", "producer returns"]

    test "Manual wakeup not interrupted test":
      check testManualSyncWakeup() == @["producer returns", "competitor"]

    test "Multiple waiters test":
      check testMultipleWaiters() ==
        @["produced", "subA", "strainA", "subB", "strainB"]

#                Chronos Test Suite
#            (c) Copyright 2026-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)
import unittest2
import ../chronos

{.push raises: [], gcsafe.}
{.used.}

suite "Stack unwind scheduling test suite":
  type Trace = seq[string]

  proc runTest(
      cb: proc (
          trace: ptr Trace
        ): Future[void].Raising([CancelledError]) {.raises: [], gcsafe.}
  ): Trace =
    var trace: Trace
    try:
      waitFor cb(addr trace)
    except CancelledError:
      raiseAssert "Not cancelled"
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

  proc testMultiLevel(): Trace =
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

  proc testFanout(): Trace =
    proc produce(
        trace: ptr Trace): Future[int] {.async: (raises: [CancelledError]).} =
      await sleepAsync(ZeroDuration)
      trace[].add "produced"
      42

    var trace: Trace
    let shared = produce(addr trace)

    proc subA(
        trace: ptr Trace): Future[void] {.async: (raises: [CancelledError]).} =
      discard await shared
      trace[].add "subA"

    proc subB(
        trace: ptr Trace): Future[void] {.async: (raises: [CancelledError]).} =
      discard await shared
      trace[].add "subB"

    proc strainA(trace: ptr Trace) {.async: (raises: [CancelledError]).} =
      await subA(trace)
      trace[].add "strainA"

    proc strainB(trace: ptr Trace) {.async: (raises: [CancelledError]).} =
      await subB(trace)
      trace[].add "strainB"

    try:
      waitFor allFutures(strainA(addr trace), strainB(addr trace))
    except CancelledError:
      raiseAssert "Not cancelled"
    trace

  test "Unwind not interrupted test":
    check:
      testValueReturn() ==
        @["producer returns", "consumer returns 42", "competitor"]
      testFailingReturn() ==
        @["producer raising", "consumer caught", "competitor"]

  test "Multi-level unwind not interrupted test":
    check testMultiLevel() ==
      @["bottom returns", "mid returns", "top returns 2", "competitor"]

  test "Observer deferred test":
    check:
      testObserverReturn() ==
        @["producer returns", "consumer returns 7", "competitor", "observer"]
      testObserverRaise() ==
        @["producer raising", "consumer caught", "competitor", "observer"]

  test "Manual wakeup interruptible test":
    check testManualWakeup() == @["competitor", "producer returns"]

  test "Fan-out depth-first test":
    # Each strain unwinds to conclusion before the next strain begins.
    # Executed in reverse registration order.
    check testFanout() ==
      @["produced", "subB", "strainB", "subA", "strainA"]

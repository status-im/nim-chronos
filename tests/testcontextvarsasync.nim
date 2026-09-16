#                Chronos Test Suite
#            (c) Copyright 2018-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

## Async propagation tests for chronos contextvars: bindings survive
## await, concurrent tasks stay isolated, and children inherit without
## leaking back. See testcontextvars.nim for the sync-only baseline.

import unittest2
import ../chronos
import ../chronos/config
import ../chronos/contextvars
import ../chronos/futures
  # Whitebox: capturingCallback is excluded from the public `import chronos`
  # surface (see chronos/internal/asyncengine.nim's `export futures except
  # ...`); the internalCallTick pin below needs it to opt a caller-supplied
  # AsyncCallback into context capture.

when not defined(windows):
  import std/posix
  when chronosEventEngine in ["epoll", "kqueue"]:
    # Signal/process registration (and asyncproc, which this file uses
    # only for spawning a child) exists on the epoll/kqueue engines
    # only — same gate testall.nim applies to testsignal/testproc.
    import ../chronos/asyncproc

{.used.}

let asyncInt = newContextVar("asyncInt", 0)
let asyncStr = newContextVar("asyncStr", "")
let asyncReq = newRequiredContextVar[int]("asyncReq")    # must-bind: no default

suite "contextvars: async propagation":

  test "concurrent tasks with interleaved suspensions each see their own binding":
    # Lockstep alternation via a future handshake (not timed sleeps, which
    # don't guarantee interleaving order) so each resume must see its own
    # binding rather than the other task's leftover.
    var tickA, tickB: Future[void]
    proc resetTicks() =
      tickA = newFuture[void]("tickA")
      tickB = newFuture[void]("tickB")

    proc taskA(): Future[int] {.async: (raises: [Exception]).} =
      asyncInt.withValue(100):
        await tickA
        check asyncInt.value == 100
        tickB.complete()  # hand off to B
        resetTicks()
        await tickA
        check asyncInt.value == 100
        tickB.complete()
        return asyncInt.value

    proc taskB(): Future[int] {.async: (raises: [Exception]).} =
      asyncInt.withValue(200):
        await tickB
        check asyncInt.value == 200
        tickA.complete()  # hand off to A
        await tickB
        check asyncInt.value == 200
        return asyncInt.value

    proc driver(): Future[(int, int)] {.async: (raises: [Exception]).} =
      resetTicks()
      let fa = taskA()
      let fb = taskB()
      tickA.complete()  # kick off A
      let a = await fa
      let b = await fb
      return (a, b)

    let (a, b) = waitFor(driver())
    check a == 100
    check b == 200

  test "multiple value types coexist on same context chain across await":
    # Both vars must remain visible after an await regardless of type or
    # position on the chain.
    proc work(): Future[(int, string)] {.async: (raises: [CancelledError]).} =
      check asyncInt.value == 42
      check asyncStr.value == "tracer"
      await sleepAsync(1.milliseconds)
      check asyncInt.value == 42
      check asyncStr.value == "tracer"
      return (asyncInt.value, asyncStr.value)

    proc driver(): Future[(int, string)] {.async: (raises: [CancelledError]).} =
      asyncInt.withValue(42):
        asyncStr.withValue("tracer"):
          return await work()

    check waitFor(driver()) == (42, "tracer")

  test "binding survives multiple sequential awaits":
    proc work(): Future[int] {.async: (raises: [CancelledError]).} =
      check asyncInt.value == 11
      await sleepAsync(1.milliseconds)
      check asyncInt.value == 11
      await sleepAsync(1.milliseconds)
      check asyncInt.value == 11
      await sleepAsync(1.milliseconds)
      return asyncInt.value

    proc driver(): Future[int] {.async: (raises: [CancelledError]).} =
      asyncInt.withValue(11):
        return await work()

    check waitFor(driver()) == 11

  test "child task inherits parent's context at spawn":
    proc child(): Future[int] {.async: (raises: [CancelledError]).} =
      check asyncInt.value == 42     # inherited from parent's binding
      await sleepAsync(1.milliseconds)
      check asyncInt.value == 42
      return asyncInt.value

    proc parent(): Future[int] {.async: (raises: [CancelledError]).} =
      asyncInt.withValue(42):
        return await child()

    check waitFor(parent()) == 42

  test "parent's binding survives spawn-then-await of independent child":
    # Deferred-await pattern: parent spawns the child future, does other
    # work, then awaits it later. Parent's binding must survive across
    # the intervening dispatcher returns.
    proc child(): Future[int] {.async: (raises: [CancelledError]).} =
      check asyncInt.value == 42      # parent's binding inherited
      await sleepAsync(1.milliseconds)
      asyncInt.withValue(999):           # child rebinds locally
        await sleepAsync(1.milliseconds)
        check asyncInt.value == 999
      check asyncInt.value == 42      # back to inherited
      return asyncInt.value

    proc parent(): Future[int] {.async: (raises: [CancelledError]).} =
      asyncInt.withValue(42):
        let f = child()           # spawn
        check asyncInt.value == 42
        await sleepAsync(1.milliseconds)  # parent yields, child runs
        check asyncInt.value == 42    # parent still sees its own
        let r = await f
        check r == 42
        check asyncInt.value == 42    # post-await, parent's binding intact
        return asyncInt.value

    check waitFor(parent()) == 42

  test "child's nested binding does not leak back to parent":
    proc child(): Future[void] {.async: (raises: [CancelledError]).} =
      asyncInt.withValue(999):
        await sleepAsync(1.milliseconds)
        check asyncInt.value == 999
      check asyncInt.value == 42    # back to parent's binding

    proc parent(): Future[int] {.async: (raises: [CancelledError]).} =
      asyncInt.withValue(42):
        await child()
        return asyncInt.value       # parent still sees its own 42

    check waitFor(parent()) == 42

  test "exception across await reverts binding":
    proc work(): Future[void] {.async: (raises: [Exception]).} =
      await sleepAsync(1.milliseconds)
      raise newException(ValueError, "boom across await")

    proc driver(): Future[int] {.async: (raises: [Exception]).} =
      try:
        asyncInt.withValue(77):
          check asyncInt.value == 77
          await work()
          check false           # unreachable
      except ValueError:
        discard
      return asyncInt.value         # binding reverted

    check waitFor(driver()) == 0

  test "CancelledError across await reverts binding":
    proc longSleep(): Future[void] {.async: (raises: [CancelledError]).} =
      await sleepAsync(1.seconds)

    proc driver(): Future[int] {.async: (raises: [CancelledError]).} =
      let f = longSleep()
      var observed = -1
      try:
        asyncInt.withValue(55):
          check asyncInt.value == 55
          # Cancel the inner future from a sibling timer so cancellation
          # propagates through our `await f`.
          discard setTimer(Moment.now() + 1.milliseconds,
                           proc(_: pointer) {.gcsafe, raises: [].} =
                             f.cancelSoon())
          await f
          check false           # unreachable — cancel must propagate
      except CancelledError:
        observed = asyncInt.value
      check observed == 0       # CancelledError unwound asyncInt.withValue(55)
      return asyncInt.value

    check waitFor(driver()) == 0

  test "CancelledError caught inside withName sees the binding":
    # Unlike the test above, the except handler is INSIDE the binder here,
    # so the binding must still be visible while it runs.
    proc longSleep(): Future[void] {.async: (raises: [CancelledError]).} =
      await sleepAsync(1.seconds)

    proc driver(): Future[int] {.async: (raises: [CancelledError]).} =
      let f = longSleep()
      var observedInsideHandler = -1
      asyncInt.withValue(88):
        check asyncInt.value == 88
        discard setTimer(Moment.now() + 1.milliseconds,
                         proc(_: pointer) {.gcsafe, raises: [].} =
                           f.cancelSoon())
        try:
          await f
          check false           # unreachable
        except CancelledError:
          observedInsideHandler = asyncInt.value   # binder still active
      check observedInsideHandler == 88
      return asyncInt.value         # binder reverted on normal exit

    check waitFor(driver()) == 0

template pinsCaptureSite(testName: string, bindValue: int, expected: int,
                          registration: untyped) =
  ## Owns the seenBinding/fired/driver scaffolding shared by the
  ## scheduling-site capture-coverage tests below, which differ only in
  ## their registration statement and the value bound at the registrant's
  ## call site (and, for the context-blind trampoline, in the expected
  ## value observed at fire time).
  test testName:
    var seenBinding = -1
    var fired = false

    proc cb(udata: pointer) {.gcsafe, raises: [], inject.} =
      seenBinding = asyncInt.value
      fired = true

    proc driver(): Future[void] {.async: (raises: [CancelledError]).} =
      asyncInt.withValue(bindValue):
        registration
        while not fired:
          await sleepAsync(1.milliseconds)

    waitFor(driver())
    check seenBinding == expected

suite "contextvars: scheduling-site capture coverage":

  pinsCaptureSite("callSoon callback fires with the registrant's binding",
                   789, 789):
    callSoon(cb, nil)

  test "sleepAsync callback fires with the registrant's binding":
    # Pinned explicitly as a regression guard on setTimer's construction site.
    proc driver(): Future[int] {.async: (raises: [CancelledError]).} =
      asyncInt.withValue(456):
        await sleepAsync(1.milliseconds)
        return asyncInt.value
    check waitFor(driver()) == 456

  pinsCaptureSite("internalCallTick is context-blind (internal trampoline)",
                   123, 0):
    # Internal scheduling sites use bareCallback (no context capture), so a
    # callback scheduled from inside asyncInt.withValue(123) must see the default.
    internalCallTick(cb, nil)

  pinsCaptureSite(
      "internalCallTick(capturingCallback(...)) fires with the registrant's binding",
      135, 135):
    # internalCallTick's AsyncCallback overload leaves the capture choice to
    # the caller; capturingCallback() is the documented opt-in counterpart
    # to the context-blind trampoline pinned above.
    internalCallTick(capturingCallback(cb, nil))

  pinsCaptureSite("callIdle callback fires with the registrant's binding",
                   321, 321):
    callIdle(cb, nil)

  when not defined(windows):
    # addReader/addWriter/addSignal2/addProcess2 are POSIX-selector APIs;
    # Windows equivalents go through separate IOCP paths.

    test "addReader callback fires with the registrant's binding":
      var seenBinding = -1
      var fired = false
      let (rfd, wfd) = createAsyncPipe()
      proc onReadable(udata: pointer) {.gcsafe, raises: [].} =
        seenBinding = asyncInt.value
        fired = true

      proc driver(): Future[void] {.async: (raises: [Exception]).} =
        asyncInt.withValue(654):
          register(rfd)
          addReader(rfd, onReadable)
          # Poke the write end to make the read end readable.
          let buf = "x"
          discard posix.write(cint(wfd), unsafeAddr buf[0], 1)
          while not fired:
            await sleepAsync(1.milliseconds)
          removeReader(rfd)
        closeSocket(rfd)
        closeSocket(wfd)
      waitFor(driver())
      check seenBinding == 654

    test "addWriter callback fires with the registrant's binding":
      # An empty pipe's write end is immediately writable, so the callback
      # fires on the next poll tick.
      var seenBinding = -1
      var fired = false
      let (rfd, wfd) = createAsyncPipe()
      proc onWritable(udata: pointer) {.gcsafe, raises: [].} =
        seenBinding = asyncInt.value
        fired = true

      proc driver(): Future[void] {.async: (raises: [Exception]).} =
        asyncInt.withValue(655):
          register(wfd)
          addWriter(wfd, onWritable)
          while not fired:
            await sleepAsync(1.milliseconds)
          removeWriter(wfd)
        closeSocket(rfd)
        closeSocket(wfd)
      waitFor(driver())
      check seenBinding == 655

    when chronosEventEngine in ["epoll", "kqueue"]:
      # Signal/process registration exists on the epoll/kqueue engines
      # only - same gate testall.nim applies to testsignal/testproc.
      test "addSignal2 handler fires with the registrant's binding":
        var seenBinding = -1
        var sigFd: SignalHandle
        let handlerFut = newFuture[void]("ctx.signal.handler")
        proc signalHandler(udata: pointer) {.gcsafe.} =
          seenBinding = asyncInt.value
          let res = removeSignal2(sigFd)
          if res.isErr():
            handlerFut.fail(newException(ValueError, osErrorMsg(res.error())))
          else:
            handlerFut.complete()

        proc driver(): Future[void] {.async: (raises: [Exception]).} =
          asyncInt.withValue(456):
            sigFd =
              block:
                let res = addSignal2(SIGUSR1, signalHandler)
                if res.isErr():
                  raiseAssert osErrorMsg(res.error())
                res.get()
            discard posix.kill(posix.getpid(), cint(SIGUSR1))
            await handlerFut.wait(5.seconds)
        waitFor(driver())
        check seenBinding == 456

      test "addProcess2 handler fires with the registrant's binding":
        var seenBinding = -1
        var pidFd: ProcessHandle
        let handlerFut = newFuture[void]("ctx.process.handler")
        var process: AsyncProcessRef
        proc processHandler(udata: pointer) {.gcsafe.} =
          seenBinding = asyncInt.value
          let res = removeProcess2(pidFd)
          if res.isErr():
            handlerFut.fail(newException(ValueError, osErrorMsg(res.error())))
          else:
            handlerFut.complete()

        proc driver(): Future[void] {.async: (raises: [Exception]).} =
          process = await startProcess("sleep 0.3",
                                       options = {AsyncProcessOption.EvalCommand})
          try:
            asyncInt.withValue(789):
              pidFd =
                block:
                  let res = addProcess2(process.pid(), processHandler)
                  if res.isErr():
                    raiseAssert osErrorMsg(res.error())
                  res.get()
              await handlerFut.wait(5.seconds)
          finally:
            await process.closeWait()
        waitFor(driver())
        check seenBinding == 789

  test "race() resolver fires with the awaiter's binding":
    proc child(value: int, delayMs: int): Future[int] {.async: (raises: [CancelledError]).} =
      asyncInt.withValue(value):
        await sleepAsync(delayMs.milliseconds)
        return value

    proc driver(): Future[int] {.async: (raises: [Exception]).} =
      asyncInt.withValue(111):
        let fa = child(222, 1)
        let fb = child(333, 50)
        discard await race(FutureBase(fa), FutureBase(fb))
        let observed = asyncInt.value
        # Drain the loser so it doesn't leak into testutils' pending check.
        await fb.cancelAndWait()
        return observed

    check waitFor(driver()) == 111

  test "allFutures() continuation fires with the awaiter's binding":
    proc child(value: int): Future[int] {.async: (raises: [CancelledError]).} =
      asyncInt.withValue(value):
        await sleepAsync(1.milliseconds)
        return value

    proc driver(): Future[int] {.async: (raises: [Exception]).} =
      asyncInt.withValue(222):
        let fa = child(444)
        let fb = child(555)
        await allFutures(fa, fb)
        return asyncInt.value

    check waitFor(driver()) == 222

  test "wait(duration) resumes the awaiter under its own binding":
    proc child(value: int): Future[int] {.async: (raises: [CancelledError]).} =
      asyncInt.withValue(value):
        await sleepAsync(1.milliseconds)
        return value

    proc driver(): Future[int] {.async: (raises: [Exception]).} =
      asyncInt.withValue(31):
        check (await child(32).wait(1.seconds)) == 32
        return asyncInt.value

    check waitFor(driver()) == 31

  test "wait(deadline future) resumes the awaiter under its own binding":
    # Routes through waitUntilImpl, a separate path from the duration variant.
    proc child(value: int): Future[int] {.async: (raises: [CancelledError]).} =
      asyncInt.withValue(value):
        await sleepAsync(1.milliseconds)
        return value

    proc driver(): Future[int] {.async: (raises: [Exception]).} =
      asyncInt.withValue(36):
        let deadline = sleepAsync(1.seconds)
        check (await child(37).wait(deadline)) == 37
        await deadline.cancelAndWait()
        return asyncInt.value

    check waitFor(driver()) == 36

  test "withTimeout() resumes the awaiter under its own binding":
    proc child(value: int): Future[int] {.async: (raises: [CancelledError]).} =
      asyncInt.withValue(value):
        await sleepAsync(1.milliseconds)
        return value

    proc driver(): Future[int] {.async: (raises: [Exception]).} =
      asyncInt.withValue(41):
        let fut = child(42)
        check (await fut.withTimeout(1.seconds)) == true
        check fut.read() == 42
        return asyncInt.value

    check waitFor(driver()) == 41

  test "`or` resumes the awaiter under its own binding":
    proc child(value: int, delayMs: int): Future[void] {.async: (raises: [CancelledError]).} =
      asyncInt.withValue(value):
        await sleepAsync(delayMs.milliseconds)

    proc driver(): Future[int] {.async: (raises: [Exception]).} =
      asyncInt.withValue(51):
        let fa = child(52, 1)
        let fb = child(53, 50)
        await fa or fb
        let observed = asyncInt.value
        # Drain the loser so it doesn't trip testutils' pending check.
        await fb.cancelAndWait()
        return observed

    check waitFor(driver()) == 51

  test "join() resumes the awaiter under its own binding":
    proc child(value: int): Future[int] {.async: (raises: [CancelledError]).} =
      asyncInt.withValue(value):
        await sleepAsync(1.milliseconds)
        return value

    proc driver(): Future[int] {.async: (raises: [Exception]).} =
      asyncInt.withValue(61):
        let fut = child(62)
        await fut.join()
        check fut.read() == 62
        return asyncInt.value

    check waitFor(driver()) == 61

  pinsCaptureSite("closeHandle aftercb fires with the registrant's binding",
                   987, 987):
    # Tested separately from closeSocket: closeHandle has its own IOCP
    # path on Windows.
    let (rfd, wfd) = createAsyncPipe()
    closeHandle(rfd, cb)
    closeHandle(wfd)

  pinsCaptureSite("closeSocket aftercb fires with the registrant's binding",
                   321, 321):
    let (rfd, wfd) = createAsyncPipe()
    closeSocket(rfd, cb)
    closeSocket(wfd)

  test "cancelSoon's already-finished branch fires aftercb with the registrant's binding":
    # When `future` is already finished at call time, cancelSoon skips the
    # cancel-and-await path and schedules aftercb directly via
    # callSoon(capturingCallback(aftercb, udata)) at the cancelSoon call
    # site itself - a different capture site from the pending-future path
    # pinned in the cancelCallback suite below.
    var seenBinding = -1
    var fired = false

    let fut = newFuture[void]("already-finished-cancelsoon")
    fut.complete()
    check fut.finished()

    proc aftercb(udata: pointer) {.gcsafe, raises: [].} =
      seenBinding = asyncInt.value
      fired = true

    asyncInt.withValue(741):
      cancelSoon(fut, aftercb, nil)

    asyncInt.withValue(742):
      poll()

    check fired
    check seenBinding == 741

  test "cancelSoon(AsyncCallback) fires under the callback's own captured binding":
    # Unlike the CallbackFunc/pointer overload above, this overload takes
    # an already-built AsyncCallback - it must fire under the binding live
    # when that AsyncCallback was constructed, not whatever is ambient at
    # the cancelSoon() call site or when the future is later polled.
    var seenBinding = -1
    var fired = false

    proc aftercb(udata: pointer) {.gcsafe, raises: [].} =
      seenBinding = asyncInt.value
      fired = true

    var acb: AsyncCallback
    asyncInt.withValue(111):
      acb = capturingCallback(aftercb, nil)

    let fut = newFuture[void]("already-finished-cancelsoon-acb")
    fut.complete()
    check fut.finished()

    asyncInt.withValue(222):
      cancelSoon(fut, acb)

    asyncInt.withValue(333):
      poll()

    check fired
    check seenBinding == 111

  test "cancelSoon(AsyncCallback)'s pending branch fires under the callback's own captured binding":
    # Sibling of the already-finished pin above: here `future` is still
    # pending when cancelSoon() registers `acb`, so it travels through the
    # cancel-and-await path (internalCallback/tryCancel) rather than the
    # direct callSoon() the already-finished branch takes. `acb`'s own
    # captured binding must still be what fires, not the binding live at
    # the cancelSoon() call site or at poll() time.
    var seenBinding = -1
    var fired = false

    proc aftercb(udata: pointer) {.gcsafe, raises: [].} =
      seenBinding = asyncInt.value
      fired = true

    var acb: AsyncCallback
    asyncInt.withValue(211):
      acb = capturingCallback(aftercb, nil)

    let fut = newFuture[void]("pending-cancelsoon-acb")
    check not fut.finished()

    asyncInt.withValue(322):
      cancelSoon(fut, acb)

    asyncInt.withValue(433):
      while not fired:
        poll()

    check fired
    check seenBinding == 211
    check fut.cancelled()

suite "contextvars: bridging independent callbacks":

  test "currentContext()/withContext() bridges independent callbacks":
    # An enter hook and a separately-fired exit hook share no await or call
    # stack, so no binder spans them; currentContext()/withContext() bridge
    # the two explicitly via a caller-held snapshot.
    var snapshot: AsyncContext
    var enterRan = false
    var exitObserved = -1

    proc enterCb(udata: pointer) {.gcsafe, raises: [].} =
      asyncInt.withValue(42):
        snapshot = currentContext()
      enterRan = true

    proc exitCb(udata: pointer) {.gcsafe, raises: [].} =
      withContext(snapshot):
        exitObserved = asyncInt.value

    callSoon(enterCb, nil)
    poll()
    check enterRan

    callSoon(exitCb, nil)
    poll()
    check exitObserved == 42

suite "contextvars: cancelCallback capture":

  test "cancelCallback observes the registrant's binding, not the canceller's":
    var seenBinding = ""
    var fired = false

    let fut = newFuture[void]("owner-future")
    asyncStr.withValue("owner"):
      fut.cancelCallback = proc(_: pointer) {.gcsafe, raises: [].} =
        seenBinding = asyncStr.value
        fired = true

    asyncStr.withValue("canceller"):
      discard tryCancel(fut)

    check fired
    check seenBinding == "owner"

  test "cancelCallback observes the registrant's binding through cancelSoon's checktick retry":
    # OwnCancelSchedule means tryCancel won't auto-cancel; onCancel defers
    # cancellation to its second call, forcing a context-blind checktick
    # retry. The registrant's "owner" binding must hold on both invocations.
    var observed: seq[string]

    let fut = newFuture[void]("owner-future-checktick",
                              {FutureFlag.OwnCancelSchedule})

    proc onCancel(_: pointer) {.gcsafe, raises: [].} =
      observed.add asyncStr.value
      if observed.len >= 2:
        fut.cancelAndSchedule()

    asyncStr.withValue("owner"):
      fut.cancelCallback = onCancel

    proc driver(): Future[void] {.async: (raises: [CancelledError]).} =
      asyncStr.withValue("canceller"):
        cancelSoon(fut)
        while not fut.finished():
          await sleepAsync(1.milliseconds)

    waitFor(driver())
    check observed == @["owner", "owner"]

  test "cancelCallback with no contextvars anywhere still cancels (nil context)":
    var fired = false

    let fut = newFuture[void]("no-context-future")
    fut.cancelCallback = proc(_: pointer) {.gcsafe, raises: [].} =
      fired = true

    check tryCancel(fut)
    check fired
    check fut.cancelled()

  test "cancelCallback fast arm fires cleanly while an unrelated task is parked mid-binder elsewhere":
    # The fast arm must observe only its own captured context and must not
    # clobber the nil ambient state a parked task's suspend already restored.
    let parkedWaiter = newFuture[void]("parked-waiter")
    var parkedObserved = -2

    proc parked(): Future[void] {.async: (raises: [Exception]).} =
      asyncInt.withValue(777):
        await parkedWaiter          # suspends INSIDE the binder
        parkedObserved = asyncInt.value

    let parkedFut = parked()        # suspends mid-binder; ambient restored to nil
    check asyncInt.value == 0           # confirms no leak from `parked`'s entry

    var fired = false
    let fut = newFuture[void]("cancel-future")
    fut.cancelCallback = proc(_: pointer) {.gcsafe, raises: [].} =
      check asyncInt.value == 0         # own captured (nil) context, not 777
      fired = true

    check tryCancel(fut)            # fires while `parked` sits suspended
    check fired
    check fut.cancelled()
    check asyncInt.value == 0           # still clean after the cancel fires

    parkedWaiter.complete()
    waitFor parkedFut
    check parkedObserved == 777     # parked's own binding, undisturbed

suite "contextvars: fast-path pins":
  # Regression pins for withRestoredContext's identity fast arm (no write)
  # vs. its slow arm (write + restore).

  test "interleaved fast/slow-arm callbacks in one poll batch each observe their own context":
    # Alternates fast-arm (nil capture) and slow-arm (bound capture) callbacks
    # in one batch; each must observe its own value regardless of arm order.
    var seen: seq[int]

    proc recordCb(udata: pointer) {.gcsafe, raises: [].} =
      seen.add asyncInt.value

    callSoon(recordCb, nil)          # nil capture -> fast arm (nil == nil)
    asyncInt.withValue(11):
      callSoon(recordCb, nil)        # 11 capture  -> slow arm
    callSoon(recordCb, nil)          # nil capture -> fast arm
    asyncInt.withValue(22):
      callSoon(recordCb, nil)        # 22 capture  -> slow arm
    asyncInt.withValue(33):
      callSoon(recordCb, nil)        # 33 capture  -> slow arm
    callSoon(recordCb, nil)          # nil capture -> fast arm

    poll()
    check seen == @[0, 11, 0, 22, 33, 0]

  test "bind-and-raise on the fast arm leaves the ambient context clean after the batch":
    # The callback binds then raises a Defect (CallbackFunc is raises: []).
    # withValue's own finally must still unwind the binding even
    # though the fast arm itself never wrote/restored currentAsyncContext.
    proc raiser(udata: pointer) {.gcsafe, raises: [].} =
      asyncInt.withValue(999):
        doAssert false, "contextvars: intentional Defect to " &
                         "exercise the fast-arm raise path"

    callSoon(raiser, nil)
    var caught = false
    try:
      poll()
    except Defect:
      caught = true
    check caught
    check asyncInt.value == 0

  test "bind-and-raise on the slow arm restores the prior ambient context after the batch (fireWithContext)":
    # Captured (111) and ambient (222) contexts differ at fire time, forcing
    # the slow arm; the callback asserting asyncInt.value == 111 before raising
    # proves the write ran.
    proc raiser(udata: pointer) {.gcsafe, raises: [].} =
      check asyncInt.value == 111       # proves the slow arm's write executed
      doAssert false, "contextvars: intentional Defect to " &
                       "exercise the slow-arm restore path (fireWithContext)"

    asyncInt.withValue(111):
      callSoon(raiser, nil)         # captured context = 111

    asyncInt.withValue(222):               # ambient at fire time = 222 != 111
      var caught = false
      try:
        poll()
      except Defect:
        caught = true
      check caught
      # The finally must restore the ambient context to 222, not leave it
      # at the callback's captured value (111).
      check asyncInt.value == 222
    check asyncInt.value == 0

  test "bind-and-raise on the slow arm restores the prior ambient context after cancellation (fireCancelCallback)":
    # Same slow-arm restore contract as above, through the cancelCallback
    # fire site instead of the regular callback fire site.
    let fut = newFuture[void]("slow-arm-cancel")
    proc raiserCancel(_: pointer) {.gcsafe, raises: [].} =
      check asyncInt.value == 333       # proves the slow arm's write executed
      doAssert false, "contextvars: intentional Defect to " &
                       "exercise the slow-arm restore path (fireCancelCallback)"

    asyncInt.withValue(333):
      fut.cancelCallback = raiserCancel   # captured context = 333

    asyncInt.withValue(444):               # ambient at fire time = 444 != 333
      var caught = false
      try:
        discard tryCancel(fut)
      except Defect:
        caught = true
      check caught
      check asyncInt.value == 444
    check asyncInt.value == 0

    # The Defect from raiserCancel escapes before cancelAndSchedule runs, so
    # fut is left permanently Pending, inflating testutils' future-count
    # checks for later tests unless completed manually here.
    fut.complete()

  test "nil-captured resume through a suspended binder leaves the ambient context clean for a later same-batch callback":
    # A yield inside withValue is a plain return, so withValue's finally
    # does not run for it; the resume must still restore currentAsyncContext
    # so callbacks queued behind it in the same batch don't see a leaked binding.
    let outerWaiter = newFuture[void]("leak-repro.outer")
    let innerWaiter = newFuture[void]("leak-repro.inner")
    var innerObserved = -1
    var laterSeenBinding = -1
    var laterFired = false

    proc leaky(): Future[void] {.async: (raises: [Exception]).} =
      await outerWaiter               # captured with nil ambient context
      asyncInt.withValue(999):
        await innerWaiter             # the suspend point is inside withValue's
                                       # dynamic extent, not before it
        innerObserved = asyncInt.value

    proc laterCb(udata: pointer) {.gcsafe, raises: [].} =
      laterSeenBinding = asyncInt.value
      laterFired = true

    let fut = leaky()                 # synchronous run to `await outerWaiter`
    outerWaiter.complete()            # queues leaky's resume (nil-context capture)
    callSoon(laterCb, nil)            # queued behind the resume, same batch
    poll()

    check laterFired
    check laterSeenBinding == 0       # not leaked from leaky's still-open binder

    innerWaiter.complete()
    waitFor fut
    check innerObserved == 999
    check fut.finished()

  test "await inside withContext survives suspension and leaves ambient restored for a later same-batch callback":
    # Same suspend hazard as the withValue pin above, but through the public
    # currentContext()/withContext() bridge instead of the withValue binder.
    var boundCtx: AsyncContext
    asyncInt.withValue(999):
      boundCtx = currentContext()

    let outerWaiter = newFuture[void]("wc-leak-repro.outer")
    let innerWaiter = newFuture[void]("wc-leak-repro.inner")
    var innerObserved = -1
    var laterSeenBinding = -1
    var laterFired = false

    proc leaky(): Future[void] {.async: (raises: [Exception]).} =
      await outerWaiter               # captured with nil ambient context
      withContext(boundCtx):
        await innerWaiter             # suspends INSIDE withContext's body
        innerObserved = asyncInt.value

    proc laterCb(udata: pointer) {.gcsafe, raises: [].} =
      laterSeenBinding = asyncInt.value
      laterFired = true

    let fut = leaky()                 # synchronous run to `await outerWaiter`
    outerWaiter.complete()            # queues leaky's resume (nil-context capture)
    callSoon(laterCb, nil)            # queued behind the resume, same batch
    poll()

    check laterFired
    check laterSeenBinding == 0       # not leaked from leaky's still-open withContext

    innerWaiter.complete()
    waitFor fut
    check innerObserved == 999        # the withContext binding survived the suspend
    check fut.finished()

suite "contextvars: scheduling scenario pins":
  # Regression pins for scenarios not exercised by the earlier suites:
  # nested reentrancy, cross-thread isolation, capture on a finished
  # future, and stream-server transitive-fire-site coverage.

  test "nested waitFor inside a running callback observes its own binding and leaves the outer callback's context intact":
    # Only applies to default (non-strict) builds, where a nested waitFor
    # from a plain callback is legal and pumps the dispatcher reentrantly.
    # Must hold: inner work sees its own binding, not the outer's; the
    # outer's binding is exactly restored after the nested waitFor returns;
    # and a callback queued behind outerCb in the same batch sees an empty
    # context either way.
    when chronosStrictReentrancy:
      skip()
    else:
      var innerObserved = -1
      var outerAfterNested = -1
      var outerFired = false
      var laterSeenBinding = -1
      var laterFired = false

      proc innerWork(): Future[int] {.async: (raises: [CancelledError]).} =
        asyncInt.withValue(999):
          await sleepAsync(1.milliseconds)
          return asyncInt.value

      proc laterCb(udata: pointer) {.gcsafe, raises: [].} =
        laterSeenBinding = asyncInt.value
        laterFired = true

      proc outerCb(udata: pointer) {.gcsafe, raises: [].} =
        asyncInt.withValue(500):
          check asyncInt.value == 500
          try:
            innerObserved = waitFor(innerWork())
          except CancelledError:
            discard
          outerAfterNested = asyncInt.value
        outerFired = true

      callSoon(outerCb, nil)   # nil capture == nil ambient at fire -> fast arm
      callSoon(laterCb, nil)   # queued behind outerCb, same top-level batch
      poll()

      check outerFired
      check innerObserved == 999
      check outerAfterNested == 500
      check laterFired
      check laterSeenBinding == 0

  test "nested waitFor inside a running callback raises under chronosStrictReentrancy, leaving the outer callback's context intact":
    # Strict-mode counterpart above: preparePoll asserts before draining, so
    # the nested waitFor raises instead. The assert fires before any context
    # is touched, so the outer callback's binding must survive untouched.
    when chronosStrictReentrancy:
      var outerAfterRaise = -1
      var outerFired = false

      proc innerWork(): Future[int] {.async: (raises: [CancelledError]).} =
        asyncInt.withValue(999):
          await sleepAsync(1.milliseconds)
          return asyncInt.value

      proc outerCb(udata: pointer) {.gcsafe, raises: [].} =
        asyncInt.withValue(500):
          check asyncInt.value == 500
          expect(Defect):
            discard waitFor(innerWork())
          outerAfterRaise = asyncInt.value
        outerFired = true

      callSoon(outerCb, nil)   # nil capture == nil ambient at fire -> fast arm
      poll()

      check outerFired
      check outerAfterRaise == 500
    else:
      skip()

  test "two threads with independent dispatchers never observe each other's contextVar binding":
    # currentAsyncContext is threadvar-based, and each thread gets its own
    # dispatcher on first use, so binding the same contextVar to different
    # values on two threads must never cross.
    type ThreadArg = object
      boundValue: int
      resultPtr: ptr int
      readyPtr: ptr bool

    proc threadProc(arg: ThreadArg) {.thread, nimcall.} =
      asyncInt.withValue(arg.boundValue):
        proc work(): Future[int] {.async: (raises: [CancelledError]).} =
          await sleepAsync(1.milliseconds)
          return asyncInt.value
        arg.resultPtr[] = waitFor(work())
      arg.readyPtr[] = true

    var resultA, resultB: int
    var readyA, readyB: bool
    var threadA: Thread[ThreadArg]
    var threadB: Thread[ThreadArg]
    createThread(threadA, threadProc,
                 ThreadArg(boundValue: 111, resultPtr: addr resultA,
                           readyPtr: addr readyA))
    createThread(threadB, threadProc,
                 ThreadArg(boundValue: 222, resultPtr: addr resultB,
                           readyPtr: addr readyB))
    joinThreads(threadA, threadB)

    check readyA
    check readyB
    check resultA == 111
    check resultB == 222

  test "cross-thread callSoon() fires with an empty context and leaves the origin thread's own binding undisturbed":
    # A cross-thread post is drained via bareCallback (no context capture,
    # since a binding chain is thread-local memory that can't cross threads):
    # the callback must see the default value, and the origin thread's own
    # binding must be unchanged afterward.
    type CrossThreadResult = object
      seenBinding: int
      fired: bool

    proc crossThreadCb(udata: pointer) {.nimcall, gcsafe, raises: [].} =
      let r = cast[ptr CrossThreadResult](udata)
      r.seenBinding = asyncInt.value
      r.fired = true

    type ThreadArg = (DispatcherHandle, ptr CrossThreadResult)
    proc threadProc(arg: ThreadArg) {.thread, nimcall.} =
      callSoon(arg[0], crossThreadCb, cast[pointer](arg[1]))

    var res: CrossThreadResult
    let disp = getThreadDispatcher()

    asyncInt.withValue(555):
      var thread: Thread[ThreadArg]
      createThread(thread, threadProc, (disp.handle(), addr res))
      # Bounded-retry rather than a single poll(): a leftover non-empty
      # queue from a prior test would otherwise race this call against
      # however long the new thread takes to post.
      #
      # Each iteration also arms a cheap no-op wakeup timer first: an
      # otherwise-idle poll() can block on an infinite OS wait, which
      # would turn a real cross-thread-wake engine failure into a test
      # hang instead of a bounded failure below.
      let deadline = Moment.now() + 5.seconds
      while not res.fired and Moment.now() < deadline:
        discard setTimer(Moment.now() + 100.milliseconds,
                         proc(_: pointer) {.gcsafe, raises: [].} = discard)
        poll()

      check res.fired
      check res.seenBinding == 0     # DEFAULT - not leaked from the origin's 555
      check asyncInt.value == 555        # origin thread's own binding undisturbed
      joinThreads(thread)

    check asyncInt.value == 0

  test "addCallback on an already-finished future captures the caller's binding, not the completer's":
    # An already-finished future's addCallback takes the immediate-dispatch
    # branch: only the caller's binding at addCallback-time is captured.
    var seenBinding = -1
    var fired = false

    let fut = newFuture[void]("already-finished")
    asyncInt.withValue(111):
      fut.complete()               # completed under binding 111

    check fut.finished()

    asyncInt.withValue(222):
      fut.addCallback(proc(udata: pointer) {.gcsafe, raises: [].} =
        seenBinding = asyncInt.value
        fired = true
      )

    poll()
    check fired
    check seenBinding == 222       # the adder's binding, not the completer's

  test "stream server handler observes the context bound at start()-time registration, not creation-time or connection-time":
    # start() is what actually registers the accept callback (and captures
    # its context); createStreamServer() only builds the object, and the
    # handler is asyncSpawn'ed transitively from the accept callback's own
    # frame. creation/registration/connection are bound to different values
    # here to make a wrong capture site observable.
    var seenBinding = -1
    var handlerFired = false
    let handlerDone = newFuture[void]("stream-handler-done")

    proc handler(server: StreamServer,
                 transp: StreamTransport) {.async: (raises: []).} =
      seenBinding = asyncInt.value
      handlerFired = true
      transp.close()
      handlerDone.complete()

    let ta = initTAddress("127.0.0.1:0")
    var server: StreamServer
    asyncInt.withValue(111):
      server = createStreamServer(ta, handler, {ReuseAddr})  # creation-time: 111

    asyncInt.withValue(222):
      server.start()                                         # registration-time: 222

    proc driver(): Future[void] {.async: (raises: [Exception]).} =
      asyncInt.withValue(333):                                     # connection-time: 333
        var transp = await connect(server.localAddress())
        await handlerDone.wait(5.seconds)
        transp.close()

    waitFor(driver())

    check handlerFired
    check seenBinding == 222       # start()-time registration binding

    server.stop()
    server.close()
    waitFor(server.join())

suite "contextvars: must-bind async propagation":

  test "must-bind binding propagates across await exactly like a defaulted var":
    # Must-bind arms use the same binder/dispatcher plumbing as asyncInt/
    # asyncStr; only the reader differs (raise vs. default on a miss).
    proc work(): Future[int] {.async: (raises: [CancelledError]).} =
      check asyncReq.value == 17
      await sleepAsync(1.milliseconds)
      check asyncReq.value == 17
      return asyncReq.value

    proc driver(): Future[int] {.async: (raises: [CancelledError]).} =
      asyncReq.withValue(17):
        return await work()

    check waitFor(driver()) == 17

  test "must-bind read with no binder anywhere, including across await, raises":
    proc work(): Future[void] {.async: (raises: [CancelledError]).} =
      await sleepAsync(1.milliseconds)
      expect(UnboundContextVarDefect):
        discard asyncReq.value

    waitFor(work())


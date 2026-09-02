#                Chronos Test Suite
#            (c) Copyright 2024-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)
import ../chronos/unittest2/asynctests

{.used.}

# A dispatcher is thread local, so every case here runs on its own thread - the
# rest of the suite still needs the one belonging to the main thread, and a
# regression in the code under test would otherwise close it.

type
  LifecycleResult = object
    noDispatcherIsNoop: bool
    closeDidNotCreateDispatcher: bool
    closeAfterWork: bool
    reusableAfterClose: bool
    secondCloseIsNoop: bool

  LifecycleResultPtr = ptr LifecycleResult

  PendingResult = object
    callbackDropped: bool
    closedCleanly: bool

  PendingResultPtr = ptr PendingResult

  RegisteredResult = object
    defectRaised: bool

  RegisteredResultPtr = ptr RegisteredResult

proc closedCleanly(): bool =
  ## `closeThreadDispatcher` returns a diagnostic only when a resource could not
  ## be released, so an empty `Opt` is the success case.
  closeThreadDispatcher().isNone()

proc tick() {.async: (raises: []).} =
  try:
    await sleepAsync(1.milliseconds)
  except CancelledError:
    discard

proc lifecycleThread(retval: LifecycleResultPtr) {.thread, nimcall.} =
  # This thread has never used chronos, so it has no dispatcher yet - closing
  # must be a no-op rather than creating one just to tear it down.
  retval[].noDispatcherIsNoop = closedCleanly()

  try:
    # `setThreadDispatcher` raises when a dispatcher is already installed, so
    # this catches a close above that created one.
    setThreadDispatcher(newDispatcher())
    retval[].closeDidNotCreateDispatcher = true
  except Defect:
    retval[].closeDidNotCreateDispatcher = false

  waitFor tick()
  retval[].closeAfterWork = closedCleanly()

  # `gDisp` was reset, so this runs on a brand new dispatcher - polling the
  # closed one would fail on its released selector or completion port.
  waitFor tick()
  retval[].reusableAfterClose = closedCleanly()

  retval[].secondCloseIsNoop = closedCleanly()

proc pendingCallback(udata: pointer) {.gcsafe.} =
  cast[PendingResultPtr](udata)[].callbackDropped = false

proc pendingThread(retval: PendingResultPtr) {.thread, nimcall.} =
  retval[].callbackDropped = true
  callSoon(pendingCallback, retval)

  # Callbacks, timers and idlers are pure-nim state: closing simply drops them,
  # so no diagnostic and no `Defect` - only OS state is worth complaining about.
  retval[].closedCleanly = closedCleanly()

proc registeredThread(retval: RegisteredResultPtr) {.thread, nimcall.} =
  let fd = createAsyncSocket(Domain.AF_INET, SockType.SOCK_STREAM,
                             Protocol.IPPROTO_TCP)
  doAssert fd != asyncInvalidSocket

  # The socket is deliberately left registered - closing the dispatcher would
  # orphan it, so it must be reported rather than silently dropped.
  try:
    discard closeThreadDispatcher()
    retval[].defectRaised = false
  except Defect:
    retval[].defectRaised = true

suite "Dispatcher test suite":
  test "closeThreadDispatcher() lifecycle":
    var
      retval = LifecycleResult()
      thread: Thread[LifecycleResultPtr]

    createThread(thread, lifecycleThread, addr retval)
    joinThreads(thread)

    check:
      retval.noDispatcherIsNoop == true
      retval.closeDidNotCreateDispatcher == true
      retval.closeAfterWork == true
      retval.reusableAfterClose == true
      retval.secondCloseIsNoop == true

  test "closeThreadDispatcher() drops pending callbacks":
    var
      retval = PendingResult()
      thread: Thread[PendingResultPtr]

    createThread(thread, pendingThread, addr retval)
    joinThreads(thread)

    check:
      retval.callbackDropped == true
      retval.closedCleanly == true

  when not defined(windows):
    # On windows the equivalent check is the completion queue, which cannot be
    # left non-empty without an operation genuinely in flight.
    test "closeThreadDispatcher() refuses to close with descriptors registered":
      var
        retval = RegisteredResult()
        thread: Thread[RegisteredResultPtr]

      createThread(thread, registeredThread, addr retval)
      joinThreads(thread)

      check retval.defectRaised == true

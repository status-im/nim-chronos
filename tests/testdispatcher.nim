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

  BusyResult = object
    defectRaised: bool
    callbackRan: bool
    closeAfterDrain: bool

  BusyResultPtr = ptr BusyResult

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

proc busyCallback(udata: pointer) {.gcsafe.} =
  cast[BusyResultPtr](udata)[].callbackRan = true

proc busyThread(retval: BusyResultPtr) {.thread, nimcall.} =
  callSoon(busyCallback, retval)

  try:
    discard closeThreadDispatcher()
  except Defect:
    retval[].defectRaised = true

  # The check happens before the dispatcher is detached, so the thread keeps a
  # working dispatcher and the queued callback still runs. A timer is awaited
  # rather than polling bare, so that a regression that detaches the dispatcher
  # fails the test instead of blocking forever on an empty queue.
  waitFor tick()

  retval[].closeAfterDrain = closedCleanly()

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

  test "closeThreadDispatcher() refuses to close a busy dispatcher":
    var
      retval = BusyResult()
      thread: Thread[BusyResultPtr]

    createThread(thread, busyThread, addr retval)
    joinThreads(thread)

    check:
      retval.defectRaised == true
      retval.callbackRan == true
      retval.closeAfterDrain == true

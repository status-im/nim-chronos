#                Chronos Test Suite
#            (c) Copyright 2018-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

## The automatic cross-thread construction guard
## (chronos/contextvars.nim, `newContextVar`/`newRequiredContextVar`'s
## unconditional thread-generation check) — split out like
## tests/testcontextvarslock.nim and tests/testcontextvarsleakguard.nim,
## and run alongside them from tests/testcontextvarsstandalone.nim:
## isolated per-process in CI via the driver's orchestrate mode, so it no
## longer matters whether this file's construction runs inside a
## dispatcher a prior suite left unsound, or ahead of the lock suite.
## Import order among the three only matters for the driver's no-args
## single-process mode, where this file must still run between the
## other two for the same reasons.
##
## Actually constructing a context variable key from a second thread is
## a genuine `--mm:refc` GC hazard (see docs/src/contextvars.md,
## "Registry and key lifetime") — the guard this file tests is what
## turns that hazard into a caught `AssertionDefect` instead, and it now
## runs in every build, not only under `chronosDebug`.

import unittest2
import ../chronos/contextvars

{.used.}

const contextVarsCrossThreadSuiteName* =
  "contextvars (raw key): cross-thread construction detection"

suite contextVarsCrossThreadSuiteName:

  test "newContextVar on a second thread trips the automatic thread-generation guard; registry stays intact":
    # Construct on the main thread first: the guard records whichever
    # thread constructs first as "the" thread. In the driver's orchestrate
    # mode this suite runs alone in its own child process, so without
    # this seed the child thread below would race the main thread for
    # that role instead of reliably exercising it as the violator.
    discard newContextVar("crossThreadMainThreadSeed", 0)

    var fired = false

    proc constructOnOtherThread(firedAddr: ptr bool) {.thread, nimcall.} =
      try:
        {.cast(gcsafe).}:
          discard newContextVar("crossThreadKey", 1)
      except AssertionDefect:
        firedAddr[] = true

    var otherThread: Thread[ptr bool]
    createThread(otherThread, constructOnOtherThread, addr fired)
    joinThread(otherThread)

    check fired

    # The failed cross-thread construction must not have reached the
    # registry mutation: a subsequent main-thread construction still
    # succeeds, which would not be reliable if the guard fired only
    # after registerVar() already ran.
    let k = newContextVar("afterCrossThreadAttempt", 2)
    check k.value == 2

  test "two sequential child threads each trip the guard, not only the first":
    # Pins that the guard keeps firing for every later violating thread,
    # not just the one that happens to run first — both threads here are
    # seeded against the same main-thread recorder from above, so this
    # is repeated-firing coverage, not a pin on recorder identity itself
    # (see tests/testcontextvarsrecorderdeath.nim for the recycled-OS-id
    # hazard, which needs a dead recording thread to exercise).
    discard newContextVar("sequentialThreadsMainSeed", 0)

    proc constructOnChildThread(firedAddr: ptr bool) {.thread, nimcall.} =
      try:
        {.cast(gcsafe).}:
          discard newContextVar("sequentialThreadsKey", 1)
      except AssertionDefect:
        firedAddr[] = true

    var firedA = false
    var threadA: Thread[ptr bool]
    createThread(threadA, constructOnChildThread, addr firedA)
    joinThread(threadA)

    var firedB = false
    var threadB: Thread[ptr bool]
    createThread(threadB, constructOnChildThread, addr firedB)
    joinThread(threadB)

    check firedA
    check firedB

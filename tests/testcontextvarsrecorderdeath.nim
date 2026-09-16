#                Chronos Test Suite
#            (c) Copyright 2018-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

## The automatic cross-thread construction guard
## (chronos/contextvars.nim, `newContextVar`/`newRequiredContextVar`'s
## unconditional thread-generation check) against a dead recording
## thread — split out like tests/testcontextvarslock.nim and run
## alongside it from tests/testcontextvarsstandalone.nim, for the same
## per-process isolation reasons documented there.
##
## OS thread-id recycling cannot be forced deterministically from
## userspace: there is no portable way to make a new thread receive a
## specific exited thread's id. This suite instead pins the state a
## recycled id could falsely satisfy — the recording thread has
## already exited — which is exactly where a generation identity must
## keep refusing and an OS-TID identity could wrongly accept a new
## thread. Runs in every build, not only under `chronosDebug`: the
## guard it tests is unconditional (see chronos/contextvars.nim).
##
## Adaptive because the recording slot is process-global and other
## suites may have already claimed it before this one runs (see the
## two branches below).

import unittest2
import ../chronos/contextvars

{.used.}

const contextVarsRecorderDeathSuiteName* =
  "contextvars (raw key): guard against a dead recording thread"

suite contextVarsRecorderDeathSuiteName:

  test "guard still trips once the recording thread has exited":
    type AttemptResult = tuple[constructed, tripped: bool]

    proc constructOnThread(resultAddr: ptr AttemptResult) {.thread, nimcall.} =
      try:
        {.cast(gcsafe).}:
          discard newContextVar("recorderDeathKey", 0)
        resultAddr[] = (constructed: true, tripped: false)
      except AssertionDefect:
        resultAddr[] = (constructed: false, tripped: true)

    var resultA: AttemptResult
    var threadA: Thread[ptr AttemptResult]
    createThread(threadA, constructOnThread, addr resultA)
    joinThread(threadA)

    if resultA.constructed:
      # This process had no prior construction: thread A is the
      # recorder, and by the time control returns here it has already
      # exited — the exact state OS-TID recycling exploits, where a
      # later thread reusing A's id would wrongly read as "the"
      # recorder. A generation identity keeps refusing regardless, so
      # both a main-thread and a fresh worker-thread construction must
      # still trip the guard; this is the real pin.
      expect AssertionDefect:
        discard newContextVar("recorderDeathAfterMain", 1)

      var resultB: AttemptResult
      var threadB: Thread[ptr AttemptResult]
      createThread(threadB, constructOnThread, addr resultB)
      joinThread(threadB)
      check not resultB.constructed
      check resultB.tripped
    else:
      # A prior suite sharing this process (leak-guard or cross-thread,
      # in the driver's legacy no-args order) already recorded the main
      # thread, so thread A tripped instead of becoming the recorder.
      # The recorder-death scenario is unreachable in this process;
      # degrade to consistency checks — the recorder is still the main
      # thread, so a main-thread construction still succeeds.
      check resultA.tripped
      let k = newContextVar("recorderDeathMainStillRecorder", 2)
      check k.value == 2

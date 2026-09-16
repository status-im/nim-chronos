#                Chronos Test Suite
#            (c) Copyright 2018-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

## Driver for the contextvars suites that cannot share a process with
## tests/testall.nim, or with each other:
##
## - tests/testcontextvarsleakguard.nim lets an AssertionDefect escape
##   poll() under chronosDebug, leaving the dispatcher unsound for any
##   suite sharing that binary afterward.
## - tests/testcontextvarscrossthread.nim constructs a key from a second
##   thread and must not run after the lock is engaged, since the lock
##   makes every construction in the process assert, including its own
##   control construction on the main thread.
## - tests/testcontextvarsrecorderdeath.nim's full scenario needs a
##   process where no key has been constructed yet, so its worker thread
##   is the one that records; it must run before the lock is engaged for
##   the same reason as the cross-thread suite, and after the
##   leak-guard/cross-thread suites so their main-thread construction
##   has already claimed the recorder in this mode, exercising its
##   degraded branch instead — which orchestrate mode's per-suite
##   process avoids, giving it the full scenario there.
## - tests/testcontextvarslock.nim's chronosDebug construction lock is
##   one-way for the process's lifetime: once engaged, every later
##   `newContextVar`/`newRequiredContextVar` call in the process asserts.
##
## Three invocation modes, selected by argv:
##
## - No arguments: all four suites run in one process, in the import
##   order below (dev convenience). Import order is load-bearing only in
##   this mode.
## - `orchestrate`: this process becomes a parent that spawns itself once
##   per suite, each child given `"<suite name>::*"` as its sole argument
##   — a unittest2 filter that runs only that suite — so isolation is by
##   construction (separate processes) rather than by import order.
##   `orchestrate` also doubles as a unittest2 filter in the parent's own
##   process: no test is named "orchestrate" and it contains neither `::`
##   nor `*`, so it matches nothing, and the parent's own exit-time test
##   run is an empty no-op that leaves the aggregate exit code to the
##   `quit` call below.
## - Any other argument: passed through to unittest2 unchanged, e.g. to
##   run a single suite directly (`<binary> "<suite name>::*"`).
import std/[os, osproc]
import ./testcontextvarsleakguard
import ./testcontextvarscrossthread
import ./testcontextvarsrecorderdeath
import ./testcontextvarslock

const orchestrateArg = "orchestrate"

if paramCount() >= 1 and paramStr(1) == orchestrateArg:
  let suiteNames = [
    contextVarsLeakGuardSuiteName,
    contextVarsCrossThreadSuiteName,
    contextVarsRecorderDeathSuiteName,
    contextVarsLockSuiteName,
  ]
  var allOk = true
  for suiteName in suiteNames:
    let child = startProcess(
      getAppFilename(), args = [suiteName & "::*"], options = {poParentStreams}
    )
    let code = waitForExit(child)
    close(child)
    echo "[testcontextvarsstandalone] ", suiteName, ": exit ", code
    if code != 0:
      allOk = false
  quit(if allOk: 0 else: 1)

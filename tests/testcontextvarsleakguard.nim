#                Chronos Test Suite
#            (c) Copyright 2018-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

## This file pins chronos's chronosDebug context-corruption detection net
## layer by layer: `withRestoredContext`'s identity-arm postcondition
## assert (chronos/futures.nim, ~231-236), the restore arm's unconditional
## `finally` self-heal (same file, ~237-240), and the cross-batch guard in
## `processCallbacks` (chronos/internal/asyncengine.nim, ~262-267).
##
## The cross-batch guard is pinned indirectly, through Nim's finally-unwind
## replacement rather than through anything the guard alone detects: a
## callback that corrupts `currentAsyncContext` through the identity arm
## fails both the identity arm's own postcondition assert and the batch
## guard's assert, since both compare the same corrupted value against the
## same pre-corruption snapshot. The batch guard's assert runs later, in
## the `finally` unwinding the identity arm's already-propagating Defect,
## and its own failure there replaces that Defect as the one a caller of
## `poll()` observes. The surfaced message therefore pins the batch guard's
## presence: delete or weaken it and the message flips to the identity
## arm's, failing that case. It is not proof the batch guard independently
## catches anything the identity arm misses - on every current dispatch
## path the identity arm's own postcondition already fires first, so the
## batch guard remains defense-in-depth against a future dispatch path that
## bypasses `withRestoredContext`, not a second independent detector today.
##
## Split out like tests/testcontextvarslock.nim rather than folded into
## testall.nim: the identity-arm and cross-batch cases leave an escaped
## AssertionDefect (and a stray, disconnected context node) behind, which
## would leave the dispatcher unsound for every other suite sharing that
## binary. In CI this file is isolated per-process via
## tests/testcontextvarsstandalone.nim's orchestrate mode; sharing a
## binary with another suite is only possible in that driver's no-args
## single-process mode, where this file must still run first for the
## same reason. The net itself only exists under `chronosDebug`, so
## every test here skips cleanly without it.

import std/strutils
import unittest2
import ../chronos/contextvars
import ../chronos/internal/contextnode
  # Whitebox: the identity-arm case constructs a bare `ContextNodeBase`
  # directly, which `chronos/contextvars.nim` does not expose.
import ../chronos/futures
  # Whitebox: `currentAsyncContext` is the threadvar the net inspects, and
  # `withRestoredContext` is the template under test; neither is reachable
  # through `import chronos`.
import ../chronos
  # Brings in `callSoon`/`poll`.

{.used.}

var leakGuardVarKey: ContextVar[int]
var leakGuardVarConstructed = false

proc leakGuardVar(): ContextVar[int] {.gcsafe.} =
  ## Constructed on first call rather than via a top-level
  ## `{.contextVar.}` `let`: this suite is linked into the same binary
  ## as tests/testcontextvarsrecorderdeath.nim (see
  ## tests/testcontextvarsstandalone.nim), and a top-level construction
  ## runs during module init, before unittest2 filters which suite's
  ## tests actually execute — claiming the process-global recorder slot
  ## in every child the orchestrate driver spawns, including
  ## recorderdeath's, and leaving it no process in which to observe an
  ## unclaimed slot. Deferring construction into the first test that
  ## needs it keeps this suite's own tests unaffected while leaving the
  ## slot free in any process where none of its tests are selected.
  {.cast(gcsafe).}:
    if not leakGuardVarConstructed:
      leakGuardVarKey = newContextVar("leakGuardVar", 0, private = true)
      leakGuardVarConstructed = true
    leakGuardVarKey

const contextVarsLeakGuardSuiteName* =
  "contextvars: chronosDebug context-corruption detection net"

suite contextVarsLeakGuardSuiteName:

  test "control: a callback that binds and unwinds through withValue trips nothing":
    when defined(chronosDebug):
      var ran = false
      proc goodCb(udata: pointer) {.gcsafe, raises: [].} =
        leakGuardVar().withValue(1):
          discard leakGuardVar().value
        ran = true

      callSoon(goodCb, nil)
      poll()
      check ran
    else:
      skip()

  test "identity-arm layer: withRestoredContext's postcondition assert fires when its body corrupts currentAsyncContext":
    when defined(chronosDebug):
      # Called directly rather than through callSoon+poll(): processCallbacks'
      # own chronosDebug batch guard wraps every dispatch in a try/finally
      # whose doAssert, given this same corruption, also fails - and when a
      # second doAssert fails while the first is still unwinding, Nim's
      # finally semantics let the second's Defect replace the first. Routed
      # through poll(), this case would therefore only ever surface the
      # batch guard's message, not the identity arm's - confirmed empirically
      # before writing this test. Calling withRestoredContext directly is
      # the only way to observe the identity arm's own assert in isolation.
      let ambient = currentAsyncContext
      var caught = false
      try:
        withRestoredContext(ambient):
          currentAsyncContext = ContextNodeBase()
      except AssertionDefect as e:
        caught = true
        check "identity arm violated" in e.msg
      check caught
      currentAsyncContext = ambient
    else:
      skip()

  test "restore-arm layer: a captured-context callback that corrupts currentAsyncContext is healed by the finally, no Defect escapes":
    when defined(chronosDebug):
      let preAmbient = currentAsyncContext
      var ran = false
      proc corruptingRestoreCb(udata: pointer) {.gcsafe, raises: [].} =
        currentAsyncContext = ContextNodeBase()
        ran = true

      leakGuardVar().withValue(2):
        # Scheduled inside withValue so capturingCallback embeds a real,
        # non-nil chain - the restore arm only runs when the captured
        # context differs from the ambient ready to receive it.
        callSoon(corruptingRestoreCb, nil)

      poll()
      check ran
      check currentAsyncContext == preAmbient
    else:
      skip()

  test "cross-batch guard layer: a callback captured at nil ambient context that corrupts currentAsyncContext surfaces the batch guard's message via finally-replacement":
    when defined(chronosDebug):
      # Ordered last and restores currentAsyncContext itself: this case
      # leaves the ambient corrupted for the duration of the escaping
      # Defect (neither failed assert writes anything), so it must not run
      # ahead of a case that assumes a clean ambient.
      let ambient = currentAsyncContext
      proc corruptingCb(udata: pointer) {.gcsafe, raises: [].} =
        currentAsyncContext = ContextNodeBase()

      callSoon(corruptingCb, nil)
      var caught = false
      try:
        poll()
      except AssertionDefect as e:
        caught = true
        check "context leaked across a callback batch" in e.msg
      check caught
      currentAsyncContext = ambient
    else:
      skip()

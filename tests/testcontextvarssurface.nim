#                Chronos Test Suite
#            (c) Copyright 2018-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

## Public-surface guardrail for continuation-local storage.
##
## Verifies that `import chronos` plus `import chronos/contextvars`
## expose only the intended public API — no dispatcher-internal or
## key-runtime-internal primitives. Kept separate from
## testcontextvarsguardrails.nim, whose checks pin representation/
## identity properties (using the same public symbols) rather than
## surface reachability.

import unittest2
import ../chronos
import ../chronos/contextvars
  # Looks unused to the compiler (declared() doesn't mark usage) but is
  # load-bearing for every assert below.

{.used.}

# --- Required public surface -------------------------------------------------

static:
  doAssert declared(ContextVar),       "ContextVar[T] type must be public"
  doAssert declared(newContextVar),    "newContextVar must be public"
  doAssert declared(newRequiredContextVar),
    "newRequiredContextVar (the must-bind constructor) must be public"
  when (NimMajor, NimMinor) >= (2, 0):
    # The `{.contextVar.}` pragma itself is 2.x-only — macro pragmas on
    # `let`/`var` sections don't exist in the 1.6 compiler — so this probe
    # doesn't even parse-expand on 1.6.
    doAssert declared(contextVar),     "the {.contextVar.} pragma macro must be public"
  doAssert declared(AsyncContext),     "AsyncContext type must be public"
  doAssert declared(currentContext),   "currentContext proc must be public"
  doAssert declared(withContext),      "withContext template must be public"
  doAssert declared(dumpContext),      "dumpContext proc must be public"
  doAssert declared(ContextVarEntry),  "ContextVarEntry type must be public"
  doAssert declared(UnboundContextVarDefect),
    "UnboundContextVarDefect must be public — it's the type a caller " &
    "needs to name to catch an unbound must-bind read"
  doAssert UnboundContextVarDefect is Defect,
    "UnboundContextVarDefect must be a Defect (not a CatchableError) " &
    "— see docs/src/contextvars.md, 'Required variables'"

let surfaceProbeKey = newContextVar("surfaceProbeKey", 0)

static:
  doAssert compiles(newContextVar("x", 0)),
    "newContextVar[T](name, default, private = false) must be public and callable"
  doAssert compiles(newRequiredContextVar[int]("x")),
    "newRequiredContextVar[T](name, private = false) must be public " &
    "and callable"
  doAssert compiles(surfaceProbeKey.value),
    "ContextVar[T].value must be public and callable"
  doAssert compiles(currentContext()[surfaceProbeKey]),
    "`[]`(AsyncContext, ContextVar[T]): T must be public and callable"
  doAssert compiles((block:
    surfaceProbeKey.withValue(1):
      discard)),
    "ContextVar[T].withValue must be public and callable"
  doAssert compiles(surfaceProbeKey in currentContext()),
    "`contains`(AsyncContext, ContextVar[T]): bool (`cv in ctx`) must " &
    "be public and callable"
  doAssert compiles(surfaceProbeKey.isBound),
    "ContextVar[T].isBound must be public and callable"
  doAssert compiles(hash(surfaceProbeKey)),
    "hash(cv: ContextVarBase): Hash must be public and callable, making " &
    "ContextVar[T] usable as a Table/HashSet key"
  doAssert compiles(surfaceProbeKey.name),
    "ContextVar[T].name must be public and callable"
  doAssert compiles(currentContext() == currentContext()),
    "`==`(a, b: AsyncContext): bool must be public and callable"
  doAssert compiles(hash(currentContext())),
    "hash(ctx: AsyncContext): Hash must be public and callable"
  doAssert compiles($(currentContext())),
    "`$`(ctx: AsyncContext): string must be public and callable"

when (NimMajor, NimMinor) >= (2, 0):
  # A must-bind key declared via the pragma (`var name* {.contextVar.}: T`,
  # no default) must be legal syntax; this probe (module-scope, so it runs
  # regardless of which test below executes) pins that the surface accepts
  # it. 2.x-only, same as the `declared(contextVar)` probe above — the
  # pragma doesn't even parse-expand on 1.6.
  var surfaceMustBind* {.contextVar.}: int

# --- Deliberately absent surface ---------------------------------------------
#
# An imperative token API (set/reset) is deliberately not part of the
# frozen surface — withValue and withContext/currentContext cover every
# known need. (`reset` itself can't be negatively asserted here:
# system.reset makes declared(reset) true in every module — see
# testcontextvarsguardrails.nim's guardrail 4 for the call-shape probes
# that work around this.)
when declared(AsyncContextToken):
  {.error: "`AsyncContextToken` must not be public: the imperative " &
           "token API was deliberately dropped from the frozen surface. " &
           "See the comment above this check.".}

# --- Anti-leak: key-runtime internals must not be reachable -----------------
#
# `ContextNodeBase`'s bare name must NOT be reachable through this
# surface: `AsyncContext` wraps its chain head in a field private to
# chronos/contextvars.nim (see that module's top-of-file comment and
# docs/src/contextvars.md, "Implementation"), so nothing public needs to
# name the base chain-node type anymore — unlike the old macro design,
# which needed it nameable for its own reasons. Whitebox probes of
# `ContextNodeBase` itself (its `next` field's privacy, the forgery
# guardrail) live in tests/testcontextvarsguardrails.nim, which imports
# chronos/internal/contextnode directly rather than going through this
# public surface.

when declared(ContextNodeBase):
  {.error: "`ContextNodeBase` must not leak through the public API — " &
           "`AsyncContext` wraps it in a private field, so no public " &
           "symbol needs to name the base chain-node type anymore. See " &
           "chronos/contextvars.nim's top-of-file comment and " &
           "docs/src/contextvars.md, \"Implementation\".".}

when declared(nextNode):
  {.error: "`nextNode` (chain traversal getter) must not leak through " &
           "the public API — it lives in chronos/internal/contextnode.nim " &
           "for chronos/contextvars.nim's own walkers only.".}

when declared(linkNode):
  {.error: "`linkNode` (chain link writer) must not leak through the " &
           "public API — a reachable link primitive would reopen chain " &
           "mutation from user code.".}

when declared(ContextNode):
  {.error: "`ContextNode[T]` must not leak through the public API — no " &
           "nameable per-key chain-node type exists anymore (the old " &
           "macro design's per-arm nameable slot subtype is exactly what " &
           "made the old cycle attack representable in the first place); " &
           "chronos/contextvars.nim builds and walks nodes from its own " &
           "definitions only.".}

when declared(ContextNodeKeyed):
  {.error: "`ContextNodeKeyed` must not leak through the public API " &
           "either — same reasoning as `ContextNode[T]` above.".}

when declared(currentAsyncContext):
  {.error: "`currentAsyncContext` threadvar must not leak through the " &
           "public API. Users must use `withContext` only.".}

when declared(registeredVars):
  {.error: "`registeredVars` (the registry-walking iterator) must not " &
           "leak through the public API — analogous to the old design's " &
           "`contextVarRegistry`, it is invoked by `dumpContext` only; " &
           "`dumpContext`/`ContextVarEntry` are the public surface " &
           "over the registry.".}

static:
  doAssert not compiles((let k = newContextVar("surfaceDefault", 0); discard k.default)),
    "ContextVarBase's `default` field must not be reachable at all " &
    "outside chronos/contextvars.nim — it's on the RFC's public-surface " &
    "Forbidden list."
  doAssert not compiles((let k = newContextVar("surfaceRender", 0); discard k.render)),
    "ContextVarBase's `render` field (the dumpContext render hook) must " &
    "not be reachable at all outside chronos/contextvars.nim."
  doAssert not compiles((let k = newContextVar("surfaceReg", 0); discard k.nextRegistered)),
    "ContextVarBase's `nextRegistered` field (the intrusive registry " &
    "link) must not be reachable at all outside chronos/contextvars.nim."

when declared(capturingCallback):
  {.error: "`capturingCallback` must not leak through the public API. It lives " &
           "in chronos/futures.nim, excluded from `asyncengine.nim`'s " &
           "`export futures`, and is used by dispatcher code only.".}

when declared(bareCallback):
  {.error: "`bareCallback` must not leak through the public API.".}

when declared(contextCallback):
  {.error: "`contextCallback` must not leak through the public API. It " &
           "lives in chronos/futures.nim, excluded from `asyncengine.nim`'s " &
           "`export futures`, and is used by Windows IOCP completion " &
           "dispatch (`poll()`) only.".}

when declared(capturingCancelCallback):
  {.error: "`capturingCancelCallback` must not leak through the public API. It " &
           "lives in chronos/futures.nim, excluded from `asyncengine.nim`'s " &
           "`export futures`, and is used by `cancelCallback=` only — " &
           "otherwise plain `import chronos` code could manufacture an " &
           "`InternalCancelCallback` and assign it directly to " &
           "`internalCancelcb`, bypassing `cancelCallback=`'s discipline.".}

when declared(withRestoredContext):
  {.error: "`withRestoredContext` must not leak through the public API. " &
           "It lives in chronos/futures.nim (placed there because " &
           "`asyncengine.nim` cannot name `ContextNodeBase` for its " &
           "typed parameter), excluded from `asyncengine.nim`'s `export " &
           "futures`, and is used by the dispatcher's fire sites only.".}

when declared(pinContext):
  {.error: "`pinContext` must not leak through the public API. It lives " &
           "in chronos/futures.nim beside `withRestoredContext`, excluded " &
           "from `asyncengine.nim`'s `export futures`, and is used by " &
           "continuation-pump resume guards only.".}

when declared(captureContextInto):
  {.error: "`captureContextInto` must not leak through the public API. " &
           "It lives in chronos/futures.nim (the shared " &
           "construction-discipline template), excluded from " &
           "`asyncengine.nim`'s `export futures`, and is used by " &
           "`capturingCallback`/`capturingCancelCallback` only — a reachable capture " &
           "primitive would let plain `import chronos` code write " &
           "`currentAsyncContext` into arbitrary fields, bypassing the " &
           "construction discipline entirely.".}

# --- Dispatcher queue fields and their backing type ---------------------------
#
# DispatcherBase.callbacks/idlers/ticks (backed by CallbackQueue) must
# stay private to chronos/internal/asyncengine.nim; only
# getThreadDispatcher() itself is public.

static:
  doAssert not compiles(getThreadDispatcher().callbacks),
    "`DispatcherBase.callbacks` must not be readable via `import chronos` " &
    "— it is private to chronos/internal/asyncengine.nim."
  doAssert not compiles(getThreadDispatcher().idlers),
    "`DispatcherBase.idlers` must not be readable via `import chronos` " &
    "— it is private to chronos/internal/asyncengine.nim."
  doAssert not compiles(getThreadDispatcher().ticks),
    "`DispatcherBase.ticks` must not be readable via `import chronos` " &
    "— it is private to chronos/internal/asyncengine.nim."

when declared(CallbackQueue):
  {.error: "`CallbackQueue` must not leak through the " &
           "public API. It backs the privatized `callbacks`/`idlers`/" &
           "`ticks` dispatcher fields and has no public-facing purpose " &
           "— unlike `std/deques.Deque` before it, which stayed exported " &
           "only because the fields it backed were themselves public.".}

# `context` is InternalAsyncCallback's (and InternalCancelCallback's)
# read-only getter, used by the dispatcher's fireWithContext/
# fireCancelCallback. Excluded from asyncengine.nim's `export futures`
# by name, which covers both overloads at once.
static:
  doAssert not compiles(default(AsyncCallback).context),
    "`context` getter must not leak through the public API. It lives " &
    "in chronos/futures.nim, excluded from `asyncengine.nim`'s " &
    "`export futures`, and is used by the dispatcher's " &
    "`fireWithContext` only."
  doAssert not compiles(default(InternalCancelCallback).context),
    "`InternalCancelCallback`'s `context` getter must not leak through " &
    "the public API either — same exclusion, same reasoning, used by " &
    "the dispatcher's `fireCancelCallback` only."

# --- Windows: CompletionData.context must not be reachable -------------------
#
# A public field here would make `ContextNodeBase` structurally
# reachable via plain `import chronos` on Windows, same class of leak
# as the `AsyncCallback`/`InternalCancelCallback` `context` getters
# above. Compiled only on the `--os:windows --compileOnly` CI leg.

when defined(windows):
  static:
    doAssert not compiles((var cd: CompletionData; discard cd.context)),
      "`CompletionData.context` must not be readable via `import " &
      "chronos` — it is private to chronos/internal/asyncengine.nim, " &
      "reached only through the `captureContextInto(var CompletionData)` " &
      "overload (write) and same-module code (read)."
    doAssert not compiles((var cd: CompletionData; cd.context = nil)),
      "`CompletionData.context` must not be writable via `import " &
      "chronos` either."

# --- A trivial runtime assertion to keep the test file unittest-recognized ---

suite "contextvars: public surface":
  test "compile-time guardrails passed":
    # The static checks above are the real guardrails; this just
    # gives the runner a green dot.
    check true

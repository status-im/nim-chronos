#
#                     Chronos
#
#  (c) Copyright 2026-Present Status Research & Development GmbH
#
#                Licensed under either of
#    Apache License, version 2.0, (LICENSE-APACHEv2)
#                MIT license (LICENSE-MIT)

## Continuation-local storage for chronos: dynamically-scoped values that
## follow a logical task through `await` suspensions, callback
## registrations, and combinators, while concurrent tasks stay isolated
## from each other. See `docs/src/contextvars.md` for the full design,
## usage examples, and the "Test plan" section describing this feature's
## test coverage.
##
## A context variable is a value — a `ContextVar[T]` key returned by
## `newContextVar[T]` or declared with the `{.contextVar.}` pragma — not a
## family of macro-minted identifiers. Every operation on a key is an
## ordinary call:
##
## - `cv.value` — the innermost binding for the current logical task, or
##   the key's default when nothing is bound; raises
##   `UnboundContextVarDefect` for a must-bind key read while unbound.
## - `ctx[cv]` — the same read, against a captured `AsyncContext` snapshot
##   instead of the ambient chain.
## - `cv.withValue(v): body` — bind `cv` to `v` for the dynamic extent of
##   `body`, restoring the previous binding on every exit path (normal,
##   exception, `CancelledError`).
##
## ## Public API
##
## - `ContextVar[T]` / `newContextVar[T](name, default, private = true)`
##   / `newRequiredContextVar[T](name, private = true)` (must-bind) —
##   the key type and its raw constructors.
## - `{.contextVar.}` — declaration pragma: `let name* {.contextVar.} =
##   default` derives the key's name and `dumpContext` privacy from the
##   declaration site itself. See docs/src/contextvars.md, "The
##   `{.contextVar.}` pragma".
## - `value`, `` `[]` ``, `withValue`, `name`, `hasDefault`, `private` —
##   the operation vocabulary above, plus read-only accessors.
## - `` `contains` ``/`cv in ctx`, `isBound` — non-raising boundness
##   probes, identity-correct (unlike inferring boundness from
##   `dumpContext`'s name-grouped output). See docs/src/contextvars.md,
##   "Required variables".
## - `AsyncContext`, `currentContext()`, `withContext(ctx, body)`,
##   `` `==` ``/`hash` — snapshot/restore for callback-style code that
##   runs under a context captured earlier. See docs/src/contextvars.md,
##   "Bridging independent callbacks".
## - `dumpContext(ctx): seq[ContextVarEntry]` / `` `$`(ctx): string `` —
##   introspect every registered (non-private) key's state within a
##   snapshot. See docs/src/contextvars.md, "Inspecting contexts".
## - `UnboundContextVarDefect` — raised by a must-bind key's read
##   (`.value` or `ctx[cv]`) when read while unbound; carries the key's
##   name in `varName`.

import std/[algorithm, atomics, hashes, strutils]
when (NimMajor, NimMinor) >= (2, 0):
  # `{.contextVar.}` (see the gate below) is the only consumer.
  import std/macros
import ./config
import ./futures
import ./internal/contextnode
# Neither `ContextNodeBase` nor the ambient `currentAsyncContext`
# threadvar (declared in `chronos/futures.nim`, used internally below via
# the plain `import ./futures`) is re-exported: `AsyncContext` below
# wraps the chain head in a field private to this module, so no external
# code — including code that imports `chronos/internal/contextnode`
# directly — has any route to construct one outside `currentContext()`'s
# own capture. See docs/src/contextvars.md, "Implementation".

# --- Key types and the registry --------------------------------------------

type
  ContextVarBase* {.acyclic.} = ref object of RootRef
    ## Non-generic base of a `ContextVar[T]` key. Ref identity IS key
    ## identity: no custom `==` is ever defined for this hierarchy — see
    ## `hash*` below for the pointer-identity hash that is defined.
    ## Fields stay unexported — `name`/`hasDefault`/`private` below are
    ## read-only accessors, and `render`/`nextRegistered` are
    ## registry/render internals reachable only from this module.
    ##
    ## `{.acyclic.}`: `nextRegistered` only ever links into
    ## `registryHead` (append-only, see `registerVar`), so this chain is
    ## cycle-free by construction; and every registered key is
    ## already immortal for the process's life (see `registryHead`
    ## below), so cycle-collector bookkeeping for it can never lead to
    ## a collection either way. Also decouples a key from the
    ## constructing thread's per-thread cycle-collector bookkeeping
    ## under `--mm:orc` — load-bearing, not cosmetic: without it, a key
    ## constructed on a thread that then exits leaves a dangling
    ## bookkeeping entry that SIGSEGVs the next decref to touch it, even
    ## at ordinary process teardown. `ContextVar[T]` below repeats the
    ## pragma — it isn't inherited by generic subtypes.
    name: string
    hasDefault: bool
    private: bool
    render: proc(cv: ContextVarBase, node: ContextNodeBase): string
      {.nimcall, gcsafe, raises: [].}
      ## `node == nil` renders the key's stored default instead of a
      ## bound node's value — the one instantiation `dumpContext`
      ## needs for both the bound and the unbound-but-defaulted case.
    nextRegistered: ContextVarBase

  ContextVar*[T] {.acyclic.} = ref object of ContextVarBase
    default: T

  ContextNodeKeyed = ref object of ContextNodeBase
    ## Carries `key` where every chain node can read it without
    ## knowing `T` — `contextnode.nim`'s `ContextNodeBase` declares
    ## only `next`, so this layer inserts the field the lookup walk
    ## needs, one level below it. `ContextNode[T]` is the only type
    ## ever built on this layer, so `key`'s presence at this offset
    ## is sound by construction, not by runtime tag.
    ##
    ## Stored as a raw `pointer`, not `ContextVarBase`: a key is a
    ## module-level `let` constructed before any `createThread` (see
    ## "Registry and key lifetime" below) and kept alive for the
    ## process's life by the registry's intrusive list — every key
    ## registers, private or not, precisely so this field can stay an
    ## untraced pointer — never by a chain node, so the pointee outlives
    ## every node that could reference it. This is
    ## load-bearing, not cosmetic: `withValue` can run on any thread
    ## once a key is constructed, and under `--mm:refc` the GC heap is
    ## per-thread (`gch` is `{.rtlThreadVar.}`), so a traced
    ## `ContextVarBase` field here would incref a foreign-thread-
    ## allocated key through the wrong thread's heap bookkeeping on
    ## every bind — reproduced as a `[GCASSERT] incRef: interiorPtr`
    ## crash under `-d:useGcAssert` (two threads, each `withValue`-
    ## binding the same key). `{.cursor.}` was tried first and does NOT
    ## fix this: this codebase's own precedent (`asyncfutures.nim`'s
    ## `cbc2 {.cursor.}` sites) documents it as an orc/arc
    ## cycle-avoidance device, and empirically refc still emits the
    ## write barrier for a cursor field here. A raw `pointer` sidesteps
    ## ref-counting entirely, on every MM, matching the old registry's
    ## own `ptr ContextVarRegistration` precedent for the same class of
    ## hazard.
    key: pointer

  ContextNode[T] = ref object of ContextNodeKeyed
    ## One chain node: the key it was bound under, plus the owned
    ## value. Unexported like `ContextNodeKeyed` — nothing outside this
    ## module ever names either type; `withValue`/`` `[]` `` build and
    ## walk nodes from inside their own template/proc bodies, which
    ## resolve against this module's scope regardless of the caller's.
    value: T

func name*(cv: ContextVarBase): string {.inline.} =
  ## Read-only: the string is stored anyway, so log/tracing code
  ## shouldn't need a registry walk to name a key. No matching `name=`
  ## is ever defined.
  cv.name

func hasDefault*(cv: ContextVarBase): bool {.inline.} =
  cv.hasDefault

func private*(cv: ContextVarBase): bool {.inline.} =
  cv.private

func hash*(cv: ContextVarBase): Hash {.inline, raises: [].} =
  ## Pointer-identity hash, consistent with ref identity being key
  ## identity (no custom `` `==` `` is ever defined for this hierarchy —
  ## see the guardrail in tests/testcontextvarsguardrails.nim) — mirrors
  ## `hash*(ctx: AsyncContext)` below. Safe to use `ContextVar[T]` as a
  ## `Table`/`HashSet` key.
  hash(cast[pointer](cv))

var registryHead: ContextVarBase
  ## Head of the intrusive registry list — process-lifetime, allocation
  ## free. Registration keeps a key alive for the life of the process,
  ## matching what a purely static, module-level-global design would
  ## have gotten for free.

func renderValue[T](v: T): string {.raises: [].} =
  when T is ref:
    if v == nil:
      return "nil"
  when compiles($(v)):
    try:
      $(v)
    except CatchableError:
      "<render-error>"
  else:
    "<no-$>"

func renderGeneric[T](cv: ContextVarBase, node: ContextNodeBase): string
    {.nimcall, gcsafe, raises: [].} =
  if node != nil:
    renderValue(cast[ContextNode[T]](node).value)
  else:
    renderValue(ContextVar[T](cv).default)

# --- Construction guards and the raw constructors ---------------------------

when defined(chronosDebug):
  var contextVarConstructionLocked = false
    ## Guard flag for the write-once-then-read-only registry discipline
    ## documented in docs/src/contextvars.md, "Registry and key
    ## lifetime": keys are constructed only before any `createThread`.
    ## Flipped by `lockContextVarConstruction()`; chronos does not wrap
    ## user thread creation, so nothing calls this automatically — it
    ## is an opt-in debug hook, exercised by the test suite. Debug-only:
    ## no lock is paid on any path in a release build.

  proc lockContextVarConstruction*() {.inline.} =
    ## Engage the construction guard. Any `newContextVar`/
    ## `newRequiredContextVar` call after this point asserts. One-way
    ## for the process's lifetime — there is no matching unlock,
    ## mirroring the real thread-creation event it stands in for.
    contextVarConstructionLocked = true

  proc checkContextVarConstructionAllowed() {.inline.} =
    doAssert not contextVarConstructionLocked,
      "newContextVar/newRequiredContextVar called after " &
      "lockContextVarConstruction() — keys must be constructed before " &
      "any thread creation"

var contextVarThreadGenCounter: Atomic[uint]
  ## Source of the never-recycled per-thread identity the guard below
  ## checks against, in place of `getThreadId()`: an OS thread id is
  ## reused once its thread exits, which would let a later, unrelated
  ## thread pass as the one that constructed the first key. Generation
  ## `0` is reserved for "unstamped" (see `contextVarThreadGen` below),
  ## so the first generation handed out is `1`.

var contextVarThreadGen {.threadvar.}: uint
  ## This thread's identity, lazily assigned by `contextVarThreadGeneration`
  ## on first use. `0` means not yet stamped.

proc contextVarThreadGeneration(): uint {.inline.} =
  if contextVarThreadGen == 0'u:
    contextVarThreadGen = contextVarThreadGenCounter.fetchAdd(1'u) + 1'u
  contextVarThreadGen

var contextVarConstructionThreadGen: Atomic[uint]
  ## Recording slot for the automatic same-thread construction guard: `0`
  ## means no key has been constructed yet; any other value is the
  ## generation (see above) of the thread that constructed the first one.
  ## Set exactly once, via the compare-exchange in
  ## `checkContextVarConstructionThread` below, so the guard needs no
  ## lock to stay race-free.

proc checkContextVarConstructionThread() {.inline.} =
  ## Unconditional in every build, not just `-d:chronosDebug`: the
  ## hazard this guards is `--mm:refc` GC-heap corruption from a chain
  ## node's untraced raw `key` pointer (see docs/src/contextvars.md,
  ## "Registry and key lifetime"), and the construction path it runs on
  ## is cold, so there is no release-build case for skipping it.
  let gen = contextVarThreadGeneration()
  var recorded = 0'u
  if not contextVarConstructionThreadGen.compareExchange(recorded, gen):
    doAssert recorded == gen,
      "newContextVar/newRequiredContextVar called from a different " &
      "thread than the one that constructed the first context " &
      "variable key — under --mm:refc this corrupts the GC heap (see " &
      "docs/src/contextvars.md, \"Registry and key lifetime\"); " &
      "construct every context variable key on a single thread, " &
      "before any createThread call"

proc checkContextVarConstruction() {.inline.} =
  ## Called unconditionally from both constructors below, so callers
  ## don't need their own `when defined(chronosDebug):` wrapper: the
  ## lock check (`checkContextVarConstructionAllowed`) is allowed only
  ## under `-d:chronosDebug`, opt-in as above; the thread check
  ## (`checkContextVarConstructionThread`) always runs.
  when defined(chronosDebug):
    checkContextVarConstructionAllowed()
  checkContextVarConstructionThread()

proc registerVar(base: ContextVarBase) =
  base.nextRegistered = registryHead
  registryHead = base

proc newContextVar*[T](name: chronosSink string, default: T,
                        private = true): ContextVar[T] {.raises: [].} =
  ## Defaulted-arm constructor. Registers unconditionally, regardless of
  ## `private` — see "Registry and key lifetime" in
  ## docs/src/contextvars.md for why registration is now the key's only
  ## lifetime guarantee. `private` governs `dumpContext` visibility only,
  ## and defaults to `true` — see "Privacy and the raw constructors".
  ##
  ## `default` stays a plain `T`, not `chronosSink T`: `T` must be
  ## inferred from this very argument at ordinary call sites (there is
  ## no other `T`-typed parameter to pin it, unlike this codebase's
  ## other `chronosSink T` sites — `asyncfutures.nim`'s `complete`,
  ## `callbackqueue.nim`'s `addLast`/`prependNoGrow` — where a
  ## `Future[T]`/`CallbackQueue[T]` parameter already fixes `T` before
  ## the sink parameter is even considered). Under `--mm:refc`'s
  ## chronosUseSink branch (Nim >= 2.0.6), `chronosSink` lowers to
  ## `sink`, and routing generic-parameter inference through the
  ## template that produces it — rather than a bare `sink T` — defeats
  ## Nim's sigmatch: `newContextVar("x", 0)` stops compiling with a type
  ## mismatch, reproduced in isolation down to a two-line template.
  ## `name`, which carries no inference burden, keeps `chronosSink`.
  checkContextVarConstruction()
  result = ContextVar[T](name: name, hasDefault: true, private: private,
                          default: default)
  result.render = renderGeneric[T]
  registerVar(result)

proc newRequiredContextVar*[T](name: chronosSink string,
                                private = true): ContextVar[T] {.raises: [].} =
  ## Must-bind constructor — no default supplied. See
  ## docs/src/contextvars.md, "Required variables". Same unconditional
  ## registration and `private` default as `newContextVar` above; a
  ## distinct name rather than a second overload of `newContextVar` —
  ## see docs/src/contextvars.md, "The raw constructors".
  checkContextVarConstruction()
  result = ContextVar[T](name: name, hasDefault: false, private: private)
  result.render = renderGeneric[T]
  registerVar(result)

iterator registeredVars(): ContextVarBase =
  ## Unexported — the registry-walking primitive is internal to this
  ## module, invoked by `dumpContext` only. Analogous to the old
  ## design's `contextVarRegistry` iterator, which was pinned off the
  ## public surface for the same reason: a caller has no legitimate use
  ## for raw registry entries that `dumpContext`/`ContextVarEntry`
  ## doesn't already serve.
  var node = registryHead
  while node != nil:
    yield node
    node = node.nextRegistered

# --- Snapshot type and the one chain-walk lookup -----------------------------
# `.value` re-expresses as `currentContext()[cv]` below, on top of this
# same `` `[]` `` — the sole walk, so the re-expression is a thin wrapper,
# not a second implementation.

type
  AsyncContext* = object
    ## Opaque snapshot of a binding chain, captured by `currentContext()`.
    node: ContextNodeBase
      ## Private: the only route to a populated `AsyncContext` is
      ## `currentContext()`'s capture below — construction from an
      ## arbitrary `ContextNodeBase` must not compile, even for code
      ## that imports `chronos/internal/contextnode` directly. See
      ## docs/src/contextvars.md, "Implementation".

func `==`*(a, b: AsyncContext): bool {.gcsafe, raises: [].} =
  ## Identity equality: `true` iff `a` and `b` reference the same
  ## underlying chain head — i.e. both were captured with no
  ## intervening binding change.
  a.node == b.node

func hash*(ctx: AsyncContext): Hash {.gcsafe, raises: [].} =
  ## Pointer-identity hash, consistent with `==`'s identity semantics —
  ## safe to use `AsyncContext` as a `Table`/`HashSet` key.
  hash(cast[pointer](ctx.node))

proc currentContext*(): AsyncContext {.gcsafe, raises: [].} =
  ## Capture the current task's binding chain as an opaque snapshot.
  # `proc`, not `func`: reading the `{.threadvar.}` trips effect analysis.
  {.cast(gcsafe).}:
    AsyncContext(node: currentAsyncContext)

template withContext*(ctx: AsyncContext, body: untyped) =
  ## Run `body` with `ctx` as the current async context; restore the
  ## prior context on every exit path (normal, exception, including
  ## `CancelledError`).
  let chronosCtxPrev = currentAsyncContext
  currentAsyncContext = ctx.node
  try:
    body
  finally:
    currentAsyncContext = chronosCtxPrev

type
  UnboundContextVarDefect* = object of Defect
    ## Raised by a must-bind key's read (`.value` or `ctx[cv]`) when no
    ## binding is in scope.
    varName*: string

func findNode(chain: ContextNodeBase, cv: ContextVarBase): ContextNodeBase =
  var node = chain
  while node != nil:
    if cast[ContextNodeKeyed](node).key == cast[pointer](cv):
      return node
    node = node.nextNode

func `[]`*[T](ctx: AsyncContext, cv: ContextVar[T]): T {.raises: [].} =
  let node = findNode(ctx.node, cv)
  if node != nil:
    when defined(chronosDebug):
      doAssert node of ContextNode[T],
        "contextvars internal error: a chain node whose key matched " &
        "cv is not a ContextNode[T] — see the construction invariant " &
        "in docs/src/contextvars.md, \"Implementation\""
    return cast[ContextNode[T]](node).value
  if cv.hasDefault:
    cv.default
  else:
    var e = newException(UnboundContextVarDefect,
      "context variable '" & cv.name & "' has no default and is not " &
      "bound in this context")
    e.varName = cv.name
    raise e

template value*[T](cv: ContextVar[T]): T =
  ## `{.cast(gcsafe).}`: `cv` is typically a module-level `let` key (a
  ## `ref`), and this template inlines directly into its caller — so
  ## without the cast, the caller (often a `{.gcsafe.}`-required async
  ## proc) would be flagged for "accessing a global using GC'ed
  ## memory". Sound: keys are write-once at construction (see
  ## docs/src/contextvars.md, "Registry and key lifetime") and never
  ## mutated after.
  {.cast(gcsafe).}:
    currentContext()[cv]

when defined(chronosDebug):
  var chainBalance* {.threadvar.}: int
    ## Debug-only bind/unbind balance counter for `withValue`:
    ## increments at push, decrements at pop. A nonzero value at
    ## test-suite end signals a binder leak. Deterministic + MM-
    ## portable — doesn't depend on GC sweep timing.

  proc chainLen*(): int {.inline, raises: [].} =
    ## Debug-only chain-depth probe. Walks `currentAsyncContext` and
    ## returns the number of nodes. Used by binder-contract tests to
    ## verify push/pop balance without relying on finalizer timing.
    # `proc`, not `func`: reading the `{.threadvar.}` trips effect analysis.
    var n = currentAsyncContext
    while n != nil:
      inc result
      n = n.nextNode

template withValue*[T](cv: ContextVar[T], v: T, body: untyped): untyped =
  ## Push a `ContextNode[T]` bound to `cv` onto the ambient chain for
  ## the dynamic extent of `body`; restore the prior head on every exit
  ## path. Allocates before mutating `currentAsyncContext`, so a failed
  ## allocation can't leave a half-pushed chain.
  ##
  ## `{.cast(gcsafe).}`: same global-access rationale as `value` above —
  ## `cv` inlines straight into the caller here too.
  let chronosCtxPrev = currentAsyncContext
  var chronosCtxNode: ContextNode[T]
  {.cast(gcsafe).}:
    chronosCtxNode = ContextNode[T](key: cast[pointer](cv), value: v)
  linkNode(chronosCtxNode, chronosCtxPrev)
  currentAsyncContext = chronosCtxNode
  when defined(chronosDebug):
    inc chainBalance
  try:
    body
  finally:
    currentAsyncContext = chronosCtxPrev
    when defined(chronosDebug):
      dec chainBalance

# --- Introspection ------------------------------------------------------------
# `ContextVarEntry`/`dumpContext`/`` `$` ``: same bound-flag semantics
# (an unbound defaulted key still shows its rendered default; an unbound
# must-bind key shows the `<unbound>` placeholder), same sorted-by-name
# order, same `{name: value, ...}` `$` format documented in
# docs/src/contextvars.md, "Inspecting contexts". Every key registers
# now (see `newContextVar`), so `dumpContext` is the filtering point:
# it skips `cv.private` entries itself rather than relying on their
# absence from the registry.

type
  ContextVarEntry* = object
    name*: string
    bound*: bool
    value*: string

func contains*[T](ctx: AsyncContext, cv: ContextVar[T]): bool {.raises: [].} =
  ## `cv in ctx` — identity-correct boundness probe (PEP 567 precedent:
  ## Python contexts support `in`). True iff `cv` has an active binding
  ## in `ctx`, false otherwise — including for a must-bind key, which
  ## `.value`/`` `[]` `` would raise `UnboundContextVarDefect` for
  ## instead. Answers what a `dumpContext` name-match cannot: which of
  ## two same-name keys is the one actually bound (see "Registry and key
  ## lifetime" — same-name keys never alias).
  findNode(ctx.node, cv) != nil

template isBound*[T](cv: ContextVar[T]): bool =
  ## Ambient form of `contains` — mirrors `value`'s relationship to
  ## `` `[]` ``. `{.cast(gcsafe).}`: same global-access rationale as
  ## `value` above — `cv` inlines straight into the caller here too.
  {.cast(gcsafe).}:
    currentContext().contains(cv)

proc dumpContext*(ctx: AsyncContext): seq[ContextVarEntry] {.raises: [].} =
  ## Introspect every registered, non-private key as of `ctx`, sorted
  ## by name. Never raises — render failures are caught inside each
  ## key's render hook.
  {.cast(gcsafe).}:
    let chain = ctx.node
    for cv in registeredVars():
      if cv.private: continue
      let node = findNode(chain, cv)
      if node != nil:
        result.add ContextVarEntry(name: cv.name, bound: true,
                                    value: cv.render(cv, node))
      elif cv.hasDefault:
        result.add ContextVarEntry(name: cv.name, bound: false,
                                    value: cv.render(cv, nil))
      else:
        result.add ContextVarEntry(name: cv.name, bound: false,
                                    value: "<unbound>")
  result.sort(proc(a, b: ContextVarEntry): int = cmp(a.name, b.name))

proc `$`*(ctx: AsyncContext): string {.raises: [].} =
  ## Render `ctx` as `{name: value, ...}`, via the same registry walk
  ## as `dumpContext`. Debugging/logging only — not a stable format.
  var parts: seq[string]
  for entry in dumpContext(ctx):
    parts.add entry.name & ": " & entry.value
  "{" & parts.join(", ") & "}"

# --- `{.contextVar.}` declaration sugar --------------------------------------
# A pragma macro, not a statement macro: `contextVar name*: T = default`
# doesn't parse (export postfix and identdef are `let`/`var`-only parser
# productions). Attached as `{.contextVar.}` between the star and the
# colon-type, it lets the parser's own identdef grammar do the
# star/type/default parsing; the macro only rewrites the RHS into a
# `newContextVar` call and re-emits the one `let`/`var` symbol.

# Macro pragmas on `let`/`var` sections (the mechanism `{.contextVar.}`
# relies on) are a 2.x-only language capability — `semVarMacroPragma`,
# which rewrites `var p {.m.}` into a call to `m`, does not exist in the
# 1.6 compiler, so the pragma silently never invokes on 1.6. Declare keys
# with `newContextVar`/`newRequiredContextVar` directly on 1.6; see
# docs/src/contextvars.md, "The `{.contextVar.}` pragma".
when (NimMajor, NimMinor) >= (2, 0):
  proc splitContextVarNameAndPrivate(identNode: NimNode):
      tuple[nameNode: NimNode, nameStr: string, private: bool] =
    ## Star present -> exported -> private = false; absent -> private =
    ## true. `nnkIdent`/`nnkSym` both resolve via `strVal` (a wrapper
    ## template forwarding its own parameter arrives as `nnkSym`); only
    ## `nnkPostfix` needs unwrapping to reach the name.
    # 1.6: explicit `result =` per branch, not a case-expression — 1.6 sems
    # case-branches as statements even when the last one is a noreturn
    # `error()` call, and rejects the tuple as unused. (Moot under the
    # 2.x gate above, kept for hygiene since the shape is trivial to keep
    # portable.)
    case identNode.kind
    of nnkPostfix:
      if identNode.len != 2 or identNode[0].strVal != "*":
        error("contextVar: unexpected postfix form: " & identNode.repr, identNode)
      result = (identNode, identNode[1].strVal, false)
    of nnkIdent, nnkSym:
      result = (identNode, identNode.strVal, true)
    else:
      error("contextVar: expected `name` or `name*`, got " & identNode.repr, identNode)

  proc parsePrivateOverride(opts: NimNode): bool =
    ## Unwraps the argument of `{.contextVar: (private: true|false).}` —
    ## `(private: true)` parses as a one-field `nnkTupleConstr` holding an
    ## `nnkExprColonExpr`, and `true`/`false` there arrive as `nnkIdent`
    ## (bare identifiers, not bool literals — the argument is untyped).
    ## Any other shape is a compile error naming the one accepted form.
    if opts.kind == nnkTupleConstr and opts.len == 1 and
        opts[0].kind == nnkExprColonExpr and opts[0][0].eqIdent("private") and
        opts[0][1].kind == nnkIdent and opts[0][1].strVal in ["true", "false"]:
      return opts[0][1].strVal == "true"
    error("contextVar: expected `(private: true)` or `(private: false)`, " &
          "got " & opts.repr, opts)

  proc contextVarImpl(def: NimNode, hasPrivateOverride: bool,
                       overridePrivate: bool): NimNode =
    ## `let name* {.contextVar.} = default` (T inferred), `let name*
    ## {.contextVar.}: T = default` (explicit T), or `var name*
    ## {.contextVar.}: T` (must-bind) — expands to exactly one symbol,
    ## `let name* = newContextVar(...)` or `newRequiredContextVar(...)`.
    ## See docs/src/contextvars.md, "The `{.contextVar.}` pragma". The
    ## `let`/`var` choice is enforced here, not just documented: a
    ## defaulted key must be a `let`, a must-bind key must be a `var` —
    ## the same split between `newContextVar` and `newRequiredContextVar`
    ## the call site makes, moved to the declaration site. `hasPrivateOverride`
    ## selects between the export-derived default (`{.contextVar.}`) and the
    ## explicit `{.contextVar: (private: ...).}` override, common to both
    ## pragma arities below.
    if def.kind notin {nnkLetSection, nnkVarSection}:
      error("contextVar: must annotate a `let` or `var` statement", def)
    if def.len != 1:
      error("contextVar: supports exactly one identifier per statement", def)
    let identDefs = def[0]
    if identDefs.kind != nnkIdentDefs or identDefs.len != 3:
      error("contextVar: expected a single `name[*][: T] [= default]` " &
            "identifier definition, got " & identDefs.repr, identDefs)
    let (nameNode, nameStr, derivedPrivate) = splitContextVarNameAndPrivate(identDefs[0])
    let private = if hasPrivateOverride: overridePrivate else: derivedPrivate
    let typAnnotation = identDefs[1]
    let value = identDefs[2]

    if value.kind == nnkEmpty:
      if typAnnotation.kind == nnkEmpty:
        error("contextVar: must-bind keys need an explicit type, e.g. " &
              "`var " & nameStr & "*: T {.contextVar.}`", identDefs)
      if def.kind != nnkVarSection:
        error("contextVar: a must-bind key (no `= default`) needs `var`, " &
              "not `let` — spell it `var " & nameStr & "*: " &
              typAnnotation.repr & " {.contextVar.}`", def)
    elif def.kind != nnkLetSection:
      error("contextVar: a defaulted key (`= default`) needs `let`, not " &
            "`var` — spell it `let " & nameStr & "*" &
            (if typAnnotation.kind != nnkEmpty: ": " & typAnnotation.repr
             else: "") & " {.contextVar.} = " & value.repr & "`", def)

    let ctorCall =
      if value.kind == nnkEmpty:
        quote do: newRequiredContextVar[`typAnnotation`](`nameStr`, private = `private`)
      elif typAnnotation.kind != nnkEmpty:
        quote do: newContextVar[`typAnnotation`](`nameStr`, `value`, private = `private`)
      else:
        quote do: newContextVar(`nameStr`, `value`, private = `private`)

    result = newNimNode(nnkLetSection)
    result.add newIdentDefs(nameNode, newEmptyNode(), ctorCall)

  macro contextVar*(def: untyped): untyped =
    ## Default form: `dumpContext` privacy is derived from the declaration's
    ## own export marker (star -> `private = false`, no star -> `private =
    ## true`). See docs/src/contextvars.md, "The `{.contextVar.}` pragma".
    contextVarImpl(def, hasPrivateOverride = false, overridePrivate = false)

  macro contextVar*(opts, def: untyped): untyped =
    ## Override form: `{.contextVar: (private: true|false).}` decouples
    ## `dumpContext` visibility from the export marker for this one
    ## declaration — e.g. an exported key that should still be
    ## dump-private, or an unexported key surfaced for cross-module
    ## debugging. See docs/src/contextvars.md, "The `{.contextVar.}`
    ## pragma", "Overriding dump-visibility".
    contextVarImpl(def, hasPrivateOverride = true,
                    overridePrivate = parsePrivateOverride(opts))

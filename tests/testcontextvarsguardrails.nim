#                Chronos Test Suite
#            (c) Copyright 2018-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

## Drift-detection guardrails for chronos's continuation-local storage
## feature.
##
## Two orthogonal halves: guardrails 1-9 pin representation/identity
## properties of the `ContextVar[T]` key runtime
## (`chronos/contextvars.nim`) — ref identity, field privacy, absence of
## an imperative API, chain-node unreachability, `std/tables` coexistence,
## name-string drift, non-aliasing, and the positive inverse of the old
## macro design's collision guardrail. The callback-capture-discipline
## guardrails after them are substrate-level — orthogonal to the API and
## carried over unchanged from before this redesign.
##
## Each check is a compile-time assertion (`static:` / `when compiles`)
## or, where the guardrail is semantic rather than structural, a runtime
## assertion — with a control assertion first wherever a bare `not
## compiles` could otherwise be vacuous (e.g. a typo'd field name).

import std/[sequtils, tables]
import unittest2
import ../chronos/contextvars
import ../chronos/internal/contextnode
  # Whitebox: guardrails 5 and 11 below name `ContextNodeBase` directly,
  # which `chronos/contextvars.nim` no longer re-exports (see guardrail
  # 11) — those checks import the internal module the same way an
  # attacker attempting the forgery in guardrail 11 would have to.
import ../chronos
  # Brings `withTimeout` into scope for guardrail 9 below, and
  # InternalAsyncCallback/AsyncCallback/InternalCancelCallback/
  # CompletionData for the capture-discipline guardrails.

{.used.}

# --- Guardrail 1: ContextVar[T] is ref ---------------------------------------
#
# Ref identity IS key identity (see docs/src/contextvars.md,
# "Implementation"): aliases compare equal, keys work in Table/seq for
# free, and a default-initialized `nil` key is a detectable invalid
# state. A value `object` key was rejected for exactly this reason.

static:
  doAssert ContextVar[int] is ref,
    "ContextVar[T] must be a `ref object` — ref identity is key " &
    "identity; a value object would let a copy silently break it."
  doAssert ContextVarBase is ref,
    "ContextVarBase must be a `ref object` too — ContextVar[T] " &
    "inherits it, so the base carries the same identity guarantee."

# --- Guardrail 2: no public mutable fields -----------------------------------
#
# `name`/`hasDefault`/`private` are exposed as read-only accessor procs
# (same spelling as the private field names, so `cv.name` etc. still
# reads via UFCS); `render`/`default`/the registry link
# (`nextRegistered`) are not reachable at all outside
# chronos/contextvars.nim. A writable field here would let user code
# corrupt a key after construction — e.g. rewrite `render` to defeat
# `dumpContext`, or flip `hasDefault` to bypass `UnboundContextVarDefect`.
# This is also the successor to the old macro design's registry-field
# guardrail (`ContextVarRegistration.registered`/`.next`): the new
# registry has no separate node type, just this one private link field
# on `ContextVarBase` itself, so its privacy is pinned here rather than
# in a dedicated registry guardrail.

static:
  # Controls: reads must still compile, or the write probes below
  # would be vacuous (indistinguishable from a typo'd field name).
  doAssert compiles((let k = newContextVar("g2CtlName", 0); discard k.name)),
    "control: `.name` must be readable — if this fails, the write " &
    "probe below isn't probing what it claims to."
  doAssert compiles((let k = newContextVar("g2CtlHasDefault", 0); discard k.hasDefault)),
    "control: `.hasDefault` must be readable."
  doAssert compiles((let k = newContextVar("g2CtlPrivate", 0); discard k.private)),
    "control: `.private` must be readable."

  doAssert not compiles((let k = newContextVar("g2Name", 0); k.name = "evil")),
    "ContextVar[T].name must not be writable — it's a read-only " &
    "accessor over a private field."
  doAssert not compiles((let k = newContextVar("g2HasDefault", 0); k.hasDefault = false)),
    "ContextVar[T].hasDefault must not be writable — flipping it " &
    "post-construction would desync a must-bind key from its Defect."
  doAssert not compiles((let k = newContextVar("g2Private", 0); k.private = true)),
    "ContextVar[T].private must not be writable — flipping it " &
    "post-construction wouldn't retroactively (un)register the key, " &
    "so a writable field would make `.private` lie about registration."
  doAssert not compiles((let k = newContextVar("g2Default", 0); k.default = 1)),
    "ContextVar[T].default must not be reachable at all outside this " &
    "module — it's on the RFC's public-surface Forbidden list."
  doAssert not compiles((let k = newContextVar("g2Render", 0); k.render = nil)),
    "ContextVarBase.render must not be reachable at all outside this " &
    "module — a writable render hook would let user code corrupt " &
    "dumpContext's output for a key it doesn't own."
  doAssert not compiles((let k = newContextVar("g2Registry", 0); k.nextRegistered = nil)),
    "ContextVarBase.nextRegistered (the intrusive registry link) must " &
    "not be reachable at all outside this module — a writable link " &
    "would let user code splice or unlink registry nodes."

# --- Guardrail 3: no custom `==` on ContextVar -------------------------------
#
# Chain-node dispatch (the `[]` walk) depends on ref-identity
# comparison; a value-based `==` would silently alias two distinct
# keys constructed with the same arguments.

type
  G3UnrelatedRef = ref object
    tag: int

static:
  doAssert not compiles(newContextVar("g3Unrelated", 0) == G3UnrelatedRef(tag: 1)),
    "ContextVar must not compare equal to an unrelated ref type — no " &
    "accidental converter or structural `==` should bridge the two " &
    "hierarchies."

suite "contextvars guardrails: g3 no custom ==":
  test "two identically-constructed same-T keys compare unequal (ref identity)":
    let k1 = newContextVar("g3Key", 0)
    let k2 = newContextVar("g3Key", 0)
    check k1 != k2

# --- Guardrail 4: imperative set/reset stays absent --------------------------
#
# Binding is block-scoped only (`withValue`); no imperative token API.
# `reset`/`set` can't be probed via `declared()` the way an absent
# surface symbol normally would (`system.reset` makes `declared(reset)`
# true in every module — see testcontextvarssurface.nim's note), so the
# probe is call-shape instead: none of these verb-shaped calls with a
# value argument may resolve against `ContextVar[T]`.

static:
  doAssert not compiles((let k = newContextVar("g4Set", 0); k.set(1))),
    "ContextVar[T] must not have an imperative `set` — binding is " &
    "block-scoped only via `withValue`."
  doAssert not compiles((let k = newContextVar("g4Reset", 0); k.reset(1))),
    "ContextVar[T] must not have an imperative `reset` taking a value."
  doAssert not compiles((let k = newContextVar("g4Push", 0); k.push(1))),
    "ContextVar[T] must not have a `push`-shaped imperative call."
  doAssert not compiles((let k = newContextVar("g4Pop", 0); k.pop(1))),
    "ContextVar[T] must not have a `pop`-shaped imperative call."
  doAssert not compiles((let k = newContextVar("g4Free", 0); set(k, 1))),
    "free-function `set(cv, v)` must not resolve either — same probe, " &
    "non-UFCS call shape."

# --- Guardrail 5: chain-node construction and `next` access unreachable -----
#
# `ContextNode`/`ContextNodeKeyed` are both unexported: neither name
# resolves outside chronos/contextvars.nim at all, so there is no
# `cast`-free way to construct a node or reach its `next`. Successor to
# the old macro design's chain-privacy guardrail, which depended on
# declaring a `contextVar` arm to obtain a nameable slot subtype to
# probe through — first-class keys have no such subtype at all, so the
# probe is simpler: the node types themselves are unnameable.
# `ContextNodeBase.next` (the inherited field) stays private to
# contextnode.nim unchanged — that half of the guardrail predates this
# redesign.

static:
  doAssert not compiles(ContextNode[int]),
    "ContextNode[T] must not be nameable outside chronos/contextvars.nim."
  doAssert not compiles(ContextNodeKeyed),
    "ContextNodeKeyed must not be nameable outside chronos/contextvars.nim either."
  doAssert not compiles((var n: ContextNodeBase; n.next = n)),
    "ContextNodeBase.next must stay unwritable from outside " &
    "chronos/internal/contextnode.nim — unchanged by this redesign, " &
    "reconfirmed here because it's the field the whole guardrail " &
    "protects."
  doAssert not compiles((var n: ContextNodeBase; discard n.next)),
    "ContextNodeBase.next must stay unreadable from outside " &
    "chronos/internal/contextnode.nim either."

# --- Guardrail 6: std/tables.withValue coexistence (pinned decision 1) ------
#
# Overloads dispatch on receiver type, ordinary stdlib verb-sharing à
# la `len`/`[]` — not a compile hazard. Compiles a module importing
# both std/tables and chronos/contextvars, calling both `withValue`s
# side by side, including once from inside a generic proc.

proc g6GenericRoundtrip[T](cv: ContextVar[T], v: T): T =
  cv.withValue(v):
    result = cv.value

suite "contextvars guardrails: g6 std/tables.withValue coexistence":
  test "Table.withValue and ContextVar.withValue compile and behave side by side":
    let cv = newContextVar("g6Key", 0)
    var t = {"a": 1}.toTable

    t.withValue("a", v):
      v[] = 99

    cv.withValue(7):
      check cv.value == 7
      check t["a"] == 99

    check g6GenericRoundtrip(cv, 55) == 55

# --- Guardrail 7: name-string drift -------------------------------------------
#
# The raw constructor's `name` argument is the DRY wart accepted for
# non-sugar call sites; this guardrail pins that the string surfaces
# verbatim, unmangled, on both consumers: dumpContext and
# UnboundContextVarDefect.varName.

suite "contextvars guardrails: g7 name-string drift":
  test "raw-constructor name surfaces verbatim in dumpContext":
    let k = newContextVar("rawNamed", 0, private = false)
    let entries = dumpContext(currentContext()).filterIt(it.name == "rawNamed")
    check entries.len == 1

  test "raw-constructor name surfaces verbatim in UnboundContextVarDefect.varName":
    let k = newRequiredContextVar[int]("rawNamed")
    try:
      discard k.value
      check false
    except UnboundContextVarDefect as e:
      check e.varName == "rawNamed"

# --- Guardrail 8: same-name keys don't alias ----------------------------------
#
# Duplicate name strings are representable and accepted as
# cosmetic-only (matching PEP 567): dumpContext may show two entries
# with the same label. What's pinned instead is the semantic property —
# binding one same-name key is never observable through the other.

suite "contextvars guardrails: g8 same-name keys don't alias":
  test "binding one of two same-name same-T keys leaves the other's default; both list in dumpContext":
    let a = newContextVar("g8Dup", 1, private = false)
    let b = newContextVar("g8Dup", 1, private = false)

    a.withValue(99):
      check a.value == 99
      check b.value == 1

    check a.value == 1
    check b.value == 1

    let entries = dumpContext(currentContext()).filterIt(it.name == "g8Dup")
    check entries.len == 2

# --- Guardrail 9: positive inverse of the old collision guardrail -----------
#
# The old macro's per-arm `withName` collided with an already-declared
# symbol of the same name (`timeout` vs. chronos's own `withTimeout`
# combinator) — a compile ERROR. First-class keys mint no derived
# identifiers, so this bug class is unrepresentable: a key literally
# named "timeout" and chronos's `withTimeout` coexist without conflict.
# Proof is compile-and-run, not `not compiles`, since the claim is the
# ABSENCE of an error — this deletes the old design's collision-error
# guardrail (and its duplicate-arm variant) outright, rather than
# re-deriving it, since the mechanism that produced the error no longer
# exists.

let timeout* = newContextVar("timeout", 5, private = false)
  ## Deliberately named to match the old collision case — the old
  ## macro would have refused this declaration outright.

suite "contextvars guardrails: g9 no collision with chronos's own symbols":
  test "a key literally named `timeout` coexists with chronos's withTimeout":
    check timeout.value == 5
    check declared(withTimeout)

# --- Guardrail 10: private-key registration closes the chain-node UAF -------
#
# A chain node's `key` field is an untraced raw pointer (see
# chronos/contextvars.nim's `ContextNodeKeyed` comment): the pointee must
# outlive every node that could reference it. Before this fix, a private
# key registered nowhere, so nothing but its own (possibly stack-scoped)
# `let` kept it alive; a captured `AsyncContext` whose chain still held a
# node pointing at that key's address, taken after the key's binding
# `let` went out of scope, was a use-after-free — worse, a *silent* one:
# a later, unrelated key allocated at the freed address would compare
# pointer-equal to the stale `node.key` and read back the dead key's
# bound value instead of its own default. Registering every key,
# private or not, closes this: the key stays alive for the process's
# life regardless of `private`, so the address can never be reused while
# a chain node can still reference it.

var g10CapturedCtx: AsyncContext

proc g10ConstructBindCapture() =
  let privateKey = newContextVar("g10Private", 111, private = true)
  privateKey.withValue(222):
    g10CapturedCtx = currentContext()

suite "contextvars guardrails: g10 private-key registration closes chain-node UAF":
  test "GC after the binding proc returns leaves the captured context safe to walk, and a later key doesn't alias it":
    g10ConstructBindCapture()
    GC_fullCollect()

    # Must not crash walking/rendering the captured chain.
    let entries = dumpContext(g10CapturedCtx)
    check not entries.anyIt(it.name == "g10Private")

    # A key constructed after collection must read its own default, not
    # the collected private key's bound value — the failure mode this
    # guardrail exists to catch if registration is ever narrowed again.
    let freshKey = newContextVar("g10Fresh", 999)
    check g10CapturedCtx[freshKey] == 999

# --- Guardrail 11: AsyncContext cannot be forged from a bare chain node -----
#
# `AsyncContext` wraps its chain-head node in a private field precisely so
# that no safe-Nim code outside chronos/contextvars.nim — not even code
# that imports chronos/internal/contextnode directly, as this file does
# above — can construct one from an arbitrary `ContextNodeBase`. This
# guardrail closes safe construction routes; it does not and cannot cover
# `cast[AsyncContext](node)`, which remains outside the guarantee the same
# way `cast` sits outside every other Nim type's invariants. Before this
# guardrail existed, `AsyncContext* = distinct ContextNodeBase` let a
# `ContextNodeBase` allocated by plain `new` convert straight into an
# `AsyncContext` that `withContext` would accept unvalidated; the chain
# walk's cast to `ContextNodeKeyed` then read past that allocation — a
# silent out-of-bounds read indistinguishable from the empty context. See
# docs/src/contextvars.md, "Implementation".

static:
  doAssert not compiles(block:
    var n: ContextNodeBase
    new(n)
    AsyncContext(n)),
    "AsyncContext must not be constructible from a bare ContextNodeBase " &
    "via distinct-style positional conversion — that was exactly the " &
    "forgery route this guardrail exists to close."
  doAssert not compiles(block:
    var n: ContextNodeBase
    new(n)
    AsyncContext(node: n)),
    "AsyncContext must not be constructible from a bare ContextNodeBase " &
    "via named-field object construction either — the `node` field must " &
    "stay private to chronos/contextvars.nim."

# =============================================================================
# --- Capture-discipline guardrails (substrate-level, orthogonal to the
#     key/macro API — carried over unchanged) ---------------------------------
# =============================================================================

# --- Guardrail: capture coverage is structural -------------------------------
#
# InternalAsyncCallback's fields are private to chronos/futures.nim;
# only capturingCallback/bareCallback/contextCallback can construct one.

static:
  doAssert not compiles(InternalAsyncCallback(function: nil, udata: nil)),
    "InternalAsyncCallback's fields must be private — raw construction " &
    "outside `capturingCallback`/`bareCallback`/`contextCallback` must not " &
    "compile. Use `capturingCallback(fn, udata)` for user-facing scheduling " &
    "sites, `bareCallback(fn, udata)` for chronos-internal trampolines, " &
    "or `contextCallback(fn, udata, ctx)` to reconstruct a callback from " &
    "a context captured earlier (Windows IOCP completion dispatch). " &
    "See docs/src/contextvars.md, 'Capture discipline'."
  doAssert not compiles((var a: AsyncCallback; a.function = nil)),
    "AsyncCallback's `function` field must be private — direct mutation " &
    "outside chronos/futures.nim must not compile."
  doAssert not compiles((var a: AsyncCallback; a.context = nil)),
    "AsyncCallback's `context` field must be private — direct mutation " &
    "would let a scheduling site silently skip context capture."

# --- Guardrail: context is a native ref, not a manually-refcounted pointer ---
#
# A `pointer` field would need manual GC_ref/GC_unref at every drop
# site — a latent leak under --mm:refc since keepItIf's shallowCopy
# bypasses hooks. The native ref delegates lifecycle to Nim's MM.

static:
  doAssert InternalAsyncCallback.context is ContextNodeBase,
    "InternalAsyncCallback.context must be `ContextNodeBase` (a native " &
    "`ref` field) — see docs/src/contextvars.md, 'Implementation'. A " &
    "`pointer` field with " &
    "manual GC_ref/unref leaks under refc via `keepItIf`'s shallowCopy, " &
    "and forces every new scheduling site to remember the manual ops."

# --- Guardrail: AsyncCallback layout stable ----------------------------------
#
# If the struct gains a field or changes layout, this assertion drifts.
# A cheap canary against accidental shape changes.

static:
  # CallbackFunc closure proc = 2 pointers (function + env), plus
  # udata (1) and context: ContextNodeBase (a ref, 1 pointer) = 4.
  doAssert sizeof(InternalAsyncCallback) == sizeof(pointer) * 4,
    "InternalAsyncCallback expected to be 4 pointer-sized fields " &
    "(function: 2-word closure proc, udata: pointer, context: ref); " &
    "actual size = " & $sizeof(InternalAsyncCallback)

# Public-surface minimality lives in tests/testcontextvarssurface.nim,
# which imports only public paths.

# --- Guardrail: InternalCancelCallback ---------------------------------------
#
# Same structural-privacy discipline as InternalAsyncCallback above,
# mirrored for this 3-word type (no udata field).

static:
  doAssert not compiles(InternalCancelCallback(function: nil, context: nil)),
    "InternalCancelCallback's fields must be private — raw construction " &
    "outside `capturingCancelCallback` (or the no-capture site in " &
    "`internalInitFutureBase`) must not compile. Use " &
    "`capturingCancelCallback(fn)`. See docs/src/contextvars.md, 'Capture " &
    "discipline'."
  doAssert not compiles((var c: InternalCancelCallback; c.function = nil)),
    "InternalCancelCallback's `function` field must be private — direct " &
    "mutation outside chronos/futures.nim must not compile."
  doAssert not compiles((var c: InternalCancelCallback; c.context = nil)),
    "InternalCancelCallback's `context` field must be private — direct " &
    "mutation would let a scheduling site silently skip context capture."

  doAssert InternalCancelCallback.context is ContextNodeBase,
    "InternalCancelCallback.context must be `ContextNodeBase` (a native " &
    "`ref` field) — same MM-delegated lifetime discipline as " &
    "`InternalAsyncCallback.context` (guardrail above)."

  # CallbackFunc closure proc (2 words) + context: ContextNodeBase (1) = 3.
  doAssert sizeof(InternalCancelCallback) == sizeof(pointer) * 3,
    "InternalCancelCallback expected to be 3 pointer-sized fields " &
    "(function: 2-word closure proc, context: ref); " &
    "actual size = " & $sizeof(InternalCancelCallback)

# --- A trivial runtime assertion to keep the test file unittest-recognized ---

suite "contextvars: drift guardrails":
  test "compile-time guardrails passed":
    # The static checks above are the real guardrails; this just
    # gives the runner a green dot.
    check true

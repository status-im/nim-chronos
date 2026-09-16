# Context variables

Context variables provide continuation-local storage: dynamically-scoped
values that follow a logical task through `await` suspensions, callback
registrations and combinators, while concurrent tasks remain isolated from
each other. They serve the same role as Python's `contextvars` module in
`asyncio`: request IDs, authenticated users, tracing spans and similar
"ambient" data that would otherwise have to be threaded through every
procedure signature.

<!-- toc -->

## Usage

```nim
import chronos
import chronos/contextvars

type User = object
  name: string

let currentUser* {.contextVar.} = User(name: "anonymous")

proc audit(action: string) =
  # Reads the innermost binding for the current logical task,
  # or the declared default when no binder is in scope.
  echo currentUser.value.name, ": ", action

proc handleRequest(user: User) {.async.} =
  currentUser.withValue(user):
    await sleepAsync(10.milliseconds)   # binding survives suspension
    audit("query")                      # sees `user`, not the default
```

(The `{.contextVar.}` pragma needs Nim 2.x; see below. On Nim 1.6, spell
`currentUser`'s declaration as `let currentUser* = newContextVar("currentUser", User(name: "anonymous"), private = false)`.)

A context variable is a value (a `ContextVar[T]` key), not a family of
generated identifiers. `let currentUser* {.contextVar.} = User(...)`
declares exactly one symbol, `currentUser`, whose type is
`ContextVar[User]`; every operation on it is a uniform, ordinary call:

- `cv.value` returns the innermost binding for the current logical task, or
  the key's default when nothing is bound (see [Required variables](#required-variables)
  for the no-default case).
- `ctx[cv]` performs the same read, against a captured `AsyncContext` snapshot
  instead of the ambient chain (see [Inspecting contexts](#inspecting-contexts)).
- `cv.withValue(v): body` binds `cv` to `v` for the dynamic extent of
  `body`, restoring the previous binding on every exit path (normal,
  exception, `CancelledError`).

`withValue` shares a name with `std/tables`'s `Table.withValue` but not a
meaning: `Table.withValue(key, value)` is a conditional-if-present,
mutate-in-place accessor, while `ContextVar[T].withValue(v)` is an
unconditional bind. The two coexist without ambiguity because Nim
overloads dispatch on receiver type, the same ordinary verb-sharing as
`len`/`[]` across the standard library.

Bindings nest (innermost wins) and propagate into tasks spawned within the
binder's extent. Two additional primitives, `currentContext()` and
`withContext(ctx, body)`, snapshot and restore the full binding chain for
synchronous-callback boundaries that don't go through `await`.

## The `{.contextVar.}` pragma

> **Requires Nim 2.x.** `{.contextVar.}` relies on macro pragmas attached
> to `let`/`var` sections, a capability the Nim compiler only gained in
> the 2.x series: the 1.6 compiler never invokes a macro attached this
> way, so the pragma silently fails to expand there. On Nim 1.6, declare
> keys with the raw constructors, [`newContextVar`/`newRequiredContextVar`](#the-raw-constructors),
> directly.

`{.contextVar.}` is the recommended way to declare a key: it derives both
the key's name and its `dumpContext` privacy from the declaration site
itself, the same way an ordinary `let`/`var`'s export marker already
governs every other kind of visibility in the module. It attaches between
the star and the type, the same position `{.threadvar.}` uses and for
the same reason: the parser's own `let`/`var` grammar has to do the
star/type/default parsing (`contextVar name*: T = default` is not
parseable Nim), so the pragma only rewrites the right-hand side after the
parser has already done its job.

```nim
let requestId* {.contextVar.} = ""              # T inferred; star -> exported
let currentScope* {.contextVar.}: Scope = nil   # explicit T (polymorphic default)
let internalCounter {.contextVar.} = 0          # no star -> private
var traceId* {.contextVar.}: string             # must-bind: no default
```

All four forms expand to exactly one symbol (a `let`/`var` binding a
`newContextVar`/`newRequiredContextVar` call), never a second, derived
identifier. `x*: T {.contextVar.}` (pragma after the type) is not
accepted; `x* {.contextVar.}: T` is the only order the grammar admits.

The `let`/`var` choice above is not just convention. The macro rejects
the wrong one at compile time: a defaulted key (has `= default`) must be
declared `let`; a must-bind key (no default) must be declared `var`.
`var requestId* {.contextVar.} = ""` and `let traceId* {.contextVar.}: string`
both fail to compile, with an error naming the correct spelling, rather
than silently accepting a keyword that doesn't match the key's arity.

The star controls two things at once, both derived from the same marker:
whether the symbol itself is exported (ordinary Nim visibility), and
whether the key registers with `dumpContext` (star -> `private = false`,
no star -> `private = true`; see [Privacy and the raw constructors](#privacy-and-the-raw-constructors)
below). Explicit `[T]` is needed only when the default is a polymorphic
literal (`nil`) or absent entirely (must-bind); `let requestId*
{.contextVar.} = ""` and `var traceId* {.contextVar.}: string` both settle
`T` without it.

### Overriding dump-visibility

The star-derived default covers the common case, but export and
dump-visibility are two different axes, and occasionally a declaration
needs them to disagree: an exported key whose value is still
too sensitive for a debug dump, or an unexported key a maintainer wants
surfaced in `dumpContext` for local debugging without changing its export
marker. `{.contextVar: (private: true|false).}` breaks the derivation for
that one declaration, leaving every other declaration's default
unaffected:

```nim
let requestId* {.contextVar: (private: true).} = ""     # exported, still dump-private
let internalCounter {.contextVar: (private: false).} = 0  # unexported, still dumped
```

The argument form composes with everything above it (explicit `[T]`,
the must-bind `var` form, the `let`/`var` grammar enforcement); it only
ever changes which `private` value reaches the underlying constructor
call. Omitting the argument (plain `{.contextVar.}`) keeps the
star-derived default; reach for the override only when a declaration's
export marker and its intended dump-visibility need to differ.

### The raw constructors

The pragma is sugar over two public, documented primitives: a distinct
name per arity, not two overloads of one name, because a bool-typed
default would otherwise collide with the must-bind constructor's own
`private: bool` parameter during overload resolution:

```nim
proc newContextVar*[T](name: string, default: T, private = true): ContextVar[T]
proc newRequiredContextVar*[T](name: string, private = true): ContextVar[T]
```

Call one directly when a key's name needs to be computed, when a key
belongs to a runtime-indexed family the pragma can't mint (one
declaration, one symbol; see [Keys as values](#keys-as-values) below), or
when composing another macro around key declarations. Each carries its
name as an explicit string, rather than one the compiler infers from the
identifier: the same DRY wart PEP 567's `ContextVar("name")` carries at
every raw call site. `cv.name`, `cv.hasDefault`, and `cv.private` are
read-only accessor procs over the same three values on any
`ContextVarBase`, sugar-declared or raw-constructed alike.

### Privacy and the raw constructors

`{.contextVar.}` keeps a key's name and privacy in lockstep with the
declaration's own export marker, so they can never drift apart. The raw
constructors cannot offer that guarantee: their `private` parameter is an
ordinary value argument, entirely decoupled from the enclosing
`let`/`var`'s own `*`. This decoupling is deliberate, not an oversight: a
non-exported `let` constructed with `newContextVar(..., private = false)`
still appears in *other* modules' `dumpContext`/`$ctx` output, even though
nothing outside its own module can read or bind it. Symmetrically,
an exported key constructed with `private = true` is reachable but
invisible to introspection. Neither case is a bug; both are pinned,
negative-tested behavior.

Both raw constructors' `private` **defaults to `true`**, mirroring the
`{.contextVar.}` pragma's own no-star-means-private mapping, and fail-safe
in the direction that matters: a key missing from a debug dump is
discoverable (grep the constructor call, add `private = false`), while a
sensitive value that leaked into a dump because a call site forgot the
argument is not. Pass `private = false` explicitly to register a
raw-constructed key for `dumpContext`, or prefer the pragma, whose star
marker sets this automatically.

## Semantics notes

A key's default is fixed once, at construction:
`newContextVar(name, default)` evaluates `default` exactly once, the way
PEP 567's `ContextVar(name, default=...)` does, not on every unbound read.
There is no per-read expression to keep cheap and side-effect-free,
because there is no per-read evaluation at all.

That trade introduces a hazard: for a `ref`-typed
`T`, a non-nil default is **one shared instance**, returned by every
unbound read across the whole process, not a fresh instance per read. Two
unrelated call sites that both read an unbound key with a mutable `ref`
default are handed the *same* object:

```nim
type Settings = ref object
  flags: seq[string]

let defaultSettings = Settings(flags: @[])
let currentSettings* {.contextVar.} = defaultSettings

proc corrupt() =
  currentSettings.value.flags.add "oops"   # mutates the shared default --
                                            # every future unbound reader
                                            # now sees "oops" too
```

Treat a `ref`-typed default as an immutable shared singleton. If a key
needs a fresh instance per unbound read, bind it explicitly with
`withValue` at the point of use instead of relying on the default; a lazy
`proc(): T` factory default is not offered: nothing in chronos needs one
today.

### Reads inside your own `{.cast(gcsafe).}` blocks

`cv.value`, `cv.withValue`, and `cv.isBound` are templates, and each
expands a narrowly-scoped `{.cast(gcsafe).}` into its caller: a key is
typically a module-level `let` holding a `ref`, so the read is formally a
global access, and the cast is what lets it appear in `{.gcsafe.}` code
(sound because keys are write-once at construction; see
[Registry and key lifetime](#registry-and-key-lifetime)).

Current Nim (through 2.2.x and devel at the time of writing) mishandles
*nested* `{.cast(gcsafe).}` blocks: when an inner cast block ends, the
compiler's effect tracking clears the enforcement outright instead of
restoring the enclosing block's state, so every statement *after* the
inner block loses the outer cast's protection. This is not specific to
chronos (two hand-written nested blocks reproduce it), but calling one
of the templates above inside your own cast block is an easy way to
trigger it, and the resulting "is not GC-safe" errors point at unrelated
statements after the call. Until the compiler fix propagates, hoist the
read above your cast block:

```nim
proc handler() {.gcsafe.} =
  let user = currentUser.value      # read first, outside the cast
  {.cast(gcsafe).}:
    touchGlobalState(user)
    runCallbacks()                  # stays covered by the outer cast
```

On a fixed compiler the hoist is unnecessary but harmless.

## Required variables

A key may omit its default entirely, using `newRequiredContextVar[T]`
(or the pragma's must-bind form, `var name* {.contextVar.}: T`):

```nim
var traceId* {.contextVar.}: string    # must-bind: no default
```

This declares a *must-bind* key, the analog of PEP 567's default-less
`ContextVar`. Reading `traceId.value` (or `ctx[traceId]`) while no
`withValue` binder is in scope raises `UnboundContextVarDefect` on both
paths; see [Implementation](#implementation) for why they're the same
read under the hood. The Defect's `varName: string` field names the
unbound key (`"traceId"` here):

```nim
proc handler() {.async: (raises: []).} =
  # traceId.value here would raise UnboundContextVarDefect unless a
  # caller already bound it.
  traceId.withValue(newTraceId()):
    await process()
```

`UnboundContextVarDefect` is a `Defect`, not a `CatchableError`. That's
deliberate, for two reasons:

- Reading a must-bind key before it's bound is a contract violation (the
  caller forgot a `withValue` somewhere up the call chain), not a
  recoverable runtime condition like a failed network call. `Defect` is
  chronos's (and Nim's) vocabulary for "this is a bug," the same category
  as an out-of-bounds index or a failed `doAssert`.
- `Defect`s sit outside Nim's `raises` effect tracking. A must-bind read
  can therefore happen inside an `{.async: (raises: []).}` proc (the
  common case for handler code that doesn't want to widen its raises
  list) without forcing every caller to declare or catch it. This
  diverges from PEP 567, whose `ctx[var]` raises a catchable
  `LookupError`; see [Divergences from cited precedent](#divergences-from-cited-precedent) below.

Everything else about a must-bind key is identical to a defaulted one: the
binder (`withValue`), spawn-time inheritance, propagation across `await`,
and restore-on-every-exit-path all use the exact same code path; only the
read's behavior on a miss differs. `dumpContext` is the one exception to
"behaves like the read"; see [Inspecting contexts](#inspecting-contexts)
for why introspection never raises.

### Checking boundness without reading

`cv in ctx` (`` `contains`(ctx: AsyncContext, cv: ContextVar[T]): bool ``)
and its ambient counterpart `cv.isBound` answer "is this key bound here?"
without raising and without returning a value: the non-raising complement
to the Defect above, for callers that want to branch on boundness rather
than catch a Defect or fall back to a default:

```nim
if traceId in currentContext():
  logSpan(traceId.value)
```

This is identity-correct, unlike inferring boundness from `dumpContext`'s
`bound` field: two keys can share a `name` (see [Registry and key lifetime](#registry-and-key-lifetime)),
and `dumpContext` groups its output by that name, so it cannot distinguish
which of two same-name keys is the one actually bound. `in`/`isBound` test
the key itself, by identity, so they answer correctly even in that case.
Works identically for a defaulted key: `cv in ctx` is `false` when
unbound even though `cv.value` would still return the default.

## Binding multiple variables

There is no combined "bind several at once" form; binding multiple keys
together is ordinary nested `withValue` blocks, one per key:

```nim
let currentUser* {.contextVar.} = User(name: "anonymous")
let requestId* {.contextVar.} = ""

proc handleRequest(user: User, reqId: string) {.async.} =
  currentUser.withValue(user):
    requestId.withValue(reqId):
      await sleepAsync(10.milliseconds)
      audit("query")   # sees both currentUser.value and requestId.value
```

Each `withValue` layer adds one `try`/`finally` frame, so the cost scales
with the number of keys bound at a given point, not with the number of
keys declared in scope elsewhere. Independent keys don't interact with
each other, so the nesting order between them is arbitrary: binding
`requestId` inside `currentUser` or the other way around produces the same
observable bindings either way.

## Spawn-time inheritance

A task spawned inside a binder (calling an `async` proc, `asyncSpawn`, or
registering a callback) inherits the spawner's binding chain as it existed
at the point of spawning. Because the chain is immutable, later re-binding
in the parent is invisible to the already-spawned child and vice versa:
a child's nested binding never leaks back to the parent.

Chain nodes own their bound value inline, so a `currentContext()` snapshot
(or a pending callback's captured chain) remains sound after the binder
that created it has exited.

## Keys as values

A `ContextVar[T]` is an ordinary value: it can be passed as a generic proc
parameter, stored in a `seq`/`array`, or used as a `Table` key. A generic
proc over the key itself, not just over its value type, works for free:

```nim
proc readOrDefault[T](cv: ContextVar[T]): T =
  cv.value      # `cv` is a runtime value here -- ordinary generic
                # dispatch, no macro expansion involved
```

chronos's own benchmark suite uses a runtime-indexed *array* of keys to
build a chain-depth ladder that a one-declaration-one-symbol pragma
cannot mint (`benchmarks/bench_contextvars.nim`):

```nim
var chainVars: array[16, ContextVar[int]]
for i in 0 ..< chainVars.len:
  chainVars[i] = newContextVar[int]("chain" & $(i + 1), 0)

# chainVars[i] is a value like any other -- index it, pass it, store it:
chainVars[3].withValue(1):
  discard chainVars[3].value
```

Two keys constructed with identical arguments (same name, same type,
same default) are still distinct: ref identity is key identity (see
[Implementation](#implementation)). `chainVars[0] != chainVars[1]` even
where their names happen to collide, and binding one is never observable
through the other.

## Bridging independent callbacks

`withValue` binds for the dynamic extent of one body inside one logical
task. A resource's independently-registered setup and teardown hooks (an
`onConnect` and a separate `onDisconnect`) are not that shape: two
independently-scheduled callbacks with no `await` or shared call stack
between them are, by construction, not a single logical task, and no
binder can span them. The dispatcher restores the context it captured at
scheduling time around *every* callback invocation (`fireWithContext` in
`chronos/internal/asyncengine.nim`), so nothing one callback binds
survives into a second, separately-scheduled callback: the next callback
observes whatever context it captured at its own registration.

An exit hook that never captured a snapshot runs under whatever
context was ambient at its own registration (typically empty), never
under another task's binding.

For that shape, use `currentContext()`/`withContext()` to capture a
snapshot in the enter hook and restore it in the exit hook:

```nim
var connContexts: Table[Connection, AsyncContext]

proc onConnect(conn: Connection) =
  currentUser.withValue(conn.authedUser):
    connContexts[conn] = currentContext()   # snapshot, not a push

proc onDisconnect(conn: Connection) =
  withContext(connContexts[conn]):
    audit("session ended")   # sees currentUser.value == conn.authedUser
  connContexts.del(conn)
```

`currentContext()` captures the whole binding chain as an immutable
snapshot that outlives the binder that created it; `withContext` runs code
under that snapshot without disturbing the caller's own chain on exit.
Because a snapshot is a value, not a chain mutation, the same snapshot can
be used from `withContext` any number of times, including from multiple
callbacks interleaved on the same dispatcher.

`AsyncContext` values are thread-affine: the chain they reference is
thread-local, garbage-collected memory (see [Migration and compatibility](#migration-and-compatibility)
on cross-thread scheduling), so a snapshot captured on one thread must not
be sent to or restored on another: "any number of times" means any
number of callbacks on the capturing thread.

chronos has no imperative token API (PEP 567's `ContextVar.set()`/
`Token.reset()` shape): within a single logical task, `withValue`
expresses every binding lifecycle, and across independent callbacks a
token could not work anyway: the dispatcher's restore-at-fire discipline
described above unwinds any push a callback leaves behind.
`tests/testcontextvarssurface.nim` pins the absence of a token API as a
compile-time check.

## Inspecting contexts

A default-initialized `AsyncContext` (`var ctx: AsyncContext`, never
assigned from `currentContext()`) is the *empty* context, the same one
every task starts with before any key is ever bound. Running under it via
`withContext` installs no bindings at all: a defaulted key reads its own
default, exactly as if no binder were ever entered, and a must-bind key
raises `UnboundContextVarDefect`, same as an unbound ambient read.

Three primitives exist purely for debugging and don't participate in the
hot paths at all: they cost nothing unless a program actually calls them.

### Identity

Two `AsyncContext` snapshots compare equal with `==` iff they reference
the same underlying chain head:

```nim
let a = currentContext()
let b = currentContext()
a == b            # true: no binding changed between the two captures

currentUser.withValue(someUser):
  let c = currentContext()
  a == c          # false: `c` was captured inside a new binder
```

This is identity equality (same chain-head pointer), not a value-by-value
comparison of bindings: two snapshots built independently that happen to
carry the same bindings are not `==`. `hash*(ctx: AsyncContext): Hash`
matches the same identity (a pointer-identity hash), so `AsyncContext`
works as a `Table`/`HashSet` key.

### `dumpContext`

`dumpContext(ctx: AsyncContext): seq[ContextVarEntry]` enumerates every
*registered* (non-private) key constructed anywhere in the program
(across every module, defaulted or must-bind) as it stands in `ctx`,
sorted by name:

```nim
type ContextVarEntry* = object
  name*: string
  bound*: bool
  value*: string
```

A private key (no star, or raw-constructed with `private = true`) never
appears here. See [The `{.contextVar.}` pragma](#the-contextvar-pragma)
for how the star maps to this filter, [Registry and key lifetime](#registry-and-key-lifetime)
for why a private key still registers, and
[Privacy and the raw constructors](#privacy-and-the-raw-constructors) for
the raw constructors' export-decoupling caveat.

Every registered key appears exactly once, bound or not, so a dump shows
everything that *could* be bound: the picture a debugger or log dump
actually wants. An unbound defaulted key shows `bound: false` and the
value its read would actually return (the rendered default); an unbound
must-bind key shows `bound: false` and a fixed `<unbound>` placeholder.
Calling `dumpContext` never raises `UnboundContextVarDefect` the way the
key's own read would, because introspection has to stay total to be
useful as a debugging tool. A value is rendered via `$` when the key's
type has one (checked with `when compiles`); otherwise it's shown as a
placeholder. A `ref`-typed key whose value is nil renders as the literal
string `"nil"` without calling `$` at all: `when compiles($v)` only
proves a matching overload exists, not that it tolerates a nil receiver,
and `dumpContext` walks every registered key including ones no caller has
bound yet.

`` `$`(ctx: AsyncContext): string `` renders the same information as a
single `{name: value, ...}` string, in the same sorted order, for quick
`echo`/logging use. Its format is not a stable, parseable contract: only
`dumpContext`'s structured `seq[ContextVarEntry]` is.

### Cost

All three are zero-cost in the sense that matters for this feature:
nothing on the read, bind, capture, or fire hot paths changed to support
them. `==` is one pointer comparison. `dumpContext` costs one walk of the
process-wide registry (see [Registry and key lifetime](#registry-and-key-lifetime))
plus one `$`-render per key, paid only when `dumpContext` is actually
called.

The no-lock argument behind that walk (see [Registry and key lifetime](#registry-and-key-lifetime))
assumes a static single-binary deployment, where every key is constructed
on the main thread before any other thread exists. It does not hold
across `dlopen`/shared-library boundaries: a library loaded after other
threads already exist can construct keys concurrently with readers on
those other threads, and unloading it leaves dangling registry entries.
Neither shape is a chronos use case today, but embedding chronos in a
plugin/shared-library host would need to revisit this registry's
construction discipline.

## Migration and compatibility

- On Nim 1.6, `{.contextVar.}` is unavailable (see [The `{.contextVar.}`
  pragma](#the-contextvar-pragma)); use the raw constructors there.
- The feature is additive: code that never constructs a `ContextVar` pays
  one pointer field per `AsyncCallback` and a pointer copy per capture.
- Cross-thread scheduling (`callSoon` on another thread's dispatcher via
  `DispatcherHandle`) fires the callback with an *empty* context: the
  origin thread's chain is thread-local, garbage-collected memory and
  cannot be shared. Same-thread scheduling through the same API captures
  normally.
- **Windows IOCP completions carry the registrant's context**, the same
  registration-time-capture contract as the epoll/kqueue paths: a
  completion fires with the context captured when its `OVERLAPPED` record
  was armed, not the context ambient when it fires. See
  [Capture discipline](#capture-discipline) for which sites capture and
  how the fallback behaves.

## Divergences from cited precedent

The uniform `.value`/`ctx[cv]`/`.withValue` vocabulary follows the shape
every mature ecosystem converged on: Python PEP 567 (`var.get()`,
`ctx[var]`), Kotlin (`coroutineContext[Key]`), Java JEP 446 ScopedValue
(`sv.get()`, `ScopedValue.where(sv, v).run(...)`), .NET `AsyncLocal`
(`v.Value`). None of them mint derived identifiers per variable: that's
the design principle this API borrows. Where chronos's design diverges
from those precedents:

- **PEP 567**: an unbound read there raises a catchable `LookupError`;
  here it raises `UnboundContextVarDefect`, a `Defect` (see
  [Required variables](#required-variables) for the raises-tracking
  rationale, a Nim-specific constraint Python has no analog of). Python's
  `Context.run(fn)` value-isolated execution is also not offered;
  `withContext`'s mutate-and-restore covers chronos's callback-boundary
  cases (see [Bridging independent callbacks](#bridging-independent-callbacks)).
- **Kotlin** couples a key and its value type through a companion object
  declared on the value type. chronos keeps independent factories
  (`newContextVar[T]`/`newRequiredContextVar[T]`) instead: Nim has no
  companion-object idiom, and the coupling wouldn't buy anything here.
- **JEP 446** forbids rebinding a `ScopedValue` within the same dynamic
  scope. chronos keeps arbitrary LIFO re-shadowing: `cv.withValue` nests
  freely, and the innermost binding always wins.
- **.NET** `AsyncLocal.Value` is an imperative setter with forward flow
  (`asyncLocal.Value = x` mutates ambient state going forward). Only its
  read spelling is cited here; the imperative-write model itself was
  rejected; see [Bridging independent callbacks](#bridging-independent-callbacks)
  above.

## Performance

The design goal is cost proportional to use: a program that never
constructs a `ContextVar` should pay a cost indistinguishable, on every
hot path, from a build without the feature at all. This is measured, not
assumed: every number below comes from `benchmarks/bench_contextvars.nim`,
run under both memory managers.

**refc** (chronos's most latency-sensitive consumers pin `--mm:refc`
unconditionally) and **orc** both show the dispatcher-level headline
metrics (`callSoon` schedule+fire, sleepAsync await chains, future
create/await, and the two memory metrics) landing within the same
run-to-run measurement noise as a pre-contextvars build, on both memory
managers; these come from the capture/restore substrate, which this
redesign left untouched.

Where the redesign *does* change measured cost is the per-node lookup
inside a bound chain walk. An RTTI-based per-node dispatch (an `of` test
against a distinct per-declaration subtype) was evaluated and rejected in
favor of the raw pointer compare used today; the difference is clearest
reading a key bound at chain depth 16 (the benchmark's worst case: the
read walks every intervening binding) under refc:

| metric (median, 4 runs/leg)                                  | result |
|----------------------------------------------------------------|--------|
| refc, chain read @ depth 16, `of` dispatch -> pointer dispatch | 44-57 ns -> 8-10 ns (~5-6x) |
| orc, chain read, all depths                                    | overlapping old/new ranges -- noise-neutral |
| `callSoon` / sleep-chain / future-churn, both MMs               | comparable to the prior design -- within measurement noise |
| memory (pending future, queued callback), both MMs             | byte-identical |

Per-call-class cost, confirmed by inspecting the generated C at each site
rather than inferred from throughput alone, and unaffected by this
redesign (substrate-level):

- leaf callback fire: one thread-local load + one predicted branch.
- continuation resume: the above plus one unconditional save/restore
  pair, required for correctness; a suspended continuation must not
  leak a stale binding into whatever fires next.
- user-callback construction: one thread-local load + one predicted
  branch; barrier-free on refc, and on orc the context copy is skipped
  entirely when no binder is live.
- registering a callback on a heap-allocated future (e.g. a cancel
  callback): one write-barrier call per `ref` field under refc, paid
  once, at the point ownership transfers into the heap field.

Struct cost: `sizeof(AsyncCallback)` grows by one pointer field (8 B);
a pending future's two embedded callbacks add 16 B combined.

A related, separately-motivated fix ships alongside this feature: the
dispatcher's internal callback queues previously used `std/deques`,
whose `popFirst` returns its element by value: a pre-existing cost
(present before contextvars, on the queue's original single `ref`
field) that contextvars' second `ref` field doubled. The dispatcher
now uses a small purpose-built queue (`chronos/internal/callbackqueue.nim`)
whose dequeue is barrier-free on the copy-out; this restores
queue-transport cost per hop to parity with what the pre-contextvars
codebase already paid on its one field.

## Internals

The rest of this document describes the implementation for chronos
contributors extending the context-variable substrate itself; application
code using the API above does not need it.

### Implementation

A key (`ContextVar[T]`) is a `ref object` inheriting a non-generic
`ContextVarBase`, which carries the name, the `dumpContext` render hook,
and the registry link. Ref identity IS key identity: `ContextVar[T]`
defines no custom `` `==` `` (Nim's builtin ref `==` is already identity
comparison), and `hash*(cv: ContextVarBase): Hash` is a pointer-identity
hash paired with that same `==`, never a custom, value-based one, so
two keys compare and hash equal only when they're the same allocation:
`let alias = someKey` compares equal to `someKey` (the intended re-export
pattern), while two keys built from identical constructor arguments are
distinct (see [Keys as values](#keys-as-values)). This identity hash is
what makes `ContextVar[T]` usable as a genuine `Table`/`HashSet` key, not
just a value stored under some other key. A value-`object` key was
rejected for the same reason as the `==`/`hash` pairing: a copy would get
its own address and silently stop being "the same key."

A context is an immutable, singly-linked chain of nodes, one per active
binding, each carrying the key it was bound under alongside the bound
value. A chain node needs to expose its key *without* knowing the node's
value type (the lookup walk visits every node on a chain regardless of
which `T` each one carries), so the key field lives one layer below the
generic `ContextNode[T]`, on a non-generic `ContextNodeKeyed` base
inserted between it and the chain's own `ContextNodeBase`. `withValue` is
the only code that ever builds a `ContextNode[T]`, and it always tags the
node with the very `ContextVar[T]` whose `T` matches the node's own type
parameter. So a node's real type is never in question once its key is
known, and the lookup walk's cast from `ContextNodeKeyed` to
`ContextNode[T]` is sound by that construction invariant, not by a runtime
type tag.

That invariant holds because every node reachable through an
`AsyncContext` was built by `withValue`, and `AsyncContext` itself can't
be fabricated from an arbitrary `ContextNodeBase`. `AsyncContext* =
object` wraps its chain head in a field private to this module: the only
route to a populated value in safe Nim is `currentContext()`'s own
capture, so no safe construction (not even from code that imports
`chronos/internal/contextnode` directly) can hand `withContext` a
snapshot whose chain wasn't built the normal way. This guarantee covers
every safe-Nim construction route; `cast[AsyncContext](node)` bypasses it
the same way a `cast` bypasses any Nim type's invariants.

The key field itself is stored as a raw `pointer` (`cast[pointer](cv)`)
rather than a traced `ContextVarBase` reference: `withValue` can run on
any thread once a key exists, and under `--mm:refc` the GC heap is
per-thread bookkeeping, so a traced ref field pointing at a key allocated
on a different thread increfs through the wrong thread's heap the moment
a second thread binds that key, reproducibly crashing under
`-d:useGcAssert`. A raw pointer sidesteps reference counting on every
memory manager, the same approach the prior registry design used for its
own `ptr` field. It is sound because node keys are only ever *compared*,
never dereferenced (`dumpContext` renders through the registry's own live
refs, not through the chain), and because keys are process-lifetime by
construction discipline (see [Registry and key lifetime](#registry-and-key-lifetime)
below).

Lookup (`` `[]`(AsyncContext, ContextVar[T]): T ``, the one real chain
walk) compares `node.key == cast[pointer](cv)` while walking (one
pointer comparison per node) and, on a match, reads the value out via
`cast[ContextNode[T]](node)`. `.value` is not a second read path: it's
`template value(cv) = currentContext()[cv]`, so the ambient spelling and
the snapshot spelling (`ctx[cv]`) are two spellings of this one walk.
Under a `chronosDebug` build, the cast is preceded by `doAssert node of
ContextNode[T]`, a checked downcast verifying the construction invariant
above, the same debug-only discipline `chainBalance` and the construction
lock below already use elsewhere in this module; release builds pay
nothing for it.

### Registry and key lifetime

Every key, private or not, links itself into a process-wide intrusive
list at construction, via a private `nextRegistered: ContextVarBase`
field threaded through `ContextVarBase` itself, so the registry costs no
separate allocation. Registration keeps a key alive for the life of the
process: a permanent, by-design leak, matching what a purely static,
module-level-global design would have gotten for free. This applies to
private keys too: a chain node's `key` field is an untraced raw pointer
(see [Implementation](#implementation) above), so an unregistered key
would have no other process-lifetime guarantee, and a chain node built
from a since-collected private key would dangle: a later key reusing the
freed address would then compare pointer-equal to the stale `node.key`
and read back the wrong value. `private` governs only `dumpContext`'s
enumeration filter, never a key's lifetime.

`newContextVar`/`newRequiredContextVar` are supported only *before* any
`createThread` call, the same write-once-then-read-only discipline the
registry already needs, enforced two ways.

The first is automatic, needs no setup, and runs in every build,
including a release build: on a key's first registration, chronos stamps
the constructing thread with a process-lifetime generation counter (not
`getThreadId()`, whose OS-level ids are recycled once a thread exits, and
so cannot tell a returning thread from an unrelated later one reusing its
id) and records that generation; every later registration doAsserts it
is running on the same thread, before either constructor's registry
mutation ever runs, so a violation leaves the registry exactly as it was.
A second thread constructing a key corrupts the GC heap under `--mm:refc`,
since a chain node's `key` field is an untraced raw pointer into whichever
thread built its key (see [Implementation](#implementation) above), and
this check fires the moment that hazard actually occurs: unconditionally,
because the hazard it prevents is not itself limited to debug builds, and
the construction path it runs on is cold.

Neither check makes a first construction on a thread that then exits
safe (the registry is left holding a reference into a dead thread's
heap), and while the guard keeps refusing every other thread's
construction from that point on, nothing makes the process itself sound
again.

The second is `lockContextVarConstruction()`, a stricter, `chronosDebug`-
only opt-in boundary: chronos does not wrap or intercept thread creation,
so nothing flips this lock automatically. Call it yourself at your
program's own construction/thread-creation boundary (the test suite is
its only caller today), and every `newContextVar`/`newRequiredContextVar`
call after that point asserts, on any thread, not just a different one
from the first. Neither check is a substitute for the other: the
automatic check catches the cross-thread case with no setup but tolerates
further same-thread construction after other threads already exist, while
the lock catches that too, but only once an application opts in. No lock
is paid on any path in a release build, and the lock itself runs only
under `chronosDebug`.

Applications are encouraged to call `lockContextVarConstruction()` at
their own thread-creation boundary in `chronosDebug` builds and in CI,
rather than relying on the automatic check alone: a construction-
discipline violation is far cheaper to catch there than to chase down as
an intermittent failure in production.

Duplicate name strings are representable (two independently-constructed
keys can share a `name`, matching PEP 567) and accepted as
cosmetic-only: `dumpContext` may show two entries with the same label, and
`UnboundContextVarDefect.varName` may be non-unique, but same-name keys
never alias: binding one is never observable through the other,
regardless of whether they share a name.

The render hook (feeding `dumpContext`/`` `$` ``) is instantiated once per
`T`, inside whichever raw constructor built the key, and stored on
`ContextVarBase` as a `{.nimcall.}` pointer, the same `when T is ref`
nil-guard and `when compiles($v)` fallback ladder as before, generic code
degraded to a plain proc pointer so a non-generic base field can hold it.

### Capture discipline

The obligation this section places on every scheduling-site author: a
context-blind trampoline (`bareCallback`) is sound only when everything
it fires either captured its own context at registration or is itself
context-neutral. `bareCallback` doesn't check this: it just fires with
an empty context, so a bare trampoline that starts firing
context-sensitive code without one of the other two constructors upstream
reintroduces a leak silently.

Every `AsyncCallback` construction site must pick one of three
constructors defined in `chronos/futures.nim`:

- `capturingCallback(fn, udata)`: for every scheduling site whose callback
  must observe registration-time bindings (`addCallback`, `callSoon`,
  `setTimer`, `addReader`/`addWriter`, `addSignal`/`addProcess`, `callIdle`,
  `closeSocket`/`closeHandle` after-callbacks), whether the callback is
  application code or chronos-internal. Captures the current context.
- `bareCallback(fn, udata)`: for chronos-internal trampolines (sentinels,
  cross-thread queue draining, the low-level per-operation IOCP
  read/write completion trampolines, `internalCallTick`'s `CallbackFunc`
  overloads) where no meaningful registration-time context exists: those
  trampolines only drive an internal future to completion, and that
  future's own awaiter already carries its own captured context. Fires
  with an empty context.
- `contextCallback(fn, udata, ctx)`: for reconstructing a callback from
  a context value captured *earlier* rather than the ambient one at the
  call site. Windows IOCP completion dispatch (`poll()` in
  `asyncengine.nim`) is the only caller: it fires every completion with
  whatever `CompletionData.context` an upstream arm site
  (`registerWaitable`, a stream server's `start()`) stored via
  `captureContextInto`, or an empty context if the arm site didn't opt
  in, the same fail-closed default as `bareCallback`. A stream server's
  accept loop captures its context once, at `start()`, and reuses it for
  every connection the server accepts, so a caller that binds a large
  value around `start()` pins it for the server's entire lifetime, not
  just for one call.

`internalCallTick` also has an `AsyncCallback`-taking overload
(`internalCallTick(acb: AsyncCallback)`) that schedules whatever
`AsyncCallback` the caller already built: the caller picks the
constructor when building that value. Only the convenience `CallbackFunc`
overloads (`internalCallTick(cbproc, data)`) default to `bareCallback` and
are therefore context-blind by design.

Only `capturingCallback`/`bareCallback`/`contextCallback` can construct an
`InternalAsyncCallback`: `function`/`udata`/`context` are private to
`chronos/futures.nim`, and no other module can read or modify a field
after construction (existing readers go through the exported
`function()`/`udata()`/`context()` getters). A raw
`AsyncCallback(function: ..., udata: ...)` literal, or a direct field
assignment, anywhere outside `chronos/futures.nim` fails to compile:
`tests/testcontextvarsguardrails.nim` pins this with `not compiles(...)`
checks.

Which constructor a given scheduling site calls is not something the type
system can check: the three share a shape, so picking the wrong one
compiles fine. `tests/testcontextvarssurface.nim` and
`tests/testcontextvarsguardrails.nim` enumerate every known
construction/capture site and pin its expected behavior; extending the
pins is part of adding a scheduling site.

### Tests

Tests live under `tests/testcontextvars*.nim`: construction and the
registry, ambient and `withValue` semantics, async propagation across the
dispatcher's scheduling sites, cross-module export rules, and the
compile-time and runtime drift guardrails above. Four of them (the
leak-guard, cross-thread-construction, dead-recording-thread, and
construction-lock suites) run from a standalone driver
(`tests/testcontextvarsstandalone.nim`) instead of `tests/testall.nim`:
the construction lock is a one-way switch that stays engaged for the
rest of the process once set, the leak-guard test deliberately lets a
Defect escape `poll` to prove the corruption check fires, and the
dead-recording-thread suite needs a process where no key has been
constructed yet to exercise its full scenario, so none of them can
safely share a process with a suite that constructs keys at runtime:
the driver runs each suite in its own subprocess.

#
#                     Chronos
#
#  (c) Copyright 2015 Dominik Picheta
#  (c) Copyright 2018-2025 Status Research & Development GmbH
#
#                Licensed under either of
#    Apache License, version 2.0, (LICENSE-APACHEv2)
#                MIT license (LICENSE-MIT)

{.push raises: [].}

import ./[config, srcloc]
import ./internal/contextnode

export srcloc

when chronosStackTrace:
  type StackTrace = string

type
  LocationKind* {.pure.} = enum
    Create
    Finish

  # TODO forbid nested poll
  # TODO https://github.com/nim-lang/Nim/issues/25976
  CallbackFunc* = proc (arg: pointer) {.gcsafe, raises: [].}

  # Internal type, not part of API
  InternalAsyncCallback* = object
    function: CallbackFunc
    udata: pointer
    context: ContextNodeBase
      ## Continuation-local context captured at scheduling time. A
      ## native `ref` field, MM-managed. Nil for callbacks scheduled
      ## outside any binding and for internal trampolines that don't
      ## fire user code. `SentinelCallback` (asyncengine.nim) must be a
      ## `template`, not `const`: Nim 2.x rejects `const` of an object
      ## with a `ref` field, and a module-level `let` is
      ## gcsafe-inaccessible from `poll`.
      ##
      ## `function`/`udata`/`context` are private to this module -
      ## only `capturingCallback`/`bareCallback` below can construct an
      ## `InternalAsyncCallback`.

  InternalCancelCallback* = object
    function: CallbackFunc
    context: ContextNodeBase
      ## Same capture/lifetime discipline as
      ## `InternalAsyncCallback.context` above. Private to this
      ## module - only `capturingCancelCallback` and the no-capture
      ## construction in `internalInitFutureBase` build one.

  FutureState* {.pure.} = enum
    Pending, Completed, Cancelled, Failed

  FutureFlag* {.pure.} = enum
    OwnCancelSchedule
      ## When OwnCancelSchedule is set, the owner of the future is responsible
      ## for implementing cancellation in one of 3 ways:
      ##
      ## * ensure that cancellation requests never reach the future by means of
      ##   not exposing it to user code, `await` and `tryCancel`
      ## * set `cancelCallback` to `nil` to stop cancellation propagation - this
      ##   is appropriate when it is expected that the future will be completed
      ##   in a regular way "soon"
      ## * set `cancelCallback` to a handler that implements cancellation in an
      ##   operation-specific way
      ##
      ## If `cancelCallback` is not set and the future gets cancelled, a
      ## `Defect` will be raised.

  FutureFlags* = set[FutureFlag]

  InternalFutureBase* = object of RootObj
    # Internal untyped future representation - the fields are not part of the
    # public API and neither is `InternalFutureBase`, ie the inheritance
    # structure may change in the future (haha)

    internalLocation*: array[LocationKind, ptr SrcLoc]
    internalCallback*: InternalAsyncCallback
      ## The vast majority of futures track a single callback only (the one
      ## installed by `await`) - to avoid allocating a seq (which involves
      ## making a separate allocation with space for several callbacks), we keep
      ## a spot in each future for that first one - the seq below will stay
      ## empty until a second callback is added
    internalCallbacks*: seq[InternalAsyncCallback]
    internalCancelcb*: InternalCancelCallback
    internalChild*: FutureBase
    internalState*: FutureState
    internalFlags*: FutureFlags
    internalError*: ref CatchableError ## Stored exception
    internalClosure*: iterator(f: FutureBase): FutureBase {.raises: [], gcsafe.}

    when chronosFutureId:
      internalId*: uint

    when chronosStackTrace:
      internalErrorStackTrace*: StackTrace
      internalStackTrace*: StackTrace ## For debugging purposes only.

    when chronosFutureTracking:
      internalNext*: FutureBase
      internalPrev*: FutureBase

  FutureBase* = ref object of InternalFutureBase
    ## Untyped Future

  Future*[T] = ref object of FutureBase ## Typed future.
    when T isnot void:
      internalValue*: T ## Stored value

  FutureDefect* = object of Defect
    cause*: FutureBase

  FutureError* = object of CatchableError
    future*: FutureBase

  CancelledError* = object of FutureError
    ## Exception raised when accessing the value of a cancelled future

func raiseFutureDefect(msg: static string, fut: FutureBase) {.
    noinline, noreturn.} =
  raise (ref FutureDefect)(msg: msg, cause: fut)

# --- InternalAsyncCallback: read-only accessors ------------------------------
#
# `function`/`udata`/`context` are private (see the type above). UFCS
# makes `callable.function` / `.udata` / `.context` reads compile
# unchanged at every existing call site.

func function*(acb: InternalAsyncCallback): CallbackFunc {.inline.} =
  acb.function

func udata*(acb: InternalAsyncCallback): pointer {.inline.} =
  acb.udata

func context*(acb: InternalAsyncCallback): ContextNodeBase {.inline.} =
  acb.context

# --- InternalCancelCallback: read-only accessors -----------------------------
#
# `function`/`context` are private (see the type above, defined beside
# `InternalAsyncCallback`). UFCS makes `callable.function` / `.context`
# reads compile the same way as `InternalAsyncCallback`'s.

func function*(acb: InternalCancelCallback): CallbackFunc {.inline.} =
  acb.function

func context*(acb: InternalCancelCallback): ContextNodeBase {.inline.} =
  acb.context

# --- Continuation-local context: dispatcher-facing primitives ---------------
#
# `ContextNodeBase` is deliberately unnameable outside modules that
# import `contextnode.nim` directly; `asyncengine.nim` reaches it only
# by inference, so `currentAsyncContext`, the constructors below, and
# `withRestoredContext`/`pinContext` all live here rather than in
# `chronos/contextvars.nim`.

var currentAsyncContext* {.threadvar.}: ContextNodeBase
  ## Per-thread head of the binding chain. Chronos is single-thread-
  ## per-dispatcher, so this is effectively per-dispatcher.

template captureContextInto*(dest: var ContextNodeBase) =
  ## Capture the ambient context into `dest`. Call only on a freshly
  ## declared local, never an object literal field or `result` -
  ## otherwise refc's reset-then-assign copy-out doubles the
  ## write-barrier cost of every callback construction.
  if not isNil(currentAsyncContext):
    dest = currentAsyncContext

template capturingCallback*(fn: CallbackFunc, ud: pointer = nil): InternalAsyncCallback =
  ## Construct an AsyncCallback that captures the current continuation-local
  ## context, so the callback fires under the bindings live at its
  ## registration site. Use at every scheduling site whose callback must
  ## observe registration-time bindings — whether the callback is
  ## application code or chronos-internal (transport loops, combinators,
  ## the continuation pump all qualify); use `bareCallback` only for
  ## context-neutral trampolines that neither read contextVars nor fire
  ## code that does.
  ##
  ## Must be a template, not a proc returning by value: constructs into
  ## a fresh local via `captureContextInto` (see its doc for why).
  ## Param is `ud`, not `udata`: template substitution would otherwise
  ## rewrite the `acb.udata` field access below too.
  var acb: InternalAsyncCallback
  acb.function = fn
  acb.udata = ud
  captureContextInto(acb.context)
  acb

template bareCallback*(fn: CallbackFunc, ud: pointer = nil): InternalAsyncCallback =
  ## Construct an AsyncCallback for chronos-internal scaffolding (IOCP
  ## completion repackaging, idle-loop sentinels, fd-readiness
  ## trampolines) that doesn't itself read contextVars — no context
  ## capture. Downstream user-visible callbacks still carry their own
  ## context from their original `capturingCallback` site.
  ##
  ## Must be a template, like `SentinelCallback` in asyncengine.nim.
  ## Param is `ud`, not `udata`, for the same substitution reason as
  ## `capturingCallback`.
  InternalAsyncCallback(function: fn, udata: ud, context: nil)

template contextCallback*(fn: CallbackFunc, ud: pointer,
                          ctx: ContextNodeBase): InternalAsyncCallback =
  ## Construct an AsyncCallback carrying a context captured earlier
  ## rather than the ambient one here — for dispatch trampolines that
  ## stored the registrant's context at arm time and reconstruct the
  ## fired callback from it because the dispatching thread has no
  ## ambient binding of its own (e.g. Windows IOCP completion
  ## processing in `poll()`).
  InternalAsyncCallback(function: fn, udata: ud, context: ctx)

template capturingCancelCallback*(fn: CallbackFunc): InternalCancelCallback =
  ## Construct the value stored in `internalCancelcb`, capturing context
  ## at construction like `capturingCallback` - the handler must observe the
  ## context bound at `cancelCallback=` time, not whatever's ambient
  ## when it fires.
  var cb: InternalCancelCallback
  cb.function = fn
  captureContextInto(cb.context)
  cb

template withRestoredContext*(newCtx: ContextNodeBase, body: untyped) =
  ## Context switch with identity fast path. Sound only when `body`
  ## cannot dangle the binder chain across a suspend — i.e. body is not
  ## a continuation pump, or the pump's entry re-pins (`pinContext`).
  let chronosCtxPrev = currentAsyncContext        # one TLS read
  if newCtx == chronosCtxPrev:                    # identity - no writes,
    body                                          # no try/finally
    when defined(chronosDebug):
      doAssert currentAsyncContext == newCtx,
        "identity arm violated: a pump body went through " &
        "withRestoredContext without its own pinContext"
  else:
    currentAsyncContext = newCtx
    try: body
    finally: currentAsyncContext = chronosCtxPrev

template pinContext*(body: untyped) =
  ## Unconditional entry/exit guard ("the pin"), no fast path ever — for
  ## bodies that may suspend mid-binder (continuation pumps).
  let chronosCtxPrev = currentAsyncContext
  try: body
  finally: currentAsyncContext = chronosCtxPrev

when chronosFutureId:
  var currentID* {.threadvar.}: uint
  template id*(fut: FutureBase): uint = fut.internalId
else:
  template id*(fut: FutureBase): uint =
    cast[uint](addr fut[])

when chronosFutureTracking:
  type
    FutureList* = object
      head*: FutureBase
      tail*: FutureBase
      count*: uint

  var futureList* {.threadvar.}: FutureList

# Internal utilities - these are not part of the stable API
proc internalInitFutureBase*(fut: FutureBase, loc: ptr SrcLoc,
                             state: FutureState, flags: FutureFlags) =
  fut.internalState = state
  fut.internalLocation[LocationKind.Create] = loc
  fut.internalFlags = flags
  if FutureFlag.OwnCancelSchedule in flags:
    # Owners must replace `cancelCallback` with `nil` if they want to ignore
    # cancellations
    proc raiseNonCancellable(_: pointer) =
      raiseAssert "Cancellation request for non-cancellable future"
    # `fut` is freshly allocated, so `internalCancelcb.context` is
    # already nil from the allocator's zero-fill - write only the
    # `function` field rather than a whole-struct literal.
    fut.internalCancelcb.function = raiseNonCancellable

  if state != FutureState.Pending:
    fut.internalLocation[LocationKind.Finish] = loc

  when chronosFutureId:
    currentID.inc()
    fut.internalId = currentID

  when chronosStackTrace:
    fut.internalStackTrace = getStackTrace()

  when chronosFutureTracking:
    if state == FutureState.Pending:
      fut.internalNext = nil
      fut.internalPrev = futureList.tail
      if not(isNil(futureList.tail)):
        futureList.tail.internalNext = fut
      futureList.tail = fut
      if isNil(futureList.head):
        futureList.head = fut
      futureList.count.inc()

# Public API
template init*[T](F: type Future[T], fromProc: static[string] = ""): Future[T] =
  ## Creates a new pending future.
  ##
  ## Specifying ``fromProc``, which is a string specifying the name of the proc
  ## that this future belongs to, is a good habit as it helps with debugging.
  let res = Future[T]()
  internalInitFutureBase(res, getSrcLocation(fromProc), FutureState.Pending, {})
  res

template init*[T](F: type Future[T], fromProc: static[string] = "",
                  flags: static[FutureFlags]): Future[T] =
  ## Creates a new pending future.
  ##
  ## Specifying ``fromProc``, which is a string specifying the name of the proc
  ## that this future belongs to, is a good habit as it helps with debugging.
  let res = Future[T]()
  internalInitFutureBase(res, getSrcLocation(fromProc), FutureState.Pending,
                         flags)
  res

template completed*(
    F: type Future, fromProc: static[string] = ""): Future[void] =
  ## Create a new completed future
  let res = Future[void]()
  internalInitFutureBase(res, getSrcLocation(fromProc), FutureState.Completed,
                         {})
  res

template completed*[T: not void](
    F: type Future, valueParam: T, fromProc: static[string] = ""): Future[T] =
  ## Create a new completed future
  let res = Future[T](internalValue: valueParam)
  internalInitFutureBase(res, getSrcLocation(fromProc), FutureState.Completed,
                         {})
  res

template failed*[T](
    F: type Future[T], errorParam: ref CatchableError,
    fromProc: static[string] = ""): Future[T] =
  ## Create a new failed future
  let res = Future[T](internalError: errorParam)
  internalInitFutureBase(res, getSrcLocation(fromProc), FutureState.Failed, {})
  when chronosStackTrace:
    res.internalErrorStackTrace =
      if getStackTrace(res.error) == "":
        getStackTrace()
      else:
        getStackTrace(res.error)
  res

func state*(future: FutureBase): FutureState =
  future.internalState

func flags*(future: FutureBase): FutureFlags =
  future.internalFlags

func finished*(future: FutureBase): bool {.inline.} =
  ## Determines whether ``future`` has finished, i.e. ``future`` state changed
  ## from state ``Pending`` to one of the states (``Finished``, ``Cancelled``,
  ## ``Failed``).
  future.state != FutureState.Pending

func cancelled*(future: FutureBase): bool {.inline.} =
  ## Determines whether ``future`` has cancelled.
  future.state == FutureState.Cancelled

func failed*(future: FutureBase): bool {.inline.} =
  ## Determines whether ``future`` finished with an error.
  future.state == FutureState.Failed

func completed*(future: FutureBase): bool {.inline.} =
  ## Determines whether ``future`` finished with a value.
  future.state == FutureState.Completed

func location*(future: FutureBase): array[LocationKind, ptr SrcLoc] =
  future.internalLocation

func value*[T: not void](future: Future[T]): lent T =
  ## Return the value in a completed future - raises Defect when
  ## `fut.completed()` is `false`.
  ##
  ## See `read` for a version that raises a catchable error when future
  ## has not completed.
  when chronosStrictFutureAccess:
    if not future.completed():
      raiseFutureDefect("Future not completed while accessing value", future)

  future.internalValue

func value*(future: Future[void]) =
  ## Return the value in a completed future - raises Defect when
  ## `fut.completed()` is `false`.
  ##
  ## See `read` for a version that raises a catchable error when future
  ## has not completed.
  when chronosStrictFutureAccess:
    if not future.completed():
      raiseFutureDefect("Future not completed while accessing value", future)

func error*(future: FutureBase): ref CatchableError =
  ## Return the error of `future`, or `nil` if future did not fail.
  ##
  ## See `readError` for a version that raises a catchable error when the
  ## future has not failed.
  when chronosStrictFutureAccess:
    if not future.failed() and not future.cancelled():
      raiseFutureDefect(
        "Future not failed/cancelled while accessing error", future)

  future.internalError

when chronosFutureTracking:
  func next*(fut: FutureBase): FutureBase = fut.internalNext
  func prev*(fut: FutureBase): FutureBase = fut.internalPrev

when chronosStackTrace:
  func errorStackTrace*(fut: FutureBase): StackTrace = fut.internalErrorStackTrace
  func stackTrace*(fut: FutureBase): StackTrace = fut.internalStackTrace

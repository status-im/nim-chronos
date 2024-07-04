#
#                     Chronos
#
#  (c) Copyright 2015 Dominik Picheta
#  (c) Copyright 2018-2023 Status Research & Development GmbH
#
#                Licensed under either of
#    Apache License, version 2.0, (LICENSE-APACHEv2)
#                MIT license (LICENSE-MIT)

{.push raises: [].}

import "."/[config, srcloc]

export srcloc

when chronosStackTrace:
  type StackTrace = string

type
  LocationKind* {.pure.} = enum
    Create
    Finish

  CallbackFunc* = proc (arg: pointer) {.gcsafe, raises: [].}

  # Internal type, not part of API
  InternalAsyncCallback* = object
    function*: CallbackFunc
    udata*: pointer

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
    internalCallbacks*: seq[InternalAsyncCallback]
    internalCancelcb*: CallbackFunc
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
    fut.internalCancelcb = proc(_: pointer) =
      raiseAssert "Cancellation request for non-cancellable future"

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

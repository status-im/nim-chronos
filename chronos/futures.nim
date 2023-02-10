#
#                     Chronos
#
#  (c) Copyright 2015 Dominik Picheta
#  (c) Copyright 2018-2023 Status Research & Development GmbH
#
#                Licensed under either of
#    Apache License, version 2.0, (LICENSE-APACHEv2)
#                MIT license (LICENSE-MIT)

import stew/base10
import "."/[config, srcloc]
export srcloc

when chronosStackTrace:
  when defined(nimHasStacktracesModule):
    import system/stacktraces
  else:
    const
      reraisedFromBegin = -10
      reraisedFromEnd = -100

when chronosStackTrace:
  type StackTrace = string

type
  LocationKind* {.pure.} = enum
    Create
    Complete

  CallbackFunc* = proc (arg: pointer) {.gcsafe, raises: [Defect].}

  # Internal type, not part of API
  InternalAsyncCallback* = object
    function*: CallbackFunc
    udata*: pointer

  FutureState* {.pure.} = enum
    Pending, Completed, Cancelled, Failed

  FutureBase* = ref object of RootObj ## Untyped future.
    when defined(chronosPreviewV4):
      location: array[LocationKind, ptr SrcLoc]
      callbacks: seq[InternalAsyncCallback]
      cancelcb: CallbackFunc
      child: FutureBase
      state: FutureState
      error: ref CatchableError ## Stored exception
      mustCancel: bool
    else:
      location*: array[LocationKind, ptr SrcLoc]
      callbacks*: seq[InternalAsyncCallback]
      cancelcb*: CallbackFunc
      child*: FutureBase
      state*: FutureState
      error*: ref CatchableError ## Stored exception
      mustCancel*: bool

    when chronosFutureId:
      id*: uint

    when chronosStackTrace:
      errorStackTrace*: StackTrace
      stackTrace*: StackTrace ## For debugging purposes only.

    when chronosFutureTracking:
      next*: FutureBase
      prev*: FutureBase

  # ZAH: we have discussed some possible optimizations where
  # the future can be stored within the caller's stack frame.
  # How much refactoring is needed to make this a regular non-ref type?
  # Obviously, it will still be allocated on the heap when necessary.
  Future*[T] = ref object of FutureBase ## Typed future.
    when chronosStrictException:
      when (NimMajor, NimMinor) < (1, 4):
        closure*: iterator(f: Future[T]): FutureBase {.raises: [Defect, CatchableError], gcsafe.}
      else:
        closure*: iterator(f: Future[T]): FutureBase {.raises: [CatchableError], gcsafe.}
    else:
      closure*: iterator(f: Future[T]): FutureBase {.raises: [Exception], gcsafe.}

    when T isnot void:
      value*: T ## Stored value

  FutureDefect* = object of Defect
    cause*: FutureBase

  FutureError* = object of CatchableError

  CancelledError* = object of FutureError

when defined(chronosPreviewV4):
  type
    FuturePendingError* = object of FutureError
      ## Exception raised when trying to access the value or error of a future
      ## when the future is not finished

    FutureCompletedError* = object of FutureError
      ## Exception raised when trying to access the error of a future that
      ## completed successfully.

else:
  type
    # chronos V3 used `ValueError` when raising these
    FuturePendingError* = ValueError
    FutureCompletedError* = ValueError

# Backwards compatibility for old FutureState name
template Finished* {.deprecated: "Use Completed instead".} = Completed
template Finished*(T: type FutureState): FutureState {.deprecated: "Use FutureState.Completed instead".} = FutureState.Completed

const
  LocCreateIndex* = LocationKind.Create
  LocCompleteIndex* = LocationKind.Complete

when chronosFutureId:
  var currentID* {.threadvar.}: uint
  currentID = 0'u
else:
  template id*(f: FutureBase): uint =
    cast[uint](addr f[])

when chronosFutureTracking:
  type
    FutureList* = object
      head*: FutureBase
      tail*: FutureBase
      count*: uint

  var futureList* {.threadvar.}: FutureList
  futureList = FutureList()

proc setupFutureBase*(
    fut: FutureBase,
    loc: ptr SrcLoc,
    state = FutureState.Pending
    ) =
  fut.state = state
  fut.location[LocCreateIndex] = loc
  if state != FutureState.Pending:
    fut.location[LocCompleteIndex] = loc

  when chronosFutureId:
    currentID.inc()
    fut.id = currentID

  when chronosStackTrace:
    fut.stackTrace = getStackTrace()

  when chronosFutureTracking:
    if state == FutureState.Pending:
      fut.next = nil
      fut.prev = futureList.tail
      if not(isNil(futureList.tail)):
        futureList.tail.next = fut
      futureList.tail = fut
      if isNil(futureList.head):
        futureList.head = fut
      futureList.count.inc()

template newCancelledError(): ref CancelledError =
  (ref CancelledError)(msg: "Future operation cancelled!")

template newFuture*[T](fromProc: static[string] = ""): Future[T] =
  ## Creates a new future.
  ##
  ## Specifying ``fromProc``, which is a string specifying the name of the proc
  ## that this future belongs to, is a good habit as it helps with debugging.
  let res = Future[T]()
  setupFutureBase(res, getSrcLocation(fromProc))
  res

template completed*(
    F: type Future, fromProc: static[string] = ""): Future[void] =
  ## Create a new completed future
  let res = Future[T]()
  setupFutureBase(res, getSrcLocation(fromProc), FutureState.Completed)
  res

template completed*[T: not void](
    F: type Future, valueParam: T, fromProc: static[string] = ""): Future[T] =
  ## Create a new completed future
  let res = Future[T](value: valueParam)
  setupFutureBase(res, getSrcLocation(fromProc), FutureState.Completed)
  res

template failed*[T](
    F: type Future[T], errorParam: ref CatchableError,
    fromProc: static[string] = ""): Future[T] =
  ## Create a new failed future
  let res = Future[T](error: errorParam)
  setupFutureBase(res, getSrcLocation(fromProc), FutureState.Failed)
  when chronosStackTrace:
    res.errorStackTrace = if getStackTrace(res.error) == "":
                            getStackTrace()
                          else:
                            getStackTrace(res.error)

  res

template cancelled*[T](
    F: type Future[T], fromProc: static[string] = ""): Future[T] =
  ## Create a new cancelled future
  let res = Future[T](error: newCancelledError())
  setupFutureBase(res, getSrcLocation(fromProc), FutureState.Cancelled)
  when chronosStackTrace:
    res.errorStackTrace = res.stackTrace
  res

func finished*(future: FutureBase): bool {.inline.} =
  ## Determines whether ``future`` has completed, i.e. ``future`` state changed
  ## from state ``Pending`` to one of the states (``Finished``, ``Cancelled``,
  ## ``Failed``).
  future.state != FutureState.Pending

func cancelled*(future: FutureBase): bool {.inline.} =
  ## Determines whether ``future`` has cancelled.
  future.state == FutureState.Cancelled

func failed*(future: FutureBase): bool {.inline.} =
  ## Determines whether ``future`` completed with an error.
  future.state == FutureState.Failed

func completed*(future: FutureBase): bool {.inline.} =
  ## Determines whether ``future`` completed without an error.
  future.state == FutureState.Completed

when chronosStackTrace:
  import std/strutils

  template getFilenameProcname(entry: StackTraceEntry): (string, string) =
    when compiles(entry.filenameStr) and compiles(entry.procnameStr):
      # We can't rely on "entry.filename" and "entry.procname" still being valid
      # cstring pointers, because the "string.data" buffers they pointed to might
      # be already garbage collected (this entry being a non-shallow copy,
      # "entry.filename" no longer points to "entry.filenameStr.data", but to the
      # buffer of the original object).
      (entry.filenameStr, entry.procnameStr)
    else:
      ($entry.filename, $entry.procname)

  proc `$`(stackTraceEntries: seq[StackTraceEntry]): string =
    try:
      when defined(nimStackTraceOverride) and declared(addDebuggingInfo):
        let entries = addDebuggingInfo(stackTraceEntries)
      else:
        let entries = stackTraceEntries

      # Find longest filename & line number combo for alignment purposes.
      var longestLeft = 0
      for entry in entries:
        let (filename, procname) = getFilenameProcname(entry)

        if procname == "": continue

        let leftLen = filename.len + len($entry.line)
        if leftLen > longestLeft:
          longestLeft = leftLen

      var indent = 2
      # Format the entries.
      for entry in entries:
        let (filename, procname) = getFilenameProcname(entry)

        if procname == "":
          if entry.line == reraisedFromBegin:
            result.add(spaces(indent) & "#[\n")
            indent.inc(2)
          elif entry.line == reraisedFromEnd:
            indent.dec(2)
            result.add(spaces(indent) & "]#\n")
          continue

        let left = "$#($#)" % [filename, $entry.line]
        result.add((spaces(indent) & "$#$# $#\n") % [
          left,
          spaces(longestLeft - left.len + 2),
          procname
        ])
    except ValueError as exc:
      return exc.msg # Shouldn't actually happen since we set the formatting
                    # string

  proc injectStacktrace(future: FutureBase) =
    const header = "\nAsync traceback:\n"

    var exceptionMsg = future.error.msg
    if header in exceptionMsg:
      # This is messy: extract the original exception message from the msg
      # containing the async traceback.
      let start = exceptionMsg.find(header)
      exceptionMsg = exceptionMsg[0..<start]

    var newMsg = exceptionMsg & header

    let entries = getStackTraceEntries(future.error)
    newMsg.add($entries)

    newMsg.add("Exception message: " & exceptionMsg & "\n")

    # # For debugging purposes
    # newMsg.add("Exception type:")
    # for entry in getStackTraceEntries(future.error):
    #   newMsg.add "\n" & $entry
    future.error.msg = newMsg

# Internal utilities - these are not part of the stable API
proc internalCheckComplete*(fut: FutureBase) {.
     raises: [Defect, CatchableError].} =
  # For internal use only. Used in asyncmacro
  if not(isNil(fut.error)):
    when chronosStackTrace:
      injectStacktrace(fut)
    raise fut.error

template internalLocation*(fut: FutureBase): array[LocationKind, ptr SrcLoc] = fut.location
template internalCallbacks*(fut: FutureBase): seq[InternalAsyncCallback] = fut.callbacks
template internalState*(fut: FutureBase): FutureState = fut.state
template internalChild*(fut: FutureBase): FutureBase = fut.child
template internalCancelcb*(fut: FutureBase): CallbackFunc = fut.cancelcb
template internalMustCancel*(fut: FutureBase): bool = fut.mustCancel
template internalError*(fut: FutureBase): ref CatchableError = fut.error
template internalValue*[T](fut: Future[T]): T = fut.value

func location*(fut: FutureBase): array[LocationKind, ptr SrcLoc] = fut.location
func state*(fut: FutureBase): FutureState = fut.state

when defined(chronosPreviewV4):
  # `error` will change definition when we move to V4
  func error*(fut: FutureBase): ref CatchableError {.
      deprecated: "Use `readError` to access error of future".} = fut.error

  func `[]`*(loc: array[LocationKind, ptr SrcLoc], v: int): ptr SrcLoc =
    case v
    of 0: loc[LocationKind.Create]
    of 1: loc[LocationKind.Complete]
    else: raiseAssert("Unknown source location " & $v)

proc read*[T](future: Future[T] ): T {.
     raises: [Defect, CatchableError].} =
  ## Retrieves the value of ``future``. Future must be finished otherwise
  ## this function will fail with a ``FuturePendingError`` exception.
  ##
  ## If the result of the future is an error then that error will be raised.
  if future.finished():
    internalCheckComplete(future)
    when T isnot void:
      future.value
  else:
    raise (ref FuturePendingError)(msg: "Future still pending")

proc readError*[T](future: Future[T]): ref CatchableError {.
     raises: [Defect, FuturePendingError, FutureCompletedError].} =
  ## Retrieves the exception stored in ``future``.
  ##
  ## An ``FuturePendingError`` exception will be thrown if no exception exists
  ## in the specified Future.
  case future.state
  of FutureState.Pending:
    raise newException(FuturePendingError, "Future still pending")
  of FutureState.Completed:
    raise newException(FutureCompletedError, "Future completed with value")
  of {FutureState.Failed, FutureState.Cancelled}:
    future.error

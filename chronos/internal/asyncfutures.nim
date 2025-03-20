#
#                     Chronos
#
#  (c) Copyright 2015 Dominik Picheta
#  (c) Copyright 2018-2023 Status Research & Development GmbH
#
#                Licensed under either of
#    Apache License, version 2.0, (LICENSE-APACHEv2)
#                MIT license (LICENSE-MIT)

## Features and utilities for `Future` that integrate it with the dispatcher
## and the rest of the async machinery

{.push raises: [].}

import std/[sequtils, macros]
import stew/base10

import ./[asyncengine, raisesfutures]
import ../[config, futures]

export
  raisesfutures.Raising, raisesfutures.InternalRaisesFuture,
  raisesfutures.init, raisesfutures.error, raisesfutures.readError

when chronosStackTrace:
  import std/strutils
  when defined(nimHasStacktracesModule):
    import system/stacktraces
  else:
    const
      reraisedFromBegin = -10
      reraisedFromEnd = -100

template LocCreateIndex*: auto {.deprecated: "LocationKind.Create".} =
    LocationKind.Create
template LocFinishIndex*: auto {.deprecated: "LocationKind.Finish".} =
    LocationKind.Finish
template LocCompleteIndex*: untyped {.deprecated: "LocationKind.Finish".} =
  LocationKind.Finish

func `[]`*(loc: array[LocationKind, ptr SrcLoc], v: int): ptr SrcLoc {.
     deprecated: "use LocationKind".} =
  case v
  of 0: loc[LocationKind.Create]
  of 1: loc[LocationKind.Finish]
  else: raiseAssert("Unknown source location " & $v)

type
  FutureStr*[T] = ref object of Future[T]
    ## Deprecated
    gcholder*: string

  FutureSeq*[A, B] = ref object of Future[A]
    ## Deprecated
    gcholder*: seq[B]

  FuturePendingError* = object of FutureError
    ## Error raised when trying to `read` a Future that is still pending
  FutureCompletedError* = object of FutureError
    ## Error raised when trying access the error of a completed Future

  SomeFuture = Future|InternalRaisesFuture

func raiseFuturePendingError(fut: FutureBase) {.
    noinline, noreturn, raises: FuturePendingError.} =
  raise (ref FuturePendingError)(msg: "Future is still pending", future: fut)
func raiseFutureCompletedError(fut: FutureBase) {.
    noinline, noreturn, raises: FutureCompletedError.} =
  raise (ref FutureCompletedError)(
    msg: "Future is completed, cannot read error", future: fut)

# Backwards compatibility for old FutureState name
template Finished* {.deprecated: "Use Completed instead".} = Completed
template Finished*(T: type FutureState): FutureState {.
         deprecated: "Use FutureState.Completed instead".} =
           FutureState.Completed

proc newFutureImpl[T](loc: ptr SrcLoc, flags: FutureFlags): Future[T] =
  let fut = Future[T]()
  internalInitFutureBase(fut, loc, FutureState.Pending, flags)
  fut

proc newInternalRaisesFutureImpl[T, E](
    loc: ptr SrcLoc, flags: FutureFlags): InternalRaisesFuture[T, E] =
  let fut = InternalRaisesFuture[T, E]()
  internalInitFutureBase(fut, loc, FutureState.Pending, flags)
  fut

proc newFutureSeqImpl[A, B](loc: ptr SrcLoc): FutureSeq[A, B] =
  let fut = FutureSeq[A, B]()
  internalInitFutureBase(fut, loc, FutureState.Pending, {})
  fut

proc newFutureStrImpl[T](loc: ptr SrcLoc): FutureStr[T] =
  let fut = FutureStr[T]()
  internalInitFutureBase(fut, loc, FutureState.Pending, {})
  fut

template newFuture*[T](fromProc: static[string] = "",
                       flags: static[FutureFlags] = {}): auto =
  ## Creates a new future.
  ##
  ## Specifying ``fromProc``, which is a string specifying the name of the proc
  ## that this future belongs to, is a good habit as it helps with debugging.
  when declared(InternalRaisesFutureRaises): # injected by `asyncraises`
    newInternalRaisesFutureImpl[T, InternalRaisesFutureRaises](
      getSrcLocation(fromProc), flags)
  else:
    newFutureImpl[T](getSrcLocation(fromProc), flags)

template newInternalRaisesFuture*[T, E](fromProc: static[string] = ""): auto =
  ## Creates a new future.
  ##
  ## Specifying ``fromProc``, which is a string specifying the name of the proc
  ## that this future belongs to, is a good habit as it helps with debugging.
  newInternalRaisesFutureImpl[T, E](getSrcLocation(fromProc), {})

template newFutureSeq*[A, B](fromProc: static[string] = ""): FutureSeq[A, B] {.deprecated.} =
  ## Create a new future which can hold/preserve GC sequence until future will
  ## not be completed.
  ##
  ## Specifying ``fromProc``, which is a string specifying the name of the proc
  ## that this future belongs to, is a good habit as it helps with debugging.
  newFutureSeqImpl[A, B](getSrcLocation(fromProc))

template newFutureStr*[T](fromProc: static[string] = ""): FutureStr[T] {.deprecated.} =
  ## Create a new future which can hold/preserve GC string until future will
  ## not be completed.
  ##
  ## Specifying ``fromProc``, which is a string specifying the name of the proc
  ## that this future belongs to, is a good habit as it helps with debugging.
  newFutureStrImpl[T](getSrcLocation(fromProc))

proc done*(future: FutureBase): bool {.deprecated: "Use `completed` instead".} =
  ## This is an alias for ``completed(future)`` procedure.
  completed(future)

when chronosFutureTracking:
  proc futureDestructor(udata: pointer) =
    ## This procedure will be called when Future[T] got completed, cancelled or
    ## failed and all Future[T].callbacks are already scheduled and processed.
    let future = cast[FutureBase](udata)
    if future == futureList.tail: futureList.tail = future.prev
    if future == futureList.head: futureList.head = future.next
    if not(isNil(future.next)): future.next.internalPrev = future.prev
    if not(isNil(future.prev)): future.prev.internalNext = future.next
    futureList.count.dec()

  proc scheduleDestructor(future: FutureBase) {.inline.} =
    callSoon(futureDestructor, cast[pointer](future))

proc checkFinished(future: FutureBase, loc: ptr SrcLoc) =
  ## Checks whether `future` is finished. If it is then raises a
  ## ``FutureDefect``.
  if future.finished():
    var msg = ""
    msg.add("An attempt was made to complete a Future more than once. ")
    msg.add("Details:")
    msg.add("\n  Future ID: " & Base10.toString(future.id))
    msg.add("\n  Creation location:")
    msg.add("\n    " & $future.location[LocationKind.Create])
    msg.add("\n  First completion location:")
    msg.add("\n    " & $future.location[LocationKind.Finish])
    msg.add("\n  Second completion location:")
    msg.add("\n    " & $loc)
    when chronosStackTrace:
      msg.add("\n  Stack trace to moment of creation:")
      msg.add("\n" & indent(future.stackTrace.strip(), 4))
      msg.add("\n  Stack trace to moment of secondary completion:")
      msg.add("\n" & indent(getStackTrace().strip(), 4))
    msg.add("\n\n")
    var err = newException(FutureDefect, msg)
    err.cause = future
    raise err
  else:
    future.internalLocation[LocationKind.Finish] = loc

proc finish(fut: FutureBase, state: FutureState) =
  # We do not perform any checks here, because:
  # 1. `finish()` is a private procedure and `state` is under our control.
  # 2. `fut.state` is checked by `checkFinished()`.
  fut.internalState = state
  fut.internalCancelcb = nil # release cancellation callback memory
  for item in fut.internalCallbacks.mitems():
    if not(isNil(item.function)):
      callSoon(item)
    item = default(AsyncCallback) # release memory as early as possible
  fut.internalCallbacks = default(seq[AsyncCallback]) # release seq as well

  when chronosFutureTracking:
    scheduleDestructor(fut)

proc complete[T](future: Future[T], val: T, loc: ptr SrcLoc) =
  if not(future.cancelled()):
    checkFinished(future, loc)
    doAssert(isNil(future.internalError))
    future.internalValue = val
    future.finish(FutureState.Completed)

template complete*[T](future: Future[T], val: T) =
  ## Completes ``future`` with value ``val``.
  complete(future, val, getSrcLocation())

proc complete(future: Future[void], loc: ptr SrcLoc) =
  if not(future.cancelled()):
    checkFinished(future, loc)
    doAssert(isNil(future.internalError))
    future.finish(FutureState.Completed)

template complete*(future: Future[void]) =
  ## Completes a void ``future``.
  complete(future, getSrcLocation())

proc failImpl(
    future: FutureBase, error: ref CatchableError, loc: ptr SrcLoc) =
  if not(future.cancelled()):
    checkFinished(future, loc)
    future.internalError = error
    when chronosStackTrace:
      future.internalErrorStackTrace = if getStackTrace(error) == "":
                                 getStackTrace()
                               else:
                                 getStackTrace(error)
    future.finish(FutureState.Failed)

template fail*[T](
    future: Future[T], error: ref CatchableError, warn: static bool = false) =
  ## Completes ``future`` with ``error``.
  failImpl(future, error, getSrcLocation())

template fail*[T, E](
    future: InternalRaisesFuture[T, E], error: ref CatchableError,
    warn: static bool = true) =
  checkRaises(future, E, error, warn)
  failImpl(future, error, getSrcLocation())

template newCancelledError(): ref CancelledError =
  (ref CancelledError)(msg: "Future operation cancelled!")

proc cancelAndSchedule(future: FutureBase, loc: ptr SrcLoc) =
  if not(future.finished()):
    checkFinished(future, loc)
    future.internalError = newCancelledError()
    when chronosStackTrace:
      future.internalErrorStackTrace = getStackTrace()
    future.finish(FutureState.Cancelled)

template cancelAndSchedule*(future: FutureBase) =
  cancelAndSchedule(future, getSrcLocation())

proc tryCancel(future: FutureBase, loc: ptr SrcLoc): bool =
  ## Perform an attempt to cancel ``future``.
  ##
  ## NOTE: This procedure does not guarantee that cancellation will actually
  ## happened.
  ##
  ## Cancellation is the process which starts from the last ``future``
  ## descendent and moves step by step to the parent ``future``. To initiate
  ## this process procedure iterates through all non-finished ``future``
  ## descendents and tries to find the last one. If last descendent is still
  ## pending it will become cancelled and process will be initiated. In such
  ## case this procedure returns ``true``.
  ##
  ## If last descendent future is not pending, this procedure will be unable to
  ## initiate cancellation process and so it returns ``false``.
  if future.cancelled():
    return true
  if future.finished():
    return false

  if not(isNil(future.internalChild)):
    # If you hit this assertion, you should have used the `CancelledError`
    # mechanism and/or use a regular `addCallback`
    when chronosStrictFutureAccess:
      doAssert future.internalCancelcb.isNil,
        "futures returned from `{.async.}` functions must not use " &
        "`cancelCallback`"
    tryCancel(future.internalChild, loc)
  else:
    if not(isNil(future.internalCancelcb)):
      future.internalCancelcb(cast[pointer](future))
    if FutureFlag.OwnCancelSchedule notin future.internalFlags:
      cancelAndSchedule(future, loc)
    future.cancelled()

template tryCancel*(future: FutureBase): bool =
  tryCancel(future, getSrcLocation())

proc clearCallbacks(future: FutureBase) =
  future.internalCallbacks = default(seq[AsyncCallback])

proc addCallback*(future: FutureBase, cb: CallbackFunc, udata: pointer) =
  ## Adds the callbacks proc to be called when the future completes.
  ##
  ## If future has already completed then ``cb`` will be called immediately.
  doAssert(not isNil(cb))
  if future.finished():
    callSoon(cb, udata)
  else:
    future.internalCallbacks.add AsyncCallback(function: cb, udata: udata)

proc addCallback*(future: FutureBase, cb: CallbackFunc) =
  ## Adds the callbacks proc to be called when the future completes.
  ##
  ## If future has already completed then ``cb`` will be called immediately.
  future.addCallback(cb, cast[pointer](future))

proc removeCallback*(future: FutureBase, cb: CallbackFunc,
                     udata: pointer) =
  ## Remove future from list of callbacks - this operation may be slow if there
  ## are many registered callbacks!
  doAssert(not isNil(cb))
  # Make sure to release memory associated with callback, or reference chains
  # may be created!
  future.internalCallbacks.keepItIf:
    it.function != cb or it.udata != udata

proc removeCallback*(future: FutureBase, cb: CallbackFunc) =
  future.removeCallback(cb, cast[pointer](future))

proc `callback=`*(future: FutureBase, cb: CallbackFunc, udata: pointer) {.
    deprecated: "use addCallback/removeCallback/clearCallbacks to manage the callback list".} =
  ## Clears the list of callbacks and sets the callback proc to be called when
  ## the future completes.
  ##
  ## If future has already completed then ``cb`` will be called immediately.
  ##
  ## It's recommended to use ``addCallback`` or ``then`` instead.
  # ZAH: how about `setLen(1); callbacks[0] = cb`
  future.clearCallbacks
  future.addCallback(cb, udata)

proc `callback=`*(future: FutureBase, cb: CallbackFunc) {.
    deprecated: "use addCallback/removeCallback/clearCallbacks instead to manage the callback list".} =
  ## Sets the callback proc to be called when the future completes.
  ##
  ## If future has already completed then ``cb`` will be called immediately.
  {.push warning[Deprecated]: off.}
  `callback=`(future, cb, cast[pointer](future))
  {.pop.}

proc `cancelCallback=`*(future: FutureBase, cb: CallbackFunc) =
  ## Sets the callback procedure to be called when the future is cancelled.
  ##
  ## This callback will be called immediately as ``future.cancel()`` invoked and
  ## must be set before future is finished.

  when chronosStrictFutureAccess:
    doAssert not future.finished(),
      "cancellation callback must be set before finishing the future"
  future.internalCancelcb = cb

{.push stackTrace: off.}
proc futureContinue*(fut: FutureBase) {.raises: [], gcsafe.}

proc internalContinue(fut: pointer) {.raises: [], gcsafe.} =
  let asFut = cast[FutureBase](fut)
  GC_unref(asFut)
  futureContinue(asFut)

proc futureContinue*(fut: FutureBase) {.raises: [], gcsafe.} =
  # This function is responsible for calling the closure iterator generated by
  # the `{.async.}` transformation either until it has completed its iteration
  #
  # Every call to an `{.async.}` proc is redirected to call this function
  # instead with its original body captured in `fut.closure`.
  while true:
    # Call closure to make progress on `fut` until it reaches `yield` (inside
    # `await` typically) or completes / fails / is cancelled
    let next: FutureBase = fut.internalClosure(fut)
    if fut.internalClosure.finished(): # Reached the end of the transformed proc
      break

    if next == nil:
      raiseAssert "Async procedure (" & ($fut.location[LocationKind.Create]) &
                  ") yielded `nil`, are you await'ing a `nil` Future?"

    if not next.finished():
      # We cannot make progress on `fut` until `next` has finished - schedule
      # `fut` to continue running when that happens
      GC_ref(fut)
      next.addCallback(CallbackFunc(internalContinue), cast[pointer](fut))

      # return here so that we don't remove the closure below
      return

    # Continue while the yielded future is already finished.

  # `futureContinue` will not be called any more for this future so we can
  # clean it up
  fut.internalClosure = nil
  fut.internalChild = nil

{.pop.}

when chronosStackTrace:
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

  proc injectStacktrace(error: ref Exception) =
    const header = "\nAsync traceback:\n"

    var exceptionMsg = error.msg
    if header in exceptionMsg:
      # This is messy: extract the original exception message from the msg
      # containing the async traceback.
      let start = exceptionMsg.find(header)
      exceptionMsg = exceptionMsg[0..<start]

    var newMsg = exceptionMsg & header

    let entries = getStackTraceEntries(error)
    newMsg.add($entries)

    newMsg.add("Exception message: " & exceptionMsg & "\n")

    # # For debugging purposes
    # newMsg.add("Exception type:")
    # for entry in getStackTraceEntries(future.error):
    #   newMsg.add "\n" & $entry
    error.msg = newMsg

proc deepLineInfo(n: NimNode, p: LineInfo) =
  n.setLineInfo(p)
  for i in 0..<n.len:
    deepLineInfo(n[i], p)

macro internalRaiseIfError*(fut: FutureBase, info: typed) =
  # Check the error field of the given future and raise if it's set to non-nil.
  # This is a macro so we can capture the line info from the original call and
  # report the correct line number on exception effect violation
  let
    info = info.lineInfoObj()
    res = quote do:
      if not(isNil(`fut`.internalError)):
        when chronosStackTrace:
          injectStacktrace(`fut`.internalError)
        raise `fut`.internalError
  res.deepLineInfo(info)
  res

macro internalRaiseIfError*(fut: InternalRaisesFuture, raises, info: typed) =
  # For InternalRaisesFuture[void, (ValueError, OSError), will do:
  # {.cast(raises: [ValueError, OSError]).}:
  #   if isNil(f.error): discard
  #   else: raise f.error
  # TODO https://github.com/nim-lang/Nim/issues/22937
  #      we cannot `getTypeInst` on the `fut` - when aliases are involved, the
  #      generics are lost - so instead, we pass the raises list explicitly

  let
    info = info.lineInfoObj()
    types = getRaisesTypes(raises)

  if isNoRaises(types):
    return quote do:
      if not(isNil(`fut`.internalError)):
        # This would indicate a bug in which `error` was set via the non-raising
        # base type
        raiseAssert("Error set on a non-raising future: " & `fut`.internalError.msg)

  expectKind(types, nnkBracketExpr)
  expectKind(types[0], nnkSym)

  assert types[0].strVal == "tuple"

  let
    internalError = nnkDotExpr.newTree(fut, ident "internalError")

    ifRaise = nnkIfExpr.newTree(
      nnkElifExpr.newTree(
        nnkCall.newTree(ident"isNil", internalError),
        nnkDiscardStmt.newTree(newEmptyNode())
      ),
      nnkElseExpr.newTree(
        nnkRaiseStmt.newTree(internalError)
      )
    )

    res = nnkPragmaBlock.newTree(
      nnkPragma.newTree(
        nnkCast.newTree(
          newEmptyNode(),
          nnkExprColonExpr.newTree(
            ident"raises",
            block:
              var res = nnkBracket.newTree()
              for r in types[1..^1]:
                res.add(r)
              res
          )
        ),
      ),
      ifRaise
    )
  res.deepLineInfo(info)
  res

proc readFinished[T: not void](fut: Future[T]): lent T {.
    raises: [CatchableError].} =
  # Read a future that is known to be finished, avoiding the extra exception
  # effect.
  internalRaiseIfError(fut, fut)
  fut.internalValue

proc read*[T: not void](fut: Future[T] ): lent T {.raises: [CatchableError].} =
  ## Retrieves the value of `fut`.
  ##
  ## If the future failed or was cancelled, the corresponding exception will be
  ## raised.
  ##
  ## If the future is still pending, `FuturePendingError` will be raised.
  if not fut.finished():
    raiseFuturePendingError(fut)

  fut.readFinished()

proc read*(fut: Future[void]) {.raises: [CatchableError].} =
  ## Checks that `fut` completed.
  ##
  ## If the future failed or was cancelled, the corresponding exception will be
  ## raised.
  ##
  ## If the future is still pending, `FuturePendingError` will be raised.
  if not fut.finished():
    raiseFuturePendingError(fut)

  internalRaiseIfError(fut, fut)

proc readError*(fut: FutureBase): ref CatchableError {.raises: [FutureError].} =
  ## Retrieves the exception of the failed or cancelled `fut`.
  ##
  ## If the future was completed with a value, `FutureCompletedError` will be
  ## raised.
  ##
  ## If the future is still pending, `FuturePendingError` will be raised.
  if not fut.finished():
    raiseFuturePendingError(fut)

  if isNil(fut.error):
    raiseFutureCompletedError(fut)

  fut.error

template taskFutureLocation(future: FutureBase): string =
  let loc = future.location[LocationKind.Create]
  "[" & (
    if len(loc.procedure) == 0: "[unspecified]" else: $loc.procedure & "()"
    ) & " at " & $loc.file & ":" & $(loc.line) & "]"

template taskErrorMessage(future: FutureBase): string =
  "Asynchronous task " & taskFutureLocation(future) &
  " finished with an exception \"" & $future.error.name &
  "\"!\nMessage: " & future.error.msg &
  "\nStack trace: " & future.error.getStackTrace()
template taskCancelMessage(future: FutureBase): string =
  "Asynchronous task " & taskFutureLocation(future) & " was cancelled!"

proc pollFor[F: Future | InternalRaisesFuture](fut: F): F {.raises: [].} =
  # Blocks the current thread of execution until `fut` has finished, returning
  # the given future.
  #
  # Must not be called recursively (from inside `async` procedures).
  #
  # See alse `awaitne`.
  if not(fut.finished()):
    var finished = false
    # Ensure that callbacks currently scheduled on the future run before returning
    proc continuation(udata: pointer) {.gcsafe.} = finished = true
    fut.addCallback(continuation)

    while not(finished):
      poll()

  fut

proc waitFor*[T: not void](fut: Future[T]): lent T {.raises: [CatchableError].} =
  ## Blocks the current thread of execution until `fut` has finished, returning
  ## its value.
  ##
  ## If the future failed or was cancelled, the corresponding exception will be
  ## raised.
  ##
  ## Must not be called recursively (from inside `async` procedures).
  ##
  ## See also `await`, `Future.read`
  pollFor(fut).readFinished()

proc waitFor*(fut: Future[void]) {.raises: [CatchableError].} =
  ## Blocks the current thread of execution until `fut` has finished.
  ##
  ## If the future failed or was cancelled, the corresponding exception will be
  ## raised.
  ##
  ## Must not be called recursively (from inside `async` procedures).
  ##
  ## See also `await`, `Future.read`
  pollFor(fut).internalRaiseIfError(fut)

proc asyncSpawn*(future: Future[void]) =
  ## Spawns a new concurrent async task.
  ##
  ## Tasks may not raise exceptions or be cancelled - a ``Defect`` will be
  ## raised when this happens.
  ##
  ## This should be used instead of ``discard`` and ``asyncCheck`` when calling
  ## an ``async`` procedure without ``await``, to ensure exceptions in the
  ## returned future are not silently discarded.
  ##
  ## Note, that if passed ``future`` is already finished, it will be checked
  ## and processed immediately.
  doAssert(not isNil(future), "Future is nil")

  proc cb(data: pointer) =
    if future.failed():
      raise newException(FutureDefect, taskErrorMessage(future))
    elif future.cancelled():
      raise newException(FutureDefect, taskCancelMessage(future))

  if not(future.finished()):
    # We adding completion callback only if ``future`` is not finished yet.
    future.addCallback(cb)
  else:
    cb(nil)

proc asyncCheck*[T](future: Future[T]) {.
    deprecated: "Raises Defect on future failure, fix your code and use" &
                " asyncSpawn!".} =
  ## This function used to raise an exception through the `poll` call if
  ## the given future failed - there's no way to handle such exceptions so this
  ## function is now an alias for `asyncSpawn`
  ##
  when T is void:
    asyncSpawn(future)
  else:
    proc cb(data: pointer) =
      if future.failed():
        raise newException(FutureDefect, taskErrorMessage(future))
      elif future.cancelled():
        raise newException(FutureDefect, taskCancelMessage(future))

    if not(future.finished()):
      # We adding completion callback only if ``future`` is not finished yet.
      future.addCallback(cb)
    else:
      cb(nil)

proc asyncDiscard*[T](future: Future[T]) {.
    deprecated: "Use asyncSpawn or `discard await`".} = discard
  ## `asyncDiscard` will discard the outcome of the operation - unlike `discard`
  ## it also throws away exceptions! Use `asyncSpawn` if you're sure your
  ## code doesn't raise exceptions, or `discard await` to ignore successful
  ## outcomes

proc `and`*[T, Y](fut1: Future[T], fut2: Future[Y]): Future[void] {.
  deprecated: "Use allFutures[T](varargs[Future[T]])".} =
  ## Returns a future which will complete once both ``fut1`` and ``fut2``
  ## finish.
  ##
  ## If cancelled, ``fut1`` and ``fut2`` futures WILL NOT BE cancelled.
  var retFuture = newFuture[void]("chronos.`and`")
  proc cb(data: pointer) =
    if not(retFuture.finished()):
      if fut1.finished() and fut2.finished():
        if cast[pointer](fut1) == data:
          if fut1.failed():
            retFuture.fail(fut1.error)
          else:
            retFuture.complete()
        else:
          if fut2.failed():
            retFuture.fail(fut2.error)
          else:
            retFuture.complete()
  fut1.addCallback(cb)
  fut2.addCallback(cb)

  proc cancellation(udata: pointer) =
    # On cancel we remove all our callbacks only.
    if not(fut1.finished()):
      fut1.removeCallback(cb)
    if not(fut2.finished()):
      fut2.removeCallback(cb)

  retFuture.cancelCallback = cancellation
  return retFuture

template orImpl*[T, Y](fut1: Future[T], fut2: Future[Y]): untyped =
  var cb: proc(udata: pointer) {.gcsafe, raises: [].}
  cb = proc(udata: pointer) {.gcsafe, raises: [].} =
    if not(retFuture.finished()):
      var fut = cast[FutureBase](udata)
      if cast[pointer](fut1) == udata:
        fut2.removeCallback(cb)
      else:
        fut1.removeCallback(cb)
      if fut.failed():
        retFuture.fail(fut.error, warn = false)
      else:
        retFuture.complete()

  proc cancellation(udata: pointer) =
    # On cancel we remove all our callbacks only.
    if not(fut1.finished()):
      fut1.removeCallback(cb)
    if not(fut2.finished()):
      fut2.removeCallback(cb)

  if fut1.finished():
    if fut1.failed():
      retFuture.fail(fut1.error, warn = false)
    else:
      retFuture.complete()
    return retFuture

  if fut2.finished():
    if fut2.failed():
      retFuture.fail(fut2.error, warn = false)
    else:
      retFuture.complete()
    return retFuture

  fut1.addCallback(cb)
  fut2.addCallback(cb)

  retFuture.cancelCallback = cancellation
  retFuture

proc `or`*[T, Y](fut1: Future[T], fut2: Future[Y]): Future[void] =
  ## Returns a future which will complete once either ``fut1`` or ``fut2``
  ## finish.
  ##
  ## If ``fut1`` or ``fut2`` future is failed, the result future will also be
  ## failed with an error stored in ``fut1`` or ``fut2`` respectively.
  ##
  ## If both ``fut1`` and ``fut2`` future are completed or failed, the result
  ## future will depend on the state of ``fut1`` future. So if ``fut1`` future
  ## is failed, the result future will also be failed, if ``fut1`` future is
  ## completed, the result future will also be completed.
  ##
  ## If cancelled, ``fut1`` and ``fut2`` futures WILL NOT BE cancelled.
  var retFuture = newFuture[void]("chronos.or()")
  orImpl(fut1, fut2)


proc all*[T](futs: varargs[Future[T]]): auto {.
  deprecated: "Use allFutures(varargs[Future[T]])".} =
  ## Returns a future which will complete once all futures in ``futs`` finish.
  ## If the argument is empty, the returned future completes immediately.
  ##
  ## If the awaited futures are not ``Future[void]``, the returned future
  ## will hold the values of all awaited futures in a sequence.
  ##
  ## If the awaited futures *are* ``Future[void]``, this proc returns
  ## ``Future[void]``.
  ##
  ## Note, that if one of the futures in ``futs`` will fail, result of ``all()``
  ## will also be failed with error from failed future.
  ##
  ## TODO: This procedure has bug on handling cancelled futures from ``futs``.
  ## So if future from ``futs`` list become cancelled, what must be returned?
  ## You can't cancel result ``retFuture`` because in such way infinite
  ## recursion will happen.
  let totalFutures = len(futs)
  var completedFutures = 0

  # Because we can't capture varargs[T] in closures we need to create copy.
  var nfuts = @futs

  when T is void:
    var retFuture = newFuture[void]("chronos.all(void)")
    proc cb(udata: pointer) =
      if not(retFuture.finished()):
        inc(completedFutures)
        if completedFutures == totalFutures:
          for nfut in nfuts:
            if nfut.failed():
              retFuture.fail(nfut.error)
              break
          if not(retFuture.failed()):
            retFuture.complete()

    for fut in nfuts:
      fut.addCallback(cb)

    if len(nfuts) == 0:
      retFuture.complete()

    return retFuture
  else:
    var retFuture = newFuture[seq[T]]("chronos.all(T)")
    var retValues = newSeq[T](totalFutures)

    proc cb(udata: pointer) =
      if not(retFuture.finished()):
        inc(completedFutures)
        if completedFutures == totalFutures:
          for k, nfut in nfuts:
            if nfut.failed():
              retFuture.fail(nfut.error)
              break
            else:
              retValues[k] = nfut.value
          if not(retFuture.failed()):
            retFuture.complete(retValues)

    for fut in nfuts:
      fut.addCallback(cb)

    if len(nfuts) == 0:
      retFuture.complete(retValues)

    return retFuture

proc oneIndex*[T](futs: varargs[Future[T]]): Future[int] {.
  deprecated: "Use one[T](varargs[Future[T]])".} =
  ## Returns a future which will complete once one of the futures in ``futs``
  ## complete.
  ##
  ## If the argument is empty, the returned future FAILS immediately.
  ##
  ## Returned future will hold index of completed/failed future in ``futs``
  ## argument.
  var nfuts = @futs
  var retFuture = newFuture[int]("chronos.oneIndex(T)")

  proc cb(udata: pointer) =
    var res = -1
    if not(retFuture.finished()):
      var rfut = cast[FutureBase](udata)
      for i in 0..<len(nfuts):
        if cast[FutureBase](nfuts[i]) != rfut:
          nfuts[i].removeCallback(cb)
        else:
          res = i
      retFuture.complete(res)

  for fut in nfuts:
    fut.addCallback(cb)

  if len(nfuts) == 0:
    retFuture.fail(newException(ValueError, "Empty Future[T] list"))

  return retFuture

proc oneValue*[T](futs: varargs[Future[T]]): Future[T] {.
  deprecated: "Use one[T](varargs[Future[T]])".} =
  ## Returns a future which will finish once one of the futures in ``futs``
  ## finish.
  ##
  ## If the argument is empty, returned future FAILS immediately.
  ##
  ## Returned future will hold value of completed ``futs`` future, or error
  ## if future was failed.
  var nfuts = @futs
  var retFuture = newFuture[T]("chronos.oneValue(T)")

  proc cb(udata: pointer) =
    var resFut: Future[T]
    if not(retFuture.finished()):
      var rfut = cast[FutureBase](udata)
      for i in 0..<len(nfuts):
        if cast[FutureBase](nfuts[i]) != rfut:
          nfuts[i].removeCallback(cb)
        else:
          resFut = nfuts[i]
      if resFut.failed():
        retFuture.fail(resFut.error)
      else:
        when T is void:
          retFuture.complete()
        else:
          retFuture.complete(resFut.read())

  for fut in nfuts:
    fut.addCallback(cb)

  if len(nfuts) == 0:
    retFuture.fail(newException(ValueError, "Empty Future[T] list"))

  return retFuture

proc cancelSoon(future: FutureBase, aftercb: CallbackFunc, udata: pointer,
                loc: ptr SrcLoc) {.raises: [].} =
  ## Perform cancellation ``future`` and call ``aftercb`` callback when
  ## ``future`` become finished (completed with value, failed or cancelled).
  ##
  ## NOTE: Compared to the `tryCancel()` call, this procedure call guarantees
  ## that ``future``will be finished (completed with value, failed or cancelled)
  ## as quickly as possible.
  proc checktick(udata: pointer) {.gcsafe, raises: [].} =
    # We trying to cancel Future on more time, and if `cancel()` succeeds we
    # return early.
    if tryCancel(future, loc):
      return
    # Cancellation signal was not delivered, so we trying to deliver it one
    # more time after one tick. But we need to check situation when child
    # future was finished but our completion callback is not yet invoked.
    if not(future.finished()):
      internalCallTick(checktick)

  proc continuation(udata: pointer) {.gcsafe.} =
    # We do not use `callSoon` here because we was just scheduled from `poll()`.
    if not(isNil(aftercb)):
      aftercb(udata)

  if future.finished():
    # We could not schedule callback directly otherwise we could fall into
    # recursion problem.
    if not(isNil(aftercb)):
      let loop = getThreadDispatcher()
      loop.callbacks.addLast(AsyncCallback(function: aftercb, udata: udata))
    return

  future.addCallback(continuation)
  # Initiate cancellation process.
  if not(tryCancel(future, loc)):
    # Cancellation signal was not delivered, so we trying to deliver it one
    # more time after async tick. But we need to check case, when future was
    # finished but our completion callback is not yet invoked.
    if not(future.finished()):
      internalCallTick(checktick)

template cancelSoon*(fut: FutureBase, cb: CallbackFunc, udata: pointer) =
  cancelSoon(fut, cb, udata, getSrcLocation())

template cancelSoon*(fut: FutureBase, cb: CallbackFunc) =
  cancelSoon(fut, cb, nil, getSrcLocation())

template cancelSoon*(fut: FutureBase, acb: AsyncCallback) =
  cancelSoon(fut, acb.function, acb.udata, getSrcLocation())

template cancelSoon*(fut: FutureBase) =
  cancelSoon(fut, nil, nil, getSrcLocation())

template cancel*(future: FutureBase) {.
         deprecated: "Please use cancelSoon() or cancelAndWait() instead".} =
  ## Cancel ``future``.
  cancelSoon(future, nil, nil, getSrcLocation())

proc cancelAndWait(
    loc: ptr SrcLoc,
    futs: varargs[FutureBase]
): Future[void] {.async: (raw: true, raises: []).} =
  let
    retFuture =
      Future[void].Raising([]).init(
        "chronos.cancelAndWait(varargs[FutureBase])",
        {FutureFlag.OwnCancelSchedule})
  var count = 0

  proc continuation(udata: pointer) {.gcsafe.} =
    dec(count)
    if count == 0:
      retFuture.complete()

  retFuture.cancelCallback = nil

  for futn in futs:
    if not(futn.finished()):
      inc(count)
      cancelSoon(futn, continuation, cast[pointer](futn), loc)

  if count == 0:
    retFuture.complete()

  retFuture

proc cancelAndWait(
    loc: ptr SrcLoc,
    futs: openArray[SomeFuture]
): Future[void] {.async: (raw: true, raises: []).} =
  cancelAndWait(loc, futs.mapIt(FutureBase(it)))

template cancelAndWait*(future: FutureBase): Future[void].Raising([]) =
  ## Perform cancellation ``future`` return Future which will be completed when
  ## ``future`` become finished (completed with value, failed or cancelled).
  ##
  ## NOTE: Compared to the `tryCancel()` call, this procedure call guarantees
  ## that ``future``will be finished (completed with value, failed or cancelled)
  ## as quickly as possible.
  cancelAndWait(getSrcLocation(), future)

template cancelAndWait*(future: SomeFuture): Future[void].Raising([]) =
  ## Perform cancellation ``future`` return Future which will be completed when
  ## ``future`` become finished (completed with value, failed or cancelled).
  ##
  ## NOTE: Compared to the `tryCancel()` call, this procedure call guarantees
  ## that ``future``will be finished (completed with value, failed or cancelled)
  ## as quickly as possible.
  cancelAndWait(getSrcLocation(), FutureBase(future))

template cancelAndWait*(futs: varargs[FutureBase]): Future[void].Raising([]) =
  ## Perform cancellation of all the ``futs``. Returns Future which will be
  ## completed when all the ``futs`` become finished (completed with value,
  ## failed or cancelled).
  ##
  ## NOTE: Compared to the `tryCancel()` call, this procedure call guarantees
  ## that all the ``futs``will be finished (completed with value, failed or
  ## cancelled) as quickly as possible.
  ##
  ## NOTE: It is safe to pass finished futures in ``futs`` (completed with
  ## value, failed or cancelled).
  ##
  ## NOTE: If ``futs`` is an empty array, procedure returns completed Future.
  cancelAndWait(getSrcLocation(), futs)

template cancelAndWait*(futs: openArray[SomeFuture]): Future[void].Raising([]) =
  ## Perform cancellation of all the ``futs``. Returns Future which will be
  ## completed when all the ``futs`` become finished (completed with value,
  ## failed or cancelled).
  ##
  ## NOTE: Compared to the `tryCancel()` call, this procedure call guarantees
  ## that all the ``futs``will be finished (completed with value, failed or
  ## cancelled) as quickly as possible.
  ##
  ## NOTE: It is safe to pass finished futures in ``futs`` (completed with
  ## value, failed or cancelled).
  ##
  ## NOTE: If ``futs`` is an empty array, procedure returns completed Future.
  cancelAndWait(getSrcLocation(), futs)

proc noCancel*[F: SomeFuture](future: F): auto = # async: (raw: true, raises: asyncraiseOf(future) - CancelledError
  ## Prevent cancellation requests from propagating to ``future`` while
  ## forwarding its value or error when it finishes.
  ##
  ## This procedure should be used when you need to perform operations which
  ## should not be cancelled at all cost, for example closing sockets, pipes,
  ## connections or servers. Usually it become useful in exception or finally
  ## blocks.
  when F is InternalRaisesFuture:
    type
      E = F.E
      InternalRaisesFutureRaises = E.remove(CancelledError)

  let retFuture = newFuture[F.T]("chronos.noCancel(T)",
                                {FutureFlag.OwnCancelSchedule})
  template completeFuture() =
    const canFail = when declared(InternalRaisesFutureRaises):
      InternalRaisesFutureRaises isnot void
    else:
      true

    if future.completed():
      when F.T is void:
        retFuture.complete()
      else:
        retFuture.complete(future.value)
    else:
      when canFail: # Avoid calling `failed` on non-failing raises futures
        if future.failed():
          retFuture.fail(future.error, warn = false)
        else:
          raiseAssert("Unexpected future state [" & $future.state & "]")
      else:
        raiseAssert("Unexpected future state [" & $future.state & "]")

  proc continuation(udata: pointer) {.gcsafe.} =
    completeFuture()

  if future.finished():
    completeFuture()
  else:
    retFuture.cancelCallback = nil
    future.addCallback(continuation)
  retFuture

proc allFutures*(futs: varargs[FutureBase]): Future[void] {.
    async: (raw: true, raises: [CancelledError]).} =
  ## Returns a future which will complete only when all futures in ``futs``
  ## will be completed, failed or canceled.
  ##
  ## If the argument is empty, the returned future COMPLETES immediately.
  ##
  ## On cancel all the awaited futures ``futs`` WILL NOT BE cancelled.
  var retFuture = newFuture[void]("chronos.allFutures()")
  let totalFutures = len(futs)
  var finishedFutures = 0

  # Because we can't capture varargs[T] in closures we need to create copy.
  var nfuts = @futs

  proc cb(udata: pointer) =
    if not(retFuture.finished()):
      inc(finishedFutures)
      if finishedFutures == totalFutures:
        retFuture.complete()
        reset(nfuts)

  proc cancellation(udata: pointer) =
    # On cancel we remove all our callbacks only.
    for i in 0..<len(nfuts):
      if not(nfuts[i].finished()):
        nfuts[i].removeCallback(cb)
    reset(nfuts)

  for fut in nfuts:
    if not(fut.finished()):
      fut.addCallback(cb)
    else:
      inc(finishedFutures)

  retFuture.cancelCallback = cancellation
  if len(nfuts) == 0 or len(nfuts) == finishedFutures:
    retFuture.complete()

  retFuture

proc allFutures*[T](futs: varargs[Future[T]]): Future[void] {.
    async: (raw: true, raises: [CancelledError]).} =
  ## Returns a future which will complete only when all futures in ``futs``
  ## will be completed, failed or canceled.
  ##
  ## If the argument is empty, the returned future COMPLETES immediately.
  ##
  ## On cancel all the awaited futures ``futs`` WILL NOT BE cancelled.
  # Because we can't capture varargs[T] in closures we need to create copy.
  allFutures(futs.mapIt(FutureBase(it)))

proc allFutures*[T, E](futs: varargs[InternalRaisesFuture[T, E]]): Future[void] {.
    async: (raw: true, raises: [CancelledError]).} =
  ## Returns a future which will complete only when all futures in ``futs``
  ## will be completed, failed or canceled.
  ##
  ## If the argument is empty, the returned future COMPLETES immediately.
  ##
  ## On cancel all the awaited futures ``futs`` WILL NOT BE cancelled.
  # Because we can't capture varargs[T] in closures we need to create copy.
  allFutures(futs.mapIt(FutureBase(it)))

proc allFinished*[F: SomeFuture](futs: varargs[F]): Future[seq[F]] {.
    async: (raw: true, raises: [CancelledError]).} =
  ## Returns a future which will complete only when all futures in ``futs``
  ## will be completed, failed or canceled.
  ##
  ## Returned sequence will hold all the Future[T] objects passed to
  ## ``allFinished`` with the order preserved.
  ##
  ## If the argument is empty, the returned future COMPLETES immediately.
  ##
  ## On cancel all the awaited futures ``futs`` WILL NOT BE cancelled.
  var retFuture = newFuture[seq[F]]("chronos.allFinished()")
  let totalFutures = len(futs)
  var finishedFutures = 0

  var nfuts = @futs

  proc cb(udata: pointer) =
    if not(retFuture.finished()):
      inc(finishedFutures)
      if finishedFutures == totalFutures:
        retFuture.complete(move(nfuts))

  proc cancellation(udata: pointer) =
    # On cancel we remove all our callbacks only.
    for fut in nfuts.mitems():
      if not(fut.finished()):
        fut.removeCallback(cb)
    reset(nfuts)

  for fut in nfuts:
    if not(fut.finished()):
      fut.addCallback(cb)
    else:
      inc(finishedFutures)

  retFuture.cancelCallback = cancellation
  if len(nfuts) == 0 or len(nfuts) == finishedFutures:
    retFuture.complete(nfuts)

  return retFuture

template oneImpl =
  # If one of the Future[T] already finished we return it as result
  for fut in futs:
    if fut.finished():
      retFuture.complete(fut)
      return retFuture

  # Because we can't capture varargs[T] in closures we need to create copy.
  var nfuts =
    when declared(fut0):
      @[fut0] & @futs
    else:
      @futs

  var cb: proc(udata: pointer) {.gcsafe, raises: [].}
  cb = proc(udata: pointer) {.gcsafe, raises: [].} =
    if not(retFuture.finished()):
      var res: F
      for i in 0..<len(nfuts):
        if cast[pointer](nfuts[i]) != udata:
          nfuts[i].removeCallback(cb)
        else:
          res = move(nfuts[i])
      retFuture.complete(res)
      reset(nfuts)
      reset(cb)

  proc cancellation(udata: pointer) =
    # On cancel we remove all our callbacks only.
    for i in 0..<len(nfuts):
      if not(nfuts[i].finished()):
        nfuts[i].removeCallback(cb)
    reset(nfuts)
    reset(cb)

  when declared(fut0):
    fut0.addCallback(cb)
  for fut in futs:
    fut.addCallback(cb)

  retFuture.cancelCallback = cancellation
  return retFuture

proc one*[F: SomeFuture](fut0: F, futs: varargs[F]): Future[F] {.
    async: (raw: true, raises: [CancelledError]).} =
  ## Returns a future which will complete and return completed Future[T] inside,
  ## when one of the futures in ``futs`` will be completed, failed or canceled.
  ##
  ## On success returned Future will hold finished Future[T].
  ##
  ## On cancel futures in ``futs`` WILL NOT BE cancelled.
  let retFuture = newFuture[F]("chronos.one()")
  if fut0.finished():
    retFuture.complete(fut0)
    return retFuture

  oneImpl

proc one*[F: SomeFuture](futs: openArray[F]): Future[F] {.
    async: (raw: true, raises: [ValueError, CancelledError]).} =
  ## Returns a future which will complete and return completed Future[T] inside,
  ## when one of the futures in ``futs`` will be completed, failed or canceled.
  ##
  ## If the argument is empty, the returned future FAILS immediately.
  ##
  ## On success returned Future will hold finished Future[T].
  ##
  ## On cancel futures in ``futs`` WILL NOT BE cancelled.
  let retFuture = newFuture[F]("chronos.one()")

  if len(futs) == 0:
    retFuture.fail(newException(ValueError, "Empty Future[T] list"))
    return retFuture

  oneImpl

template raceImpl =
  # If one of the Future[T] already finished we return it as result
  for fut in futs:
    if fut.finished():
      retFuture.complete(fut)
      return retFuture

  # Because we can't capture openArray/varargs in closures we need to create copy.
  var nfuts =
    when declared(fut0):
      @[fut0] & @futs
    else:
      @futs

  var cb: proc(udata: pointer) {.gcsafe, raises: [].}
  cb = proc(udata: pointer) {.gcsafe, raises: [].} =
    if not(retFuture.finished()):
      var res: FutureBase
      for i in 0..<len(nfuts):
        if cast[pointer](nfuts[i]) != udata:
          nfuts[i].removeCallback(cb)
        else:
          res = move(nfuts[i])
      retFuture.complete(res)
      reset(nfuts)
      reset(cb)

  proc cancellation(udata: pointer) =
    # On cancel we remove all our callbacks only.
    for i in 0..<len(nfuts):
      if not(nfuts[i].finished()):
        nfuts[i].removeCallback(cb)
    reset(nfuts)
    reset(cb)

  when declared(fut0):
    fut0.addCallback(cb, cast[pointer](fut0))
  for fut in futs:
    fut.addCallback(cb, cast[pointer](fut))

  retFuture.cancelCallback = cancellation

  return retFuture

proc race*(fut0: FutureBase, futs: varargs[FutureBase]): Future[FutureBase] {.
    async: (raw: true, raises: [CancelledError]).} =
  ## Returns a future which will complete and return finished FutureBase,
  ## when one of the given futures will be completed, failed or canceled.
  ##
  ## On success returned Future will hold finished FutureBase.
  ##
  ## On cancel futures in ``futs`` WILL NOT BE cancelled.
  let retFuture = newFuture[FutureBase]("chronos.race()")
  if fut0.finished:
    retFuture.complete(fut0)
    return retFuture

  raceImpl

proc race*(futs: openArray[FutureBase]): Future[FutureBase] {.
    async: (raw: true, raises: [ValueError, CancelledError]).} =
  ## Returns a future which will complete and return finished FutureBase,
  ## when one of the futures in ``futs`` will be completed, failed or canceled.
  ##
  ## If the argument is empty, the returned future FAILS immediately.
  ##
  ## On success returned Future will hold finished FutureBase.
  ##
  ## On cancel futures in ``futs`` WILL NOT BE cancelled.
  let retFuture = newFuture[FutureBase]("chronos.race()")

  if len(futs) == 0:
    retFuture.fail(newException(ValueError, "Empty Future[T] list"))
    return retFuture

  raceImpl

proc race*(futs: openArray[SomeFuture]): Future[FutureBase] {.
    async: (raw: true, raises: [ValueError, CancelledError]).} =
  ## Returns a future which will complete and return completed FutureBase,
  ## when one of the futures in ``futs`` will be completed, failed or canceled.
  ##
  ## If the argument is empty, the returned future FAILS immediately.
  ##
  ## On success returned Future will hold finished FutureBase.
  ##
  ## On cancel futures in ``futs`` WILL NOT BE cancelled.
  # Because we can't capture varargs[T] in closures we need to create copy.
  race(futs.mapIt(FutureBase(it)))

when (chronosEventEngine in ["epoll", "kqueue"]) or defined(windows):
  import std/os

  proc waitSignal*(signal: int): Future[void] {.
      async: (raw: true, raises: [AsyncError, CancelledError]).} =
    var retFuture = newFuture[void]("chronos.waitSignal()")
    var signalHandle: Opt[SignalHandle]

    template getSignalException(e: OSErrorCode): untyped =
      newException(AsyncError, "Could not manipulate signal handler, " &
                   "reason [" & $int(e) & "]: " & osErrorMsg(e))

    proc continuation(udata: pointer) {.gcsafe.} =
      if not(retFuture.finished()):
        if signalHandle.isSome():
          let res = removeSignal2(signalHandle.get())
          if res.isErr():
            retFuture.fail(getSignalException(res.error()))
          else:
            retFuture.complete()

    proc cancellation(udata: pointer) {.gcsafe.} =
      if not(retFuture.finished()):
        if signalHandle.isSome():
          let res = removeSignal2(signalHandle.get())
          if res.isErr():
            retFuture.fail(getSignalException(res.error()))

    signalHandle =
      block:
        let res = addSignal2(signal, continuation)
        if res.isErr():
          retFuture.fail(getSignalException(res.error()))
        Opt.some(res.get())

    retFuture.cancelCallback = cancellation
    retFuture

proc sleepAsync*(duration: Duration): Future[void] {.
    async: (raw: true, raises: [CancelledError]).} =
  ## Suspends the execution of the current async procedure for the next
  ## ``duration`` time.
  var retFuture = newFuture[void]("chronos.sleepAsync(Duration)")
  let moment = Moment.fromNow(duration)
  var timer: TimerCallback

  proc completion(data: pointer) {.gcsafe.} =
    if not(retFuture.finished()):
      retFuture.complete()
    timer = nil # Release circular reference (for gc:arc)

  proc cancellation(udata: pointer) {.gcsafe.} =
    if not isNil(timer):
      clearTimer(timer)
    timer = nil # Release circular reference (for gc:arc)

  retFuture.cancelCallback = cancellation
  timer = setTimer(moment, completion)
  return retFuture

proc sleepAsync*(ms: int): Future[void] {.
     inline, deprecated: "Use sleepAsync(Duration)",
     async: (raw: true, raises: [CancelledError]).} =
  result = sleepAsync(ms.milliseconds())

proc stepsAsync*(number: int): Future[void] {.
    async: (raw: true, raises: [CancelledError]).} =
  ## Suspends the execution of the current async procedure for the next
  ## ``number`` of asynchronous steps (``poll()`` calls).
  ##
  ## This primitive can be useful when you need to create more deterministic
  ## tests and cases.
  doAssert(number > 0, "Number should be positive integer")
  var
    retFuture = newFuture[void]("chronos.stepsAsync(int)")
    counter = 0
    continuation: proc(data: pointer) {.gcsafe, raises: [].}

  continuation = proc(data: pointer) {.gcsafe, raises: [].} =
    if not(retFuture.finished()):
      inc(counter)
      if counter < number:
        internalCallTick(continuation)
      else:
        retFuture.complete()

  if number <= 0:
    retFuture.complete()
  else:
    internalCallTick(continuation)

  retFuture

proc idleAsync*(): Future[void] {.
    async: (raw: true, raises: [CancelledError]).} =
  ## Suspends the execution of the current asynchronous task until "idle" time.
  ##
  ## "idle" time its moment of time, when no network events were processed by
  ## ``poll()`` call.
  var retFuture = newFuture[void]("chronos.idleAsync()")

  proc continuation(data: pointer) {.gcsafe.} =
    if not(retFuture.finished()):
      retFuture.complete()

  proc cancellation(udata: pointer) {.gcsafe.} =
    discard

  retFuture.cancelCallback = cancellation
  callIdle(continuation, nil)
  retFuture

proc withTimeout*[T](fut: Future[T], timeout: Duration): Future[bool] {.
    async: (raw: true, raises: [CancelledError]).} =
  ## Returns a future which will complete once ``fut`` completes or after
  ## ``timeout`` milliseconds has elapsed.
  ##
  ## If ``fut`` completes first the returned future will hold true,
  ## otherwise, if ``timeout`` milliseconds has elapsed first, the returned
  ## future will hold false.
  var
    retFuture = newFuture[bool]("chronos.withTimeout",
                                {FutureFlag.OwnCancelSchedule})
      # We set `OwnCancelSchedule` flag, because we going to cancel `retFuture`
      # manually at proper time.
    moment: Moment
    timer: TimerCallback
    timeouted = false

  template completeFuture(fut: untyped, timeout: bool): untyped =
    if fut.failed() or fut.completed():
      retFuture.complete(true)
    else:
      if timeout:
        retFuture.complete(false)
      else:
        retFuture.cancelAndSchedule()

  # TODO: raises annotation shouldn't be needed, but likely similar issue as
  # https://github.com/nim-lang/Nim/issues/17369
  proc continuation(udata: pointer) {.gcsafe, raises: [].} =
    if not(retFuture.finished()):
      if timeouted:
        # We should not unconditionally complete result future with `false`.
        # Initiated by timeout handler cancellation could fail, in this case
        # we could get `fut` in complete or in failed state, so we should
        # complete result future with `true` instead of `false` here.
        fut.completeFuture(timeouted)
        return
      if not(fut.finished()):
        # Timer exceeded first, we going to cancel `fut` and wait until it
        # not completes.
        timeouted = true
        fut.cancelSoon()
      else:
        # Future `fut` completed/failed/cancelled first.
        if not(isNil(timer)):
          clearTimer(timer)
        fut.completeFuture(false)
    timer = nil

  # TODO: raises annotation shouldn't be needed, but likely similar issue as
  # https://github.com/nim-lang/Nim/issues/17369
  proc cancellation(udata: pointer) {.gcsafe, raises: [].} =
    if not(fut.finished()):
      if not isNil(timer):
        clearTimer(timer)
      fut.cancelSoon()
    else:
      fut.completeFuture(false)
    timer = nil

  if fut.finished():
    retFuture.complete(true)
  else:
    if timeout.isZero():
      retFuture.complete(false)
    elif timeout.isInfinite():
      retFuture.cancelCallback = cancellation
      fut.addCallback(continuation)
    else:
      moment = Moment.fromNow(timeout)
      retFuture.cancelCallback = cancellation
      timer = setTimer(moment, continuation, nil)
      fut.addCallback(continuation)

  retFuture

proc withTimeout*[T](fut: Future[T], timeout: int): Future[bool] {.
     inline, deprecated: "Use withTimeout(Future[T], Duration)".} =
  withTimeout(fut, timeout.milliseconds())

proc waitUntilImpl[F: SomeFuture](fut: F, retFuture: auto,
                                  deadline: auto): auto =
  var timeouted = false

  template completeFuture(fut: untyped, timeout: bool): untyped =
    if fut.failed():
      retFuture.fail(fut.error(), warn = false)
    elif fut.cancelled():
      if timeout:
        # Its possible that `future` could be cancelled in some other place. In
        # such case we can't detect if it was our cancellation due to timeout,
        # or some other cancellation.
        retFuture.fail(newException(AsyncTimeoutError, "Timeout exceeded!"))
      else:
        retFuture.cancelAndSchedule()
    else:
      when type(fut).T is void:
        retFuture.complete()
      else:
        retFuture.complete(fut.value)

  proc continuation(udata: pointer) {.raises: [].} =
    if not(retFuture.finished()):
      if timeouted:
        # When timeout is exceeded and we cancelled future via cancelSoon(),
        # its possible that future at this moment already has value
        # and/or error.
        fut.completeFuture(timeouted)
        return
      if not(fut.finished()):
        timeouted = true
        fut.cancelSoon()
      else:
        fut.completeFuture(false)

  var cancellation: proc(udata: pointer) {.gcsafe, raises: [].}
  cancellation = proc(udata: pointer) {.gcsafe, raises: [].} =
    deadline.removeCallback(continuation)
    if not(fut.finished()):
      fut.cancelSoon()
    else:
      fut.completeFuture(false)

  if fut.finished():
    fut.completeFuture(false)
  else:
    if deadline.finished():
      retFuture.fail(newException(AsyncTimeoutError, "Timeout exceeded!"))
    else:
      retFuture.cancelCallback = cancellation
      fut.addCallback(continuation)
      deadline.addCallback(continuation)
  retFuture

proc waitImpl[F: SomeFuture](fut: F, retFuture: auto, timeout: Duration): auto =
  var
    moment: Moment
    timer: TimerCallback
    timeouted = false

  template completeFuture(fut: untyped, timeout: bool): untyped =
    if fut.failed():
      retFuture.fail(fut.error(), warn = false)
    elif fut.cancelled():
      if timeout:
        retFuture.fail(newException(AsyncTimeoutError, "Timeout exceeded!"))
      else:
        retFuture.cancelAndSchedule()
    else:
      when type(fut).T is void:
        retFuture.complete()
      else:
        retFuture.complete(fut.value)

  proc continuation(udata: pointer) {.raises: [].} =
    if not(retFuture.finished()):
      if timeouted:
        # We should not unconditionally fail `retFuture` with
        # `AsyncTimeoutError`. Initiated by timeout handler cancellation
        # could fail, in this case we could get `fut` in complete or in failed
        # state, so we should return error/value instead of `AsyncTimeoutError`.
        fut.completeFuture(timeouted)
        return
      if not(fut.finished()):
        # Timer exceeded first.
        timeouted = true
        fut.cancelSoon()
      else:
        # Future `fut` completed/failed/cancelled first.
        if not(isNil(timer)):
          clearTimer(timer)
        fut.completeFuture(false)
    timer = nil

  var cancellation: proc(udata: pointer) {.gcsafe, raises: [].}
  cancellation = proc(udata: pointer) {.gcsafe, raises: [].} =
    if not(fut.finished()):
      if not(isNil(timer)):
        clearTimer(timer)
      fut.cancelSoon()
    else:
      fut.completeFuture(false)

    timer = nil

  if fut.finished():
    fut.completeFuture(false)
  else:
    if timeout.isZero():
      retFuture.fail(newException(AsyncTimeoutError, "Timeout exceeded!"))
    elif timeout.isInfinite():
      retFuture.cancelCallback = cancellation
      fut.addCallback(continuation)
    else:
      moment = Moment.fromNow(timeout)
      retFuture.cancelCallback = cancellation
      timer = setTimer(moment, continuation, nil)
      fut.addCallback(continuation)

  retFuture

proc wait*[T](fut: Future[T], timeout = InfiniteDuration): Future[T] =
  ## Returns a future which will complete once future ``fut`` completes
  ## or if timeout of ``timeout`` milliseconds has been expired.
  ##
  ## If ``timeout`` is ``-1``, then statement ``await wait(fut)`` is
  ## equal to ``await fut``.
  ##
  ## TODO: In case when ``fut`` got cancelled, what result Future[T]
  ## should return, because it can't be cancelled too.
  var
    retFuture = newFuture[T]("chronos.wait(duration)",
                             {FutureFlag.OwnCancelSchedule})
      # We set `OwnCancelSchedule` flag, because we going to cancel `retFuture`
      # manually at proper time.

  waitImpl(fut, retFuture, timeout)

proc wait*[T](fut: Future[T], timeout = -1): Future[T] {.
     inline, deprecated: "Use wait(Future[T], Duration)".} =
  if timeout == -1:
    wait(fut, InfiniteDuration)
  elif timeout == 0:
    wait(fut, ZeroDuration)
  else:
    wait(fut, timeout.milliseconds())

proc wait*[T](fut: Future[T], deadline: SomeFuture): Future[T] =
  ## Returns a future which will complete once future ``fut`` completes
  ## or if ``deadline`` future completes.
  ##
  ## If `deadline` future completes before future `fut` -
  ## `AsyncTimeoutError` exception will be raised.
  ##
  ## Note: `deadline` future will not be cancelled and/or failed.
  ##
  ## Note: While `waitUntil(future)` operation is pending, please avoid any
  ## attempts to cancel future `fut`. If it happens `waitUntil()` could
  ## introduce undefined behavior - it could raise`CancelledError` or
  ## `AsyncTimeoutError`.
  ##
  ## If you need to cancel `future` - cancel `waitUntil(future)` instead.
  var
    retFuture = newFuture[T]("chronos.wait(future)",
                             {FutureFlag.OwnCancelSchedule})
      # We set `OwnCancelSchedule` flag, because we going to cancel `retFuture`
      # manually at proper time.
  waitUntilImpl(fut, retFuture, deadline)

proc join*(future: FutureBase): Future[void] {.
     async: (raw: true, raises: [CancelledError]).} =
  ## Returns a future which will complete once future ``future`` completes.
  ##
  ## This primitive helps to carefully monitor ``future`` state, in case of
  ## cancellation ``join`` operation it will not going to cancel ``future``.
  ##
  ## If ``future`` is already completed - ``join`` will return completed
  ## future immediately.
  let retFuture = newFuture[void]("chronos.join()")

  proc continuation(udata: pointer) {.gcsafe.} =
    retFuture.complete()

  proc cancellation(udata: pointer) {.gcsafe.} =
    future.removeCallback(continuation, cast[pointer](retFuture))

  if not(future.finished()):
    future.addCallback(continuation, cast[pointer](retFuture))
    retFuture.cancelCallback = cancellation
  else:
    retFuture.complete()

  retFuture

proc join*(future: SomeFuture): Future[void] {.
     async: (raw: true, raises: [CancelledError]).} =
  ## Returns a future which will complete once future ``future`` completes.
  ##
  ## This primitive helps to carefully monitor ``future`` state, in case of
  ## cancellation ``join`` operation it will not going to cancel ``future``.
  join(FutureBase(future))

when defined(windows):
  import ../osdefs

  proc waitForSingleObject*(handle: HANDLE,
                            timeout: Duration): Future[WaitableResult] {.
       async: (raises: [AsyncError, CancelledError], raw: true).} =
    ## Waits until the specified object is in the signaled state or the
    ## time-out interval elapses. WaitForSingleObject() for asynchronous world.
    let flags = WT_EXECUTEONLYONCE

    var
      retFuture = newFuture[WaitableResult]("chronos.waitForSingleObject()")
      waitHandle: WaitableHandle = nil

    proc continuation(udata: pointer) {.gcsafe.} =
      doAssert(not(isNil(waitHandle)))
      if not(retFuture.finished()):
        let
          ovl = cast[PtrCustomOverlapped](udata)
          returnFlag = WINBOOL(ovl.data.bytesCount)
          res = closeWaitable(waitHandle)
        if res.isErr():
          retFuture.fail(newException(AsyncError, osErrorMsg(res.error())))
        else:
          if returnFlag == TRUE:
            retFuture.complete(WaitableResult.Timeout)
          else:
            retFuture.complete(WaitableResult.Ok)

    proc cancellation(udata: pointer) {.gcsafe.} =
      doAssert(not(isNil(waitHandle)))
      if not(retFuture.finished()):
        discard closeWaitable(waitHandle)

    let wres = uint32(waitForSingleObject(handle, DWORD(0)))
    if wres == WAIT_OBJECT_0:
      retFuture.complete(WaitableResult.Ok)
      return retFuture
    elif wres == WAIT_ABANDONED:
      retFuture.fail(newException(AsyncError, "Handle was abandoned"))
      return retFuture
    elif wres == WAIT_FAILED:
      retFuture.fail(newException(AsyncError, osErrorMsg(osLastError())))
      return retFuture

    if timeout == ZeroDuration:
      retFuture.complete(WaitableResult.Timeout)
      return retFuture

    waitHandle =
      block:
        let res = registerWaitable(handle, flags, timeout, continuation, nil)
        if res.isErr():
          retFuture.fail(newException(AsyncError, osErrorMsg(res.error())))
          return retFuture
        res.get()

    retFuture.cancelCallback = cancellation
    return retFuture

{.pop.} # Automatically deduced raises from here onwards

proc readFinished[T: not void; E](fut: InternalRaisesFuture[T, E]): lent T =
  internalRaiseIfError(fut, E, fut)
  fut.internalValue

proc read*[T: not void, E](fut: InternalRaisesFuture[T, E]): lent T = # {.raises: [E, FuturePendingError].}
  ## Retrieves the value of `fut`.
  ##
  ## If the future failed or was cancelled, the corresponding exception will be
  ## raised.
  ##
  ## If the future is still pending, `FuturePendingError` will be raised.
  if not fut.finished():
    raiseFuturePendingError(fut)

  fut.readFinished()

proc read*[E](fut: InternalRaisesFuture[void, E]) = # {.raises: [E].}
  ## Checks that `fut` completed.
  ##
  ## If the future failed or was cancelled, the corresponding exception will be
  ## raised.
  ##
  ## If the future is still pending, `FuturePendingError` will be raised.
  if not fut.finished():
    raiseFuturePendingError(fut)

  internalRaiseIfError(fut, E, fut)

proc waitFor*[T: not void; E](fut: InternalRaisesFuture[T, E]): lent T = # {.raises: [E]}
  ## Blocks the current thread of execution until `fut` has finished, returning
  ## its value.
  ##
  ## If the future failed or was cancelled, the corresponding exception will be
  ## raised.
  ##
  ## Must not be called recursively (from inside `async` procedures).
  ##
  ## See also `await`, `Future.read`
  pollFor(fut).readFinished()

proc waitFor*[E](fut: InternalRaisesFuture[void, E]) = # {.raises: [E]}
  ## Blocks the current thread of execution until `fut` has finished.
  ##
  ## If the future failed or was cancelled, the corresponding exception will be
  ## raised.
  ##
  ## Must not be called recursively (from inside `async` procedures).
  ##
  ## See also `await`, `Future.read`
  pollFor(fut).internalRaiseIfError(E, fut)

proc `or`*[T, Y, E1, E2](
    fut1: InternalRaisesFuture[T, E1],
    fut2: InternalRaisesFuture[Y, E2]): auto =
  type
    InternalRaisesFutureRaises = union(E1, E2).union((CancelledError,))

  let retFuture = newFuture[void]("chronos.or()", {})
  orImpl(fut1, fut2)

proc wait*(fut: InternalRaisesFuture, timeout = InfiniteDuration): auto =
  type
    T = type(fut).T
    E = type(fut).E
    InternalRaisesFutureRaises = E.prepend(CancelledError, AsyncTimeoutError)

  let
    retFuture = newFuture[T]("chronos.wait(duration)", {OwnCancelSchedule})
      # We set `OwnCancelSchedule` flag, because we going to cancel `retFuture`
      # manually at proper time.

  waitImpl(fut, retFuture, timeout)

proc wait*(fut: InternalRaisesFuture, deadline: SomeFuture): auto =
  type
    T = type(fut).T
    E = type(fut).E
    InternalRaisesFutureRaises = E.prepend(CancelledError, AsyncTimeoutError)

  let
    retFuture = newFuture[T]("chronos.wait(future)", {OwnCancelSchedule})
      # We set `OwnCancelSchedule` flag, because we going to cancel `retFuture`
      # manually at proper time.

  waitUntilImpl(fut, retFuture, deadline)

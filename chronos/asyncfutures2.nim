#
#                     Chronos
#
#           (c) Copyright 2015 Dominik Picheta
#  (c) Copyright 2018-Present Status Research & Development GmbH
#
#                Licensed under either of
#    Apache License, version 2.0, (LICENSE-APACHEv2)
#                MIT license (LICENSE-MIT)

import os, tables, strutils, times, heapqueue, options, deques, cstrutils
import srcloc
export srcloc

const
  LocCreateIndex = 0
  LocCompleteIndex = 1

type
  CallbackFunc* = proc (arg: pointer = nil) {.gcsafe.}
  CallSoonProc* = proc (c: CallbackFunc, u: pointer = nil) {.gcsafe.}

  AsyncCallback* = object
    function*: CallbackFunc
    udata*: pointer
    deleted*: bool

  # ZAH: This can probably be stored with a cheaper representation
  # until the moment it needs to be printed to the screen
  # (e.g. seq[StackTraceEntry])
  StackTrace = string

  FutureState* {.pure.} = enum
    Pending, Finished, Cancelled, Failed

  FutureBase* = ref object of RootObj ## Untyped future.
    location: array[2, ptr SrcLoc]
    callbacks: Deque[AsyncCallback]
    cancelcb*: CallbackFunc
    child*: FutureBase
    state*: FutureState
    error*: ref Exception ## Stored exception
    errorStackTrace*: StackTrace
    stackTrace: StackTrace ## For debugging purposes only.
    id: int

  # ZAH: we have discussed some possible optimizations where
  # the future can be stored within the caller's stack frame.
  # How much refactoring is needed to make this a regular non-ref type?
  # Obviously, it will still be allocated on the heap when necessary.
  Future*[T] = ref object of FutureBase ## Typed future.
    value: T ## Stored value

  FutureStr*[T] = ref object of Future[T]
    ## Future to hold GC strings
    gcholder*: string

  FutureSeq*[A, B] = ref object of Future[A]
    ## Future to hold GC seqs
    gcholder*: seq[B]

  FutureVar*[T] = distinct Future[T]

  FutureError* = object of Exception
    cause*: FutureBase

  CancelledError* = object of FutureError

var currentID* {.threadvar.}: int
currentID = 0

# ZAH: This seems unnecessary. Isn't it easy to introduce a seperate
# module for the dispatcher type, so it can be directly referenced here?
var callSoonHolder {.threadvar.}: CallSoonProc

proc getCallSoonProc*(): CallSoonProc {.gcsafe.} =
  ## Get current implementation of ``callSoon``.
  return callSoonHolder

proc setCallSoonProc*(p: CallSoonProc) =
  ## Change current implementation of ``callSoon``.
  callSoonHolder = p

proc callSoon*(c: CallbackFunc, u: pointer = nil) =
  ## Call ``cbproc`` "soon".
  callSoonHolder(c, u)

template setupFutureBase(loc: ptr SrcLoc) =
  new(result)
  result.state = FutureState.Pending
  result.stackTrace = getStackTrace()
  result.id = currentID
  result.location[LocCreateIndex] = loc
  currentID.inc()

## ZAH: As far as I undestand `fromProc` is just a debugging helper.
## It would be more efficient if it's represented as a simple statically
## known `char *` in the final program (so it needs to be a `cstring` in Nim).
## The public API can be defined as a template expecting a `static[string]`
## and converting this immediately to a `cstring`.
proc newFuture[T](loc: ptr SrcLoc): Future[T] =
  setupFutureBase(loc)

proc newFutureSeq[A, B](loc: ptr SrcLoc): FutureSeq[A, B] =
  setupFutureBase(loc)

proc newFutureStr[T](loc: ptr SrcLoc): FutureStr[T] =
  setupFutureBase(loc)

proc newFutureVar[T](loc: ptr SrcLoc): FutureVar[T] =
  FutureVar[T](newFuture[T](loc))

template newFuture*[T](fromProc: static[string] = ""): auto =
  ## Creates a new future.
  ##
  ## Specifying ``fromProc``, which is a string specifying the name of the proc
  ## that this future belongs to, is a good habit as it helps with debugging.
  newFuture[T](getSrcLocation(fromProc))

template newFutureSeq*[A, B](fromProc: static[string] = ""): auto =
  ## Create a new future which can hold/preserve GC sequence until future will
  ## not be completed.
  ##
  ## Specifying ``fromProc``, which is a string specifying the name of the proc
  ## that this future belongs to, is a good habit as it helps with debugging.
  newFutureSeq[A, B](getSrcLocation(fromProc))

template newFutureStr*[T](fromProc: static[string] = ""): auto =
  ## Create a new future which can hold/preserve GC string until future will
  ## not be completed.
  ##
  ## Specifying ``fromProc``, which is a string specifying the name of the proc
  ## that this future belongs to, is a good habit as it helps with debugging.
  newFutureStr[T](getSrcLocation(fromProc))

template newFutureVar*[T](fromProc: static[string] = ""): auto =
  ## Create a new ``FutureVar``. This Future type is ideally suited for
  ## situations where you want to avoid unnecessary allocations of Futures.
  ##
  ## Specifying ``fromProc``, which is a string specifying the name of the proc
  ## that this future belongs to, is a good habit as it helps with debugging.
  newFutureVar[T](getSrcLocation(fromProc))

proc clean*[T](future: FutureVar[T]) =
  ## Resets the ``finished`` status of ``future``.
  Future[T](future).state = FutureState.Pending
  Future[T](future).error = nil

proc finished*(future: FutureBase | FutureVar): bool {.inline.} =
  ## Determines whether ``future`` has completed.
  ##
  ## ``True`` may indicate an error or a value. Use ``failed`` to distinguish.
  when future is FutureVar:
    result = (FutureBase(future).state != FutureState.Pending)
  else:
    result = (future.state != FutureState.Pending)

proc cancelled*(future: FutureBase): bool {.inline.} =
  ## Determines whether ``future`` has cancelled.
  result = (future.state == FutureState.Cancelled)

proc failed*(future: FutureBase): bool {.inline.} =
  ## Determines whether ``future`` completed with an error.
  result = (future.state == FutureState.Failed)

proc checkFinished[T](future: Future[T], loc: ptr SrcLoc) =
  ## Checks whether `future` is finished. If it is then raises a
  ## ``FutureError``.
  if future.finished():
    var msg = ""
    msg.add("An attempt was made to complete a Future more than once. ")
    msg.add("Details:")
    msg.add("\n  Future ID: " & $future.id)
    msg.add("\n  Creation location:")
    msg.add("\n    " & $future.location[LocCreateIndex])
    msg.add("\n  First completion location:")
    msg.add("\n    " & $future.location[LocCompleteIndex])
    msg.add("\n  Second completion location:")
    msg.add("\n    " & $loc)
    msg.add("\n  Stack trace to moment of creation:")
    msg.add("\n" & indent(future.stackTrace.strip(), 4))
    when T is string:
      msg.add("\n  Contents (string): ")
      msg.add("\n" & indent(future.value.repr, 4))
    msg.add("\n  Stack trace to moment of secondary completion:")
    msg.add("\n" & indent(getStackTrace().strip(), 4))
    msg.add("\n\n")
    var err = newException(FutureError, msg)
    err.cause = future
    raise err
  else:
    future.location[LocCompleteIndex] = loc

proc call(callbacks: var Deque[AsyncCallback]) =
  var count = len(callbacks)
  while count > 0:
    var item = callbacks.popFirst()
    if not(item.deleted):
      callSoon(item.function, item.udata)
    dec(count)

proc add(callbacks: var Deque[AsyncCallback], item: AsyncCallback) =
  if len(callbacks) == 0:
    callbacks = initDeque[AsyncCallback]()
  callbacks.addLast(item)

proc remove(callbacks: var Deque[AsyncCallback], item: AsyncCallback) =
  for p in callbacks.mitems():
    if p.function == item.function and p.udata == item.udata:
      p.deleted = true

proc complete[T](future: Future[T], val: T, loc: ptr SrcLoc) =
  checkFinished(future, loc)
  doAssert(isNil(future.error))
  future.value = val
  future.state = FutureState.Finished
  future.callbacks.call()

template complete*[T](future: Future[T], val: T) =
  ## Completes ``future`` with value ``val``.
  complete(future, val, getSrcLocation())

proc complete(future: Future[void], loc: ptr SrcLoc) =
  ## Completes a void ``future``.
  checkFinished(future, loc)
  doAssert(isNil(future.error))
  future.state = FutureState.Finished
  future.callbacks.call()

template complete*(future: Future[void]) =
  complete(future, getSrcLocation())

proc complete[T](future: FutureVar[T], loc: ptr SrcLoc) =
  template fut: untyped = Future[T](future)
  checkFinished(fut, loc)
  doAssert(isNil(fut.error))
  fut.state = FutureState.Finished
  fut.callbacks.call()

template complete*[T](futvar: FutureVar[T]) =
  ## Completes a ``FutureVar``.
  complete(futvar, getSrcLocation())

proc complete[T](futvar: FutureVar[T], val: T, loc: ptr SrcLoc) =
  template fut: untyped = Future[T](futvar)
  checkFinished(fut, loc)
  doAssert(isNil(fut.error))
  fut.state = FutureState.Finished
  fut.value = val
  fut.callbacks.call()

template complete*[T](futvar: FutureVar[T], val: T) =
  ## Completes a ``FutureVar`` with value ``val``.
  ##
  ## Any previously stored value will be overwritten.
  complete(futvar, val, getSrcLocation())

proc fail[T](future: Future[T], error: ref Exception, loc: ptr SrcLoc) =
  checkFinished(future, loc)
  future.state = FutureState.Failed
  future.error = error
  future.errorStackTrace =
    if getStackTrace(error) == "": getStackTrace() else: getStackTrace(error)
  future.callbacks.call()

template fail*[T](future: Future[T], error: ref Exception) =
  ## Completes ``future`` with ``error``.
  fail(future, error, getSrcLocation())

proc cancel[T](future: Future[T], loc: ptr SrcLoc) =
  if future.finished():
    checkFinished(future, loc)
  else:
    var first = FutureBase(future)
    var last = first
    while (not isNil(last.child)) and (not(last.child.finished())):
      last = last.child
    if last == first:
      checkFinished(future, loc)
    last.state = FutureState.Cancelled
    last.error = newException(CancelledError, "")
    if not(isNil(last.cancelcb)):
      last.cancelcb(cast[pointer](last))
    last.callbacks.call()

template cancel*[T](future: Future[T]) =
  ## Cancel ``future``.
  cancel(future, getSrcLocation())

proc clearCallbacks(future: FutureBase) =
  var count = len(future.callbacks)
  while count > 0:
    discard future.callbacks.popFirst()
    dec(count)

proc addCallback*(future: FutureBase, cb: CallbackFunc, udata: pointer = nil) =
  ## Adds the callbacks proc to be called when the future completes.
  ##
  ## If future has already completed then ``cb`` will be called immediately.
  doAssert(not isNil(cb))
  if future.finished():
    callSoon(cb, udata)
  else:
    let acb = AsyncCallback(function: cb, udata: udata)
    future.callbacks.add acb

proc addCallback*[T](future: Future[T], cb: CallbackFunc) =
  ## Adds the callbacks proc to be called when the future completes.
  ##
  ## If future has already completed then ``cb`` will be called immediately.
  future.addCallback(cb, cast[pointer](future))

proc removeCallback*(future: FutureBase, cb: CallbackFunc,
                     udata: pointer = nil) =
  doAssert(not isNil(cb))
  let acb = AsyncCallback(function: cb, udata: udata)
  future.callbacks.remove acb

proc removeCallback*[T](future: Future[T], cb: CallbackFunc) =
  future.removeCallback(cb, cast[pointer](future))

proc `callback=`*(future: FutureBase, cb: CallbackFunc, udata: pointer = nil) =
  ## Clears the list of callbacks and sets the callback proc to be called when
  ## the future completes.
  ##
  ## If future has already completed then ``cb`` will be called immediately.
  ##
  ## It's recommended to use ``addCallback`` or ``then`` instead.
  # ZAH: how about `setLen(1); callbacks[0] = cb`
  future.clearCallbacks
  future.addCallback(cb, udata)

proc `callback=`*[T](future: Future[T], cb: CallbackFunc) =
  ## Sets the callback proc to be called when the future completes.
  ##
  ## If future has already completed then ``cb`` will be called immediately.
  `callback=`(future, cb, cast[pointer](future))

proc `cancelCallback=`*[T](future: Future[T], cb: CallbackFunc) =
  ## Sets the callback procedure to be called when the future is cancelled.
  ##
  ## This callback will be called immediately as ``future.cancel()`` invoked.
  future.cancelcb = cb

proc getHint(entry: StackTraceEntry): string =
  ## We try to provide some hints about stack trace entries that the user
  ## may not be familiar with, in particular calls inside the stdlib.
  result = ""
  if entry.procname == "processPendingCallbacks":
    if cmpIgnoreStyle(entry.filename, "asyncdispatch.nim") == 0:
      return "Executes pending callbacks"
  elif entry.procname == "poll":
    if cmpIgnoreStyle(entry.filename, "asyncdispatch.nim") == 0:
      return "Processes asynchronous completion events"

  if entry.procname.endsWith("_continue"):
    if cmpIgnoreStyle(entry.filename, "asyncmacro.nim") == 0:
      return "Resumes an async procedure"

proc `$`*(entries: seq[StackTraceEntry]): string =
  result = ""
  # Find longest filename & line number combo for alignment purposes.
  var longestLeft = 0
  for entry in entries:
    if isNil(entry.procName): continue

    let left = $entry.filename & $entry.line
    if left.len > longestLeft:
      longestLeft = left.len

  var indent = 2
  # Format the entries.
  for entry in entries:
    if isNil(entry.procName):
      if entry.line == -10:
        result.add(spaces(indent) & "#[\n")
        indent.inc(2)
      else:
        indent.dec(2)
        result.add(spaces(indent) & "]#\n")
      continue

    let left = "$#($#)" % [$entry.filename, $entry.line]
    result.add((spaces(indent) & "$#$# $#\n") % [
      left,
      spaces(longestLeft - left.len + 2),
      $entry.procName
    ])
    let hint = getHint(entry)
    if hint.len > 0:
      result.add(spaces(indent+2) & "## " & hint & "\n")

proc injectStacktrace[T](future: Future[T]) =
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
  newMsg.add("Exception type:")

  # # For debugging purposes
  # for entry in getStackTraceEntries(future.error):
  #   newMsg.add "\n" & $entry
  future.error.msg = newMsg

proc read*[T](future: Future[T] | FutureVar[T]): T =
  ## Retrieves the value of ``future``. Future must be finished otherwise
  ## this function will fail with a ``FutureError`` exception.
  ##
  ## If the result of the future is an error then that error will be raised.
  {.push hint[ConvFromXtoItselfNotNeeded]: off.}
  let fut = Future[T](future)
  {.pop.}
  if fut.finished():
    if not(isNil(fut.error)):
      injectStacktrace(fut)
      raise fut.error
    when T isnot void:
      return fut.value
  else:
    # TODO: Make a custom exception type for this?
    raise newException(FutureError, "Future still in progress.")

proc readError*[T](future: Future[T]): ref Exception =
  ## Retrieves the exception stored in ``future``.
  ##
  ## An ``FutureError`` exception will be thrown if no exception exists
  ## in the specified Future.
  if not(isNil(future.error)):
    return future.error
  else:
    raise newException(FutureError, "No error in future.")

proc mget*[T](future: FutureVar[T]): var T =
  ## Returns a mutable value stored in ``future``.
  ##
  ## Unlike ``read``, this function will not raise an exception if the
  ## Future has not been finished.
  result = Future[T](future).value

proc asyncCheck*[T](future: Future[T]) =
  ## Sets a callback on ``future`` which raises an exception if the future
  ## finished with an error.
  ##
  ## This should be used instead of ``discard`` to discard void futures.
  doAssert(not isNil(future), "Future is nil")
  proc cb(data: pointer) =
    if future.failed() or future.cancelled():
      injectStacktrace(future)
      raise future.error
  future.callback = cb

proc asyncDiscard*[T](future: Future[T]) = discard
  ## This is async workaround for discard ``Future[T]``.

proc `and`*[T, Y](fut1: Future[T], fut2: Future[Y]): Future[void] =
  ## Returns a future which will complete once both ``fut1`` and ``fut2``
  ## complete.
  ##
  ## TODO: In case when `fut1` or `fut2` got cancelled, what result Future[void]
  ## should return?
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
  fut1.callback = cb
  fut2.callback = cb

  proc cancel(udata: pointer) {.gcsafe.} =
    if not(retFuture.finished()):
      fut1.removeCallback(cb)
      fut2.removeCallback(cb)
      if not(fut1.finished()):
        fut1.cancel()
      if not(fut2.finished()):
        fut2.cancel()

  retFuture.cancelCallback = cancel
  return retFuture

proc `or`*[T, Y](fut1: Future[T], fut2: Future[Y]): Future[void] =
  ## Returns a future which will complete once either ``fut1`` or ``fut2``
  ## complete.
  var retFuture = newFuture[void]("chronos.`or`")
  proc cb(udata: pointer) {.gcsafe.} =
    if not(retFuture.finished()):
      var fut = cast[FutureBase](udata)
      if cast[pointer](fut1) == udata:
        fut2.removeCallback(cb)
      else:
        fut1.removeCallback(cb)
      if fut.failed(): retFuture.fail(fut.error)
      else: retFuture.complete()
  fut1.callback = cb
  fut2.callback = cb

  proc cancel(udata: pointer) {.gcsafe.} =
    if not(retFuture.finished()):
      fut1.removeCallback(cb)
      fut2.removeCallback(cb)
      if not(fut1.finished()):
        fut1.cancel()
      if not(fut2.finished()):
        fut2.cancel()

  retFuture.cancelCallback = cancel
  return retFuture

proc all*[T](futs: varargs[Future[T]]): auto =
  ## Returns a future which will complete once all futures in ``futs`` complete.
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
    proc cb(udata: pointer) {.gcsafe.} =
      if not(retFuture.finished()):
        inc(completedFutures)
        if completedFutures == totalFutures:
          for nfut in nfuts:
            if nfut.failed():
              retFuture.fail(nfut.error)
              break
          if not(retFuture.failed()):
            retFuture.complete()

    proc cancel(udata: pointer) {.gcsafe.} =
      if not(retFuture.finished()):
        for i in 0..<len(nfuts):
          if not(nfuts[i].finished()):
            nfuts[i].removeCallback(cb)
            nfuts[i].cancel()

    for fut in nfuts:
      fut.addCallback(cb)

    if len(nfuts) == 0:
      retFuture.complete()

    retFuture.cancelCallback = cancel
    return retFuture
  else:
    var retFuture = newFuture[seq[T]]("chronos.all(T)")
    var retValues = newSeq[T](totalFutures)

    proc cb(udata: pointer) {.gcsafe.} =
      if not(retFuture.finished()):
        inc(completedFutures)
        if completedFutures == totalFutures:
          for k, nfut in nfuts:
            if nfut.failed():
              retFuture.fail(nfut.error)
              break
            else:
              retValues[k] = nfut.read()
          if not(retFuture.failed()):
            retFuture.complete(retValues)

    proc cancel(udata: pointer) {.gcsafe.} =
      if not(retFuture.finished()):
        for i in 0..<len(nfuts):
          if not(nfuts[i].finished()):
            nfuts[i].removeCallback(cb)
            nfuts[i].cancel()

    for fut in nfuts:
      fut.addCallback(cb)

    if len(nfuts) == 0:
      retFuture.complete(retValues)

    retFuture.cancelCallback = cancel
    return retFuture

proc oneIndex*[T](futs: varargs[Future[T]]): Future[int] =
  ## Returns a future which will complete once one of the futures in ``futs``
  ## complete.
  ##
  ## If the argument is empty, the returned future FAILS immediately.
  ##
  ## Returned future will hold index of completed/failed future in ``futs``
  ## argument.
  var nfuts = @futs
  var retFuture = newFuture[int]("chronos.oneIndex(T)")

  proc cb(udata: pointer) {.gcsafe.} =
    var res = -1
    if not(retFuture.finished()):
      var rfut = cast[FutureBase](udata)
      for i in 0..<len(nfuts):
        if cast[FutureBase](nfuts[i]) != rfut:
          nfuts[i].removeCallback(cb)
        else:
          res = i
      retFuture.complete(res)

  proc cancel(udata: pointer) {.gcsafe.} =
    if not(retFuture.finished()):
      for i in 0..<len(nfuts):
        if not(nfuts[i].finished()):
          nfuts[i].removeCallback(cb)
          nfuts[i].cancel()

  for fut in nfuts:
    fut.addCallback(cb)

  if len(nfuts) == 0:
    retFuture.fail(newException(FutureError, "Empty Future[T] list"))

  retFuture.cancelCallback = cancel
  return retFuture

proc oneValue*[T](futs: varargs[Future[T]]): Future[T] =
  ## Returns a future which will complete once one of the futures in ``futs``
  ## complete.
  ##
  ## If the argument is empty, returned future FAILS immediately.
  ##
  ## Returned future will hold value of completed ``futs`` future, or error
  ## if future was failed.
  ##
  ## TODO: This procedure has bug on handling cancelled futures from ``futs``.
  ## So if future from ``futs`` list become cancelled, what must be returned?
  ## You can't cancel result ``retFuture`` because in such way infinite
  ## recursion will happen.
  var nfuts = @futs
  var retFuture = newFuture[T]("chronos.oneValue(T)")

  proc cb(udata: pointer) {.gcsafe.} =
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

  proc cancel(udata: pointer) {.gcsafe.} =
    if not(retFuture.finished()):
      for i in 0..<len(nfuts):
        if not(nfuts[i].finished()):
          nfuts[i].removeCallback(cb)
          nfuts[i].cancel()

  for fut in nfuts:
    fut.addCallback(cb)

  if len(nfuts) == 0:
    retFuture.fail(newException(FutureError, "Empty Future[T] list"))

  retFuture.cancelCallback = cancel
  return retFuture

proc cancelAndWait*[T](future: Future[T]): Future[void] =
  ## Cancel future ``future`` and wait until it completes.
  var retFuture = newFuture[void]("chronos.cancelAndWait(T)")

  proc continuation(udata: pointer) {.gcsafe.} =
    if not(retFuture.finished()):
      retFuture.complete()

  future.addCallback(continuation)
  future.cancel()
  return retFuture

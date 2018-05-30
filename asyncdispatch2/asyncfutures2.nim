#
#                     Asyncdispatch2
#
#           (c) Coprygith 2015 Dominik Picheta
#  (c) Copyright 2018 Status Research & Development GmbH
#
#                Licensed under either of
#    Apache License, version 2.0, (LICENSE-APACHEv2)
#                MIT license (LICENSE-MIT)

import os, tables, strutils, times, heapqueue, options, deques, cstrutils

type
  CallbackFunc* = proc (arg: pointer = nil) {.gcsafe.}
  CallSoonProc* = proc (c: CallbackFunc, u: pointer = nil) {.gcsafe.}

  AsyncCallback* = object
    function*: CallbackFunc
    udata*: pointer
    deleted*: bool

  # ZAH: This can probably be stored with a cheaper representation
  # until the moment it needs to be printed to the screen (e.g. seq[StackTraceEntry])
  StackTrace = string

  FutureBase* = ref object of RootObj ## Untyped future.
    callbacks: Deque[AsyncCallback]

    finished: bool
    error*: ref Exception ## Stored exception
    errorStackTrace*: StackTrace
    when not defined(release):
      stackTrace: StackTrace ## For debugging purposes only.
      id: int
      fromProc: string

  # ZAH: we have discussed some possible optimizations where
  # the future can be stored within the caller's stack frame.
  # How much refactoring is needed to make this a regular non-ref type?
  # Obviously, it will still be allocated on the heap when necessary.
  Future*[T] = ref object of FutureBase ## Typed future.
    value: T ## Stored value

  FutureVar*[T] = distinct Future[T]

  FutureError* = object of Exception
    cause*: FutureBase

{.deprecated: [PFutureBase: FutureBase, PFuture: Future].}

when not defined(release):
  var currentID = 0

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

template setupFutureBase(fromProc: string) =
  new(result)
  result.finished = false
  when not defined(release):
    result.stackTrace = getStackTrace()
    result.id = currentID
    result.fromProc = fromProc
    currentID.inc()

## ZAH: As far as I undestand `fromProc` is just a debugging helper.
## It would be more efficient if it's represented as a simple statically
## known `char *` in the final program (so it needs to be a `cstring` in Nim).
## The public API can be defined as a template expecting a `static[string]`
## and converting this immediately to a `cstring`.
proc newFuture*[T](fromProc: string = "unspecified"): Future[T] =
  ## Creates a new future.
  ##
  ## Specifying ``fromProc``, which is a string specifying the name of the proc
  ## that this future belongs to, is a good habit as it helps with debugging.
  setupFutureBase(fromProc)

proc newFutureVar*[T](fromProc = "unspecified"): FutureVar[T] =
  ## Create a new ``FutureVar``. This Future type is ideally suited for
  ## situations where you want to avoid unnecessary allocations of Futures.
  ##
  ## Specifying ``fromProc``, which is a string specifying the name of the proc
  ## that this future belongs to, is a good habit as it helps with debugging.
  result = FutureVar[T](newFuture[T](fromProc))

proc clean*[T](future: FutureVar[T]) =
  ## Resets the ``finished`` status of ``future``.
  Future[T](future).finished = false
  Future[T](future).error = nil

proc checkFinished[T](future: Future[T]) =
  ## Checks whether `future` is finished. If it is then raises a
  ## ``FutureError``.
  when not defined(release):
    if future.finished:
      var msg = ""
      msg.add("An attempt was made to complete a Future more than once. ")
      msg.add("Details:")
      msg.add("\n  Future ID: " & $future.id)
      msg.add("\n  Created in proc: " & future.fromProc)
      msg.add("\n  Stack trace to moment of creation:")
      msg.add("\n" & indent(future.stackTrace.strip(), 4))
      when T is string:
        msg.add("\n  Contents (string): ")
        msg.add("\n" & indent(future.value.repr, 4))
      msg.add("\n  Stack trace to moment of secondary completion:")
      msg.add("\n" & indent(getStackTrace().strip(), 4))
      var err = newException(FutureError, msg)
      err.cause = future
      raise err

proc call(callbacks: var Deque[AsyncCallback]) =
  var count = len(callbacks)
  while count > 0:
    var item = callbacks.popFirst()
    if not item.deleted:
      callSoon(item.function, item.udata)
    dec(count)

proc add(callbacks: var Deque[AsyncCallback], item: AsyncCallback) =
  # ZAH: perhaps this is the default behavior with latest Nim (no need for the `len` check)
  if len(callbacks) == 0:
    callbacks = initDeque[AsyncCallback]()
  callbacks.addLast(item)

proc remove(callbacks: var Deque[AsyncCallback], item: AsyncCallback) =
  for p in callbacks.mitems():
    if p.function == item.function and p.udata == item.udata:
      p.deleted = true

proc complete*[T](future: Future[T], val: T) =
  ## Completes ``future`` with value ``val``.
  #assert(not future.finished, "Future already finished, cannot finish twice.")
  checkFinished(future)
  assert(future.error == nil)
  future.value = val
  future.finished = true
  future.callbacks.call()

proc complete*(future: Future[void]) =
  ## Completes a void ``future``.
  #assert(not future.finished, "Future already finished, cannot finish twice.")
  checkFinished(future)
  assert(future.error == nil)
  future.finished = true
  future.callbacks.call()

proc complete*[T](future: FutureVar[T]) =
  ## Completes a ``FutureVar``.
  template fut: untyped = Future[T](future)
  checkFinished(fut)
  assert(fut.error == nil)
  fut.finished = true
  fut.callbacks.call()

proc complete*[T](future: FutureVar[T], val: T) =
  ## Completes a ``FutureVar`` with value ``val``.
  ##
  ## Any previously stored value will be overwritten.
  template fut: untyped = Future[T](future)
  checkFinished(fut)
  assert(fut.error.isNil())
  fut.finished = true
  fut.value = val
  fut.callbacks.call()

proc fail*[T](future: Future[T], error: ref Exception) =
  ## Completes ``future`` with ``error``.
  #assert(not future.finished, "Future already finished, cannot finish twice.")
  checkFinished(future)
  future.finished = true
  future.error = error
  future.errorStackTrace =
    if getStackTrace(error) == "": getStackTrace() else: getStackTrace(error)
  future.callbacks.call()

proc clearCallbacks(future: FutureBase) =
  # ZAH: This could have been a single call to `setLen`
  var count = len(future.callbacks)
  while count > 0:
    discard future.callbacks.popFirst()
    dec(count)

proc addCallback*(future: FutureBase, cb: CallbackFunc, udata: pointer = nil) =
  ## Adds the callbacks proc to be called when the future completes.
  ##
  ## If future has already completed then ``cb`` will be called immediately.
  assert cb != nil
  if future.finished:
    # ZAH: it seems that the Future needs to know its associated Dispatcher
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
  assert cb != nil
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
    if entry.procName.isNil: continue

    let left = $entry.filename & $entry.line
    if left.len > longestLeft:
      longestLeft = left.len

  var indent = 2
  # Format the entries.
  for entry in entries:
    if entry.procName.isNil:
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
  when not defined(release):
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
  ## this function will fail with a ``ValueError`` exception.
  ##
  ## If the result of the future is an error then that error will be raised.
  {.push hint[ConvFromXtoItselfNotNeeded]: off.}
  let fut = Future[T](future)
  {.pop.}
  if fut.finished:
    if fut.error != nil:
      injectStacktrace(fut)
      raise fut.error
    when T isnot void:
      return fut.value
  else:
    # TODO: Make a custom exception type for this?
    raise newException(ValueError, "Future still in progress.")

proc readError*[T](future: Future[T]): ref Exception =
  ## Retrieves the exception stored in ``future``.
  ##
  ## An ``ValueError`` exception will be thrown if no exception exists
  ## in the specified Future.
  if future.error != nil: return future.error
  else:
    raise newException(ValueError, "No error in future.")

proc mget*[T](future: FutureVar[T]): var T =
  ## Returns a mutable value stored in ``future``.
  ##
  ## Unlike ``read``, this function will not raise an exception if the
  ## Future has not been finished.
  result = Future[T](future).value

proc finished*(future: FutureBase | FutureVar): bool =
  ## Determines whether ``future`` has completed.
  ##
  ## ``True`` may indicate an error or a value. Use ``failed`` to distinguish.
  when future is FutureVar:
    result = (FutureBase(future)).finished
  else:
    result = future.finished

proc failed*(future: FutureBase): bool =
  ## Determines whether ``future`` completed with an error.
  return future.error != nil

proc asyncCheckProxy[T](udata: pointer) =
  var future = cast[Future[T]](udata)
  if future.failed:
    injectStacktrace(future)
    raise future.error

proc asyncCheck*[T](future: Future[T]) =
  ## Sets a callback on ``future`` which raises an exception if the future
  ## finished with an error.
  ##
  ## This should be used instead of ``discard`` to discard void futures.
  assert(not future.isNil, "Future is nil")
  # ZAH: This should probably add a callback instead of replacing all call-backs.
  # Perhaps a new API can be introduced to avoid the breaking change.
  future.callback = asyncCheckProxy[T]
    # proc (udata: pointer) =
    #   if future.failed:
    #     injectStacktrace(future)
    #     raise future.error

# ZAH: The return type here could be a Future[(T, Y)]
proc `and`*[T, Y](fut1: Future[T], fut2: Future[Y]): Future[void] =
  ## Returns a future which will complete once both ``fut1`` and ``fut2``
  ## complete.
  # ZAH: The Rust implementation of futures is making the case that the
  # `and` combinator can be implemented in a more efficient way without
  # resorting to closures and callbacks. I haven't thought this through
  # completely yet, but here is their write-up:
  # http://aturon.github.io/2016/09/07/futures-design/
  #
  # We should investigate this further, before settling on the final design.
  # The same reasoning applies to `or` and `all`.
  var retFuture = newFuture[void]("asyncdispatch.`and`")
  proc cb(data: pointer) =
    if not retFuture.finished:
      if (fut1.failed or fut1.finished) and (fut2.failed or fut2.finished):
        if cast[pointer](fut1) == data:
          if fut1.failed: retFuture.fail(fut1.error)
          elif fut2.finished: retFuture.complete()
        else:
          if fut2.failed: retFuture.fail(fut2.error)
          elif fut1.finished: retFuture.complete()
  fut1.callback = cb
  fut2.callback = cb
  return retFuture

proc `or`*[T, Y](fut1: Future[T], fut2: Future[Y]): Future[void] =
  ## Returns a future which will complete once either ``fut1`` or ``fut2``
  ## complete.
  var retFuture = newFuture[void]("asyncdispatch.`or`")
  proc cb(data: pointer) {.gcsafe.} =
    if not retFuture.finished:
      var fut = cast[FutureBase](data)
      if cast[pointer](fut1) == data:
        fut2.removeCallback(cb)
      else:
        fut1.removeCallback(cb)
      if fut.failed: retFuture.fail(fut.error)
      else: retFuture.complete()
  fut1.callback = cb
  fut2.callback = cb
  return retFuture

# ZAH: The return type here could be a tuple
# This will enable waiting a heterogenous collection of futures.
proc all*[T](futs: varargs[Future[T]]): auto =
  ## Returns a future which will complete once
  ## all futures in ``futs`` complete.
  ## If the argument is empty, the returned future completes immediately.
  ##
  ## If the awaited futures are not ``Future[void]``, the returned future
  ## will hold the values of all awaited futures in a sequence.
  ##
  ## If the awaited futures *are* ``Future[void]``,
  ## this proc returns ``Future[void]``.

  when T is void:
    var
      retFuture = newFuture[void]("asyncdispatch.all")
      completedFutures = 0

    let totalFutures = len(futs)

    for fut in futs:
      fut.addCallback proc (f: Future[T]) =
        inc(completedFutures)
        if not retFuture.finished:
          if f.failed:
            retFuture.fail(f.error)
          else:
            if completedFutures == totalFutures:
              retFuture.complete()

    if totalFutures == 0:
      retFuture.complete()

    return retFuture

  else:
    var
      retFuture = newFuture[seq[T]]("asyncdispatch.all")
      retValues = newSeq[T](len(futs))
      completedFutures = 0

    for i, fut in futs:
      proc setCallback(i: int) =
        fut.addCallback proc (f: Future[T]) =
          inc(completedFutures)
          if not retFuture.finished:
            if f.failed:
              retFuture.fail(f.error)
            else:
              retValues[i] = f.read()

              if completedFutures == len(retValues):
                retFuture.complete(retValues)

      setCallback(i)

    if retValues.len == 0:
      retFuture.complete(retValues)

    return retFuture

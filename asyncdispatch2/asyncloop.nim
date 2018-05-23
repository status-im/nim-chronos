#
#                     Asyncdispatch2
#
#           (c) Coprygith 2015 Dominik Picheta
#  (c) Copyright 2018 Status Research & Development GmbH
#
#                Licensed under either of
#    Apache License, version 2.0, (LICENSE-APACHEv2)
#                MIT license (LICENSE-MIT)

include "system/inclrtl"

import os, tables, strutils, heapqueue, lists, options
import timer
import asyncfutures2 except callSoon

import nativesockets, net, deques

export Port, SocketFlag
export asyncfutures2

#{.injectStmt: newGcInvariant().}

## AsyncDispatch
## *************
##
## This module implements asynchronous IO. This includes a dispatcher,
## a ``Future`` type implementation, and an ``async`` macro which allows
## asynchronous code to be written in a synchronous style with the ``await``
## keyword.
##
## The dispatcher acts as a kind of event loop. You must call ``poll`` on it
## (or a function which does so for you such as ``waitFor`` or ``runForever``)
## in order to poll for any outstanding events. The underlying implementation
## is based on epoll on Linux, IO Completion Ports on Windows and select on
## other operating systems.
##
## The ``poll`` function will not, on its own, return any events. Instead
## an appropriate ``Future`` object will be completed. A ``Future`` is a
## type which holds a value which is not yet available, but which *may* be
## available in the future. You can check whether a future is finished
## by using the ``finished`` function. When a future is finished it means that
## either the value that it holds is now available or it holds an error instead.
## The latter situation occurs when the operation to complete a future fails
## with an exception. You can distinguish between the two situations with the
## ``failed`` function.
##
## Future objects can also store a callback procedure which will be called
## automatically once the future completes.
##
## Futures therefore can be thought of as an implementation of the proactor
## pattern. In this
## pattern you make a request for an action, and once that action is fulfilled
## a future is completed with the result of that action. Requests can be
## made by calling the appropriate functions. For example: calling the ``recv``
## function will create a request for some data to be read from a socket. The
## future which the ``recv`` function returns will then complete once the
## requested amount of data is read **or** an exception occurs.
##
## Code to read some data from a socket may look something like this:
##
##   .. code-block::nim
##      var future = socket.recv(100)
##      future.addCallback(
##        proc () =
##          echo(future.read)
##      )
##
## All asynchronous functions returning a ``Future`` will not block. They
## will not however return immediately. An asynchronous function will have
## code which will be executed before an asynchronous request is made, in most
## cases this code sets up the request.
##
## In the above example, the ``recv`` function will return a brand new
## ``Future`` instance once the request for data to be read from the socket
## is made. This ``Future`` instance will complete once the requested amount
## of data is read, in this case it is 100 bytes. The second line sets a
## callback on this future which will be called once the future completes.
## All the callback does is write the data stored in the future to ``stdout``.
## The ``read`` function is used for this and it checks whether the future
## completes with an error for you (if it did it will simply raise the
## error), if there is no error however it returns the value of the future.
##
## Asynchronous procedures
## -----------------------
##
## Asynchronous procedures remove the pain of working with callbacks. They do
## this by allowing you to write asynchronous code the same way as you would
## write synchronous code.
##
## An asynchronous procedure is marked using the ``{.async.}`` pragma.
## When marking a procedure with the ``{.async.}`` pragma it must have a
## ``Future[T]`` return type or no return type at all. If you do not specify
## a return type then ``Future[void]`` is assumed.
##
## Inside asynchronous procedures ``await`` can be used to call any
## procedures which return a
## ``Future``; this includes asynchronous procedures. When a procedure is
## "awaited", the asynchronous procedure it is awaited in will
## suspend its execution
## until the awaited procedure's Future completes. At which point the
## asynchronous procedure will resume its execution. During the period
## when an asynchronous procedure is suspended other asynchronous procedures
## will be run by the dispatcher.
##
## The ``await`` call may be used in many contexts. It can be used on the right
## hand side of a variable declaration: ``var data = await socket.recv(100)``,
## in which case the variable will be set to the value of the future
## automatically. It can be used to await a ``Future`` object, and it can
## be used to await a procedure returning a ``Future[void]``:
## ``await socket.send("foobar")``.
##
## If an awaited future completes with an error, then ``await`` will re-raise
## this error. To avoid this, you can use the ``yield`` keyword instead of
## ``await``. The following section shows different ways that you can handle
## exceptions in async procs.
##
## Handling Exceptions
## ~~~~~~~~~~~~~~~~~~~
##
## The most reliable way to handle exceptions is to use ``yield`` on a future
## then check the future's ``failed`` property. For example:
##
##   .. code-block:: Nim
##     var future = sock.recv(100)
##     yield future
##     if future.failed:
##       # Handle exception
##
## The ``async`` procedures also offer limited support for the try statement.
##
##    .. code-block:: Nim
##      try:
##        let data = await sock.recv(100)
##        echo("Received ", data)
##      except:
##        # Handle exception
##
## Unfortunately the semantics of the try statement may not always be correct,
## and occasionally the compilation may fail altogether.
## As such it is better to use the former style when possible.
##
##
## Discarding futures
## ------------------
##
## Futures should **never** be discarded. This is because they may contain
## errors. If you do not care for the result of a Future then you should
## use the ``asyncCheck`` procedure instead of the ``discard`` keyword.
##
## Examples
## --------
##
## For examples take a look at the documentation for the modules implementing
## asynchronous IO. A good place to start is the
## `asyncnet module <asyncnet.html>`_.
##
## Limitations/Bugs
## ----------------
##
## * The effect system (``raises: []``) does not work with async procedures.
## * Can't await in a ``except`` body
## * Forward declarations for async procs are broken,
##   link includes workaround: https://github.com/nim-lang/Nim/issues/3182.

# TODO: Check if yielded future is nil and throw a more meaningful exception

type
  TimerCallback* = object
    finishAt*: uint64
    function*: AsyncCallback

  PDispatcherBase = ref object of RootRef
    timers*: HeapQueue[TimerCallback]
    callbacks*: Deque[AsyncCallback]

proc `<`(a, b: TimerCallback): bool =
  result = a.finishAt < b.finishAt

proc callSoon(cbproc: CallbackFunc, data: pointer = nil) {.gcsafe.}

proc initCallSoonProc() =
  if asyncfutures2.getCallSoonProc().isNil:
    asyncfutures2.setCallSoonProc(callSoon)

when defined(windows) or defined(nimdoc):
  import winlean, sets, hashes
  type
    WSAPROC_TRANSMITFILE = proc(hSocket: SocketHandle, hFile: Handle,
                                nNumberOfBytesToWrite: DWORD,
                                nNumberOfBytesPerSend: DWORD,
                                lpOverlapped: POVERLAPPED,
                                lpTransmitBuffers: pointer,
                                dwReserved: DWORD): cint {.
                                stdcall.}

    CompletionKey = ULONG_PTR

    CompletionData* = object
      fd*: AsyncFD
      cb*: CallbackFunc
      errCode*: OSErrorCode
      bytesCount*: int32
      udata*: pointer

    PDispatcher* = ref object of PDispatcherBase
      ioPort: Handle
      handles: HashSet[AsyncFD]
      connectEx*: WSAPROC_CONNECTEX
      acceptEx*: WSAPROC_ACCEPTEX
      getAcceptExSockAddrs*: WSAPROC_GETACCEPTEXSOCKADDRS
      transmitFile*: WSAPROC_TRANSMITFILE

    CustomOverlapped* = object of OVERLAPPED
      data*: CompletionData

    PtrCustomOverlapped* = ptr CustomOverlapped

    RefCustomOverlapped* = ref CustomOverlapped

    AsyncFD* = distinct int

  proc hash(x: AsyncFD): Hash {.borrow.}
  proc `==`*(x: AsyncFD, y: AsyncFD): bool {.borrow.}

  proc newDispatcher*(): PDispatcher =
    ## Creates a new Dispatcher instance.
    new result
    result.ioPort = createIoCompletionPort(INVALID_HANDLE_VALUE, 0, 0, 1)
    result.handles = initSet[AsyncFD]()
    result.timers.newHeapQueue()
    result.callbacks = initDeque[AsyncCallback](64)

  var gDisp{.threadvar.}: PDispatcher ## Global dispatcher

  proc setGlobalDispatcher*(disp: PDispatcher) =
    if not gDisp.isNil:
      assert gDisp.callbacks.len == 0
    gDisp = disp
    initCallSoonProc()

  proc getGlobalDispatcher*(): PDispatcher =
    if gDisp.isNil:
      setGlobalDispatcher(newDispatcher())
    result = gDisp

  proc getIoHandler*(disp: PDispatcher): Handle =
    ## Returns the underlying IO Completion Port handle (Windows) or selector
    ## (Unix) for the specified dispatcher.
    return disp.ioPort

  proc register*(fd: AsyncFD) =
    ## Registers ``fd`` with the dispatcher.
    let p = getGlobalDispatcher()
    if createIoCompletionPort(fd.Handle, p.ioPort,
                              cast[CompletionKey](fd), 1) == 0:
      raiseOSError(osLastError())
    p.handles.incl(fd)

  proc poll*() =
    let loop = getGlobalDispatcher()
    var curTime = fastEpochTime()
    var curTimeout = DWORD(0)

    # Moving expired timers to `loop.callbacks` and calculate timeout
    var count = len(loop.timers)
    if count > 0:
      var lastFinish = curTime
      while count > 0:
        lastFinish = loop.timers[0].finishAt
        if curTime < lastFinish:
          break
        loop.callbacks.addLast(loop.timers.pop().function)
        dec(count)
      if count > 0:
        curTimeout = DWORD(lastFinish - curTime)

    if curTimeout == 0:
      if len(loop.callbacks) == 0:
        curTimeout = INFINITE
    else:
      if len(loop.callbacks) != 0:
        curTimeout = 0

    # Processing handles
    var lpNumberOfBytesTransferred: Dword
    var lpCompletionKey: ULONG_PTR
    var customOverlapped: PtrCustomOverlapped
    let res = getQueuedCompletionStatus(
      loop.ioPort, addr lpNumberOfBytesTransferred, addr lpCompletionKey,
      cast[ptr POVERLAPPED](addr customOverlapped), curTimeout).bool
    if res:
      customOverlapped.data.bytesCount = lpNumberOfBytesTransferred
      customOverlapped.data.errCode = OSErrorCode(-1)
      let acb = AsyncCallback(function: customOverlapped.data.cb,
                              udata: cast[pointer](customOverlapped))
      loop.callbacks.addLast(acb)
    else:
      let errCode = osLastError()
      if customOverlapped != nil:
        assert customOverlapped.data.fd == lpCompletionKey.AsyncFD
        customOverlapped.data.errCode = errCode
        let acb = AsyncCallback(function: customOverlapped.data.cb,
                                udata: cast[pointer](customOverlapped))
        loop.callbacks.addLast(acb)
      else:
        if int32(errCode) != WAIT_TIMEOUT:
          raiseOSError(errCode)

    # Moving expired timers to `loop.callbacks`.
    curTime = fastEpochTime()
    count = len(loop.timers)
    if count > 0:
      while count > 0:
        if curTime < loop.timers[0].finishAt:
          break
        loop.callbacks.addLast(loop.timers.pop().function)
        dec(count)

    # All callbacks which will be added in process will be processed on next
    # poll() call.
    count = len(loop.callbacks)
    for i in 0..<count:
      var callable = loop.callbacks.popFirst()
      callable.function(callable.udata)

  template getUdata*(u: untyped) =
    if isNil(u):
      nil
    else:
      cast[ptr CustomOverlapped](u).data.udata

  proc getFunc(s: SocketHandle, fun: var pointer, guid: var GUID): bool =
    var bytesRet: Dword
    fun = nil
    result = WSAIoctl(s, SIO_GET_EXTENSION_FUNCTION_POINTER, addr guid,
                      sizeof(GUID).Dword, addr fun, sizeof(pointer).Dword,
                      addr bytesRet, nil, nil) == 0

  proc initAPI() =
    var
      WSAID_TRANSMITFILE = GUID(
        D1: 0xb5367df0'i32, D2: 0xcbac'i16, D3: 0x11cf'i16,
        D4: [0x95'i8, 0xca'i8, 0x00'i8, 0x80'i8,
             0x5f'i8, 0x48'i8, 0xa1'i8, 0x92'i8])

    let loop = getGlobalDispatcher()

    var wsa: WSAData
    if wsaStartup(0x0202'i16, addr wsa) != 0:
      raiseOSError(osLastError())

    let sock = winlean.socket(winlean.AF_INET, 1 , 6)
    if sock == INVALID_SOCKET:
      raiseOSError(osLastError())

    var funcPointer: pointer = nil
    if not getFunc(sock, funcPointer, WSAID_CONNECTEX):
      close(sock)
      raiseOSError(osLastError())
    loop.connectEx = cast[WSAPROC_CONNECTEX](funcPointer)
    if not getFunc(sock, funcPointer, WSAID_ACCEPTEX):
      close(sock)
      raiseOSError(osLastError())
    loop.acceptEx = cast[WSAPROC_ACCEPTEX](funcPointer)
    if not getFunc(sock, funcPointer, WSAID_GETACCEPTEXSOCKADDRS):
      close(sock)
      raiseOSError(osLastError())
    loop.getAcceptExSockAddrs = cast[WSAPROC_GETACCEPTEXSOCKADDRS](funcPointer)
    if not getFunc(sock, funcPointer, WSAID_TRANSMITFILE):
      close(sock)
      raiseOSError(osLastError())
    loop.transmitFile = cast[WSAPROC_TRANSMITFILE](funcPointer)
    close(sock)

  proc closeSocket*(socket: AsyncFD) =
    ## Closes a socket and ensures that it is unregistered.
    socket.SocketHandle.close()
    getGlobalDispatcher().handles.excl(socket)

  proc unregister*(fd: AsyncFD) =
    ## Unregisters ``fd``.
    getGlobalDispatcher().handles.excl(fd)

  proc contains*(disp: PDispatcher, fd: AsyncFD): bool =
    return fd in disp.handles

else:
  import selectors
  from posix import EINTR, EAGAIN, EINPROGRESS, EWOULDBLOCK, MSG_PEEK,
                    MSG_NOSIGNAL
  type
    AsyncFD* = distinct cint

    CompletionData* = object
      fd*: AsyncFD
      udata*: pointer

    PCompletionData* = ptr CompletionData

    SelectorData* = object
      reader*: AsyncCallback
      rdata*: CompletionData
      writer*: AsyncCallback
      wdata*: CompletionData

    PDispatcher* = ref object of PDispatcherBase
      selector: Selector[SelectorData]
      keys: seq[ReadyKey]

  proc `==`*(x, y: AsyncFD): bool {.borrow.}

  proc newDispatcher*(): PDispatcher =
    new result
    result.selector = newSelector[SelectorData]()
    result.timers.newHeapQueue()
    result.callbacks = initDeque[AsyncCallback](64)
    result.keys = newSeq[ReadyKey](64)

  var gDisp{.threadvar.}: PDispatcher ## Global dispatcher

  proc setGlobalDispatcher*(disp: PDispatcher) =
    if not gDisp.isNil:
      assert gDisp.callbacks.len == 0
    gDisp = disp
    initCallSoonProc()

  proc getGlobalDispatcher*(): PDispatcher =
    if gDisp.isNil:
      setGlobalDispatcher(newDispatcher())
    result = gDisp

  proc getIoHandler*(disp: PDispatcher): Selector[SelectorData] =
    return disp.selector

  proc register*(fd: AsyncFD) =
    var data: SelectorData
    data.rdata.fd = fd
    data.wdata.fd = fd
    let loop = getGlobalDispatcher()
    loop.selector.registerHandle(int(fd), {}, data)

  proc closeSocket*(sock: AsyncFD) =
    let loop = getGlobalDispatcher()
    loop.selector.unregister(sock.SocketHandle)
    sock.SocketHandle.close()

  proc unregister*(fd: AsyncFD) =
    getGlobalDispatcher().selector.unregister(int(fd))

  proc contains*(disp: PDispatcher, fd: AsyncFd): bool {.inline.} =
    result = int(fd) in disp.selector

  proc addReader*(fd: AsyncFD, cb: CallbackFunc, udata: pointer = nil) =
    let p = getGlobalDispatcher()
    var newEvents = {Event.Read}
    withData(p.selector, int(fd), adata) do:
      let acb = AsyncCallback(function: cb, udata: addr adata.rdata)
      adata.reader = acb
      adata.rdata.fd = fd
      adata.rdata.udata = udata
      newEvents.incl(Event.Read)
      if not isNil(adata.writer.function): newEvents.incl(Event.Write)
    do:
      raise newException(ValueError, "File descriptor not registered.")
    p.selector.updateHandle(int(fd), newEvents)

  proc removeReader*(fd: AsyncFD) =
    let p = getGlobalDispatcher()
    var newEvents: set[Event]
    withData(p.selector, int(fd), adata) do:
      if not isNil(adata.writer.function): newEvents.incl(Event.Write)
    do:
      raise newException(ValueError, "File descriptor not registered.")
    p.selector.updateHandle(int(fd), newEvents)

  proc addWriter*(fd: AsyncFD, cb: CallbackFunc, udata: pointer = nil) =
    let p = getGlobalDispatcher()
    var newEvents = {Event.Write}
    withData(p.selector, int(fd), adata) do:
      let acb = AsyncCallback(function: cb, udata: addr adata.wdata)
      adata.writer = acb
      adata.wdata.fd = fd
      adata.wdata.udata = udata
      newEvents.incl(Event.Write)
      if not isNil(adata.reader.function): newEvents.incl(Event.Read)
    do:
      raise newException(ValueError, "File descriptor not registered.")
    p.selector.updateHandle(int(fd), newEvents)

  proc removeWriter*(fd: AsyncFD) =
    let p = getGlobalDispatcher()
    var newEvents: set[Event]
    withData(p.selector, int(fd), adata) do:
      if not isNil(adata.reader.function): newEvents.incl(Event.Read)
    do:
      raise newException(ValueError, "File descriptor not registered.")
    p.selector.updateHandle(int(fd), newEvents)

  proc poll*() =
    let loop = getGlobalDispatcher()
    var curTime = fastEpochTime()
    var curTimeout = 0

    when ioselSupportedPlatform:
      let customSet = {Event.Timer, Event.Signal, Event.Process,
                       Event.Vnode}

    # Moving expired timers to `loop.callbacks` and calculate timeout
    var count = len(loop.timers)
    if count > 0:
      var lastFinish = curTime
      while count > 0:
        lastFinish = loop.timers[0].finishAt
        if curTime < lastFinish:
          break
        loop.callbacks.addLast(loop.timers.pop().function)
        dec(count)
      if count > 0:
        curTimeout = int(lastFinish - curTime)

    if curTimeout == 0:
      if len(loop.callbacks) == 0:
        curTimeout = -1
    else:
      if len(loop.callbacks) != 0:
        curTimeout = 0

    count = loop.selector.selectInto(curTimeout, loop.keys)
    for i in 0..<count:
      let fd = loop.keys[i].fd
      let events = loop.keys[i].events

      if Event.Read in events or events == {Event.Error}:
        withData(loop.selector, fd, adata) do:
          loop.callbacks.addLast(adata.reader)

      if Event.Write in events or events == {Event.Error}:
        withData(loop.selector, fd, adata) do:
          loop.callbacks.addLast(adata.writer)

      if Event.User in events:
        withData(loop.selector, fd, adata) do:
          loop.callbacks.addLast(adata.reader)

      when ioselSupportedPlatform:
        if customSet * events != {}:
          withData(loop.selector, fd, adata) do:
            loop.callbacks.addLast(adata.reader)

    # Moving expired timers to `loop.callbacks`.
    curTime = fastEpochTime()
    count = len(loop.timers)
    if count > 0:
      while count > 0:
        if curTime < loop.timers[0].finishAt:
          break
        loop.callbacks.addLast(loop.timers.pop().function)
        dec(count)

    # All callbacks which will be added in process will be processed on next
    # poll() call.
    count = len(loop.callbacks)
    for i in 0..<count:
      var callable = loop.callbacks.popFirst()
      callable.function(callable.udata)

  proc initAPI() =
    discard getGlobalDispatcher()

proc addTimer*(at: uint64, cb: CallbackFunc, udata: pointer = nil) =
  let loop = getGlobalDispatcher()
  var tcb = TimerCallback(finishAt: at,
                          function: AsyncCallback(function: cb, udata: udata))
  loop.timers.push(tcb)

proc removeTimer*(at: uint64, cb: CallbackFunc, udata: pointer = nil) =
  let loop = getGlobalDispatcher()
  var list = cast[seq[TimerCallback]](loop.timers)
  var index = -1
  for i in 0..<len(list):
    if list[i].finishAt == at and list[i].function.function == cb and
       list[i].function.udata == udata:
      index = i
      break
  if index != -1:
    loop.timers.del(index)

proc completeProxy*[T](data: pointer) =
  var future = cast[Future[T]](data)
  future.complete()

proc sleepAsync*(ms: int): Future[void] =
  ## Suspends the execution of the current async procedure for the next
  ## ``ms`` milliseconds.
  var retFuture = newFuture[void]("sleepAsync")
  addTimer(fastEpochTime() + uint64(ms),
           completeProxy[void], cast[pointer](retFuture))
  return retFuture

proc withTimeout*[T](fut: Future[T], timeout: int): Future[bool] =
  ## Returns a future which will complete once ``fut`` completes or after
  ## ``timeout`` milliseconds has elapsed.
  ##
  ## If ``fut`` completes first the returned future will hold true,
  ## otherwise, if ``timeout`` milliseconds has elapsed first, the returned
  ## future will hold false.
  var retFuture = newFuture[bool]("asyncdispatch.`withTimeout`")
  proc continuation(udata: pointer) {.gcsafe.} =
    if not retFuture.finished:
      if isNil(udata):
        fut.removeCallback(continuation)
        retFuture.complete(false)
      else:
        if not retFuture.finished:
          retFuture.complete(true)
  addTimer(fastEpochTime() + uint64(timeout), continuation, nil)
  fut.addCallback(continuation)
  return retFuture

include asyncmacro2

proc callSoon(cbproc: CallbackFunc, data: pointer = nil) =
  ## Schedule `cbproc` to be called as soon as possible.
  ## The callback is called when control returns to the event loop.
  let acb = AsyncCallback(function: cbproc, udata: data)
  getGlobalDispatcher().callbacks.addLast(acb)

proc runForever*() =
  ## Begins a never ending global dispatcher poll loop.
  while true:
    poll()

proc waitFor*[T](fut: Future[T]): T =
  ## **Blocks** the current thread until the specified future completes.
  while not fut.finished:
    poll()

  fut.read

# Global API and callSoon initialization.
initAPI()

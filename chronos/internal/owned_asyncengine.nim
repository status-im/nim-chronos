#
#                     Chronos
#
#           (c) Copyright 2015 Dominik Picheta
#  (c) Copyright 2018-Present Status Research & Development GmbH
#
#                Licensed under either of
#    Apache License, version 2.0, (LICENSE-APACHEv2)
#                MIT license (LICENSE-MIT)

{.push raises: [].}

## This module implements the core asynchronous engine / dispatcher.
##
## Is a copy of asyncengine module but gives more control over dispatcher
## ownership and lifecycle.
##
## For more information, see the `Concepts` chapter of the guide.

from nativesockets import Port
import std/[tables, heapqueue, deques]
import results
import ".."/[config, futures, osdefs, oserrno, osutils, timer]

import ./[asyncmacro, errors, asyncengine_types]

export Port
export deques, errors, futures, timer, results

export
  asyncmacro.async, asyncmacro.await, asyncmacro.awaitne

const
  MaxEventsCount* = 64

when defined(windows):
  import std/[sets, hashes]
elif defined(macosx) or defined(freebsd) or defined(netbsd) or
     defined(openbsd) or defined(dragonfly) or defined(macos) or
     defined(linux) or defined(android) or defined(solaris):
  import ../selectors2
  export SIGHUP, SIGINT, SIGQUIT, SIGILL, SIGTRAP, SIGABRT,
         SIGBUS, SIGFPE, SIGKILL, SIGUSR1, SIGSEGV, SIGUSR2,
         SIGPIPE, SIGALRM, SIGTERM, SIGPIPE
  export oserrno

proc sentinelCallbackImpl(arg: pointer) {.gcsafe, noreturn.} =
  raiseAssert "Sentinel callback MUST not be scheduled"

const
  SentinelCallback = AsyncCallback(function: sentinelCallbackImpl,
                                   udata: nil)

proc isSentinel(acb: AsyncCallback): bool =
  acb == SentinelCallback

proc `<`(a, b: TimerCallback): bool =
  result = a.finishAt < b.finishAt

func getAsyncTimestamp*(a: Duration): auto {.inline.} =
  ## Return rounded up value of duration with milliseconds resolution.
  ##
  ## This function also take care on int32 overflow, because Linux and Windows
  ## accepts signed 32bit integer as timeout.
  let milsec = Millisecond.nanoseconds()
  let nansec = a.nanoseconds()
  var res = nansec div milsec
  let mid = nansec mod milsec
  when defined(windows):
    res = min(int64(high(int32) - 1), res)
    result = cast[DWORD](res)
    result += DWORD(min(1'i32, cast[int32](mid)))
  else:
    res = min(int64(high(int32) - 1), res)
    result = cast[int32](res)
    result += min(1, cast[int32](mid))

template processTimersGetTimeout(disp, timeout: untyped) =
  var lastFinish = curTime
  while disp.timers.len > 0:
    if disp.timers[0].function.function.isNil:
      discard disp.timers.pop()
      continue

    lastFinish = disp.timers[0].finishAt
    if curTime < lastFinish:
      break

    disp.callbacks.addLast(disp.timers.pop().function)

  if disp.timers.len > 0:
    timeout = (lastFinish - curTime).getAsyncTimestamp()

  if timeout == 0:
    if (len(disp.callbacks) == 0) and (len(disp.idlers) == 0):
      when defined(windows):
        timeout = INFINITE
      else:
        timeout = -1
  else:
    if (len(disp.callbacks) != 0) or (len(disp.idlers) != 0):
      timeout = 0

template processTimers(disp: untyped) =
  var curTime = Moment.now()
  while disp.timers.len > 0:
    if disp.timers[0].function.function.isNil:
      discard disp.timers.pop()
      continue

    if curTime < disp.timers[0].finishAt:
      break
    disp.callbacks.addLast(disp.timers.pop().function)

template processIdlers(disp: untyped) =
  if len(disp.idlers) > 0:
    disp.callbacks.addLast(disp.idlers.popFirst())

template processTicks(disp: untyped) =
  while len(disp.ticks) > 0:
    disp.callbacks.addLast(disp.ticks.popFirst())

template processCallbacks(disp: untyped) =
  while true:
    let callable = disp.callbacks.popFirst()  # len must be > 0 due to sentinel
    if isSentinel(callable):
      break
    if not(isNil(callable.function)):
      callable.function(callable.udata)

proc raiseAsDefect*(exc: ref Exception, msg: string) {.noreturn, noinline.} =
  # Reraise an exception as a Defect, where it's unexpected and can't be handled
  # We include the stack trace in the message because otherwise, it's easily
  # lost - Nim doesn't print it for `parent` exceptions for example (!)
  raise (ref Defect)(
    msg: msg & "\n" & exc.msg & "\n" & exc.getStackTrace(), parent: exc)

func toPointer(error: OSErrorCode): pointer =
  when sizeof(int) == 8:
    cast[pointer](uint64(uint32(error)))
  else:
    cast[pointer](uint32(error))

func toException*(v: OSErrorCode): ref OSError = newOSError(v)
  # This helper will allow to use `tryGet()` and raise OSError for
  # Result[T, OSErrorCode] values.

when defined(nimdoc):
  proc poll*(disp: PDispatcher) = discard
    ## Perform single asynchronous step, processing timers and completing
    ## tasks. Blocks until at least one event has completed.
    ##
    ## Exceptions raised during `async` task exection are stored as outcome
    ## in the corresponding `Future` - `poll` itself does not raise.

  proc register2*(fd: AsyncFD): Result[void, OSErrorCode] = discard
  proc unregister2*(fd: AsyncFD): Result[void, OSErrorCode] = discard
  proc addReader2*(fd: AsyncFD, cb: CallbackFunc,
                   udata: pointer = nil): Result[void, OSErrorCode] = discard
  proc removeReader2*(fd: AsyncFD): Result[void, OSErrorCode] = discard
  proc addWriter2*(fd: AsyncFD, cb: CallbackFunc,
                   udata: pointer = nil): Result[void, OSErrorCode] = discard
  proc removeWriter2*(fd: AsyncFD): Result[void, OSErrorCode] = discard
  proc closeHandle*(fd: AsyncFD, aftercb: CallbackFunc = nil) = discard
  proc closeSocket*(fd: AsyncFD, aftercb: CallbackFunc = nil) = discard
  proc unregisterAndCloseFd*(fd: AsyncFD): Result[void, OSErrorCode] = discard

  proc `==`*(x: AsyncFD, y: AsyncFD): bool {.borrow, gcsafe.}

elif defined(windows):
  {.pragma: stdcallbackFunc, stdcall, gcsafe, raises: [].}

  export SIGINT, SIGQUIT, SIGTERM

  proc hash(x: AsyncFD): Hash {.borrow.}
  proc `==`*(x: AsyncFD, y: AsyncFD): bool {.borrow, gcsafe.}

  proc getFunc(s: SocketHandle, fun: var pointer, guid: GUID): bool =
    var bytesRet: DWORD
    fun = nil
    wsaIoctl(s, SIO_GET_EXTENSION_FUNCTION_POINTER, unsafeAddr(guid),
             DWORD(sizeof(GUID)), addr fun, DWORD(sizeof(pointer)),
             addr(bytesRet), nil, nil) == 0

  proc globalInit() =
    var wsa = WSAData()
    let res = wsaStartup(0x0202'u16, addr wsa)
    if res != 0:
      raiseOsDefect(osLastError(),
                    "globalInit(): Unable to initialize Windows Sockets API")

  proc newDispatcher*(): PDispatcher =
    ## Creates a new Dispatcher instance.
    let port = createIoCompletionPort(osdefs.INVALID_HANDLE_VALUE,
                                      HANDLE(0), 0, 1)
    if port == osdefs.INVALID_HANDLE_VALUE:
      raiseOsDefect(osLastError(), "newDispatcher(): Unable to create " &
                                   "IOCP port")
    var res = PDispatcher(
      ioPort: port,
      handles: initHashSet[AsyncFD](),
      timers: initHeapQueue[TimerCallback](),
      callbacks: initDeque[AsyncCallback](64),
      idlers: initDeque[AsyncCallback](),
      ticks: initDeque[AsyncCallback](),
      trackers: initTable[string, TrackerBase](),
      counters: initTable[string, TrackerCounter]()
    )
    res.callbacks.addLast(SentinelCallback)
    initAPI(res)
    res

  proc setThreadDispatcher*(disp: PDispatcher) {.gcsafe, raises: [].}
  proc getThreadDispatcher*(): PDispatcher {.gcsafe, raises: [].}

  proc getIoHandler*(disp: PDispatcher): HANDLE =
    ## Returns the underlying IO Completion Port handle (Windows) or selector
    ## (Unix) for the specified dispatcher.
    disp.ioPort

  proc register2*(disp: PDispatcher, fd: AsyncFD): Result[void, OSErrorCode] =
    ## Register file descriptor ``fd`` in thread's dispatcher.
    if createIoCompletionPort(HANDLE(fd), disp.ioPort, cast[CompletionKey](fd),
                              1) == osdefs.INVALID_HANDLE_VALUE:
      return err(osLastError())
    disp.handles.incl(fd)
    ok()

  proc register*(disp: PDispatcher, fd: AsyncFD) {.raises: [OSError].} =
    ## Register file descriptor ``fd`` in thread's dispatcher.
    register2(disp, fd).tryGet()

  proc unregister*(disp: PDispatcher, fd: AsyncFD) =
    ## Unregisters ``fd``.
    disp.handles.excl(fd)

  {.push stackTrace: off.}
  proc waitableCallback(param: pointer, timerOrWaitFired: BYTE) {.
       stdcallbackFunc.} =
    # This procedure will be executed in `wait thread`, so it must not use
    # GC related objects.
    # We going to ignore callbacks which was spawned when `isNil(param) == true`
    # because we unable to indicate this error.
    if isNil(param): return
    var wh = cast[ptr PostCallbackData](param)
    # We ignore result of postQueueCompletionStatus() call because we unable to
    # indicate error.
    discard postQueuedCompletionStatus(
      wh[].ioPort, DWORD(timerOrWaitFired and 0xFF'u8),
      ULONG_PTR(wh[].handleFd), wh[].ovl)
  {.pop.}

  proc registerWaitable*(
         disp: PDispatcher,
         handle: HANDLE,
         flags: ULONG,
         timeout: Duration,
         cb: CallbackFunc,
         udata: pointer
       ): Result[WaitableHandle, OSErrorCode] =
    ## Register handle of (Change notification, Console input, Event,
    ## Memory resource notification, Mutex, Process, Semaphore, Thread,
    ## Waitable timer) for waiting, using specific Windows' ``flags`` and
    ## ``timeout`` value.
    ##
    ## Callback ``cb`` will be scheduled with ``udata`` parameter when
    ## ``handle`` become signaled.
    ##
    ## Result of this procedure call ``WaitableHandle`` should be closed using
    ## closeWaitable() call.
    ##
    ## NOTE: This is private procedure, not supposed to be publicly available,
    ## please use ``waitForSingleObject()``.
    var ovl = RefCustomOverlapped(data: CompletionData(cb: cb))

    var whandle = (ref PostCallbackData)(
      ioPort: disp.getIoHandler(),
      handleFd: AsyncFD(handle),
      udata: udata,
      ovlref: ovl,
      ovl: cast[pointer](ovl)
    )

    ovl.data.udata = cast[pointer](whandle)

    let dwordTimeout =
      if timeout == InfiniteDuration:
        DWORD(INFINITE)
      else:
        DWORD(timeout.milliseconds)

    if registerWaitForSingleObject(addr(whandle[].waitFd), handle,
                                   cast[WAITORTIMERCALLBACK](waitableCallback),
                                   cast[pointer](whandle),
                                   dwordTimeout,
                                   flags) == WINBOOL(0):
      ovl.data.udata = nil
      whandle.ovlref = nil
      whandle.ovl = nil
      return err(osLastError())

    ok(WaitableHandle(whandle))

  proc closeWaitable*(wh: WaitableHandle): Result[void, OSErrorCode] =
    ## Close waitable handle ``wh`` and clear all the resources. It is safe
    ## to close this handle, even if wait operation is pending.
    ##
    ## NOTE: This is private procedure, not supposed to be publicly available,
    ## please use ``waitForSingleObject()``.
    doAssert(not(isNil(wh)))

    let pdata = (ref PostCallbackData)(wh)
    # We are not going to clear `ref` fields in PostCallbackData object because
    # it possible that callback is already scheduled.
    if unregisterWait(pdata.waitFd) == 0:
      let res = osLastError()
      if res != ERROR_IO_PENDING:
        return err(res)
    ok()

  proc addProcess2*(disp: PDispatcher, pid: int, cb: CallbackFunc,
                    udata: pointer = nil): Result[ProcessHandle, OSErrorCode] =
    ## Registers callback ``cb`` to be called when process with process
    ## identifier ``pid`` exited. Returns process identifier, which can be
    ## used to clear process callback via ``removeProcess``.
    doAssert(pid > 0, "Process identifier must be positive integer")
    let
      hProcess = openProcess(SYNCHRONIZE, WINBOOL(0), DWORD(pid))
      flags = WT_EXECUTEINWAITTHREAD or WT_EXECUTEONLYONCE

    var wh: WaitableHandle = nil

    if hProcess == HANDLE(0):
      return err(osLastError())

    proc continuation(udata: pointer) {.gcsafe.} =
      doAssert(not(isNil(udata)))
      doAssert(not(isNil(wh)))
      discard closeFd(hProcess)
      cb(wh[].udata)

    wh =
      block:
        let res = registerWaitable(hProcess, flags, InfiniteDuration,
                                   continuation, udata)
        if res.isErr():
          discard closeFd(hProcess)
          return err(res.error())
        res.get()
    ok(ProcessHandle(wh))

  proc removeProcess2*(procHandle: ProcessHandle): Result[void, OSErrorCode] =
    ## Remove process' watching using process' descriptor ``procHandle``.
    let waitableHandle = WaitableHandle(procHandle)
    doAssert(not(isNil(waitableHandle)))
    ? closeWaitable(waitableHandle)
    ok()

  proc addProcess*(disp: PDispatcher, pid: int, cb: CallbackFunc,
                   udata: pointer = nil): ProcessHandle {.
       raises: [OSError].} =
    ## Registers callback ``cb`` to be called when process with process
    ## identifier ``pid`` exited. Returns process identifier, which can be
    ## used to clear process callback via ``removeProcess``.
    disp.addProcess2(pid, cb, udata).tryGet()

  proc removeProcess*(procHandle: ProcessHandle) {.
       raises: [ OSError].} =
    ## Remove process' watching using process' descriptor ``procHandle``.
    removeProcess2(procHandle).tryGet()

  {.push stackTrace: off.}
  proc consoleCtrlEventHandler(dwCtrlType: DWORD): uint32 {.stdcallbackFunc.} =
    ## This procedure will be executed in different thread, so it MUST not use
    ## any GC related features (strings, seqs, echo etc.).
    case dwCtrlType
    of CTRL_C_EVENT:
      return
        (if raiseSignal(SIGINT).valueOr(false): TRUE else: FALSE)
    of CTRL_BREAK_EVENT:
      return
        (if raiseSignal(SIGINT).valueOr(false): TRUE else: FALSE)
    of CTRL_CLOSE_EVENT:
      return
        (if raiseSignal(SIGTERM).valueOr(false): TRUE else: FALSE)
    of CTRL_LOGOFF_EVENT:
      return
        (if raiseSignal(SIGQUIT).valueOr(false): TRUE else: FALSE)
    else:
      FALSE
  {.pop.}

  proc addSignal2*(disp: PDispatcher, signal: int, cb: CallbackFunc,
                   udata: pointer = nil): Result[SignalHandle, OSErrorCode] =
    ## Start watching signal ``signal``, and when signal appears, call the
    ## callback ``cb`` with specified argument ``udata``. Returns signal
    ## identifier code, which can be used to remove signal callback
    ## via ``removeSignal``.
    ##
    ## NOTE: On Windows only subset of signals are supported: SIGINT, SIGTERM,
    ##       SIGQUIT
    const supportedSignals = [SIGINT, SIGTERM, SIGQUIT]
    doAssert(cint(signal) in supportedSignals, "Signal is not supported")
    var hWait: WaitableHandle = nil

    proc continuation(ucdata: pointer) {.gcsafe.} =
      doAssert(not(isNil(ucdata)))
      doAssert(not(isNil(hWait)))
      cb(hWait[].udata)

    if SignalHandlerInstalled notin disp.flags:
      if getConsoleCP() != 0'u32:
        # Console application, we going to cleanup Nim default signal handlers.
        if setConsoleCtrlHandler(consoleCtrlEventHandler, TRUE) == FALSE:
          return err(osLastError())
        disp.flags.incl(SignalHandlerInstalled)
      else:
        return err(ERROR_NOT_SUPPORTED)

    let
      flags = WT_EXECUTEINWAITTHREAD
      hEvent = ? openEvent($getSignalName(signal))

    hWait = registerWaitable(hEvent, flags, InfiniteDuration,
                             continuation, udata).valueOr:
      discard closeFd(hEvent)
      return err(error)
    ok(SignalHandle(hWait))

  proc removeSignal2*(signalHandle: SignalHandle): Result[void, OSErrorCode] =
    ## Remove watching signal ``signal``.
    ? closeWaitable(WaitableHandle(signalHandle))
    ok()

  proc addSignal*(signal: int, cb: CallbackFunc,
                  udata: pointer = nil): SignalHandle {.
       raises: [ValueError].} =
    ## Registers callback ``cb`` to be called when signal ``signal`` will be
    ## raised. Returns signal identifier, which can be used to clear signal
    ## callback via ``removeSignal``.
    addSignal2(signal, cb, udata).valueOr:
      raise newException(ValueError, osErrorMsg(error))

  proc removeSignal*(signalHandle: SignalHandle) {.
       raises: [ValueError].} =
    ## Remove signal's watching using signal descriptor ``signalfd``.
    let res = removeSignal2(signalHandle)
    if res.isErr():
      raise newException(ValueError, osErrorMsg(res.error()))

  proc poll*(disp: PDispatcher) =
    var
      curTime = Moment.now()
      curTimeout = DWORD(0)
      events: array[MaxEventsCount, osdefs.OVERLAPPED_ENTRY]

    # On reentrant `poll` calls from `processCallbacks`, e.g., `waitFor`,
    # complete pending work of the outer `processCallbacks` call.
    # On non-reentrant `poll` calls, this only removes sentinel element.
    disp.processCallbacks()

    # Moving expired timers to `disp.callbacks` and calculate timeout
    disp.processTimersGetTimeout(curTimeout)

    let networkEventsCount =
      if isNil(disp.getQueuedCompletionStatusEx):
        let res = getQueuedCompletionStatus(
          disp.ioPort,
          addr events[0].dwNumberOfBytesTransferred,
          addr events[0].lpCompletionKey,
          cast[ptr POVERLAPPED](addr events[0].lpOverlapped),
          curTimeout
        )
        if res == FALSE:
          let errCode = osLastError()
          if not(isNil(events[0].lpOverlapped)):
            1
          else:
            if uint32(errCode) != WAIT_TIMEOUT:
              raiseOsDefect(errCode, "poll(): Unable to get OS events")
            0
        else:
          1
      else:
        var eventsReceived = ULONG(0)
        let res = disp.getQueuedCompletionStatusEx(
          disp.ioPort,
          addr events[0],
          ULONG(len(events)),
          eventsReceived,
          curTimeout,
          WINBOOL(0)
        )
        if res == FALSE:
          let errCode = osLastError()
          if uint32(errCode) != WAIT_TIMEOUT:
            raiseOsDefect(errCode, "poll(): Unable to get OS events")
          0
        else:
          int(eventsReceived)

    for i in 0 ..< networkEventsCount:
      var customOverlapped = PtrCustomOverlapped(events[i].lpOverlapped)
      customOverlapped.data.errCode =
        block:
          let res = cast[uint64](customOverlapped.internal)
          if res == 0'u64:
            OSErrorCode(-1)
          else:
            OSErrorCode(rtlNtStatusToDosError(res))
      customOverlapped.data.bytesCount = events[i].dwNumberOfBytesTransferred
      let acb = AsyncCallback(function: customOverlapped.data.cb,
                              udata: cast[pointer](customOverlapped))
      disp.callbacks.addLast(acb)

    # Moving expired timers to `disp.callbacks`.
    disp.processTimers()

    # We move idle callbacks to `disp.callbacks` only if there no pending
    # network events.
    if networkEventsCount == 0:
      disp.processIdlers()

    # We move tick callbacks to `disp.callbacks` always.
    disp.processTicks()

    # All callbacks which will be added during `processCallbacks` will be
    # scheduled after the sentinel and are processed on next `poll()` call.
    disp.callbacks.addLast(SentinelCallback)
    disp.processCallbacks()

    # All callbacks done, skip `processCallbacks` at start.
    disp.callbacks.addFirst(SentinelCallback)

  proc closeSocket*(disp: PDispatcher, fd: AsyncFD, aftercb: CallbackFunc = nil) =
    ## Closes a socket and ensures that it is unregistered.
    disp.handles.excl(fd)
    let
      param = toPointer(
        if closeFd(SocketHandle(fd)) == 0:
          OSErrorCode(0)
        else:
          osLastError()
      )
    if not(isNil(aftercb)):
      disp.callbacks.addLast(AsyncCallback(function: aftercb, udata: param))

  proc closeHandle*(disp: PDispatcher, fd: AsyncFD, aftercb: CallbackFunc = nil) =
    ## Closes a (pipe/file) handle and ensures that it is unregistered.
    disp.handles.excl(fd)
    let
      param = toPointer(
        if closeFd(HANDLE(fd)) == 0:
          OSErrorCode(0)
        else:
          osLastError()
      )

    if not(isNil(aftercb)):
      disp.callbacks.addLast(AsyncCallback(function: aftercb, udata: param))

  proc unregisterAndCloseFd*(fd: AsyncFD): Result[void, OSErrorCode] =
    ## Unregister from system queue and close asynchronous socket.
    ##
    ## NOTE: Use this function to close temporary sockets/pipes only (which
    ## are not exposed to the public and not supposed to be used/reused).
    ## Please use closeSocket(AsyncFD) and closeHandle(AsyncFD) instead.
    doAssert(fd != AsyncFD(osdefs.INVALID_SOCKET))
    unregister(fd)
    if closeFd(SocketHandle(fd)) != 0:
      err(osLastError())
    else:
      ok()

  proc contains*(disp: PDispatcher, fd: AsyncFD): bool =
    ## Returns ``true`` if ``fd`` is registered in thread's dispatcher.
    fd in disp.handles

elif defined(macosx) or defined(freebsd) or defined(netbsd) or
     defined(openbsd) or defined(dragonfly) or defined(macos) or
     defined(linux) or defined(android) or defined(solaris):
  const
    SIG_IGN = cast[proc(x: cint) {.raises: [], noconv, gcsafe.}](1)

  proc `==`*(x, y: AsyncFD): bool {.borrow, gcsafe.}

  proc globalInit() =
    # We are ignoring SIGPIPE signal, because we are working with EPIPE.
    signal(cint(SIGPIPE), SIG_IGN)

  proc initAPI(disp: PDispatcher) =
    discard

  var gDisp{.threadvar.}: PDispatcher ## Global dispatcher

  proc setThreadDispatcher*(disp: PDispatcher) {.gcsafe, raises: [].}
  proc getThreadDispatcher*(): PDispatcher {.gcsafe, raises: [].}

  proc getIoHandler*(disp: PDispatcher): Selector[SelectorData] =
    ## Returns system specific OS queue.
    disp.selector

  proc contains*(disp: PDispatcher, fd: AsyncFD): bool {.inline.} =
    ## Returns ``true`` if ``fd`` is registered in thread's dispatcher.
    cint(fd) in disp.selector

  proc register2*(disp: PDispatcher, fd: AsyncFD): Result[void, OSErrorCode] =
    ## Register file descriptor ``fd`` in thread's dispatcher.
    var data: SelectorData
    disp.selector.registerHandle2(cint(fd), {}, data)

  proc unregister2*(disp: PDispatcher, fd: AsyncFD): Result[void, OSErrorCode] =
    ## Unregister file descriptor ``fd`` from thread's dispatcher.
    disp.selector.unregister2(cint(fd))

  proc addReader2*(disp: PDispatcher, fd: AsyncFD, cb: CallbackFunc,
                   udata: pointer = nil): Result[void, OSErrorCode] =
    ## Start watching the file descriptor ``fd`` for read availability and then
    ## call the callback ``cb`` with specified argument ``udata``.
    var newEvents = {Event.Read}
    withData(disp.selector, cint(fd), adata) do:
      let acb = AsyncCallback(function: cb, udata: udata)
      adata.reader = acb
      if not(isNil(adata.writer.function)):
        newEvents.incl(Event.Write)
    do:
      return err(osdefs.EBADF)
    disp.selector.updateHandle2(cint(fd), newEvents)

  proc removeReader2*(disp: PDispatcher, fd: AsyncFD): Result[void, OSErrorCode] =
    ## Stop watching the file descriptor ``fd`` for read availability.
    var newEvents: set[Event]
    withData(disp.selector, cint(fd), adata) do:
      # We need to clear `reader` data, because `selectors` don't do it
      adata.reader = default(AsyncCallback)
      if not(isNil(adata.writer.function)):
        newEvents.incl(Event.Write)
    do:
      return err(osdefs.EBADF)
    disp.selector.updateHandle2(cint(fd), newEvents)

  proc addWriter2*(disp: PDispatcher, fd: AsyncFD, cb: CallbackFunc,
                   udata: pointer = nil): Result[void, OSErrorCode] =
    ## Start watching the file descriptor ``fd`` for write availability and then
    ## call the callback ``cb`` with specified argument ``udata``.
    var newEvents = {Event.Write}
    withData(disp.selector, cint(fd), adata) do:
      let acb = AsyncCallback(function: cb, udata: udata)
      adata.writer = acb
      if not(isNil(adata.reader.function)):
        newEvents.incl(Event.Read)
    do:
      return err(osdefs.EBADF)
    disp.selector.updateHandle2(cint(fd), newEvents)

  proc removeWriter2*(disp: PDispatcher, fd: AsyncFD): Result[void, OSErrorCode] =
    ## Stop watching the file descriptor ``fd`` for write availability.
    var newEvents: set[Event]
    withData(disp.selector, cint(fd), adata) do:
      # We need to clear `writer` data, because `selectors` don't do it
      adata.writer = default(AsyncCallback)
      if not(isNil(adata.reader.function)):
        newEvents.incl(Event.Read)
    do:
      return err(osdefs.EBADF)
    disp.selector.updateHandle2(cint(fd), newEvents)

  proc register*(disp: PDispatcher, fd: AsyncFD) {.raises: [OSError].} =
    ## Register file descriptor ``fd`` in thread's dispatcher.
    register2(disp, fd).tryGet()

  proc unregister*(disp: PDispatcher, fd: AsyncFD) {.raises: [OSError].} =
    ## Unregister file descriptor ``fd`` from thread's dispatcher.
    unregister2(disp, fd).tryGet()

  proc addReader*(disp: PDispatcher, fd: AsyncFD, cb: CallbackFunc, udata: pointer = nil) {.
       raises: [OSError].} =
    ## Start watching the file descriptor ``fd`` for read availability and then
    ## call the callback ``cb`` with specified argument ``udata``.
    addReader2(disp, fd, cb, udata).tryGet()

  proc removeReader*(disp: PDispatcher, fd: AsyncFD) {.raises: [OSError].} =
    ## Stop watching the file descriptor ``fd`` for read availability.
    removeReader2(disp, fd).tryGet()

  proc addWriter*(disp: PDispatcher, fd: AsyncFD, cb: CallbackFunc, udata: pointer = nil) {.
       raises: [OSError].} =
    ## Start watching the file descriptor ``fd`` for write availability and then
    ## call the callback ``cb`` with specified argument ``udata``.
    addWriter2(disp, fd, cb, udata).tryGet()

  proc removeWriter*(disp: PDispatcher, fd: AsyncFD) {.raises: [OSError].} =
    ## Stop watching the file descriptor ``fd`` for write availability.
    removeWriter2(disp, fd).tryGet()

  proc unregisterAndCloseFd*(disp: PDispatcher, fd: AsyncFD): Result[void, OSErrorCode] =
    ## Unregister from system queue and close asynchronous socket.
    ##
    ## NOTE: Use this function to close temporary sockets/pipes only (which
    ## are not exposed to the public and not supposed to be used/reused).
    ## Please use closeSocket(AsyncFD) and closeHandle(AsyncFD) instead.
    doAssert(fd != AsyncFD(osdefs.INVALID_SOCKET))
    ? disp.unregister2(fd)
    if closeFd(cint(fd)) != 0:
      err(osLastError())
    else:
      ok()

  proc closeSocket*(disp: PDispatcher, fd: AsyncFD, aftercb: CallbackFunc = nil) =
    ## Close asynchronous socket.
    ##
    ## Please note, that socket is not closed immediately. To avoid bugs with
    ## closing socket, while operation pending, socket will be closed as
    ## soon as all pending operations will be notified.
    proc continuation(udata: pointer) =
      let
        param = toPointer(
          if SocketHandle(fd) in disp.selector:
            let ures = disp.unregister2(fd)
            if ures.isErr():
              discard closeFd(cint(fd))
              ures.error()
            else:
              if closeFd(cint(fd)) != 0:
                osLastError()
              else:
                OSErrorCode(0)
          else:
            osdefs.EBADF
        )
      if not(isNil(aftercb)): aftercb(param)

    withData(disp.selector, cint(fd), adata) do:
      # We are scheduling reader and writer callbacks to be called
      # explicitly, so they can get an error and continue work.
      # Callbacks marked as deleted so we don't need to get REAL notifications
      # from system queue for this reader and writer.

      if not(isNil(adata.reader.function)):
        disp.callbacks.addLast(adata.reader)
        adata.reader = default(AsyncCallback)

      if not(isNil(adata.writer.function)):
        disp.callbacks.addLast(adata.writer)
        adata.writer = default(AsyncCallback)

    # We can't unregister file descriptor from system queue here, because
    # in such case processing queue will stuck on poll() call, because there
    # can be no file descriptors registered in system queue.
    var acb = AsyncCallback(function: continuation)
    disp.callbacks.addLast(acb)

  proc closeHandle*(disp: PDispatcher,fd: AsyncFD, aftercb: CallbackFunc = nil) =
    ## Close asynchronous file/pipe handle.
    ##
    ## Please note, that socket is not closed immediately. To avoid bugs with
    ## closing socket, while operation pending, socket will be closed as
    ## soon as all pending operations will be notified.
    ## You can execute ``aftercb`` before actual socket close operation.
    disp.closeSocket(fd, aftercb)

  when chronosEventEngine in ["epoll", "kqueue"]:
    proc addSignal2*(
           disp: PDispatcher,
           signal: int,
           cb: CallbackFunc,
           udata: pointer = nil
         ): Result[SignalHandle, OSErrorCode] =
      ## Start watching signal ``signal``, and when signal appears, call the
      ## callback ``cb`` with specified argument ``udata``. Returns signal
      ## identifier code, which can be used to remove signal callback
      ## via ``removeSignal``.
      var data: SelectorData
      let sigfd = ? disp.selector.registerSignal(signal, data)
      withData(disp.selector, sigfd, adata) do:
        adata.reader = AsyncCallback(function: cb, udata: udata)
      do:
        return err(osdefs.EBADF)
      ok(SignalHandle(sigfd))

    proc addProcess2*(
           disp: PDispatcher,
           pid: int,
           cb: CallbackFunc,
           udata: pointer = nil
         ): Result[ProcessHandle, OSErrorCode] =
      ## Registers callback ``cb`` to be called when process with process
      ## identifier ``pid`` exited. Returns process' descriptor, which can be
      ## used to clear process callback via ``removeProcess``.
      var data: SelectorData
      let procfd = ? disp.selector.registerProcess(pid, data)
      withData(disp.selector, procfd, adata) do:
        adata.reader = AsyncCallback(function: cb, udata: udata)
      do:
        return err(osdefs.EBADF)
      ok(ProcessHandle(procfd))

    proc removeSignal2*(disp: PDispatcher, signalHandle: SignalHandle): Result[void, OSErrorCode] =
      ## Remove watching signal ``signal``.
      disp.selector.unregister2(cint(signalHandle))

    proc removeProcess2*(disp: PDispatcher, procHandle: ProcessHandle): Result[void, OSErrorCode] =
      ## Remove process' watching using process' descriptor ``procfd``.
      disp.selector.unregister2(cint(procHandle))

    proc addSignal*(disp: PDispatcher, signal: int, cb: CallbackFunc,
                    udata: pointer = nil): SignalHandle {.
         raises: [OSError].} =
      ## Start watching signal ``signal``, and when signal appears, call the
      ## callback ``cb`` with specified argument ``udata``. Returns signal
      ## identifier code, which can be used to remove signal callback
      ## via ``removeSignal``.
      addSignal2(disp, signal, cb, udata).tryGet()

    proc removeSignal*(disp: PDispatcher, signalHandle: SignalHandle) {.
         raises: [OSError].} =
      ## Remove watching signal ``signal``.
      removeSignal2(disp, signalHandle).tryGet()

    proc addProcess*(disp: PDispatcher,pid: int, cb: CallbackFunc,
                     udata: pointer = nil): ProcessHandle {.
         raises: [OSError].} =
      ## Registers callback ``cb`` to be called when process with process
      ## identifier ``pid`` exited. Returns process identifier, which can be
      ## used to clear process callback via ``removeProcess``.
      disp.addProcess2(pid, cb, udata).tryGet()

    proc removeProcess*(disp: PDispatcher,procHandle: ProcessHandle) {.
         raises: [OSError].} =
      ## Remove process' watching using process' descriptor ``procHandle``.
      disp.removeProcess2(procHandle).tryGet()

  proc poll*(disp: PDispatcher) {.gcsafe.} =
    ## Perform single asynchronous step.
    var curTime = Moment.now()
    var curTimeout = 0

    # On reentrant `poll` calls from `processCallbacks`, e.g., `waitFor`,
    # complete pending work of the outer `processCallbacks` call.
    # On non-reentrant `poll` calls, this only removes sentinel element.
    disp.processCallbacks()

    # Moving expired timers to `disp.callbacks` and calculate timeout.
    disp.processTimersGetTimeout(curTimeout)

    # Processing IO descriptors and all hardware events.
    let count =
      block:
        let res = disp.selector.selectInto2(curTimeout, disp.keys)
        if res.isErr():
          raiseOsDefect(res.error(), "poll(): Unable to get OS events")
        res.get()

    for i in 0 ..< count:
      let fd = disp.keys[i].fd
      let events = disp.keys[i].events

      withData(disp.selector, cint(fd), adata) do:
        if (Event.Read in events) or (events == {Event.Error}):
          if not isNil(adata.reader.function):
            disp.callbacks.addLast(adata.reader)

        if (Event.Write in events) or (events == {Event.Error}):
          if not isNil(adata.writer.function):
            disp.callbacks.addLast(adata.writer)

        if Event.User in events:
          if not isNil(adata.reader.function):
            disp.callbacks.addLast(adata.reader)

        when chronosEventEngine in ["epoll", "kqueue"]:
          let customSet = {Event.Timer, Event.Signal, Event.Process,
                           Event.Vnode}
          if customSet * events != {}:
            if not isNil(adata.reader.function):
              disp.callbacks.addLast(adata.reader)

    # Moving expired timers to `disp.callbacks`.
    disp.processTimers()

    # We move idle callbacks to `disp.callbacks` only if there no pending
    # network events.
    if count == 0:
      disp.processIdlers()

    # We move tick callbacks to `disp.callbacks` always.
    disp.processTicks()

    # All callbacks which will be added during `processCallbacks` will be
    # scheduled after the sentinel and are processed on next `poll()` call.
    disp.callbacks.addLast(SentinelCallback)
    disp.processCallbacks()

    # All callbacks done, skip `processCallbacks` at start.
    disp.callbacks.addFirst(SentinelCallback)

else:
  proc initAPI() = discard
  proc globalInit() = discard

proc setThreadDispatcher*(disp: PDispatcher) =
  ## Set current thread's dispatcher instance to ``disp``.
  if not(gDisp.isNil()):
    doAssert gDisp.callbacks.len == 0
  gDisp = disp

proc getThreadDispatcher*(): PDispatcher =
  ## Returns current thread's dispatcher instance.
  if gDisp.isNil():
    setThreadDispatcher(newDispatcher())
  gDisp

proc setTimer*(disp: PDispatcher, at: Moment, cb: CallbackFunc,
               udata: pointer = nil): TimerCallback =
  ## Arrange for the callback ``cb`` to be called at the given absolute
  ## timestamp ``at``. You can also pass ``udata`` to callback.
  result = TimerCallback(finishAt: at,
                         function: AsyncCallback(function: cb, udata: udata))
  disp.timers.push(result)

proc addTimer*(disp: PDispatcher, at: Moment, cb: CallbackFunc, udata: pointer = nil) {.
     inline, deprecated: "Use setTimer/clearTimer instead".} =
  ## Arrange for the callback ``cb`` to be called at the given absolute
  ## timestamp ``at``. You can also pass ``udata`` to callback.
  discard setTimer(disp, at, cb, udata)

proc addTimer*(disp: PDispatcher, at: int64, cb: CallbackFunc, udata: pointer = nil) {.
     inline, deprecated: "Use addTimer(Duration, cb, udata)".} =
  discard setTimer(disp, Moment.init(at, Millisecond), cb, udata)

proc addTimer*(disp: PDispatcher, at: uint64, cb: CallbackFunc, udata: pointer = nil) {.
     inline, deprecated: "Use addTimer(Duration, cb, udata)".} =
  discard setTimer(disp, Moment.init(int64(at), Millisecond), cb, udata)

proc removeTimer*(disp: PDispatcher, at: Moment, cb: CallbackFunc, udata: pointer = nil) =
  ## Remove timer callback ``cb`` with absolute timestamp ``at`` from waiting
  ## queue.
  let
    index =
      block:
        var res = -1
        for i in 0 ..< len(disp.timers):
          if (disp.timers[i].finishAt == at) and
             (disp.timers[i].function.function == cb) and
             (disp.timers[i].function.udata == udata):
            res = i
            break
        res
  if index != -1:
    disp.timers.del(index)

proc removeTimer*(disp: PDispatcher, at: int64, cb: CallbackFunc, udata: pointer = nil) {.
     inline, deprecated: "Use removeTimer(Duration, cb, udata)".} =
  removeTimer(disp, Moment.init(at, Millisecond), cb, udata)

proc removeTimer*(disp: PDispatcher, at: uint64, cb: CallbackFunc, udata: pointer = nil) {.
     inline, deprecated: "Use removeTimer(Duration, cb, udata)".} =
  removeTimer(disp, Moment.init(int64(at), Millisecond), cb, udata)

proc callSoon*(disp: PDispatcher, acb: AsyncCallback) =
  ## Schedule `cbproc` to be called as soon as possible.
  ## The callback is called when control returns to the event disp.
  disp.callbacks.addLast(acb)

proc callSoon*(disp: PDispatcher, cbproc: CallbackFunc, data: pointer) {.
     gcsafe.} =
  ## Schedule `cbproc` to be called as soon as possible.
  ## The callback is called when control returns to the event disp.
  doAssert(not isNil(cbproc))
  disp.callSoon(AsyncCallback(function: cbproc, udata: data))

proc callSoon*(disp: PDispatcher, cbproc: CallbackFunc) =
  disp.callSoon(cbproc, nil)

proc callIdle*(disp: PDispatcher, acb: AsyncCallback) =
  ## Schedule ``cbproc`` to be called when there no pending network events
  ## available.
  ##
  ## **WARNING!** Despite the name, "idle" callbacks called on every disp
  ## iteration if there no network events available, not when the disp is
  ## actually "idle".
  disp.idlers.addLast(acb)

proc callIdle*(disp: PDispatcher, cbproc: CallbackFunc, data: pointer) =
  ## Schedule ``cbproc`` to be called when there no pending network events
  ## available.
  ##
  ## **WARNING!** Despite the name, "idle" callbacks called on every disp
  ## iteration if there no network events available, not when the disp is
  ## actually "idle".
  doAssert(not isNil(cbproc))
  disp.callIdle(AsyncCallback(function: cbproc, udata: data))

proc callIdle*(disp: PDispatcher, cbproc: CallbackFunc) =
  callIdle(disp, cbproc, nil)

proc internalCallTick*(disp: PDispatcher, acb: AsyncCallback) =
  ## Schedule ``cbproc`` to be called after all scheduled callbacks, but only
  ## when OS system queue finished processing events.
  disp.ticks.addLast(acb)

proc internalCallTick*(disp: PDispatcher, cbproc: CallbackFunc, data: pointer) =
  ## Schedule ``cbproc`` to be called after all scheduled callbacks when
  ## OS system queue processing is done.
  doAssert(not isNil(cbproc))
  internalCallTick(disp, AsyncCallback(function: cbproc, udata: data))

proc internalCallTick*(disp: PDispatcher, cbproc: CallbackFunc) =
  internalCallTick(disp, AsyncCallback(function: cbproc, udata: nil))

proc runForever*(disp: PDispatcher) =
  ## Begins a never ending global dispatcher poll disp.
  ## Raises different exceptions depending on the platform.
  while true:
    disp.poll()

proc addTracker*[T](disp: PDispatcher, id: string, tracker: T) {.
     deprecated: "Please use trackCounter facility instead".} =
  ## Add new ``tracker`` object to current thread dispatcher with identifier
  ## ``id``.
  disp.trackers[id] = tracker

proc getTracker*(disp: PDispatcher, id: string): TrackerBase {.
     deprecated: "Please use getTrackerCounter() instead".} =
  ## Get ``tracker`` from current thread dispatcher using identifier ``id``.
  disp.trackers.getOrDefault(id, nil)

proc trackCounter*(disp: PDispatcher, name: string) {.noinit.} =
  ## Increase tracker counter with name ``name`` by 1.
  let tracker = TrackerCounter(opened: 0'u64, closed: 0'u64)
  inc(disp.counters.mgetOrPut(name, tracker).opened)

proc untrackCounter*(disp: PDispatcher, name: string) {.noinit.} =
  ## Decrease tracker counter with name ``name`` by 1.
  let tracker = TrackerCounter(opened: 0'u64, closed: 0'u64)
  inc(disp.counters.mgetOrPut(name, tracker).closed)

proc getTrackerCounter*(disp: PDispatcher, name: string): TrackerCounter {.noinit.} =
  ## Return value of counter with name ``name``.
  let tracker = TrackerCounter(opened: 0'u64, closed: 0'u64)
  disp.counters.getOrDefault(name, tracker)

proc isCounterLeaked*(disp: PDispatcher, name: string): bool {.noinit.} =
  ## Returns ``true`` if leak is detected, number of `opened` not equal to
  ## number of `closed` requests.
  let tracker = TrackerCounter(opened: 0'u64, closed: 0'u64)
  let res = disp.counters.getOrDefault(name, tracker)
  res.opened != res.closed

iterator trackerCounters*(
           disp: PDispatcher
         ): tuple[name: string, value: TrackerCounter] =
  ## Iterates over `disp` thread dispatcher tracker counter table, returns all
  ## the tracker counter's names and values.
  doAssert(not(isNil(disp)))
  for key, value in disp.counters.pairs():
    yield (key, value)

iterator trackerCounterKeys*(disp: PDispatcher): string =
  doAssert(not(isNil(disp)))
  ## Iterates over `disp` thread dispatcher tracker counter table, returns all
  ## tracker names.
  for key in disp.counters.keys():
    yield key

when chronosFutureTracking:
  iterator pendingFutures*(): FutureBase =
    ## Iterates over the list of pending Futures (Future[T] objects which not
    ## yet completed, cancelled or failed).
    var slider = futureList.head
    while not(isNil(slider)):
      yield slider
      slider = slider.next

  proc pendingFuturesCount*(): uint =
    ## Returns number of pending Futures (Future[T] objects which not yet
    ## completed, cancelled or failed).
    futureList.count

when not defined(nimdoc):
  # Perform global per-module initialization.
  globalInit()

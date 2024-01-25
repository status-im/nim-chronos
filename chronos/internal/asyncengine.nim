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
## For more information, see the `Concepts` chapter of the guide.

from nativesockets import Port
import std/[tables, heapqueue, deques]
import results
import ".."/[config, futures, osdefs, oserrno, osutils, timer]

import ./[asyncmacro, errors]

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

type
  AsyncCallback* = InternalAsyncCallback

  TimerCallback* = ref object
    finishAt*: Moment
    function*: AsyncCallback

  TrackerBase* = ref object of RootRef
    id*: string
    dump*: proc(): string {.gcsafe, raises: [].}
    isLeaked*: proc(): bool {.gcsafe, raises: [].}

  TrackerCounter* = object
    opened*: uint64
    closed*: uint64

  PDispatcherBase = ref object of RootRef
    timers*: HeapQueue[TimerCallback]
    callbacks*: Deque[AsyncCallback]
    idlers*: Deque[AsyncCallback]
    ticks*: Deque[AsyncCallback]
    trackers*: Table[string, TrackerBase]
    counters*: Table[string, TrackerCounter]

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

template processTimersGetTimeout(loop, timeout: untyped) =
  var lastFinish = curTime
  while loop.timers.len > 0:
    if loop.timers[0].function.function.isNil:
      discard loop.timers.pop()
      continue

    lastFinish = loop.timers[0].finishAt
    if curTime < lastFinish:
      break

    loop.callbacks.addLast(loop.timers.pop().function)

  if loop.timers.len > 0:
    timeout = (lastFinish - curTime).getAsyncTimestamp()

  if timeout == 0:
    if (len(loop.callbacks) == 0) and (len(loop.idlers) == 0):
      when defined(windows):
        timeout = INFINITE
      else:
        timeout = -1
  else:
    if (len(loop.callbacks) != 0) or (len(loop.idlers) != 0):
      timeout = 0

template processTimers(loop: untyped) =
  var curTime = Moment.now()
  while loop.timers.len > 0:
    if loop.timers[0].function.function.isNil:
      discard loop.timers.pop()
      continue

    if curTime < loop.timers[0].finishAt:
      break
    loop.callbacks.addLast(loop.timers.pop().function)

template processIdlers(loop: untyped) =
  if len(loop.idlers) > 0:
    loop.callbacks.addLast(loop.idlers.popFirst())

template processTicks(loop: untyped) =
  while len(loop.ticks) > 0:
    loop.callbacks.addLast(loop.ticks.popFirst())

template processCallbacks(loop: untyped) =
  while true:
    let callable = loop.callbacks.popFirst()  # len must be > 0 due to sentinel
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

proc raiseOsDefect*(error: OSErrorCode, msg = "") {.noreturn, noinline.} =
  # Reraise OS error code as a Defect, where it's unexpected and can't be
  # handled. We include the stack trace in the message because otherwise,
  # it's easily lost.
  raise (ref Defect)(msg: msg & "\n[" & $int(error) & "] " & osErrorMsg(error) &
                          "\n" & getStackTrace())

func toPointer(error: OSErrorCode): pointer =
  when sizeof(int) == 8:
    cast[pointer](uint64(uint32(error)))
  else:
    cast[pointer](uint32(error))

func toException*(v: OSErrorCode): ref OSError = newOSError(v)
  # This helper will allow to use `tryGet()` and raise OSError for
  # Result[T, OSErrorCode] values.

when defined(nimdoc):
  type
    PDispatcher* = ref object of PDispatcherBase
    AsyncFD* = distinct cint

  var gDisp {.threadvar.}: PDispatcher

  proc newDispatcher*(): PDispatcher = discard
  proc poll*() = discard
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
  type
    CompletionKey = ULONG_PTR

    CompletionData* = object
      cb*: CallbackFunc
      errCode*: OSErrorCode
      bytesCount*: uint32
      udata*: pointer

    CustomOverlapped* = object of OVERLAPPED
      data*: CompletionData

    DispatcherFlag* = enum
      SignalHandlerInstalled

    PDispatcher* = ref object of PDispatcherBase
      ioPort: HANDLE
      handles: HashSet[AsyncFD]
      connectEx*: WSAPROC_CONNECTEX
      acceptEx*: WSAPROC_ACCEPTEX
      getAcceptExSockAddrs*: WSAPROC_GETACCEPTEXSOCKADDRS
      transmitFile*: WSAPROC_TRANSMITFILE
      getQueuedCompletionStatusEx*: LPFN_GETQUEUEDCOMPLETIONSTATUSEX
      disconnectEx*: WSAPROC_DISCONNECTEX
      flags: set[DispatcherFlag]

    PtrCustomOverlapped* = ptr CustomOverlapped

    RefCustomOverlapped* = ref CustomOverlapped

    PostCallbackData = object
      ioPort: HANDLE
      handleFd: AsyncFD
      waitFd: HANDLE
      udata: pointer
      ovlref: RefCustomOverlapped
      ovl: pointer

    WaitableHandle* = ref PostCallbackData
    ProcessHandle* = distinct WaitableHandle
    SignalHandle* = distinct WaitableHandle

    WaitableResult* {.pure.} = enum
      Ok, Timeout

    AsyncFD* = distinct int

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

  proc initAPI(loop: PDispatcher) =
    var funcPointer: pointer = nil

    let kernel32 = getModuleHandle(newWideCString("kernel32.dll"))
    loop.getQueuedCompletionStatusEx = cast[LPFN_GETQUEUEDCOMPLETIONSTATUSEX](
      getProcAddress(kernel32, "GetQueuedCompletionStatusEx"))

    let sock = osdefs.socket(osdefs.AF_INET, 1, 6)
    if sock == osdefs.INVALID_SOCKET:
      raiseOsDefect(osLastError(), "initAPI(): Unable to create control socket")

    block:
      let res = getFunc(sock, funcPointer, WSAID_CONNECTEX)
      if not(res):
        raiseOsDefect(osLastError(), "initAPI(): Unable to initialize " &
                                     "dispatcher's ConnectEx()")
      loop.connectEx = cast[WSAPROC_CONNECTEX](funcPointer)

    block:
      let res = getFunc(sock, funcPointer, WSAID_ACCEPTEX)
      if not(res):
        raiseOsDefect(osLastError(), "initAPI(): Unable to initialize " &
                                     "dispatcher's AcceptEx()")
      loop.acceptEx = cast[WSAPROC_ACCEPTEX](funcPointer)

    block:
      let res = getFunc(sock, funcPointer, WSAID_GETACCEPTEXSOCKADDRS)
      if not(res):
        raiseOsDefect(osLastError(), "initAPI(): Unable to initialize " &
                                     "dispatcher's GetAcceptExSockAddrs()")
      loop.getAcceptExSockAddrs =
        cast[WSAPROC_GETACCEPTEXSOCKADDRS](funcPointer)

    block:
      let res = getFunc(sock, funcPointer, WSAID_TRANSMITFILE)
      if not(res):
        raiseOsDefect(osLastError(), "initAPI(): Unable to initialize " &
                                     "dispatcher's TransmitFile()")
      loop.transmitFile = cast[WSAPROC_TRANSMITFILE](funcPointer)

    block:
      let res = getFunc(sock, funcPointer, WSAID_DISCONNECTEX)
      if not(res):
        raiseOsDefect(osLastError(), "initAPI(): Unable to initialize " &
                                     "dispatcher's DisconnectEx()")
      loop.disconnectEx = cast[WSAPROC_DISCONNECTEX](funcPointer)

    if closeFd(sock) != 0:
      raiseOsDefect(osLastError(), "initAPI(): Unable to close control socket")

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

  var gDisp{.threadvar.}: PDispatcher ## Global dispatcher

  proc setThreadDispatcher*(disp: PDispatcher) {.gcsafe, raises: [].}
  proc getThreadDispatcher*(): PDispatcher {.gcsafe, raises: [].}

  proc getIoHandler*(disp: PDispatcher): HANDLE =
    ## Returns the underlying IO Completion Port handle (Windows) or selector
    ## (Unix) for the specified dispatcher.
    disp.ioPort

  proc register2*(fd: AsyncFD): Result[void, OSErrorCode] =
    ## Register file descriptor ``fd`` in thread's dispatcher.
    let loop = getThreadDispatcher()
    if createIoCompletionPort(HANDLE(fd), loop.ioPort, cast[CompletionKey](fd),
                              1) == osdefs.INVALID_HANDLE_VALUE:
      return err(osLastError())
    loop.handles.incl(fd)
    ok()

  proc register*(fd: AsyncFD) {.raises: [OSError].} =
    ## Register file descriptor ``fd`` in thread's dispatcher.
    register2(fd).tryGet()

  proc unregister*(fd: AsyncFD) =
    ## Unregisters ``fd``.
    getThreadDispatcher().handles.excl(fd)

  {.push stackTrace: off.}
  proc waitableCallback(param: pointer, timerOrWaitFired: WINBOOL) {.
       stdcallbackFunc.} =
    # This procedure will be executed in `wait thread`, so it must not use
    # GC related objects.
    # We going to ignore callbacks which was spawned when `isNil(param) == true`
    # because we unable to indicate this error.
    if isNil(param): return
    var wh = cast[ptr PostCallbackData](param)
    # We ignore result of postQueueCompletionStatus() call because we unable to
    # indicate error.
    discard postQueuedCompletionStatus(wh[].ioPort, DWORD(timerOrWaitFired),
                                       ULONG_PTR(wh[].handleFd),
                                       wh[].ovl)
  {.pop.}

  proc registerWaitable*(
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
    let loop = getThreadDispatcher()
    var ovl = RefCustomOverlapped(data: CompletionData(cb: cb))

    var whandle = (ref PostCallbackData)(
      ioPort: loop.getIoHandler(),
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

  proc addProcess2*(pid: int, cb: CallbackFunc,
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

  proc addProcess*(pid: int, cb: CallbackFunc,
                   udata: pointer = nil): ProcessHandle {.
       raises: [OSError].} =
    ## Registers callback ``cb`` to be called when process with process
    ## identifier ``pid`` exited. Returns process identifier, which can be
    ## used to clear process callback via ``removeProcess``.
    addProcess2(pid, cb, udata).tryGet()

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

  proc addSignal2*(signal: int, cb: CallbackFunc,
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
    let loop = getThreadDispatcher()
    var hWait: WaitableHandle = nil

    proc continuation(ucdata: pointer) {.gcsafe.} =
      doAssert(not(isNil(ucdata)))
      doAssert(not(isNil(hWait)))
      cb(hWait[].udata)

    if SignalHandlerInstalled notin loop.flags:
      if getConsoleCP() != 0'u32:
        # Console application, we going to cleanup Nim default signal handlers.
        if setConsoleCtrlHandler(consoleCtrlEventHandler, TRUE) == FALSE:
          return err(osLastError())
        loop.flags.incl(SignalHandlerInstalled)
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

  proc poll*() =
    let loop = getThreadDispatcher()
    var
      curTime = Moment.now()
      curTimeout = DWORD(0)
      events: array[MaxEventsCount, osdefs.OVERLAPPED_ENTRY]

    # On reentrant `poll` calls from `processCallbacks`, e.g., `waitFor`,
    # complete pending work of the outer `processCallbacks` call.
    # On non-reentrant `poll` calls, this only removes sentinel element.
    processCallbacks(loop)

    # Moving expired timers to `loop.callbacks` and calculate timeout
    loop.processTimersGetTimeout(curTimeout)

    let networkEventsCount =
      if isNil(loop.getQueuedCompletionStatusEx):
        let res = getQueuedCompletionStatus(
          loop.ioPort,
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
        let res = loop.getQueuedCompletionStatusEx(
          loop.ioPort,
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
      loop.callbacks.addLast(acb)

    # Moving expired timers to `loop.callbacks`.
    loop.processTimers()

    # We move idle callbacks to `loop.callbacks` only if there no pending
    # network events.
    if networkEventsCount == 0:
      loop.processIdlers()

    # We move tick callbacks to `loop.callbacks` always.
    processTicks(loop)

    # All callbacks which will be added during `processCallbacks` will be
    # scheduled after the sentinel and are processed on next `poll()` call.
    loop.callbacks.addLast(SentinelCallback)
    processCallbacks(loop)

    # All callbacks done, skip `processCallbacks` at start.
    loop.callbacks.addFirst(SentinelCallback)

  proc closeSocket*(fd: AsyncFD, aftercb: CallbackFunc = nil) =
    ## Closes a socket and ensures that it is unregistered.
    let loop = getThreadDispatcher()
    loop.handles.excl(fd)
    let
      param = toPointer(
        if closeFd(SocketHandle(fd)) == 0:
          OSErrorCode(0)
        else:
          osLastError()
      )
    if not(isNil(aftercb)):
      loop.callbacks.addLast(AsyncCallback(function: aftercb, udata: param))

  proc closeHandle*(fd: AsyncFD, aftercb: CallbackFunc = nil) =
    ## Closes a (pipe/file) handle and ensures that it is unregistered.
    let loop = getThreadDispatcher()
    loop.handles.excl(fd)
    let
      param = toPointer(
        if closeFd(HANDLE(fd)) == 0:
          OSErrorCode(0)
        else:
          osLastError()
      )

    if not(isNil(aftercb)):
      loop.callbacks.addLast(AsyncCallback(function: aftercb, udata: param))

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

  type
    AsyncFD* = distinct cint

    SelectorData* = object
      reader*: AsyncCallback
      writer*: AsyncCallback

    PDispatcher* = ref object of PDispatcherBase
      selector: Selector[SelectorData]
      keys: seq[ReadyKey]

  proc `==`*(x, y: AsyncFD): bool {.borrow, gcsafe.}

  proc globalInit() =
    # We are ignoring SIGPIPE signal, because we are working with EPIPE.
    signal(cint(SIGPIPE), SIG_IGN)

  proc initAPI(disp: PDispatcher) =
    discard

  proc newDispatcher*(): PDispatcher =
    ## Create new dispatcher.
    let selector =
      block:
        let res = Selector.new(SelectorData)
        if res.isErr(): raiseOsDefect(res.error(),
                                      "Could not initialize selector")
        res.get()

    var res = PDispatcher(
      selector: selector,
      timers: initHeapQueue[TimerCallback](),
      callbacks: initDeque[AsyncCallback](chronosEventsCount),
      idlers: initDeque[AsyncCallback](),
      keys: newSeq[ReadyKey](chronosEventsCount),
      trackers: initTable[string, TrackerBase](),
      counters: initTable[string, TrackerCounter]()
    )
    res.callbacks.addLast(SentinelCallback)
    initAPI(res)
    res

  var gDisp{.threadvar.}: PDispatcher ## Global dispatcher

  proc setThreadDispatcher*(disp: PDispatcher) {.gcsafe, raises: [].}
  proc getThreadDispatcher*(): PDispatcher {.gcsafe, raises: [].}

  proc getIoHandler*(disp: PDispatcher): Selector[SelectorData] =
    ## Returns system specific OS queue.
    disp.selector

  proc contains*(disp: PDispatcher, fd: AsyncFD): bool {.inline.} =
    ## Returns ``true`` if ``fd`` is registered in thread's dispatcher.
    cint(fd) in disp.selector

  proc register2*(fd: AsyncFD): Result[void, OSErrorCode] =
    ## Register file descriptor ``fd`` in thread's dispatcher.
    var data: SelectorData
    getThreadDispatcher().selector.registerHandle2(cint(fd), {}, data)

  proc unregister2*(fd: AsyncFD): Result[void, OSErrorCode] =
    ## Unregister file descriptor ``fd`` from thread's dispatcher.
    getThreadDispatcher().selector.unregister2(cint(fd))

  proc addReader2*(fd: AsyncFD, cb: CallbackFunc,
                   udata: pointer = nil): Result[void, OSErrorCode] =
    ## Start watching the file descriptor ``fd`` for read availability and then
    ## call the callback ``cb`` with specified argument ``udata``.
    let loop = getThreadDispatcher()
    var newEvents = {Event.Read}
    withData(loop.selector, cint(fd), adata) do:
      let acb = AsyncCallback(function: cb, udata: udata)
      adata.reader = acb
      if not(isNil(adata.writer.function)):
        newEvents.incl(Event.Write)
    do:
      return err(osdefs.EBADF)
    loop.selector.updateHandle2(cint(fd), newEvents)

  proc removeReader2*(fd: AsyncFD): Result[void, OSErrorCode] =
    ## Stop watching the file descriptor ``fd`` for read availability.
    let loop = getThreadDispatcher()
    var newEvents: set[Event]
    withData(loop.selector, cint(fd), adata) do:
      # We need to clear `reader` data, because `selectors` don't do it
      adata.reader = default(AsyncCallback)
      if not(isNil(adata.writer.function)):
        newEvents.incl(Event.Write)
    do:
      return err(osdefs.EBADF)
    loop.selector.updateHandle2(cint(fd), newEvents)

  proc addWriter2*(fd: AsyncFD, cb: CallbackFunc,
                   udata: pointer = nil): Result[void, OSErrorCode] =
    ## Start watching the file descriptor ``fd`` for write availability and then
    ## call the callback ``cb`` with specified argument ``udata``.
    let loop = getThreadDispatcher()
    var newEvents = {Event.Write}
    withData(loop.selector, cint(fd), adata) do:
      let acb = AsyncCallback(function: cb, udata: udata)
      adata.writer = acb
      if not(isNil(adata.reader.function)):
        newEvents.incl(Event.Read)
    do:
      return err(osdefs.EBADF)
    loop.selector.updateHandle2(cint(fd), newEvents)

  proc removeWriter2*(fd: AsyncFD): Result[void, OSErrorCode] =
    ## Stop watching the file descriptor ``fd`` for write availability.
    let loop = getThreadDispatcher()
    var newEvents: set[Event]
    withData(loop.selector, cint(fd), adata) do:
      # We need to clear `writer` data, because `selectors` don't do it
      adata.writer = default(AsyncCallback)
      if not(isNil(adata.reader.function)):
        newEvents.incl(Event.Read)
    do:
      return err(osdefs.EBADF)
    loop.selector.updateHandle2(cint(fd), newEvents)

  proc register*(fd: AsyncFD) {.raises: [OSError].} =
    ## Register file descriptor ``fd`` in thread's dispatcher.
    register2(fd).tryGet()

  proc unregister*(fd: AsyncFD) {.raises: [OSError].} =
    ## Unregister file descriptor ``fd`` from thread's dispatcher.
    unregister2(fd).tryGet()

  proc addReader*(fd: AsyncFD, cb: CallbackFunc, udata: pointer = nil) {.
       raises: [OSError].} =
    ## Start watching the file descriptor ``fd`` for read availability and then
    ## call the callback ``cb`` with specified argument ``udata``.
    addReader2(fd, cb, udata).tryGet()

  proc removeReader*(fd: AsyncFD) {.raises: [OSError].} =
    ## Stop watching the file descriptor ``fd`` for read availability.
    removeReader2(fd).tryGet()

  proc addWriter*(fd: AsyncFD, cb: CallbackFunc, udata: pointer = nil) {.
       raises: [OSError].} =
    ## Start watching the file descriptor ``fd`` for write availability and then
    ## call the callback ``cb`` with specified argument ``udata``.
    addWriter2(fd, cb, udata).tryGet()

  proc removeWriter*(fd: AsyncFD) {.raises: [OSError].} =
    ## Stop watching the file descriptor ``fd`` for write availability.
    removeWriter2(fd).tryGet()

  proc unregisterAndCloseFd*(fd: AsyncFD): Result[void, OSErrorCode] =
    ## Unregister from system queue and close asynchronous socket.
    ##
    ## NOTE: Use this function to close temporary sockets/pipes only (which
    ## are not exposed to the public and not supposed to be used/reused).
    ## Please use closeSocket(AsyncFD) and closeHandle(AsyncFD) instead.
    doAssert(fd != AsyncFD(osdefs.INVALID_SOCKET))
    ? unregister2(fd)
    if closeFd(cint(fd)) != 0:
      err(osLastError())
    else:
      ok()

  proc closeSocket*(fd: AsyncFD, aftercb: CallbackFunc = nil) =
    ## Close asynchronous socket.
    ##
    ## Please note, that socket is not closed immediately. To avoid bugs with
    ## closing socket, while operation pending, socket will be closed as
    ## soon as all pending operations will be notified.
    let loop = getThreadDispatcher()

    proc continuation(udata: pointer) =
      let
        param = toPointer(
          if SocketHandle(fd) in loop.selector:
            let ures = unregister2(fd)
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

    withData(loop.selector, cint(fd), adata) do:
      # We are scheduling reader and writer callbacks to be called
      # explicitly, so they can get an error and continue work.
      # Callbacks marked as deleted so we don't need to get REAL notifications
      # from system queue for this reader and writer.

      if not(isNil(adata.reader.function)):
        loop.callbacks.addLast(adata.reader)
        adata.reader = default(AsyncCallback)

      if not(isNil(adata.writer.function)):
        loop.callbacks.addLast(adata.writer)
        adata.writer = default(AsyncCallback)

    # We can't unregister file descriptor from system queue here, because
    # in such case processing queue will stuck on poll() call, because there
    # can be no file descriptors registered in system queue.
    var acb = AsyncCallback(function: continuation)
    loop.callbacks.addLast(acb)

  proc closeHandle*(fd: AsyncFD, aftercb: CallbackFunc = nil) =
    ## Close asynchronous file/pipe handle.
    ##
    ## Please note, that socket is not closed immediately. To avoid bugs with
    ## closing socket, while operation pending, socket will be closed as
    ## soon as all pending operations will be notified.
    ## You can execute ``aftercb`` before actual socket close operation.
    closeSocket(fd, aftercb)

  when chronosEventEngine in ["epoll", "kqueue"]:
    type
      ProcessHandle* = distinct int
      SignalHandle* = distinct int

    proc addSignal2*(
           signal: int,
           cb: CallbackFunc,
           udata: pointer = nil
         ): Result[SignalHandle, OSErrorCode] =
      ## Start watching signal ``signal``, and when signal appears, call the
      ## callback ``cb`` with specified argument ``udata``. Returns signal
      ## identifier code, which can be used to remove signal callback
      ## via ``removeSignal``.
      let loop = getThreadDispatcher()
      var data: SelectorData
      let sigfd = ? loop.selector.registerSignal(signal, data)
      withData(loop.selector, sigfd, adata) do:
        adata.reader = AsyncCallback(function: cb, udata: udata)
      do:
        return err(osdefs.EBADF)
      ok(SignalHandle(sigfd))

    proc addProcess2*(
           pid: int,
           cb: CallbackFunc,
           udata: pointer = nil
         ): Result[ProcessHandle, OSErrorCode] =
      ## Registers callback ``cb`` to be called when process with process
      ## identifier ``pid`` exited. Returns process' descriptor, which can be
      ## used to clear process callback via ``removeProcess``.
      let loop = getThreadDispatcher()
      var data: SelectorData
      let procfd = ? loop.selector.registerProcess(pid, data)
      withData(loop.selector, procfd, adata) do:
        adata.reader = AsyncCallback(function: cb, udata: udata)
      do:
        return err(osdefs.EBADF)
      ok(ProcessHandle(procfd))

    proc removeSignal2*(signalHandle: SignalHandle): Result[void, OSErrorCode] =
      ## Remove watching signal ``signal``.
      getThreadDispatcher().selector.unregister2(cint(signalHandle))

    proc removeProcess2*(procHandle: ProcessHandle): Result[void, OSErrorCode] =
      ## Remove process' watching using process' descriptor ``procfd``.
      getThreadDispatcher().selector.unregister2(cint(procHandle))

    proc addSignal*(signal: int, cb: CallbackFunc,
                    udata: pointer = nil): SignalHandle {.
         raises: [OSError].} =
      ## Start watching signal ``signal``, and when signal appears, call the
      ## callback ``cb`` with specified argument ``udata``. Returns signal
      ## identifier code, which can be used to remove signal callback
      ## via ``removeSignal``.
      addSignal2(signal, cb, udata).tryGet()

    proc removeSignal*(signalHandle: SignalHandle) {.
         raises: [OSError].} =
      ## Remove watching signal ``signal``.
      removeSignal2(signalHandle).tryGet()

    proc addProcess*(pid: int, cb: CallbackFunc,
                     udata: pointer = nil): ProcessHandle {.
         raises: [OSError].} =
      ## Registers callback ``cb`` to be called when process with process
      ## identifier ``pid`` exited. Returns process identifier, which can be
      ## used to clear process callback via ``removeProcess``.
      addProcess2(pid, cb, udata).tryGet()

    proc removeProcess*(procHandle: ProcessHandle) {.
         raises: [OSError].} =
      ## Remove process' watching using process' descriptor ``procHandle``.
      removeProcess2(procHandle).tryGet()

  proc poll*() {.gcsafe.} =
    ## Perform single asynchronous step.
    let loop = getThreadDispatcher()
    var curTime = Moment.now()
    var curTimeout = 0

    # On reentrant `poll` calls from `processCallbacks`, e.g., `waitFor`,
    # complete pending work of the outer `processCallbacks` call.
    # On non-reentrant `poll` calls, this only removes sentinel element.
    processCallbacks(loop)

    # Moving expired timers to `loop.callbacks` and calculate timeout.
    loop.processTimersGetTimeout(curTimeout)

    # Processing IO descriptors and all hardware events.
    let count =
      block:
        let res = loop.selector.selectInto2(curTimeout, loop.keys)
        if res.isErr():
          raiseOsDefect(res.error(), "poll(): Unable to get OS events")
        res.get()

    for i in 0 ..< count:
      let fd = loop.keys[i].fd
      let events = loop.keys[i].events

      withData(loop.selector, cint(fd), adata) do:
        if (Event.Read in events) or (events == {Event.Error}):
          if not isNil(adata.reader.function):
            loop.callbacks.addLast(adata.reader)

        if (Event.Write in events) or (events == {Event.Error}):
          if not isNil(adata.writer.function):
            loop.callbacks.addLast(adata.writer)

        if Event.User in events:
          if not isNil(adata.reader.function):
            loop.callbacks.addLast(adata.reader)

        when chronosEventEngine in ["epoll", "kqueue"]:
          let customSet = {Event.Timer, Event.Signal, Event.Process,
                           Event.Vnode}
          if customSet * events != {}:
            if not isNil(adata.reader.function):
              loop.callbacks.addLast(adata.reader)

    # Moving expired timers to `loop.callbacks`.
    loop.processTimers()

    # We move idle callbacks to `loop.callbacks` only if there no pending
    # network events.
    if count == 0:
      loop.processIdlers()

    # We move tick callbacks to `loop.callbacks` always.
    processTicks(loop)

    # All callbacks which will be added during `processCallbacks` will be
    # scheduled after the sentinel and are processed on next `poll()` call.
    loop.callbacks.addLast(SentinelCallback)
    processCallbacks(loop)

    # All callbacks done, skip `processCallbacks` at start.
    loop.callbacks.addFirst(SentinelCallback)

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

proc setGlobalDispatcher*(disp: PDispatcher) {.
      gcsafe, deprecated: "Use setThreadDispatcher() instead".} =
  setThreadDispatcher(disp)

proc getGlobalDispatcher*(): PDispatcher {.
      gcsafe, deprecated: "Use getThreadDispatcher() instead".} =
  getThreadDispatcher()

proc setTimer*(at: Moment, cb: CallbackFunc,
               udata: pointer = nil): TimerCallback =
  ## Arrange for the callback ``cb`` to be called at the given absolute
  ## timestamp ``at``. You can also pass ``udata`` to callback.
  let loop = getThreadDispatcher()
  result = TimerCallback(finishAt: at,
                         function: AsyncCallback(function: cb, udata: udata))
  loop.timers.push(result)

proc clearTimer*(timer: TimerCallback) {.inline.} =
  timer.function = default(AsyncCallback)

proc addTimer*(at: Moment, cb: CallbackFunc, udata: pointer = nil) {.
     inline, deprecated: "Use setTimer/clearTimer instead".} =
  ## Arrange for the callback ``cb`` to be called at the given absolute
  ## timestamp ``at``. You can also pass ``udata`` to callback.
  discard setTimer(at, cb, udata)

proc addTimer*(at: int64, cb: CallbackFunc, udata: pointer = nil) {.
     inline, deprecated: "Use addTimer(Duration, cb, udata)".} =
  discard setTimer(Moment.init(at, Millisecond), cb, udata)

proc addTimer*(at: uint64, cb: CallbackFunc, udata: pointer = nil) {.
     inline, deprecated: "Use addTimer(Duration, cb, udata)".} =
  discard setTimer(Moment.init(int64(at), Millisecond), cb, udata)

proc removeTimer*(at: Moment, cb: CallbackFunc, udata: pointer = nil) =
  ## Remove timer callback ``cb`` with absolute timestamp ``at`` from waiting
  ## queue.
  let
    loop = getThreadDispatcher()
    index =
      block:
        var res = -1
        for i in 0 ..< len(loop.timers):
          if (loop.timers[i].finishAt == at) and
             (loop.timers[i].function.function == cb) and
             (loop.timers[i].function.udata == udata):
            res = i
            break
        res
  if index != -1:
    loop.timers.del(index)

proc removeTimer*(at: int64, cb: CallbackFunc, udata: pointer = nil) {.
     inline, deprecated: "Use removeTimer(Duration, cb, udata)".} =
  removeTimer(Moment.init(at, Millisecond), cb, udata)

proc removeTimer*(at: uint64, cb: CallbackFunc, udata: pointer = nil) {.
     inline, deprecated: "Use removeTimer(Duration, cb, udata)".} =
  removeTimer(Moment.init(int64(at), Millisecond), cb, udata)

proc callSoon*(acb: AsyncCallback) =
  ## Schedule `cbproc` to be called as soon as possible.
  ## The callback is called when control returns to the event loop.
  getThreadDispatcher().callbacks.addLast(acb)

proc callSoon*(cbproc: CallbackFunc, data: pointer) {.
     gcsafe.} =
  ## Schedule `cbproc` to be called as soon as possible.
  ## The callback is called when control returns to the event loop.
  doAssert(not isNil(cbproc))
  callSoon(AsyncCallback(function: cbproc, udata: data))

proc callSoon*(cbproc: CallbackFunc) =
  callSoon(cbproc, nil)

proc callIdle*(acb: AsyncCallback) =
  ## Schedule ``cbproc`` to be called when there no pending network events
  ## available.
  ##
  ## **WARNING!** Despite the name, "idle" callbacks called on every loop
  ## iteration if there no network events available, not when the loop is
  ## actually "idle".
  getThreadDispatcher().idlers.addLast(acb)

proc callIdle*(cbproc: CallbackFunc, data: pointer) =
  ## Schedule ``cbproc`` to be called when there no pending network events
  ## available.
  ##
  ## **WARNING!** Despite the name, "idle" callbacks called on every loop
  ## iteration if there no network events available, not when the loop is
  ## actually "idle".
  doAssert(not isNil(cbproc))
  callIdle(AsyncCallback(function: cbproc, udata: data))

proc callIdle*(cbproc: CallbackFunc) =
  callIdle(cbproc, nil)

proc internalCallTick*(acb: AsyncCallback) =
  ## Schedule ``cbproc`` to be called after all scheduled callbacks, but only
  ## when OS system queue finished processing events.
  getThreadDispatcher().ticks.addLast(acb)

proc internalCallTick*(cbproc: CallbackFunc, data: pointer) =
  ## Schedule ``cbproc`` to be called after all scheduled callbacks when
  ## OS system queue processing is done.
  doAssert(not isNil(cbproc))
  internalCallTick(AsyncCallback(function: cbproc, udata: data))

proc internalCallTick*(cbproc: CallbackFunc) =
  internalCallTick(AsyncCallback(function: cbproc, udata: nil))

proc runForever*() =
  ## Begins a never ending global dispatcher poll loop.
  ## Raises different exceptions depending on the platform.
  while true:
    poll()

proc addTracker*[T](id: string, tracker: T) {.
     deprecated: "Please use trackCounter facility instead".} =
  ## Add new ``tracker`` object to current thread dispatcher with identifier
  ## ``id``.
  getThreadDispatcher().trackers[id] = tracker

proc getTracker*(id: string): TrackerBase {.
     deprecated: "Please use getTrackerCounter() instead".} =
  ## Get ``tracker`` from current thread dispatcher using identifier ``id``.
  getThreadDispatcher().trackers.getOrDefault(id, nil)

proc trackCounter*(name: string) {.noinit.} =
  ## Increase tracker counter with name ``name`` by 1.
  let tracker = TrackerCounter(opened: 0'u64, closed: 0'u64)
  inc(getThreadDispatcher().counters.mgetOrPut(name, tracker).opened)

proc untrackCounter*(name: string) {.noinit.} =
  ## Decrease tracker counter with name ``name`` by 1.
  let tracker = TrackerCounter(opened: 0'u64, closed: 0'u64)
  inc(getThreadDispatcher().counters.mgetOrPut(name, tracker).closed)

proc getTrackerCounter*(name: string): TrackerCounter {.noinit.} =
  ## Return value of counter with name ``name``.
  let tracker = TrackerCounter(opened: 0'u64, closed: 0'u64)
  getThreadDispatcher().counters.getOrDefault(name, tracker)

proc isCounterLeaked*(name: string): bool {.noinit.} =
  ## Returns ``true`` if leak is detected, number of `opened` not equal to
  ## number of `closed` requests.
  let tracker = TrackerCounter(opened: 0'u64, closed: 0'u64)
  let res = getThreadDispatcher().counters.getOrDefault(name, tracker)
  res.opened != res.closed

iterator trackerCounters*(
           loop: PDispatcher
         ): tuple[name: string, value: TrackerCounter] =
  ## Iterates over `loop` thread dispatcher tracker counter table, returns all
  ## the tracker counter's names and values.
  doAssert(not(isNil(loop)))
  for key, value in loop.counters.pairs():
    yield (key, value)

iterator trackerCounterKeys*(loop: PDispatcher): string =
  doAssert(not(isNil(loop)))
  ## Iterates over `loop` thread dispatcher tracker counter table, returns all
  ## tracker names.
  for key in loop.counters.keys():
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

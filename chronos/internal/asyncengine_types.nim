import std/[tables, heapqueue, deques]
import ".."/[config, futures, timer, osdefs]

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

proc raiseOsDefect*(error: OSErrorCode, msg = "") {.noreturn, noinline.} =
  # Reraise OS error code as a Defect, where it's unexpected and can't be
  # handled. We include the stack trace in the message because otherwise,
  # it's easily lost.
  raise (ref Defect)(msg: msg & "\n[" & $int(error) & "] " & osErrorMsg(error) &
                          "\n" & getStackTrace())

when defined(nimdoc):
  type
    PDispatcher* = ref object of PDispatcherBase
    AsyncFD* = distinct cint

elif defined(windows):
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

  proc initAPI(disp: PDispatcher) =
    var funcPointer: pointer = nil

    let kernel32 = getModuleHandle(newWideCString("kernel32.dll"))
    disp.getQueuedCompletionStatusEx = cast[LPFN_GETQUEUEDCOMPLETIONSTATUSEX](
      getProcAddress(kernel32, "GetQueuedCompletionStatusEx"))

    let sock = osdefs.socket(osdefs.AF_INET, 1, 6)
    if sock == osdefs.INVALID_SOCKET:
      raiseOsDefect(osLastError(), "initAPI(): Unable to create control socket")

    block:
      let res = getFunc(sock, funcPointer, WSAID_CONNECTEX)
      if not(res):
        raiseOsDefect(osLastError(), "initAPI(): Unable to initialize " &
                                     "dispatcher's ConnectEx()")
      disp.connectEx = cast[WSAPROC_CONNECTEX](funcPointer)

    block:
      let res = getFunc(sock, funcPointer, WSAID_ACCEPTEX)
      if not(res):
        raiseOsDefect(osLastError(), "initAPI(): Unable to initialize " &
                                     "dispatcher's AcceptEx()")
      disp.acceptEx = cast[WSAPROC_ACCEPTEX](funcPointer)

    block:
      let res = getFunc(sock, funcPointer, WSAID_GETACCEPTEXSOCKADDRS)
      if not(res):
        raiseOsDefect(osLastError(), "initAPI(): Unable to initialize " &
                                     "dispatcher's GetAcceptExSockAddrs()")
      disp.getAcceptExSockAddrs =
        cast[WSAPROC_GETACCEPTEXSOCKADDRS](funcPointer)

    block:
      let res = getFunc(sock, funcPointer, WSAID_TRANSMITFILE)
      if not(res):
        raiseOsDefect(osLastError(), "initAPI(): Unable to initialize " &
                                     "dispatcher's TransmitFile()")
      disp.transmitFile = cast[WSAPROC_TRANSMITFILE](funcPointer)

    block:
      let res = getFunc(sock, funcPointer, WSAID_DISCONNECTEX)
      if not(res):
        raiseOsDefect(osLastError(), "initAPI(): Unable to initialize " &
                                     "dispatcher's DisconnectEx()")
      disp.disconnectEx = cast[WSAPROC_DISCONNECTEX](funcPointer)

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

elif defined(macosx) or defined(freebsd) or defined(netbsd) or
     defined(openbsd) or defined(dragonfly) or defined(macos) or
     defined(linux) or defined(android) or defined(solaris):
  import ../selectors2
  type
    AsyncFD* = distinct cint

    SelectorData* = object
      reader*: AsyncCallback
      writer*: AsyncCallback

    PDispatcher* = ref object of PDispatcherBase
      selector*: Selector[SelectorData]
      keys*: seq[ReadyKey]

  when chronosEventEngine in ["epoll", "kqueue"]:
    type
      ProcessHandle* = distinct int
      SignalHandle* = distinct int

  proc sentinelCallbackImpl(arg: pointer) {.gcsafe, noreturn.} =
    raiseAssert "Sentinel callback MUST not be scheduled"

  const
    SentinelCallback = AsyncCallback(function: sentinelCallbackImpl,
                                    udata: nil)

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
    res

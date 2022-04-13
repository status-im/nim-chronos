#
#         Chronos' asynchronous process management
#
#  (c) Copyright 2022-Present Status Research & Development GmbH
#
#                Licensed under either of
#    Apache License, version 2.0, (LICENSE-APACHEv2)
#                MIT license (LICENSE-MIT)
import std/os
import stew/results
import ./asyncloop
export results

when defined(windows):
  import winlean

  proc postQueuedCompletionStatus(CompletionPort: Handle,
                                  dwNumberOfBytesTransferred: DWORD,
                                  dwCompletionKey: ULONG_PTR,
                                  lpOverlapped: pointer): WINBOOL {.
       stdcall, dynlib: "kernel32", importc: "PostQueuedCompletionStatus".}

  proc registerWaitForSingleObject(phNewWaitObject: ptr Handle,
                                   hObject: Handle,
                                   Callback: WAITORTIMERCALLBACK,
                                   Context: pointer,
                                   dwMilliseconds: ULONG,
                                   dwFlags: ULONG): WINBOOL {.
       stdcall, dynlib: "kernel32", importc: "RegisterWaitForSingleObject".}

  type
    PostCallbackData = object
      ioPort: Handle
      handleFd: AsyncFD
      waitFd: Handle
      ovl: RefCustomOverlapped

    WaitableHandle* = ptr PostCallbackData

  {.push stackTrace: off.}
  proc waitableCallback(param: pointer, timerOrWaitFired: WINBOOL) {.
       stdcall, gcsafe, raises: [Defect] .} =
    # This procedure will be executed in `wait thread`, so it must not use
    # GC related objects.
    # We going to ignore callbacks which was spawned when `isNil(param) == true`
    # because we unable to indicate this error.
    if isNil(param):
      return
    var wh = cast[WaitableHandle](param)
    # We ignore result of postQueueCompletionStatus() because we unable to
    # indicate error.
    discard postQueuedCompletionStatus(wh.ioPort, DWORD(timerOrWaitFired),
                                       ULONG_PTR(wh.handleFd),
                                       cast[pointer](wh.ovl))
  {.pop.}

  proc registerWaitable*(handle: Handle, flags: ULONG,
                         timeout: DWORD, cb: CallbackFunc, udata: pointer
                        ): Result[WaitableHandle, OSErrorCode] {.
       raises: [Defect].} =
    let
      loop = getThreadDispatcher()
      handleFd = AsyncFD(handle)

    var ovl = RefCustomOverlapped(
      data: CompletionData(cb: cb, cell:system.protect(rawEnv(cb)),
                           udata: udata)
    )
    GC_ref(ovl)
    var whandle = cast[WaitableHandle](allocShared0(sizeof(PostCallbackData)))
    whandle.ioPort = loop.getIoHandler()
    whandle.handleFd = AsyncFD(handle)
    whandle.ovl = ovl

    if registerWaitForSingleObject(addr whandle.waitFd, handle,
                                   cast[WAITORTIMERCALLBACK](waitableCallback),
                                   cast[pointer](whandle), DWORD(timeout),
                                   flags) == WINBOOL(0):
      system.dispose(ovl.data.cell)
      GC_unref(ovl)
      deallocShared(cast[pointer](whandle))
      return err(osLastError())

    let res = registerNe(handleFd)
    if res.isErr():
      system.dispose(ovl.data.cell)
      GC_unref(ovl)
      deallocShared(cast[pointer](whandle))
      return err(res.error())

    ok(whandle)

  proc closeWaitable*(wh: WaitableHandle): Result[void, OSErrorCode] {.
       raises: [Defect].} =
    let
      handleFd = wh.handleFd
      waitFd = wh.waitFd

    system.dispose(wh.ovl.data.cell)
    GC_unref(wh.ovl)
    deallocShared(cast[pointer](wh))
    unregister(handleFd)

    if unregisterWait(waitFd) == 0:
      let res = osLastError()
      if int32(res) != ERROR_IO_PENDING:
        discard winlean.closeHandle(Handle(handleFd))
        return err(res)
    if closeHandle(Handle(handleFd)) == 0:
      return err(osLastError())
    ok()

  proc addProcess*(pid: int, cb: CallbackFunc, udata: pointer = nil): int {.
       raises: [Defect, ValueError].} =
    let
      loop = getThreadDispatcher()
      hProcess = openProcess(SYNCHRONIZE, WINBOOL(0), DWORD(pid))
      flags = DWORD(WT_EXECUTEINWAITTHREAD) or DWORD(WT_EXECUTEONLYONCE)

    var wh: WaitableHandle = nil

    if hProcess == Handle(0):
      raise newException(ValueError, osErrorMsg(osLastError()))

    proc callable(udata: pointer) {.gcsafe.} =
      doAssert(not(isNil(udata)))
      doAssert(not(isNil(wh)))
      # We ignore result here because its not possible to indicate an error.
      let
        ovl = cast[CustomOverlapped](udata)
        udata = ovl.data.udata
      discard closeWaitable(wh)
      cb(udata)

    wh =
      block:
        let res = registerWaitable(hProcess, flags, DWORD(INFINITE),
                                   callable, udata)
        if res.isErr():
          raise newException(ValueError, osErrorMsg(res.error()))
        res.get()
    cast[int](wh)

  proc removeProcess*(procfd: int) {.raises: [Defect, ValueError].} =
    doAssert(procfd != 0)
    # WaitableHandle is allocated in shared memory, so it is not managed by GC.
    let wh = cast[WaitableHandle](procfd)
    let res = closeWaitable(wh)
    if res.isErr():
      raise newException(ValueError, osErrorMsg(res.error()))

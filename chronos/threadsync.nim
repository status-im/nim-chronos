#
#            Chronos synchronization primitives
#
#  (c) Copyright 2023-Present Status Research & Development GmbH
#
#                Licensed under either of
#    Apache License, version 2.0, (LICENSE-APACHEv2)
#                MIT license (LICENSE-MIT)

## This module implements some core async thread synchronization primitives.
import stew/results
import "."/[timer, asyncloop]

export results

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

const hasThreadSupport* = compileOption("threads")
when not(hasThreadSupport):
  {.fatal: "Compile this program with threads enabled!".}

# import std/locks
import "."/[osdefs, osutils, oserrno]

const
  TimedOutErrorMessage = "The wait operation timed out"

type
  ThreadEvent* = object
    when defined(windows):
      event: HANDLE
    elif defined(linux):
      efd: AsyncFD
    else:
      rfd, wfd: AsyncFD

  ThreadEventPtr* = ptr ThreadEvent

proc new*(t: typedesc[ThreadEventPtr]): Result[ThreadEventPtr, string] =
  ## Create new ThreadEvent object.
  let res = cast[ptr ThreadEvent](allocShared0(sizeof(ThreadEvent)))
  when defined(windows):
    var sa = getSecurityAttributes()
    let event = osdefs.createEvent(addr sa, DWORD(0), DWORD(0), nil)
    if event == HANDLE(0):
      deallocShared(res)
      return err(osErrorMsg(osLastError()))
    res[] = ThreadEvent(event: event)
  elif defined(linux):
    let efd = eventfd(0, EFD_CLOEXEC or EFD_NONBLOCK)
    if efd == -1:
      deallocShared(res)
      return err(osErrorMsg(osLastError()))
    res[] = ThreadEvent(efd: efd)
  else:
    let
      flags = {DescriptorFlag.CloseOnExec, DescriptorFlag.NonBlock}
      pipes = createOsPipe(flags, flags).valueOr:
        deallocShared(res)
        return err(osErrorMsg(osLastError()))
    res[] = ThreadEvent(rfd: pipes.read, wfd: pipes.write)
  ok(ThreadEventPtr(res))

proc close*(event: ThreadEventPtr): Result[void, string] =
  ## Close AsyncThreadEvent ``event`` and free all the resources.
  when defined(windows):
    if closeHandle(event[].event) == 0'u32:
      deallocShared(event)
      return err(osErrorMsg(osLastError()))
  elif defined(linux):
    let res = unregisterAndCloseFd(event[].efd)
    if res.isErr():
      deallocShared(event)
      return err(osErrorMsg(res.error))
  else:
    let res1 = unregisterAndCloseFd(event[].rfd)
    let res2 = unregisterAndCloseFd(event[].wfd)
    if res1.isErr():
      deallocShared(event)
      return err(osErrorMsg(res1.error))
    if res2.isErr():
      deallocShared(event)
      return err(osErrorMsg(res2.error))
  deallocShared(event)
  ok()

when not(defined(windows)):
  type
    WaitKind* {.pure.} = enum
      Read, Write

  func toTimeval(a: Duration): Timeval =
    ## Convert Duration ``a`` to ``Timeval`` object.
    let nanos = a.nanoseconds
    let m = nanos mod Second.nanoseconds()
    Timeval(
      tv_sec: Time(nanos div Second.nanoseconds()),
      tv_usec: Suseconds(m div Microsecond.nanoseconds())
    )

  proc waitReady(fd: cint, kind: WaitKind,
                 timeout: Duration): Result[bool, OSErrorCode] =
    var
      tv: Timeval
      fdset =
        block:
          var res: TFdSet
          FD_ZERO(res)
          FD_SET(SocketHandle(fd), res)
          res

    let
      ptv =
        if not(timeout.isInfinite()):
          tv = timeout.toTimeval()
          addr tv
        else:
          nil
      nfd = cint(fd) + 1
      res =
        case kind
        of WaitKind.Read:
          handleEintr(select(nfd, addr fdset, nil, nil, ptv))
        of WaitKind.Write:
          handleEintr(select(nfd, nil, addr fdset, nil, ptv))

    if res > 0:
      ok(true)
    elif res == 0:
      ok(false)
    else:
      err(osLastError())

proc fireSync*(event: ThreadEventPtr,
               timeout = InfiniteDuration): Result[void, string] =
  ## Set state of ThreadEventPtr ``event`` to signaled in blocking way.
  when defined(windows):
    if setEvent(event.event) == 0'u32:
      return err(osErrorMsg(osLastError()))
    ok()
  else:
    let eventFd =
      when defined(linux):
        cint(event[].efd)
      else:
        cint(event[].wfd)

    var data = 1'u64
    while true:
      let res = handleEintr(write(eventFd, addr data, sizeof(uint64)))
      if res < 0:
        let errorCode = osLastError()
        case errorCode
        of EAGAIN:
          let wres = waitReady(eventFd, WaitKind.Write, timeout)
          if wres.isErr():
            return err(osErrorMsg(wres.error))
          if not(wres.get()):
            return err(osErrorMsg(ETIMEDOUT))
        else:
          return err(osErrorMsg(errorCode))
      elif res != sizeof(data):
        return err(osErrorMsg(EINVAL))
      else:
        return ok()

proc waitSync*(event: ThreadEventPtr,
               timeout = InfiniteDuration): Result[void, string] =
  ## Wait until the ThreadEventPtr ``event`` become signaled. This procedure is
  ## ``NOT`` async, so it blocks execution flow, but this procedure do not
  ## need asynchronous event loop to be present.
  when defined(windows):
    let
      timeoutWin =
        if timeout.isInfinite():
          INFINITE
        else:
          DWORD(timeout.milliseconds())
      handle = event.event
      res = waitForSingleObject(handle, timeoutWin)
    if res == WAIT_OBJECT_0:
      ok()
    elif res == WAIT_TIMEOUT:
      err(TimedOutErrorMessage)
    elif res == WAIT_ABANDONED:
      err("The wait operation has been abandoned")
    else:
      err("The wait operation has been failed")
  else:
    var
      data = 0'u64
    let eventFd =
      when defined(linux):
        cint(event[].efd)
      else:
        cint(event[].rfd)
    let wres = waitReady(eventFd, WaitKind.Read, timeout).valueOr:
      return err(osErrorMsg(error))
    if not(wres):
      return err(TimedOutErrorMessage)
    let res = handleEintr(read(eventFd, addr data, sizeof(uint64)))
    if res < 0:
      let errorCode = osLastError()
      err(osErrorMsg(errorCode))
    elif res != sizeof(data):
      err(osErrorMsg(EINVAL))
    else:
      ok()

proc fire*(event: ThreadEventPtr): Future[void] =
  ## Set state of ThreadEventPtr ``event`` to signaled in asynchronous way.
  var retFuture = newFuture[void]("asyncthreadevent.fire")
  when defined(windows):
    if setEvent(event.event) == 0'u32:
      retFuture.fail(newException(AsyncError, osErrorMsg(osLastError())))
    else:
      retFuture.complete()
  else:
    var data = 1'u64
    let eventFd =
      when defined(linux):
        cint(event[].efd)
      else:
        cint(event[].wfd)

    proc continuation(udata: pointer) {.gcsafe, raises: [].} =
      if not(retFuture.finished()):
        let res = handleEintr(write(eventFd, addr data, sizeof(uint64)))
        if res < 0:
          let errorCode = osLastError()
          discard removeWriter2(AsyncFD(eventFd))
          retFuture.fail(newException(AsyncError, osErrorMsg(errorCode)))
        elif res != sizeof(data):
          discard removeWriter2(AsyncFD(eventFd))
          retFuture.fail(newException(AsyncError, osErrorMsg(EINVAL)))
        else:
          let eres = removeWriter2(AsyncFD(eventFd))
          if eres.isErr():
            retFuture.fail(newException(AsyncError, osErrorMsg(eres.error)))
          else:
            retFuture.complete()

    proc cancellation(udata: pointer) {.gcsafe, raises: [].} =
      if not(retFuture.finished()):
        discard removeWriter2(AsyncFD(eventFd))

    let res = handleEintr(write(eventFd, addr data, sizeof(uint64)))
    if res < 0:
      let errorCode = osLastError()
      case errorCode
      of EAGAIN:
        let wres = addWriter2(AsyncFD(eventFd), continuation)
        if wres.isErr():
          retFuture.fail(newException(AsyncError,
                                      osErrorMsg(wres.error)))
        else:
          retFuture.cancelCallback = cancellation
      else:
        retFuture.fail(newException(AsyncError,
                                    osErrorMsg(osLastError())))
    elif res != sizeof(data):
      retFuture.fail(newException(AsyncError, osErrorMsg(EINVAL)))
    else:
      retFuture.complete()

  retFuture

when defined(windows):
  proc wait*(event: ThreadEventPtr) {.async.} =
    let handle = event[].event
    let res = await waitForSingleObject(handle, InfiniteDuration)
    # There should be no other response, because we use `InfiniteDuration`.
    doAssert(res == WaitableResult.Ok)
else:
  proc wait*(event: ThreadEventPtr): Future[void] =
    var retFuture = newFuture[void]("asyncthreadevent.wait")
    var data = 1'u64
    let eventFd =
      when defined(linux):
        cint(event[].efd)
      else:
        cint(event[].rfd)

    proc continuation(udata: pointer) {.gcsafe, raises: [].} =
      if not(retFuture.finished()):
        let res = handleEintr(read(eventFd, addr data, sizeof(uint64)))
        if res < 0:
          let errorCode = osLastError()
          discard removeReader2(AsyncFD(eventFd))
          retFuture.fail(newException(AsyncError, osErrorMsg(errorCode)))
        elif res != sizeof(data):
          discard removeReader2(AsyncFD(eventFd))
          retFuture.fail(newException(AsyncError, osErrorMsg(EINVAL)))
        else:
          let eres = removeReader2(AsyncFD(eventFd))
          if eres.isErr():
            retFuture.fail(newException(AsyncError, osErrorMsg(eres.error)))
          else:
            retFuture.complete()

    proc cancellation(udata: pointer) {.gcsafe, raises: [].} =
      if not(retFuture.finished()):
        discard removeReader2(AsyncFD(eventFd))

    let rres = addReader2(AsyncFD(eventFd), continuation)
    if rres.isErr():
      retFuture.fail(newException(AsyncError,
                                  osErrorMsg(rres.error)))
    else:
      retFuture.cancelCallback = cancellation

    retFuture

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

import "."/[osdefs, osutils, oserrno]

type
  ThreadSignal* = object
    when defined(windows):
      event: HANDLE
    elif defined(linux):
      efd: AsyncFD
    else:
      rfd, wfd: AsyncFD

  ThreadSignalPtr* = ptr ThreadSignal

proc new*(t: typedesc[ThreadSignalPtr]): Result[ThreadSignalPtr, string] =
  ## Create new ThreadSignal object.
  let res = cast[ptr ThreadSignal](allocShared0(sizeof(ThreadSignal)))
  when defined(windows):
    var sa = getSecurityAttributes()
    let event = osdefs.createEvent(addr sa, DWORD(0), DWORD(0), nil)
    if event == HANDLE(0):
      deallocShared(res)
      return err(osErrorMsg(osLastError()))
    res[] = ThreadSignal(event: event)
  elif defined(linux):
    let efd = eventfd(0, EFD_CLOEXEC or EFD_NONBLOCK)
    if efd == -1:
      deallocShared(res)
      return err(osErrorMsg(osLastError()))
    res[] = ThreadSignal(efd: AsyncFD(efd))
  else:
    let
      flags = {DescriptorFlag.CloseOnExec, DescriptorFlag.NonBlock}
      pipes = createOsPipe(flags, flags).valueOr:
        deallocShared(res)
        return err(osErrorMsg(osLastError()))
    res[] = ThreadSignal(rfd: AsyncFD(pipes.read), wfd: AsyncFD(pipes.write))
  ok(ThreadSignalPtr(res))

when not(defined(windows)):
  type
    WaitKind {.pure.} = enum
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

  proc safeUnregisterAndCloseFd(fd: AsyncFD): Result[void, OSErrorCode] =
    let loop = getThreadDispatcher()
    if loop.contains(fd):
      ? unregister2(fd)
    if closeFd(cint(fd)) != 0:
      err(osLastError())
    else:
      ok()

proc close*(signal: ThreadSignalPtr): Result[void, string] =
  ## Close ThreadSignal object and free all the resources.
  defer: deallocShared(signal)
  when defined(windows):
    # We do not need to perform unregistering on Windows, we can only close it.
    if closeHandle(signal[].event) == 0'u32:
      return err(osErrorMsg(osLastError()))
  elif defined(linux):
    let res = safeUnregisterAndCloseFd(signal[].efd)
    if res.isErr():
      return err(osErrorMsg(res.error))
  else:
    let res1 = safeUnregisterAndCloseFd(signal[].rfd)
    let res2 = safeUnregisterAndCloseFd(signal[].wfd)
    if res1.isErr(): return err(osErrorMsg(res1.error))
    if res2.isErr(): return err(osErrorMsg(res2.error))
  ok()

proc fireSync*(signal: ThreadSignalPtr,
               timeout = InfiniteDuration): Result[bool, string] =
  ## Set state of ``signal`` to signaled state in blocking way.
  ##
  ## Returns ``false`` if signal was not signalled in time, and ``true``
  ## if operation was successful.
  when defined(windows):
    if setEvent(signal[].event) == 0'u32:
      return err(osErrorMsg(osLastError()))
    ok(true)
  else:
    let eventFd =
      when defined(linux):
        cint(signal[].efd)
      else:
        cint(signal[].wfd)

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
            return ok(false)
        else:
          return err(osErrorMsg(errorCode))
      elif res != sizeof(data):
        return err(osErrorMsg(EINVAL))
      else:
        return ok(true)

proc waitSync*(signal: ThreadSignalPtr,
               timeout = InfiniteDuration): Result[bool, string] =
  ## Wait until the signal become signaled. This procedure is ``NOT`` async,
  ## so it blocks execution flow, but this procedure do not need asynchronous
  ## event loop to be present.
  when defined(windows):
    let
      timeoutWin =
        if timeout.isInfinite():
          INFINITE
        else:
          DWORD(timeout.milliseconds())
      handle = signal[].event
      res = waitForSingleObject(handle, timeoutWin)
    if res == WAIT_OBJECT_0:
      ok(true)
    elif res == WAIT_TIMEOUT:
      ok(false)
    elif res == WAIT_ABANDONED:
      err("The wait operation has been abandoned")
    else:
      err("The wait operation has been failed")
  else:
    let eventFd =
      when defined(linux):
        cint(signal[].efd)
      else:
        cint(signal[].rfd)
    var
      data = 0'u64
      timer = timeout
    while true:
      let wres =
        block:
          let
            start = Moment.now()
            res = waitReady(eventFd, WaitKind.Read, timer)
          timer = timer - (Moment.now() - start)
          res
      if wres.isErr():
        return err(osErrorMsg(wres.error))
      if not(wres.get()):
        return ok(false)
      let res = handleEintr(read(eventFd, addr data, sizeof(uint64)))
      if res < 0:
        let errorCode = osLastError()
        # If errorCode == EAGAIN it means that reading operation is already
        # pending and so some other consumer reading eventfd or pipe end, in
        # this case we going to ignore error and wait for another event.
        if errorCode != EAGAIN:
          return err(osErrorMsg(errorCode))
      elif res != sizeof(data):
        return err(osErrorMsg(EINVAL))
      else:
        return ok(true)

proc fire*(signal: ThreadSignalPtr): Future[void] =
  ## Set state of ``signal`` to signaled in asynchronous way.
  var retFuture = newFuture[void]("asyncthreadsignal.fire")
  when defined(windows):
    if setEvent(signal[].event) == 0'u32:
      retFuture.fail(newException(AsyncError, osErrorMsg(osLastError())))
    else:
      retFuture.complete()
  else:
    var data = 1'u64
    let eventFd =
      when defined(linux):
        cint(signal[].efd)
      else:
        cint(signal[].wfd)

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
        let loop = getThreadDispatcher()
        if not(loop.contains(AsyncFD(eventFd))):
          let rres = register2(AsyncFD(eventFd))
          if rres.isErr():
            retFuture.fail(newException(AsyncError, osErrorMsg(rres.error)))
            return retFuture
        let wres = addWriter2(AsyncFD(eventFd), continuation)
        if wres.isErr():
          retFuture.fail(newException(AsyncError, osErrorMsg(wres.error)))
        else:
          retFuture.cancelCallback = cancellation
      else:
        retFuture.fail(newException(AsyncError, osErrorMsg(errorCode)))
    elif res != sizeof(data):
      retFuture.fail(newException(AsyncError, osErrorMsg(EINVAL)))
    else:
      retFuture.complete()

  retFuture

when defined(windows):
  proc wait*(signal: ThreadSignalPtr) {.async.} =
    let handle = signal[].event
    let res = await waitForSingleObject(handle, InfiniteDuration)
    # There should be no other response, because we use `InfiniteDuration`.
    doAssert(res == WaitableResult.Ok)
else:
  proc wait*(signal: ThreadSignalPtr): Future[void] =
    var retFuture = newFuture[void]("asyncthreadsignal.wait")
    var data = 1'u64
    let eventFd =
      when defined(linux):
        cint(signal[].efd)
      else:
        cint(signal[].rfd)

    proc continuation(udata: pointer) {.gcsafe, raises: [].} =
      if not(retFuture.finished()):
        let res = handleEintr(read(eventFd, addr data, sizeof(uint64)))
        if res < 0:
          let errorCode = osLastError()
          # If errorCode == EAGAIN it means that reading operation is already
          # pending and so some other consumer reading eventfd or pipe end, in
          # this case we going to ignore error and wait for another event.
          if errorCode != EAGAIN:
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
        # Future is already cancelled so we ignore errors.
        discard removeReader2(AsyncFD(eventFd))

    let loop = getThreadDispatcher()
    if not(loop.contains(AsyncFD(eventFd))):
      let res = register2(AsyncFD(eventFd))
      if res.isErr():
        retFuture.fail(newException(AsyncError, osErrorMsg(res.error)))
        return retFuture
    let res = addReader2(AsyncFD(eventFd), continuation)
    if res.isErr():
      retFuture.fail(newException(AsyncError, osErrorMsg(res.error)))
      return retFuture
    retFuture.cancelCallback = cancellation
    retFuture

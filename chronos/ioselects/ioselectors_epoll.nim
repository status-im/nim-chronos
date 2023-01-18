#
#
#            Nim's Runtime Library
#        (c) Copyright 2016 Eugene Kabanov
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

# This module implements Linux epoll().
import std/[deques, tables]
import stew/base10

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

type
  SelectorImpl[T] = object
    epollFd: cint
    sigFd: Opt[cint]
    pidFd: Opt[cint]
    fds: Table[uint32, SelectorKey[T]]
    signals: Table[uint32, SelectorKey[T]]
    processes: Table[uint32, SelectorKey[T]]
    signalMask: Sigset
    virtualHoles: Deque[uint32]
    virtualId: uint32
    childrenExited: bool
    pendingEvents: Deque[ReadyKey]
    count: int

  Selector*[T] = ref SelectorImpl[T]

  SelectEventImpl = object
    efd: cint

  SelectEvent* = ptr SelectEventImpl

proc getVirtualId[T](s: Selector[T]): SelectResult[uint32] =
  if len(s.virtualHoles) > 0:
    ok(s.virtualHoles.popLast())
  else:
    let newId = s.virtualId + 1'u32
    if newId < s.virtualId:
      err(OSErrorCode(EMFILE))
    else:
      s.virtualId = newId
      ok(s.virtualId)

proc isVirtualId(ident: uint32): bool =
  if ident <= uint32(high(cint)):
    false
  else:
    true

proc toInt(data: uint32): int =
  int(cast[int32](data))

proc toString(key: uint32): string =
  if isVirtualId(key):
    "V" & Base10.toString(key - uint32(high(cint)))
  else:
    Base10.toString(key)

template addKey[T](s: Selector[T], key: cint|uint32, skey: SelectorKey[T]) =
  let fdu32 = when key is uint32: key else: uint32(key)
  if s.fds.hasKeyOrPut(fdu32, skey):
    raiseAssert "Descriptor [" & fdu32.toString() &
                "] is already registered in the selector!"

template getKey[T](s: Selector[T], key: uint32): SelectorKey[T] =
  let
    defaultKey = SelectorKey[T](ident: InvalidIdent)
    pkey = s.fds.getOrDefault(key, defaultKey)
  doAssert(pkey.ident != InvalidIdent, "Descriptor [" & key.toString() &
                                       "] is not registered in the selector!")
  pkey

proc addSignal[T](s: Selector[T], signal: int, skey: SelectorKey[T]) =
  let fdu32 = uint32(signal)
  if s.signals.hasKeyOrPut(fdu32, skey):
    raiseAssert "Signal [" & Base10.toString(fdu32) & "] is already " &
                "registered in the selector"

template addProcess[T](s: Selector[T], pid: int, skey: SelectorKey[T]) =
  let fdu32 = uint32(pid)
  if s.processes.hasKeyOrPut(fdu32, skey):
    raiseAssert "Process [" & Base10.toString(fdu32) & "] is already " &
                "registered in the selector"

proc freeKey[T](s: Selector[T], ident: uint32) =
  s.fds.del(ident)
  if isVirtualId(ident):
    s.virtualHoles.addFirst(ident)

proc freeSignal[T](s: Selector[T], ident: int) =
  s.signals.del(uint32(ident))

proc freeProcess[T](s: Selector[T], ident: int) =
  s.processes.del(uint32(ident))

proc new*(t: typedesc[Selector], T: typedesc): SelectResult[Selector[T]] =
  var nmask: Sigset
  if sigemptyset(nmask) < 0:
    return err(osLastError())
  let epollFd = epoll_create(asyncEventsCount)
  if epollFd < 0:
    return err(osLastError())
  let selector = Selector[T](
    epollFd: epollFd,
    fds: initTable[uint32, SelectorKey[T]](asyncInitialSize),
    signals: initTable[uint32, SelectorKey[T]](16),
    processes: initTable[uint32, SelectorKey[T]](16),
    signalMask: nmask,
    virtualId: uint32(high(int32)),
    childrenExited: false,
    virtualHoles: initDeque[uint32](),
    pendingEvents: initDeque[ReadyKey]()
  )
  ok(selector)

proc close2*[T](s: Selector[T]): SelectResult[void] =
  s.fds.clear()
  s.signals.clear()
  s.processes.clear()
  if handleEintr(osdefs.close(s.epollFd)) != 0:
    err(osLastError())
  else:
    ok()

proc new*(t: typedesc[SelectEvent]): SelectResult[SelectEvent] =
  let eFd = eventfd(0, EFD_CLOEXEC or EFD_NONBLOCK)
  if eFd == -1:
    return err(osLastError())
  var res = cast[SelectEvent](allocShared0(sizeof(SelectEventImpl)))
  res.efd = eFd
  ok(res)

proc trigger2*(event: SelectEvent): SelectResult[void] =
  var data: uint64 = 1
  let res = handleEintr(osdefs.write(event.efd, addr data, sizeof(uint64)))
  if res == -1:
    err(osLastError())
  elif res != sizeof(uint64):
    err(OSErrorCode(osdefs.EINVAL))
  else:
    ok()

proc close2*(event: SelectEvent): SelectResult[void] =
  let evFd = event.efd
  deallocShared(cast[pointer](event))
  let res = handleEintr(osdefs.close(evFd))
  if res == -1:
    err(osLastError())
  else:
    ok()

proc init(t: typedesc[EpollEvent], fdi: int, events: set[Event]): EpollEvent =
  var res = uint32(EPOLLRDHUP)
  if Event.Read in events: res = res or uint32(EPOLLIN)
  if Event.Write in events: res = res or uint32(EPOLLOUT)
  EpollEvent(events: res, data: EpollData(u64: uint64(fdi)))

proc registerHandle2*[T](s: Selector[T], fd: cint, events: set[Event],
                         data: T): SelectResult[void] =
  let
    fdu32 = uint32(fd)
    skey = SelectorKey[T](ident: fd, events: events, param: 0, data: data)

  s.addKey(fd, skey)

  if events != {}:
    let epollEvents = EpollEvent.init(fd, events)
    if epoll_ctl(s.epollFd, EPOLL_CTL_ADD, fd, unsafeAddr(epollEvents)) != 0:
      s.freeKey(fdu32)
      return err(osLastError())
    inc(s.count)
  ok()

proc updateHandle2*[T](s: Selector[T], fd: cint,
                       events: set[Event]): SelectResult[void] =
  const EventsMask = {Event.Timer, Event.Signal, Event.Process, Event.Vnode,
                      Event.User, Event.Oneshot, Event.Error}
  let fdu32 = uint32(fd)
  s.fds.withValue(fdu32, pkey):
    doAssert(pkey[].events * EventsMask == {},
             "Descriptor [" & fdu32.toString() & "] could not be updated!")
    if pkey[].events != events:
      let epollEvents = EpollEvent.init(fd, events)
      if pkey[].events == {}:
        if epoll_ctl(s.epollFd, EPOLL_CTL_ADD, fd,
                     unsafeAddr(epollEvents)) != 0:
          return err(osLastError())
        inc(s.count)
      else:
        if events != {}:
          if epoll_ctl(s.epollFd, EPOLL_CTL_MOD, fd,
                       unsafeAddr(epollEvents)) != 0:
            return err(osLastError())
        else:
          if epoll_ctl(s.epollFd, EPOLL_CTL_DEL, fd,
                       unsafeAddr epollEvents) != 0:
            return err(osLastError())
          dec(s.count)
      pkey.events = events
  do:
    raiseAssert "Descriptor [" & fdu32.toString() &
                "] is not registered in the selector!"
  ok()

proc blockSignal[T](s: Selector[T], signal: int): SelectResult[bool] =
  let isMember = sigismember(s.signalMask, cint(signal))
  if isMember < 0:
    err(osLastError())
  elif isMember > 0:
    ok(false)
  else:
    var omask, nmask: Sigset
    if sigemptyset(nmask) < 0:
      return err(osLastError())
    if sigemptyset(omask) < 0:
      return err(osLastError())
    if sigaddset(nmask, cint(signal)) < 0:
      return err(osLastError())
    ? blockSignals(nmask, omask)
    if sigaddset(s.signalMask, cint(signal)) < 0:
      # Try to restore previous state of signals mask
      let errorCode = osLastError()
      discard unblockSignals(nmask, omask)
      return err(errorCode)
    ok(true)

proc unblockSignal[T](s: Selector[T], signal: int): SelectResult[bool] =
  let isMember = sigismember(s.signalMask, cint(signal))
  if isMember < 0:
    err(osLastError())
  elif isMember == 0:
    ok(false)
  else:
    var omask, nmask: Sigset
    if sigemptyset(nmask) < 0:
      return err(osLastError())
    if sigemptyset(omask) < 0:
      return err(osLastError())
    if sigaddset(nmask, cint(signal)) < 0:
      return err(osLastError())
    ? unblockSignals(nmask, omask)
    if sigdelset(s.signalMask, cint(signal)) < 0:
      # Try to restore previous state of signals mask
      let errorCode = osLastError()
      discard blockSignals(nmask, omask)
      return err(errorCode)
    ok(true)

proc registerSignalEvent[T](s: Selector[T], signal: int,
                            events: set[Event], param: int,
                            data: T): SelectResult[int] =
  let
    fdu32 = ? s.getVirtualId()
    selectorKey = SelectorKey[T](ident: signal, events: events,
                                param: param, data: data)
    signalKey = SelectorKey[T](ident: toInt(fdu32), events: events,
                               param: param, data: data)

  s.addKey(fdu32, selectorKey)
  s.addSignal(signal, signalKey)

  let mres =
    block:
      let res = s.blockSignal(signal)
      if res.isErr():
        s.freeKey(fdu32)
        s.freeSignal(signal)
        return err(res.error())
      res.get()

  if not(mres):
    raiseAssert "Signal [" & $signal & "] could have only one handler at " &
                "the same time!"

  if s.sigFd.isSome():
    let res = signalfd(s.sigFd.get(), s.signalMask,
                       SFD_NONBLOCK or SFD_CLOEXEC)
    if res == -1:
      let errorCode = osLastError()
      s.freeKey(fdu32)
      s.freeSignal(signal)
      discard s.unblockSignal(signal)
      return err(errorCode)
  else:
    let sigFd = signalfd(-1, s.signalMask, SFD_NONBLOCK or SFD_CLOEXEC)
    if sigFd == -1:
      let errorCode = osLastError()
      s.freeKey(fdu32)
      s.freeSignal(signal)
      discard s.unblockSignal(signal)
      return err(errorCode)

    let fdKey = SelectorKey[T](ident: sigFd, events: {Event.Signal})
    s.addKey(uint32(sigFd), fdKey)

    let event = EpollEvent(events: EPOLLIN or EPOLLRDHUP,
                           data: EpollData(u64: uint64(sigFd)))
    if epoll_ctl(s.epollFd, EPOLL_CTL_ADD, sigFd, unsafeAddr(event)) != 0:
      let errorCode = osLastError()
      s.freeKey(fdu32)
      s.freeSignal(signal)
      s.freeKey(uint32(sigFd))
      discard s.unblockSignal(signal)
      discard handleEintr(osdefs.close(sigFd))
      return err(errorCode)

    s.sigFd = Opt.some(sigFd)
    inc(s.count)

  inc(s.count)
  ok(toInt(fdu32))

proc registerSignal*[T](s: Selector[T], signal: int,
                       data: T): SelectResult[int] =
  registerSignalEvent(s, signal, {Event.Signal}, 0, data)

proc registerTimer2*[T](s: Selector[T], timeout: int, oneshot: bool,
                        data: T): SelectResult[int] =
  let timerFd = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC or TFD_NONBLOCK)
  if timerFd == -1:
    return err(osLastError())

  let
    fdu32 = uint32(timerFd)
    (key, event) =
      if oneshot:
        (
          SelectorKey[T](ident: timerFd, events: {Event.Timer, Event.Oneshot},
                         param: 0, data: data),
          EpollEvent(events: EPOLLIN or EPOLLRDHUP or EPOLLONESHOT,
                     data: EpollData(u64: uint64(timerFd)))
        )
      else:
        (
          SelectorKey[T](ident: timerFd, events: {Event.Timer},
                         param: 0, data: data),
          EpollEvent(events: EPOLLIN or EPOLLRDHUP,
                     data: EpollData(u64: uint64(timerFd)))
        )
  var timeStruct =
    if oneshot:
      Itimerspec(
        it_interval: Timespec(tv_sec: osdefs.Time(0), tv_nsec: 0),
        it_value: Timespec(tv_sec: osdefs.Time(timeout div 1_000),
                           tv_nsec: (timeout %% 1000) * 1_000_000)
      )
    else:
      Itimerspec(
        it_interval: Timespec(tv_sec: osdefs.Time(timeout div 1_000),
                              tv_nsec: 0),
        it_value: Timespec(tv_sec: osdefs.Time(timeout div 1_000),
                           tv_nsec: 0),
      )

  s.addKey(fdu32, key)

  var oldTs = Itimerspec()
  if timerfd_settime(timerFd, cint(0), timeStruct, oldTs) != 0:
    let errorCode = osLastError()
    s.freeKey(fdu32)
    discard handleEintr(osdefs.close(timerFd))
    return err(errorCode)

  if epoll_ctl(s.epollFd, EPOLL_CTL_ADD, timerFd, unsafeAddr(event)) != 0:
    let errorCode = osLastError()
    s.freeKey(fdu32)
    discard handleEintr(osdefs.close(timerFd))
    return err(errorCode)

  inc(s.count)
  ok(toInt(fdu32))

proc registerEvent2*[T](s: Selector[T], ev: SelectEvent,
                        data: T): SelectResult[int] =
  let
    fdu32 = uint32(ev.efd)
    key = SelectorKey[T](ident: ev.efd, events: {Event.User},
                         param: 0, data: data)
    event = EpollEvent(events: EPOLLIN or EPOLLRDHUP,
                       data: EpollData(u64: uint64(fdu32)))

  s.addKey(fdu32, key)

  if epoll_ctl(s.epollFd, EPOLL_CTL_ADD, ev.efd, unsafeAddr(event)) != 0:
    let errorCode = osLastError()
    s.fds.del(fdu32)
    return err(errorCode)

  inc(s.count)
  ok(toInt(fdu32))

template checkPid(pid: int) =
  when sizeof(int) == 8:
    doAssert(pid >= 0 and pid <= int(high(uint32)))
  else:
    doAssert(pid >= 0 and pid <= high(int32))

proc registerProcess*[T](s: Selector, pid: int, data: T): SelectResult[int] =
  checkPid(pid)

  let
    fdu32 = ? s.getVirtualId()
    events = {Event.Process, Event.Oneshot}
    selectorKey = SelectorKey[T](ident: pid, events: events, param: 0,
                                 data: data)
    processKey = SelectorKey[T](ident: toInt(fdu32), events: events, param: 0,
                                data: data)

  s.addProcess(pid, processKey)
  s.addKey(fdu32, selectorKey)

  if s.pidFd.isNone():
    let res = registerSignalEvent(s, int(SIGCHLD), {Event.Signal}, 0, data)
    if res.isErr():
      s.freeKey(fdu32)
      s.freeProcess(pid)
      return err(res.error())
    s.pidFd = Opt.some(cast[cint](res.get()))

  ok(toInt(fdu32))

proc unregister2*[T](s: Selector[T], fd: cint): SelectResult[void] =
  let
    fdu32 = uint32(fd)
    pkey = s.getKey(fdu32)

  if pkey.events != {}:
    if {Event.Read, Event.Write, Event.User} * pkey.events != {}:
      if epoll_ctl(s.epollFd, EPOLL_CTL_DEL, cint(pkey.ident), nil) != 0:
        return err(osLastError())
      dec(s.count)

    elif Event.Timer in pkey.events:
      if Event.Finished notin pkey.events:
        if epoll_ctl(s.epollFd, EPOLL_CTL_DEL, fd, nil) != 0:
          let errorCode = osLastError()
          discard handleEintr(osdefs.close(fd))
          return err(errorCode)
        dec(s.count)
      if handleEintr(osdefs.close(fd)) == -1:
        return err(osLastError())

    elif Event.Signal in pkey.events:
      if not(s.signals.hasKey(uint32(pkey.ident))):
        raiseAssert "Signal " & $pkey.ident & " is not registered in the " &
                    "selector!"
      let sigFd =
        block:
          doAssert(s.sigFd.isSome(), "signalfd descriptor is missing")
          s.sigFd.get()

      s.freeSignal(pkey.ident)

      if len(s.signals) > 0:
        let res = signalfd(sigFd, s.signalMask, SFD_NONBLOCK or SFD_CLOEXEC)
        if res == -1:
          let errorCode = osLastError()
          discard s.unblockSignal(pkey.ident)
          return err(errorCode)
      else:
        s.freeKey(uint32(sigFd))
        s.sigFd = Opt.none(cint)

        if epoll_ctl(s.epollFd, EPOLL_CTL_DEL, sigFd, nil) != 0:
          let errorCode = osLastError()
          discard handleEintr(osdefs.close(sigFd))
          discard s.unblockSignal(pkey.ident)
          return err(errorCode)

        dec(s.count)

        if handleEintr(osdefs.close(sigFd)) != 0:
          let errorCode = osLastError()
          discard s.unblockSignal(pkey.ident)
          return err(errorCode)

      let mres = ? s.unblockSignal(pkey.ident)
      doAssert(mres, "Signal is not present in stored mask!")
      dec(s.count)

    elif Event.Process in pkey.events:
      if not(s.processes.hasKey(uint32(pkey.ident))):
        raiseAssert "Process " & $pkey.ident & " is not registered in the " &
                    "selector!"

      let pidFd =
        block:
          doAssert(s.pidFd.isSome(), "process descriptor is missing")
          s.pidFd.get()

      s.freeProcess(pkey.ident)

      # We need to filter pending events queue for just unregistered process.
      if len(s.pendingEvents) > 0:
        s.pendingEvents =
          block:
            var res = initDeque[ReadyKey](len(s.pendingEvents))
            for item in s.pendingEvents.items():
              if uint32(item.fd) != fdu32:
                res.addLast(item)
            res

      if len(s.processes) == 0:
        s.pidFd = Opt.none(cint)
        let res = s.unregister2(pidFd)
        if res.isErr():
          return err(res.error())
      dec(s.count)

  s.freeKey(fdu32)
  ok()

proc prepareKey[T](s: Selector[T], event: EpollEvent): Opt[ReadyKey] =
  let
    defaultKey = SelectorKey[T](ident: InvalidIdent)
    fdi =
      block:
        doAssert(event.data.u64 <= uint64(high(cint)),
                 "Invalid user data value in epoll event object")
        cint(event.data.u64)
    fdu32 = uint32(fdi)

  var
    pkey = s.getKey(fdu32)
    rkey = ReadyKey(fd: int(fdi))

  if (event.events and EPOLLERR) != 0:
    rkey.events.incl(Event.Error)
    rkey.errorCode = OSErrorCode(ECONNRESET)

  if (event.events and EPOLLHUP) != 0 or (event.events and EPOLLRDHUP) != 0:
    rkey.events.incl(Event.Error)
    rkey.errorCode = OSErrorCode(ECONNRESET)

  if (event.events and EPOLLOUT) != 0:
    rkey.events.incl(Event.Write)

  if (event.events and EPOLLIN) != 0:
    if Event.Read in pkey.events:
      rkey.events.incl(Event.Read)

    elif Event.Timer in pkey.events:
      var data: uint64
      rkey.events.incl(Event.Timer)
      let res = handleEintr(osdefs.read(fdi, addr data, sizeof(uint64)))
      if res != sizeof(uint64):
        rkey.events.incl(Event.Error)
        rkey.errorCode = osLastError()

    elif Event.Signal in pkey.events:
      var data: SignalFdInfo
      let res = handleEintr(osdefs.read(fdi, addr data, sizeof(SignalFdInfo)))
      if res != sizeof(SignalFdInfo):
        # We could not obtain `signal` number so we can't report an error to
        # proper handler.
        return Opt.none(ReadyKey)
      if data.ssi_signo != uint32(SIGCHLD) or len(s.processes) == 0:
        let skey = s.signals.getOrDefault(data.ssi_signo, defaultKey)
        if skey.ident == InvalidIdent:
          # We do not have any handlers for received event so we can't report
          # an error to proper handler.
          return Opt.none(ReadyKey)
        rkey.events.incl(Event.Signal)
        rkey.fd = skey.ident
      else:
        # Indicate that SIGCHLD has been seen.
        s.childrenExited = true
        # Current signal processing.
        let pidKey = s.processes.getOrDefault(data.ssi_pid, defaultKey)
        if pidKey.ident == InvalidIdent:
          # We do not have any handlers with signal's pid.
          return Opt.none(ReadyKey)
        rkey.events.incl({Event.Process, Event.Oneshot, Event.Finished})
        rkey.fd = pidKey.ident
        # Mark process descriptor inside fds table as finished.
        var fdKey = s.fds.getOrDefault(uint32(pidKey.ident), defaultKey)
        if fdKey.ident != InvalidIdent:
          fdKey.events.incl(Event.Finished)
          s.fds[uint32(pidKey.ident)] = fdKey

    elif Event.User in pkey.events:
      var data: uint64
      let res = handleEintr(osdefs.read(fdi, addr data, sizeof(uint64)))
      if res != sizeof(uint64):
        let errorCode = osLastError()
        if errorCode == EAGAIN:
          return Opt.none(ReadyKey)
        else:
          rkey.events.incl({Event.User, Event.Error})
          rkey.errorCode = errorCode
      else:
        rkey.events.incl(Event.User)

  if Event.Oneshot in rkey.events:
    if Event.Timer in rkey.events:
      if epoll_ctl(s.epollFd, EPOLL_CTL_DEL, cint(fdi), nil) != 0:
        rkey.events.incl(Event.Error)
        rkey.errorCode = osLastError()
      # we will not clear key until it will be unregistered, so
      # application can obtain data, but we will decrease counter,
      # because epoll is empty.
      dec(s.count)
      # we are marking key with `Finished` event, to avoid double decrease.
      rkey.events.incl(Event.Finished)
      pkey.events.incl(Event.Finished)
      s.fds[fdu32] = pkey

  ok(rkey)

proc checkProcesses[T](s: Selector[T]) =
  # If SIGCHLD has been seen we need to check all processes we are monitoring
  # for completion, because in Linux SIGCHLD could be masked.
  # You can get more information in article "Signalfd is useless" -
  # https://ldpreload.com/blog/signalfd-is-useless?reposted-on-request
  if s.childrenExited:
    let
      defaultKey = SelectorKey[T](ident: InvalidIdent)
      flags = WNOHANG or WNOWAIT or WSTOPPED or WEXITED
    s.childrenExited = false
    for pid, pidKey in s.processes.pairs():
      var fdKey = s.fds.getOrDefault(uint32(pidKey.ident), defaultKey)
      if fdKey.ident != InvalidIdent:
        if Event.Finished notin fdKey.events:
          var sigInfo = SigInfo()
          let res = handleEintr(osdefs.waitid(P_PID, Id(pid), sigInfo, flags))
          if (res == 0) and (cint(sigInfo.si_pid) == cint(pid)):
            fdKey.events.incl(Event.Finished)
            let rkey = ReadyKey(fd: pidKey.ident, events: fdKey.events)
            s.pendingEvents.addLast(rkey)
            s.fds[uint32(pidKey.ident)] = fdKey

proc selectInto2*[T](s: Selector[T], timeout: int,
                     readyKeys: var openArray[ReadyKey]
                    ): SelectResult[int] =
  var
    queueEvents: array[asyncEventsCount, EpollEvent]
    k: int = 0

  verifySelectParams(timeout, -1, int(high(cint)))

  let
    maxEventsCount = min(len(queueEvents), len(readyKeys))
    maxPendingEventsCount = min(maxEventsCount, len(s.pendingEvents))
    maxNewEventsCount = max(maxEventsCount - maxPendingEventsCount, 0)

  let
    eventsCount =
      if maxNewEventsCount > 0:
        let res = handleEintr(epoll_wait(s.epollFd, addr(queueEvents[0]),
                                         cint(maxNewEventsCount),
                                         cint(timeout)))
        if res < 0:
          return err(osLastError())
        res
      else:
        0

  s.childrenExited = false

  for i in 0 ..< eventsCount:
    let rkey = s.prepareKey(queueEvents[i]).valueOr: continue
    readyKeys[k] = rkey
    inc(k)

  s.checkProcesses()

  let pendingEventsCount = min(len(readyKeys) - eventsCount,
                               len(s.pendingEvents))

  for i in 0 ..< pendingEventsCount:
    readyKeys[k] = s.pendingEvents.popFirst()
    inc(k)

  ok(k)

proc select2*[T](s: Selector[T], timeout: int): SelectResult[seq[ReadyKey]] =
  var res = newSeq[ReadyKey](asyncEventsCount)
  let count = ? selectInto(s, timeout, res)
  res.setLen(count)
  ok(res)

proc newSelector*[T](): Selector[T] {.
     raises: [Defect, OSError].} =
  let res = Selector.new(T)
  if res.isErr(): raiseOSError(res.error())
  res.get()

proc close*[T](s: Selector[T]) {.
     raises: [Defect, IOSelectorsException].} =
  let res = s.close2()
  if res.isErr(): raiseIOSelectorsError(res.error())

proc newSelectEvent*(): SelectEvent {.
     raises: [Defect, IOSelectorsException].} =
  let res = SelectEvent.new()
  if res.isErr(): raiseIOSelectorsError(res.error())
  res.get()

proc trigger*(event: SelectEvent) {.
     raises: [Defect, IOSelectorsException].} =
  let res = event.trigger2()
  if res.isErr(): raiseIOSelectorsError(res.error())

proc close*(event: SelectEvent) {.
     raises: [Defect, IOSelectorsException].} =
  let res = event.close2()
  if res.isErr(): raiseIOSelectorsError(res.error())

proc registerHandle*[T](s: Selector[T], fd: int | SocketHandle,
                        events: set[Event], data: T) {.
    raises: [Defect, IOSelectorsException].} =
  let res = registerHandle2(s, cint(fd), events, data)
  if res.isErr(): raiseIOSelectorsError(res.isErr())

proc updateHandle*[T](s: Selector[T], fd: int | SocketHandle,
                      events: set[Event]) {.
    raises: [Defect, IOSelectorsException].} =
  let res = updateHandle2(s, cint(fd), events)
  if res.isErr(): raiseIOSelectorsError(res.error())

proc unregister*[T](s: Selector[T], fd: int | SocketHandle) {.
     raises: [Defect, IOSelectorsException].} =
  let res = unregister2(s, cint(fd))
  if res.isErr(): raiseIOSelectorsError(res.error())

proc unregister*[T](s: Selector[T], event: SelectEvent) {.
    raises: [Defect, IOSelectorsException].} =
  let res = unregister2(s, event)
  if res.isErr(): raiseIOSelectorsError(res.error())

proc registerTimer*[T](s: Selector[T], timeout: int, oneshot: bool,
                       data: T): int {.
    discardable, raises: [Defect, IOSelectorsException].} =
  let res = registerTimer2(s, timeout, oneshot, data)
  if res.isErr(): raiseIOSelectorsError(res.error())
  res.get()

proc registerEvent*[T](s: Selector[T], event: SelectEvent,
                       data: T) {.
     raises: [Defect, IOSelectorsException].} =
  let res = registerEvent2(s, event, data)
  if res.isErr(): raiseIOSelectorsError(res.error())

proc selectInto*[T](s: Selector[T], timeout: int,
                    readyKeys: var openArray[ReadyKey]): int {.
     raises: [Defect, IOSelectorsException].} =
  let res = selectInto2(s, timeout, readyKeys)
  if res.isErr(): raiseIOSelectorsError(res.error())
  res.get()

proc select*[T](s: Selector[T], timeout: int): seq[ReadyKey] =
  var res = newSeq[ReadyKey](asyncEventsCount)
  let count = selectInto(s, timeout, res)
  res.setLen(count)
  res

template isEmpty*[T](s: Selector[T]): bool =
  s.count == 0

proc contains*[T](s: Selector[T], fd: SocketHandle|int): bool {.inline.} =
  let fdu32 = uint32(fd)
  s.fds.contains(fdu32)

proc setData*[T](s: Selector[T], fd: SocketHandle|int, data: T): bool =
  let fdu32 = uint32(fd)
  s.fds.withValue(fdu32, skey):
    skey[].data = data
    return true
  do:
    return false

template withData*[T](s: Selector[T], fd: SocketHandle|int, value,
                        body: untyped) =
  let fdu32 = uint32(fd)
  s.fds.withValue(fdu32, skey):
    var value = addr(skey[].data)
    body

template withData*[T](s: Selector[T], fd: SocketHandle|int, value, body1,
                        body2: untyped) =
  let fdu32 = uint32(fd)
  s.fds.withValue(fdu32, skey):
    var value = addr(skey[].data)
    body1
  do:
    body2

proc getFd*[T](s: Selector[T]): int = int(s.epollFd)

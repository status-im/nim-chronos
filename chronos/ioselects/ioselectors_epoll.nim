#
#
#            Nim's Runtime Library
#        (c) Copyright 2016 Eugene Kabanov
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

# This module implements Linux epoll().

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

when hasThreadSupport:
  type
    SelectorImpl[T] = object
      epollFD: cint
      numFD: int
      fds: ptr SharedArray[SelectorKey[T]]
      count: int
    Selector*[T] = ptr SelectorImpl[T]
else:
  type
    SelectorImpl[T] = object
      epollFD: cint
      numFD: int
      fds: seq[SelectorKey[T]]
      count: int
    Selector*[T] = ref SelectorImpl[T]
type
  SelectEventImpl = object
    efd: cint
  SelectEvent* = ptr SelectEventImpl

proc new*(t: typedesc[Selector], T: typedesc): SelectResult[Selector[T]] =
  var epollFD = epoll_create(asyncEventsCount)
  if epollFD < 0:
    return err(osLastError())
  var selector =
    when hasThreadSupport:
      var res = cast[Selector[T]](allocShared0(sizeof(SelectorImpl[T])))
      res.epollFD = epollFD
      res.numFD = asyncInitialSize
      res.fds = allocSharedArray[SelectorKey[T]](asyncInitialSize)
      res
    else:
      Selector[T](
        epollFD: epollFD, numFD: asyncInitialSize,
        fds: newSeq[SelectorKey[T]](asyncInitialSize)
      )
  for i in 0 ..< asyncInitialSize:
    selector.fds[i].ident = InvalidIdent
  ok(selector)

proc close2*[T](s: Selector[T]): SelectResult[void] =
  let epollFD = s.epollFD
  when hasThreadSupport:
    deallocSharedArray(s.fds)
    deallocShared(cast[pointer](s))
  if handleEintr(osdefs.close(epollFD)) != 0:
    err(osLastError())
  else:
    ok()

proc new*(t: typedesc[SelectEvent]): SelectResult[SelectEvent] =
  let eFD = eventfd(0, EFD_CLOEXEC or EFD_NONBLOCK)
  if eFD == -1:
    return err(osLastError())
  var res = cast[SelectEvent](allocShared0(sizeof(SelectEventImpl)))
  res.efd = eFD
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
  let evFD = event.efd
  deallocShared(cast[pointer](event))
  let res = handleEintr(osdefs.close(evFD))
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
  let fdi = int(fd)
  s.checkFd(fdi)
  doAssert(s.fds[fdi].ident == InvalidIdent,
           "Descriptor " & $fdi & " already registered in the selector!")
  s.setKey(fdi, events, 0, data)
  if events != {}:
    let epollEvents = EpollEvent.init(fdi, events)
    if epoll_ctl(s.epollFD, EPOLL_CTL_ADD, fd, unsafeAddr epollEvents) != 0:
      return err(osLastError())
    inc(s.count)
  ok()

proc updateHandle2*[T](s: Selector[T], fd: cint,
                       events: set[Event]): SelectResult[void] =
  const EventsMask = {Event.Timer, Event.Signal, Event.Process, Event.Vnode,
                      Event.User, Event.Oneshot, Event.Error}
  let fdi = int(fd)
  doAssert(fdi < s.numFD,
           "Descriptor " & $fdi & " is not registered in the selector!")
  var pkey = addr(s.fds[fdi])
  doAssert(pkey.ident != InvalidIdent,
           "Descriptor " & $fdi & " is not registered in the selector!")
  doAssert(pkey.events * EventsMask == {},
           "Descriptor " & $fdi & " could not be updated!")
  if pkey.events != events:
    let epollEvents = EpollEvent.init(fdi, events)
    if pkey.events == {}:
      if epoll_ctl(s.epollFD, EPOLL_CTL_ADD, fd, unsafeAddr epollEvents) != 0:
        return err(osLastError())
      inc(s.count)
    else:
      if events != {}:
        if epoll_ctl(s.epollFD, EPOLL_CTL_MOD, fd, unsafeAddr epollEvents) != 0:
          return err(osLastError())
      else:
        if epoll_ctl(s.epollFD, EPOLL_CTL_DEL, fd, unsafeAddr epollEvents) != 0:
          return err(osLastError())
        dec(s.count)
    pkey.events = events
  ok()

proc unregister2*[T](s: Selector[T], fd: cint): SelectResult[void] =
  let fdi = int(fd)
  doAssert(fdi < s.numFD,
           "Descriptor " & $fdi & " is not registered in the selector!")
  var pkey = addr(s.fds[fdi])
  doAssert(pkey.ident != InvalidIdent,
           "Descriptor " & $fdi & " is not registered in the selector!")
  if pkey.events != {}:
    if {Event.Read, Event.Write, Event.User} * pkey.events != {}:
      if epoll_ctl(s.epollFD, EPOLL_CTL_DEL, fd, nil) != 0:
        return err(osLastError())
      dec(s.count)
    elif Event.Timer in pkey.events:
      if Event.Finished notin pkey.events:
        if epoll_ctl(s.epollFD, EPOLL_CTL_DEL, fd, nil) != 0:
          return err(osLastError())
        dec(s.count)
      if handleEintr(osdefs.close(fd)) == -1:
        return err(osLastError())
    elif Event.Signal in pkey.events:
      if epoll_ctl(s.epollFD, EPOLL_CTL_DEL, fd, nil) != 0:
          return err(osLastError())
      var nmask, omask: Sigset
      discard sigemptyset(nmask)
      discard sigemptyset(omask)
      discard sigaddset(nmask, cint(s.fds[fdi].param))
      ? unblockSignals(nmask, omask)
      dec(s.count)
      if handleEintr(osdefs.close(fd)) == -1:
        return err(osLastError())
    elif Event.Process in pkey.events:
      if Event.Finished notin pkey.events:
        if epoll_ctl(s.epollFD, EPOLL_CTL_DEL, fdi.cint, nil) != 0:
          return err(osLastError())
        var nmask, omask: Sigset
        discard sigemptyset(nmask)
        discard sigemptyset(omask)
        discard sigaddset(nmask, SIGCHLD)
        ? unblockSignals(nmask, omask)
        dec(s.count)
      if handleEintr(osdefs.close(fd)) == -1:
        return err(osLastError())
  clearKey(pkey)
  ok()

proc unregister2*[T](s: Selector[T], event: SelectEvent): SelectResult[void] =
  let fdi = int(event.efd)
  doAssert(fdi < s.numFD, NotRegisteredMessage)
  var pkey = addr(s.fds[fdi])
  doAssert(pkey.ident != InvalidIdent, NotRegisteredMessage)
  doAssert(Event.User in pkey.events)
  if epoll_ctl(s.epollFD, EPOLL_CTL_DEL, event.efd, nil) != 0:
    err(osLastError())
  else:
    dec(s.count)
    clearKey(pkey)
    ok()

proc registerTimer2*[T](s: Selector[T], timeout: int, oneshot: bool,
                        data: T): SelectResult[int] =
  var oldTs = Itimerspec()
  let fdi = int(timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC or TFD_NONBLOCK))
  if fdi == -1:
    return err(osLastError())

  s.checkFd(fdi)
  doAssert(s.fds[fdi].ident == InvalidIdent)

  var timeStruct =
    if oneshot:
      Itimerspec(
        it_interval: Timespec(tv_sec: osdefs.Time(0), tv_nsec: 0),
        it_value: Timespec(tv_sec: osdefs.Time(timeout div 1_000),
                           tv_nsec: (timeout %% 1000) * 1_000_000))
    else:
      Itimerspec(
        it_interval: Timespec(tc_sec: osdefs.Time(0), tv_nsec: 0),
        it_value: Timespec(tv_sec: osdefs.Time(timeout div 1_000),
                           tv_nsec: (timeout %% 1_000) * 1_000_000))
  let keyEvents, epollEvent =
    if oneshot:
      ({Event.Timer, Event.Oneshot},
       EpollEvent(events: EPOLLIN or EPOLLRDHUP or EPOLLONESHOT,
                  data: EpollData(u64: uint64(fdi))))
    else:
      ({Event.Timer},
       EpollEvent(events: EPOLLIN or EPOLLRDHUP,
                  data: EpollData(u64: uint64(fdi))))

  if timerfd_settime(cint(fdi), cint(0), timeStruct, oldTs) != 0:
    let errorCode = osLastError()
    discard handleEintr(osdefs.close(cint(fdi)))
    return err(errorCode)
  if epoll_ctl(s.epollFD, EPOLL_CTL_ADD, cint(fdi), unsafeAddr epollEvent) != 0:
    let errorCode = osLastError()
    discard handleEintr(osdefs.close(cint(fdi)))
    return err(errorCode)
  s.setKey(fdi, keyEvents, 0, data)
  inc(s.count)
  ok(fdi)

proc registerSignal*[T](s: Selector[T], signal: int,
                        data: T): SelectResult[int] =
  var
    nmask: Sigset
    omask: Sigset

  discard sigemptyset(nmask)
  discard sigemptyset(omask)
  discard sigaddset(nmask, cint(signal))
  ? blockSignals(nmask, omask)

  let fdi = int(signalfd(-1, nmask, SFD_NONBLOCK or SFD_CLOEXEC))
  if fdi == -1:
    let errorCode = osLastError()
    discard unblockSignals(nmask, omask)
    return err(errorCode)

  s.checkFd(fdi)
  doAssert(s.fds[fdi].ident == InvalidIdent)

  let epollEvent = EpollEvent(events: EPOLLIN or EPOLLRDHUP,
                              data: EpollData(u64: uint64(fdi)))
  if epoll_ctl(s.epollFD, EPOLL_CTL_ADD, cint(fdi), unsafeAddr epollEvent) != 0:
    let errorCode = osLastError()
    discard unblockSignals(nmask, omask)
    discard handleEintr(osdefs.close(cint(fdi)))
    return err(errorCode)
  s.setKey(fdi, {Event.Signal}, signal, data)
  inc(s.count)
  ok(fdi)

proc registerProcess*[T](s: Selector, pid: int, data: T): SelectResult[int] =
  var
    nmask: Sigset
    omask: Sigset

  discard sigemptyset(nmask)
  discard sigemptyset(omask)
  discard sigaddset(nmask, posix.SIGCHLD)
  ? blockSignals(nmask, omask)

  let fdi = int(signalfd(-1, nmask, SFD_NONBLOCK or SFD_CLOEXEC))
  if fdi == -1:
    let errorCode = osLastError()
    discard unblockSignals(nmask, omask)
    return err(errorCode)

  s.checkFd(fdi)
  doAssert(s.fds[fdi].ident == InvalidIdent)

  let epollEvent = EpollEvent(events: EPOLLIN or EPOLLRDHUP,
                              data: EpollData(u64: uint64(fdi)))
  if epoll_ctl(s.epollFD, EPOLL_CTL_ADD, cint(fdi), unsafeAddr epollEvent) != 0:
    let errorCode = osLastError()
    discard unblockSignals(nmask, omask)
    discard handleEintr(osdefs.close(cint(fdi)))
    return err(errorCode)
  s.setKey(fdi, {Event.Process, Event.Oneshot}, pid, data)
  inc(s.count)
  ok(fdi)

proc registerEvent2*[T](s: Selector[T], ev: SelectEvent,
                        data: T): SelectResult[int] =
  let fdi = int(ev.efd)
  s.checkFd(fdi)
  doAssert(s.fds[fdi].ident == InvalidIdent,
           "Event is already registered in the selector!")
  let epollEvent = EpollEvent(events: EPOLLIN or EPOLLRDHUP,
                              data: EpollData(u64: uint64(fdi)))
  if epoll_ctl(s.epollFD, EPOLL_CTL_ADD, ev.efd, unsafeAddr epollEvent) != 0:
    return err(osLastError())
  inc(s.count)
  ok()

proc selectInto2*[T](s: Selector[T], timeout: int,
                     readyKeys: var openArray[ReadyKey]
                    ): SelectResult[int] =
  var queueEvents: array[asyncEventsCount, EpollEvent]

  verifySelectParams(timeout)
  doAssert(timeout <= int(high(cint)), "Timeout value is too big!")

  let
    maxEventsCount = cint(min(asyncEventsCount, len(readyKeys)))
    eventsCount = handleEintr(epoll_wait(s.epollFD, addr(queueEvents[0]),
                                         maxEventsCount, cint(timeout)))
  if eventsCount < 0:
    return err(osLastError())

  var k = 0
  for i in 0 ..< eventsCount:
    doAssert(queueEvents[i].data.u64 < uint64(len(s.fds)))
    let
      fdi = int(queueEvents[i].data.u64)
      pevents = queueEvents[i].events
    var pkey = addr(s.fds[fdi])
    doAssert(pkey.ident != InvalidIdent)
    var rkey = ReadyKey(fd: fdi, events: {})

    if (pevents and EPOLLERR) != 0:
      rkey.events.incl(Event.Error)
      rkey.errorCode = OSErrorCode(ECONNRESET)

    if (pevents and EPOLLHUP) != 0 or (pevents and EPOLLRDHUP) != 0:
      rkey.events.incl(Event.Error)
      rkey.errorCode = OSErrorCode(ECONNRESET)

    if (pevents and EPOLLOUT) != 0:
      rkey.events.incl(Event.Write)

    if (pevents and EPOLLIN) != 0:
      if Event.Read in pkey.events:
        rkey.events.incl(Event.Read)
      elif Event.Timer in pkey.events:
        var data = 0'u64
        let res = handleEintr(osdefs.read(cint(fdi), addr data,
                                          sizeof(uint64)))
        rkey.events.incl(Event.Timer)
        if res != sizeof(uint64):
          rkey.events.incl(Event.Error)
          rkey.errorCode = osLastError()
      elif Event.Signal in pkey.events:
        var data = SignalFdInfo()
        let res = handleEintr(osdefs.read(cint(fdi), addr data,
                                          sizeof(SignalFdInfo)))
        rkey.events.incl(Event.Signal)
        if res != sizeof(SignalFdInfo):
          rkey.events.incl(Event.Error)
          rkey.errorCode = osLastError()
      elif Event.Process in pkey.events:
        var data = SignalFdInfo()
        let res = handleEintr(osdefs.read(cint(fdi), addr data,
                                          sizeof(SignalFdInfo)))
        if res != sizeof(SignalFdInfo):
          rkey.events.incl({Event.Process, Event.Error})
          rkey.errorCode = osLastError()
        else:
          if cast[int](data.ssi_pid) == pkey.param:
            rkey.events.incl(Event.Process)
          else:
            continue
      elif Event.User in pkey.events:
        var data: uint64 = 0
        let res = handleEintr(osdefs.read(cint(fdi), addr data,
                                          sizeof(uint64)))
        if res != sizeof(uint64):
          let errorCode = osLastError()
          if errorCode == EAGAIN:
            continue
          else:
            rkey.events.incl({Event.User, Event.Error})
            rkey.errorCode = errorCode
        else:
          rkey.events.incl(Event.User)

    if Event.Oneshot in pkey.events:
      var epv = EpollEvent()
      if epoll_ctl(s.epollFD, EPOLL_CTL_DEL, cint(fdi), nil) != 0:
        rkey.events.incl(Event.Error)
        rkey.errCode = osLastError()
      # we will not clear key until it will be unregistered, so
      # application can obtain data, but we will decrease counter,
      # because epoll is empty.
      dec(s.count)
      # we are marking key with `Finished` event, to avoid double decrease.
      pkey.events.incl(Event.Finished)

    readyKeys[k] = rkey
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
  if res.isErr():
    raiseOSError(res.error())
  res.get()

proc close*[T](s: Selector[T]) {.
     raises: [Defect, IOSelectorsException].} =
  let res = s.close2()
  if res.isErr():
    raiseIOSelectorsError(res.error())

proc newSelectEvent*(): SelectEvent {.
     raises: [Defect, IOSelectorsException].} =
  let res = SelectEvent.new()
  if res.isErr():
    raiseIOSelectorsError(res.error())

proc trigger*(event: SelectEvent) {.
     raises: [Defect, IOSelectorsException].} =
  let res = event.trigger2()
  if res.isErr():
    raiseIOSelectorsError(res.error())

proc close*(event: SelectEvent) {.
     raises: [Defect, IOSelectorsException].} =
  let res = event.close2()
  if res.isErr():
    raiseIOSelectorsError(res.error())

proc registerHandle*[T](s: Selector[T], fd: int | SocketHandle,
                        events: set[Event], data: T) {.
    raises: [Defect, IOSelectorsException].} =
  let res = registerHandle2(s, cint(fd), events, data)
  if res.isErr():
    raiseIOSelectorsError(res.isErr())

proc updateHandle*[T](s: Selector[T], fd: int | SocketHandle,
                      events: set[Event]) {.
    raises: [Defect, IOSelectorsException].} =
  let res = updateHandle2(s, cint(fd), events)
  if res.isErr():
    raiseIOSelectorsError(res.error())

proc unregister*[T](s: Selector[T], fd: int | SocketHandle) {.
     raises: [Defect, IOSelectorsException].} =
  let res = unregister2(s, cint(fd))
  if res.isErr():
    raiseIOSelectorsError(res.error())

proc unregister*[T](s: Selector[T], event: SelectEvent) {.
    raises: [Defect, IOSelectorsException].} =
  let res = unregister2(s, event)
  if res.isErr():
    raiseIOSelectorsError(res.error())

proc registerTimer*[T](s: Selector[T], timeout: int, oneshot: bool,
                       data: T): int {.
    discardable, raises: [Defect, IOSelectorsException].} =
  let res = registerTimer2(s, timeout, oneshot, data)
  if res.isErr():
    raiseIOSelectorsError(res.error())

proc registerEvent*[T](s: Selector[T], event: SelectEvent,
                       data: T) {.
     raises: [Defect, IOSelectorsException].} =
  let res = registerEvent2(s, event, data)
  if res.isErr():
    raiseIOSelectorsError(res.error())

proc selectInto*[T](s: Selector[T], timeout: int,
                    readyKeys: var openArray[ReadyKey]): int {.
     raises: [Defect, IOSelectorsException].} =
  let res = selectInto2(s, timeout, readyKeys)
  if res.isErr():
    raiseIOSelectorsError(res.error())
  res.get()

proc select*[T](s: Selector[T], timeout: int): seq[ReadyKey] =
  var res = newSeq[ReadyKey](asyncEventsCount)
  let count = selectInto(s, timeout, res)
  res.setLen(count)
  res

template isEmpty*[T](s: Selector[T]): bool =
  (s.count == 0)

proc contains*[T](s: Selector[T], fd: SocketHandle|int): bool {.inline.} =
  let fdi = int(fd)
  (fdi < s.numFD) and (s.fds[fdi].ident != InvalidIdent)

proc setData*[T](s: Selector[T], fd: SocketHandle|int, data: T): bool =
  let fdi = int(fd)
  if fdi in s:
    s.fds[fdi].data = data
    true
  else:
    false

template withData*[T](s: Selector[T], fd: SocketHandle|int, value,
                        body: untyped) =
  let fdi = int(fd)
  if fdi in s:
    var value = addr(s.fds[fdi].data)
    body

template withData*[T](s: Selector[T], fd: SocketHandle|int, value, body1,
                        body2: untyped) =
  let fdi = int(fd)
  if fdi in s:
    var value = addr(s.fds[fdi].data)
    body1
  else:
    body2

proc getFd*[T](s: Selector[T]): int =
  int(s.epollFd)

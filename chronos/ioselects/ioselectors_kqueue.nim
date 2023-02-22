#
#
#            Nim's Runtime Library
#        (c) Copyright 2016 Eugene Kabanov
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#
#  This module implements BSD kqueue().

{.push raises: [Defect].}
import std/[kqueue, deques, tables]
import stew/base10

const
  # SIG_IGN and SIG_DFL declared in posix.nim as variables, but we need them
  # to be constants and GC-safe.
  SIG_DFL = cast[proc(x: cint) {.raises: [], noconv, gcsafe.}](0)
  SIG_IGN = cast[proc(x: cint) {.raises: [], noconv, gcsafe.}](1)

type
  SelectorImpl[T] = object
    kqFd: cint
    fds: Table[uint32, SelectorKey[T]]
    virtualHoles: Deque[uint32]
    virtualId: uint32
    count: int

  Selector*[T] = ref SelectorImpl[T]

  SelectEventImpl = object
    rfd: cint
    wfd: cint

  SelectEvent* = ptr SelectEventImpl
  # SelectEvent is declared as `ptr` to be placed in `shared memory`,
  # so you can share one SelectEvent handle between threads.

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
  if ident <= uint32(high(cint)): false else: true

proc toInt(data: uint32): int =
  int(cast[int32](data))

proc toString(key: uint32): string =
  if isVirtualId(key):
    "V" & Base10.toString(key - uint32(high(cint)))
  else:
    Base10.toString(key)

template checkPid(pid: int) =
  when sizeof(int) == 8:
    doAssert(pid >= 0 and pid <= int(high(uint32)))
  else:
    doAssert(pid >= 0 and pid <= high(int32))

template addKey[T](s: Selector[T], ident: cint|uint32, skey: SelectorKey[T]) =
  let fdu32 =
    when ident is uint32:
      ident
    else:
      uint32(ident)

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

template getKey(key: SocketHandle|int): uint32 =
  doAssert((int(key) >= int(low(int32))) and (int(key) <= int(high(int32))),
           "Invalid descriptor [" & $int(key) & "] specified")
  uint32(int32(key))

proc freeKey[T](s: Selector[T], ident: uint32) =
  s.fds.del(ident)
  if isVirtualId(ident):
    s.virtualHoles.addFirst(ident)

template getIdent(event: KEvent): uint32 =
  doAssert(event.ident <= uint(high(uint32)),
           "Invalid event ident value [" & Base10.toString(event.ident) &
           "] in the kqueue event object")
  uint32(event.ident)

template getUdata(event: KEvent): uint32 =
  let udata = cast[uint](event.udata)
  doAssert(event.ident <= uint(high(uint32)),
             "Invalid event udata value [" & Base10.toString(udata) &
             "] in the kqueue event object with ident [" &
             Base10.toString(event.ident) & "]")
  uint32(udata)

proc new*(t: typedesc[Selector], T: typedesc): SelectResult[Selector[T]] =
  let kqFd =
    block:
      let res = handleEintr(kqueue())
      if res == -1:
        return err(osLastError())
      cint(res)

  let selector = Selector[T](
    kqFd: kqFd,
    fds: initTable[uint32, SelectorKey[T]](asyncInitialSize),
    virtualId: uint32(high(int32)),
    virtualHoles: initDeque[uint32]()
  )
  ok(selector)

proc close2*[T](s: Selector[T]): SelectResult[void] =
  s.fds.clear()
  s.virtualHoles.clear()
  s.virtualId = uint32(high(int32))
  s.count = 0
  if closeFd(s.kqFd) != 0:
    err(osLastError())
  else:
    ok()

proc new*(t: typedesc[SelectEvent]): SelectResult[SelectEvent] =
  var fds: array[2, cint]
  when declared(pipe2):
    if osdefs.pipe2(fds, osdefs.O_NONBLOCK or osdefs.O_CLOEXEC) == -1:
      return err(osLastError())

    var res = cast[SelectEvent](allocShared0(sizeof(SelectEventImpl)))
    res.rfd = fds[0]
    res.wfd = fds[1]
    ok(res)
  else:
    if osdefs.pipe(fds) == -1:
      return err(osLastError())

    let res1 = setDescriptorFlags(fds[0], true, true)
    if res1.isErr():
      discard closeFd(fds[0])
      discard closeFd(fds[1])
      return err(res1.error())
    let res2 = setDescriptorFlags(fds[1], true, true)
    if res2.isErr():
      discard closeFd(fds[0])
      discard closeFd(fds[1])
      return err(res2.error())

    var res = cast[SelectEvent](allocShared0(sizeof(SelectEventImpl)))
    res.rfd = fds[0]
    res.wfd = fds[1]
    ok(res)

proc trigger2*(event: SelectEvent): SelectResult[void] =
  var data: uint64 = 1
  let res = handleEintr(osdefs.write(event.wfd, addr data, sizeof(uint64)))
  if res == -1:
    err(osLastError())
  elif res != sizeof(uint64):
    err(OSErrorCode(osdefs.EINVAL))
  else:
    ok()

proc close2*(ev: SelectEvent): SelectResult[void] =
  let
    rfd = ev.rfd
    wfd = ev.wfd

  deallocShared(cast[pointer](ev))

  if closeFd(rfd) != 0:
    let errorCode = osLastError()
    discard closeFd(wfd)
    err(errorCode)
  else:
    if closeFd(wfd) != 0:
      err(osLastError())
    else:
      ok()

template modifyKQueue(changes: var openArray[KEvent], index: int, nident: uint,
                      nfilter: cshort, nflags: cushort, nfflags: cuint,
                      ndata: int, nudata: pointer) =
  changes[index] = KEvent(ident: nident, filter: nfilter, flags: nflags,
                          fflags: nfflags, data: ndata, udata: nudata)

proc registerHandle2*[T](s: Selector[T], fd: cint, events: set[Event],
                         data: T): SelectResult[void] =
  let
    fdu32 = uint32(fd)
    selectorKey = SelectorKey[T](ident: toInt(fdu32), events: events,
                                 param: 0, data: data)

  s.addKey(fdu32, selectorKey)

  if events != {}:
    var
      changes: array[2, KEvent]
      k = 0
    if Event.Read in events:
      changes.modifyKQueue(k, uint(fdu32), EVFILT_READ, EV_ADD, 0, 0, nil)
      inc(k)
    if Event.Write in events:
      changes.modifyKQueue(k, uint(fdu32), EVFILT_WRITE, EV_ADD, 0, 0, nil)
      inc(k)
    if k > 0:
      if handleEintr(kevent(s.kqFd, addr(changes[0]), cint(k), nil,
                            0, nil)) == -1:
        s.freeKey(fdu32)
        return err(osLastError())

  inc(s.count)
  ok()

proc updateHandle2*[T](s: Selector[T], fd: cint,
                       events: set[Event]): SelectResult[void] =
  let EventsMask = {Event.Timer, Event.Signal, Event.Process, Event.Vnode,
                    Event.User, Event.Oneshot, Event.Error}
  let fdu32 = uint32(fd)
  s.fds.withValue(fdu32, pkey):
    doAssert(pkey[].events * EventsMask == {},
             "Descriptor [" & fdu32.toString() & "]" &
             " could not be updated, got " & $pkey[].events)
    if pkey.events != events:
      var
        changes: array[4, KEvent]
        k = 0
      if (Event.Read in pkey[].events) and (Event.Read notin events):
        changes.modifyKQueue(k, uint(fdu32), EVFILT_READ, EV_DELETE, 0, 0, nil)
        inc(k)
      if (Event.Write in pkey[].events) and (Event.Write notin events):
        changes.modifyKQueue(k, uint(fdu32), EVFILT_WRITE, EV_DELETE, 0, 0, nil)
        inc(k)
      if (Event.Read notin pkey[].events) and (Event.Read in events):
        changes.modifyKQueue(k, uint(fdu32), EVFILT_READ, EV_ADD, 0, 0, nil)
        inc(k)
      if (Event.Write notin pkey[].events) and (Event.Write in events):
        changes.modifyKQueue(k, uint(fdu32), EVFILT_WRITE, EV_ADD, 0, 0, nil)
        inc(k)
      if k > 0:
        if handleEintr(kevent(s.kqFd, addr(changes[0]), cint(k), nil,
                              0, nil)) == -1:
          return err(osLastError())
      pkey[].events = events
  do:
    raiseAssert "Descriptor [" & fdu32.toString() &
                "] is not registered in the selector!"
  ok()

proc registerTimer*[T](s: Selector[T], timeout: int, oneshot: bool,
                       data: T): SelectResult[int] =
  let
    fdu32 = ? s.getVirtualId()
    events = if oneshot: {Event.Timer, Event.Oneshot} else: {Event.Timer}
    flags: cushort = if oneshot: EV_ONESHOT or EV_ADD else: EV_ADD
    selectorKey = SelectorKey[T](ident: toInt(fdu32), events: events,
                                 param: timeout, data: data)
  var changes: array[1, KEvent]
  s.addKey(fdu32, selectorKey)

  # EVFILT_TIMER on Open/Net(BSD) has granularity of only milliseconds,
  # but MacOS and FreeBSD allow use `0` as `fflags` to use milliseconds
  # too
  changes.modifyKQueue(0, uint(fdu32), EVFILT_TIMER, flags, 0,
                       cint(timeout), nil)
  if handleEintr(kevent(s.kqFd, addr(changes[0]), cint(1), nil, 0, nil)) == -1:
    s.freeKey(fdu32)
    return err(osLastError())

  inc(s.count)
  ok(toInt(fdu32))

proc blockSignal(signal: int): SelectResult[void] =
  var omask, nmask: Sigset
  if sigemptyset(nmask) < 0:
    return err(osLastError())
  if sigemptyset(omask) < 0:
    return err(osLastError())
  if sigaddset(nmask, cint(signal)) < 0:
    return err(osLastError())
  ? blockSignals(nmask, omask)
  ok()

proc unblockSignal(signal: int): SelectResult[void] =
  var omask, nmask: Sigset
  if sigemptyset(nmask) < 0:
    return err(osLastError())
  if sigemptyset(omask) < 0:
    return err(osLastError())
  if sigaddset(nmask, cint(signal)) < 0:
    return err(osLastError())
  ? unblockSignals(nmask, omask)
  ok()

proc registerSignal*[T](s: Selector[T], signal: int,
                        data: T): SelectResult[int] =
  let
    fdu32 = ? s.getVirtualId()
    events = {Event.Signal}
    selectorKey = SelectorKey[T](ident: toInt(fdu32), events: events,
                                 param: signal, data: data)

  var changes: array[1, KEvent]
  s.addKey(fdu32, selectorKey)

  let res = blockSignal(signal)
  if res.isErr():
    s.freeKey(fdu32)
    return err(res.error())

  # To be compatible with linux semantic we need to "eat" signals
  signal(cint(signal), SIG_IGN)
  changes.modifyKQueue(0, uint(signal), EVFILT_SIGNAL, EV_ADD, 0, 0,
                       cast[pointer](fdu32))
  if handleEintr(kevent(s.kqFd, addr(changes[0]), cint(1), nil, 0, nil)) == -1:
    let errorCode = osLastError()
    s.freeKey(fdu32)
    discard unblockSignal(signal)
    return err(errorCode)

  inc(s.count)
  ok(toInt(fdu32))

proc registerProcess*[T](s: Selector[T], pid: int, data: T): SelectResult[int] =
  checkPid(pid)

  let
    fdu32 = ? s.getVirtualId()
    events = {Event.Process, Event.Oneshot}
    flags: cushort = EV_ONESHOT or EV_ADD
    selectorKey = SelectorKey[T](ident: toInt(fdu32), events: events,
                                 param: pid, data: data)
  var changes: array[1, KEvent]
  s.addKey(fdu32, selectorKey)

  changes.modifyKQueue(0, uint(pid), EVFILT_PROC, flags, NOTE_EXIT,
                       0, cast[pointer](fdu32))
  if handleEintr(kevent(s.kqFd, addr(changes[0]), cint(1), nil, 0, nil)) == -1:
    s.freeKey(fdu32)
    return err(osLastError())

  inc(s.count)
  ok(toInt(fdu32))

proc registerEvent2*[T](s: Selector[T], ev: SelectEvent,
                        data: T): SelectResult[int] =
  let
    fdu32 = uint32(ev.rfd)
    selectorKey = SelectorKey[T](ident: toInt(fdu32), events: {Event.User},
                                 param: 0, data: data)

  var changes: array[1, KEvent]
  s.addKey(fdu32, selectorKey)

  changes.modifyKQueue(0, uint(fdu32), EVFILT_READ, EV_ADD, 0, 0, nil)
  if handleEintr(kevent(s.kqFd, addr(changes[0]), cint(1), nil, 0, nil)) == -1:
    s.freeKey(fdu32)
    return err(osLastError())

  inc(s.count)
  ok(toInt(fdu32))

template processVnodeEvents(events: set[Event]): cuint =
  var rfflags = cuint(0)
  if events == {Event.VnodeWrite, Event.VnodeDelete, Event.VnodeExtend,
                Event.VnodeAttrib, Event.VnodeLink, Event.VnodeRename,
                Event.VnodeRevoke}:
    rfflags = NOTE_DELETE or NOTE_WRITE or NOTE_EXTEND or NOTE_ATTRIB or
              NOTE_LINK or NOTE_RENAME or NOTE_REVOKE
  else:
    if Event.VnodeDelete in events: rfflags = rfflags or NOTE_DELETE
    if Event.VnodeWrite in events: rfflags = rfflags or NOTE_WRITE
    if Event.VnodeExtend in events: rfflags = rfflags or NOTE_EXTEND
    if Event.VnodeAttrib in events: rfflags = rfflags or NOTE_ATTRIB
    if Event.VnodeLink in events: rfflags = rfflags or NOTE_LINK
    if Event.VnodeRename in events: rfflags = rfflags or NOTE_RENAME
    if Event.VnodeRevoke in events: rfflags = rfflags or NOTE_REVOKE
  rfflags

proc registerVnode2*[T](s: Selector[T], fd: cint, events: set[Event],
                        data: T): SelectResult[int] =
  let
    fdu32 = ? s.getVirtualId()
    events = {Event.Vnode} + events
    fflags = processVnodeEvents(events)
    selectorKey = SelectorKey[T](ident: toInt(fdu32), events: events,
                                 param: 0, data: data)

  var changes: array[1, KEvent]
  s.addKey(fdu32, selectorKey)

  changes.modifyKQueue(0, uint(fdu32), EVFILT_VNODE, EV_ADD or EV_CLEAR,
                       fflags, 0, nil)
  if handleEintr(kevent(s.kqFd, addr(changes[0]), cint(1), nil, 0, nil)) == -1:
    s.freeKey(fdu32)
    return err(osLastError())

  inc(s.count)
  ok(toInt(fdu32))

proc unregister2*[T](s: Selector[T], fd: cint): SelectResult[void] =
  let
    fdu32 = uint32(fd)
    pkey = s.getKey(fdu32)

  var changes: array[2, KEvent]
  var k = 0

  if pkey.events != {}:
    if pkey.events * {Event.Read, Event.Write} != {}:
      if Event.Read in pkey.events:
        changes.modifyKQueue(k, uint(fdu32), EVFILT_READ, EV_DELETE,
                             0, 0, nil)
        inc(k)
      if Event.Write in pkey.events:
        changes.modifyKQueue(k, uint(fdu32), EVFILT_WRITE, EV_DELETE,
                             0, 0, nil)
        inc(k)
      if k > 0:
        if handleEintr(kevent(s.kqFd, addr(changes[0]), cint(k), nil,
                              0, nil)) == -1:
          return err(osLastError())
      dec(s.count)

    elif Event.Timer in pkey.events:
      if Event.Finished notin pkey.events:
        changes.modifyKQueue(0, uint(fdu32), EVFILT_TIMER, EV_DELETE,
                             0, 0, nil)
        if handleEintr(kevent(s.kqFd, addr(changes[0]), cint(1), nil,
                              0, nil)) == -1:
          return err(osLastError())
        dec(s.count)

    elif Event.Signal in pkey.events:
      let sig = cint(pkey.param)
      osdefs.signal(sig, SIG_DFL)
      changes.modifyKQueue(0, uint(pkey.param), EVFILT_SIGNAL, EV_DELETE,
                           0, 0, nil)
      if handleEintr(kevent(s.kqFd, addr(changes[0]), cint(1), nil,
                            0, nil)) == -1:
        discard unblockSignal(sig)
        return err(osLastError())

      ? unblockSignal(sig)
      dec(s.count)

    elif Event.Process in pkey.events:
      if Event.Finished notin pkey.events:
        changes.modifyKQueue(0, uint(pkey.param), EVFILT_PROC, EV_DELETE,
                             0, 0, nil)
        if handleEintr(kevent(s.kqFd, addr(changes[0]), cint(1), nil,
                              0, nil)) == -1:
          return err(osLastError())
        dec(s.count)

    elif Event.Vnode in pkey.events:
      changes.modifyKQueue(0, uint(fdu32), EVFILT_VNODE, EV_DELETE,
                           0, 0, nil)
      if handleEintr(kevent(s.kqFd, addr(changes[0]), cint(1), nil,
                              0, nil)) == -1:
        return err(osLastError())
      dec(s.count)

    elif Event.User in pkey.events:
      changes.modifyKQueue(0, uint(fdu32), EVFILT_READ, EV_DELETE,
                           0, 0, nil)
      if handleEintr(kevent(s.kqFd, addr(changes[0]), cint(1), nil,
                              0, nil)) == -1:
        return err(osLastError())
      dec(s.count)

  s.freeKey(fdu32)
  ok()

proc unregister2*[T](s: Selector[T], event: SelectEvent): SelectResult[void] =
  s.unregister2(event.rfd)

proc prepareKey[T](s: Selector[T], event: KEvent): Opt[ReadyKey] =
  let fdu32 = event.getIdent()

  var rkey = ReadyKey(fd: toInt(fdu32), events: {})
  var pkey =
    case event.filter:
    of EVFILT_READ, EVFILT_WRITE, EVFILT_TIMER, EVFILT_VNODE:
      s.getKey(fdu32)
    of EVFILT_SIGNAL, EVFILT_PROC:
      let virtualFd = event.getUdata()
      s.getKey(virtualFd)
    else:
      raiseAssert "Unsupported kqueue filter [" & $event.filter & "] reported!"

  case event.filter
  of EVFILT_READ:
    if (event.flags and EV_EOF) != 0:
      rkey.events.incl(Event.Error)
      rkey.errorCode = OSErrorCode(ECONNRESET)

    if Event.User in pkey.events:
      var data: uint64 = 0
      if handleEintr(osdefs.read(cint(event.ident), addr data,
                                 sizeof(uint64))) != sizeof(uint64):
        let errorCode = osLastError()
        if errorCode == EAGAIN:
          # Someone already consumed event data
          return Opt.none(ReadyKey)
        else:
          rkey.events.incl(Event.Error)
          rkey.errorCode = errorCode
      rkey.events.incl(Event.User)
    else:
      rkey.events.incl(Event.Read)

  of EVFILT_WRITE:
    if (event.flags and EV_EOF) != 0:
      rkey.events.incl(Event.Error)
      rkey.errorCode = OSErrorCode(ECONNRESET)

    rkey.events.incl(Event.Write)

  of EVFILT_TIMER:
    rkey.events.incl(Event.Timer)
    if Event.Oneshot in pkey.events:
      # we will not clear key until it will be unregistered, so
      # application can obtain data, but we will decrease counter,
      # because kqueue is empty.
      dec(s.count)
      # we are marking key with `Finished` event, to avoid double decrease.
      pkey.events.incl(Event.Finished)
      rkey.events.incl({Event.Oneshot, Event.Finished})
      s.fds[fdu32] = pkey

  of EVFILT_VNODE:
    rkey.events.incl(Event.Vnode)
    if (event.fflags and NOTE_DELETE) != 0: rkey.events.incl(Event.VnodeDelete)
    if (event.fflags and NOTE_WRITE) != 0: rkey.events.incl(Event.VnodeWrite)
    if (event.fflags and NOTE_EXTEND) != 0: rkey.events.incl(Event.VnodeExtend)
    if (event.fflags and NOTE_ATTRIB) != 0: rkey.events.incl(Event.VnodeAttrib)
    if (event.fflags and NOTE_LINK) != 0: rkey.events.incl(Event.VnodeLink)
    if (event.fflags and NOTE_RENAME) != 0: rkey.events.incl(Event.VnodeRename)
    if (event.fflags and NOTE_REVOKE) != 0: rkey.events.incl(Event.VnodeRevoke)

  of EVFILT_SIGNAL:
    rkey.events.incl(Event.Signal)
    rkey.fd = pkey.ident

  of EVFILT_PROC:
    rkey.events.incl({Event.Process, Event.Oneshot, Event.Finished})
    dec(s.count)
    rkey.fd = pkey.ident
    pkey.events.incl(Event.Finished)
    s.fds[uint32(pkey.ident)] = pkey

  else:
    raiseAssert "Unsupported kqueue filter [" & $event.filter & "] reported!"

  ok(rkey)

proc selectInto2*[T](s: Selector[T], timeout: int,
                     readyKeys: var openArray[ReadyKey]
                     ): SelectResult[int] =
  var
    tv: Timespec
    queueEvents: array[asyncEventsCount, KEvent]

  verifySelectParams(timeout, -1, high(int))

  let
    ptrTimeout =
      if timeout != -1:
        if timeout >= 1000:
          tv.tv_sec = Time(timeout div 1_000)
          tv.tv_nsec = (timeout %% 1_000) * 1_000_000
        else:
          tv.tv_sec = Time(0)
          tv.tv_nsec = timeout * 1_000_000
        addr tv
      else:
        nil
    maxEventsCount = cint(min(asyncEventsCount, len(readyKeys)))
    eventsCount =
      block:
        var res = 0
        while true:
          res = kevent(s.kqFd, nil, cint(0), addr(queueEvents[0]),
                       maxEventsCount, ptrTimeout)
          if res < 0:
            let errorCode = osLastError()
            if errorCode == EINTR:
              continue
            return err(errorCode)
          else:
            break
        res

  var k = 0
  for i in 0 ..< eventsCount:
    let rkey = s.prepareKey(queueEvents[i]).valueOr: continue
    readyKeys[k] = rkey
    inc(k)

  ok(k)

proc select2*[T](s: Selector[T],
                 timeout: int): Result[seq[ReadyKey], OSErrorCode] =
  var res = newSeq[ReadyKey](asyncEventsCount)
  let count = ? selectInto2(s, timeout, res)
  res.setLen(count)
  ok(res)

proc newSelector*[T](): owned(Selector[T]) {.
     raises: [Defect, IOSelectorsException].} =
  let res = Selector.new(T)
  if res.isErr():
    raiseIOSelectorsError(res.error())
  res.get()

proc newSelectEvent*(): SelectEvent {.
     raises: [Defect, IOSelectorsException].} =
  let res = SelectEvent.new()
  if res.isErr():
    raiseIOSelectorsError(res.error())
  res.get()

proc trigger*(ev: SelectEvent) {.
     raises: [Defect, IOSelectorsException].} =
  let res = ev.trigger2()
  if res.isErr():
    raiseIOSelectorsError(res.error())

proc close*(ev: SelectEvent) {.
     raises: [Defect, IOSelectorsException].} =
  let res = ev.close2()
  if res.isErr():
    raiseIOSelectorsError(res.error())

proc registerHandle*[T](s: Selector[T], fd: int | SocketHandle,
                        events: set[Event], data: T) {.
     raises: [Defect, IOSelectorsException].} =
  let res = registerHandle2(s, cint(fd), events, data)
  if res.isErr():
    raiseIOSelectorsError(res.error())

proc updateHandle*[T](s: Selector[T], fd: int | SocketHandle,
                      events: set[Event]) {.
     raises: [Defect, IOSelectorsException].} =
  let res = updateHandle2(s, cint(fd), events)
  if res.isErr():
    raiseIOSelectorsError(res.error())

proc registerEvent*[T](s: Selector[T], ev: SelectEvent, data: T) {.
     raises: [Defect, IOSelectorsException].} =
  let res = registerEvent2(s, ev, data)
  if res.isErr():
    raiseIOSelectorsError(res.error())

proc registerVnode*[T](s: Selector[T], fd: cint, events: set[Event], data: T) {.
     raises: [Defect, IOSelectorsException].} =
  let res = registerVnode2(s, fd, events, data)
  if res.isErr():
    raiseIOSelectorsError(res.error())

proc unregister*[T](s: Selector[T], event: SelectEvent) {.
  raises: [Defect, IOSelectorsException].} =
  let res = unregister2(s, event)
  if res.isErr():
    raiseIOSelectorsError(res.error())

proc unregister*[T](s: Selector[T], fd: int|SocketHandle) {.
  raises: [Defect, IOSelectorsException].} =
  let res = unregister2(s, fd)
  if res.isErr():
    raiseIOSelectorsError(res.error())

proc selectInto*[T](s: Selector[T], timeout: int,
                    results: var openArray[ReadyKey]): int {.
     raises: [Defect, IOSelectorsException].} =
  let res = selectInto2(s, timeout, results)
  if res.isErr():
    raiseIOSelectorsError(res.error())
  res.get()

proc select*[T](s: Selector[T], timeout: int): seq[ReadyKey] {.
     raises: [Defect, IOSelectorsException].} =
  let res = select2(s, timeout)
  if res.isErr():
    raiseIOSelectorsError(res.error())
  res.get()

proc close*[T](s: Selector[T]) {.raises: [Defect, IOSelectorsException].} =
  let res = s.close2()
  if res.isErr():
    raiseIOSelectorsError(res.error())

template isEmpty*[T](s: Selector[T]): bool =
  (s.count == 0)

proc contains*[T](s: Selector[T], fd: SocketHandle|int): bool {.inline.} =
  let fdu32 = getKey(fd)
  s.fds.contains(fdu32)

proc setData*[T](s: Selector[T], fd: SocketHandle|int, data: T): bool =
  let fdu32 = getKey(fd)
  s.fds.withValue(fdu32, skey):
    skey[].data = data
    return true
  do:
    return false

template withData*[T](s: Selector[T], fd: SocketHandle|int, value,
                        body: untyped) =
  let fdu32 = getKey(fd)
  s.fds.withValue(fdu32, skey):
    var value = addr(skey[].data)
    body

template withData*[T](s: Selector[T], fd: SocketHandle|int, value, body1,
                        body2: untyped) =
  let fdu32 = getKey(fd)
  s.fds.withValue(fdu32, skey):
    var value = addr(skey[].data)
    body1
  do:
    body2

proc getFd*[T](s: Selector[T]): int = int(s.kqFd)

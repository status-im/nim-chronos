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
import std/kqueue

const
  # SIG_IGN and SIG_DFL declared in posix.nim as variables, but we need them
  # to be constants and GC-safe.
  SIG_DFL = cast[proc(x: cint) {.raises: [],noconv,gcsafe.}](0)
  SIG_IGN = cast[proc(x: cint) {.raises: [],noconv,gcsafe.}](1)

when hasThreadSupport:
  type
    SelectorImpl[T] = object
      kqFD: cint
      numFD: int
      changes: ptr SharedArray[KEvent]
      fds: ptr SharedArray[SelectorKey[T]]
      count: int
      changesLock: Lock
      changesSize: int
      changesLength: int
      sock: cint
    Selector*[T] = ptr SelectorImpl[T]
else:
  type
    SelectorImpl[T] = object
      kqFD: cint
      numFD: int
      changes: seq[KEvent]
      fds: seq[SelectorKey[T]]
      count: int
      sock: cint
    Selector*[T] = ref SelectorImpl[T]

type
  SelectEventImpl = object
    rfd: cint
    wfd: cint

  SelectEvent* = ptr SelectEventImpl
  # SelectEvent is declared as `ptr` to be placed in `shared memory`,
  # so you can share one SelectEvent handle between threads.

proc getUnique[T](s: Selector[T]): SelectResult[int] =
  # we create duplicated handles to get unique indexes for our `fds` array.
  let res = handleEintr(posix.fcntl(s.sock, F_DUPFD, s.sock))
  if res == -1:
    err(osLastError())
  else:
    ok(res)

proc new*(t: typedesc[Selector], T: typedesc): SelectResult[Selector[T]] =
  var kqFD = handleEintr(kqueue())
  if kqFD == -1:
    return err(osLastError())

  # we allocating empty socket to duplicate it handle in future, to get unique
  # indexes for `fds` array. This is needed to properly identify
  # {Event.Timer, Event.Signal, Event.Process} events.
  let usock = cint(osdefs.socket(osdefs.AF_INET, osdefs.SOCK_STREAM,
                                 osdefs.IPPROTO_TCP))
  if usock == -1:
    let errorCode = osLastError()
    discard handleEintr(osdefs.close(cint(kqFD)))
    return err(errorCode)

  var selector =
    when hasThreadSupport:
      var res = cast[Selector[T]](allocShared0(sizeof(SelectorImpl[T])))
      res.kqFD = cint(kqFD)
      res.sock = usock
      res.numFD = asyncInitialSize
      res.fds = allocSharedArray[SelectorKey[T]](asyncInitialSize)
      res.changes = allocSharedArray[KEvent](asyncEventsCount)
      res.changesSize = asyncEventsCount
      initLock(res.changesLock)
      res
    else:
      Selector[T](kqFD: cint(kqFD), sock: usock, numFD: asyncInitialSize,
                  fds: newSeq[SelectorKey[T]](asyncInitialSize),
                  changes: newSeqOfCap[KEvent](asyncEventsCount))

  for i in 0 ..< selector.numFD:
    selector.fds[i].ident = InvalidIdent
  ok(selector)

proc close2*[T](s: Selector[T]): SelectResult[void] =
  let
    kqFD = s.kqFD
    sockFD = s.sock

  when hasThreadSupport:
    deinitLock(s.changesLock)
    deallocSharedArray(s.fds)
    deallocShared(cast[pointer](s))

  if handleEintr(osdefs.close(sockFD)) != 0:
    let errorCode = osLastError()
    discard osdefs.close(kqFD)
    err(errorCode)
  else:
    if handleEintr(osdefs.close(kqFD)) != 0:
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
      discard handleEintr(osdefs.close(fds[0]))
      discard handleEintr(osdefs.close(fds[1]))
      return err(res1.error())
    let res2 = setDescriptorFlags(fds[1], true, true)
    if res2.isErr():
      discard handleEintr(osdefs.close(fds[0]))
      discard handleEintr(osdefs.close(fds[1]))
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

  if handleEintr(osdefs.close(rfd)) != 0:
    let errorCode = osLastError()
    discard osdefs.close(wfd)
    err(errorCode)
  else:
    if handleEintr(osdefs.close(wfd)) != 0:
      err(osLastError())
    else:
      ok()

when hasThreadSupport:
  template withChangeLock[T](s: Selector[T], body: untyped) =
    acquire(s.changesLock)
    {.locks: [s.changesLock].}:
      try:
        body
      finally:
        release(s.changesLock)

  template modifyKQueue[T](s: Selector[T], nident: uint, nfilter: cshort,
                           nflags: cushort, nfflags: cuint, ndata: int,
                           nudata: pointer) =
    mixin withChangeLock
    s.withChangeLock():
      if s.changesLength == s.changesSize:
        # if cache array is full, we allocating new with size * 2
        let newSize = s.changesSize shl 1
        let rdata = allocSharedArray[KEvent](newSize)
        copyMem(rdata, s.changes, s.changesSize * sizeof(KEvent))
        s.changesSize = newSize
      s.changes[s.changesLength] = KEvent(ident: nident,
                                          filter: nfilter, flags: nflags,
                                          fflags: nfflags, data: ndata,
                                          udata: nudata)
      inc(s.changesLength)

  proc flushKQueue[T](s: Selector[T]): SelectResult[void] =
    mixin withChangeLock
    s.withChangeLock():
      if s.changesLength > 0:
        if handleEintr(kevent(s.kqFD, addr(s.changes[0]), cint(s.changesLength),
                              nil, 0, nil)) == -1:
          return err(osLastError())
        s.changesLength = 0
    ok()

else:
  template modifyKQueue[T](s: Selector[T], nident: uint, nfilter: cshort,
                           nflags: cushort, nfflags: cuint, ndata: int,
                           nudata: pointer) =
    s.changes.add(KEvent(ident: nident,
                         filter: nfilter, flags: nflags,
                         fflags: nfflags, data: ndata,
                         udata: nudata))

  proc flushKQueue[T](s: Selector[T]): SelectResult[void] =
    let length = cint(len(s.changes))
    if length > 0:
      if handleEintr(kevent(s.kqFD, addr(s.changes[0]), length, nil,
                            0, nil)) == -1:
        return err(osLastError())
      s.changes.setLen(0)
    ok()

proc registerHandle2*[T](s: Selector[T], fd: cint, events: set[Event],
                         data: T): Result[void, OSErrorCode] =
  let fdi = int(fd)
  s.checkFd(fdi)
  doAssert(s.fds[fdi].ident == InvalidIdent,
           "Descriptor " & $fdi & " already registered in the selector!")
  s.setKey(fdi, events, 0, data)
  if events != {}:
    if Event.Read in events:
      modifyKQueue(s, uint(fdi), EVFILT_READ, EV_ADD, 0, 0, nil)
      inc(s.count)
    if Event.Write in events:
      modifyKQueue(s, uint(fdi), EVFILT_WRITE, EV_ADD, 0, 0, nil)
      inc(s.count)
    ? flushKQueue(s)
  ok()

proc updateHandle2*[T](s: Selector[T], fd: cint,
                       events: set[Event]): SelectResult[void] =
  let EventsMask = {Event.Timer, Event.Signal, Event.Process, Event.Vnode,
                    Event.User, Event.Oneshot, Event.Error}
  let fdi = int(fd)
  doAssert(fdi < s.numFD,
           "Descriptor [" & $fdi & " is not registered in the selector!")
  var pkey = addr(s.fds[fdi])
  doAssert(pkey.ident != InvalidIdent,
           "Descriptor [" & $fdi & " is not registered in the selector!")
  doAssert(pkey.events * EventsMask == {},
           "Descriptor " & $fdi & " could not be updated!")

  if pkey.events != events:
    if (Event.Read in pkey.events) and (Event.Read notin events):
      modifyKQueue(s, fdi.uint, EVFILT_READ, EV_DELETE, 0, 0, nil)
      dec(s.count)
    if (Event.Write in pkey.events) and (Event.Write notin events):
      modifyKQueue(s, fdi.uint, EVFILT_WRITE, EV_DELETE, 0, 0, nil)
      dec(s.count)
    if (Event.Read notin pkey.events) and (Event.Read in events):
      modifyKQueue(s, fdi.uint, EVFILT_READ, EV_ADD, 0, 0, nil)
      inc(s.count)
    if (Event.Write notin pkey.events) and (Event.Write in events):
      modifyKQueue(s, fdi.uint, EVFILT_WRITE, EV_ADD, 0, 0, nil)
      inc(s.count)
    ? flushKQueue(s)
    pkey.events = events
  ok()

proc registerTimer*[T](s: Selector[T], timeout: int, oneshot: bool,
                       data: T): SelectResult[int] =
  let fdi = ? getUnique(s)
  s.checkFd(fdi)
  doAssert(s.fds[fdi].ident == InvalidIdent,
           "Descriptor [" & $fdi & " is already registered in the selector!")

  let events = if oneshot: {Event.Timer, Event.Oneshot} else: {Event.Timer}
  let flags: cushort = if oneshot: EV_ONESHOT or EV_ADD else: EV_ADD
  s.setKey(fdi, events, 0, data)

  # EVFILT_TIMER on Open/Net(BSD) has granularity of only milliseconds,
  # but MacOS and FreeBSD allow use `0` as `fflags` to use milliseconds
  # too
  modifyKQueue(s, uint(fdi), EVFILT_TIMER, flags, 0, cint(timeout), nil)

  let res = flushKQueue(s)
  if res.isErr():
    discard handleEintr(osdefs.close(cint(fdi)))
    return err(res.error())
  inc(s.count)
  ok(fdi)

proc registerSignal*[T](s: Selector[T], signal: int,
                        data: T): SelectResult[int] =
  let fdi = ? getUnique(s)
  s.checkFd(fdi)
  doAssert(s.fds[fdi].ident == InvalidIdent,
           "Descriptor [" & $fdi & " is already registered in the selector!")

  s.setKey(fdi, {Event.Signal}, signal, data)
  var nmask, omask: Sigset
  discard sigemptyset(nmask)
  discard sigemptyset(omask)
  discard sigaddset(nmask, cint(signal))

  let bres = blockSignals(nmask, omask)
  if bres.isErr():
    discard handleEintr(osdefs.close(cint(fdi)))
    return err(bres.error())

  # to be compatible with linux semantic we need to "eat" signals
  posix.signal(cint(signal), SIG_IGN)
  modifyKQueue(s, uint(signal), EVFILT_SIGNAL, EV_ADD, 0, 0, cast[pointer](fdi))

  let fres = flushKQueue(s)
  if fres.isErr():
    discard unblockSignals(nmask, omask)
    discard handleEintr(osdefs.close(cint(fdi)))
    return err(fres.error())
  inc(s.count)
  ok(fdi)

proc registerProcess*[T](s: Selector[T], pid: int, data: T): SelectResult[int] =
  let fdi = ? getUnique(s)
  s.checkFd(fdi)
  doAssert(s.fds[fdi].ident == InvalidIdent,
           "Descriptor [" & $fdi & " is already registered in the selector!")

  var kflags: cushort = EV_ONESHOT or EV_ADD
  setKey(s, fdi, {Event.Process, Event.Oneshot}, pid, data)

  modifyKQueue(s, uint(pid), EVFILT_PROC, kflags, NOTE_EXIT, 0,
               cast[pointer](fdi))
  let res = flushKQueue(s)
  if res.isErr():
    discard handleEintr(osdefs.close(cint(fdi)))
    return err(res.error())
  inc(s.count)
  ok(fdi)

proc registerEvent2*[T](s: Selector[T], ev: SelectEvent,
                        data: T): SelectResult[void] =
  let fdi = int(ev.rfd)
  s.checkFd(fdi)
  doAssert(s.fds[fdi].ident == InvalidIdent,
           "Event is already registered in the selector!")
  setKey(s, fdi, {Event.User}, 0, data)

  modifyKQueue(s, fdi.uint, EVFILT_READ, EV_ADD, 0, 0, nil)
  ? flushKQueue(s)
  inc(s.count)
  ok()

template processVnodeEvents(events: set[Event]): cuint =
  var rfflags = 0.cuint
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
                        data: T): SelectResult[void] =
  let fdi = int(fd)
  s.checkFd(fdi)
  doAssert(s.fds[fdi].ident == InvalidIdent,
           "Descriptor [" & $fdi & " is already registered in the selector!")
  setKey(s, fdi, {Event.Vnode} + events, 0, data)
  let fflags = processVnodeEvents(events)
  modifyKQueue(s, uint(fdi), EVFILT_VNODE, EV_ADD or EV_CLEAR, fflags, 0, nil)
  ? flushKQueue(s)
  inc(s.count)
  ok()

proc unregister2*[T](s: Selector[T], fd: cint): SelectResult[void] =
  let fdi = int(fd)
  doAssert(fdi < s.numFD,
           "Descriptor [" & $fdi & "] is not registered in the selector!")
  var pkey = addr(s.fds[fdi])
  doAssert(pkey.ident != InvalidIdent,
           "Descriptor [" & $fdi & "] is not registered in the selector!")

  if pkey.events != {}:
    if pkey.events * {Event.Read, Event.Write} != {}:
      var count = 0
      if Event.Read in pkey.events:
        modifyKQueue(s, uint(fdi), EVFILT_READ, EV_DELETE, 0, 0, nil)
        inc(count)
      if Event.Write in pkey.events:
        modifyKQueue(s, uint(fdi), EVFILT_WRITE, EV_DELETE, 0, 0, nil)
        inc(count)
      ? flushKQueue(s)
      dec(s.count, count)
    elif Event.Timer in pkey.events:
      if Event.Finished notin pkey.events:
        modifyKQueue(s, uint(fdi), EVFILT_TIMER, EV_DELETE, 0, 0, nil)
        ? flushKQueue(s)
        dec(s.count)
      if handleEintr(osdefs.close(cint(pkey.ident))) != 0:
        return err(osLastError())
    elif Event.Signal in pkey.events:
      var nmask, omask: Sigset
      let sig = cint(pkey.param)
      osdefs.signal(sig, SIG_DFL)
      modifyKQueue(s, uint(pkey.param), EVFILT_SIGNAL, EV_DELETE, 0, 0, nil)
      ? flushKQueue(s)
      dec(s.count)
      discard sigemptyset(nmask)
      discard sigemptyset(omask)
      discard sigaddset(nmask, sig)
      let res = unblockSignals(nmask, omask)
      if res.isErr():
        discard handleEintr(osdefs.close(cint(pkey.ident)))
        return err(res.error())
      else:
        if handleEintr(osdefs.close(cint(pkey.ident))) != 0:
          return err(osLastError())
    elif Event.Process in pkey.events:
      if Event.Finished notin pkey.events:
        modifyKQueue(s, uint(pkey.param), EVFILT_PROC, EV_DELETE, 0, 0, nil)
        ? flushKQueue(s)
        dec(s.count)
      if handleEintr(osdefs.close(cint(pkey.ident))) != 0:
        return err(osLastError())
    elif Event.Vnode in pkey.events:
      modifyKQueue(s, uint(fdi), EVFILT_VNODE, EV_DELETE, 0, 0, nil)
      ? flushKQueue(s)
      dec(s.count)
    elif Event.User in pkey.events:
      modifyKQueue(s, uint(fdi), EVFILT_READ, EV_DELETE, 0, 0, nil)
      ? flushKQueue(s)
      dec(s.count)

  clearKey(pkey)
  ok()

proc unregister2*[T](s: Selector[T],
                     event: SelectEvent): Result[void, OSErrorCode] =
  const NotRegisteredMessage = "Event is not registered in the selector!"
  let fdi = int(event.rfd)
  doAssert(fdi < s.numFD, NotRegisteredMessage)
  var pkey = addr(s.fds[fdi])
  doAssert(pkey.ident != InvalidIdent, NotRegisteredMessage)
  doAssert(Event.User in pkey.events)
  modifyKQueue(s, uint(fdi), EVFILT_READ, EV_DELETE, 0, 0, nil)
  ? flushKQueue(s)
  clearKey(pkey)
  dec(s.count)
  ok()

proc selectInto2*[T](s: Selector[T], timeout: int,
                     readyKeys: var openArray[ReadyKey]
                     ): Result[int, OSErrorCode] =
  var
    tv: Timespec
    queueEvents: array[asyncEventsCount, KEvent]

  verifySelectParams(timeout)

  let
    ptrTimeout =
      if timeout != -1:
        if timeout >= 1000:
          tv.tv_sec = posix.Time(timeout div 1_000)
          tv.tv_nsec = (timeout %% 1_000) * 1_000_000
        else:
          tv.tv_sec = posix.Time(0)
          tv.tv_nsec = timeout * 1_000_000
        addr tv
      else:
        nil
    maxEventsCount = cint(min(asyncEventsCount, len(readyKeys)))
    eventsCount =
      block:
        var res = 0
        while true:
          res = kevent(s.kqFD, nil, cint(0), addr(queueEvents[0]),
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
    let kevent = addr(queueEvents[i])
    var rkey = ReadyKey(fd: int(kevent.ident), events: {})

    if (kevent.flags and EV_ERROR) != 0:
      rkey.events.incl(Event.Error)
      rkey.errorCode = OSErrorCode(kevent.data)

    if (kevent.flags and EV_EOF) != 0:
      rkey.events.incl(Event.Error)
      rkey.errorCode = OSErrorCode(ECONNRESET)

    case kevent.filter
    of EVFILT_READ:
      var pkey = addr(s.fds[int(kevent.ident)])
      if Event.User in pkey.events:
        var data: uint64 = 0
        if osdefs.read(cint(kevent.ident), addr data,
                       sizeof(uint64)) != sizeof(uint64):
          let errorCode = osLastError()
          if errorCode == EAGAIN:
            # someone already consumed event data
            continue
          else:
            rkey.events.incl(Event.Error)
            rkey.errorCode = errorCode
        rkey.events.incl(Event.User)
      else:
        rkey.events.incl(Event.Read)
    of EVFILT_WRITE:
      rkey.events.incl(Event.Write)
    of EVFILT_TIMER:
      var pkey = addr(s.fds[int(kevent.ident)])
      rkey.events.incl(Event.Timer)
      if Event.Oneshot in pkey.events:
        # we will not clear key until it will be unregistered, so
        # application can obtain data, but we will decrease counter,
        # because kqueue is empty.
        dec(s.count)
        # we are marking key with `Finished` event, to avoid double decrease.
        pkey.events.incl(Event.Finished)
    of EVFILT_VNODE:
      rkey.events.incl(Event.Vnode)
      if (kevent.fflags and NOTE_DELETE) != 0:
        rkey.events.incl(Event.VnodeDelete)
      if (kevent.fflags and NOTE_WRITE) != 0:
        rkey.events.incl(Event.VnodeWrite)
      if (kevent.fflags and NOTE_EXTEND) != 0:
        rkey.events.incl(Event.VnodeExtend)
      if (kevent.fflags and NOTE_ATTRIB) != 0:
        rkey.events.incl(Event.VnodeAttrib)
      if (kevent.fflags and NOTE_LINK) != 0:
        rkey.events.incl(Event.VnodeLink)
      if (kevent.fflags and NOTE_RENAME) != 0:
        rkey.events.incl(Event.VnodeRename)
      if (kevent.fflags and NOTE_REVOKE) != 0:
        rkey.events.incl(Event.VnodeRevoke)
    of EVFILT_SIGNAL:
      rkey.fd = cast[int](kevent.udata)
      rkey.events.incl(Event.Signal)
    of EVFILT_PROC:
      let fd = cast[int](kevent.udata)
      var pkey = addr(s.fds[fd])
      rkey.fd = fd
      rkey.events.incl(Event.Process)
      pkey.events.incl(Event.Finished)
      # we will not clear key, until it will be unregistered, so
      # application can obtain data, but we will decrease counter,
      # because kqueue is empty.
      dec(s.count)
    else:
      doAssert(true, "Unsupported kqueue filter in the selector!")

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
  int(s.kqFD)

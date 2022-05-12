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
import "."/chronos/osdefs
import std/kqueue
import stew/results
export results

const
  # Maximum number of events that can be returned.
  MAX_KQUEUE_EVENTS = 64
  # SIG_IGN and SIG_DFL declared in posix.nim as variables, but we need them
  # to be constants and GC-safe.
  SIG_DFL = cast[proc(x: cint) {.raises: [],noconv,gcsafe.}](0)
  SIG_IGN = cast[proc(x: cint) {.raises: [],noconv,gcsafe.}](1)

when defined(macosx) or defined(freebsd) or defined(dragonfly):
  when defined(macosx):
    const MAX_DESCRIPTORS_ID = 29 # KERN_MAXFILESPERPROC (MacOS)
  else:
    const MAX_DESCRIPTORS_ID = 27 # KERN_MAXFILESPERPROC (FreeBSD)
  proc sysctl(name: ptr cint, namelen: cuint, oldp: pointer,
              oldplen: ptr csize_t, newp: pointer, newplen: csize_t): cint {.
       importc: "sysctl",header: """#include <sys/types.h>
                                    #include <sys/sysctl.h>"""}
elif defined(netbsd) or defined(openbsd):
  # OpenBSD and NetBSD don't have KERN_MAXFILESPERPROC, so we are using
  # KERN_MAXFILES, because KERN_MAXFILES is always bigger,
  # than KERN_MAXFILESPERPROC.
  const MAX_DESCRIPTORS_ID = 7 # KERN_MAXFILES
  proc sysctl(name: ptr cint, namelen: cuint, oldp: pointer,
              oldplen: ptr csize_t, newp: pointer, newplen: csize_t): cint {.
       importc: "sysctl",header: """#include <sys/param.h>
                                    #include <sys/sysctl.h>"""}

when hasThreadSupport:
  type
    SelectorImpl[T] = object
      kqFD: cint
      maxFD: int
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
      maxFD: int
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

proc getUnique[T](s: Selector[T]): Result[int, OSErrorCode] =
  # we create duplicated handles to get unique indexes for our `fds` array.
  let res = posix.fcntl(s.sock, F_DUPFD, s.sock)
  if res == -1:
    err(osLastError())
  else:
    ok(res)

proc new*(t: typedesc[Selector],
          T: typedesc): Result[Selector[T], OSErrorCode] =
  var
    maxFD = cint(0)
    size = csize_t(sizeof(cint))
    namearr = [cint(1), cint(MAX_DESCRIPTORS_ID)]

  if sysctl(addr(namearr[0]), 2, cast[pointer](addr maxFD), addr size,
            nil, 0) != 0:
    return err(osLastError())

  var kqFD = kqueue()
  if kqFD < 0:
    return err(osLastError())

  # we allocating empty socket to duplicate it handle in future, to get unique
  # indexes for `fds` array. This is needed to properly identify
  # {Event.Timer, Event.Signal, Event.Process} events.
  let usock = osdefs.socket(osdefs.AF_INET, osdefs.SOCK_STREAM,
                            osdefs.IPPROTO_TCP).cint
  if usock == -1:
    let err = osLastError()
    discard osdefs.close(kqFD)
    return err(err)

  var selector =
    when hasThreadSupport:
      var res = cast[Selector[T]](allocShared0(sizeof(SelectorImpl[T])))
      res.fds = allocSharedArray[SelectorKey[T]](maxFD)
      res.changes = allocSharedArray[KEvent](MAX_KQUEUE_EVENTS)
      res.changesSize = MAX_KQUEUE_EVENTS
      initLock(res.changesLock)
      res
    else:
      var res = Selector[T]()
      res.fds = newSeq[SelectorKey[T]](maxFD)
      res.changes = newSeqOfCap[KEvent](MAX_KQUEUE_EVENTS)
      res

  for i in 0 ..< maxFD:
    selector.fds[i].ident = InvalidIdent

  selector.sock = usock
  selector.kqFD = kqFD
  selector.maxFD = int(maxFD)
  ok(selector)

proc close2*[T](s: Selector[T]): Result[void, OSErrorCode] =
  let
    kqFD = s.kqFD
    sockFD = s.sock

  when hasThreadSupport:
    deinitLock(s.changesLock)
    deallocSharedArray(s.fds)
    deallocShared(cast[pointer](s))

  if osdefs.close(sockFD) != 0:
    discard osdefs.close(kqFD)
    err(osLastError())
  else:
    if osdefs.close(kqFD) != 0:
      err(osLastError())
    else:
      ok()

proc setSocketFlags(s: cint,
                    nonblock, cloexec: bool): Result[void, OSErrorCode] =
  if nonblock:
    let flags = osdefs.fcntl(s, osdefs.F_GETFL)
    if flags == -1:
      return err(osLastError())
    let value = flags or osdefs.O_NONBLOCK
    if osdefs.fcntl(s, osdefs.F_SETFL, value) == -1:
      return err(osLastError())
  if cloexec:
    let flags = osdefs.fcntl(s, osdefs.F_GETFD)
    if flags == -1:
      return err(osLastError())
    let value = flags or osdefs.FD_CLOEXEC
    if osdefs.fcntl(s, osdefs.F_SETFD, value) == -1:
      return err(osLastError())
  ok()

proc new*(t: typedesc[SelectEvent]): Result[SelectEvent, OSErrorCode] =
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

    let res1 = setSocketFlags(fds[0], true, true)
    if res1.isErr():
      discard osdefs.close(fds[0])
      discard osdefs.close(fds[1])
      return err(res1.error())
    let res2 = setSocketFlags(fds[1], true, true)
    if res2.isErr():
      discard osdefs.close(fds[0])
      discard osdefs.close(fds[1])
      return err(res2.error())

    var res = cast[SelectEvent](allocShared0(sizeof(SelectEventImpl)))
    res.rfd = fds[0]
    res.wfd = fds[1]
    ok(res)

proc trigger2*(ev: SelectEvent): Result[void, OSErrorCode] =
  var data: uint64 = 1
  if osdefs.write(ev.wfd, addr data, sizeof(uint64)) != sizeof(uint64):
    err(osLastError())
  else:
    ok()

proc close2*(ev: SelectEvent): Result[void, OSErrorCode] =
  let
    rfd = ev.rfd
    wfd = ev.wfd
  deallocShared(cast[pointer](ev))

  if osdefs.close(rfd) != 0:
    discard osdefs.close(wfd)
    err(osLastError())
  else:
    if osdefs.close(wfd) != 0:
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

  proc flushKQueue[T](s: Selector[T]): Result[void, OSErrorCode] =
    mixin withChangeLock
    s.withChangeLock():
      if s.changesLength > 0:
        if kevent(s.kqFD, addr(s.changes[0]), cint(s.changesLength),
                  nil, 0, nil) == -1:
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

  proc flushKQueue[T](s: Selector[T]): Result[void, OSErrorCode] =
    let length = cint(len(s.changes))
    if length > 0:
      if kevent(s.kqFD, addr(s.changes[0]), length,
                nil, 0, nil) == -1:
        return err(osLastError())
      s.changes.setLen(0)
    ok()

proc registerHandle2*[T](s: Selector[T], fd: int | SocketHandle,
                         events: set[Event],
                         data: T): Result[void, OSErrorCode] =
  let fdi = int(fd)
  if fdi >= s.maxFD:
    return err(OSErrorCode(osdefs.EMFILE))
  doAssert(s.fds[fdi].ident == InvalidIdent)
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

proc updateHandle2*[T](s: Selector[T], fd: int | SocketHandle,
                       events: set[Event]): Result[void, OSErrorCode] =
  let maskEvents = {Event.Timer, Event.Signal, Event.Process, Event.Vnode,
                    Event.User, Event.Oneshot, Event.Error}
  let fdi = int(fd)
  doAssert(fdi < s.maxFD,
           "Descriptor [" & $fdi & " is not registered in the queue!")
  var pkey = addr(s.fds[fdi])
  doAssert(pkey.ident != InvalidIdent,
           "Descriptor [" & $fdi & " is not registered in the queue!")
  doAssert(pkey.events * maskEvents == {})

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
                       data: T): Result[int, OSErrorCode] =
  let fdi = ? getUnique(s)
  if fdi >= s.maxFD:
    return err(OSErrorCode(osdefs.EMFILE))
  doAssert(s.fds[fdi].ident == InvalidIdent)

  let events = if oneshot: {Event.Timer, Event.Oneshot} else: {Event.Timer}
  let flags: cushort = if oneshot: EV_ONESHOT or EV_ADD else: EV_ADD

  s.setKey(fdi, events, 0, data)

  # EVFILT_TIMER on Open/Net(BSD) has granularity of only milliseconds,
  # but MacOS and FreeBSD allow use `0` as `fflags` to use milliseconds
  # too
  modifyKQueue(s, uint(fdi), EVFILT_TIMER, flags, 0, cint(timeout), nil)
  ? flushKQueue(s)
  inc(s.count)
  ok(fdi)

proc registerSignal*[T](s: Selector[T], signal: int,
                        data: T): Result[int, OSErrorCode] =
  let fdi = ? getUnique(s)
  if fdi >= s.maxFD:
    return err(OSErrorCode(osdefs.EMFILE))
  doAssert(s.fds[fdi].ident == InvalidIdent)

  s.setKey(fdi, {Event.Signal}, signal, data)
  var nmask, omask: Sigset
  discard sigemptyset(nmask)
  discard sigemptyset(omask)
  discard sigaddset(nmask, cint(signal))

  when hasThreadSupport:
    if posix.pthread_sigmask(SIG_BLOCK, nmask, omask) == -1:
      return err(osLastError())
  else:
    if posix.sigprocmask(SIG_BLOCK, nmask, omask) == -1:
      return err(osLastError())

  # to be compatible with linux semantic we need to "eat" signals
  posix.signal(cint(signal), SIG_IGN)

  modifyKQueue(s, uint(signal), EVFILT_SIGNAL, EV_ADD, 0, 0, cast[pointer](fdi))
  ? flushKQueue(s)
  inc(s.count)
  ok(fdi)

proc registerProcess*[T](s: Selector[T], pid: int,
                         data: T): Result[int, OSErrorCode] =
  let fdi = ? getUnique(s)
  if fdi >= s.maxFD:
    return err(OSErrorCode(osdefs.EMFILE))
  doAssert(s.fds[fdi].ident == InvalidIdent)

  var kflags: cushort = EV_ONESHOT or EV_ADD
  setKey(s, fdi, {Event.Process, Event.Oneshot}, pid, data)

  modifyKQueue(s, uint(pid), EVFILT_PROC, kflags, NOTE_EXIT, 0,
               cast[pointer](fdi))
  ? flushKQueue(s)
  inc(s.count)
  ok(fdi)

proc registerEvent2*[T](s: Selector[T], ev: SelectEvent,
                        data: T): Result[void, OSErrorCode] =
  let fdi = int(ev.rfd)
  doAssert(s.fds[fdi].ident == InvalidIdent,
           "Event is already registered in the queue!")
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
                        data: T): Result[void, OSErrorCode] =
  let fdi = int(fd)
  setKey(s, fdi, {Event.Vnode} + events, 0, data)
  let fflags = processVnodeEvents(events)

  modifyKQueue(s, uint(fdi), EVFILT_VNODE, EV_ADD or EV_CLEAR, fflags, 0, nil)
  ? flushKQueue(s)
  inc(s.count)
  ok()

proc unregister2*[T](s: Selector[T],
                     fd: int|SocketHandle): Result[void, OSErrorCode] =
  let fdi = int(fd)
  doAssert(fdi < s.maxFD,
           "Descriptor [" & $fdi & "] is not registered in the queue")
  var pkey = addr(s.fds[fdi])
  doAssert(pkey.ident != InvalidIdent,
           "Descriptor [" & $fdi & "] is not registered in the queue!")

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
      if osdefs.close(cint(pkey.ident)) != 0:
        return err(osLastError())
    elif Event.Signal in pkey.events:
      var nmask, omask: Sigset
      let signal = cint(pkey.param)
      discard sigemptyset(nmask)
      discard sigemptyset(omask)
      discard sigaddset(nmask, signal)
      when hasThreadSupport:
        if posix.pthread_sigmask(SIG_UNBLOCK, nmask, omask) == -1:
          return err(osLastError())
      else:
        if posix.sigprocmask(SIG_UNBLOCK, nmask, omask) == -1:
          return err(osLastError())
      osdefs.signal(signal, SIG_DFL)
      modifyKQueue(s, uint(pkey.param), EVFILT_SIGNAL, EV_DELETE, 0, 0, nil)
      ? flushKQueue(s)
      dec(s.count)
      if osdefs.close(cint(pkey.ident)) != 0:
        return err(osLastError())
    elif Event.Process in pkey.events:
      if Event.Finished notin pkey.events:
        modifyKQueue(s, uint(pkey.param), EVFILT_PROC, EV_DELETE, 0, 0, nil)
        ? flushKQueue(s)
        dec(s.count)
      if osdefs.close(cint(pkey.ident)) != 0:
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
  const NotRegisteredMessage = "Event is not registered in the queue!"
  let fdi = int(event.rfd)
  doAssert(fdi < s.maxFD, NotRegisteredMessage)
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
    queueEvents: array[MAX_KQUEUE_EVENTS, KEvent]

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
    maxEventsCount = cint(min(MAX_KQUEUE_EVENTS, len(readyKeys)))
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
            rkey.errorCode = errorCode
            rkey.events.incl(Event.Error)
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
      doAssert(true, "Unsupported kqueue filter in the queue!")

    readyKeys[k] = rkey
    inc(k)

  ok(k)

proc select2*[T](s: Selector[T],
                 timeout: int): Result[seq[ReadyKey], OSErrorCode] =
  var res = newSeq[ReadyKey](MAX_KQUEUE_EVENTS)
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
  let res = registerHandle2(s, fd, events, data)
  if res.isErr():
    raiseIOSelectorsError(res.error())

proc updateHandle*[T](s: Selector[T], fd: int | SocketHandle,
                      events: set[Event]) {.
     raises: [Defect, IOSelectorsException].} =
  let res = updateHandle2(s, fd, events)
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
  let fdi = fd.int
  fdi < s.maxFD and s.fds[fd.int].ident != InvalidIdent

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
  return s.kqFD.int

#
#             Chronos Datagram Transport
#             (c) Copyright 2018-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

{.push raises: [Defect].}

import std/[net, nativesockets, os, deques]
import ".."/[selectors2, asyncloop, handles]
import ./common

when defined(windows) or defined(nimdoc):
  import winlean
else:
  import posix
  when (defined(linux) and not defined(android)) and defined(amd64):
    const IP_MULTICAST_TTL: cint = 33
  else:
    var IP_MULTICAST_TTL* {.importc: "IP_MULTICAST_TTL",
                            header: "<netinet/in.h>".}: cint

type
  VectorKind = enum
    WithoutAddress, WithAddress

  GramVector = object
    kind: VectorKind            # Vector kind (with address/without address)
    address: TransportAddress   # Destination address
    buf: pointer                # Writer buffer pointer
    buflen: int                 # Writer buffer size
    writer: Future[void]        # Writer vector completion Future

  DatagramCallback* = proc(transp: DatagramTransport,
                           remote: TransportAddress): Future[void] {.
                      gcsafe, raises: [Defect].}

  DatagramTransport* = ref object of RootRef
    fd*: AsyncFD                    # File descriptor
    state: set[TransportState]      # Current Transport state
    flags: set[ServerFlags]         # Flags
    buffer: seq[byte]               # Reading buffer
    buflen: int                     # Reading buffer effective size
    error: ref CatchableError       # Current error
    queue: Deque[GramVector]        # Writer queue
    local: TransportAddress         # Local address
    remote: TransportAddress        # Remote address
    udata*: pointer                 # User-driven pointer
    function: DatagramCallback      # Receive data callback
    future: Future[void]            # Transport's life future
    raddr: Sockaddr_storage         # Reader address storage
    ralen: SockLen                  # Reader address length
    waddr: Sockaddr_storage         # Writer address storage
    walen: SockLen                  # Writer address length
    when defined(windows):
      rovl: CustomOverlapped          # Reader OVERLAPPED structure
      wovl: CustomOverlapped          # Writer OVERLAPPED structure
      rflag: int32                    # Reader flags storage
      rwsabuf: TWSABuf                # Reader WSABUF structure
      wwsabuf: TWSABuf                # Writer WSABUF structure

  DgramTransportTracker* = ref object of TrackerBase
    opened*: int64
    closed*: int64

const
  DgramTransportTrackerName = "datagram.transport"

proc remoteAddress*(transp: DatagramTransport): TransportAddress {.
    raises: [Defect, TransportOsError].} =
  ## Returns ``transp`` remote socket address.
  if transp.remote.family == AddressFamily.None:
    var saddr: Sockaddr_storage
    var slen = SockLen(sizeof(saddr))
    if getpeername(SocketHandle(transp.fd), cast[ptr SockAddr](addr saddr),
                   addr slen) != 0:
      raiseTransportOsError(osLastError())
    fromSAddr(addr saddr, slen, transp.remote)
  result = transp.remote

proc localAddress*(transp: DatagramTransport): TransportAddress {.
    raises: [Defect, TransportOsError].} =
  ## Returns ``transp`` local socket address.
  if transp.local.family == AddressFamily.None:
    var saddr: Sockaddr_storage
    var slen = SockLen(sizeof(saddr))
    if getsockname(SocketHandle(transp.fd), cast[ptr SockAddr](addr saddr),
                   addr slen) != 0:
      raiseTransportOsError(osLastError())
    fromSAddr(addr saddr, slen, transp.local)
  result = transp.local

template setReadError(t, e: untyped) =
  (t).state.incl(ReadError)
  (t).error = getTransportOsError(e)

proc setupDgramTransportTracker(): DgramTransportTracker {.
     gcsafe, raises: [Defect].}

proc getDgramTransportTracker(): DgramTransportTracker {.inline.} =
  result = cast[DgramTransportTracker](getTracker(DgramTransportTrackerName))
  if isNil(result):
    result = setupDgramTransportTracker()

proc dumpTransportTracking(): string {.gcsafe.} =
  var tracker = getDgramTransportTracker()
  result = "Opened transports: " & $tracker.opened & "\n" &
           "Closed transports: " & $tracker.closed

proc leakTransport(): bool {.gcsafe.} =
  var tracker = getDgramTransportTracker()
  result = (tracker.opened != tracker.closed)

proc trackDgram(t: DatagramTransport) {.inline.} =
  var tracker = getDgramTransportTracker()
  inc(tracker.opened)

proc untrackDgram(t: DatagramTransport) {.inline.}  =
  var tracker = getDgramTransportTracker()
  inc(tracker.closed)

proc setupDgramTransportTracker(): DgramTransportTracker {.gcsafe.} =
  result = new DgramTransportTracker
  result.opened = 0
  result.closed = 0
  result.dump = dumpTransportTracking
  result.isLeaked = leakTransport
  addTracker(DgramTransportTrackerName, result)

when defined(nimdoc):
  proc newDatagramTransportCommon(cbproc: DatagramCallback,
                                  remote: TransportAddress,
                                  local: TransportAddress,
                                  sock: AsyncFD,
                                  flags: set[ServerFlags],
                                  udata: pointer,
                                  child: DatagramTransport,
                                  bufferSize: int,
                                  ttl: int): DatagramTransport {.
      raises: [Defect, CatchableError].} =
    discard

  proc resumeRead(transp: DatagramTransport) {.inline.} =
    discard

  proc resumeWrite(transp: DatagramTransport) {.inline.} =
    discard

elif defined(windows):
  template setWriterWSABuffer(t, v: untyped) =
    (t).wwsabuf.buf = cast[cstring](v.buf)
    (t).wwsabuf.len = cast[int32](v.buflen)

  const
    IOC_VENDOR = DWORD(0x18000000)
    SIO_UDP_CONNRESET = DWORD(winlean.IOC_IN) or IOC_VENDOR or DWORD(12)
    IPPROTO_IP = DWORD(0)
    IP_TTL = DWORD(4)

  proc writeDatagramLoop(udata: pointer) =
    var bytesCount: int32
    var ovl = cast[PtrCustomOverlapped](udata)
    var transp = cast[DatagramTransport](ovl.data.udata)
    while len(transp.queue) > 0:
      if WritePending in transp.state:
        ## Continuation
        transp.state.excl(WritePending)
        let err = transp.wovl.data.errCode
        let vector = transp.queue.popFirst()
        if err == OSErrorCode(-1):
          if not(vector.writer.finished()):
            vector.writer.complete()
        elif int(err) == ERROR_OPERATION_ABORTED:
          # CancelIO() interrupt
          transp.state.incl(WritePaused)
          if not(vector.writer.finished()):
            vector.writer.complete()
        else:
          transp.state.incl({WritePaused, WriteError})
          if not(vector.writer.finished()):
            vector.writer.fail(getTransportOsError(err))
      else:
        ## Initiation
        transp.state.incl(WritePending)
        let fd = SocketHandle(transp.fd)
        var vector = transp.queue.popFirst()
        transp.setWriterWSABuffer(vector)
        var ret: cint
        if vector.kind == WithAddress:
          var fixedAddress = windowsAnyAddressFix(vector.address)
          toSAddr(fixedAddress, transp.waddr, transp.walen)
          ret = WSASendTo(fd, addr transp.wwsabuf, DWORD(1), addr bytesCount,
                          DWORD(0), cast[ptr SockAddr](addr transp.waddr),
                          cint(transp.walen),
                          cast[POVERLAPPED](addr transp.wovl), nil)
        else:
          ret = WSASend(fd, addr transp.wwsabuf, DWORD(1), addr bytesCount,
                        DWORD(0), cast[POVERLAPPED](addr transp.wovl), nil)
        if ret != 0:
          let err = osLastError()
          if int(err) == ERROR_OPERATION_ABORTED:
            # CancelIO() interrupt
            transp.state.excl(WritePending)
            transp.state.incl(WritePaused)
            if not(vector.writer.finished()):
              vector.writer.complete()
          elif int(err) == ERROR_IO_PENDING:
            transp.queue.addFirst(vector)
          else:
            transp.state.excl(WritePending)
            transp.state.incl({WritePaused, WriteError})
            if not(vector.writer.finished()):
              vector.writer.fail(getTransportOsError(err))
        else:
          transp.queue.addFirst(vector)
        break

    if len(transp.queue) == 0:
      transp.state.incl(WritePaused)

  proc readDatagramLoop(udata: pointer) =
    var
      bytesCount: int32
      raddr: TransportAddress
    var ovl = cast[PtrCustomOverlapped](udata)
    var transp = cast[DatagramTransport](ovl.data.udata)
    while true:
      if ReadPending in transp.state:
        ## Continuation
        transp.state.excl(ReadPending)
        let err = transp.rovl.data.errCode
        if err == OSErrorCode(-1):
          let bytesCount = transp.rovl.data.bytesCount
          if bytesCount == 0:
            transp.state.incl({ReadEof, ReadPaused})
          fromSAddr(addr transp.raddr, transp.ralen, raddr)
          transp.buflen = bytesCount
          asyncCheck transp.function(transp, raddr)
        elif int(err) == ERROR_OPERATION_ABORTED:
          # CancelIO() interrupt or closeSocket() call.
          transp.state.incl(ReadPaused)
          if ReadClosed in transp.state and not(transp.future.finished()):
            # Stop tracking transport
            untrackDgram(transp)
            # If `ReadClosed` present, then close(transport) was called.
            transp.future.complete()
            GC_unref(transp)
          break
        else:
          transp.setReadError(err)
          transp.state.incl(ReadPaused)
          transp.buflen = 0
          asyncCheck transp.function(transp, raddr)
      else:
        ## Initiation
        if transp.state * {ReadEof, ReadClosed, ReadError} == {}:
          transp.state.incl(ReadPending)
          let fd = SocketHandle(transp.fd)
          transp.rflag = 0
          transp.ralen = SockLen(sizeof(Sockaddr_storage))
          let ret = WSARecvFrom(fd, addr transp.rwsabuf, DWORD(1),
                                addr bytesCount, addr transp.rflag,
                                cast[ptr SockAddr](addr transp.raddr),
                                cast[ptr cint](addr transp.ralen),
                                cast[POVERLAPPED](addr transp.rovl), nil)
          if ret != 0:
            let err = osLastError()
            if int(err) == ERROR_OPERATION_ABORTED:
              # CancelIO() interrupt
              transp.state.excl(ReadPending)
              transp.state.incl(ReadPaused)
            elif int(err) == common.WSAECONNRESET:
              transp.state.excl(ReadPending)
              transp.state.incl({ReadPaused, ReadEof})
              break
            elif int(err) == ERROR_IO_PENDING:
              discard
            else:
              transp.state.excl(ReadPending)
              transp.state.incl(ReadPaused)
              transp.setReadError(err)
              transp.buflen = 0
              asyncCheck transp.function(transp, raddr)
        else:
          # Transport closure happens in callback, and we not started new
          # WSARecvFrom session.
          if ReadClosed in transp.state and not(transp.future.finished()):
            # Stop tracking transport
            untrackDgram(transp)
            transp.future.complete()
            GC_unref(transp)
        break

  proc resumeRead(transp: DatagramTransport) {.inline.} =
    transp.state.excl(ReadPaused)
    readDatagramLoop(cast[pointer](addr transp.rovl))

  proc resumeWrite(transp: DatagramTransport) {.inline.} =
    transp.state.excl(WritePaused)
    writeDatagramLoop(cast[pointer](addr transp.wovl))

  proc newDatagramTransportCommon(cbproc: DatagramCallback,
                                  remote: TransportAddress,
                                  local: TransportAddress,
                                  sock: AsyncFD,
                                  flags: set[ServerFlags],
                                  udata: pointer,
                                  child: DatagramTransport,
                                  bufferSize: int,
                                  ttl: int): DatagramTransport {.
      raises: [Defect, CatchableError].} =
    var localSock: AsyncFD
    doAssert(remote.family == local.family)
    doAssert(not isNil(cbproc))
    doAssert(remote.family in {AddressFamily.IPv4, AddressFamily.IPv6})

    if isNil(child):
      result = DatagramTransport()
    else:
      result = child

    if sock == asyncInvalidSocket:
      localSock = createAsyncSocket(local.getDomain(), SockType.SOCK_DGRAM,
                                    Protocol.IPPROTO_UDP)

      if localSock == asyncInvalidSocket:
        raiseTransportOsError(osLastError())
    else:
      if not setSocketBlocking(SocketHandle(sock), false):
        raiseTransportOsError(osLastError())
      localSock = sock
      register(localSock)

    ## Apply ServerFlags here
    if ServerFlags.ReuseAddr in flags:
      if not setSockOpt(localSock, SOL_SOCKET, SO_REUSEADDR, 1):
        let err = osLastError()
        if sock == asyncInvalidSocket:
          closeSocket(localSock)
        raiseTransportOsError(err)

    if ServerFlags.Broadcast in flags:
      if not setSockOpt(localSock, SOL_SOCKET, SO_BROADCAST, 1):
        let err = osLastError()
        if sock == asyncInvalidSocket:
          closeSocket(localSock)
        raiseTransportOsError(err)

      if ttl > 0:
        if not setSockOpt(localSock, IPPROTO_IP, IP_TTL, DWORD(ttl)):
          let err = osLastError()
          if sock == asyncInvalidSocket:
            closeSocket(localSock)
          raiseTransportOsError(err)

    ## Fix for Q263823.
    var bytesRet: DWORD
    var bval = WINBOOL(0)
    if WSAIoctl(SocketHandle(localSock), SIO_UDP_CONNRESET, addr bval,
                sizeof(WINBOOL).DWORD, nil, DWORD(0),
                addr bytesRet, nil, nil) != 0:
      raiseTransportOsError(osLastError())

    if local.family != AddressFamily.None:
      var saddr: Sockaddr_storage
      var slen: SockLen
      toSAddr(local, saddr, slen)

      if bindAddr(SocketHandle(localSock), cast[ptr SockAddr](addr saddr),
                  slen) != 0:
        let err = osLastError()
        if sock == asyncInvalidSocket:
          closeSocket(localSock)
        raiseTransportOsError(err)
    else:
      var saddr: Sockaddr_storage
      var slen: SockLen
      saddr.ss_family = type(saddr.ss_family)(local.getDomain())
      if bindAddr(SocketHandle(localSock), cast[ptr SockAddr](addr saddr),
                  slen) != 0:
        let err = osLastError()
        if sock == asyncInvalidSocket:
          closeSocket(localSock)
        raiseTransportOsError(err)

    if remote.port != Port(0):
      var fixedAddress = windowsAnyAddressFix(remote)
      var saddr: Sockaddr_storage
      var slen: SockLen
      toSAddr(fixedAddress, saddr, slen)
      if connect(SocketHandle(localSock), cast[ptr SockAddr](addr saddr),
                 slen) != 0:
        let err = osLastError()
        if sock == asyncInvalidSocket:
          closeSocket(localSock)
        raiseTransportOsError(err)
      result.remote = fixedAddress

    result.fd = localSock
    result.function = cbproc
    result.buffer = newSeq[byte](bufferSize)
    result.queue = initDeque[GramVector]()
    result.udata = udata
    result.state = {WritePaused}
    result.future = newFuture[void]("datagram.transport")
    result.rovl.data = CompletionData(cb: readDatagramLoop,
                                      udata: cast[pointer](result))
    result.wovl.data = CompletionData(cb: writeDatagramLoop,
                                      udata: cast[pointer](result))
    result.rwsabuf = TWSABuf(buf: cast[cstring](addr result.buffer[0]),
                             len: int32(len(result.buffer)))
    GC_ref(result)
    # Start tracking transport
    trackDgram(result)
    if NoAutoRead notin flags:
      result.resumeRead()
    else:
      result.state.incl(ReadPaused)

else:
  # Linux/BSD/MacOS part

  proc readDatagramLoop(udata: pointer) {.raises: Defect.}=
    var raddr: TransportAddress
    doAssert(not isNil(udata))
    let transp = cast[DatagramTransport](udata)
    let fd = SocketHandle(transp.fd)
    if int(fd) == 0:
      ## This situation can be happen, when there events present
      ## after transport was closed.
      return
    if ReadClosed in transp.state:
      transp.state.incl({ReadPaused})
    else:
      while true:
        transp.ralen = SockLen(sizeof(Sockaddr_storage))
        var res = posix.recvfrom(fd, addr transp.buffer[0],
                                 cint(len(transp.buffer)), cint(0),
                                 cast[ptr SockAddr](addr transp.raddr),
                                 addr transp.ralen)
        if res >= 0:
          fromSAddr(addr transp.raddr, transp.ralen, raddr)
          transp.buflen = res
          asyncCheck transp.function(transp, raddr)
        else:
          let err = osLastError()
          if int(err) == EINTR:
            continue
          else:
            transp.buflen = 0
            transp.setReadError(err)
            asyncCheck transp.function(transp, raddr)
        break

  proc writeDatagramLoop(udata: pointer) =
    var res: int
    doAssert(not isNil(udata))
    var transp = cast[DatagramTransport](udata)
    let fd = SocketHandle(transp.fd)
    if int(fd) == 0:
      ## This situation can be happen, when there events present
      ## after transport was closed.
      return
    if WriteClosed in transp.state:
      transp.state.incl({WritePaused})
    else:
      if len(transp.queue) > 0:
        var vector = transp.queue.popFirst()
        while true:
          if vector.kind == WithAddress:
            toSAddr(vector.address, transp.waddr, transp.walen)
            res = posix.sendto(fd, vector.buf, vector.buflen, MSG_NOSIGNAL,
                               cast[ptr SockAddr](addr transp.waddr),
                               transp.walen)
          elif vector.kind == WithoutAddress:
            res = posix.send(fd, vector.buf, vector.buflen, MSG_NOSIGNAL)
          if res >= 0:
            if not(vector.writer.finished()):
              vector.writer.complete()
          else:
            let err = osLastError()
            if int(err) == EINTR:
              continue
            else:
              if not(vector.writer.finished()):
                vector.writer.fail(getTransportOsError(err))
          break
      else:
        transp.state.incl(WritePaused)
        try:
          transp.fd.removeWriter()
        except IOSelectorsException as exc:
          raiseAsDefect exc, "removeWriter"
        except ValueError as exc:
          raiseAsDefect exc, "removeWriter"

  proc resumeWrite(transp: DatagramTransport) {.inline.} =
    transp.state.excl(WritePaused)
    try:
      addWriter(transp.fd, writeDatagramLoop, cast[pointer](transp))
    except IOSelectorsException as exc:
      raiseAsDefect exc, "addWriter"
    except ValueError as exc:
      raiseAsDefect exc, "addWriter"

  proc resumeRead(transp: DatagramTransport) {.inline.} =
    transp.state.excl(ReadPaused)
    try:
      addReader(transp.fd, readDatagramLoop, cast[pointer](transp))
    except IOSelectorsException as exc:
      raiseAsDefect exc, "addReader"
    except ValueError as exc:
      raiseAsDefect exc, "addReader"

  proc newDatagramTransportCommon(cbproc: DatagramCallback,
                                  remote: TransportAddress,
                                  local: TransportAddress,
                                  sock: AsyncFD,
                                  flags: set[ServerFlags],
                                  udata: pointer,
                                  child: DatagramTransport,
                                  bufferSize: int,
                                  ttl: int): DatagramTransport {.
      raises: [Defect, CatchableError].} =
    var localSock: AsyncFD
    doAssert(remote.family == local.family)
    doAssert(not isNil(cbproc))

    if isNil(child):
      result = DatagramTransport()
    else:
      result = child

    if sock == asyncInvalidSocket:
      var proto = Protocol.IPPROTO_UDP
      if local.family == AddressFamily.Unix:
        # `Protocol` enum is missing `0` value, so we making here cast, until
        # `Protocol` enum will not support IPPROTO_IP == 0.
        proto = cast[Protocol](0)
      localSock = createAsyncSocket(local.getDomain(), SockType.SOCK_DGRAM,
                                    proto)
      if localSock == asyncInvalidSocket:
        raiseTransportOsError(osLastError())
    else:
      if not setSocketBlocking(SocketHandle(sock), false):
        raiseTransportOsError(osLastError())
      localSock = sock
      register(localSock)

    ## Apply ServerFlags here
    if ServerFlags.ReuseAddr in flags:
      if not setSockOpt(localSock, SOL_SOCKET, SO_REUSEADDR, 1):
        let err = osLastError()
        if sock == asyncInvalidSocket:
          closeSocket(localSock)
        raiseTransportOsError(err)

    if ServerFlags.Broadcast in flags:
      if not setSockOpt(localSock, SOL_SOCKET, SO_BROADCAST, 1):
        let err = osLastError()
        if sock == asyncInvalidSocket:
          closeSocket(localSock)
        raiseTransportOsError(err)

      if ttl > 0:
        var res: bool
        if local.family == AddressFamily.IPv4:
          res = setSockOpt(localSock, posix.IPPROTO_IP, IP_MULTICAST_TTL,
                           cint(ttl))
        elif local.family == AddressFamily.IPv6:
           res = setSockOpt(localSock, posix.IPPROTO_IP, IPV6_MULTICAST_HOPS,
                            cint(ttl))
        if not res:
          let err = osLastError()
          if sock == asyncInvalidSocket:
            closeSocket(localSock)
          raiseTransportOsError(err)

    if local.family != AddressFamily.None:
      var saddr: Sockaddr_storage
      var slen: SockLen
      toSAddr(local, saddr, slen)
      if bindAddr(SocketHandle(localSock), cast[ptr SockAddr](addr saddr),
                  slen) != 0:
        let err = osLastError()
        if sock == asyncInvalidSocket:
          closeSocket(localSock)
        raiseTransportOsError(err)

    if remote.port != Port(0):
      var saddr: Sockaddr_storage
      var slen: SockLen
      toSAddr(remote, saddr, slen)
      if connect(SocketHandle(localSock), cast[ptr SockAddr](addr saddr),
                 slen) != 0:
        let err = osLastError()
        if sock == asyncInvalidSocket:
          closeSocket(localSock)
        raiseTransportOsError(err)
      result.remote = remote

    result.fd = localSock
    result.function = cbproc
    result.flags = flags
    result.buffer = newSeq[byte](bufferSize)
    result.queue = initDeque[GramVector]()
    result.udata = udata
    result.state = {WritePaused}
    result.future = newFuture[void]("datagram.transport")
    GC_ref(result)
    # Start tracking transport
    trackDgram(result)
    if NoAutoRead notin flags:
      result.resumeRead()
    else:
      result.state.incl(ReadPaused)

proc close*(transp: DatagramTransport) =
  ## Closes and frees resources of transport ``transp``.
  proc continuation(udata: pointer) {.raises: Defect.} =
    if not(transp.future.finished()):
      # Stop tracking transport
      untrackDgram(transp)
      transp.future.complete()
      GC_unref(transp)

  when defined(windows):
    if {ReadClosed, WriteClosed} * transp.state == {}:
      transp.state.incl({WriteClosed, ReadClosed})
      if ReadPaused in transp.state:
        # If readDatagramLoop() is not running we need to finish in
        # continuation step.
        closeSocket(transp.fd, continuation)
      else:
        # If readDatagramLoop() is running, it will be properly finished inside
        # of readDatagramLoop().
        closeSocket(transp.fd)
  else:
    if {ReadClosed, WriteClosed} * transp.state == {}:
      transp.state.incl({WriteClosed, ReadClosed})
      closeSocket(transp.fd, continuation)

proc newDatagramTransport*(cbproc: DatagramCallback,
                           remote: TransportAddress = AnyAddress,
                           local: TransportAddress = AnyAddress,
                           sock: AsyncFD = asyncInvalidSocket,
                           flags: set[ServerFlags] = {},
                           udata: pointer = nil,
                           child: DatagramTransport = nil,
                           bufSize: int = DefaultDatagramBufferSize,
                           ttl: int = 0
                           ): DatagramTransport {.
    raises: [Defect, CatchableError].} =
  ## Create new UDP datagram transport (IPv4).
  ##
  ## ``cbproc`` - callback which will be called, when new datagram received.
  ## ``remote`` - bind transport to remote address (optional).
  ## ``local`` - bind transport to local address (to serving incoming
  ## datagrams, optional)
  ## ``sock`` - application-driven socket to use.
  ## ``flags`` - flags that will be applied to socket.
  ## ``udata`` - custom argument which will be passed to ``cbproc``.
  ## ``bufSize`` - size of internal buffer.
  ## ``ttl`` - TTL for UDP datagram packet (only usable when flags has
  ## ``Broadcast`` option).
  result = newDatagramTransportCommon(cbproc, remote, local, sock,
                                      flags, udata, child, bufSize, ttl)

proc newDatagramTransport*[T](cbproc: DatagramCallback,
                              udata: ref T,
                              remote: TransportAddress = AnyAddress,
                              local: TransportAddress = AnyAddress,
                              sock: AsyncFD = asyncInvalidSocket,
                              flags: set[ServerFlags] = {},
                              child: DatagramTransport = nil,
                              bufSize: int = DefaultDatagramBufferSize,
                              ttl: int = 0
                              ): DatagramTransport {.
    raises: [Defect, CatchableError].} =
  var fflags = flags + {GCUserData}
  GC_ref(udata)
  result = newDatagramTransportCommon(cbproc, remote, local, sock,
                                      fflags, cast[pointer](udata),
                                      child, bufSize, ttl)

proc newDatagramTransport6*(cbproc: DatagramCallback,
                            remote: TransportAddress = AnyAddress6,
                            local: TransportAddress = AnyAddress6,
                            sock: AsyncFD = asyncInvalidSocket,
                            flags: set[ServerFlags] = {},
                            udata: pointer = nil,
                            child: DatagramTransport = nil,
                            bufSize: int = DefaultDatagramBufferSize,
                            ttl: int = 0
                            ): DatagramTransport {.
    raises: [Defect, CatchableError].} =
  ## Create new UDP datagram transport (IPv6).
  ##
  ## ``cbproc`` - callback which will be called, when new datagram received.
  ## ``remote`` - bind transport to remote address (optional).
  ## ``local`` - bind transport to local address (to serving incoming
  ## datagrams, optional)
  ## ``sock`` - application-driven socket to use.
  ## ``flags`` - flags that will be applied to socket.
  ## ``udata`` - custom argument which will be passed to ``cbproc``.
  ## ``bufSize`` - size of internal buffer.
  ## ``ttl`` - TTL for UDP datagram packet (only usable when flags has
  ## ``Broadcast`` option).
  result = newDatagramTransportCommon(cbproc, remote, local, sock,
                                      flags, udata, child, bufSize, ttl)

proc newDatagramTransport6*[T](cbproc: DatagramCallback,
                               udata: ref T,
                               remote: TransportAddress = AnyAddress6,
                               local: TransportAddress = AnyAddress6,
                               sock: AsyncFD = asyncInvalidSocket,
                               flags: set[ServerFlags] = {},
                               child: DatagramTransport = nil,
                               bufSize: int = DefaultDatagramBufferSize,
                               ttl: int = 0
                               ): DatagramTransport {.
    raises: [Defect, CatchableError].} =
  var fflags = flags + {GCUserData}
  GC_ref(udata)
  result = newDatagramTransportCommon(cbproc, remote, local, sock,
                                      fflags, cast[pointer](udata),
                                      child, bufSize, ttl)

proc join*(transp: DatagramTransport): Future[void] =
  ## Wait until the transport ``transp`` will be closed.
  var retFuture = newFuture[void]("datagram.transport.join")

  proc continuation(udata: pointer) {.gcsafe.} =
    retFuture.complete()

  proc cancel(udata: pointer) {.gcsafe.} =
    transp.future.removeCallback(continuation, cast[pointer](retFuture))

  if not(transp.future.finished()):
    transp.future.addCallback(continuation, cast[pointer](retFuture))
    retFuture.cancelCallback = cancel
  else:
    retFuture.complete()

  return retFuture

proc closeWait*(transp: DatagramTransport): Future[void] =
  ## Close transport ``transp`` and release all resources.
  transp.close()
  result = transp.join()

proc send*(transp: DatagramTransport, pbytes: pointer,
           nbytes: int): Future[void] =
  ## Send buffer with pointer ``pbytes`` and size ``nbytes`` using transport
  ## ``transp`` to remote destination address which was bounded on transport.
  var retFuture = newFuture[void]("datagram.transport.send(pointer)")
  transp.checkClosed(retFuture)
  if transp.remote.port == Port(0):
    retFuture.fail(newException(TransportError, "Remote peer not set!"))
    return retFuture
  var vector = GramVector(kind: WithoutAddress, buf: pbytes, buflen: nbytes,
                          writer: retFuture)
  transp.queue.addLast(vector)
  if WritePaused in transp.state:
    transp.resumeWrite()
  return retFuture

proc send*(transp: DatagramTransport, msg: string, msglen = -1): Future[void] =
  ## Send string ``msg`` using transport ``transp`` to remote destination
  ## address which was bounded on transport.
  var retFuture = newFutureStr[void]("datagram.transport.send(string)")
  transp.checkClosed(retFuture)
  if not isLiteral(msg):
    shallowCopy(retFuture.gcholder, msg)
  else:
    retFuture.gcholder = msg
  let length = if msglen <= 0: len(msg) else: msglen
  let vector = GramVector(kind: WithoutAddress, buf: addr retFuture.gcholder[0],
                          buflen: length,
                          writer: cast[Future[void]](retFuture))
  transp.queue.addLast(vector)
  if WritePaused in transp.state:
    transp.resumeWrite()
  return retFuture

proc send*[T](transp: DatagramTransport, msg: seq[T],
              msglen = -1): Future[void] =
  ## Send string ``msg`` using transport ``transp`` to remote destination
  ## address which was bounded on transport.
  var retFuture = newFutureSeq[void, T]("datagram.transport.send(seq)")
  transp.checkClosed(retFuture)
  if not isLiteral(msg):
    shallowCopy(retFuture.gcholder, msg)
  else:
    retFuture.gcholder = msg
  let length = if msglen <= 0: (len(msg) * sizeof(T)) else: (msglen * sizeof(T))
  let vector = GramVector(kind: WithoutAddress, buf: addr retFuture.gcholder[0],
                          buflen: length,
                          writer: cast[Future[void]](retFuture))
  transp.queue.addLast(vector)
  if WritePaused in transp.state:
    transp.resumeWrite()
  return retFuture

proc sendTo*(transp: DatagramTransport, remote: TransportAddress,
             pbytes: pointer, nbytes: int): Future[void] =
  ## Send buffer with pointer ``pbytes`` and size ``nbytes`` using transport
  ## ``transp`` to remote destination address ``remote``.
  var retFuture = newFuture[void]("datagram.transport.sendTo(pointer)")
  transp.checkClosed(retFuture)
  let vector = GramVector(kind: WithAddress, buf: pbytes, buflen: nbytes,
                          writer: retFuture, address: remote)
  transp.queue.addLast(vector)
  if WritePaused in transp.state:
    transp.resumeWrite()
  return retFuture

proc sendTo*(transp: DatagramTransport, remote: TransportAddress,
             msg: string, msglen = -1): Future[void] =
  ## Send string ``msg`` using transport ``transp`` to remote destination
  ## address ``remote``.
  var retFuture = newFutureStr[void]("datagram.transport.sendTo(string)")
  transp.checkClosed(retFuture)
  if not isLiteral(msg):
    shallowCopy(retFuture.gcholder, msg)
  else:
    retFuture.gcholder = msg
  let length = if msglen <= 0: len(msg) else: msglen
  let vector = GramVector(kind: WithAddress, buf: addr retFuture.gcholder[0],
                          buflen: length,
                          writer: cast[Future[void]](retFuture),
                          address: remote)
  transp.queue.addLast(vector)
  if WritePaused in transp.state:
    transp.resumeWrite()
  return retFuture

proc sendTo*[T](transp: DatagramTransport, remote: TransportAddress,
                msg: seq[T], msglen = -1): Future[void] =
  ## Send sequence ``msg`` using transport ``transp`` to remote destination
  ## address ``remote``.
  var retFuture = newFutureSeq[void, T]("datagram.transport.sendTo(seq)")
  transp.checkClosed(retFuture)
  if not isLiteral(msg):
    shallowCopy(retFuture.gcholder, msg)
  else:
    retFuture.gcholder = msg
  let length = if msglen <= 0: (len(msg) * sizeof(T)) else: (msglen * sizeof(T))
  let vector = GramVector(kind: WithAddress, buf: addr retFuture.gcholder[0],
                          buflen: length,
                          writer: cast[Future[void]](retFuture),
                          address: remote)
  transp.queue.addLast(vector)
  if WritePaused in transp.state:
    transp.resumeWrite()
  return retFuture

proc peekMessage*(transp: DatagramTransport, msg: var seq[byte],
                  msglen: var int) {.raises: [Defect, CatchableError].} =
  ## Get access to internal message buffer and length of incoming datagram.
  if ReadError in transp.state:
    transp.state.excl(ReadError)
    raise transp.getError()
  shallowCopy(msg, transp.buffer)
  msglen = transp.buflen

proc getMessage*(transp: DatagramTransport): seq[byte] {.
    raises: [Defect, CatchableError].} =
  ## Copy data from internal message buffer and return result.
  if ReadError in transp.state:
    transp.state.excl(ReadError)
    raise transp.getError()
  if transp.buflen > 0:
    result = newSeq[byte](transp.buflen)
    copyMem(addr result[0], addr transp.buffer[0], transp.buflen)

proc getUserData*[T](transp: DatagramTransport): T {.inline.} =
  ## Obtain user data stored in ``transp`` object.
  result = cast[T](transp.udata)

proc closed*(transp: DatagramTransport): bool {.inline.} =
  ## Returns ``true`` if transport in closed state.
  result = ({ReadClosed, WriteClosed} * transp.state != {})

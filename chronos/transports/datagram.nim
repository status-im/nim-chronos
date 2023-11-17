#
#             Chronos Datagram Transport
#             (c) Copyright 2018-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

{.push raises: [].}

import std/deques
when not(defined(windows)): import ".."/selectors2
import ".."/[asyncloop, config, osdefs, oserrno, osutils, handles]
import "."/common

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
                           async: (raises: []).}

  UnsafeDatagramCallback* = proc(transp: DatagramTransport,
                           remote: TransportAddress): Future[void] {.async.}

  DatagramTransport* = ref object of RootRef
    fd*: AsyncFD                    # File descriptor
    state: set[TransportState]      # Current Transport state
    flags: set[ServerFlags]         # Flags
    buffer: seq[byte]               # Reading buffer
    buflen: int                     # Reading buffer effective size
    error: ref TransportError       # Current error
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
      rflag: uint32                   # Reader flags storage
      rwsabuf: WSABUF                 # Reader WSABUF structure
      wwsabuf: WSABUF                 # Writer WSABUF structure

const
  DgramTransportTrackerName* = "datagram.transport"

proc remoteAddress*(transp: DatagramTransport): TransportAddress {.
    raises: [TransportOsError].} =
  ## Returns ``transp`` remote socket address.
  if transp.remote.family == AddressFamily.None:
    var saddr: Sockaddr_storage
    var slen = SockLen(sizeof(saddr))
    if getpeername(SocketHandle(transp.fd), cast[ptr SockAddr](addr saddr),
                   addr slen) != 0:
      raiseTransportOsError(osLastError())
    fromSAddr(addr saddr, slen, transp.remote)
  transp.remote

proc localAddress*(transp: DatagramTransport): TransportAddress {.
    raises: [TransportOsError].} =
  ## Returns ``transp`` local socket address.
  if transp.local.family == AddressFamily.None:
    var saddr: Sockaddr_storage
    var slen = SockLen(sizeof(saddr))
    if getsockname(SocketHandle(transp.fd), cast[ptr SockAddr](addr saddr),
                   addr slen) != 0:
      raiseTransportOsError(osLastError())
    fromSAddr(addr saddr, slen, transp.local)
  transp.local

template setReadError(t, e: untyped) =
  (t).state.incl(ReadError)
  (t).error = getTransportOsError(e)

when defined(windows):
  template setWriterWSABuffer(t, v: untyped) =
    (t).wwsabuf.buf = cast[cstring](v.buf)
    (t).wwsabuf.len = cast[ULONG](v.buflen)

  proc writeDatagramLoop(udata: pointer) =
    var bytesCount: uint32
    var ovl = cast[PtrCustomOverlapped](udata)
    var transp = cast[DatagramTransport](ovl.data.udata)
    while len(transp.queue) > 0:
      if WritePending in transp.state:
        ## Continuation
        transp.state.excl(WritePending)
        let err = transp.wovl.data.errCode
        let vector = transp.queue.popFirst()
        case err
        of OSErrorCode(-1):
          if not(vector.writer.finished()):
            vector.writer.complete()
        of ERROR_OPERATION_ABORTED:
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
        let ret =
          if vector.kind == WithAddress:
            var fixedAddress = windowsAnyAddressFix(vector.address)
            toSAddr(fixedAddress, transp.waddr, transp.walen)
            wsaSendTo(fd, addr transp.wwsabuf, DWORD(1), addr bytesCount,
                      DWORD(0), cast[ptr SockAddr](addr transp.waddr),
                      cint(transp.walen),
                      cast[POVERLAPPED](addr transp.wovl), nil)
          else:
            wsaSend(fd, addr transp.wwsabuf, DWORD(1), addr bytesCount,
                    DWORD(0), cast[POVERLAPPED](addr transp.wovl), nil)
        if ret != 0:
          let err = osLastError()
          case err
          of ERROR_OPERATION_ABORTED:
            # CancelIO() interrupt
            transp.state.excl(WritePending)
            transp.state.incl(WritePaused)
            if not(vector.writer.finished()):
              vector.writer.complete()
          of ERROR_IO_PENDING:
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
      bytesCount: uint32
      raddr: TransportAddress
    var ovl = cast[PtrCustomOverlapped](udata)
    var transp = cast[DatagramTransport](ovl.data.udata)
    while true:
      if ReadPending in transp.state:
        ## Continuation
        transp.state.excl(ReadPending)
        let err = transp.rovl.data.errCode
        case err
        of OSErrorCode(-1):
          let bytesCount = transp.rovl.data.bytesCount
          if bytesCount == 0:
            transp.state.incl({ReadEof, ReadPaused})
          fromSAddr(addr transp.raddr, transp.ralen, raddr)
          transp.buflen = int(bytesCount)
          asyncSpawn transp.function(transp, raddr)
        of ERROR_OPERATION_ABORTED:
          # CancelIO() interrupt or closeSocket() call.
          transp.state.incl(ReadPaused)
          if ReadClosed in transp.state and not(transp.future.finished()):
            # Stop tracking transport
            untrackCounter(DgramTransportTrackerName)
            # If `ReadClosed` present, then close(transport) was called.
            transp.future.complete()
            GC_unref(transp)
          break
        else:
          transp.setReadError(err)
          transp.state.incl(ReadPaused)
          transp.buflen = 0
          asyncSpawn transp.function(transp, raddr)
      else:
        ## Initiation
        if transp.state * {ReadEof, ReadClosed, ReadError} == {}:
          transp.state.incl(ReadPending)
          let fd = SocketHandle(transp.fd)
          transp.rflag = 0
          transp.ralen = SockLen(sizeof(Sockaddr_storage))
          let ret = wsaRecvFrom(fd, addr transp.rwsabuf, DWORD(1),
                                addr bytesCount, addr transp.rflag,
                                cast[ptr SockAddr](addr transp.raddr),
                                cast[ptr cint](addr transp.ralen),
                                cast[POVERLAPPED](addr transp.rovl), nil)
          if ret != 0:
            let err = osLastError()
            case err
            of ERROR_OPERATION_ABORTED:
              # CancelIO() interrupt
              transp.state.excl(ReadPending)
              transp.state.incl(ReadPaused)
            of WSAECONNRESET:
              transp.state.excl(ReadPending)
              transp.state.incl({ReadPaused, ReadEof})
              break
            of ERROR_IO_PENDING:
              discard
            else:
              transp.state.excl(ReadPending)
              transp.state.incl(ReadPaused)
              transp.setReadError(err)
              transp.buflen = 0
              asyncSpawn transp.function(transp, raddr)
        else:
          # Transport closure happens in callback, and we not started new
          # WSARecvFrom session.
          if ReadClosed in transp.state and not(transp.future.finished()):
            # Stop tracking transport
            untrackCounter(DgramTransportTrackerName)
            transp.future.complete()
            GC_unref(transp)
        break

  proc resumeRead(transp: DatagramTransport): Result[void, OSErrorCode] =
    if ReadPaused in transp.state:
      transp.state.excl(ReadPaused)
      readDatagramLoop(cast[pointer](addr transp.rovl))
    ok()

  proc resumeWrite(transp: DatagramTransport): Result[void, OSErrorCode] =
    if WritePaused in transp.state:
      transp.state.excl(WritePaused)
      writeDatagramLoop(cast[pointer](addr transp.wovl))
    ok()

  proc newDatagramTransportCommon(cbproc: DatagramCallback,
                                  remote: TransportAddress,
                                  local: TransportAddress,
                                  sock: AsyncFD,
                                  flags: set[ServerFlags],
                                  udata: pointer,
                                  child: DatagramTransport,
                                  bufferSize: int,
                                  ttl: int,
                                  dualstack = DualStackType.Auto
                                 ): DatagramTransport {.
      raises: [TransportOsError].} =
    doAssert(not isNil(cbproc))
    var res = if isNil(child): DatagramTransport() else: child

    let localSock =
      if sock == asyncInvalidSocket:
        let proto =
          if local.family == AddressFamily.Unix:
            Protocol.IPPROTO_IP
          else:
            Protocol.IPPROTO_UDP
        let res = createAsyncSocket2(local.getDomain(), SockType.SOCK_DGRAM,
                                     proto)
        if res.isErr():
          raiseTransportOsError(res.error)
        res.get()
      else:
        setDescriptorBlocking(SocketHandle(sock), false).isOkOr:
          raiseTransportOsError(error)
        register2(sock).isOkOr:
          raiseTransportOsError(error)
        sock

    ## Apply ServerFlags here
    if ServerFlags.ReuseAddr in flags:
      setSockOpt2(localSock, SOL_SOCKET, SO_REUSEADDR, 1).isOkOr:
        if sock == asyncInvalidSocket:
          closeSocket(localSock)
        raiseTransportOsError(error)

    if ServerFlags.ReusePort in flags:
      setSockOpt2(localSock, SOL_SOCKET, SO_REUSEPORT, 1).isOkOr:
        if sock == asyncInvalidSocket:
          closeSocket(localSock)
        raiseTransportOsError(error)

    if ServerFlags.Broadcast in flags:
      setSockOpt2(localSock, SOL_SOCKET, SO_BROADCAST, 1).isOkOr:
        if sock == asyncInvalidSocket:
          closeSocket(localSock)
        raiseTransportOsError(error)

      if ttl > 0:
        setSockOpt2(localSock, osdefs.IPPROTO_IP, osdefs.IP_TTL, ttl).isOkOr:
          if sock == asyncInvalidSocket:
            closeSocket(localSock)
          raiseTransportOsError(error)

    ## IPV6_V6ONLY
    if sock == asyncInvalidSocket:
      setDualstack(localSock, local.family, dualstack).isOkOr:
        closeSocket(localSock)
        raiseTransportOsError(error)
    else:
      setDualstack(localSock, dualstack).isOkOr:
        raiseTransportOsError(error)

    ## Fix for Q263823.
    var bytesRet: DWORD
    var bval = WINBOOL(0)
    if wsaIoctl(SocketHandle(localSock), osdefs.SIO_UDP_CONNRESET, addr bval,
                sizeof(WINBOOL).DWORD, nil, DWORD(0),
                addr bytesRet, nil, nil) != 0:
      raiseTransportOsError(osLastError())

    if local.family != AddressFamily.None:
      var saddr: Sockaddr_storage
      var slen: SockLen
      toSAddr(local, saddr, slen)

      if bindSocket(SocketHandle(localSock), cast[ptr SockAddr](addr saddr),
                    slen) != 0:
        let err = osLastError()
        if sock == asyncInvalidSocket:
          closeSocket(localSock)
        raiseTransportOsError(err)
    else:
      var saddr: Sockaddr_storage
      var slen: SockLen
      saddr.ss_family = type(saddr.ss_family)(local.getDomain())
      if bindSocket(SocketHandle(localSock), cast[ptr SockAddr](addr saddr),
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
      res.remote = fixedAddress

    res.fd = localSock
    res.function = cbproc
    res.buffer = newSeq[byte](bufferSize)
    res.queue = initDeque[GramVector]()
    res.udata = udata
    res.state = {ReadPaused, WritePaused}
    res.future = newFuture[void]("datagram.transport")
    res.rovl.data = CompletionData(cb: readDatagramLoop,
                                      udata: cast[pointer](res))
    res.wovl.data = CompletionData(cb: writeDatagramLoop,
                                      udata: cast[pointer](res))
    res.rwsabuf = WSABUF(buf: cast[cstring](addr res.buffer[0]),
                         len: ULONG(len(res.buffer)))
    GC_ref(res)
    # Start tracking transport
    trackCounter(DgramTransportTrackerName)
    if NoAutoRead notin flags:
      let rres = res.resumeRead()
      if rres.isErr(): raiseTransportOsError(rres.error())
    res

else:
  # Linux/BSD/MacOS part

  proc readDatagramLoop(udata: pointer) {.raises: [].}=
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
        var res = osdefs.recvfrom(fd, addr transp.buffer[0],
                                  cint(len(transp.buffer)), cint(0),
                                  cast[ptr SockAddr](addr transp.raddr),
                                  addr transp.ralen)
        if res >= 0:
          fromSAddr(addr transp.raddr, transp.ralen, raddr)
          transp.buflen = res
          asyncSpawn transp.function(transp, raddr)
        else:
          let err = osLastError()
          case err
          of oserrno.EINTR:
            continue
          else:
            transp.buflen = 0
            transp.setReadError(err)
            asyncSpawn transp.function(transp, raddr)
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
            res = osdefs.sendto(fd, vector.buf, vector.buflen, MSG_NOSIGNAL,
                                cast[ptr SockAddr](addr transp.waddr),
                                transp.walen)
          elif vector.kind == WithoutAddress:
            res = osdefs.send(fd, vector.buf, vector.buflen, MSG_NOSIGNAL)
          if res >= 0:
            if not(vector.writer.finished()):
              vector.writer.complete()
          else:
            let err = osLastError()
            case err
            of oserrno.EINTR:
              continue
            else:
              if not(vector.writer.finished()):
                vector.writer.fail(getTransportOsError(err))
          break
      else:
        transp.state.incl({WritePaused})
        discard removeWriter2(transp.fd)

  proc resumeWrite(transp: DatagramTransport): Result[void, OSErrorCode] =
    if WritePaused in transp.state:
      ? addWriter2(transp.fd, writeDatagramLoop, cast[pointer](transp))
      transp.state.excl(WritePaused)
    ok()

  proc resumeRead(transp: DatagramTransport): Result[void, OSErrorCode] =
    if ReadPaused in transp.state:
      ? addReader2(transp.fd, readDatagramLoop, cast[pointer](transp))
      transp.state.excl(ReadPaused)
    ok()

  proc newDatagramTransportCommon(cbproc: DatagramCallback,
                                  remote: TransportAddress,
                                  local: TransportAddress,
                                  sock: AsyncFD,
                                  flags: set[ServerFlags],
                                  udata: pointer,
                                  child: DatagramTransport,
                                  bufferSize: int,
                                  ttl: int,
                                  dualstack = DualStackType.Auto
                                 ): DatagramTransport {.
      raises: [TransportOsError].} =
    doAssert(not isNil(cbproc))
    var res = if isNil(child): DatagramTransport() else: child

    let localSock =
      if sock == asyncInvalidSocket:
        let proto =
          if local.family == AddressFamily.Unix:
            Protocol.IPPROTO_IP
          else:
            Protocol.IPPROTO_UDP
        let res = createAsyncSocket2(local.getDomain(), SockType.SOCK_DGRAM,
                                     proto)
        if res.isErr():
          raiseTransportOsError(res.error)
        res.get()
      else:
        setDescriptorBlocking(SocketHandle(sock), false).isOkOr:
          raiseTransportOsError(error)
        register2(sock).isOkOr:
          raiseTransportOsError(error)
        sock

    ## Apply ServerFlags here
    if ServerFlags.ReuseAddr in flags:
      setSockOpt2(localSock, SOL_SOCKET, SO_REUSEADDR, 1).isOkOr:
        if sock == asyncInvalidSocket:
          closeSocket(localSock)
        raiseTransportOsError(error)

    if ServerFlags.ReusePort in flags:
      setSockOpt2(localSock, SOL_SOCKET, SO_REUSEPORT, 1).isOkOr:
        if sock == asyncInvalidSocket:
          closeSocket(localSock)
        raiseTransportOsError(error)

    if ServerFlags.Broadcast in flags:
      setSockOpt2(localSock, SOL_SOCKET, SO_BROADCAST, 1).isOkOr:
        if sock == asyncInvalidSocket:
          closeSocket(localSock)
        raiseTransportOsError(error)

      if ttl > 0:
        if local.family == AddressFamily.IPv4:
          setSockOpt2(localSock, osdefs.IPPROTO_IP, osdefs.IP_MULTICAST_TTL,
                      cint(ttl)).isOkOr:
            if sock == asyncInvalidSocket:
              closeSocket(localSock)
            raiseTransportOsError(error)
        elif local.family == AddressFamily.IPv6:
          setSockOpt2(localSock, osdefs.IPPROTO_IP, osdefs.IPV6_MULTICAST_HOPS,
                      cint(ttl)).isOkOr:
            if sock == asyncInvalidSocket:
              closeSocket(localSock)
            raiseTransportOsError(error)
        else:
          raiseAssert "Unsupported address bound to local socket"

    ## IPV6_V6ONLY
    if sock == asyncInvalidSocket:
      setDualstack(localSock, local.family, dualstack).isOkOr:
        closeSocket(localSock)
        raiseTransportOsError(error)
    else:
      setDualstack(localSock, dualstack).isOkOr:
        raiseTransportOsError(error)

    if local.family != AddressFamily.None:
      var saddr: Sockaddr_storage
      var slen: SockLen
      toSAddr(local, saddr, slen)
      if bindSocket(SocketHandle(localSock), cast[ptr SockAddr](addr saddr),
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
      res.remote = remote

    res.fd = localSock
    res.function = cbproc
    res.flags = flags
    res.buffer = newSeq[byte](bufferSize)
    res.queue = initDeque[GramVector]()
    res.udata = udata
    res.state = {ReadPaused, WritePaused}
    res.future = newFuture[void]("datagram.transport")
    GC_ref(res)
    # Start tracking transport
    trackCounter(DgramTransportTrackerName)
    if NoAutoRead notin flags:
      let rres = res.resumeRead()
      if rres.isErr(): raiseTransportOsError(rres.error())
    res

proc close*(transp: DatagramTransport) =
  ## Closes and frees resources of transport ``transp``.
  proc continuation(udata: pointer) {.raises: [].} =
    if not(transp.future.finished()):
      # Stop tracking transport
      untrackCounter(DgramTransportTrackerName)
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

proc newDatagramTransportCommon(cbproc: UnsafeDatagramCallback,
                                remote: TransportAddress,
                                local: TransportAddress,
                                sock: AsyncFD,
                                flags: set[ServerFlags],
                                udata: pointer,
                                child: DatagramTransport,
                                bufferSize: int,
                                ttl: int,
                                dualstack = DualStackType.Auto
                          ): DatagramTransport {.
    raises: [TransportOsError].} =
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

  proc wrap(transp: DatagramTransport,
            remote: TransportAddress) {.async: (raises: []).} =
    try:
      cbproc(transp, remote)
    except CatchableError as exc:
      raiseAssert "Unexpected exception from stream server cbproc: " & exc.msg

  newDatagramTransportCommon(wrap, remote, local, sock, flags, udata, child,
                             bufferSize, ttl, dualstack)

proc newDatagramTransport*(cbproc: DatagramCallback,
                           remote: TransportAddress = AnyAddress,
                           local: TransportAddress = AnyAddress,
                           sock: AsyncFD = asyncInvalidSocket,
                           flags: set[ServerFlags] = {},
                           udata: pointer = nil,
                           child: DatagramTransport = nil,
                           bufSize: int = DefaultDatagramBufferSize,
                           ttl: int = 0,
                           dualstack = DualStackType.Auto
                          ): DatagramTransport {.
    raises: [TransportOsError].} =
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
  newDatagramTransportCommon(cbproc, remote, local, sock, flags, udata, child,
                             bufSize, ttl, dualstack)

proc newDatagramTransport*[T](cbproc: DatagramCallback,
                              udata: ref T,
                              remote: TransportAddress = AnyAddress,
                              local: TransportAddress = AnyAddress,
                              sock: AsyncFD = asyncInvalidSocket,
                              flags: set[ServerFlags] = {},
                              child: DatagramTransport = nil,
                              bufSize: int = DefaultDatagramBufferSize,
                              ttl: int = 0,
                              dualstack = DualStackType.Auto
                             ): DatagramTransport {.
    raises: [TransportOsError].} =
  var fflags = flags + {GCUserData}
  GC_ref(udata)
  newDatagramTransportCommon(cbproc, remote, local, sock, fflags,
                             cast[pointer](udata), child, bufSize, ttl,
                             dualstack)

proc newDatagramTransport6*(cbproc: DatagramCallback,
                            remote: TransportAddress = AnyAddress6,
                            local: TransportAddress = AnyAddress6,
                            sock: AsyncFD = asyncInvalidSocket,
                            flags: set[ServerFlags] = {},
                            udata: pointer = nil,
                            child: DatagramTransport = nil,
                            bufSize: int = DefaultDatagramBufferSize,
                            ttl: int = 0,
                            dualstack = DualStackType.Auto
                           ): DatagramTransport {.
    raises: [TransportOsError].} =
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
  newDatagramTransportCommon(cbproc, remote, local, sock, flags, udata, child,
                             bufSize, ttl, dualstack)

proc newDatagramTransport6*[T](cbproc: DatagramCallback,
                               udata: ref T,
                               remote: TransportAddress = AnyAddress6,
                               local: TransportAddress = AnyAddress6,
                               sock: AsyncFD = asyncInvalidSocket,
                               flags: set[ServerFlags] = {},
                               child: DatagramTransport = nil,
                               bufSize: int = DefaultDatagramBufferSize,
                               ttl: int = 0,
                               dualstack = DualStackType.Auto
                              ): DatagramTransport {.
    raises: [TransportOsError].} =
  var fflags = flags + {GCUserData}
  GC_ref(udata)
  newDatagramTransportCommon(cbproc, remote, local, sock, fflags,
                             cast[pointer](udata), child, bufSize, ttl,
                             dualstack)

proc newDatagramTransport*(cbproc: UnsafeDatagramCallback,
                           remote: TransportAddress = AnyAddress,
                           local: TransportAddress = AnyAddress,
                           sock: AsyncFD = asyncInvalidSocket,
                           flags: set[ServerFlags] = {},
                           udata: pointer = nil,
                           child: DatagramTransport = nil,
                           bufSize: int = DefaultDatagramBufferSize,
                           ttl: int = 0,
                           dualstack = DualStackType.Auto
                          ): DatagramTransport {.
    raises: [TransportOsError],
    deprecated: "Callback must not raise exceptions, annotate with {.async: (raises: []).}".} =
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
  newDatagramTransportCommon(cbproc, remote, local, sock, flags, udata, child,
                             bufSize, ttl, dualstack)

proc newDatagramTransport*[T](cbproc: UnsafeDatagramCallback,
                              udata: ref T,
                              remote: TransportAddress = AnyAddress,
                              local: TransportAddress = AnyAddress,
                              sock: AsyncFD = asyncInvalidSocket,
                              flags: set[ServerFlags] = {},
                              child: DatagramTransport = nil,
                              bufSize: int = DefaultDatagramBufferSize,
                              ttl: int = 0,
                              dualstack = DualStackType.Auto
                             ): DatagramTransport {.
    raises: [TransportOsError],
    deprecated: "Callback must not raise exceptions, annotate with {.async: (raises: []).}".} =
  var fflags = flags + {GCUserData}
  GC_ref(udata)
  newDatagramTransportCommon(cbproc, remote, local, sock, fflags,
                             cast[pointer](udata), child, bufSize, ttl,
                             dualstack)

proc newDatagramTransport6*(cbproc: UnsafeDatagramCallback,
                            remote: TransportAddress = AnyAddress6,
                            local: TransportAddress = AnyAddress6,
                            sock: AsyncFD = asyncInvalidSocket,
                            flags: set[ServerFlags] = {},
                            udata: pointer = nil,
                            child: DatagramTransport = nil,
                            bufSize: int = DefaultDatagramBufferSize,
                            ttl: int = 0,
                            dualstack = DualStackType.Auto
                           ): DatagramTransport {.
    raises: [TransportOsError],
    deprecated: "Callback must not raise exceptions, annotate with {.async: (raises: []).}".} =
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
  newDatagramTransportCommon(cbproc, remote, local, sock, flags, udata, child,
                             bufSize, ttl, dualstack)

proc newDatagramTransport6*[T](cbproc: UnsafeDatagramCallback,
                               udata: ref T,
                               remote: TransportAddress = AnyAddress6,
                               local: TransportAddress = AnyAddress6,
                               sock: AsyncFD = asyncInvalidSocket,
                               flags: set[ServerFlags] = {},
                               child: DatagramTransport = nil,
                               bufSize: int = DefaultDatagramBufferSize,
                               ttl: int = 0,
                               dualstack = DualStackType.Auto
                              ): DatagramTransport {.
    raises: [TransportOsError],
    deprecated: "Callback must not raise exceptions, annotate with {.async: (raises: []).}".} =
  var fflags = flags + {GCUserData}
  GC_ref(udata)
  newDatagramTransportCommon(cbproc, remote, local, sock, fflags,
                             cast[pointer](udata), child, bufSize, ttl,
                             dualstack)

proc join*(transp: DatagramTransport): Future[void] {.
    async: (raw: true, raises: [CancelledError]).} =
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

proc closeWait*(transp: DatagramTransport): Future[void] {.
    async: (raw: true, raises: []).} =
  ## Close transport ``transp`` and release all resources.
  let retFuture = newFuture[void](
    "datagram.transport.closeWait", {FutureFlag.OwnCancelSchedule})

  if {ReadClosed, WriteClosed} * transp.state != {}:
    retFuture.complete()
    return retFuture

  proc continuation(udata: pointer) {.gcsafe.} =
    retFuture.complete()

  proc cancellation(udata: pointer) {.gcsafe.} =
    # We are not going to change the state of `retFuture` to cancelled, so we
    # will prevent the entire sequence of Futures from being cancelled.
    discard

  transp.close()
  if transp.future.finished():
    retFuture.complete()
  else:
    transp.future.addCallback(continuation, cast[pointer](retFuture))
    retFuture.cancelCallback = cancellation
  retFuture

proc send*(transp: DatagramTransport, pbytes: pointer,
           nbytes: int): Future[void] {.
           async: (raw: true, raises: [TransportError, CancelledError]).} =
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
    let wres = transp.resumeWrite()
    if wres.isErr():
      retFuture.fail(getTransportOsError(wres.error()))
  return retFuture

proc send*(transp: DatagramTransport, msg: sink string,
           msglen = -1): Future[void] {.
           async: (raw: true, raises: [TransportError, CancelledError]).} =
  ## Send string ``msg`` using transport ``transp`` to remote destination
  ## address which was bounded on transport.
  var retFuture = newFuture[void]("datagram.transport.send(string)")
  transp.checkClosed(retFuture)

  let length = if msglen <= 0: len(msg) else: msglen
  var localCopy = chronosMoveSink(msg)
  retFuture.addCallback(proc(_: pointer) = reset(localCopy))

  let vector = GramVector(kind: WithoutAddress, buf: addr localCopy[0],
                          buflen: length,
                          writer: retFuture)

  transp.queue.addLast(vector)
  if WritePaused in transp.state:
    let wres = transp.resumeWrite()
    if wres.isErr():
      retFuture.fail(getTransportOsError(wres.error()))
  return retFuture

proc send*[T](transp: DatagramTransport, msg: sink seq[T],
              msglen = -1): Future[void] {.
              async: (raw: true, raises: [TransportError, CancelledError]).} =
  ## Send string ``msg`` using transport ``transp`` to remote destination
  ## address which was bounded on transport.
  var retFuture = newFuture[void]("datagram.transport.send(seq)")
  transp.checkClosed(retFuture)

  let length = if msglen <= 0: (len(msg) * sizeof(T)) else: (msglen * sizeof(T))
  var localCopy = chronosMoveSink(msg)
  retFuture.addCallback(proc(_: pointer) = reset(localCopy))

  let vector = GramVector(kind: WithoutAddress, buf: addr localCopy[0],
                          buflen: length,
                          writer: retFuture)
  transp.queue.addLast(vector)
  if WritePaused in transp.state:
    let wres = transp.resumeWrite()
    if wres.isErr():
      retFuture.fail(getTransportOsError(wres.error()))
  return retFuture

proc sendTo*(transp: DatagramTransport, remote: TransportAddress,
             pbytes: pointer, nbytes: int): Future[void] {.
             async: (raw: true, raises: [TransportError, CancelledError]).} =
  ## Send buffer with pointer ``pbytes`` and size ``nbytes`` using transport
  ## ``transp`` to remote destination address ``remote``.
  var retFuture = newFuture[void]("datagram.transport.sendTo(pointer)")
  transp.checkClosed(retFuture)
  let vector = GramVector(kind: WithAddress, buf: pbytes, buflen: nbytes,
                          writer: retFuture, address: remote)
  transp.queue.addLast(vector)
  if WritePaused in transp.state:
    let wres = transp.resumeWrite()
    if wres.isErr():
      retFuture.fail(getTransportOsError(wres.error()))
  return retFuture

proc sendTo*(transp: DatagramTransport, remote: TransportAddress,
             msg: sink string, msglen = -1): Future[void] {.
             async: (raw: true, raises: [TransportError, CancelledError]).} =
  ## Send string ``msg`` using transport ``transp`` to remote destination
  ## address ``remote``.
  var retFuture = newFuture[void]("datagram.transport.sendTo(string)")
  transp.checkClosed(retFuture)

  let length = if msglen <= 0: len(msg) else: msglen
  var localCopy = chronosMoveSink(msg)
  retFuture.addCallback(proc(_: pointer) = reset(localCopy))

  let vector = GramVector(kind: WithAddress, buf: addr localCopy[0],
                          buflen: length,
                          writer: retFuture,
                          address: remote)
  transp.queue.addLast(vector)
  if WritePaused in transp.state:
    let wres = transp.resumeWrite()
    if wres.isErr():
      retFuture.fail(getTransportOsError(wres.error()))
  return retFuture

proc sendTo*[T](transp: DatagramTransport, remote: TransportAddress,
                msg: sink seq[T], msglen = -1): Future[void] {.
                async: (raw: true, raises: [TransportError, CancelledError]).} =
  ## Send sequence ``msg`` using transport ``transp`` to remote destination
  ## address ``remote``.
  var retFuture = newFuture[void]("datagram.transport.sendTo(seq)")
  transp.checkClosed(retFuture)
  let length = if msglen <= 0: (len(msg) * sizeof(T)) else: (msglen * sizeof(T))
  var localCopy = chronosMoveSink(msg)
  retFuture.addCallback(proc(_: pointer) = reset(localCopy))

  let vector = GramVector(kind: WithAddress, buf: addr localCopy[0],
                          buflen: length,
                          writer: cast[Future[void]](retFuture),
                          address: remote)
  transp.queue.addLast(vector)
  if WritePaused in transp.state:
    let wres = transp.resumeWrite()
    if wres.isErr():
      retFuture.fail(getTransportOsError(wres.error()))
  return retFuture

proc peekMessage*(transp: DatagramTransport, msg: var seq[byte],
                  msglen: var int) {.raises: [TransportError].} =
  ## Get access to internal message buffer and length of incoming datagram.
  if ReadError in transp.state:
    transp.state.excl(ReadError)
    raise transp.getError()
  when declared(shallowCopy):
    shallowCopy(msg, transp.buffer)
  else:
    msg = transp.buffer
  msglen = transp.buflen

proc getMessage*(transp: DatagramTransport): seq[byte] {.
    raises: [TransportError].} =
  ## Copy data from internal message buffer and return result.
  var default: seq[byte]
  if ReadError in transp.state:
    transp.state.excl(ReadError)
    raise transp.getError()
  if transp.buflen > 0:
    var res = newSeq[byte](transp.buflen)
    copyMem(addr res[0], addr transp.buffer[0], transp.buflen)
    res
  else:
    default

proc getUserData*[T](transp: DatagramTransport): T {.inline.} =
  ## Obtain user data stored in ``transp`` object.
  cast[T](transp.udata)

proc closed*(transp: DatagramTransport): bool {.inline.} =
  ## Returns ``true`` if transport in closed state.
  {ReadClosed, WriteClosed} * transp.state != {}

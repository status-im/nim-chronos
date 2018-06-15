#
#          Asyncdispatch2 Datagram Transport
#                 (c) Copyright 2018
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

import net, nativesockets, os, deques
import ../asyncloop, ../handles
import common

when defined(windows):
  import winlean
else:
  import posix

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
                           remote: TransportAddress): Future[void] {.gcsafe.}

  DatagramTransport* = ref object of RootRef
    fd*: AsyncFD                    # File descriptor
    state: set[TransportState]      # Current Transport state
    flags: set[ServerFlags]         # Flags
    buffer: seq[byte]               # Reading buffer
    buflen: int                     # Reading buffer effective size
    error: ref Exception            # Current error
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

template setReadError(t, e: untyped) =
  (t).state.incl(ReadError)
  (t).error = newException(TransportOsError, osErrorMsg((e)))

template setWriterWSABuffer(t, v: untyped) =
  (t).wwsabuf.buf = cast[cstring](v.buf)
  (t).wwsabuf.len = cast[int32](v.buflen)

when defined(windows):
  const
    IOC_VENDOR = DWORD(0x18000000)
    SIO_UDP_CONNRESET = DWORD(winlean.IOC_IN) or IOC_VENDOR or DWORD(12)

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
          vector.writer.complete()
        elif int(err) == ERROR_OPERATION_ABORTED:
          # CancelIO() interrupt
          transp.state.incl(WritePaused)
          vector.writer.complete()
        else:
          transp.state = transp.state + {WritePaused, WriteError}
          vector.writer.fail(newException(TransportOsError, osErrorMsg(err)))
      else:
        ## Initiation
        transp.state.incl(WritePending)
        let fd = SocketHandle(ovl.data.fd)
        var vector = transp.queue.popFirst()
        transp.setWriterWSABuffer(vector)
        var ret: cint
        if vector.kind == WithAddress:
          toSockAddr(vector.address.address, vector.address.port,
                     transp.waddr, transp.walen)
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
            transp.state.incl(WritePaused)
            vector.writer.complete()
          elif int(err) == ERROR_IO_PENDING:
            transp.queue.addFirst(vector)
          else:
            transp.state.excl(WritePending)
            transp.state = transp.state + {WritePaused, WriteError}
            vector.writer.fail(newException(TransportOsError, osErrorMsg(err)))
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
        if ReadClosed in transp.state:
          break
        transp.state.excl(ReadPending)
        let err = transp.rovl.data.errCode
        if err == OSErrorCode(-1):
          let bytesCount = transp.rovl.data.bytesCount
          if bytesCount == 0:
            transp.state.incl({ReadEof, ReadPaused})
          fromSockAddr(transp.raddr, transp.ralen, raddr.address, raddr.port)
          transp.buflen = bytesCount
          discard transp.function(transp, raddr)
        elif int(err) == ERROR_OPERATION_ABORTED:
          # CancelIO() interrupt
          transp.state.incl(ReadPaused)
          break
        else:
          transp.setReadError(err)
          transp.state.incl(ReadPaused)
          transp.buflen = 0
          discard transp.function(transp, raddr)
      else:
        ## Initiation
        if transp.state * {ReadEof, ReadClosed, ReadError} == {}:
          transp.state.incl(ReadPending)
          let fd = SocketHandle(ovl.data.fd)
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
            elif int(err) == WSAECONNRESET:
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
              discard transp.function(transp, raddr)
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
                                  bufferSize: int): DatagramTransport =
    var localSock: AsyncFD
    assert(remote.address.family == local.address.family)
    assert(not isNil(cbproc))

    if isNil(child):
      result = DatagramTransport()
    else:
      result = child

    if sock == asyncInvalidSocket:
      if local.address.family == IpAddressFamily.IPv4:
        localSock = createAsyncSocket(Domain.AF_INET, SockType.SOCK_DGRAM,
                                      Protocol.IPPROTO_UDP)
      else:
        localSock = createAsyncSocket(Domain.AF_INET6, SockType.SOCK_DGRAM,
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
          closeAsyncSocket(localSock)
        raiseTransportOsError(err)

    ## Fix for Q263823.
    var bytesRet: DWORD
    var bval = WINBOOL(0)
    if WSAIoctl(SocketHandle(localSock), SIO_UDP_CONNRESET, addr bval,
                sizeof(WINBOOL).DWORD, nil, DWORD(0),
                addr bytesRet, nil, nil) != 0:
      raiseTransportOsError(osLastError())

    if local.port != Port(0):
      var saddr: Sockaddr_storage
      var slen: SockLen
      toSockAddr(local.address, local.port, saddr, slen)
      if bindAddr(SocketHandle(localSock), cast[ptr SockAddr](addr saddr),
                  slen) != 0:
        let err = osLastError()
        if sock == asyncInvalidSocket:
          closeAsyncSocket(localSock)
        raiseTransportOsError(err)
      result.local = local
    else:
      var saddr: Sockaddr_storage
      var slen: SockLen
      if local.address.family == IpAddressFamily.IPv4:
        saddr.ss_family = winlean.AF_INET
        slen = SockLen(sizeof(SockAddr_in))
      else:
        saddr.ss_family = winlean.AF_INET6
        slen = SockLen(sizeof(SockAddr_in6))
      if bindAddr(SocketHandle(localSock), cast[ptr SockAddr](addr saddr),
                  slen) != 0:
        let err = osLastError()
        if sock == asyncInvalidSocket:
          closeAsyncSocket(localSock)
        raiseTransportOsError(err)

    if remote.port != Port(0):
      var saddr: Sockaddr_storage
      var slen: SockLen
      toSockAddr(remote.address, remote.port, saddr, slen)
      if connect(SocketHandle(localSock), cast[ptr SockAddr](addr saddr),
                 slen) != 0:
        let err = osLastError()
        if sock == asyncInvalidSocket:
          closeAsyncSocket(localSock)
        raiseTransportOsError(err)
      result.remote = remote

    result.fd = localSock
    result.function = cbproc
    result.buffer = newSeq[byte](bufferSize)
    result.queue = initDeque[GramVector]()
    result.udata = udata
    result.state = {WritePaused}
    result.future = newFuture[void]("datagram.transport")
    result.rovl.data = CompletionData(fd: localSock, cb: readDatagramLoop,
                                      udata: cast[pointer](result))
    result.wovl.data = CompletionData(fd: localSock, cb: writeDatagramLoop,
                                      udata: cast[pointer](result))
    result.rwsabuf = TWSABuf(buf: cast[cstring](addr result.buffer[0]),
                             len: int32(len(result.buffer)))
    GC_ref(result)
    if NoAutoRead notin flags:
      result.resumeRead()
    else:
      result.state.incl(ReadPaused)

  proc close*(transp: DatagramTransport) =
    ## Closes and frees resources of transport ``transp``.
    if ReadClosed notin transp.state and WriteClosed notin transp.state:
      # discard cancelIo(Handle(transp.fd))
      closeAsyncSocket(transp.fd)
      transp.state.incl(WriteClosed)
      transp.state.incl(ReadClosed)
      transp.future.complete()
      if not isNil(transp.udata) and GCUserData in transp.flags:
        GC_unref(cast[ref int](transp.udata))
      GC_unref(transp)

else:
  # Linux/BSD/MacOS part

  proc readDatagramLoop(udata: pointer) =
    var raddr: TransportAddress
    var cdata = cast[ptr CompletionData](udata)
    if not isNil(cdata) and (int(cdata.fd) == 0 or isNil(cdata.udata)):
      # Transport was closed earlier, exiting
      return
    var transp = cast[DatagramTransport](cdata.udata)
    let fd = SocketHandle(cdata.fd)
    if not isNil(transp):
      while true:
        transp.ralen = SockLen(sizeof(Sockaddr_storage))
        var res = posix.recvfrom(fd, addr transp.buffer[0],
                                 cint(len(transp.buffer)), cint(0),
                                 cast[ptr SockAddr](addr transp.raddr),
                                 addr transp.ralen)
        if res >= 0:
          fromSockAddr(transp.raddr, transp.ralen, raddr.address, raddr.port)
          transp.buflen = res
          discard transp.function(transp, raddr)
        else:
          let err = osLastError()
          if int(err) == EINTR:
            continue
          else:
            transp.buflen = 0
            transp.setReadError(err)
            discard transp.function(transp, raddr)
        break

  proc writeDatagramLoop(udata: pointer) =
    var res: int
    var cdata = cast[ptr CompletionData](udata)
    if not isNil(cdata) and (int(cdata.fd) == 0 or isNil(cdata.udata)):
      # Transport was closed earlier, exiting
      return
    var transp = cast[DatagramTransport](cdata.udata)
    let fd = SocketHandle(cdata.fd)
    if not isNil(transp):
      if len(transp.queue) > 0:
        var vector = transp.queue.popFirst()
        while true:
          if vector.kind == WithAddress:
            toSockAddr(vector.address.address, vector.address.port,
                       transp.waddr, transp.walen)
            res = posix.sendto(fd, vector.buf, vector.buflen, MSG_NOSIGNAL,
                               cast[ptr SockAddr](addr transp.waddr),
                               transp.walen)
          elif vector.kind == WithoutAddress:
            res = posix.send(fd, vector.buf, vector.buflen, MSG_NOSIGNAL)
          if res >= 0:
            vector.writer.complete()
          else:
            let err = osLastError()
            if int(err) == EINTR:
              continue
            else:
              vector.writer.fail(newException(TransportOsError,
                                              osErrorMsg(err)))
          break
      else:
        transp.state.incl(WritePaused)
        transp.fd.removeWriter()

  proc resumeWrite(transp: DatagramTransport) {.inline.} =
    transp.state.excl(WritePaused)
    addWriter(transp.fd, writeDatagramLoop, cast[pointer](transp))

  proc resumeRead(transp: DatagramTransport) {.inline.} =
    transp.state.excl(ReadPaused)
    addReader(transp.fd, readDatagramLoop, cast[pointer](transp))

  proc newDatagramTransportCommon(cbproc: DatagramCallback,
                                  remote: TransportAddress,
                                  local: TransportAddress,
                                  sock: AsyncFD,
                                  flags: set[ServerFlags],
                                  udata: pointer,
                                  child: DatagramTransport = nil,
                                  bufferSize: int): DatagramTransport =
    var localSock: AsyncFD
    assert(remote.address.family == local.address.family)
    assert(not isNil(cbproc))

    if isNil(child):
      result = DatagramTransport()
    else:
      result = child

    if sock == asyncInvalidSocket:
      if local.address.family == IpAddressFamily.IPv4:
        localSock = createAsyncSocket(Domain.AF_INET, SockType.SOCK_DGRAM,
                                      Protocol.IPPROTO_UDP)
      else:
        localSock = createAsyncSocket(Domain.AF_INET6, SockType.SOCK_DGRAM,
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
          closeAsyncSocket(localSock)
        raiseTransportOsError(err)

    if local.port != Port(0):
      var saddr: Sockaddr_storage
      var slen: SockLen
      toSockAddr(local.address, local.port, saddr, slen)
      if bindAddr(SocketHandle(localSock), cast[ptr SockAddr](addr saddr),
                  slen) != 0:
        let err = osLastError()
        if sock == asyncInvalidSocket:
          closeAsyncSocket(localSock)
        raiseTransportOsError(err)
      result.local = local

    if remote.port != Port(0):
      var saddr: Sockaddr_storage
      var slen: SockLen
      toSockAddr(remote.address, remote.port, saddr, slen)
      if connect(SocketHandle(localSock), cast[ptr SockAddr](addr saddr),
                 slen) != 0:
        let err = osLastError()
        if sock == asyncInvalidSocket:
          closeAsyncSocket(localSock)
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
    if NoAutoRead notin flags:
      result.resumeRead()
    else:
      result.state.incl(ReadPaused)

  proc close*(transp: DatagramTransport) =
    ## Closes and frees resources of transport ``transp``.
    if {ReadClosed, WriteClosed} * transp.state == {}:
      closeAsyncSocket(transp.fd)
      transp.state.incl({WriteClosed, ReadClosed})
      transp.future.complete()
      GC_unref(transp)

proc newDatagramTransport*(cbproc: DatagramCallback,
                           remote: TransportAddress = AnyAddress,
                           local: TransportAddress = AnyAddress,
                           sock: AsyncFD = asyncInvalidSocket,
                           flags: set[ServerFlags] = {},
                           udata: pointer = nil,
                           child: DatagramTransport = nil,
                           bufSize: int = DefaultDatagramBufferSize
                           ): DatagramTransport =
  ## Create new UDP datagram transport (IPv4).
  ##
  ## ``cbproc`` - callback which will be called, when new datagram received.
  ## ``remote`` - bind transport to remote address (optional).
  ## ``local`` - bind transport to local address (to serving incoming
  ## datagrams, optional)
  ## ``sock`` - application-driven socket to use.
  ## ``flags`` - flags that will be applied to socket.
  ## ``udata`` - custom argument which will be passed to ``cbproc``.
  ## ``bufSize`` - size of internal buffer
  result = newDatagramTransportCommon(cbproc, remote, local, sock,
                                      flags, udata, child, bufSize)

proc newDatagramTransport*[T](cbproc: DatagramCallback,
                              udata: ref T,
                              remote: TransportAddress = AnyAddress,
                              local: TransportAddress = AnyAddress,
                              sock: AsyncFD = asyncInvalidSocket,
                              flags: set[ServerFlags] = {},
                              child: DatagramTransport = nil,
                              bufSize: int = DefaultDatagramBufferSize
                              ): DatagramTransport =
  var fflags = flags + {GCUserData}
  GC_ref(udata)
  result = newDatagramTransportCommon(cbproc, remote, local, sock,
                                      fflags, cast[pointer](udata),
                                      child, bufSize)

proc newDatagramTransport6*(cbproc: DatagramCallback,
                            remote: TransportAddress = AnyAddress6,
                            local: TransportAddress = AnyAddress6,
                            sock: AsyncFD = asyncInvalidSocket,
                            flags: set[ServerFlags] = {},
                            udata: pointer = nil,
                            child: DatagramTransport = nil,
                            bufSize: int = DefaultDatagramBufferSize
                            ): DatagramTransport =
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
  result = newDatagramTransportCommon(cbproc, remote, local, sock,
                                      flags, udata, child, bufSize)

proc newDatagramTransport6*[T](cbproc: DatagramCallback,
                               udata: ref T,
                               remote: TransportAddress = AnyAddress6,
                               local: TransportAddress = AnyAddress6,
                               sock: AsyncFD = asyncInvalidSocket,
                               flags: set[ServerFlags] = {},
                               child: DatagramTransport = nil,
                               bufSize: int = DefaultDatagramBufferSize
                               ): DatagramTransport =
  var fflags = flags + {GCUserData}
  GC_ref(udata)
  result = newDatagramTransportCommon(cbproc, remote, local, sock,
                                      fflags, cast[pointer](udata),
                                      child, bufSize)

proc join*(transp: DatagramTransport) {.async.} =
  ## Wait until the transport ``transp`` will be closed.
  if not transp.future.finished:
    await transp.future

proc send*(transp: DatagramTransport, pbytes: pointer,
           nbytes: int): Future[void] =
  ## Send buffer with pointer ``pbytes`` and size ``nbytes`` using transport
  ## ``transp`` to remote destination address which was bounded on transport.
  var retFuture = newFuture[void]()
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
  var retFuture = FutureGCString[void]()
  transp.checkClosed(retFuture)
  if not isLiteral(msg):
    shallowCopy(retFuture.gcholder, msg)
  let length = if msglen <= 0: len(msg) else: msglen
  let vector = GramVector(kind: WithoutAddress, buf: unsafeAddr msg[0],
                          buflen: len(msg),
                          writer: cast[Future[void]](retFuture))
  transp.queue.addLast(vector)
  if WritePaused in transp.state:
    transp.resumeWrite()
  return retFuture

proc send*[T](transp: DatagramTransport, msg: seq[T],
              msglen = -1): Future[void] =
  ## Send string ``msg`` using transport ``transp`` to remote destination
  ## address which was bounded on transport.
  var retFuture = FutureGCSeq[void, T]()
  transp.checkClosed(retFuture)
  if not isLiteral(msg):
    shallowCopy(retFuture.gcholder, msg)
  let length = if msglen <= 0: (len(msg) * sizeof(T)) else: (msglen * sizeof(T))
  let vector = GramVector(kind: WithoutAddress, buf: unsafeAddr msg[0],
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
  var retFuture = newFuture[void]()
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
  var retFuture = FutureGCString[void]()
  transp.checkClosed(retFuture)
  if not isLiteral(msg):
    shallowCopy(retFuture.gcholder, msg)
  let length = if msglen <= 0: len(msg) else: msglen
  let vector = GramVector(kind: WithAddress, buf: unsafeAddr msg[0],
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
  var retFuture = FutureGCSeq[void, T]()
  transp.checkClosed(retFuture)
  if not isLiteral(msg):
    shallowCopy(retFuture.gcholder, msg)
  let length = if msglen <= 0: (len(msg) * sizeof(T)) else: (msglen * sizeof(T))
  let vector = GramVector(kind: WithAddress, buf: unsafeAddr msg[0],
                          buflen: length,
                          writer: cast[Future[void]](retFuture),
                          address: remote)
  transp.queue.addLast(vector)
  if WritePaused in transp.state:
    transp.resumeWrite()
  return retFuture

proc peekMessage*(transp: DatagramTransport, msg: var seq[byte],
                  msglen: var int) =
  ## Get access to internal message buffer and length of incoming datagram.
  if ReadError in transp.state:
    raise transp.getError()
  shallowCopy(msg, transp.buffer)
  msglen = transp.buflen

proc getMessage*(transp: DatagramTransport): seq[byte] =
  ## Copy data from internal message buffer and return result.
  if ReadError in transp.state:
    raise transp.getError()
  if transp.buflen > 0:
    result = newSeq[byte](transp.buflen)
    copyMem(addr result[0], addr transp.buffer[0], transp.buflen)

proc getUserData*[T](transp: DatagramTransport): T {.inline.} =
  ## Obtain user data stored in ``transp`` object.
  result = cast[T](transp.udata)

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

type
  VectorKind = enum
    WithoutAddress, WithAddress

when defined(windows):
  import winlean
  type
    GramVector = object
      kind: VectorKind            # Vector kind (with address/without address)
      buf: TWSABuf                # Writer vector buffer
      address: TransportAddress   # Destination address
      writer: Future[void]        # Writer vector completion Future

else:
  import posix

  type
    GramVector = object
      kind: VectorKind            # Vector kind (with address/without address)
      buf: pointer                # Writer buffer pointer
      buflen: int                 # Writer buffer size
      address: TransportAddress   # Destination address
      writer: Future[void]        # Writer vector completion Future

type
  DatagramCallback* = proc(transp: DatagramTransport,
                           pbytes: pointer,
                           nbytes: int,
                           remote: TransportAddress,
                           udata: pointer): Future[void] {.gcsafe.}
    ## Datagram asynchronous receive callback.
    ## ``transp`` - transport object
    ## ``pbytes`` - pointer to data received
    ## ``nbytes`` - number of bytes received
    ## ``remote`` - remote peer address
    ## ``udata`` - user-defined pointer, specified at Transport creation.
    ## 
    ## ``pbytes`` will be `nil` and ``nbytes`` will be ``0``, if there an error
    ## happens.

  DatagramTransport* = ref object of RootRef
    fd: AsyncFD                     # File descriptor
    state: set[TransportState]      # Current Transport state
    buffer: seq[byte]               # Reading buffer
    error: ref Exception            # Current error
    queue: Deque[GramVector]        # Writer queue
    local: TransportAddress         # Local address
    remote: TransportAddress        # Remote address
    udata: pointer                  # User-driven pointer
    function: DatagramCallback      # Receive data callback
    future: Future[void]            # Transport's life future

template setReadError(t, e: untyped) =
  (t).state.incl(ReadError)
  (t).error = newException(TransportOsError, osErrorMsg((e)))

template setWriteError(t, e: untyped) =
  (t).state.incl(WriteError)
  (t).error = newException(TransportOsError, osErrorMsg((e)))

when defined(windows):
  type
    WindowsDatagramTransport* = ref object of DatagramTransport
      rovl: CustomOverlapped
      wovl: CustomOverlapped
      raddr: Sockaddr_storage
      ralen: SockLen
      rflag: int32
      wsabuf: TWSABuf

  template finishWriter(t: untyped) =
    var vv = (t).queue.popFirst()
    vv.writer.complete()

  proc writeDatagramLoop(udata: pointer) =
    var bytesCount: int32
    if isNil(udata):
      return
    var ovl = cast[PCustomOverlapped](udata)
    var transp = cast[WindowsDatagramTransport](ovl.data.udata)
    while len(transp.queue) > 0:
      if WritePending in transp.state:
        ## Continuation
        transp.state.excl(WritePending)
        let err = transp.wovl.data.errCode
        if err == OSErrorCode(-1):
          var vector = transp.queue.popFirst()
          vector.writer.complete()
        else:
          transp.setWriteError(err)
          transp.finishWriter()
      else:
        ## Initiation
        var saddr: Sockaddr_storage
        var slen: SockLen
        transp.state.incl(WritePending)
        let fd = SocketHandle(ovl.data.fd)
        var vector = transp.queue[0]
        if vector.kind == WithAddress:
          toSockAddr(vector.address.address, vector.address.port, saddr, slen)
        else:
          toSockAddr(transp.remote.address, transp.remote.port, saddr, slen)
        let ret = WSASendTo(fd, addr vector.buf, DWORD(1), addr bytesCount,
                            DWORD(0), cast[ptr SockAddr](addr saddr),
                            cint(slen),
                            cast[POVERLAPPED](addr transp.wovl), nil)
        if ret != 0:
          let err = osLastError()
          if int(err) == ERROR_OPERATION_ABORTED:
            transp.state.incl(WritePaused)
          elif int(err) != ERROR_IO_PENDING:
            transp.state.excl(WritePending)
            transp.setWriteError(err)
            transp.finishWriter()
        break

    if len(transp.queue) == 0:
      transp.state.incl(WritePaused)

  proc readDatagramLoop(udata: pointer) =
    var
      bytesCount: int32
      raddr: TransportAddress
    if isNil(udata):
      return
    var ovl = cast[PCustomOverlapped](udata)
    var transp = cast[WindowsDatagramTransport](ovl.data.udata)
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
            transp.state.incl(ReadEof)
            transp.state.incl(ReadPaused)
          fromSockAddr(transp.raddr, transp.ralen, raddr.address, raddr.port)
          discard transp.function(transp, addr transp.buffer[0], bytesCount,
                                  raddr, transp.udata)
        else:
          transp.setReadError(err)
          transp.state.incl(ReadPaused)
          discard transp.function(transp, nil, 0, raddr, transp.udata)
      else:
        ## Initiation
        if (ReadEof notin transp.state) and (ReadClosed notin transp.state):
          transp.state.incl(ReadPending)
          let fd = SocketHandle(ovl.data.fd)
          transp.rflag = 0
          transp.ralen = SockLen(sizeof(Sockaddr_storage))
          let ret = WSARecvFrom(fd,
                                addr transp.wsabuf,
                                DWORD(1),
                                addr bytesCount,
                                addr transp.rflag,
                                cast[ptr SockAddr](addr transp.raddr),
                                cast[ptr cint](addr transp.ralen),
                                cast[POVERLAPPED](addr transp.rovl), nil)
          if ret != 0:
            let err = osLastError()
            if int(err) == ERROR_OPERATION_ABORTED:
              transp.state.incl(ReadPaused)
            elif int(err) != ERROR_IO_PENDING:
              transp.state.excl(ReadPending)
              transp.setReadError(err)
              discard transp.function(transp, nil, 0, raddr, transp.udata)
        break

  proc resumeRead(transp: DatagramTransport) {.inline.} =
    var wtransp = cast[WindowsDatagramTransport](transp)
    wtransp.state.excl(ReadPaused)
    readDatagramLoop(cast[pointer](addr wtransp.rovl))

  proc resumeWrite(transp: DatagramTransport) {.inline.} =
    var wtransp = cast[WindowsDatagramTransport](transp)
    wtransp.state.excl(WritePaused)
    writeDatagramLoop(cast[pointer](addr wtransp.wovl))

  proc newDatagramTransportCommon(cbproc: DatagramCallback,
                                  remote: TransportAddress,
                                  local: TransportAddress,
                                  sock: AsyncFD,
                                  flags: set[ServerFlags],
                                  udata: pointer,
                                  bufferSize: int): DatagramTransport =
    var localSock: AsyncFD
    assert(remote.address.family == local.address.family)
    assert(not isNil(cbproc))

    var wresult = new WindowsDatagramTransport

    if sock == asyncInvalidSocket:
      if local.address.family == IpAddressFamily.IPv4:
        localSock = createAsyncSocket(Domain.AF_INET, SockType.SOCK_DGRAM,
                                      Protocol.IPPROTO_UDP)
      else:
        localSock = createAsyncSocket(Domain.AF_INET6, SockType.SOCK_DGRAM,
                                      Protocol.IPPROTO_UDP)
      if localSock == asyncInvalidSocket:
        raiseOsError(osLastError())
    else:
      if not setSocketBlocking(SocketHandle(sock), false):
        raiseOsError(osLastError())
      localSock = sock
      register(localSock)

    if local.port != Port(0):
      var saddr: Sockaddr_storage
      var slen: SockLen
      toSockAddr(local.address, local.port, saddr, slen)
      if bindAddr(SocketHandle(localSock), cast[ptr SockAddr](addr saddr),
                  slen) != 0:
        let err = osLastError()
        if sock == asyncInvalidSocket:
          closeAsyncSocket(localSock)
        raiseOsError(err)
      wresult.local = local
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
        raiseOsError(err)
    if remote.port != Port(0):
      wresult.remote = remote

    ## TODO: Apply server flags

    wresult.fd = localSock
    wresult.function = cbproc
    wresult.buffer = newSeq[byte](bufferSize)
    wresult.queue = initDeque[GramVector]()
    wresult.udata = udata
    wresult.state = {WritePaused}
    wresult.future = newFuture[void]("datagram.transport")
    wresult.rovl.data = CompletionData(fd: localSock, cb: readDatagramLoop,
                                       udata: cast[pointer](wresult))
    wresult.wovl.data = CompletionData(fd: localSock, cb: writeDatagramLoop,
                                       udata: cast[pointer](wresult))
    wresult.wsabuf = TWSABuf(buf: cast[cstring](addr wresult.buffer[0]),
                             len: int32(len(wresult.buffer)))
    result = cast[DatagramTransport](wresult)
    result.resumeRead()

  proc close*(transp: DatagramTransport) =
    ## Closes and frees resources of transport ``transp``.
    if ReadClosed notin transp.state and WriteClosed notin transp.state:
      discard cancelIo(Handle(transp.fd))
      closeAsyncSocket(transp.fd)
      transp.state.incl(WriteClosed)
      transp.state.incl(ReadClosed)
      transp.future.complete()

else:

  proc readDatagramLoop(udata: pointer) =
    var
      saddr: Sockaddr_storage
      slen: SockLen
      raddr: TransportAddress

    var cdata = cast[ptr CompletionData](udata)
    var transp = cast[DatagramTransport](cdata.udata)
    let fd = SocketHandle(cdata.fd)
    if not isNil(transp):
      while true:
        slen = SockLen(sizeof(Sockaddr_storage))
        var res = posix.recvfrom(fd, addr transp.buffer[0],
                                 cint(len(transp.buffer)), cint(0),
                                 cast[ptr SockAddr](addr saddr),
                                 addr slen)
        if res >= 0:
          fromSockAddr(saddr, slen, raddr.address, raddr.port)
          discard transp.function(transp, addr transp.buffer[0], res,
                                  raddr, transp.udata)
        else:
          let err = osLastError()
          if int(err) == EINTR:
            continue
          else:
            transp.setReadError(err)
            discard transp.function(transp, nil, 0, raddr, transp.udata)
        break

  proc writeDatagramLoop(udata: pointer) =
    var res: int = 0
    var cdata = cast[ptr CompletionData](udata)
    var transp = cast[DatagramTransport](cdata.udata)
    var saddr: Sockaddr_storage
    var slen: SockLen
    let fd = SocketHandle(cdata.fd)
    if not isNil(transp):
      if len(transp.queue) > 0:
        var vector = transp.queue.popFirst()
        while true:
          if vector.kind == WithAddress:
            toSockAddr(vector.address.address, vector.address.port, saddr, slen)
            res = posix.sendto(fd, vector.buf, vector.buflen, MSG_NOSIGNAL,
                               cast[ptr SockAddr](addr saddr),
                               slen)
          elif vector.kind == WithoutAddress:
            res = posix.send(fd, vector.buf, vector.buflen, MSG_NOSIGNAL)
          if res >= 0:
            vector.writer.complete()
          else:
            let err = osLastError()
            if int(err) == EINTR:
              continue
            else:
              transp.setWriteError(err)
              vector.writer.complete()
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
                                  bufferSize: int): DatagramTransport =
    var localSock: AsyncFD
    assert(remote.address.family == local.address.family)
    assert(not isNil(cbproc))

    result = new DatagramTransport

    if sock == asyncInvalidSocket:
      if local.address.family == IpAddressFamily.IPv4:
        localSock = createAsyncSocket(Domain.AF_INET, SockType.SOCK_DGRAM,
                                      Protocol.IPPROTO_UDP)
      else:
        localSock = createAsyncSocket(Domain.AF_INET6, SockType.SOCK_DGRAM,
                                      Protocol.IPPROTO_UDP)
      if localSock == asyncInvalidSocket:
        raiseOsError(osLastError())
    else:
      if not setSocketBlocking(SocketHandle(sock), false):
        raiseOsError(osLastError())
      localSock = sock
      register(localSock)

    ## Apply ServerFlags here
    if ServerFlags.ReuseAddr in flags:
      if not setSockOpt(localSock, SOL_SOCKET, SO_REUSEADDR, 1):
        let err = osLastError()
        if sock == asyncInvalidSocket:
          closeAsyncSocket(localSock)
        raiseOsError(err)

    if local.port != Port(0):
      var saddr: Sockaddr_storage
      var slen: SockLen
      toSockAddr(local.address, local.port, saddr, slen)
      if bindAddr(SocketHandle(localSock), cast[ptr SockAddr](addr saddr),
                  slen) != 0:
        let err = osLastError()
        if sock == asyncInvalidSocket:
          closeAsyncSocket(localSock)
        raiseOsError(err)
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
        raiseOsError(err)
      result.remote = remote

    result.fd = localSock
    result.function = cbproc
    result.buffer = newSeq[byte](bufferSize)
    result.queue = initDeque[GramVector]()
    result.udata = udata
    result.state = {WritePaused}
    result.future = newFuture[void]("datagram.transport")
    result.resumeRead()

  proc close*(transp: DatagramTransport) =
    ## Closes and frees resources of transport ``transp``.
    if ReadClosed notin transp.state and WriteClosed notin transp.state:
      closeAsyncSocket(transp.fd)
      transp.state.incl(WriteClosed)
      transp.state.incl(ReadClosed)
      transp.future.complete()

proc newDatagramTransport*(cbproc: DatagramCallback,
                           remote: TransportAddress = AnyAddress,
                           local: TransportAddress = AnyAddress,
                           sock: AsyncFD = asyncInvalidSocket,
                           flags: set[ServerFlags] = {},
                           udata: pointer = nil,
                           bufSize: int = DefaultDatagramBufferSize
                           ): DatagramTransport =
  result = newDatagramTransportCommon(cbproc, remote, local, sock,
                                      flags, udata, bufSize)

proc newDatagramTransport6*(cbproc: DatagramCallback,
                            remote: TransportAddress = AnyAddress6,
                            local: TransportAddress = AnyAddress6,
                            sock: AsyncFD = asyncInvalidSocket,
                            flags: set[ServerFlags] = {},
                            udata: pointer = nil,
                            bufSize: int = DefaultDatagramBufferSize
                            ): DatagramTransport =
  result = newDatagramTransportCommon(cbproc, remote, local, sock,
                                      flags, udata, bufSize)

proc join*(transp: DatagramTransport) {.async.} =
  await transp.future

proc send*(transp: DatagramTransport, pbytes: pointer,
           nbytes: int): Future[void] {.async.} =
  checkClosed(transp)
  if transp.remote.port == Port(0):
    raise newException(TransportError, "Remote peer is not set!")
  var waitFuture = newFuture[void]("datagram.transport.send")
  when defined(windows):
    let wsabuf = TWSABuf(buf: cast[cstring](pbytes), len: int32(nbytes))
    var vector = GramVector(kind: WithoutAddress, buf: wsabuf,
                            writer: waitFuture)
  else:
    var vector = GramVector(kind: WithoutAddress, buf: pbytes, buflen: nbytes,
                            writer: waitFuture)
  transp.queue.addLast(vector)
  if WritePaused in transp.state:
    transp.resumeWrite()
  await vector.writer
  if WriteError in transp.state:
    raise transp.getError()

proc sendTo*(transp: DatagramTransport, pbytes: pointer, nbytes: int,
             remote: TransportAddress): Future[void] {.async.} =
  checkClosed(transp)
  var saddr: Sockaddr_storage
  var slen: SockLen
  toSockAddr(remote.address, remote.port, saddr, slen)
  var waitFuture = newFuture[void]("datagram.transport.sendto")
  when defined(windows):
    let wsabuf = TWSABuf(buf: cast[cstring](pbytes), len: int32(nbytes))
    var vector = GramVector(kind: WithAddress, buf: wsabuf,
                            address: remote, writer: waitFuture)
  else:
    var vector = GramVector(kind: WithAddress, buf: pbytes, buflen: nbytes,
                            address: remote, writer: waitFuture)
  transp.queue.addLast(vector)
  if WritePaused in transp.state:
    transp.resumeWrite()
  await vector.writer
  if WriteError in transp.state:
    raise transp.getError()

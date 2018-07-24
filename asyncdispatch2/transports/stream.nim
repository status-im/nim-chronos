#
#             Asyncdispatch2 Stream Transport
#                 (c) Copyright 2018
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

import net, nativesockets, os, deques
import ../asyncloop, ../handles, ../sendfile
import common

when defined(windows):
  import winlean
else:
  import posix

type
  VectorKind = enum
    DataBuffer,                     # Simple buffer pointer/length
    DataFile                        # File handle for sendfile/TransmitFile

  StreamVector = object
    kind: VectorKind                # Writer vector source kind
    buf: pointer                    # Writer buffer pointer
    buflen: int                     # Writer buffer size
    offset: uint                    # Writer vector offset
    writer: Future[int]             # Writer vector completion Future

  TransportKind* {.pure.} = enum
    Socket,                         # Socket transport
    Pipe,                           # Pipe transport
    File                            # File transport

when defined(windows):
  const SO_UPDATE_CONNECT_CONTEXT = 0x7010

  type
    StreamTransport* = ref object of RootRef
      fd*: AsyncFD                    # File descriptor
      state: set[TransportState]      # Current Transport state
      reader: Future[void]            # Current reader Future
      buffer: seq[byte]               # Reading buffer
      offset: int                     # Reading buffer offset
      error: ref Exception            # Current error
      queue: Deque[StreamVector]      # Writer queue
      future: Future[void]            # Stream life future
      # Windows specific part
      rwsabuf: TWSABuf                # Reader WSABUF
      wwsabuf: TWSABuf                # Writer WSABUF
      rovl: CustomOverlapped          # Reader OVERLAPPED structure
      wovl: CustomOverlapped          # Writer OVERLAPPED structure
      roffset: int                    # Pending reading offset
      case kind*: TransportKind
      of TransportKind.Socket:
        domain: Domain                # Socket transport domain (IPv4/IPv6)
        local: TransportAddress       # Local address
        remote: TransportAddress      # Remote address
      of TransportKind.Pipe:
        todo1: int
      of TransportKind.File:
        todo2: int
else:
  type
    StreamTransport* = ref object of RootRef
      fd*: AsyncFD                    # File descriptor
      state: set[TransportState]      # Current Transport state
      reader: Future[void]            # Current reader Future
      buffer: seq[byte]               # Reading buffer
      offset: int                     # Reading buffer offset
      error: ref Exception            # Current error
      queue: Deque[StreamVector]      # Writer queue
      future: Future[void]            # Stream life future
      case kind*: TransportKind
      of TransportKind.Socket:
        domain: Domain                # Socket transport domain (IPv4/IPv6)
        local: TransportAddress       # Local address
        remote: TransportAddress      # Remote address
      of TransportKind.Pipe:
        todo1: int
      of TransportKind.File:
        todo2: int

type

  StreamCallback* = proc(server: StreamServer,
                         client: StreamTransport): Future[void] {.gcsafe.}
    ## New remote client connection callback
    ## ``server`` - StreamServer object.
    ## ``client`` - accepted client transport.

  TransportInitCallback* = proc(server: StreamServer,
                                fd: AsyncFD): StreamTransport {.gcsafe.}
    ## Custom transport initialization procedure, which can allocated inherited
    ## StreamTransport object.

  StreamServer* = ref object of SocketServer
    ## StreamServer object
    function*: StreamCallback         # callback which will be called after new
                                      # client accepted
    init*: TransportInitCallback      # callback which will be called before
                                      # transport for new client

proc remoteAddress*(transp: StreamTransport): TransportAddress =
  ## Returns ``transp`` remote socket address.
  if transp.kind != TransportKind.Socket:
    raise newException(TransportError, "Socket required!")
  if transp.remote.port == Port(0):
    var saddr: Sockaddr_storage
    var slen = SockLen(sizeof(saddr))
    if getpeername(SocketHandle(transp.fd), cast[ptr SockAddr](addr saddr),
                   addr slen) != 0:
      raiseTransportOsError(osLastError())
    fromSockAddr(saddr, slen, transp.remote.address, transp.remote.port)
  result = transp.remote

proc localAddress*(transp: StreamTransport): TransportAddress =
  ## Returns ``transp`` local socket address.
  if transp.kind != TransportKind.Socket:
    raise newException(TransportError, "Socket required!")
  if transp.local.port == Port(0):
    var saddr: Sockaddr_storage
    var slen = SockLen(sizeof(saddr))
    if getsockname(SocketHandle(transp.fd), cast[ptr SockAddr](addr saddr),
                   addr slen) != 0:
      raiseTransportOsError(osLastError())
    fromSockAddr(saddr, slen, transp.local.address, transp.local.port)
  result = transp.local

template setReadError(t, e: untyped) =
  (t).state.incl(ReadError)
  (t).error = newException(TransportOsError, osErrorMsg((e)))

template checkPending(t: untyped) =
  if not isNil((t).reader):
    raise newException(TransportError, "Read operation already pending!")

template shiftBuffer(t, c: untyped) =
  if (t).offset > c:
    moveMem(addr((t).buffer[0]), addr((t).buffer[(c)]), (t).offset - (c))
    (t).offset = (t).offset - (c)
  else:
    (t).offset = 0

template shiftVectorBuffer(v, o: untyped) =
  (v).buf = cast[pointer](cast[uint]((v).buf) + uint(o))
  (v).buflen -= int(o)

template shiftVectorFile(v, o: untyped) =
  (v).buf = cast[pointer](cast[uint]((v).buf) - cast[uint](o))
  (v).offset += cast[uint]((o))

when defined(windows):

  template zeroOvelappedOffset(t: untyped) =
    (t).offset = 0
    (t).offsetHigh = 0

  template setOverlappedOffset(t, o: untyped) =
    (t).offset = cast[int32](cast[uint64](o) and 0xFFFFFFFF'u64)
    (t).offsetHigh = cast[int32](cast[uint64](o) shr 32)

  template getFileSize(v: untyped): uint =
    cast[uint]((v).buf)

  template getFileHandle(v: untyped): Handle =
    cast[Handle]((v).buflen)

  template slideBuffer(t, o: untyped) =
    (t).wwsabuf.buf = cast[cstring](cast[uint]((t).wwsabuf.buf) + uint(o))
    (t).wwsabuf.len -= int32(o)

  template setReaderWSABuffer(t: untyped) =
    (t).rwsabuf.buf = cast[cstring](
      cast[uint](addr t.buffer[0]) + uint((t).roffset))
    (t).rwsabuf.len = int32(len((t).buffer) - (t).roffset)

  template setWriterWSABuffer(t, v: untyped) =
    (t).wwsabuf.buf = cast[cstring](v.buf)
    (t).wwsabuf.len = cast[int32](v.buflen)

  proc writeStreamLoop(udata: pointer) {.gcsafe, nimcall.} =
    var bytesCount: int32
    var ovl = cast[PtrCustomOverlapped](udata)
    var transp = cast[StreamTransport](ovl.data.udata)

    while len(transp.queue) > 0:
      if WritePending in transp.state:
        ## Continuation
        transp.state.excl(WritePending)
        let err = transp.wovl.data.errCode
        if err == OSErrorCode(-1):
          bytesCount = transp.wovl.data.bytesCount
          var vector = transp.queue.popFirst()
          if bytesCount == 0:
            vector.writer.complete(0)
          else:
            if transp.kind == TransportKind.Socket:
              if vector.kind == VectorKind.DataBuffer:
                if bytesCount < transp.wwsabuf.len:
                  vector.shiftVectorBuffer(bytesCount)
                  transp.queue.addFirst(vector)
                else:
                  vector.writer.complete(transp.wwsabuf.len)
              else:
                if uint(bytesCount) < getFileSize(vector):
                  vector.shiftVectorFile(bytesCount)
                  transp.queue.addFirst(vector)
                else:
                  vector.writer.complete(int(getFileSize(vector)))
        elif int(err) == ERROR_OPERATION_ABORTED:
          # CancelIO() interrupt
          transp.state.incl(WritePaused)
          let v = transp.queue.popFirst()
          v.writer.complete(0)
          break
        else:
          let v = transp.queue.popFirst()
          transp.state.incl(WriteError)
          v.writer.fail(newException(TransportOsError, osErrorMsg(err)))
      else:
        ## Initiation
        transp.state.incl(WritePending)
        if transp.kind == TransportKind.Socket:
          let sock = SocketHandle(transp.wovl.data.fd)
          var vector = transp.queue.popFirst()
          if vector.kind == VectorKind.DataBuffer:
            transp.wovl.zeroOvelappedOffset()
            transp.setWriterWSABuffer(vector)
            let ret = WSASend(sock, addr transp.wwsabuf, 1,
                              addr bytesCount, DWORD(0),
                              cast[POVERLAPPED](addr transp.wovl), nil)
            if ret != 0:
              let err = osLastError()
              if int(err) == ERROR_OPERATION_ABORTED:
                # CancelIO() interrupt
                transp.state.excl(WritePending)
                transp.state.incl(WritePaused)
                vector.writer.complete(0)
              elif int(err) == ERROR_IO_PENDING:
                transp.queue.addFirst(vector)
              else:
                transp.state.excl(WritePending)
                transp.state = transp.state + {WritePaused, WriteError}
                vector.writer.fail(newException(TransportOsError,
                                                osErrorMsg(err)))
            else:
              transp.queue.addFirst(vector)
          else:
            let loop = getGlobalDispatcher()
            var size: int32
            var flags: int32

            if getFileSize(vector) > 2_147_483_646'u:
              size = 2_147_483_646
            else:
              size = int32(getFileSize(vector))

            transp.wovl.setOverlappedOffset(vector.offset)
            var ret = loop.transmitFile(sock, getFileHandle(vector), size, 0,
                                        cast[POVERLAPPED](addr transp.wovl),
                                        nil, flags)
            if ret == 0:
              let err = osLastError()
              if int(err) == ERROR_OPERATION_ABORTED:
                # CancelIO() interrupt
                transp.state.excl(WritePending)
                transp.state.incl(WritePaused)
                vector.writer.complete(0)
              elif int(err) == ERROR_IO_PENDING:
                transp.queue.addFirst(vector)
              else:
                transp.state.excl(WritePending)
                transp.state = transp.state + {WritePaused, WriteError}
                vector.writer.fail(newException(TransportOsError,
                                                osErrorMsg(err)))
            else:
              transp.queue.addFirst(vector)
        break

    if len(transp.queue) == 0:
      transp.state.incl(WritePaused)

  proc readStreamLoop(udata: pointer) {.gcsafe, nimcall.} =
    var ovl = cast[PtrCustomOverlapped](udata)
    var transp = cast[StreamTransport](ovl.data.udata)

    while true:
      if ReadPending in transp.state:
        ## Continuation
        transp.state.excl(ReadPending)
        if ReadClosed in transp.state:
          break
        let err = transp.rovl.data.errCode
        if err == OSErrorCode(-1):
          let bytesCount = transp.rovl.data.bytesCount
          if bytesCount == 0:
            transp.state.incl({ReadEof, ReadPaused})
          else:
            if transp.offset != transp.roffset:
              moveMem(addr transp.buffer[transp.offset],
                      addr transp.buffer[transp.roffset],
                      bytesCount)
            transp.offset += bytesCount
            transp.roffset = transp.offset
            if transp.offset == len(transp.buffer):
              transp.state.incl(ReadPaused)
        elif int(err) == ERROR_OPERATION_ABORTED:
          # CancelIO() interrupt
          transp.state.incl(ReadPaused)
        elif int(err) == ERROR_NETNAME_DELETED:
          transp.state.incl({ReadEof, ReadPaused})
        else:
          transp.setReadError(err)
        if not isNil(transp.reader):
          if not transp.reader.finished:
            transp.reader.complete()
            transp.reader = nil
        if ReadPaused in transp.state:
          # Transport buffer is full, so we will not continue on reading.
          break
      else:
        ## Initiation
        if transp.state * {ReadEof, ReadClosed, ReadError} == {}:
          var flags = DWORD(0)
          var bytesCount: int32 = 0
          transp.state.excl(ReadPaused)
          transp.state.incl(ReadPending)
          if transp.kind == TransportKind.Socket:
            let sock = SocketHandle(transp.rovl.data.fd)
            transp.roffset = transp.offset
            transp.setReaderWSABuffer()
            let ret = WSARecv(sock, addr transp.rwsabuf, 1,
                              addr bytesCount, addr flags,
                              cast[POVERLAPPED](addr transp.rovl), nil)
            if ret != 0:
              let err = osLastError()
              if int(err) == ERROR_OPERATION_ABORTED:
                # CancelIO() interrupt
                transp.state.excl(ReadPending)
                transp.state.incl(ReadPaused)
              elif int32(err) in {WSAECONNRESET, WSAENETRESET}:
                if not isNil(transp.reader):
                  transp.state = {ReadEof, ReadPaused}
                  transp.reader.complete()
                  transp.reader = nil
              elif int32(err) != ERROR_IO_PENDING:
                transp.state.excl(ReadPending)
                transp.state.incl(ReadPaused)
                transp.setReadError(err)
                if not isNil(transp.reader):
                  transp.reader.complete()
                  transp.reader = nil
        ## Finish Loop
        break

  proc newStreamSocketTransport(sock: AsyncFD, bufsize: int,
                                child: StreamTransport): StreamTransport =
    var transp: StreamTransport
    if not isNil(child):
      transp = child
    else:
      transp = StreamTransport(kind: TransportKind.Socket)
    transp.fd = sock
    transp.rovl.data = CompletionData(fd: sock, cb: readStreamLoop,
                                      udata: cast[pointer](transp))
    transp.wovl.data = CompletionData(fd: sock, cb: writeStreamLoop,
                                      udata: cast[pointer](transp))
    transp.buffer = newSeq[byte](bufsize)
    transp.state = {ReadPaused, WritePaused}
    transp.queue = initDeque[StreamVector]()
    transp.future = newFuture[void]("stream.socket.transport")
    GC_ref(transp)
    result = transp

  proc bindToDomain(handle: AsyncFD, domain: Domain): bool =
    result = true
    if domain == Domain.AF_INET6:
      var saddr: Sockaddr_in6
      saddr.sin6_family = int16(toInt(domain))
      if bindAddr(SocketHandle(handle), cast[ptr SockAddr](addr(saddr)),
                  sizeof(saddr).SockLen) != 0'i32:
        result = false
    else:
      var saddr: Sockaddr_in
      saddr.sin_family = int16(toInt(domain))
      if bindAddr(SocketHandle(handle), cast[ptr SockAddr](addr(saddr)),
                  sizeof(saddr).SockLen) != 0'i32:
        result = false

  proc connect*(address: TransportAddress,
                bufferSize = DefaultStreamBufferSize,
                child: StreamTransport = nil): Future[StreamTransport] =
    ## Open new connection to remote peer with address ``address`` and create
    ## new transport object ``StreamTransport`` for established connection.
    ## ``bufferSize`` is size of internal buffer for transport.
    let loop = getGlobalDispatcher()
    var
      saddr: Sockaddr_storage
      slen: SockLen
      sock: AsyncFD
      povl: RefCustomOverlapped

    var retFuture = newFuture[StreamTransport]("stream.transport.connect")
    toSockAddr(address.address, address.port, saddr, slen)
    sock = createAsyncSocket(address.address.getDomain(), SockType.SOCK_STREAM,
                             Protocol.IPPROTO_TCP)
    if sock == asyncInvalidSocket:
      result.fail(newException(TransportOsError, osErrorMsg(osLastError())))

    if not bindToDomain(sock, address.address.getDomain()):
      sock.closeAsyncSocket()
      result.fail(newException(TransportOsError, osErrorMsg(osLastError())))

    proc continuation(udata: pointer) =
      var ovl = cast[RefCustomOverlapped](udata)
      if not retFuture.finished:
        if ovl.data.errCode == OSErrorCode(-1):
          if setsockopt(SocketHandle(sock), cint(SOL_SOCKET),
                        cint(SO_UPDATE_CONNECT_CONTEXT), nil,
                        SockLen(0)) != 0'i32:
            sock.closeAsyncSocket()
            retFuture.fail(newException(TransportOsError,
                                        osErrorMsg(osLastError())))
          else:
            retFuture.complete(newStreamSocketTransport(povl.data.fd,
                                                        bufferSize,
                                                        child))
        else:
          sock.closeAsyncSocket()
          retFuture.fail(newException(TransportOsError,
                                      osErrorMsg(ovl.data.errCode)))
      GC_unref(ovl)

    povl = RefCustomOverlapped()
    GC_ref(povl)
    povl.data = CompletionData(fd: sock, cb: continuation)
    var res = loop.connectEx(SocketHandle(sock),
                             cast[ptr SockAddr](addr saddr),
                             DWORD(slen), nil, 0, nil,
                             cast[POVERLAPPED](povl))
    # We will not process immediate completion, to avoid undefined behavior.
    if not res:
      let err = osLastError()
      if int32(err) != ERROR_IO_PENDING:
        GC_unref(povl)
        sock.closeAsyncSocket()
        retFuture.fail(newException(TransportOsError, osErrorMsg(err)))
    return retFuture

  proc acceptLoop(udata: pointer) {.gcsafe, nimcall.} =
    var ovl = cast[PtrCustomOverlapped](udata)
    var server = cast[StreamServer](ovl.data.udata)
    var loop = getGlobalDispatcher()

    while true:
      if server.apending:
        ## Continuation
        server.apending = false
        if server.status == ServerStatus.Stopped:
          server.asock.closeAsyncSocket()
        else:
          if ovl.data.errCode == OSErrorCode(-1):
            if setsockopt(SocketHandle(server.asock), cint(SOL_SOCKET),
                          cint(SO_UPDATE_ACCEPT_CONTEXT),
                          addr server.sock,
                          SockLen(sizeof(SocketHandle))) != 0'i32:
              server.asock.closeAsyncSocket()
              raiseTransportOsError(osLastError())
            else:
              if not isNil(server.init):
                var transp = server.init(server, server.asock)
                let ntransp = newStreamSocketTransport(server.asock,
                                                       server.bufferSize,
                                                       transp)
                asyncCheck server.function(server, ntransp)
              else:
                let ntransp = newStreamSocketTransport(server.asock,
                                                       server.bufferSize, nil)
                asyncCheck server.function(server, ntransp)
          elif int32(ovl.data.errCode) == ERROR_OPERATION_ABORTED:
            # CancelIO() interrupt
            server.asock.closeAsyncSocket()
            break
          else:
            server.asock.closeAsyncSocket()
            raiseTransportOsError(osLastError())
      else:
        ## Initiation
        if server.status in {ServerStatus.Stopped, ServerStatus.Closed}:
          ## Server was already stopped/closed exiting
          break

        server.apending = true
        server.asock = createAsyncSocket(server.domain, SockType.SOCK_STREAM,
                                         Protocol.IPPROTO_TCP)
        if server.asock == asyncInvalidSocket:
          raiseTransportOsError(osLastError())

        var dwBytesReceived = DWORD(0)
        let dwReceiveDataLength = DWORD(0)
        let dwLocalAddressLength = DWORD(sizeof(Sockaddr_in6) + 16)
        let dwRemoteAddressLength = DWORD(sizeof(Sockaddr_in6) + 16)

        let res = loop.acceptEx(SocketHandle(server.sock),
                                SocketHandle(server.asock),
                                addr server.abuffer[0],
                                dwReceiveDataLength, dwLocalAddressLength,
                                dwRemoteAddressLength, addr dwBytesReceived,
                                cast[POVERLAPPED](addr server.aovl))
        if not res:
          let err = osLastError()
          if int32(err) == ERROR_OPERATION_ABORTED:
            server.apending = false
            break
          elif int32(err) == ERROR_IO_PENDING:
            discard
          else:
            raiseTransportOsError(err)
        break

  proc resumeRead(transp: StreamTransport) {.inline.} =
    transp.state.excl(ReadPaused)
    readStreamLoop(cast[pointer](addr transp.rovl))

  proc resumeWrite(transp: StreamTransport) {.inline.} =
    transp.state.excl(WritePaused)
    writeStreamLoop(cast[pointer](addr transp.wovl))

  proc pauseAccept(server: StreamServer) {.inline.} =
    if server.apending:
      discard cancelIO(Handle(server.sock))

  proc resumeAccept(server: StreamServer) {.inline.} =
    if not server.apending:
      acceptLoop(cast[pointer](addr server.aovl))

else:

  template getVectorBuffer(v: untyped): pointer =
    cast[pointer](cast[uint]((v).buf) + uint((v).boffset))

  template getVectorLength(v: untyped): int =
    cast[int]((v).buflen - int((v).boffset))

  template initBufferStreamVector(v, p, n, t: untyped) =
    (v).kind = DataBuffer
    (v).buf = cast[pointer]((p))
    (v).buflen = int(n)
    (v).writer = (t)

  proc writeStreamLoop(udata: pointer) {.gcsafe.} =
    var cdata = cast[ptr CompletionData](udata)
    if not isNil(cdata) and (int(cdata.fd) == 0 or isNil(cdata.udata)):
      # Transport was closed earlier, exiting
      return
    var transp = cast[StreamTransport](cdata.udata)
    let fd = SocketHandle(cdata.fd)
    if len(transp.queue) > 0:
      var vector = transp.queue.popFirst()
      while true:
        if transp.kind == TransportKind.Socket:
          if vector.kind == VectorKind.DataBuffer:
            let res = posix.send(fd, vector.buf, vector.buflen, MSG_NOSIGNAL)
            if res >= 0:
              if vector.buflen - res == 0:
                vector.writer.complete(vector.buflen)
              else:
                vector.shiftVectorBuffer(res)
                transp.queue.addFirst(vector)
            else:
              let err = osLastError()
              if int(err) == EINTR:
                continue
              else:
                vector.writer.fail(newException(TransportOsError,
                                                osErrorMsg(err)))
          else:
            let res = sendfile(int(fd), cast[int](vector.buflen),
                               int(vector.offset),
                               cast[int](vector.buf))
            if res >= 0:
              if cast[int](vector.buf) - res == 0:
                vector.writer.complete(cast[int](vector.buf))
              else:
                vector.shiftVectorFile(res)
                transp.queue.addFirst(vector)
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

  proc readStreamLoop(udata: pointer) {.gcsafe.} =
    var cdata = cast[ptr CompletionData](udata)
    if not isNil(cdata) and (int(cdata.fd) == 0 or isNil(cdata.udata)):
      # Transport was closed earlier, exiting
      return
    var transp = cast[StreamTransport](cdata.udata)
    let fd = SocketHandle(cdata.fd)
    while true:
      var res = posix.recv(fd, addr transp.buffer[transp.offset],
                           len(transp.buffer) - transp.offset, cint(0))
      if res < 0:
        let err = osLastError()
        if int(err) == EINTR:
          continue
        elif int(err) in {ECONNRESET}:
          transp.state = transp.state + {ReadEof, ReadPaused}
          cdata.fd.removeReader()
        else:
          transp.setReadError(err)
          cdata.fd.removeReader()
      elif res == 0:
        transp.state = transp.state + {ReadEof, ReadPaused}
        cdata.fd.removeReader()
      else:
        transp.offset += res
        if transp.offset == len(transp.buffer):
          transp.state.incl(ReadPaused)
          cdata.fd.removeReader()
      if not isNil(transp.reader):
        transp.finishReader()
      break

  proc newStreamSocketTransport(sock: AsyncFD, bufsize: int,
                                child: StreamTransport): StreamTransport =
    var transp: StreamTransport
    if not isNil(child):
      transp = child
    else:
      transp = StreamTransport(kind: TransportKind.Socket)

    transp.fd = sock
    transp.buffer = newSeq[byte](bufsize)
    transp.state = {ReadPaused, WritePaused}
    transp.queue = initDeque[StreamVector]()
    transp.future = newFuture[void]("socket.stream.transport")
    GC_ref(transp)
    result = transp

  proc connect*(address: TransportAddress,
                bufferSize = DefaultStreamBufferSize,
                child: StreamTransport = nil): Future[StreamTransport] =
    ## Open new connection to remote peer with address ``address`` and create
    ## new transport object ``StreamTransport`` for established connection.
    ## ``bufferSize`` - size of internal buffer for transport.
    var
      saddr: Sockaddr_storage
      slen: SockLen
      sock: AsyncFD
    var retFuture = newFuture[StreamTransport]("transport.connect")
    toSockAddr(address.address, address.port, saddr, slen)
    sock = createAsyncSocket(address.address.getDomain(), SockType.SOCK_STREAM,
                             Protocol.IPPROTO_TCP)
    if sock == asyncInvalidSocket:
      retFuture.fail(newException(TransportOsError, osErrorMsg(osLastError())))
      return retFuture

    proc continuation(udata: pointer) =
      var data = cast[ptr CompletionData](udata)
      var err = 0
      let fd = data.fd
      if not fd.getSocketError(err):
        fd.closeAsyncSocket()
        retFuture.fail(newException(TransportOsError,
                                    osErrorMsg(osLastError())))
        return
      if err != 0:
        fd.closeAsyncSocket()
        retFuture.fail(newException(TransportOsError,
                                    osErrorMsg(OSErrorCode(err))))
        return
      fd.removeWriter()
      retFuture.complete(newStreamSocketTransport(fd, bufferSize, child))

    while true:
      var res = posix.connect(SocketHandle(sock),
                              cast[ptr SockAddr](addr saddr), slen)
      if res == 0:
        retFuture.complete(newStreamSocketTransport(sock, bufferSize, child))
        break
      else:
        let err = osLastError()
        if int(err) == EINTR:
          continue
        elif int(err) == EINPROGRESS:
          sock.addWriter(continuation)
          break
        else:
          sock.closeAsyncSocket()
          retFuture.fail(newException(TransportOsError, osErrorMsg(err)))
          break
    return retFuture

  proc acceptLoop(udata: pointer) =
    var
      saddr: Sockaddr_storage
      slen: SockLen
    var server = cast[StreamServer](cast[ptr CompletionData](udata).udata)
    while true:
      let res = posix.accept(SocketHandle(server.sock),
                             cast[ptr SockAddr](addr saddr), addr slen)
      if int(res) > 0:
        let sock = wrapAsyncSocket(res)
        if sock != asyncInvalidSocket:
          if not isNil(server.init):
            var transp = server.init(server, sock)
            asyncCheck server.function(server,
              newStreamSocketTransport(sock, server.bufferSize, transp))
          else:
            asyncCheck server.function(server,
              newStreamSocketTransport(sock, server.bufferSize, nil))
          break
      else:
        let err = osLastError()
        if int(err) == EINTR:
          continue
        else:
          ## Critical unrecoverable error
          raiseTransportOsError(err)

  proc resumeAccept(server: StreamServer) =
    addReader(server.sock, acceptLoop, cast[pointer](server))

  proc pauseAccept(server: StreamServer) =
    removeReader(server.sock)

  proc resumeRead(transp: StreamTransport) {.inline.} =
    transp.state.excl(ReadPaused)
    addReader(transp.fd, readStreamLoop, cast[pointer](transp))

  proc resumeWrite(transp: StreamTransport) {.inline.} =
    transp.state.excl(WritePaused)
    addWriter(transp.fd, writeStreamLoop, cast[pointer](transp))

proc start*(server: StreamServer) =
  ## Starts ``server``.
  if server.status == ServerStatus.Starting:
    server.resumeAccept()
    server.status = ServerStatus.Running

proc stop*(server: StreamServer) =
  ## Stops ``server``.
  if server.status == ServerStatus.Running:
    server.pauseAccept()
    server.status = ServerStatus.Stopped
  elif server.status == ServerStatus.Starting:
    server.status = ServerStatus.Stopped

proc join*(server: StreamServer) {.async.} =
  ## Waits until ``server`` is not closed.
  if not server.loopFuture.finished:
    await server.loopFuture

proc close*(server: StreamServer) =
  ## Release ``server`` resources.
  if server.status == ServerStatus.Stopped:
    closeAsyncSocket(server.sock)
    server.status = ServerStatus.Closed
    server.loopFuture.complete()
    if not isNil(server.udata) and GCUserData in server.flags:
      GC_unref(cast[ref int](server.udata))
    GC_unref(server)

proc createStreamServer*(host: TransportAddress,
                         cbproc: StreamCallback,
                         flags: set[ServerFlags] = {},
                         sock: AsyncFD = asyncInvalidSocket,
                         backlog: int = 100,
                         bufferSize: int = DefaultStreamBufferSize,
                         child: StreamServer = nil,
                         init: TransportInitCallback = nil,
                         udata: pointer = nil): StreamServer =
  ## Create new TCP stream server.
  ##
  ## ``host`` - address to which server will be bound.
  ## ``flags`` - flags to apply to server socket.
  ## ``cbproc`` - callback function which will be called, when new client
  ## connection will be established.
  ## ``sock`` - user-driven socket to use.
  ## ``backlog`` -  number of outstanding connections in the socket's listen
  ## queue.
  ## ``bufferSize`` - size of internal buffer for transport.
  ## ``child`` - existing object ``StreamServer``object to initialize, can be
  ## used to initalize ``StreamServer`` inherited objects.
  ## ``udata`` - user-defined pointer.
  var
    saddr: Sockaddr_storage
    slen: SockLen
    serverSocket: AsyncFD
  if sock == asyncInvalidSocket:
    serverSocket = createAsyncSocket(host.address.getDomain(),
                                     SockType.SOCK_STREAM,
                                     Protocol.IPPROTO_TCP)
    if serverSocket == asyncInvalidSocket:
      raiseTransportOsError(osLastError())
  else:
    if not setSocketBlocking(SocketHandle(sock), false):
      raiseTransportOsError(osLastError())
    register(sock)
    serverSocket = sock

  if ServerFlags.ReuseAddr in flags:
    if not setSockOpt(serverSocket, SOL_SOCKET, SO_REUSEADDR, 1):
      let err = osLastError()
      if sock == asyncInvalidSocket:
        closeAsyncSocket(serverSocket)
      raiseTransportOsError(err)

  toSockAddr(host.address, host.port, saddr, slen)
  if bindAddr(SocketHandle(serverSocket), cast[ptr SockAddr](addr saddr),
              slen) != 0:
    let err = osLastError()
    if sock == asyncInvalidSocket:
      closeAsyncSocket(serverSocket)
    raiseTransportOsError(err)

  if nativesockets.listen(SocketHandle(serverSocket), cint(backlog)) != 0:
    let err = osLastError()
    if sock == asyncInvalidSocket:
      closeAsyncSocket(serverSocket)
    raiseTransportOsError(err)

  if not isNil(child):
    result = child
  else:
    result = StreamServer()

  result.sock = serverSocket
  result.function = cbproc
  result.init = init
  result.bufferSize = bufferSize
  result.status = Starting
  result.loopFuture = newFuture[void]("stream.server")
  result.udata = udata
  result.local = host

  when defined(windows):
    result.aovl.data = CompletionData(fd: serverSocket, cb: acceptLoop,
                                      udata: cast[pointer](result))
    result.domain = host.address.getDomain()
    result.apending = false
  GC_ref(result)

proc createStreamServer*[T](host: TransportAddress,
                            cbproc: StreamCallback,
                            flags: set[ServerFlags] = {},
                            udata: ref T,
                            sock: AsyncFD = asyncInvalidSocket,
                            backlog: int = 100,
                            bufferSize: int = DefaultStreamBufferSize,
                            child: StreamServer = nil,
                            init: TransportInitCallback = nil): StreamServer =
  var fflags = flags + {GCUserData}
  GC_ref(udata)
  result = createStreamServer(host, cbproc, flags, sock, backlog, bufferSize,
                              child, init, cast[pointer](udata))

proc getUserData*[T](server: StreamServer): T {.inline.} =
  ## Obtain user data stored in ``server`` object.
  result = cast[T](server.udata)

proc write*(transp: StreamTransport, pbytes: pointer,
            nbytes: int): Future[int] =
  ## Write data from buffer ``pbytes`` with size ``nbytes`` using transport
  ## ``transp``.
  var retFuture = newFuture[int]()
  transp.checkClosed(retFuture)
  var vector = StreamVector(kind: DataBuffer, writer: retFuture,
                            buf: pbytes, buflen: nbytes)
  transp.queue.addLast(vector)
  if WritePaused in transp.state:
    transp.resumeWrite()
  return retFuture

proc write*(transp: StreamTransport, msg: string, msglen = -1): Future[int] =
  ## Write data from string ``msg`` using transport ``transp``.
  var retFuture = FutureGCString[int]()
  transp.checkClosed(retFuture)
  if not isLiteral(msg):
    shallowCopy(retFuture.gcholder, msg)
  let length = if msglen <= 0: len(msg) else: msglen
  var vector = StreamVector(kind: DataBuffer,
                            writer: cast[Future[int]](retFuture),
                            buf: addr retFuture.gcholder[0], buflen: length)
  transp.queue.addLast(vector)
  if WritePaused in transp.state:
    transp.resumeWrite()
  return retFuture

proc write*[T](transp: StreamTransport, msg: seq[T], msglen = -1): Future[int] =
  ## Write sequence ``msg`` using transport ``transp``.
  var retFuture = FutureGCSeq[int, T]()
  transp.checkClosed(retFuture)
  if not isLiteral(msg):
    shallowCopy(retFuture.gcholder, msg)
  let length = if msglen <= 0: (len(msg) * sizeof(T)) else: (msglen * sizeof(T))
  var vector = StreamVector(kind: DataBuffer,
                            writer: cast[Future[int]](retFuture),
                            buf: addr retFuture.gcholder[0],
                            buflen: length)
  transp.queue.addLast(vector)
  if WritePaused in transp.state:
    transp.resumeWrite()
  return retFuture

proc writeFile*(transp: StreamTransport, handle: int,
                offset: uint = 0, size: int = 0): Future[int] =
  ## Write data from file descriptor ``handle`` to transport ``transp``.
  ##
  ## You can specify starting ``offset`` in opened file and number of bytes
  ## to transfer from file to transport via ``size``.
  var retFuture = newFuture[int]("transport.writeFile")
  transp.checkClosed(retFuture)
  var vector = StreamVector(kind: DataFile, writer: retFuture,
                            buf: cast[pointer](size), offset: offset,
                            buflen: handle)
  transp.queue.addLast(vector)
  if WritePaused in transp.state:
    transp.resumeWrite()
  return retFuture

proc atEof*(transp: StreamTransport): bool {.inline.} =
  ## Returns ``true`` if ``transp`` is at EOF.
  result = (transp.offset == 0) and (ReadEof in transp.state) and
           (ReadPaused in transp.state)

proc readExactly*(transp: StreamTransport, pbytes: pointer,
                  nbytes: int) {.async.} =
  ## Read exactly ``nbytes`` bytes from transport ``transp`` and store it to
  ## ``pbytes``.
  ##
  ## If EOF is received and ``nbytes`` is not yet readed, the procedure
  ## will raise ``TransportIncompleteError``.
  checkClosed(transp)
  checkPending(transp)
  var index = 0
  while true:
    if transp.offset == 0:
      if (ReadError in transp.state):
        raise transp.getError()
      if (ReadClosed in transp.state) or transp.atEof():
        raise newException(TransportIncompleteError, "Data incomplete!")

    if transp.offset >= (nbytes - index):
      copyMem(cast[pointer](cast[uint](pbytes) + uint(index)),
              addr(transp.buffer[0]), nbytes - index)
      transp.shiftBuffer(nbytes - index)
      break
    else:
      if transp.offset != 0:
        copyMem(cast[pointer](cast[uint](pbytes) + uint(index)),
                addr(transp.buffer[0]), transp.offset)
        index += transp.offset

      transp.reader = newFuture[void]("stream.transport.readExactly")
      transp.offset = 0
      if ReadPaused in transp.state:
        transp.resumeRead()
      await transp.reader

proc readOnce*(transp: StreamTransport, pbytes: pointer,
               nbytes: int): Future[int] {.async.} =
  ## Perform one read operation on transport ``transp``.
  ##
  ## If internal buffer is not empty, ``nbytes`` bytes will be transferred from
  ## internal buffer, otherwise it will wait until some bytes will be received.
  checkClosed(transp)
  checkPending(transp)
  while true:
    if transp.offset == 0:
      if (ReadError in transp.state):
        raise transp.getError()
      if (ReadClosed in transp.state) or transp.atEof():
        result = 0
        break
      transp.reader = newFuture[void]("stream.transport.readOnce")
      if ReadPaused in transp.state:
        transp.resumeRead()
      await transp.reader
      # we need to clear transp.reader to avoid double completion of this
      # Future[T], because readLoop continues working.
      transp.reader = nil
    else:
      if transp.offset > nbytes:
        copyMem(pbytes, addr(transp.buffer[0]), nbytes)
        transp.shiftBuffer(nbytes)
        result = nbytes
      else:
        copyMem(pbytes, addr(transp.buffer[0]), transp.offset)
        result = transp.offset
      break

proc readUntil*(transp: StreamTransport, pbytes: pointer, nbytes: int,
                sep: seq[byte]): Future[int] {.async.} =
  ## Read data from the transport ``transp`` until separator ``sep`` is found.
  ##
  ## On success, the data and separator will be removed from the internal
  ## buffer (consumed). Returned data will NOT include the separator at the end.
  ##
  ## If EOF is received, and `sep` was not found, procedure will raise
  ## ``TransportIncompleteError``.
  ##
  ## If ``nbytes`` bytes has been received and `sep` was not found, procedure
  ## will raise ``TransportLimitError``.
  ##
  ## Procedure returns actual number of bytes read.
  checkClosed(transp)
  checkPending(transp)

  var dest = cast[ptr UncheckedArray[byte]](pbytes)
  var state = 0
  var k = 0
  var index = 0

  while true:
    if ReadError in transp.state:
      raise transp.getError()
    if (ReadClosed in transp.state) or transp.atEof():
      raise newException(TransportIncompleteError, "Data incomplete!")

    index = 0
    while index < transp.offset:
      let ch = transp.buffer[index]
      if sep[state] == ch:
        inc(state)
      else:
        state = 0
      if k < nbytes:
        dest[k] = ch
        inc(k)
      else:
        raise newException(TransportLimitError, "Limit reached!")
      if state == len(sep):
        break
      inc(index)

    if state == len(sep):
      transp.shiftBuffer(index + 1)
      result = k
      break
    else:
      transp.shiftBuffer(transp.offset)
      transp.reader = newFuture[void]("stream.transport.readUntil")
      if ReadPaused in transp.state:
        transp.resumeRead()
      await transp.reader

proc readLine*(transp: StreamTransport, limit = 0,
               sep = "\r\n"): Future[string] {.async.} =
  ## Read one line from transport ``transp``, where "line" is a sequence of
  ## bytes ending with ``sep`` (default is "\r\n").
  ##
  ## If EOF is received, and ``sep`` was not found, the method will return the
  ## partial read bytes.
  ##
  ## If the EOF was received and the internal buffer is empty, return an
  ## empty string.
  ##
  ## If ``limit`` more then 0, then read is limited to ``limit`` bytes.
  checkClosed(transp)
  checkPending(transp)

  result = ""
  var lim = if limit <= 0: -1 else: limit
  var state = 0
  var index = 0

  while true:
    if (ReadError in transp.state):
      raise transp.getError()
    if (ReadClosed in transp.state) or transp.atEof():
      break

    index = 0
    while index < transp.offset:
      let ch = char(transp.buffer[index])
      if sep[state] == ch:
        inc(state)
        if state == len(sep):
          transp.shiftBuffer(index + 1)
          break
      else:
        state = 0
        result.add(ch)
        if len(result) == lim:
          transp.shiftBuffer(index + 1)
          break
      inc(index)

    if (state == len(sep)) or (lim == len(result)):
      break
    else:
      transp.shiftBuffer(transp.offset)
      transp.reader = newFuture[void]("stream.transport.readLine")
      if ReadPaused in transp.state:
        transp.resumeRead()
      await transp.reader

proc read*(transp: StreamTransport, n = -1): Future[seq[byte]] {.async.} =
  ## Read all bytes (n == -1) or exactly `n` bytes from transport ``transp``.
  ##
  ## This procedure allocates buffer seq[byte] and return it as result.
  checkClosed(transp)
  checkPending(transp)
  result = newSeq[byte]()
  while true:
    if (ReadError in transp.state):
      raise transp.getError()
    if (ReadClosed in transp.state) or transp.atEof():
      break

    if transp.offset > 0:
      let s = len(result)
      let o = s + transp.offset
      if n == -1:
        # grabbing all incoming data, until EOF
        result.setLen(o)
        copyMem(cast[pointer](addr result[s]), addr(transp.buffer[0]),
                transp.offset)
        transp.offset = 0
      else:
        let left = n - s
        if transp.offset >= left:
          # size of buffer data is more then we need, grabbing only part
          result.setLen(n)
          copyMem(cast[pointer](addr result[s]), addr(transp.buffer[0]),
                  left)
          transp.shiftBuffer(left)
          break
        else:
          # there not enough data in buffer, grabbing all
          result.setLen(o)
          copyMem(cast[pointer](addr result[s]), addr(transp.buffer[0]),
                  transp.offset)
          transp.offset = 0

    transp.reader = newFuture[void]("stream.transport.read")
    if ReadPaused in transp.state:
      transp.resumeRead()
    await transp.reader

proc consume*(transp: StreamTransport, n = -1): Future[int] {.async.} =
  ## Consume all bytes (n == -1) or ``n`` bytes from transport ``transp``.
  ##
  ## Return number of bytes actually consumed
  checkClosed(transp)
  checkPending(transp)
  result = 0
  while true:
    if (ReadError in transp.state):
      raise transp.getError()
    if ReadClosed in transp.state or transp.atEof():
      break

    if transp.offset > 0:
      if n == -1:
        # consume all incoming data, until EOF
        result += transp.offset
        transp.offset = 0
      else:
        let left = n - result
        if transp.offset >= left:
          # size of buffer data is more then we need, consume only part
          result += left
          transp.shiftBuffer(left)
          break
        else:
          # there not enough data in buffer, consume all
          result += transp.offset
          transp.offset = 0

    transp.reader = newFuture[void]("stream.transport.consume")
    if ReadPaused in transp.state:
      transp.resumeRead()
    await transp.reader

proc join*(transp: StreamTransport) {.async.} =
  ## Wait until ``transp`` will not be closed.
  if not transp.future.finished:
    await transp.future

proc close*(transp: StreamTransport) =
  ## Closes and frees resources of transport ``transp``.
  if {ReadClosed, WriteClosed} * transp.state == {}:
    when defined(windows):
      discard cancelIo(Handle(transp.fd))
    closeAsyncSocket(transp.fd)
    transp.state.incl({WriteClosed, ReadClosed})
    transp.future.complete()
    GC_unref(transp)

proc closed*(transp: StreamTransport): bool {.inline.} =
  ## Returns ``true`` if transport in closed state.
  result = ({ReadClosed, WriteClosed} * transp.state != {})

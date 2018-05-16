#
#             Asyncdispatch2 Stream Transport
#                 (c) Copyright 2018
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

import ../asyncloop, ../asyncsync, ../handles
import common
import net, nativesockets, os, deques, strutils

type
  VectorKind = enum
    DataBuffer,                   # Simple buffer pointer/length
    DataFile                      # File handle for sendfile/TransmitFile

when defined(windows):
  import winlean
  type
    StreamVector = object
      kind: VectorKind            # Writer vector source kind
      dataBuf: ptr TWSABuf        # Writer vector buffer
      offset: uint                # Writer vector offset
      writer: Future[void]        # Writer vector completion Future

else:
  import posix
  type
    StreamVector = object
      kind: VectorKind            # Writer vector source kind
      buf: pointer                # Writer buffer pointer
      buflen: int                 # Writer buffer size
      offset: uint                # Writer vector offset
      writer: Future[void]        # Writer vector completion Future

type
  TransportKind* {.pure.} = enum
    Socket,                       # Socket transport
    Pipe,                         # Pipe transport
    File                          # File transport

type
  StreamTransport* = ref object of RootRef
    fd: AsyncFD                     # File descriptor
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
      fd0: AsyncFD
      fd1: AsyncFD
    of TransportKind.File:
      length: int

  StreamCallback* = proc(t: StreamTransport,
                         udata: pointer): Future[void] {.gcsafe.}

  StreamServer* = ref object of SocketServer
    function*: StreamCallback

proc remoteAddress*(transp: StreamTransport): TransportAddress =
  ## Returns ``transp`` remote socket address.
  if transp.kind != TransportKind.Socket:
    raise newException(TransportError, "Socket required!")
  if transp.remote.port == Port(0):
    var saddr: Sockaddr_storage
    var slen = SockLen(sizeof(saddr))
    if getpeername(SocketHandle(transp.fd), cast[ptr SockAddr](addr saddr),
                   addr slen) != 0:
      raiseOsError(osLastError())
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
      raiseOsError(osLastError())
    fromSockAddr(saddr, slen, transp.local.address, transp.local.port)
  result = transp.local

template setReadError(t, e: untyped) =
  (t).state.incl(ReadError)
  (t).error = newException(TransportOsError, osErrorMsg((e)))

template setWriteError(t, e: untyped) =
  (t).state.incl(WriteError)
  (t).error = newException(TransportOsError, osErrorMsg((e)))

template finishReader(t: untyped) =
  var reader = (t).reader
  (t).reader = nil
  reader.complete()

template checkPending(t: untyped) =
  if not isNil((t).reader):
    raise newException(TransportError, "Read operation already pending!")

# template shiftBuffer(t, c: untyped) =
#   let length = len((t).buffer)
#   if length > c:
#     moveMem(addr((t).buffer[0]), addr((t).buffer[(c)]), length - (c))
#     (t).offset = (t).offset - (c)
#   else:
#     (t).offset = 0

template shiftBuffer(t, c: untyped) =
  if (t).offset > c:
    moveMem(addr((t).buffer[0]), addr((t).buffer[(c)]), (t).offset - (c))
    (t).offset = (t).offset - (c)
  else:
    (t).offset = 0

when defined(windows):
  import winlean
  type
    WindowsStreamTransport = ref object of StreamTransport
      wsabuf: TWSABuf             # Reader WSABUF
      rovl: CustomOverlapped      # Reader OVERLAPPED structure
      wovl: CustomOverlapped      # Writer OVERLAPPED structure
      roffset: int                # Pending reading offset

    WindowsStreamServer* = ref object of RootRef
      server: SocketServer        # Server object
      domain: Domain
      abuffer: array[128, byte]
      aovl: CustomOverlapped

  const SO_UPDATE_CONNECT_CONTEXT = 0x7010

  template finishWriter(t: untyped) =
    var vv = (t).queue.popFirst()
    vv.writer.complete()

  template zeroOvelappedOffset(t: untyped) =
    (t).offset = 0
    (t).offsetHigh = 0

  template setOverlappedOffset(t, o: untyped) =
    (t).offset = cast[int32](cast[uint64](o) and 0xFFFFFFFF'u64)
    (t).offsetHigh = cast[int32](cast[uint64](o) shr 32)

  template getFileSize(t: untyped): uint =
    cast[uint]((t).dataBuf.buf)

  template getFileHandle(t: untyped): Handle =
    cast[Handle]((t).dataBuf.len)

  template slideOffset(v, o: untyped) =
    let s = cast[uint]((v).dataBuf.buf) - cast[uint]((o))
    (v).dataBuf.buf = cast[cstring](s)
    (v).offset = (v).offset + cast[uint]((o))

  template slideBuffer(t, o: untyped) =
    (t).dataBuf.buf = cast[cstring](cast[uint]((t).dataBuf.buf) + uint(o))
    (t).dataBuf.len -= int32(o)

  template setWSABuffer(t: untyped) =
    (t).wsabuf.buf = cast[cstring](
      cast[uint](addr t.buffer[0]) + uint((t).roffset))
    (t).wsabuf.len = int32(len((t).buffer) - (t).roffset)

  # template initTransmitStreamVector(v, h, o, n, t: untyped) =
  #   (v).kind = DataFile
  #   (v).dataBuf.buf = cast[cstring]((n))
  #   (v).dataBuf.len = cast[int32]((h))
  #   (v).offset = cast[uint]((o))
  #   (v).writer = (t)

  proc writeStreamLoop(udata: pointer) {.gcsafe.} =
    var bytesCount: int32
    if isNil(udata):
      return
    var ovl = cast[PCustomOverlapped](udata)
    var transp = cast[WindowsStreamTransport](ovl.data.udata)

    while len(transp.queue) > 0:
      if WritePending in transp.state:
        ## Continuation
        transp.state.excl(WritePending)
        let err = transp.wovl.data.errCode
        if err == OSErrorCode(-1):
          bytesCount = transp.wovl.data.bytesCount
          var vector = transp.queue.popFirst()
          if bytesCount == 0:
            vector.writer.complete()
          else:
            if transp.kind == TransportKind.Socket:
              if vector.kind == VectorKind.DataBuffer:
                if bytesCount < vector.dataBuf.len:
                  vector.slideBuffer(bytesCount)
                  transp.queue.addFirst(vector)
                else:
                  vector.writer.complete()
              else:
                if uint(bytesCount) < getFileSize(vector):
                  vector.slideOffset(bytesCount)
                  transp.queue.addFirst(vector)
                else:
                  vector.writer.complete()
        else:
          transp.setWriteError(err)
          transp.finishWriter()
      else:
        ## Initiation
        transp.state.incl(WritePending)
        if transp.kind == TransportKind.Socket:
          let sock = SocketHandle(transp.wovl.data.fd)
          var vector = transp.queue.popFirst()
          if vector.kind == VectorKind.DataBuffer:
            transp.wovl.zeroOvelappedOffset()
            let ret = WSASend(sock, vector.dataBuf, 1,
                              addr bytesCount, DWORD(0),
                              cast[POVERLAPPED](addr transp.wovl), nil)
            if ret != 0:
              let err = osLastError()
              if int(err) == ERROR_OPERATION_ABORTED:
                transp.state.incl(WritePaused)
              elif int(err) == ERROR_IO_PENDING:
                transp.queue.addFirst(vector)
              else:
                transp.state.excl(WritePending)
                transp.setWriteError(err)
                transp.finishWriter()
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
                transp.state.incl(WritePaused)
              elif int(err) == ERROR_IO_PENDING:
                transp.queue.addFirst(vector)
              else:
                transp.state.excl(WritePending)
                transp.setWriteError(err)
                transp.finishWriter()
            else:
              transp.queue.addFirst(vector)
        break

    if len(transp.queue) == 0:
      transp.state.incl(WritePaused)

  proc readStreamLoop(udata: pointer) {.gcsafe.} =
    if isNil(udata):
      return
    var ovl = cast[PCustomOverlapped](udata)
    var transp = cast[WindowsStreamTransport](ovl.data.udata)

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
          else:
            if transp.offset != transp.roffset:
              moveMem(addr transp.buffer[transp.offset],
                      addr transp.buffer[transp.roffset],
                      bytesCount)
            transp.offset += bytesCount
            transp.roffset = transp.offset
            if transp.offset == len(transp.buffer):
              transp.state.incl(ReadPaused)
        else:
          transp.setReadError(err)
        if not isNil(transp.reader):
          transp.finishReader()
      else:
        ## Initiation
        if (ReadEof notin transp.state) and (ReadClosed notin transp.state):
          var flags = DWORD(0)
          var bytesCount: int32 = 0
          transp.state.excl(ReadPaused)
          transp.state.incl(ReadPending)
          if transp.kind == TransportKind.Socket:
            let sock = SocketHandle(transp.rovl.data.fd)
            transp.setWSABuffer()
            let ret = WSARecv(sock, addr transp.wsabuf, 1,
                              addr bytesCount, addr flags,
                              cast[POVERLAPPED](addr transp.rovl), nil)
            if ret != 0:
              let err = osLastError()
              if int(err) == ERROR_OPERATION_ABORTED:
                transp.state.incl(ReadPaused)
              elif int32(err) != ERROR_IO_PENDING:
                transp.setReadError(err)
                if not isNil(transp.reader):
                  transp.finishReader()
        ## Finish Loop
        break

  proc newStreamSocketTransport(sock: AsyncFD, bufsize: int): StreamTransport =
    var t = WindowsStreamTransport(kind: TransportKind.Socket)
    t.fd = sock
    t.rovl.data = CompletionData(fd: sock, cb: readStreamLoop,
                                 udata: cast[pointer](t))
    t.wovl.data = CompletionData(fd: sock, cb: writeStreamLoop,
                                 udata: cast[pointer](t))
    t.buffer = newSeq[byte](bufsize)
    t.state = {ReadPaused, WritePaused}
    t.queue = initDeque[StreamVector]()
    t.future = newFuture[void]("stream.socket.transport")
    result = cast[StreamTransport](t)

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
                bufferSize = DefaultStreamBufferSize): Future[StreamTransport] =
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
      result.fail(newException(OSError, osErrorMsg(osLastError())))

    if not bindToDomain(sock, address.address.getDomain()):
      sock.closeAsyncSocket()
      result.fail(newException(OSError, osErrorMsg(osLastError())))

    proc continuation(udata: pointer) =
      var ovl = cast[PCustomOverlapped](udata)
      if not retFuture.finished:
        if ovl.data.errCode == OSErrorCode(-1):
          if setsockopt(SocketHandle(sock), cint(SOL_SOCKET),
                        cint(SO_UPDATE_CONNECT_CONTEXT), nil,
                        SockLen(0)) != 0'i32:
            sock.closeAsyncSocket()
            retFuture.fail(newException(OSError, osErrorMsg(osLastError())))
          else:
            retFuture.complete(newStreamSocketTransport(povl.data.fd,
                                                        bufferSize))
        else:
          sock.closeAsyncSocket()
          retFuture.fail(newException(OSError, osErrorMsg(ovl.data.errCode)))

    povl = RefCustomOverlapped()
    povl.data = CompletionData(fd: sock, cb: continuation)
    var res = loop.connectEx(SocketHandle(sock),
                             cast[ptr SockAddr](addr saddr),
                             DWORD(slen), nil, 0, nil,
                             cast[POVERLAPPED](povl))
    # We will not process immediate completion, to avoid undefined behavior.
    if not res:
      let err = osLastError()
      if int32(err) != ERROR_IO_PENDING:
        sock.closeAsyncSocket()
        retFuture.fail(newException(OSError, osErrorMsg(err)))
    return retFuture

  proc acceptAddr(server: WindowsStreamServer): Future[AsyncFD] =
    var retFuture = newFuture[AsyncFD]("transport.acceptAddr")
    let loop = getGlobalDispatcher()
    var sock = createAsyncSocket(server.domain, SockType.SOCK_STREAM,
                                 Protocol.IPPROTO_TCP)
    if sock == asyncInvalidSocket:
      retFuture.fail(newException(OSError, osErrorMsg(osLastError())))

    var dwBytesReceived = DWORD(0)
    let dwReceiveDataLength = DWORD(0)
    let dwLocalAddressLength = DWORD(sizeof(Sockaddr_in6) + 16)
    let dwRemoteAddressLength = DWORD(sizeof(Sockaddr_in6) + 16)

    proc continuation(udata: pointer) =
      var ovl = cast[PCustomOverlapped](udata)
      if not retFuture.finished:
        if server.server.status in {Stopped, Paused}:
          sock.closeAsyncSocket()
          retFuture.complete(asyncInvalidSocket)
        else:
          if ovl.data.errCode == OSErrorCode(-1):
            if setsockopt(SocketHandle(sock), cint(SOL_SOCKET),
                          cint(SO_UPDATE_ACCEPT_CONTEXT),
                          addr server.server.sock,
                          SockLen(sizeof(SocketHandle))) != 0'i32:
              sock.closeAsyncSocket()
              retFuture.fail(newException(OSError, osErrorMsg(osLastError())))
            else:
              retFuture.complete(sock)
          else:
            sock.closeAsyncSocket()
            retFuture.fail(newException(OSError, osErrorMsg(ovl.data.errCode)))

    server.aovl.data.fd = server.server.sock
    server.aovl.data.cb = continuation

    let res = loop.acceptEx(SocketHandle(server.server.sock),
                            SocketHandle(sock), addr server.abuffer[0],
                            dwReceiveDataLength, dwLocalAddressLength,
                            dwRemoteAddressLength, addr dwBytesReceived,
                            cast[POVERLAPPED](addr server.aovl))

    if not res:
      let err = osLastError()
      if int32(err) != ERROR_IO_PENDING:
        retFuture.fail(newException(OSError, osErrorMsg(err)))
    return retFuture

  proc serverLoop(server: StreamServer): Future[void] {.async.} =
    ## TODO: This procedure must be reviewed, when cancellation support
    ## will be added
    var wserver = new WindowsStreamServer
    wserver.server = server
    wserver.domain = server.local.address.getDomain()
    await server.actEvent.wait()
    server.actEvent.clear()
    if server.action == ServerCommand.Start:
      var eventFut = server.actEvent.wait()
      while true:
        var acceptFut = acceptAddr(wserver)
        await eventFut or acceptFut
        if eventFut.finished:
          if server.action == ServerCommand.Start:
            if server.status in {Stopped, Paused}:
              server.status = Running
          elif server.action == ServerCommand.Stop:
            if server.status in {Running}:
              server.status = Stopped
              break
            elif server.status in {Paused}:
              server.status = Stopped
              break
          elif server.action == ServerCommand.Pause:
            if server.status in {Running}:
              server.status = Paused
        if acceptFut.finished:
          if not acceptFut.failed:
            var sock = acceptFut.read()
            if sock != asyncInvalidSocket:
              spawn server.function(
                newStreamSocketTransport(sock, server.bufferSize),
                server.udata)

  proc resumeRead(transp: StreamTransport) {.inline.} =
    var wtransp = cast[WindowsStreamTransport](transp)
    wtransp.state.excl(ReadPaused)
    readStreamLoop(cast[pointer](addr wtransp.rovl))

  proc resumeWrite(transp: StreamTransport) {.inline.} =
    var wtransp = cast[WindowsStreamTransport](transp)
    wtransp.state.excl(WritePaused)
    writeStreamLoop(cast[pointer](addr wtransp.wovl))

else:
  import posix

  type
    UnixStreamTransport* = ref object of StreamTransport

  template getVectorBuffer(v: untyped): pointer =
    cast[pointer](cast[uint]((v).buf) + uint((v).boffset))

  template getVectorLength(v: untyped): int =
    cast[int]((v).buflen - int((v).boffset))

  template shiftVectorBuffer(t, o: untyped) =
    (t).buf = cast[pointer](cast[uint]((t).buf) + uint(o))
    (t).buflen -= int(o)

  template initBufferStreamVector(v, p, n, t: untyped) =
    (v).kind = DataBuffer
    (v).buf = cast[pointer]((p))
    (v).buflen = int(n)
    (v).writer = (t)

  proc writeStreamLoop(udata: pointer) {.gcsafe.} =
    var cdata = cast[ptr CompletionData](udata)
    var transp = cast[UnixStreamTransport](cdata.udata)
    let fd = SocketHandle(cdata.fd)
    if not isNil(transp):
      if len(transp.queue) > 0:
        echo "len(transp.queue) = ", len(transp.queue)
        var vector = transp.queue.popFirst()
        while true:
          if transp.kind == TransportKind.Socket:
            if vector.kind == VectorKind.DataBuffer:
              let res = posix.send(fd, vector.buf, vector.buflen, MSG_NOSIGNAL)
              if res >= 0:
                if vector.buflen - res == 0:
                  vector.writer.complete()
                else:
                  vector.shiftVectorBuffer(res)
                  transp.queue.addFirst(vector)
              else:
                let err = osLastError()
                if int(err) == EINTR:
                  continue
                else:
                  transp.setWriteError(err)
                  vector.writer.complete()
              break
            else:
              discard
      else:
        transp.state.incl(WritePaused)
        transp.fd.removeWriter()

  proc readStreamLoop(udata: pointer) {.gcsafe.} =
    var cdata = cast[ptr CompletionData](udata)
    var transp = cast[UnixStreamTransport](cdata.udata)
    let fd = SocketHandle(cdata.fd)
    if not isNil(transp):
      while true:
        var res = posix.recv(fd, addr transp.buffer[transp.offset],
                             len(transp.buffer) - transp.offset, cint(0))
        if res < 0:
          let err = osLastError()
          if int(err) == EINTR:
            continue
          elif int(err) in {ECONNRESET}:
            transp.state.incl(ReadEof)
            transp.state.incl(ReadPaused)
            cdata.fd.removeReader()
          else:
            transp.setReadError(err)
            cdata.fd.removeReader()
        elif res == 0:
          transp.state.incl(ReadEof)
          transp.state.incl(ReadPaused)
          cdata.fd.removeReader()
        else:
          transp.offset += res
          if transp.offset == len(transp.buffer):
            transp.state.incl(ReadPaused)
            cdata.fd.removeReader()
        if not isNil(transp.reader):
          transp.finishReader()
        break

  proc newStreamSocketTransport(sock: AsyncFD, bufsize: int): StreamTransport =
    var t = UnixStreamTransport(kind: TransportKind.Socket)
    t.fd = sock
    t.buffer = newSeq[byte](bufsize)
    t.state = {ReadPaused, WritePaused}
    t.queue = initDeque[StreamVector]()
    t.future = newFuture[void]("socket.stream.transport")
    result = cast[StreamTransport](t)

  proc connect*(address: TransportAddress,
                bufferSize = DefaultStreamBufferSize): Future[StreamTransport] =
    var
      saddr: Sockaddr_storage
      slen: SockLen
      sock: AsyncFD
    var retFuture = newFuture[StreamTransport]("transport.connect")
    toSockAddr(address.address, address.port, saddr, slen)
    sock = createAsyncSocket(address.address.getDomain(), SockType.SOCK_STREAM,
                             Protocol.IPPROTO_TCP)
    if sock == asyncInvalidSocket:
      result.fail(newException(OSError, osErrorMsg(osLastError())))

    proc continuation(udata: pointer) =
      var data = cast[ptr CompletionData](udata)
      var err = 0
      if not data.fd.getSocketError(err):
        sock.closeAsyncSocket()
        retFuture.fail(newException(OSError, osErrorMsg(osLastError())))
        return
      if err != 0:
        sock.closeAsyncSocket()
        retFuture.fail(newException(OSError, osErrorMsg(OSErrorCode(err))))
        return
      data.fd.removeWriter()
      retFuture.complete(newStreamSocketTransport(data.fd, bufferSize))

    while true:
      var res = posix.connect(SocketHandle(sock),
                              cast[ptr SockAddr](addr saddr), slen)
      if res == 0:
        retFuture.complete(newStreamSocketTransport(sock, bufferSize))
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
          retFuture.fail(newException(OSError, osErrorMsg(err)))
          break
    return retFuture

  proc serverCallback(udata: pointer) =
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
          spawn server.function(
            newStreamSocketTransport(sock, server.bufferSize),
            server.udata)
          break
      else:
        let err = osLastError()
        if int(err) == EINTR:
          continue
        elif int(err) in {EBADF, EINVAL, ENOTSOCK, EOPNOTSUPP, EPROTO}:
          ## Critical unrecoverable error
          raiseOsError(err)

  proc serverLoop(server: SocketServer): Future[void] {.async.} =
    while true:
      await server.actEvent.wait()
      server.actEvent.clear()
      if server.action == ServerCommand.Start:
        if server.status in {Stopped, Paused, Starting}:
          addReader(server.sock, serverCallback,
                    cast[pointer](server))
          server.status = Running
      elif server.action == ServerCommand.Stop:
        if server.status in {Running}:
          removeReader(server.sock)
          server.status = Stopped
          break
        elif server.status in {Paused}:
          server.status = Stopped
          break
      elif server.action == ServerCommand.Pause:
        if server.status in {Running}:
          removeReader(server.sock)
          server.status = Paused

  proc resumeRead(transp: StreamTransport) {.inline.} =
    transp.state.excl(ReadPaused)
    addReader(transp.fd, readStreamLoop, cast[pointer](transp))

  proc resumeWrite(transp: StreamTransport) {.inline.} =
    transp.state.excl(WritePaused)
    addWriter(transp.fd, writeStreamLoop, cast[pointer](transp))

proc start*(server: SocketServer) =
  server.action = Start
  server.actEvent.fire()

proc stop*(server: SocketServer) =
  server.action = Stop
  server.actEvent.fire()

proc pause*(server: SocketServer) =
  server.action = Pause
  server.actEvent.fire()

proc join*(server: SocketServer) {.async.} =
  await server.loopFuture

proc createStreamServer*(host: TransportAddress,
                         flags: set[ServerFlags],
                         cbproc: StreamCallback,
                         sock: AsyncFD = asyncInvalidSocket,
                         backlog: int = 100,
                         bufferSize: int = DefaultStreamBufferSize,
                         udata: pointer = nil): StreamServer =
  var
    saddr: Sockaddr_storage
    slen: SockLen
    serverSocket: AsyncFD
  if sock == asyncInvalidSocket:
    serverSocket = createAsyncSocket(host.address.getDomain(),
                                     SockType.SOCK_STREAM,
                                     Protocol.IPPROTO_TCP)
    if serverSocket == asyncInvalidSocket:
      raiseOsError(osLastError())
  else:
    if not setSocketBlocking(SocketHandle(sock), false):
      raiseOsError(osLastError())
    register(sock)
    serverSocket = sock

  ## TODO: Set socket options here
  if ServerFlags.ReuseAddr in flags:
    if not setSockOpt(serverSocket, SOL_SOCKET, SO_REUSEADDR, 1):
      let err = osLastError()
      if sock == asyncInvalidSocket:
        closeAsyncSocket(serverSocket)
      raiseOsError(err)

  toSockAddr(host.address, host.port, saddr, slen)
  if bindAddr(SocketHandle(serverSocket), cast[ptr SockAddr](addr saddr),
              slen) != 0:
    let err = osLastError()
    if sock == asyncInvalidSocket:
      closeAsyncSocket(serverSocket)
    raiseOsError(err)
  
  if nativesockets.listen(SocketHandle(serverSocket), cint(backlog)) != 0:
    let err = osLastError()
    if sock == asyncInvalidSocket:
      closeAsyncSocket(serverSocket)
    raiseOsError(err)

  result = StreamServer()
  result.sock = serverSocket
  result.function = cbproc
  result.bufferSize = bufferSize
  result.status = Starting
  result.actEvent = newAsyncEvent()
  result.udata = udata
  result.local = host
  result.loopFuture = serverLoop(result)

proc write*(transp: StreamTransport, pbytes: pointer,
            nbytes: int): Future[int] {.async.} =
  checkClosed(transp)
  var waitFuture = newFuture[void]("transport.write")
  var vector = StreamVector(kind: DataBuffer, writer: waitFuture)
  when defined(windows):
    var wsabuf = TWSABuf(buf: cast[cstring](pbytes), len: cast[int32](nbytes))
    vector.dataBuf = addr wsabuf
  else:
    vector.buf = pbytes
    vector.buflen = nbytes
  transp.queue.addLast(vector)
  if WritePaused in transp.state:
    transp.resumeWrite()
  await vector.writer
  if WriteError in transp.state:
    raise transp.getError()
  result = nbytes

# proc writeFile*(transp: StreamTransport, handle: int,
#                 offset: uint = 0,
#                 size: uint = 0): Future[void] {.async.} =
#   if transp.kind != TransportKind.Socket:
#     raise newException(TransportError, "You can transmit files only to sockets")
#   checkClosed(transp)
#   var waitFuture = newFuture[void]("transport.writeFile")
#   var vector: StreamVector
#   vector.initTransmitStreamVector(handle, offset, size, waitFuture)
#   transp.queue.addLast(vector)

#   if WritePaused in transp.state:
#     transp.resumeWrite()
#   await vector.writer
#   if WriteError in transp.state:
#     raise transp.getError()

proc readExactly*(transp: StreamTransport, pbytes: pointer,
                  nbytes: int): Future[int] {.async.} =
  ## Read exactly ``nbytes`` bytes from transport ``transp``.
  checkClosed(transp)
  checkPending(transp)
  var index = 0
  while true:
    if transp.offset == 0:
      if (ReadError in transp.state):
        raise transp.getError()
      if (ReadEof in transp.state) or (ReadClosed in transp.state):
        raise newException(TransportIncompleteError, "Data incomplete!")

    if transp.offset >= (nbytes - index):
      copyMem(cast[pointer](cast[uint](pbytes) + uint(index)),
              addr(transp.buffer[0]), nbytes - index)
      transp.shiftBuffer(nbytes - index)
      result = nbytes
      break
    else:
      copyMem(cast[pointer](cast[uint](pbytes) + uint(index)),
              addr(transp.buffer[0]), transp.offset)
      index += transp.offset
      transp.reader = newFuture[void]("transport.readExactly")
      transp.offset = 0
      if ReadPaused in transp.state:
        transp.resumeRead()
      await transp.reader
  # we are no longer need data
  transp.reader = nil

proc readOnce*(transp: StreamTransport, pbytes: pointer,
               nbytes: int): Future[int] {.async.} =
  ## Perform one read operation on transport ``transp``.
  checkClosed(transp)
  checkPending(transp)
  while true:
    if transp.offset == 0:
      if (ReadError in transp.state):
        raise transp.getError()
      if (ReadEof in transp.state) or (ReadClosed in transp.state):
        result = 0
        break
      transp.reader = newFuture[void]("transport.readOnce")
      if ReadPaused in transp.state:
        transp.resumeRead()
      await transp.reader
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
  checkClosed(transp)
  checkPending(transp)

  var dest = cast[ptr UncheckedArray[byte]](pbytes)
  var state = 0
  var k = 0
  var index = 0

  while true:
    if (transp.offset - index) == 0:
      if ReadError in transp.state:
        transp.shiftBuffer(index)
        raise transp.getError()
      if (ReadEof in transp.state) or (ReadClosed in transp.state):
        transp.shiftBuffer(index)
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
        transp.shiftBuffer(index + 1)
        break

      inc(index)

    if state == len(sep):
      result = k
      break
    else:
      if (transp.offset - index) == 0:
        transp.reader = newFuture[void]("transport.readUntil")
        if ReadPaused in transp.state:
          transp.resumeRead()
        await transp.reader

  # we are no longer need data
  transp.reader = nil

proc readLine*(transp: StreamTransport, limit = 0,
               sep = "\r\n"): Future[string] {.async.} =
  checkClosed(transp)
  checkPending(transp)

  result = ""
  var lim = if limit <= 0: -1 else: limit
  var state = 0
  var index = 0

  while true:
    if (transp.offset - index) == 0:
      if (ReadError in transp.state):
        transp.shiftBuffer(index)
        raise transp.getError()
      if (ReadEof in transp.state) or (ReadClosed in transp.state):
        transp.shiftBuffer(index)
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
      if (transp.offset - index) == 0:
        transp.reader = newFuture[void]("transport.readLine")
        if ReadPaused in transp.state:
          transp.resumeRead()
        await transp.reader

  # we are no longer need data
  transp.reader = nil

proc read*(transp: StreamTransport, n = -1): Future[seq[byte]] {.async.} =
  checkClosed(transp)
  checkPending(transp)

  result = newSeq[byte]()

  while true:
    if (ReadError in transp.state):
      raise transp.getError()
    if (ReadEof in transp.state) or (ReadClosed in transp.state):
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
        if transp.offset >= (n - s):
          # size of buffer data is more then we need, grabbing only part
          let part = transp.offset - (n - s)
          result.setLen(n)
          copyMem(cast[pointer](addr result[s]), addr(transp.buffer[0]),
                  part)
          transp.shiftBuffer(part)
          break
        else:
          # there not enough data in buffer, grabbing all
          result.setLen(o)
          copyMem(cast[pointer](addr result[s]), addr(transp.buffer[0]),
                  transp.offset)
          transp.offset = 0

    transp.reader = newFuture[void]("transport.read")
    if ReadPaused in transp.state:
      transp.resumeRead()
    await transp.reader

  # we are no longer need data
  transp.reader = nil

proc atEof*(transp: StreamTransport): bool {.inline.} =
  ## Returns ``true`` if ``transp`` is at EOF.
  result = (transp.offset == 0) and (ReadEof in transp.state) and
           (ReadPaused in transp.state)

proc join*(transp: StreamTransport) {.async.} =
  ## Wait until ``transp`` will not be closed.
  await transp.future

proc close*(transp: StreamTransport) =
  ## Closes and frees resources of transport ``transp``.
  if ReadClosed notin transp.state and WriteClosed notin transp.state:
    when defined(windows):
      discard cancelIo(Handle(transp.fd))
    closeAsyncSocket(transp.fd)
    transp.state.incl(WriteClosed)
    transp.state.incl(ReadClosed)
    transp.future.complete()

#
#             Chronos Stream Transport
#            (c) Copyright 2018-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

{.push raises: [].}

import std/deques
import stew/ptrops
import results
import ".."/[asyncloop, config, handles, bipbuffer, osdefs, osutils, oserrno]
import ./[common, ipnet]

export results

type
  VectorKind = enum
    DataBuffer,                     # Simple buffer pointer/length
    DataFile                        # File handle for sendfile/TransmitFile

  StreamVector = object
    kind: VectorKind                # Writer vector source kind
    buf: pointer                    # Writer buffer pointer
    buflen: int                     # Writer buffer size
    offset: uint                    # Writer vector offset
    size: int                       # Original size
    writer: Future[int]             # Writer vector completion Future

  TransportKind* {.pure.} = enum
    Socket,                         # Socket transport
    Pipe,                           # Pipe transport
    File                            # File transport

  TransportFlags* = enum
    None,
    # Default value
    WinServerPipe,
    # This is internal flag which used to differentiate between server pipe
    # handle and client pipe handle.
    WinNoPipeFlash,
    # By default `AddressFamily.Unix` transports in Windows are using
    # `FlushFileBuffers()` when transport closing.
    # This flag disables usage of `FlushFileBuffers()` on `AddressFamily.Unix`
    # transport shutdown. If both server and client are running in the same
    # thread, because of `FlushFileBuffers()` will ensure that all bytes
    # or messages written to the pipe are read by the client, it is possible to
    # get stuck on transport `close()`.
    # Please use this flag only if you are making both client and server in
    # the same thread.
    TcpNoDelay, # deprecated: Use SocketFlags.TcpNoDelay
    V4Mapped

  SocketFlags* {.pure.} = enum
    TcpNoDelay,
    ReuseAddr,
    ReusePort

  ReadMessagePredicate* = proc (data: openArray[byte]): tuple[consumed: int,
                                                              done: bool] {.
    gcsafe, raises: [].}

  ReaderFuture = Future[void].Raising([TransportError, CancelledError])

const
  StreamTransportTrackerName* = "stream.transport"
  StreamServerTrackerName* = "stream.server"
  DefaultBacklogSize* = high(int32)

when defined(windows):
  type
    StreamTransport* = ref object of RootRef
      fd*: AsyncFD                    # File descriptor
      state: set[TransportState]      # Current Transport state
      reader: ReaderFuture            # Current reader Future
      buffer: BipBuffer               # Reading buffer
      error: ref TransportError       # Current error
      queue: Deque[StreamVector]      # Writer queue
      future: Future[void].Raising([]) # Stream life future
      # Windows specific part
      rwsabuf: WSABUF                 # Reader WSABUF
      wwsabuf: WSABUF                 # Writer WSABUF
      rovl: CustomOverlapped          # Reader OVERLAPPED structure
      wovl: CustomOverlapped          # Writer OVERLAPPED structure
      flags: set[TransportFlags]      # Internal flags
      case kind*: TransportKind
      of TransportKind.Socket:
        domain: Domain                # Socket transport domain (IPv4/IPv6)
        local: TransportAddress       # Local address
        remote: TransportAddress      # Remote address
      of TransportKind.Pipe:
        discard
      of TransportKind.File:
        discard
else:
  type
    StreamTransport* = ref object of RootRef
      fd*: AsyncFD                    # File descriptor
      state: set[TransportState]      # Current Transport state
      reader: ReaderFuture            # Current reader Future
      buffer: BipBuffer               # Reading buffer
      error: ref TransportError       # Current error
      queue: Deque[StreamVector]      # Writer queue
      future: Future[void].Raising([]) # Stream life future
      flags: set[TransportFlags]      # Internal flags
      case kind*: TransportKind
      of TransportKind.Socket:
        domain: Domain                # Socket transport domain (IPv4/IPv6)
        local: TransportAddress       # Local address
        remote: TransportAddress      # Remote address
      of TransportKind.Pipe:
        discard
      of TransportKind.File:
        discard

type
  # TODO evaluate naming of raises-annotated callbacks
  StreamCallback2* = proc(server: StreamServer,
                          client: StreamTransport) {.async: (raises: []).}
    ## New remote client connection callback
    ## ``server`` - StreamServer object.
    ## ``client`` - accepted client transport.

  StreamCallback* = proc(server: StreamServer,
                         client: StreamTransport) {.async.}
    ## Connection callback that doesn't check for exceptions at compile time
    ## ``server`` - StreamServer object.
    ## ``client`` - accepted client transport.

  TransportInitCallback* = proc(server: StreamServer,
                                fd: AsyncFD): StreamTransport {.
                                gcsafe, raises: [].}
    ## Custom transport initialization procedure, which can allocate inherited
    ## StreamTransport object.

  StreamServer* = ref object of SocketServer
    ## StreamServer object
    function*: StreamCallback2         # callback which will be called after new
                                      # client accepted
    init*: TransportInitCallback      # callback which will be called before
                                      # transport for new client

proc getRemoteAddress(transp: StreamTransport,
                      address: Sockaddr_storage, length: SockLen,
                     ): TransportAddress =
  var raddr: TransportAddress
  fromSAddr(unsafeAddr address, length, raddr)
  if TransportFlags.V4Mapped in transp.flags:
    if raddr.isV4Mapped(): raddr.toIPv4() else: raddr
  else:
    raddr

proc remoteAddress2*(
    transp: StreamTransport
): Result[TransportAddress, OSErrorCode] =
  ## Returns ``transp`` remote socket address.
  if transp.remote.family == AddressFamily.None:
    var
      saddr: Sockaddr_storage
      slen = SockLen(sizeof(saddr))
    if getpeername(SocketHandle(transp.fd), cast[ptr SockAddr](addr saddr),
                   addr slen) != 0:
      return err(osLastError())
    transp.remote = transp.getRemoteAddress(saddr, slen)
  ok(transp.remote)

proc localAddress2*(
    transp: StreamTransport
): Result[TransportAddress, OSErrorCode] =
  ## Returns ``transp`` local socket address.
  if transp.local.family == AddressFamily.None:
    var
      saddr: Sockaddr_storage
      slen = SockLen(sizeof(saddr))
    if getsockname(SocketHandle(transp.fd), cast[ptr SockAddr](addr saddr),
                   addr slen) != 0:
      return err(osLastError())
    fromSAddr(addr saddr, slen, transp.local)
  ok(transp.local)

# TODO(cheatfate): This function should not be public, but for some weird
# reason if we will make it non-public it start generate
# Hint: 'toException' is declared but not used [XDeclaredButNotUsed]
func toException*(v: OSErrorCode): ref TransportOsError =
  getTransportOsError(v)

proc remoteAddress*(transp: StreamTransport): TransportAddress {.
    raises: [TransportOsError].} =
  ## Returns ``transp`` remote socket address.
  remoteAddress2(transp).tryGet()

proc localAddress*(transp: StreamTransport): TransportAddress {.
    raises: [TransportOsError].} =
  ## Returns ``transp`` remote socket address.
  localAddress2(transp).tryGet()

proc localAddress*(server: StreamServer): TransportAddress =
  ## Returns ``server`` bound local socket address.
  server.local

template completeReader(stream: StreamTransport) =
  if not(isNil(transp.reader)) and not(transp.reader.finished()):
    transp.reader.complete()
    transp.reader = nil

template setReadError(t, e: untyped) =
  (t).state.incl(ReadError)
  (t).error = getTransportOsError(e)

template checkPending(t: untyped) =
  if not(isNil((t).reader)):
    raise newException(TransportError, "Read operation already pending!")

template shiftVectorBuffer(v: var StreamVector, o: untyped) =
  (v).buf = cast[pointer](cast[uint]((v).buf) + uint(o))
  (v).buflen -= int(o)

template shiftVectorFile(v: var StreamVector, o: untyped) =
  (v).buf = cast[pointer](cast[uint]((v).buf) - uint(o))
  (v).offset += uint(o)

proc completePendingWriteQueue(queue: var Deque[StreamVector],
                               v: int) {.inline.} =
  while len(queue) > 0:
    var vector = queue.popFirst()
    if not(vector.writer.finished()):
      vector.writer.complete(v)

proc failPendingWriteQueue(queue: var Deque[StreamVector],
                           error: ref TransportError) {.inline.} =
  while len(queue) > 0:
    var vector = queue.popFirst()
    if not(vector.writer.finished()):
      vector.writer.fail(error)

proc clean(server: StreamServer) {.inline.} =
  if not(server.loopFuture.finished()):
    untrackCounter(StreamServerTrackerName)
    server.loopFuture.complete()
    if not(isNil(server.udata)) and (GCUserData in server.flags):
      GC_unref(cast[ref int](server.udata))
    GC_unref(server)

proc clean(transp: StreamTransport) {.inline.} =
  if not(transp.future.finished()):
    untrackCounter(StreamTransportTrackerName)
    transp.future.complete()
    GC_unref(transp)

template toUnchecked*(a: untyped): untyped =
  cast[ptr UncheckedArray[byte]](a)

func getTransportFlags(server: StreamServer): set[TransportFlags] =
  if ServerFlags.V4Mapped in server.flags:
    {TransportFlags.V4Mapped}
  else:
    {}

when defined(windows):

  template zeroOvelappedOffset(t: untyped) =
    (t).offset = 0
    (t).offsetHigh = 0

  template setOverlappedOffset(t, o: untyped) =
    (t).offset = cast[DWORD](cast[uint64](o) and 0xFFFFFFFF'u64)
    (t).offsetHigh = cast[DWORD](cast[uint64](o) shr 32)

  template getFileSize(v: untyped): uint =
    cast[uint]((v).buf)

  template getFileHandle(v: untyped): HANDLE =
    cast[HANDLE]((v).buflen)

  template setReaderWSABuffer(t: untyped) =
    let res = (t).buffer.reserve()
    (t).rwsabuf.buf = cast[cstring](res.data)
    (t).rwsabuf.len = uint32(res.size)

  template setWriterWSABuffer(t, v: untyped) =
    (t).wwsabuf.buf = cast[cstring](v.buf)
    (t).wwsabuf.len = cast[ULONG](v.buflen)

  func isConnResetError(err: OSErrorCode): bool {.inline.} =
    case err
    of WSAECONNRESET, WSAECONNABORTED, ERROR_PIPE_NOT_CONNECTED:
      true
    else:
      false

  proc writeStreamLoop(udata: pointer) {.gcsafe, nimcall.} =
    var bytesCount: uint32
    var ovl = cast[PtrCustomOverlapped](udata)
    var transp = cast[StreamTransport](ovl.data.udata)

    if WriteClosed in transp.state:
      transp.state.excl(WritePending)
      transp.state.incl({WritePaused})
      let error = getTransportUseClosedError()
      failPendingWriteQueue(transp.queue, error)
    else:
      while len(transp.queue) > 0:
        if WritePending in transp.state:
          ## Continuation
          transp.state.excl(WritePending)
          let err = transp.wovl.data.errCode
          case err
          of OSErrorCode(-1):
            bytesCount = transp.wovl.data.bytesCount
            var vector = transp.queue.popFirst()
            if bytesCount == 0:
              if not(vector.writer.finished()):
                vector.writer.complete(0)
            else:
              if transp.kind == TransportKind.Socket:
                if vector.kind == VectorKind.DataBuffer:
                  if bytesCount < transp.wwsabuf.len:
                    vector.shiftVectorBuffer(bytesCount)
                    transp.queue.addFirst(vector)
                  else:
                    if not(vector.writer.finished()):
                      # This conversion to `int` safe, because its impossible
                      # to call write() with size bigger than `int`.
                      vector.writer.complete(int(transp.wwsabuf.len))
                else:
                  if uint(bytesCount) < getFileSize(vector):
                    vector.shiftVectorFile(bytesCount)
                    transp.queue.addFirst(vector)
                  else:
                    if not(vector.writer.finished()):
                      vector.writer.complete(int(getFileSize(vector)))
              elif transp.kind == TransportKind.Pipe:
                if vector.kind == VectorKind.DataBuffer:
                  if bytesCount < transp.wwsabuf.len:
                    vector.shiftVectorBuffer(bytesCount)
                    transp.queue.addFirst(vector)
                  else:
                    if not(vector.writer.finished()):
                      # This conversion to `int` safe, because its impossible
                      # to call write() with size bigger than `int`.
                      vector.writer.complete(int(transp.wwsabuf.len))
          of ERROR_OPERATION_ABORTED:
            # CancelIO() interrupt
            transp.state.incl({WritePaused, WriteEof})
            let vector = transp.queue.popFirst()
            if not(vector.writer.finished()):
              vector.writer.complete(0)
            completePendingWriteQueue(transp.queue, 0)
            break
          else:
            let vector = transp.queue.popFirst()
            if isConnResetError(err):
              # Soft error happens which indicates that remote peer got
              # disconnected, complete all pending writes in queue with 0.
              transp.state.incl({WritePaused, WriteEof})
              if not(vector.writer.finished()):
                vector.writer.complete(0)
              completePendingWriteQueue(transp.queue, 0)
              break
            else:
              transp.state.incl({WritePaused, WriteError})
              let error = getTransportOsError(err)
              if not(vector.writer.finished()):
                vector.writer.fail(error)
              failPendingWriteQueue(transp.queue, error)
              break
        else:
          ## Initiation
          transp.state.incl(WritePending)
          if transp.kind == TransportKind.Socket:
            let sock = SocketHandle(transp.fd)
            var vector = transp.queue.popFirst()
            if vector.kind == VectorKind.DataBuffer:
              transp.wovl.zeroOvelappedOffset()
              transp.setWriterWSABuffer(vector)
              let ret = wsaSend(sock, addr transp.wwsabuf, 1,
                                addr bytesCount, DWORD(0),
                                cast[POVERLAPPED](addr transp.wovl), nil)
              if ret != 0:
                let err = osLastError()
                case err
                of ERROR_OPERATION_ABORTED:
                  # CancelIO() interrupt
                  transp.state.excl(WritePending)
                  transp.state.incl({WritePaused, WriteEof})
                  if not(vector.writer.finished()):
                    vector.writer.complete(0)
                  completePendingWriteQueue(transp.queue, 0)
                  break
                of ERROR_IO_PENDING:
                  transp.queue.addFirst(vector)
                else:
                  transp.state.excl(WritePending)
                  if isConnResetError(err):
                    # Soft error happens which indicates that remote peer got
                    # disconnected, complete all pending writes in queue with 0.
                    transp.state.incl({WritePaused, WriteEof})
                    if not(vector.writer.finished()):
                      vector.writer.complete(0)
                    completePendingWriteQueue(transp.queue, 0)
                    break
                  else:
                    transp.state.incl({WritePaused, WriteError})
                    let error = getTransportOsError(err)
                    if not(vector.writer.finished()):
                      vector.writer.fail(error)
                    failPendingWriteQueue(transp.queue, error)
                    break
              else:
                transp.queue.addFirst(vector)
            else:
              let
                loop = getThreadDispatcher()
                size = min(uint32(getFileSize(vector)), 2_147_483_646'u32)

              transp.wovl.setOverlappedOffset(vector.offset)
              var ret = loop.transmitFile(sock, getFileHandle(vector), size,
                                          0'u32,
                                          cast[POVERLAPPED](addr transp.wovl),
                                          nil, 0'u32)
              if ret == 0:
                let err = osLastError()
                case err
                of ERROR_OPERATION_ABORTED:
                  # CancelIO() interrupt
                  transp.state.excl(WritePending)
                  transp.state.incl({WritePaused, WriteEof})
                  if not(vector.writer.finished()):
                    vector.writer.complete(0)
                  completePendingWriteQueue(transp.queue, 0)
                  break
                of ERROR_IO_PENDING:
                  transp.queue.addFirst(vector)
                else:
                  transp.state.excl(WritePending)
                  if isConnResetError(err):
                    # Soft error happens which indicates that remote peer got
                    # disconnected, complete all pending writes in queue with 0.
                    transp.state.incl({WritePaused, WriteEof})
                    if not(vector.writer.finished()):
                      vector.writer.complete(0)
                    completePendingWriteQueue(transp.queue, 0)
                    break
                  else:
                    transp.state.incl({WritePaused, WriteError})
                    let error = getTransportOsError(err)
                    if not(vector.writer.finished()):
                      vector.writer.fail(error)
                    failPendingWriteQueue(transp.queue, error)
                    break
              else:
                transp.queue.addFirst(vector)
          elif transp.kind == TransportKind.Pipe:
            let pipe = HANDLE(transp.fd)
            var vector = transp.queue.popFirst()
            if vector.kind == VectorKind.DataBuffer:
              transp.wovl.zeroOvelappedOffset()
              transp.setWriterWSABuffer(vector)
              let ret = writeFile(pipe, cast[pointer](transp.wwsabuf.buf),
                                  DWORD(transp.wwsabuf.len), addr bytesCount,
                                  cast[POVERLAPPED](addr transp.wovl))
              if ret == 0:
                let err = osLastError()
                case err
                of ERROR_OPERATION_ABORTED, ERROR_NO_DATA:
                  # CancelIO() interrupt
                  transp.state.excl(WritePending)
                  transp.state.incl({WritePaused, WriteEof})
                  if not(vector.writer.finished()):
                    vector.writer.complete(0)
                  completePendingWriteQueue(transp.queue, 0)
                  break
                of ERROR_IO_PENDING:
                  transp.queue.addFirst(vector)
                else:
                  transp.state.excl(WritePending)
                  if isConnResetError(err):
                    # Soft error happens which indicates that remote peer got
                    # disconnected, complete all pending writes in queue with 0.
                    transp.state.incl({WritePaused, WriteEof})
                    if not(vector.writer.finished()):
                      vector.writer.complete(0)
                    completePendingWriteQueue(transp.queue, 0)
                    break
                  else:
                    transp.state.incl({WritePaused, WriteError})
                    let error = getTransportOsError(err)
                    if not(vector.writer.finished()):
                      vector.writer.fail(error)
                    failPendingWriteQueue(transp.queue, error)
                    break
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
        let err = transp.rovl.data.errCode
        case err
        of OSErrorCode(-1):
          let bytesCount = transp.rovl.data.bytesCount
          if bytesCount == 0:
            transp.state.incl({ReadEof, ReadPaused})
          else:
            transp.buffer.commit(bytesCount)
            if transp.buffer.availSpace() == 0:
              transp.state.incl(ReadPaused)
        of ERROR_OPERATION_ABORTED, ERROR_CONNECTION_ABORTED,
           ERROR_BROKEN_PIPE:
          # CancelIO() interrupt or closeSocket() call.
          transp.buffer.commit(0)
          transp.state.incl(ReadPaused)
        of ERROR_NETNAME_DELETED, WSAECONNABORTED:
          transp.buffer.commit(0)
          if transp.kind == TransportKind.Socket:
            transp.state.incl({ReadEof, ReadPaused})
          else:
            transp.setReadError(err)
        of ERROR_PIPE_NOT_CONNECTED:
          transp.buffer.commit(0)
          if transp.kind == TransportKind.Pipe:
            transp.state.incl({ReadEof, ReadPaused})
          else:
            transp.setReadError(err)
        else:
          transp.buffer.commit(0)
          transp.setReadError(err)

        transp.completeReader()

        if ReadClosed in transp.state:
          # Stop tracking transport
          transp.clean()

        if ReadPaused in transp.state:
          # Transport buffer is full, so we will not continue on reading.
          break
      else:
        ## Initiation
        if transp.state * {ReadEof, ReadClosed, ReadError} == {}:
          var flags = DWORD(0)
          var bytesCount = 0'u32
          transp.state.excl(ReadPaused)
          transp.state.incl(ReadPending)
          if transp.kind == TransportKind.Socket:
            let sock = SocketHandle(transp.fd)
            transp.setReaderWSABuffer()
            let ret = wsaRecv(sock, addr transp.rwsabuf, 1,
                              addr bytesCount, addr flags,
                              cast[POVERLAPPED](addr transp.rovl), nil)
            if ret != 0:
              let err = osLastError()
              case err
              of ERROR_OPERATION_ABORTED:
                # CancelIO() interrupt
                transp.state.excl(ReadPending)
                transp.state.incl(ReadPaused)
              of WSAECONNRESET, WSAENETRESET, WSAECONNABORTED:
                transp.state.excl(ReadPending)
                transp.state.incl({ReadEof, ReadPaused})
                transp.completeReader()
              of ERROR_IO_PENDING:
                discard
              else:
                transp.state.excl(ReadPending)
                transp.state.incl(ReadPaused)
                transp.setReadError(err)
                transp.completeReader()
          elif transp.kind == TransportKind.Pipe:
            let pipe = HANDLE(transp.fd)
            transp.setReaderWSABuffer()
            let ret = readFile(pipe, cast[pointer](transp.rwsabuf.buf),
                               DWORD(transp.rwsabuf.len), addr bytesCount,
                               cast[POVERLAPPED](addr transp.rovl))
            if ret == 0:
              let err = osLastError()
              case err
              of ERROR_OPERATION_ABORTED:
                # CancelIO() interrupt
                transp.state.excl(ReadPending)
                transp.state.incl(ReadPaused)
              of ERROR_BROKEN_PIPE, ERROR_PIPE_NOT_CONNECTED:
                transp.state.excl(ReadPending)
                transp.state.incl({ReadEof, ReadPaused})
                transp.completeReader()
              of ERROR_IO_PENDING:
                discard
              else:
                transp.state.excl(ReadPending)
                transp.state.incl(ReadPaused)
                transp.setReadError(err)
                transp.completeReader()
        else:
          transp.state.incl(ReadPaused)
          transp.completeReader()
          # Transport close happens in callback, and we not started new
          # WSARecvFrom session.
          if ReadClosed in transp.state:
            if not(transp.future.finished()):
              transp.future.complete()
        ## Finish Loop
        break

  proc newStreamSocketTransport(sock: AsyncFD, bufsize: int,
                                child: StreamTransport,
                                flags: set[TransportFlags]): StreamTransport =
    var transp: StreamTransport
    if not(isNil(child)):
      transp = child
    else:
      transp = StreamTransport(kind: TransportKind.Socket)
    transp.fd = sock
    transp.flags = flags
    transp.rovl.data = CompletionData(cb: readStreamLoop,
                                      udata: cast[pointer](transp))
    transp.wovl.data = CompletionData(cb: writeStreamLoop,
                                      udata: cast[pointer](transp))
    let size = max(bufsize, DefaultStreamBufferSize)
    transp.buffer = BipBuffer.init(size)
    transp.state = {ReadPaused, WritePaused}
    transp.queue = initDeque[StreamVector]()
    transp.future = Future[void].Raising([]).init(
      "stream.socket.transport", {FutureFlag.OwnCancelSchedule})
    GC_ref(transp)
    transp

  proc newStreamPipeTransport(fd: AsyncFD, bufsize: int,
                              child: StreamTransport,
                             flags: set[TransportFlags] = {}): StreamTransport =
    var transp: StreamTransport
    if not(isNil(child)):
      transp = child
    else:
      transp = StreamTransport(kind: TransportKind.Pipe)
    transp.fd = fd
    transp.rovl.data = CompletionData(cb: readStreamLoop,
                                      udata: cast[pointer](transp))
    transp.wovl.data = CompletionData(cb: writeStreamLoop,
                                      udata: cast[pointer](transp))
    let size = max(bufsize, DefaultStreamBufferSize)
    transp.buffer = BipBuffer.init(size)
    transp.flags = flags
    transp.state = {ReadPaused, WritePaused}
    transp.queue = initDeque[StreamVector]()
    transp.future = Future[void].Raising([]).init(
      "stream.pipe.transport", {FutureFlag.OwnCancelSchedule})
    GC_ref(transp)
    transp

  proc bindToDomain(handle: AsyncFD,
                    family: AddressFamily): Result[void, OSErrorCode] =
    case family
    of AddressFamily.IPv6:
      var saddr: Sockaddr_in6
      saddr.sin6_family = type(saddr.sin6_family)(osdefs.AF_INET6)
      if osdefs.bindSocket(SocketHandle(handle),
                           cast[ptr SockAddr](addr(saddr)),
                           sizeof(saddr).SockLen) != 0'i32:
        return err(osLastError())
      ok()
    of AddressFamily.IPv4:
      var saddr: Sockaddr_in
      saddr.sin_family = type(saddr.sin_family)(osdefs.AF_INET)
      if osdefs.bindSocket(SocketHandle(handle),
                           cast[ptr SockAddr](addr(saddr)),
                           sizeof(saddr).SockLen) != 0'i32:
        return err(osLastError())
      ok()
    else:
      raiseAssert "Unsupported family"

  proc connect*(address: TransportAddress,
                bufferSize = DefaultStreamBufferSize,
                child: StreamTransport = nil,
                localAddress = TransportAddress(),
                flags: set[SocketFlags] = {},
                dualstack = DualStackType.Auto
               ): Future[StreamTransport] {.
               async: (raw: true, raises: [TransportError, CancelledError]).} =
    ## Open new connection to remote peer with address ``address`` and create
    ## new transport object ``StreamTransport`` for established connection.
    ## ``bufferSize`` is size of internal buffer for transport.
    let loop = getThreadDispatcher()
    var retFuture = newFuture[StreamTransport]("stream.transport.connect")
    if address.family in {AddressFamily.IPv4, AddressFamily.IPv6}:
      ## Socket handling part
      var
        saddr: Sockaddr_storage
        slen: SockLen
        sock: AsyncFD
        povl: RefCustomOverlapped
        proto: Protocol

      var raddress = windowsAnyAddressFix(address)

      toSAddr(raddress, saddr, slen)
      proto = Protocol.IPPROTO_TCP
      sock = createAsyncSocket2(raddress.getDomain(), SockType.SOCK_STREAM,
                                proto).valueOr:
        retFuture.fail(getTransportOsError(error))
        return retFuture

      if address.family in {AddressFamily.IPv4, AddressFamily.IPv6}:
        if SocketFlags.TcpNoDelay in flags:
          setSockOpt2(sock, osdefs.IPPROTO_TCP, osdefs.TCP_NODELAY, 1).isOkOr:
            sock.closeSocket()
            retFuture.fail(getTransportOsError(error))
            return retFuture

      if SocketFlags.ReuseAddr in flags:
        setSockOpt2(sock, SOL_SOCKET, SO_REUSEADDR, 1).isOkOr:
          sock.closeSocket()
          retFuture.fail(getTransportOsError(error))
          return retFuture
      if SocketFlags.ReusePort in flags:
        setSockOpt2(sock, SOL_SOCKET, SO_REUSEPORT, 1).isOkOr:
          sock.closeSocket()
          retFuture.fail(getTransportOsError(error))
          return retFuture
      # IPV6_V6ONLY.
      setDualstack(sock, address.family, dualstack).isOkOr:
        sock.closeSocket()
        retFuture.fail(getTransportOsError(error))
        return retFuture

      let transportFlags =
        block:
          # Add `V4Mapped` flag when `::` address is used and dualstack is
          # set to enabled or auto.
          var res: set[TransportFlags]
          if (localAddress.family == AddressFamily.IPv6) and
             localAddress.isAnyLocal():
            if dualstack in {DualStackType.Enabled, DualStackType.Auto}:
              res.incl(TransportFlags.V4Mapped)
          res

      case localAddress.family
      of AddressFamily.IPv4, AddressFamily.IPv6:
        var
          saddr: Sockaddr_storage
          slen: SockLen
        toSAddr(localAddress, saddr, slen)
        if bindSocket(SocketHandle(sock),
          cast[ptr SockAddr](addr saddr), slen) != 0:
          sock.closeSocket()
          retFuture.fail(getTransportOsError(osLastError()))
          return retFuture
      of AddressFamily.Unix:
        raiseAssert "Unsupported local address family"
      of AddressFamily.None:
        let res = bindToDomain(sock, raddress.family)
        if res.isErr():
          sock.closeSocket()
          retFuture.fail(getTransportOsError(res.error))
          return retFuture

      proc socketContinuation(udata: pointer) {.gcsafe.} =
        var ovl = cast[RefCustomOverlapped](udata)
        if not(retFuture.finished()):
          if ovl.data.errCode == OSErrorCode(-1):
            if setsockopt(SocketHandle(sock), cint(SOL_SOCKET),
                          cint(SO_UPDATE_CONNECT_CONTEXT), nil,
                          SockLen(0)) != 0'i32:
              let err = wsaGetLastError()
              sock.closeSocket()
              retFuture.fail(getTransportOsError(err))
            else:
              let transp = newStreamSocketTransport(sock, bufferSize, child,
                                                    transportFlags)
              # Start tracking transport
              trackCounter(StreamTransportTrackerName)
              retFuture.complete(transp)
          else:
            sock.closeSocket()
            retFuture.fail(getTransportOsError(ovl.data.errCode))
        GC_unref(ovl)

      proc cancel(udata: pointer) {.gcsafe.} =
        sock.closeSocket()

      povl = RefCustomOverlapped()
      GC_ref(povl)
      povl.data = CompletionData(cb: socketContinuation)
      let res = loop.connectEx(SocketHandle(sock),
                               cast[ptr SockAddr](addr saddr),
                               cint(slen), nil, 0, nil,
                               cast[POVERLAPPED](povl))
      # We will not process immediate completion, to avoid undefined behavior.
      if res == FALSE:
        let err = osLastError()
        case err
        of ERROR_IO_PENDING:
          discard
        else:
          GC_unref(povl)
          sock.closeSocket()
          retFuture.fail(getTransportOsError(err))

      retFuture.cancelCallback = cancel

    elif address.family == AddressFamily.Unix:
      ## Unix domain socket emulation with Windows Named Pipes.
      # For some reason Nim compiler does not detect `pipeHandle` usage in
      # pipeContinuation() procedure, so we marking it as {.used.} here.
      var pipeHandle {.used.} = INVALID_HANDLE_VALUE
      var pipeContinuation: proc (udata: pointer) {.gcsafe, raises: [].}

      pipeContinuation = proc (udata: pointer) {.gcsafe, raises: [].} =
        # Continue only if `retFuture` is not cancelled.
        if not(retFuture.finished()):
          let
            pipeSuffix = $cast[cstring](baseAddr address.address_un)
            pipeAsciiName = PipeHeaderName & pipeSuffix[1 .. ^1]
            pipeName = toWideString(pipeAsciiName).valueOr:
              retFuture.fail(getTransportOsError(error))
              return
            genericFlags = GENERIC_READ or GENERIC_WRITE
            shareFlags = FILE_SHARE_READ or FILE_SHARE_WRITE
            pipeHandle = createFile(pipeName, genericFlags, shareFlags,
                                    nil, OPEN_EXISTING,
                                    FILE_FLAG_OVERLAPPED, HANDLE(0))
          free(pipeName)
          if pipeHandle == INVALID_HANDLE_VALUE:
            let err = osLastError()
            case err
            of ERROR_PIPE_BUSY:
              discard setTimer(Moment.fromNow(50.milliseconds),
                               pipeContinuation, nil)
            else:
              retFuture.fail(getTransportOsError(err))
          else:
            let res = register2(AsyncFD(pipeHandle))
            if res.isErr():
              retFuture.fail(getTransportOsError(res.error()))
              return

            let transp = newStreamPipeTransport(AsyncFD(pipeHandle),
                                                bufferSize, child)
            # Start tracking transport
            trackCounter(StreamTransportTrackerName)
            retFuture.complete(transp)
      pipeContinuation(nil)

    return retFuture

  proc createAcceptPipe(server: StreamServer): Result[AsyncFD, OSErrorCode] =
    let
      pipeSuffix = $cast[cstring](baseAddr server.local.address_un)
      pipeName = ? toWideString(PipeHeaderName & pipeSuffix)
      openMode =
        if FirstPipe notin server.flags:
          server.flags.incl(FirstPipe)
          PIPE_ACCESS_DUPLEX or FILE_FLAG_OVERLAPPED or
          FILE_FLAG_FIRST_PIPE_INSTANCE
        else:
          PIPE_ACCESS_DUPLEX or FILE_FLAG_OVERLAPPED
      pipeMode = PIPE_TYPE_BYTE or PIPE_READMODE_BYTE or PIPE_WAIT
      pipeHandle = createNamedPipe(pipeName, openMode, pipeMode,
                                   PIPE_UNLIMITED_INSTANCES,
                                   DWORD(server.bufferSize),
                                   DWORD(server.bufferSize),
                                   DWORD(0), nil)
    free(pipeName)
    if pipeHandle == INVALID_HANDLE_VALUE:
      return err(osLastError())
    let res = register2(AsyncFD(pipeHandle))
    if res.isErr():
      discard closeHandle(pipeHandle)
      return err(res.error())

    ok(AsyncFD(pipeHandle))

  proc acceptPipeLoop(udata: pointer) {.gcsafe, nimcall.} =
    var ovl = cast[PtrCustomOverlapped](udata)
    var server = cast[StreamServer](ovl.data.udata)

    while true:
      if server.apending:
        ## Continuation
        server.apending = false
        if server.status notin {ServerStatus.Stopped, ServerStatus.Closed}:
          case ovl.data.errCode
          of OSErrorCode(-1):
            var ntransp: StreamTransport
            var flags = {WinServerPipe}
            if NoPipeFlash in server.flags:
              flags.incl(WinNoPipeFlash)
            if not(isNil(server.init)):
              var transp = server.init(server, server.sock)
              ntransp = newStreamPipeTransport(server.sock, server.bufferSize,
                                               transp, flags)
            else:
              ntransp = newStreamPipeTransport(server.sock, server.bufferSize,
                                               nil, flags)
            # Start tracking transport
            trackCounter(StreamTransportTrackerName)
            asyncSpawn server.function(server, ntransp)
          of ERROR_OPERATION_ABORTED:
            # CancelIO() interrupt or close call.
            if server.status in {ServerStatus.Closed, ServerStatus.Stopped}:
              server.clean()
            break
          else:
            # We should not raise defects in this loop.
            discard disconnectNamedPipe(HANDLE(server.sock))
            discard closeHandle(HANDLE(server.sock))
            raiseOsDefect(osLastError(), "acceptPipeLoop(): Unable to accept " &
                                         "new pipe connection")
        else:
          # Server close happens in callback, and we are not started new
          # connectNamedPipe session.
          if not(server.loopFuture.finished()):
            server.clean()
          break
      else:
        ## Initiation
        if server.status notin {ServerStatus.Stopped, ServerStatus.Closed}:
          server.apending = true
          let
            pipeSuffix = $cast[cstring](baseAddr server.local.address_un)
            pipeAsciiName = PipeHeaderName & pipeSuffix
            pipeName = toWideString(pipeAsciiName).valueOr:
              raiseOsDefect(error, "acceptPipeLoop(): Unable to create name " &
                                   "for new pipe connection")
            openMode =
              if FirstPipe notin server.flags:
                server.flags.incl(FirstPipe)
                PIPE_ACCESS_DUPLEX or FILE_FLAG_OVERLAPPED or
                FILE_FLAG_FIRST_PIPE_INSTANCE
              else:
                PIPE_ACCESS_DUPLEX or FILE_FLAG_OVERLAPPED
            pipeMode = PIPE_TYPE_BYTE or PIPE_READMODE_BYTE or PIPE_WAIT
            pipeHandle = createNamedPipe(pipeName, openMode, pipeMode,
                                         PIPE_UNLIMITED_INSTANCES,
                                         DWORD(server.bufferSize),
                                         DWORD(server.bufferSize),
                                         DWORD(0), nil)
          free(pipeName)
          if pipeHandle == INVALID_HANDLE_VALUE:
            raiseOsDefect(osLastError(), "acceptPipeLoop(): Unable to create " &
                                         "new pipe")
          server.sock = AsyncFD(pipeHandle)
          let wres = register2(server.sock)
          if wres.isErr():
            raiseOsDefect(wres.error(), "acceptPipeLoop(): Unable to " &
                                        "register new pipe in dispatcher")
          let res = connectNamedPipe(pipeHandle,
                                     cast[POVERLAPPED](addr server.aovl))
          if res == 0:
            let errCode = osLastError()
            if errCode == ERROR_OPERATION_ABORTED:
              server.apending = false
              break
            elif errCode == ERROR_IO_PENDING:
              discard
            elif errCode == ERROR_PIPE_CONNECTED:
              discard
            else:
              raiseOsDefect(errCode, "acceptPipeLoop(): Unable to establish " &
                                     "pipe connection")
          break
        else:
          # Server close happens in callback, and we are not started new
          # connectNamedPipe session.
          if not(server.loopFuture.finished()):
            server.clean()
          break

  proc acceptLoop(udata: pointer) {.gcsafe, nimcall.} =
    var ovl = cast[PtrCustomOverlapped](udata)
    var server = cast[StreamServer](ovl.data.udata)
    var loop = getThreadDispatcher()

    while true:
      if server.apending:
        ## Continuation
        server.apending = false
        if server.status notin {ServerStatus.Stopped, ServerStatus.Closed}:
          case ovl.data.errCode
          of OSErrorCode(-1):
            if setsockopt(SocketHandle(server.asock), cint(SOL_SOCKET),
                          cint(SO_UPDATE_ACCEPT_CONTEXT),
                          addr server.sock,
                          SockLen(sizeof(SocketHandle))) != 0'i32:
              let errCode = OSErrorCode(wsaGetLastError())
              server.asock.closeSocket()
              raiseOsDefect(errCode, "acceptLoop(): Unable to set accept " &
                                     "context for socket")
            else:
              var ntransp: StreamTransport
              if not(isNil(server.init)):
                let transp = server.init(server, server.asock)
                ntransp = newStreamSocketTransport(server.asock,
                                                   server.bufferSize,
                                                   transp,
                                                   server.getTransportFlags())
              else:
                ntransp = newStreamSocketTransport(server.asock,
                                                   server.bufferSize, nil,
                                                   server.getTransportFlags())
              # Start tracking transport
              trackCounter(StreamTransportTrackerName)
              asyncSpawn server.function(server, ntransp)

          of ERROR_OPERATION_ABORTED:
            # CancelIO() interrupt or close.
            server.asock.closeSocket()
            if server.status in {ServerStatus.Closed, ServerStatus.Stopped}:
              # Stop tracking server
              if not(server.loopFuture.finished()):
                server.clean()
            break
          else:
            server.asock.closeSocket()
            raiseOsDefect(ovl.data.errCode, "acceptLoop(): Unable to accept " &
                                            "new connection")
        else:
          # Server close happens in callback, and we are not started new
          # AcceptEx session.
          if not(server.loopFuture.finished()):
            server.clean()
          break
      else:
        ## Initiation
        if server.status notin {ServerStatus.Stopped, ServerStatus.Closed}:
          server.apending = true
          # TODO No way to report back errors!
          server.asock = createAsyncSocket2(server.domain, SockType.SOCK_STREAM,
                                            Protocol.IPPROTO_TCP).valueOr:
            raiseOsDefect(error, "acceptLoop(): Unablet to create new socket")

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
          if res == FALSE:
            let errCode = osLastError()
            if errCode == ERROR_OPERATION_ABORTED:
              server.apending = false
              break
            elif errCode == ERROR_IO_PENDING:
              discard
            else:
              raiseOsDefect(errCode, "acceptLoop(): Unable to accept " &
                                     "connection")
          break
        else:
          # Server close happens in callback, and we are not started new
          # AcceptEx session.
          if not(server.loopFuture.finished()):
            server.clean()
          break

  proc resumeRead(transp: StreamTransport): Result[void, OSErrorCode] =
    if ReadPaused in transp.state:
      transp.state.excl(ReadPaused)
      readStreamLoop(cast[pointer](addr transp.rovl))
    ok()

  proc resumeWrite(transp: StreamTransport): Result[void, OSErrorCode] =
    if WritePaused in transp.state:
      transp.state.excl(WritePaused)
      writeStreamLoop(cast[pointer](addr transp.wovl))
    ok()

  proc pauseAccept(server: StreamServer): Result[void, OSErrorCode] =
    if server.apending:
      discard cancelIo(HANDLE(server.sock))
    ok()

  proc resumeAccept(server: StreamServer): Result[void, OSErrorCode] =
    if not(server.apending):
      server.aovl.data.cb(addr server.aovl)
    ok()

  proc accept*(server: StreamServer): Future[StreamTransport] {.
      async: (raw: true, raises: [TransportUseClosedError,
              TransportTooManyError, TransportAbortedError, TransportOsError,
              CancelledError]).} =
    var retFuture = newFuture[StreamTransport]("stream.server.accept")

    doAssert(server.status != ServerStatus.Running,
             "You could not use accept() if server was already started")

    if server.status == ServerStatus.Closed:
      retFuture.fail(getServerUseClosedError())
      return retFuture

    proc continuationSocket(udata: pointer) {.gcsafe.} =
      if retFuture.finished():
        # `retFuture` could become finished in 2 cases:
        # 1. OS sends IOCP notification about failure, but we already failed
        #    `retFuture` with proper error.
        # 2. `accept()` call has been cancelled. Cancellation callback closed
        #    accepting socket, so OS sends IOCP notification with an
        #    `ERROR_OPERATION_ABORTED` error.
        return

      var
        ovl = cast[PtrCustomOverlapped](udata)
        server = cast[StreamServer](ovl.data.udata)
      server.apending = false

      if server.status in {ServerStatus.Stopped, ServerStatus.Closed}:
        retFuture.fail(getServerUseClosedError())
        server.asock.closeSocket()
        server.clean()
      else:
        case ovl.data.errCode
        of OSErrorCode(-1):
          if setsockopt(SocketHandle(server.asock), cint(SOL_SOCKET),
                        cint(SO_UPDATE_ACCEPT_CONTEXT),
                        addr server.sock,
                        SockLen(sizeof(SocketHandle))) != 0'i32:
            let err = osLastError()
            server.asock.closeSocket()
            case err
            of WSAENOTSOCK:
              # This can be happened when server get closed, but continuation
              # was already scheduled, so we failing it not with OS error.
              retFuture.fail(getServerUseClosedError())
            else:
              let errorMsg = osErrorMsg(err)
              retFuture.fail(getConnectionAbortedError(errorMsg))
          else:
            var ntransp: StreamTransport
            if not(isNil(server.init)):
              let transp = server.init(server, server.asock)
              ntransp = newStreamSocketTransport(server.asock,
                                                 server.bufferSize,
                                                 transp,
                                                 server.getTransportFlags())
            else:
              ntransp = newStreamSocketTransport(server.asock,
                                                 server.bufferSize, nil,
                                                 server.getTransportFlags())
            # Start tracking transport
            trackCounter(StreamTransportTrackerName)
            retFuture.complete(ntransp)
        of ERROR_OPERATION_ABORTED:
          # CancelIO() interrupt or close.
          server.asock.closeSocket()
          retFuture.fail(getServerUseClosedError())
          server.clean()
        of WSAENETDOWN, WSAENETRESET, WSAECONNABORTED, WSAECONNRESET,
           WSAETIMEDOUT, ERROR_NETNAME_DELETED:
          server.asock.closeSocket()
          retFuture.fail(getConnectionAbortedError(ovl.data.errCode))
          server.clean()
        else:
          server.asock.closeSocket()
          retFuture.fail(getTransportOsError(ovl.data.errCode))

    proc cancellationSocket(udata: pointer) {.gcsafe.} =
      if server.apending:
        server.apending = false
      server.asock.closeSocket()

    proc continuationPipe(udata: pointer) {.gcsafe.} =
      if retFuture.finished():
        # `retFuture` could become finished in 2 cases:
        # 1. OS sends IOCP notification about failure, but we already failed
        #    `retFuture` with proper error.
        # 2. `accept()` call has been cancelled. Cancellation callback closed
        #    accepting socket, so OS sends IOCP notification with an
        #    `ERROR_OPERATION_ABORTED` error.
        return

      var
        ovl = cast[PtrCustomOverlapped](udata)
        server = cast[StreamServer](ovl.data.udata)
      server.apending = false

      if server.status in {ServerStatus.Stopped, ServerStatus.Closed}:
        retFuture.fail(getServerUseClosedError())
        server.sock.closeHandle()
        server.clean()
      else:
        case ovl.data.errCode
        of OSErrorCode(-1):
          var ntransp: StreamTransport
          var flags = {WinServerPipe}
          if NoPipeFlash in server.flags:
            flags.incl(WinNoPipeFlash)
          if not(isNil(server.init)):
            var transp = server.init(server, server.sock)
            ntransp = newStreamPipeTransport(server.sock, server.bufferSize,
                                             transp, flags)
          else:
            ntransp = newStreamPipeTransport(server.sock, server.bufferSize,
                                             nil, flags)
          server.sock = server.createAcceptPipe().valueOr:
            server.sock = asyncInvalidSocket
            server.errorCode = error
            retFuture.fail(getTransportOsError(error))
            return

          trackCounter(StreamTransportTrackerName)
          retFuture.complete(ntransp)

        of ERROR_OPERATION_ABORTED, ERROR_PIPE_NOT_CONNECTED:
          # CancelIO() interrupt or close call.
          retFuture.fail(getServerUseClosedError())
          server.clean()
        else:
          discard closeHandle(HANDLE(server.sock))
          server.sock = server.createAcceptPipe().valueOr:
            server.sock = asyncInvalidSocket
            server.errorCode = error
            retFuture.fail(getTransportOsError(error))
            return
          retFuture.fail(getTransportOsError(ovl.data.errCode))

    proc cancellationPipe(udata: pointer) {.gcsafe.} =
      if server.apending:
        server.apending = false
      server.sock.closeHandle()

    if server.local.family in {AddressFamily.IPv4, AddressFamily.IPv6}:
      # TCP Sockets part
      var loop = getThreadDispatcher()
      server.asock = createAsyncSocket2(server.domain, SockType.SOCK_STREAM,
                                        Protocol.IPPROTO_TCP).valueOr:
        case error
        of ERROR_TOO_MANY_OPEN_FILES, WSAENOBUFS, WSAEMFILE:
          retFuture.fail(getTransportTooManyError(error))
        else:
          retFuture.fail(getTransportOsError(error))
        return retFuture

      var dwBytesReceived = DWORD(0)
      let dwReceiveDataLength = DWORD(0)
      let dwLocalAddressLength = DWORD(sizeof(Sockaddr_in6) + 16)
      let dwRemoteAddressLength = DWORD(sizeof(Sockaddr_in6) + 16)

      server.aovl.data = CompletionData(cb: continuationSocket,
                                        udata: cast[pointer](server))
      server.apending = true
      let res = loop.acceptEx(SocketHandle(server.sock),
                              SocketHandle(server.asock),
                              addr server.abuffer[0],
                              dwReceiveDataLength, dwLocalAddressLength,
                              dwRemoteAddressLength, addr dwBytesReceived,
                              cast[POVERLAPPED](addr server.aovl))
      if res == FALSE:
        let err = osLastError()
        case err
        of ERROR_OPERATION_ABORTED:
          server.apending = false
          retFuture.fail(getServerUseClosedError())
          return retFuture
        of ERROR_IO_PENDING:
          discard
        of WSAECONNRESET, WSAECONNABORTED, WSAENETDOWN,
           WSAENETRESET, WSAETIMEDOUT:
          server.apending = false
          retFuture.fail(getConnectionAbortedError(err))
          return retFuture
        else:
          server.apending = false
          retFuture.fail(getTransportOsError(err))
          return retFuture

      retFuture.cancelCallback = cancellationSocket

    elif server.local.family in {AddressFamily.Unix}:
      # Unix domain sockets emulation via Windows Named pipes part.
      server.apending = true
      if server.sock == asyncInvalidPipe:
        let err = server.errorCode
        case err
        of ERROR_TOO_MANY_OPEN_FILES:
          retFuture.fail(getTransportTooManyError())
        else:
          retFuture.fail(getTransportOsError(err))
        return retFuture

      server.aovl.data = CompletionData(cb: continuationPipe,
                                        udata: cast[pointer](server))
      server.apending = true
      let res = connectNamedPipe(HANDLE(server.sock),
                                 cast[POVERLAPPED](addr server.aovl))
      if res == 0:
        let err = osLastError()
        case err
        of ERROR_OPERATION_ABORTED:
          server.apending = false
          retFuture.fail(getServerUseClosedError())
          return retFuture
        of ERROR_IO_PENDING, ERROR_PIPE_CONNECTED:
          discard
        else:
          server.apending = false
          retFuture.fail(getTransportOsError(err))
          return retFuture

      retFuture.cancelCallback = cancellationPipe

    return retFuture

else:
  import ../sendfile

  proc isConnResetError(err: OSErrorCode): bool {.inline.} =
    (err == oserrno.ECONNRESET) or (err == oserrno.EPIPE)

  proc writeStreamLoop(udata: pointer) =
    if isNil(udata):
      # TODO this is an if rather than an assert for historical reasons:
      # it should not happen unless there are race conditions - but if there
      # are race conditions, `transp` might be invalid even if it's not nil:
      # it could have been released
      return

    let
      transp = cast[StreamTransport](udata)
      fd = SocketHandle(transp.fd)

    if WriteClosed in transp.state:
      if transp.queue.len > 0:
        let error = getTransportUseClosedError()
        discard removeWriter2(transp.fd)
        failPendingWriteQueue(transp.queue, error)
      return

    # We exit this loop in two ways:
    # * The queue is empty: we call removeWriter to disable further callbacks
    # * EWOULDBLOCK is returned and we need to wait for a new notification

    while len(transp.queue) > 0:
      template handleError() =
        let err = osLastError()
        case err
        of oserrno.EINTR:
          # Signal happened while writing - try again with all data
          transp.queue.addFirst(vector)
          continue
        of oserrno.EWOULDBLOCK:
          # Socket buffer is full - wait until next write notification - in
          # particular, ensure removeWriter is not called
          transp.queue.addFirst(vector)
          return
        else:
          # The errors below will clear the write queue, meaning we'll exit the
          # loop
          if isConnResetError(err):
            # Soft error happens which indicates that remote peer got
            # disconnected, complete all pending writes in queue with 0.
            transp.state.incl({WriteEof})
            if not(vector.writer.finished()):
              vector.writer.complete(0)
            completePendingWriteQueue(transp.queue, 0)
          else:
            transp.state.incl({WriteError})
            let error = getTransportOsError(err)
            if not(vector.writer.finished()):
              vector.writer.fail(error)
            failPendingWriteQueue(transp.queue, error)

      var vector = transp.queue.popFirst()
      case vector.kind
      of VectorKind.DataBuffer:
        let res =
          case transp.kind
          of TransportKind.Socket:
            osdefs.send(fd, vector.buf, vector.buflen, MSG_NOSIGNAL)
          of TransportKind.Pipe:
            osdefs.write(cint(fd), vector.buf, vector.buflen)
          else: raiseAssert "Unsupported transport kind: " & $transp.kind

        if res >= 0:
          if vector.buflen == res:
            if not(vector.writer.finished()):
              vector.writer.complete(vector.size)
          else:
            vector.shiftVectorBuffer(res)
            transp.queue.addFirst(vector) # Try again with rest of data
        else:
          handleError()

      of VectorKind.DataFile:
        var nbytes = cast[int](vector.buf)
        let res = sendfile(int(fd), cast[int](vector.buflen),
                           int(vector.offset), nbytes)

        # In case of some errors on some systems, some bytes may have been
        # written (see sendfile.nim)
        vector.size += nbytes

        if res >= 0:
          if cast[int](vector.buf) == nbytes:
            if not(vector.writer.finished()):
              vector.writer.complete(vector.size)
          else:
            vector.shiftVectorFile(nbytes)
            transp.queue.addFirst(vector)
        else:
          vector.shiftVectorFile(nbytes)
          handleError()

    # Nothing left in the queue - no need for further write notifications
    # All writers are already scheduled, so its impossible to notify about an
    # error.
    transp.state.incl(WritePaused)
    discard removeWriter2(transp.fd)

  proc readStreamLoop(udata: pointer) =
    if isNil(udata):
      # TODO this is an if rather than an assert for historical reasons:
      # it should not happen unless there are race conditions - but if there
      # are race conditions, `transp` might be invalid even if it's not nil:
      # it could have been released
      return

    let
      transp = cast[StreamTransport](udata)
      fd = SocketHandle(transp.fd)

    if ReadClosed in transp.state:
      transp.state.incl({ReadPaused})
      transp.completeReader()
    else:
      if transp.kind == TransportKind.Socket:
        while true:
          let
            (data, size) = transp.buffer.reserve()
            res = handleEintr(osdefs.recv(fd, data, size, cint(0)))
          if res < 0:
            let err = osLastError()
            transp.buffer.commit(0)
            case err
            of oserrno.ECONNRESET:
              transp.state.incl({ReadEof, ReadPaused})
              let rres = removeReader2(transp.fd)
              if rres.isErr():
                transp.state.incl(ReadError)
                transp.setReadError(rres.error())
            else:
              transp.state.incl({ReadPaused, ReadError})
              transp.setReadError(err)
              discard removeReader2(transp.fd)
          elif res == 0:
            transp.state.incl({ReadEof, ReadPaused})
            transp.buffer.commit(0)
            let rres = removeReader2(transp.fd)
            if rres.isErr():
              transp.state.incl(ReadError)
              transp.setReadError(rres.error())
          else:
            transp.buffer.commit(res)
            if transp.buffer.availSpace() == 0:
              transp.state.incl(ReadPaused)
              let rres = removeReader2(transp.fd)
              if rres.isErr():
                transp.state.incl(ReadError)
                transp.setReadError(rres.error())
          transp.completeReader()
          break
      elif transp.kind == TransportKind.Pipe:
        while true:
          let
            (data, size) = transp.buffer.reserve()
            res = handleEintr(osdefs.read(cint(fd), data, size))
          if res < 0:
            let err = osLastError()
            transp.buffer.commit(0)
            transp.state.incl(ReadPaused)
            transp.setReadError(err)
            discard removeReader2(transp.fd)
          elif res == 0:
            transp.state.incl({ReadEof, ReadPaused})
            transp.buffer.commit(0)
            let rres = removeReader2(transp.fd)
            if rres.isErr():
              transp.state.incl(ReadError)
              transp.setReadError(rres.error())
          else:
            transp.buffer.commit(res)
            if transp.buffer.availSpace() == 0:
              transp.state.incl(ReadPaused)
              let rres = removeReader2(transp.fd)
              if rres.isErr():
                transp.state.incl(ReadError)
                transp.setReadError(rres.error())
          transp.completeReader()
          break

  proc newStreamSocketTransport(sock: AsyncFD, bufsize: int,
                                child: StreamTransport,
                                flags: set[TransportFlags]): StreamTransport =
    var transp: StreamTransport
    if not(isNil(child)):
      transp = child
    else:
      transp = StreamTransport(kind: TransportKind.Socket)

    transp.fd = sock
    transp.flags = flags
    let size = max(bufsize, DefaultStreamBufferSize)
    transp.buffer = BipBuffer.init(size)
    transp.state = {ReadPaused, WritePaused}
    transp.queue = initDeque[StreamVector]()
    transp.future = Future[void].Raising([]).init(
      "socket.stream.transport", {FutureFlag.OwnCancelSchedule})
    GC_ref(transp)
    transp

  proc newStreamPipeTransport(fd: AsyncFD, bufsize: int,
                              child: StreamTransport): StreamTransport =
    var transp: StreamTransport
    if not(isNil(child)):
      transp = child
    else:
      transp = StreamTransport(kind: TransportKind.Pipe)

    transp.fd = fd
    let size = max(bufsize, DefaultStreamBufferSize)
    transp.buffer = BipBuffer.init(size)
    transp.state = {ReadPaused, WritePaused}
    transp.queue = initDeque[StreamVector]()
    transp.future = Future[void].Raising([]).init(
      "pipe.stream.transport", {FutureFlag.OwnCancelSchedule})
    GC_ref(transp)
    transp

  proc connect*(address: TransportAddress,
                bufferSize = DefaultStreamBufferSize,
                child: StreamTransport = nil,
                localAddress = TransportAddress(),
                flags: set[SocketFlags] = {},
                dualstack = DualStackType.Auto,
               ): Future[StreamTransport] {.
               async: (raw: true, raises: [TransportError, CancelledError]).} =
    ## Open new connection to remote peer with address ``address`` and create
    ## new transport object ``StreamTransport`` for established connection.
    ## ``bufferSize`` - size of internal buffer for transport.
    var
      saddr: Sockaddr_storage
      slen: SockLen
    var retFuture = newFuture[StreamTransport]("stream.transport.connect")
    address.toSAddr(saddr, slen)
    let proto =
      if address.family == AddressFamily.Unix:
        Protocol.IPPROTO_IP
      else:
        Protocol.IPPROTO_TCP

    let sock = createAsyncSocket2(address.getDomain(), SockType.SOCK_STREAM,
                                  proto).valueOr:
      case error
      of oserrno.EMFILE:
        retFuture.fail(getTransportTooManyError())
      else:
        retFuture.fail(getTransportOsError(error))
      return retFuture

    if address.family in {AddressFamily.IPv4, AddressFamily.IPv6}:
      if SocketFlags.TcpNoDelay in flags:
        setSockOpt2(sock, osdefs.IPPROTO_TCP, osdefs.TCP_NODELAY, 1).isOkOr:
          sock.closeSocket()
          retFuture.fail(getTransportOsError(error))
          return retFuture

    if SocketFlags.ReuseAddr in flags:
      setSockOpt2(sock, SOL_SOCKET, SO_REUSEADDR, 1).isOkOr:
        sock.closeSocket()
        retFuture.fail(getTransportOsError(error))
        return retFuture
    if SocketFlags.ReusePort in flags:
      setSockOpt2(sock, SOL_SOCKET, SO_REUSEPORT, 1).isOkOr:
        sock.closeSocket()
        retFuture.fail(getTransportOsError(error))
        return retFuture
    # IPV6_V6ONLY.
    setDualstack(sock, address.family, dualstack).isOkOr:
      sock.closeSocket()
      retFuture.fail(getTransportOsError(error))
      return retFuture

    let transportFlags =
      block:
        # Add `V4Mapped` flag when `::` address is used and dualstack is
        # set to enabled or auto.
        var res: set[TransportFlags]
        if (localAddress.family == AddressFamily.IPv6) and
           localAddress.isAnyLocal():
          if dualstack != DualStackType.Disabled:
            res.incl(TransportFlags.V4Mapped)
        res

    case localAddress.family
    of AddressFamily.IPv4, AddressFamily.IPv6, AddressFamily.Unix:
      var
        lsaddr: Sockaddr_storage
        lslen: SockLen
      toSAddr(localAddress, lsaddr, lslen)
      if bindSocket(SocketHandle(sock),
        cast[ptr SockAddr](addr lsaddr), lslen) != 0:
        sock.closeSocket()
        retFuture.fail(getTransportOsError(osLastError()))
        return retFuture
    of AddressFamily.None:
      discard

    proc continuation(udata: pointer) =
      if not(retFuture.finished()):
        removeWriter2(sock).isOkOr:
          discard unregisterAndCloseFd(sock)
          retFuture.fail(getTransportOsError(error))
          return

        let err = sock.getSocketError2().valueOr:
          discard unregisterAndCloseFd(sock)
          retFuture.fail(getTransportOsError(error))
          return

        if err != 0:
          discard unregisterAndCloseFd(sock)
          retFuture.fail(getTransportOsError(OSErrorCode(err)))
          return

        let transp = newStreamSocketTransport(sock, bufferSize, child,
                                              transportFlags)
        # Start tracking transport
        trackCounter(StreamTransportTrackerName)
        retFuture.complete(transp)

    proc cancel(udata: pointer) =
      if not(retFuture.finished()):
        closeSocket(sock)

    while true:
      let res = osdefs.connect(SocketHandle(sock),
                               cast[ptr SockAddr](addr saddr), slen)
      if res == 0:
        let transp = newStreamSocketTransport(sock, bufferSize, child,
                                              transportFlags)
        # Start tracking transport
        trackCounter(StreamTransportTrackerName)
        retFuture.complete(transp)
        break
      else:
        let errorCode = osLastError()
        # If connect() is interrupted by a signal that is caught while blocked
        # waiting to establish a connection, connect() shall fail and set
        # connect() to [EINTR], but the connection request shall not be aborted,
        # and the connection shall be established asynchronously.
        #
        # http://www.madore.org/~david/computers/connect-intr.html
        case errorCode
        of oserrno.EINPROGRESS, oserrno.EINTR:
          addWriter2(sock, continuation).isOkOr:
            discard unregisterAndCloseFd(sock)
            retFuture.fail(getTransportOsError(error))
            return retFuture
          retFuture.cancelCallback = cancel
          break
        else:
          discard unregisterAndCloseFd(sock)
          retFuture.fail(getTransportOsError(errorCode))
          break
    return retFuture

  proc acceptLoop(udata: pointer) =
    if isNil(udata):
      # TODO this is an if rather than an assert for historical reasons:
      # it should not happen unless there are race conditions - but if there
      # are race conditions, `transp` might be invalid even if it's not nil:
      # it could have been released
      return

    var
      saddr: Sockaddr_storage
      slen: SockLen
    let server = cast[StreamServer](udata)
    if server.status in {ServerStatus.Stopped, ServerStatus.Closed}:
      return

    let
      flags = {DescriptorFlag.CloseOnExec, DescriptorFlag.NonBlock}
      sres = acceptConn(cint(server.sock), cast[ptr SockAddr](addr saddr),
                        addr slen, flags)
    if sres.isOk():
      let sock = AsyncFD(sres.get())
      let rres = register2(sock)
      if rres.isOk():
        let ntransp =
          if not(isNil(server.init)):
            let transp = server.init(server, sock)
            newStreamSocketTransport(sock, server.bufferSize, transp,
                                     server.getTransportFlags())
          else:
            newStreamSocketTransport(sock, server.bufferSize, nil,
                                     server.getTransportFlags())
        trackCounter(StreamTransportTrackerName)
        asyncSpawn server.function(server, ntransp)
      else:
        # Client was accepted, so we not going to raise assertion, but
        # we need to close the socket.
        discard closeFd(cint(sock))
    else:
      let errorCode = sres.error()
      if errorCode != oserrno.EAGAIN:
        # This EAGAIN error appears only when server get closed, while
        # acceptLoop() reader callback is already scheduled.
        raiseOsDefect(errorCode, "acceptLoop(): Unable to accept connection")

  proc resumeAccept(server: StreamServer): Result[void, OSErrorCode] =
    addReader2(server.sock, acceptLoop, cast[pointer](server))

  proc pauseAccept(server: StreamServer): Result[void, OSErrorCode] =
    removeReader2(server.sock)

  proc resumeRead(transp: StreamTransport): Result[void, OSErrorCode] =
    if ReadPaused in transp.state:
      ? addReader2(transp.fd, readStreamLoop, cast[pointer](transp))
      transp.state.excl(ReadPaused)
    ok()

  proc resumeWrite(transp: StreamTransport): Result[void, OSErrorCode] =
    if transp.queue.len() == 1:
      # writeStreamLoop keeps writing until queue is empty - we should not call
      # resumeWrite under any other condition than when the items are
      # added to a queue - if the flag is not set here, it means that the socket
      # was not removed from write notifications at the right time, and this
      # would mean an imbalance in registration and deregistration
      doAssert(WritePaused in transp.state)
      ? addWriter2(transp.fd, writeStreamLoop, cast[pointer](transp))
      transp.state.excl(WritePaused)
    ok()

  proc accept*(server: StreamServer): Future[StreamTransport] {.
      async: (raw: true, raises: [TransportUseClosedError,
              TransportTooManyError, TransportAbortedError, TransportOsError,
              CancelledError]).} =
    var retFuture = newFuture[StreamTransport]("stream.server.accept")

    doAssert(server.status != ServerStatus.Running,
             "You could not use accept() if server was started with start()")
    if server.status == ServerStatus.Closed:
      retFuture.fail(getServerUseClosedError())
      return retFuture

    proc continuation(udata: pointer) {.gcsafe.} =
      var
        saddr: Sockaddr_storage
        slen: SockLen

      if not(retFuture.finished()):
        if server.status in {ServerStatus.Stopped, ServerStatus.Closed}:
          retFuture.fail(getServerUseClosedError())
        else:
          let
            flags = {DescriptorFlag.CloseOnExec, DescriptorFlag.NonBlock}
            sres = acceptConn(cint(server.sock), cast[ptr SockAddr](addr saddr),
                              addr slen, flags)
          if sres.isErr():
            let errorCode = sres.error()
            case errorCode
            of oserrno.EAGAIN:
              # This error appears only when server get closed, while accept()
              # continuation is already scheduled.
              retFuture.fail(getServerUseClosedError())
            of oserrno.EMFILE, oserrno.ENFILE, oserrno.ENOBUFS, oserrno.ENOMEM:
              retFuture.fail(getTransportTooManyError(errorCode))
            of oserrno.ECONNABORTED, oserrno.EPERM, oserrno.ETIMEDOUT:
              retFuture.fail(getConnectionAbortedError(errorCode))
            else:
              retFuture.fail(getTransportOsError(errorCode))
            # Error is already happened so we ignore removeReader2() errors.
            discard removeReader2(server.sock)
          else:
            let
              sock = AsyncFD(sres.get())
              rres = register2(sock)
            if rres.isOk():
              let res = removeReader2(server.sock)
              if res.isOk():
                let ntransp =
                  if not(isNil(server.init)):
                    let transp = server.init(server, sock)
                    newStreamSocketTransport(sock, server.bufferSize, transp,
                                             server.getTransportFlags())
                  else:
                    newStreamSocketTransport(sock, server.bufferSize, nil,
                                             server.getTransportFlags())
                # Start tracking transport
                trackCounter(StreamTransportTrackerName)
                retFuture.complete(ntransp)
              else:
                discard closeFd(cint(sock))
                let errorMsg = osErrorMsg(res.error())
                retFuture.fail(getConnectionAbortedError(errorMsg))
            else:
              # Error is already happened so we ignore errors.
              discard removeReader2(server.sock)
              discard closeFd(cint(sock))
              let errorMsg = osErrorMsg(rres.error())
              retFuture.fail(getConnectionAbortedError(errorMsg))

    proc cancellation(udata: pointer) =
      if not(retFuture.finished()):
        discard removeReader2(server.sock)

    let res = addReader2(server.sock, continuation, nil)
    if res.isErr():
      retFuture.fail(getTransportOsError(res.error()))
    else:
      retFuture.cancelCallback = cancellation
    return retFuture

proc start2*(server: StreamServer): Result[void, OSErrorCode] =
  ## Starts ``server``.
  doAssert(not(isNil(server.function)), "You should not start the server " &
           "unless you have processing callback configured!")
  if server.status == ServerStatus.Starting:
    ? server.resumeAccept()
    server.status = ServerStatus.Running
  ok()

proc stop2*(server: StreamServer): Result[void, OSErrorCode] =
  ## Stops ``server``.
  if server.status == ServerStatus.Running:
    if not(isNil(server.function)):
      ? server.pauseAccept()
    server.status = ServerStatus.Stopped
  elif server.status == ServerStatus.Starting:
    server.status = ServerStatus.Stopped
  ok()

proc start*(server: StreamServer) {.raises: [TransportOsError].} =
  ## Starts ``server``.
  let res = start2(server)
  if res.isErr(): raiseTransportOsError(res.error())

proc stop*(server: StreamServer) {.raises: [TransportOsError].} =
  ## Stops ``server``.
  let res = stop2(server)
  if res.isErr(): raiseTransportOsError(res.error())

proc join*(server: StreamServer): Future[void] {.
    async: (raw: true, raises: [CancelledError]).} =
  ## Waits until ``server`` is not closed.
  server.loopFuture.join()

proc connect*(address: TransportAddress,
              bufferSize = DefaultStreamBufferSize,
              child: StreamTransport = nil,
              flags: set[TransportFlags],
              localAddress = TransportAddress(),
              dualstack = DualStackType.Auto
             ): Future[StreamTransport] {.
             async: (raw: true, raises: [TransportError, CancelledError]).} =
  # Retro compatibility with TransportFlags
  var mappedFlags: set[SocketFlags]
  if TcpNoDelay in flags: mappedFlags.incl(SocketFlags.TcpNoDelay)
  connect(address, bufferSize, child, localAddress, mappedFlags, dualstack)

proc closed*(server: StreamServer): bool =
  server.status == ServerStatus.Closed

proc close*(server: StreamServer) =
  ## Release ``server`` resources.
  ##
  ## Please note that release of resources is not completed immediately, to be
  ## sure all resources got released please use ``await server.join()``.
  proc continuation(udata: pointer) =
    # Stop tracking server
    if not(server.loopFuture.finished()):
      server.clean()

  if server.status in {ServerStatus.Starting, ServerStatus.Stopped}:
    server.status = ServerStatus.Closed
    when defined(windows):
      if server.local.family in {AddressFamily.IPv4, AddressFamily.IPv6}:
        if server.apending:
          server.asock.closeSocket()
          server.apending = false
        server.sock.closeSocket(continuation)
      elif server.local.family in {AddressFamily.Unix}:
        if NoPipeFlash notin server.flags:
          discard flushFileBuffers(HANDLE(server.sock))
        discard disconnectNamedPipe(HANDLE(server.sock))
        server.sock.closeHandle(continuation)
    else:
      server.sock.closeSocket(continuation)

proc closeWait*(server: StreamServer): Future[void] {.async: (raises: []).} =
  ## Close server ``server`` and release all resources.
  if not server.closed():
    server.close()
    await noCancel(server.join())

proc getBacklogSize(backlog: int): cint =
  doAssert(backlog >= 0 and backlog <= high(int32))
  when defined(windows):
    # The maximum length of the queue of pending connections. If set to
    # SOMAXCONN, the underlying service provider responsible for
    # socket s will set the backlog to a maximum reasonable value. If set to
    # SOMAXCONN_HINT(N) (where N is a number), the backlog value will be N,
    # adjusted to be within the range (200, 65535). Note that SOMAXCONN_HINT
    # can be used to set the backlog to a larger value than possible with
    # SOMAXCONN.
    #
    # Microsoft SDK values are
    # #define SOMAXCONN       0x7fffffff
    # #define SOMAXCONN_HINT(b) (-(b))
    if backlog != high(int32):
      cint(-backlog)
    else:
      cint(backlog)
  else:
    cint(backlog)

proc createStreamServer*(host: TransportAddress,
                         cbproc: StreamCallback2,
                         flags: set[ServerFlags] = {},
                         sock: AsyncFD = asyncInvalidSocket,
                         backlog: int = DefaultBacklogSize,
                         bufferSize: int = DefaultStreamBufferSize,
                         child: StreamServer = nil,
                         init: TransportInitCallback = nil,
                         udata: pointer = nil,
                         dualstack = DualStackType.Auto): StreamServer {.
    raises: [TransportOsError].} =
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
  let (serverSocket, localAddress, serverFlags) =
    when defined(windows):
      # Windows
      if host.family in {AddressFamily.IPv4, AddressFamily.IPv6}:
        var
          saddr: Sockaddr_storage
          slen: SockLen
          laddress: TransportAddress

        let sockres =
          if sock == asyncInvalidSocket:
            # TODO (cheatfate): `valueOr` generates weird compile error.
            let res = createAsyncSocket2(host.getDomain(), SockType.SOCK_STREAM,
                                         Protocol.IPPROTO_TCP)
            if res.isErr():
              raiseTransportOsError(res.error())
            res.get()
          else:
            setDescriptorBlocking(SocketHandle(sock), false).isOkOr:
              raiseTransportOsError(error)
            register2(sock).isOkOr:
              raiseTransportOsError(error)
            sock
        # SO_REUSEADDR
        if ServerFlags.ReuseAddr in flags:
          setSockOpt2(sockres, SOL_SOCKET, SO_REUSEADDR, 1).isOkOr:
            if sock == asyncInvalidSocket:
              discard closeFd(SocketHandle(sockres))
            raiseTransportOsError(error)
        # SO_REUSEPORT
        if ServerFlags.ReusePort in flags:
          setSockOpt2(sockres, SOL_SOCKET, SO_REUSEPORT, 1).isOkOr:
            if sock == asyncInvalidSocket:
              discard closeFd(SocketHandle(sockres))
            raiseTransportOsError(error)
        # TCP_NODELAY
        if ServerFlags.TcpNoDelay in flags:
          setSockOpt2(sockres, osdefs.IPPROTO_TCP,
                      osdefs.TCP_NODELAY, 1).isOkOr:
            if sock == asyncInvalidSocket:
              discard closeFd(SocketHandle(sockres))
            raiseTransportOsError(error)
        # IPV6_V6ONLY.
        if sock == asyncInvalidSocket:
          setDualstack(sockres, host.family, dualstack).isOkOr:
            discard closeFd(SocketHandle(sockres))
            raiseTransportOsError(error)
        else:
          setDualstack(sockres, dualstack).isOkOr:
            raiseTransportOsError(error)

        let flagres =
          block:
            var res = flags
            if (host.family == AddressFamily.IPv6) and host.isAnyLocal():
              if dualstack in {DualStackType.Enabled, DualStackType.Auto}:
                res.incl(ServerFlags.V4Mapped)
            res

        host.toSAddr(saddr, slen)

        if bindSocket(SocketHandle(sockres),
                      cast[ptr SockAddr](addr saddr), slen) != 0:
          let err = osLastError()
          if sock == asyncInvalidSocket:
            discard closeFd(SocketHandle(sockres))
          raiseTransportOsError(err)

        slen = SockLen(sizeof(saddr))

        if getsockname(SocketHandle(sockres), cast[ptr SockAddr](addr saddr),
                       addr slen) != 0:
          let err = osLastError()
          if sock == asyncInvalidSocket:
            discard closeFd(SocketHandle(sockres))
          raiseTransportOsError(err)

        fromSAddr(addr saddr, slen, laddress)

        if listen(SocketHandle(sockres), getBacklogSize(backlog)) != 0:
          let err = osLastError()
          if sock == asyncInvalidSocket:
            discard closeFd(SocketHandle(sockres))
          raiseTransportOsError(err)

        (sockres, laddress, flagres)
      elif host.family == AddressFamily.Unix:
        (AsyncFD(0), host, flags)
      else:
        raiseAssert "Incorrect host address family"
    else:
      # Posix
      var
        saddr: Sockaddr_storage
        slen: SockLen
        laddress: TransportAddress

      let sockres =
        if sock == asyncInvalidSocket:
          let proto = if host.family == AddressFamily.Unix:
            Protocol.IPPROTO_IP
          else:
            Protocol.IPPROTO_TCP
          # TODO (cheatfate): `valueOr` generates weird compile error.
          let res = createAsyncSocket2(host.getDomain(), SockType.SOCK_STREAM,
                                       proto)
          if res.isErr():
            raiseTransportOsError(res.error())
          res.get()
        else:
          setDescriptorFlags(cint(sock), true, true).isOkOr:
            raiseTransportOsError(error)
          register2(sock).isOkOr:
            raiseTransportOsError(error)
          sock

      if host.family in {AddressFamily.IPv4, AddressFamily.IPv6}:
        # SO_REUSEADDR
        if ServerFlags.ReuseAddr in flags:
          setSockOpt2(sockres, SOL_SOCKET, SO_REUSEADDR, 1).isOkOr:
            if sock == asyncInvalidSocket:
              discard unregisterAndCloseFd(sockres)
            raiseTransportOsError(error)
        # SO_REUSEPORT
        if ServerFlags.ReusePort in flags:
          setSockOpt2(sockres, SOL_SOCKET, SO_REUSEPORT, 1).isOkOr:
            if sock == asyncInvalidSocket:
              discard unregisterAndCloseFd(sockres)
            raiseTransportOsError(error)
        # TCP_NODELAY
        if ServerFlags.TcpNoDelay in flags:
          setSockOpt2(sockres, osdefs.IPPROTO_TCP,
                      osdefs.TCP_NODELAY, 1).isOkOr:
            if sock == asyncInvalidSocket:
              discard unregisterAndCloseFd(sockres)
            raiseTransportOsError(error)
        # IPV6_V6ONLY
        if sock == asyncInvalidSocket:
          setDualstack(sockres, host.family, dualstack).isOkOr:
            discard closeFd(SocketHandle(sockres))
            raiseTransportOsError(error)
        else:
          setDualstack(sockres, dualstack).isOkOr:
            raiseTransportOsError(error)

      elif host.family in {AddressFamily.Unix}:
        # We do not care about result here, because if file cannot be removed,
        # `bindSocket` will return EADDRINUSE.
        discard osdefs.unlink(cast[cstring](baseAddr host.address_un))

      let flagres =
        block:
          var res = flags
          if (host.family == AddressFamily.IPv6) and host.isAnyLocal():
            if dualstack != DualStackType.Disabled:
              res.incl(ServerFlags.V4Mapped)
          res

      host.toSAddr(saddr, slen)

      if osdefs.bindSocket(SocketHandle(sockres),
                           cast[ptr SockAddr](addr saddr), slen) != 0:
        let err = osLastError()
        if sock == asyncInvalidSocket:
          discard unregisterAndCloseFd(sockres)
        raiseTransportOsError(err)

      # Obtain real address
      slen = SockLen(sizeof(saddr))
      if getsockname(SocketHandle(sockres), cast[ptr SockAddr](addr saddr),
                     addr slen) != 0:
        let err = osLastError()
        if sock == asyncInvalidSocket:
          discard unregisterAndCloseFd(sockres)
        raiseTransportOsError(err)

      fromSAddr(addr saddr, slen, laddress)

      if listen(SocketHandle(sockres), getBacklogSize(backlog)) != 0:
        let err = osLastError()
        if sock == asyncInvalidSocket:
          discard unregisterAndCloseFd(sockres)
        raiseTransportOsError(err)

      (sockres, laddress, flagres)

  var sres = if not(isNil(child)): child else: StreamServer()

  sres.sock = serverSocket
  sres.flags = serverFlags
  sres.function = cbproc
  sres.init = init
  sres.bufferSize = bufferSize
  sres.status = Starting
  sres.loopFuture = asyncloop.init(
    Future[void].Raising([]), "stream.transport.server",
    {FutureFlag.OwnCancelSchedule})
  sres.udata = udata
  sres.dualstack = dualstack
  if localAddress.family != AddressFamily.None:
    sres.local = localAddress

  when defined(windows):
    var cb: CallbackFunc
    if host.family in {AddressFamily.IPv4, AddressFamily.IPv6}:
      cb = acceptLoop
    elif host.family == AddressFamily.Unix:
      cb = acceptPipeLoop

    if not(isNil(cbproc)):
      sres.aovl.data = CompletionData(cb: cb, udata: cast[pointer](sres))
    else:
      if host.family == AddressFamily.Unix:
        sres.sock =
          block:
            let res = sres.createAcceptPipe()
            if res.isErr():
              raiseTransportOsError(res.error())
            res.get()

    sres.domain = host.getDomain()
    sres.apending = false

  # Start tracking server
  trackCounter(StreamServerTrackerName)
  GC_ref(sres)
  sres

proc createStreamServer*(host: TransportAddress,
                         cbproc: StreamCallback,
                         flags: set[ServerFlags] = {},
                         sock: AsyncFD = asyncInvalidSocket,
                         backlog: int = DefaultBacklogSize,
                         bufferSize: int = DefaultStreamBufferSize,
                         child: StreamServer = nil,
                         init: TransportInitCallback = nil,
                         udata: pointer = nil,
                         dualstack = DualStackType.Auto): StreamServer {.
    raises: [TransportOsError],
    deprecated: "Callback must not raise exceptions, annotate with {.async: (raises: []).}".} =
  proc wrap(server: StreamServer,
            client: StreamTransport) {.async: (raises: []).} =
    try:
      await cbproc(server, client)
    except CatchableError as exc:
      raiseAssert "Unexpected exception from stream server cbproc: " & exc.msg

  createStreamServer(
    host, wrap, flags, sock, backlog, bufferSize, child, init, udata,
    dualstack)

proc createStreamServer*(host: TransportAddress,
                         flags: set[ServerFlags] = {},
                         sock: AsyncFD = asyncInvalidSocket,
                         backlog: int = DefaultBacklogSize,
                         bufferSize: int = DefaultStreamBufferSize,
                         child: StreamServer = nil,
                         init: TransportInitCallback = nil,
                         udata: pointer = nil,
                         dualstack = DualStackType.Auto): StreamServer {.
    raises: [TransportOsError].} =
  createStreamServer(host, StreamCallback2(nil), flags, sock, backlog, bufferSize,
                     child, init, cast[pointer](udata), dualstack)

proc createStreamServer*(port: Port,
                         host: Opt[IpAddress] = Opt.none(IpAddress),
                         flags: set[ServerFlags] = {},
                         sock: AsyncFD = asyncInvalidSocket,
                         backlog: int = DefaultBacklogSize,
                         bufferSize: int = DefaultStreamBufferSize,
                         child: StreamServer = nil,
                         init: TransportInitCallback = nil,
                         udata: pointer = nil,
                         dualstack = DualStackType.Auto): StreamServer {.
    raises: [TransportOsError].} =
  ## Create stream server which will be bound to:
  ## 1. IPv6 address `::`, if IPv6 is available
  ## 2. IPv4 address `0.0.0.0`, if IPv6 is not available.
  let hostname =
    if host.isSome():
      initTAddress(host.get(), port)
    else:
      getAutoAddress(port)
  createStreamServer(hostname, StreamCallback2(nil), flags, sock,
                     backlog, bufferSize, child, init, cast[pointer](udata),
                     dualstack)

proc createStreamServer*(cbproc: StreamCallback2,
                         port: Port,
                         host: Opt[IpAddress] = Opt.none(IpAddress),
                         flags: set[ServerFlags] = {},
                         sock: AsyncFD = asyncInvalidSocket,
                         backlog: int = DefaultBacklogSize,
                         bufferSize: int = DefaultStreamBufferSize,
                         child: StreamServer = nil,
                         init: TransportInitCallback = nil,
                         udata: pointer = nil,
                         dualstack = DualStackType.Auto): StreamServer {.
    raises: [TransportOsError].} =
  ## Create stream server which will be bound to:
  ## 1. IPv6 address `::`, if IPv6 is available
  ## 2. IPv4 address `0.0.0.0`, if IPv6 is not available.
  let hostname =
    if host.isSome():
      initTAddress(host.get(), port)
    else:
      getAutoAddress(port)
  createStreamServer(hostname, cbproc, flags, sock, backlog,
                     bufferSize, child, init, cast[pointer](udata), dualstack)

proc createStreamServer*[T](host: TransportAddress,
                            cbproc: StreamCallback2,
                            flags: set[ServerFlags] = {},
                            udata: ref T,
                            sock: AsyncFD = asyncInvalidSocket,
                            backlog: int = DefaultBacklogSize,
                            bufferSize: int = DefaultStreamBufferSize,
                            child: StreamServer = nil,
                            init: TransportInitCallback = nil,
                            dualstack = DualStackType.Auto): StreamServer {.
    raises: [TransportOsError].} =
  var fflags = flags + {GCUserData}
  GC_ref(udata)
  createStreamServer(host, cbproc, fflags, sock, backlog, bufferSize,
                     child, init, cast[pointer](udata), dualstack)

proc createStreamServer*[T](host: TransportAddress,
                            cbproc: StreamCallback,
                            flags: set[ServerFlags] = {},
                            udata: ref T,
                            sock: AsyncFD = asyncInvalidSocket,
                            backlog: int = DefaultBacklogSize,
                            bufferSize: int = DefaultStreamBufferSize,
                            child: StreamServer = nil,
                            init: TransportInitCallback = nil,
                            dualstack = DualStackType.Auto): StreamServer {.
    raises: [TransportOsError],
    deprecated: "Callback must not raise exceptions, annotate with {.async: (raises: []).}".} =
  var fflags = flags + {GCUserData}
  GC_ref(udata)
  createStreamServer(host, cbproc, fflags, sock, backlog, bufferSize,
                     child, init, cast[pointer](udata), dualstack)

proc createStreamServer*[T](host: TransportAddress,
                            flags: set[ServerFlags] = {},
                            udata: ref T,
                            sock: AsyncFD = asyncInvalidSocket,
                            backlog: int = DefaultBacklogSize,
                            bufferSize: int = DefaultStreamBufferSize,
                            child: StreamServer = nil,
                            init: TransportInitCallback = nil,
                            dualstack = DualStackType.Auto): StreamServer {.
    raises: [TransportOsError].} =
  var fflags = flags + {GCUserData}
  GC_ref(udata)
  createStreamServer(host, StreamCallback2(nil), fflags, sock, backlog, bufferSize,
                     child, init, cast[pointer](udata), dualstack)

proc createStreamServer*[T](cbproc: StreamCallback2,
                            port: Port,
                            host: Opt[IpAddress] = Opt.none(IpAddress),
                            flags: set[ServerFlags] = {},
                            udata: ref T,
                            sock: AsyncFD = asyncInvalidSocket,
                            backlog: int = DefaultBacklogSize,
                            bufferSize: int = DefaultStreamBufferSize,
                            child: StreamServer = nil,
                            init: TransportInitCallback = nil,
                            dualstack = DualStackType.Auto): StreamServer {.
    raises: [TransportOsError].} =
  ## Create stream server which will be bound to:
  ## 1. IPv6 address `::`, if IPv6 is available
  ## 2. IPv4 address `0.0.0.0`, if IPv6 is not available.
  let fflags = flags + {GCUserData}
  GC_ref(udata)
  let hostname =
    if host.isSome():
      initTAddress(host.get(), port)
    else:
      getAutoAddress(port)
  createStreamServer(hostname, cbproc, fflags, sock, backlog,
                     bufferSize, child, init, cast[pointer](udata), dualstack)

proc createStreamServer*[T](port: Port,
                            host: Opt[IpAddress] = Opt.none(IpAddress),
                            flags: set[ServerFlags] = {},
                            udata: ref T,
                            sock: AsyncFD = asyncInvalidSocket,
                            backlog: int = DefaultBacklogSize,
                            bufferSize: int = DefaultStreamBufferSize,
                            child: StreamServer = nil,
                            init: TransportInitCallback = nil,
                            dualstack = DualStackType.Auto): StreamServer {.
    raises: [TransportOsError].} =
  ## Create stream server which will be bound to:
  ## 1. IPv6 address `::`, if IPv6 is available
  ## 2. IPv4 address `0.0.0.0`, if IPv6 is not available.
  let fflags = flags + {GCUserData}
  GC_ref(udata)
  let hostname =
    if host.isSome():
      initTAddress(host.get(), port)
    else:
      getAutoAddress(port)
  createStreamServer(hostname, StreamCallback2(nil), fflags, sock,
                     backlog, bufferSize, child, init, cast[pointer](udata),
                     dualstack)

proc getUserData*[T](server: StreamServer): T {.inline.} =
  ## Obtain user data stored in ``server`` object.
  cast[T](server.udata)

template fastWrite(transp: auto, pbytes: var ptr byte, rbytes: var int,
                   nbytes: int) =
  # On windows, the write could be initiated here if there is no other write
  # ongoing, but the queue is still needed due to the mechanics of iocp

  when not defined(windows) and not defined(nimdoc):
    if transp.queue.len == 0:
      while rbytes > 0:
        let res =
          case transp.kind
          of TransportKind.Socket:
            osdefs.send(SocketHandle(transp.fd), pbytes, rbytes,
                       MSG_NOSIGNAL)
          of TransportKind.Pipe:
            osdefs.write(cint(transp.fd), pbytes, rbytes)
          else:
            raiseAssert "Unsupported transport kind: " & $transp.kind
        if res > 0:
          pbytes = cast[ptr byte](cast[uint](pbytes) + cast[uint](res))
          rbytes -= res

          if rbytes == 0:
            retFuture.complete(nbytes)
            return retFuture
          # Not all bytes written - keep going
        else:
          let err = osLastError()
          case err
          of oserrno.EWOULDBLOCK:
            break # No bytes written, add to queue
          of oserrno.EINTR:
            continue
          else:
            if isConnResetError(err):
              transp.state.incl({WriteEof})
              retFuture.complete(0)
              return retFuture
            else:
              transp.state.incl({WriteError})
              let error = getTransportOsError(err)
              retFuture.fail(error)
              return retFuture

proc write*(transp: StreamTransport, pbytes: pointer,
            nbytes: int): Future[int] {.
            async: (raw: true, raises: [TransportError, CancelledError]).} =
  ## Write data from buffer ``pbytes`` with size ``nbytes`` using transport
  ## ``transp``.
  var retFuture = newFuture[int]("stream.transport.write(pointer)")
  transp.checkClosed(retFuture)
  transp.checkWriteEof(retFuture)

  var
    pbytes = cast[ptr byte](pbytes)
    rbytes = nbytes # Remaining bytes

  fastWrite(transp, pbytes, rbytes, nbytes)

  var vector = StreamVector(kind: DataBuffer, writer: retFuture,
                            buf: pbytes, buflen: rbytes, size: nbytes)
  transp.queue.addLast(vector)
  let wres = transp.resumeWrite()
  if wres.isErr():
    retFuture.fail(getTransportOsError(wres.error()))
  return retFuture

proc write*(transp: StreamTransport, msg: string,
            msglen = -1): Future[int] {.
            async: (raw: true, raises: [TransportError, CancelledError]).} =
  ## Write data from string ``msg`` using transport ``transp``.
  var retFuture = newFuture[int]("stream.transport.write(string)")
  transp.checkClosed(retFuture)
  transp.checkWriteEof(retFuture)
  let
    nbytes = if msglen <= 0: len(msg) else: msglen

  var
    pbytes = cast[ptr byte](baseAddr msg)
    rbytes = nbytes

  fastWrite(transp, pbytes, rbytes, nbytes)

  let
    written = nbytes - rbytes # In case fastWrite wrote some

  var localCopy = msg
  retFuture.addCallback(proc(_: pointer) = reset(localCopy))

  pbytes = cast[ptr byte](addr localCopy[written])

  var vector = StreamVector(kind: DataBuffer, writer: retFuture,
                            buf: pbytes, buflen: rbytes, size: nbytes)
  transp.queue.addLast(vector)
  let wres = transp.resumeWrite()
  if wres.isErr():
    retFuture.fail(getTransportOsError(wres.error()))
  return retFuture

proc write*[T](transp: StreamTransport, msg: seq[T],
               msglen = -1): Future[int] {.
               async: (raw: true, raises: [TransportError, CancelledError]).} =
  ## Write sequence ``msg`` using transport ``transp``.
  var retFuture = newFuture[int]("stream.transport.write(seq)")
  transp.checkClosed(retFuture)
  transp.checkWriteEof(retFuture)

  let
    nbytes = if msglen <= 0: (len(msg) * sizeof(T)) else: (msglen * sizeof(T))

  var
    pbytes = cast[ptr byte](baseAddr msg)
    rbytes = nbytes

  fastWrite(transp, pbytes, rbytes, nbytes)

  let
    written = nbytes - rbytes # In case fastWrite wrote some

  var localCopy = msg
  retFuture.addCallback(proc(_: pointer) = reset(localCopy))

  pbytes = cast[ptr byte](addr localCopy[written])

  var vector = StreamVector(kind: DataBuffer, writer: retFuture,
                            buf: pbytes, buflen: rbytes, size: nbytes)
  transp.queue.addLast(vector)
  let wres = transp.resumeWrite()
  if wres.isErr():
    retFuture.fail(getTransportOsError(wres.error()))
  return retFuture

proc writeFile*(transp: StreamTransport, handle: int,
                offset: uint = 0, size: int = 0): Future[int] {.
                async: (raw: true, raises: [TransportError, CancelledError]).} =
  ## Write data from file descriptor ``handle`` to transport ``transp``.
  ##
  ## You can specify starting ``offset`` in opened file and number of bytes
  ## to transfer from file to transport via ``size``.
  var retFuture = newFuture[int]("stream.transport.writeFile")
  when defined(windows):
    if transp.kind != TransportKind.Socket:
      retFuture.fail(newException(
        TransportNoSupport, "writeFile() is not supported!"))
      return retFuture
  transp.checkClosed(retFuture)
  transp.checkWriteEof(retFuture)
  var vector = StreamVector(kind: DataFile, writer: retFuture,
                            buf: cast[pointer](size), offset: offset,
                            buflen: handle)
  transp.queue.addLast(vector)
  let wres = transp.resumeWrite()
  if wres.isErr():
    retFuture.fail(getTransportOsError(wres.error()))
  return retFuture

proc atEof*(transp: StreamTransport): bool {.inline.} =
  ## Returns ``true`` if ``transp`` is at EOF.
  (len(transp.buffer) == 0) and (ReadEof in transp.state) and
  (ReadPaused in transp.state)

template readLoop(name, body: untyped): untyped =
  # Read data until a predicate is satisfied - the body should return a tuple
  # signalling how many bytes have been processed and whether we're done reading
  checkClosed(transp)
  checkPending(transp)
  while true:
    if ReadClosed in transp.state:
      raise newException(TransportUseClosedError,
                         "Attempt to read data from closed stream")
    if len(transp.buffer) == 0:
      # We going to raise an error, only if transport buffer is empty.
      if ReadError in transp.state:
        raise transp.getError()

    let (consumed, done) = body
    transp.buffer.consume(consumed)
    if done:
      break

    if len(transp.buffer) == 0:
      checkPending(transp)
      let fut = ReaderFuture.init(name)
      transp.reader = fut
      let res = resumeRead(transp)
      if res.isErr():
        let errorCode = res.error()
        when defined(windows):
          # This assertion could be changed, because at this moment
          # resumeRead() could not return any error.
          raiseOsDefect(errorCode, "readLoop(): Unable to resume reading")
        else:
          transp.completeReader()
          if errorCode == oserrno.ESRCH:
            # ESRCH 3 "No such process"
            # This error could be happened on pipes only, when process which
            # owns and communicates through this pipe (stdin, stdout, stderr) is
            # already dead. In such case we need to send notification that this
            # pipe is at EOF.
            transp.state.incl({ReadEof, ReadPaused})
          else:
            raiseTransportOsError(errorCode)
      else:
        await fut

proc readExactly*(transp: StreamTransport, pbytes: pointer,
                  nbytes: int) {.
                  async: (raises: [TransportError, CancelledError]).} =
  ## Read exactly ``nbytes`` bytes from transport ``transp`` and store it to
  ## ``pbytes``. ``pbytes`` must not be ``nil`` pointer and ``nbytes`` should
  ## be Natural.
  ##
  ## If ``nbytes == 0`` this operation will return immediately.
  ##
  ## If EOF is received and ``nbytes`` is not yet read, the procedure
  ## will raise ``TransportIncompleteError``, potentially with some bytes
  ## already written.
  doAssert(not(isNil(pbytes)), "pbytes must not be nil")
  doAssert(nbytes >= 0, "nbytes must be non-negative integer")

  if nbytes == 0:
    return

  var
    index = 0
    pbuffer = pbytes.toUnchecked()
  readLoop("stream.transport.readExactly"):
    if len(transp.buffer) == 0:
      if transp.atEof():
        raise newException(TransportIncompleteError, "Data incomplete!")
    var bytesRead = 0
    for (region, rsize) in transp.buffer.regions():
      let count = min(nbytes - index, rsize)
      bytesRead += count
      if count > 0:
        copyMem(addr pbuffer[index], region, count)
        index += count
      if index == nbytes:
        break
    (consumed: bytesRead, done: index == nbytes)

proc readOnce*(transp: StreamTransport, pbytes: pointer,
               nbytes: int): Future[int] {.
               async: (raises: [TransportError, CancelledError]).} =
  ## Perform one read operation on transport ``transp``.
  ##
  ## If internal buffer is not empty, ``nbytes`` bytes will be transferred from
  ## internal buffer, otherwise it will wait until some bytes will be received.
  doAssert(not(isNil(pbytes)), "pbytes must not be nil")
  doAssert(nbytes > 0, "nbytes must be positive integer")

  var
    pbuffer = pbytes.toUnchecked()
    index = 0
  readLoop("stream.transport.readOnce"):
    if len(transp.buffer) == 0:
      (0, transp.atEof())
    else:
      for (region, rsize) in transp.buffer.regions():
        let size = min(rsize, nbytes - index)
        copyMem(addr pbuffer[index], region, size)
        index += size
        if index >= nbytes:
          break
      (index, true)
  index

proc readUntil*(transp: StreamTransport, pbytes: pointer, nbytes: int,
                sep: seq[byte]): Future[int] {.
                async: (raises: [TransportError, CancelledError]).} =
  ## Read data from the transport ``transp`` until separator ``sep`` is found.
  ##
  ## On success, the data and separator will be removed from the internal
  ## buffer (consumed). Returned data will include the separator at the end.
  ##
  ## If EOF is received, and `sep` was not found, procedure will raise
  ## ``TransportIncompleteError``.
  ##
  ## If ``nbytes`` bytes has been received and `sep` was not found, procedure
  ## will raise ``TransportLimitError``.
  ##
  ## Procedure returns actual number of bytes read.
  doAssert(not(isNil(pbytes)), "pbytes must not be nil")
  doAssert(len(sep) > 0, "separator must not be empty")
  doAssert(nbytes >= 0, "nbytes must be non-negative integer")

  if nbytes == 0:
    raise newException(TransportLimitError, "Limit reached!")

  var pbuffer = pbytes.toUnchecked()
  var state = 0
  var k = 0

  readLoop("stream.transport.readUntil"):
    if transp.atEof():
      raise newException(TransportIncompleteError, "Data incomplete!")

    var index = 0
    for ch in transp.buffer:
      if k >= nbytes:
        raise newException(TransportLimitError, "Limit reached!")

      inc(index)
      pbuffer[k] = ch
      inc(k)

      if sep[state] == ch:
        inc(state)
        if state == len(sep):
          break
      else:
        state = 0

    (index, state == len(sep))
  k

proc readLine*(transp: StreamTransport, limit = 0,
               sep = "\r\n"): Future[string] {.
               async: (raises: [TransportError, CancelledError]).} =
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
  let lim = if limit <= 0: -1 else: limit
  var state = 0
  var res: string

  readLoop("stream.transport.readLine"):
    if transp.atEof():
      (0, true)
    else:
      var index = 0
      for ch in transp.buffer:
        inc(index)

        if sep[state] == char(ch):
          inc(state)
          if state == len(sep):
            break
        else:
          if state != 0:
            if limit > 0:
              let missing = min(state, lim - len(res) - 1)
              res.add(sep[0 ..< missing])
            else:
              res.add(sep[0 ..< state])
            state = 0

          res.add(char(ch))
          if len(res) == lim:
            break

      (index, (state == len(sep)) or (lim == len(res)))
  res

proc read*(transp: StreamTransport): Future[seq[byte]] {.
    async: (raises: [TransportError, CancelledError]).} =
  ## Read all bytes from transport ``transp``.
  ##
  ## This procedure allocates buffer seq[byte] and return it as result.
  var res: seq[byte]
  readLoop("stream.transport.read"):
    if transp.atEof():
      (0, true)
    else:
      var bytesRead = 0
      for (region, rsize) in transp.buffer.regions():
        bytesRead += rsize
        res.add(region.toUnchecked().toOpenArray(0, rsize - 1))
      (bytesRead, false)
  res

proc read*(transp: StreamTransport, n: int): Future[seq[byte]] {.
    async: (raises: [TransportError, CancelledError]).} =
  ## Read all bytes (n <= 0) or exactly `n` bytes from transport ``transp``.
  ##
  ## This procedure allocates buffer seq[byte] and return it as result.
  if n <= 0:
    await transp.read()
  else:
    var res: seq[byte]
    readLoop("stream.transport.read"):
      if transp.atEof():
        (0, true)
      else:
        var bytesRead = 0
        for (region, rsize) in transp.buffer.regions():
          let count = min(rsize, n - len(res))
          bytesRead += count
          res.add(region.toUnchecked().toOpenArray(0, count - 1))
        (bytesRead, len(res) == n)
    res

proc consume*(transp: StreamTransport): Future[int] {.
    async: (raises: [TransportError, CancelledError]).} =
  ## Consume all bytes from transport ``transp`` and discard it.
  ##
  ## Return number of bytes actually consumed and discarded.
  var res = 0
  readLoop("stream.transport.consume"):
    if transp.atEof():
      (0, true)
    else:
      let used = len(transp.buffer)
      res += used
      (used, false)
  res

proc consume*(transp: StreamTransport, n: int): Future[int] {.
    async: (raises: [TransportError, CancelledError]).} =
  ## Consume all bytes (n <= 0) or ``n`` bytes from transport ``transp`` and
  ## discard it.
  ##
  ## Return number of bytes actually consumed and discarded.
  if n <= 0:
    await transp.consume()
  else:
    var res = 0
    readLoop("stream.transport.consume"):
      if transp.atEof():
        (0, true)
      else:
        let
          used = len(transp.buffer)
          count = min(used, n - res)
        res += count
        (count, res == n)
    res

proc readMessage*(transp: StreamTransport,
                  predicate: ReadMessagePredicate) {.
                  async: (raises: [TransportError, CancelledError]).} =
  ## Read all bytes from transport ``transp`` until ``predicate`` callback
  ## will not be satisfied.
  ##
  ## ``predicate`` callback should return tuple ``(consumed, result)``, where
  ## ``consumed`` is the number of bytes processed and ``result`` is a
  ## completion flag (``true`` if readMessage() should stop reading data,
  ## or ``false`` if readMessage() should continue to read data from transport).
  ##
  ## ``predicate`` callback must copy all the data from ``data`` array and
  ## return number of bytes it is going to consume.
  ## ``predicate`` callback will receive (zero-length) openArray, if transport
  ## is at EOF.
  readLoop("stream.transport.readMessage"):
    if len(transp.buffer) == 0:
      if transp.atEof():
        predicate([])
      else:
        # Case, when transport's buffer is not yet filled with data.
        (0, false)
    else:
      var res: tuple[consumed: int, done: bool]
      for (region, rsize) in transp.buffer.regions():
        res = predicate(region.toUnchecked().toOpenArray(0, rsize - 1))
        break
      res

proc join*(transp: StreamTransport): Future[void] {.
    async: (raw: true, raises: [CancelledError]).} =
  ## Wait until ``transp`` will not be closed.
  var retFuture = newFuture[void]("stream.transport.join")

  proc continuation(udata: pointer) {.gcsafe.} =
    retFuture.complete()

  proc cancel(udata: pointer) {.gcsafe.} =
    transp.future.removeCallback(continuation, cast[pointer](retFuture))

  if not(transp.future.finished()):
    transp.future.addCallback(continuation, cast[pointer](retFuture))
    retFuture.cancelCallback = cancel
  else:
    retFuture.complete()
  retFuture

proc closed*(transp: StreamTransport): bool {.inline.} =
  ## Returns ``true`` if transport in closed state.
  ({ReadClosed, WriteClosed} * transp.state != {})

proc finished*(transp: StreamTransport): bool {.inline.} =
  ## Returns ``true`` if transport in finished (EOF) state.
  ({ReadEof, WriteEof} * transp.state != {})

proc failed*(transp: StreamTransport): bool {.inline.} =
  ## Returns ``true`` if transport in error state.
  ({ReadError, WriteError} * transp.state != {})

proc running*(transp: StreamTransport): bool {.inline.} =
  ## Returns ``true`` if transport is still pending.
  ({ReadClosed, ReadEof, ReadError,
    WriteClosed, WriteEof, WriteError} * transp.state == {})

proc close*(transp: StreamTransport) =
  ## Closes and frees resources of transport ``transp``.
  ##
  ## Please note that release of resources is not completed immediately, to be
  ## sure all resources got released please use ``await transp.join()``.
  proc continuation(udata: pointer) {.gcsafe.} =
    transp.clean()

  if {ReadClosed, WriteClosed} * transp.state == {}:
    transp.state.incl({WriteClosed, ReadClosed})
    when defined(windows):
      if transp.kind == TransportKind.Pipe:
        if WinServerPipe in transp.flags:
          if WinNoPipeFlash notin transp.flags:
            discard flushFileBuffers(HANDLE(transp.fd))
          discard disconnectNamedPipe(HANDLE(transp.fd))
        else:
          if WinNoPipeFlash notin transp.flags:
            discard flushFileBuffers(HANDLE(transp.fd))
        if ReadPaused in transp.state:
          # If readStreamLoop() is not running we need to finish in
          # continuation step.
          closeHandle(transp.fd, continuation)
        else:
          # If readStreamLoop() is running, it will be properly finished inside
          # of readStreamLoop().
          closeHandle(transp.fd)
      elif transp.kind == TransportKind.Socket:
        if ReadPaused in transp.state:
          # If readStreamLoop() is not running we need to finish in
          # continuation step.
          closeSocket(transp.fd, continuation)
        else:
          # If readStreamLoop() is running, it will be properly finished inside
          # of readStreamLoop().
          closeSocket(transp.fd)
    else:
      if transp.kind == TransportKind.Pipe:
        closeHandle(transp.fd, continuation)
      elif transp.kind == TransportKind.Socket:
        closeSocket(transp.fd, continuation)

proc closeWait*(transp: StreamTransport): Future[void] {.async: (raises: []).} =
  ## Close and frees resources of transport ``transp``.
  if not transp.closed():
    transp.close()
    await noCancel(transp.join())

proc shutdownWait*(transp: StreamTransport): Future[void] {.
    async: (raw: true, raises: [TransportError, CancelledError]).} =
  ## Perform graceful shutdown of TCP connection backed by transport ``transp``.
  doAssert(transp.kind == TransportKind.Socket)
  let retFuture = newFuture[void]("stream.transport.shutdown")
  transp.checkClosed(retFuture)

  when defined(windows):
    let loop = getThreadDispatcher()
    proc continuation(udata: pointer) {.gcsafe.} =
      let ovl = cast[RefCustomOverlapped](udata)
      if not(retFuture.finished()):
        if ovl.data.errCode == OSErrorCode(-1):
          retFuture.complete()
        else:
          transp.state.excl({WriteEof})
          retFuture.fail(getTransportOsError(ovl.data.errCode))
        GC_unref(ovl)

    let povl = RefCustomOverlapped(data: CompletionData(cb: continuation))
    GC_ref(povl)

    let res = loop.disconnectEx(SocketHandle(transp.fd),
                                cast[POVERLAPPED](povl), 0'u32, 0'u32)
    if res == FALSE:
      let err = osLastError()
      case err
      of ERROR_IO_PENDING:
        transp.state.incl({WriteEof})
      else:
        GC_unref(povl)
        retFuture.fail(getTransportOsError(err))
    else:
      transp.state.incl({WriteEof})
      retFuture.complete()

    retFuture
  else:
    proc continuation(udata: pointer) {.gcsafe.} =
      if not(retFuture.finished()):
        retFuture.complete()

    let res = osdefs.shutdown(SocketHandle(transp.fd), SHUT_WR)
    if res < 0:
      let err = osLastError()
      case err
      of ENOTCONN:
        # The specified socket is not connected, it means that our initial
        # goal is already happened.
        transp.state.incl({WriteEof})
        callSoon(continuation, nil)
      else:
        retFuture.fail(getTransportOsError(err))
    else:
      transp.state.incl({WriteEof})
      callSoon(continuation, nil)
    retFuture

proc fromPipe2*(fd: AsyncFD, child: StreamTransport = nil,
                bufferSize = DefaultStreamBufferSize
               ): Result[StreamTransport, OSErrorCode] =
  ## Create new transport object using pipe's file descriptor.
  ##
  ## ``bufferSize`` is size of internal buffer for transport.
  ? register2(fd)
  var res = newStreamPipeTransport(fd, bufferSize, child)
  # Start tracking transport
  trackCounter(StreamTransportTrackerName)
  ok(res)

proc fromPipe*(fd: AsyncFD, child: StreamTransport = nil,
               bufferSize = DefaultStreamBufferSize): StreamTransport {.
    raises: [TransportOsError].} =
  ## Create new transport object using pipe's file descriptor.
  ##
  ## ``bufferSize`` is size of internal buffer for transport.
  let res = fromPipe2(fd, child, bufferSize)
  if res.isErr(): raiseTransportOsError(res.error())
  res.get()

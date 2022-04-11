#
#             Chronos Stream Transport
#            (c) Copyright 2018-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

{.push raises: [Defect].}

import std/[net, nativesockets, os, deques]
import ".."/[asyncloop, handles, selectors2]
import common

when defined(windows) or defined(nimdoc):
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
    WinNoPipeFlash
    # By default `AddressFamily.Unix` transports in Windows are using
    # `FlushFileBuffers()` when transport closing.
    # This flag disables usage of `FlushFileBuffers()` on `AddressFamily.Unix`
    # transport shutdown. If both server and client are running in the same
    # thread, because of `FlushFileBuffers()` will ensure that all bytes
    # or messages written to the pipe are read by the client, it is possible to
    # get stuck on transport `close()`.
    # Please use this flag only if you are making both client and server in
    # the same thread.

  StreamTransportTracker* = ref object of TrackerBase
    opened*: int64
    closed*: int64

  StreamServerTracker* = ref object of TrackerBase
    opened*: int64
    closed*: int64

  ReadMessagePredicate* = proc (data: openArray[byte]): tuple[consumed: int,
                                                              done: bool] {.
    gcsafe, raises: [Defect].}

const
  StreamTransportTrackerName = "stream.transport"
  StreamServerTrackerName = "stream.server"

when defined(windows):
  const SO_UPDATE_CONNECT_CONTEXT = 0x7010

  type
    StreamTransport* = ref object of RootRef
      fd*: AsyncFD                    # File descriptor
      state: set[TransportState]      # Current Transport state
      reader: Future[void]            # Current reader Future
      buffer: seq[byte]               # Reading buffer
      offset: int                     # Reading buffer offset
      error: ref CatchableError       # Current error
      queue: Deque[StreamVector]      # Writer queue
      future: Future[void]            # Stream life future
      # Windows specific part
      rwsabuf: TWSABuf                # Reader WSABUF
      wwsabuf: TWSABuf                # Writer WSABUF
      rovl: CustomOverlapped          # Reader OVERLAPPED structure
      wovl: CustomOverlapped          # Writer OVERLAPPED structure
      roffset: int                    # Pending reading offset
      flags: set[TransportFlags]      # Internal flags
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
      error: ref CatchableError       # Current error
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
                         client: StreamTransport): Future[void] {.gcsafe, raises: [Defect].}
    ## New remote client connection callback
    ## ``server`` - StreamServer object.
    ## ``client`` - accepted client transport.

  TransportInitCallback* = proc(server: StreamServer,
                                fd: AsyncFD): StreamTransport {.gcsafe, raises: [Defect].}
    ## Custom transport initialization procedure, which can allocate inherited
    ## StreamTransport object.

  StreamServer* = ref object of SocketServer
    ## StreamServer object
    function*: StreamCallback         # callback which will be called after new
                                      # client accepted
    init*: TransportInitCallback      # callback which will be called before
                                      # transport for new client

proc remoteAddress*(transp: StreamTransport): TransportAddress {.
    raises: [Defect, TransportError].} =
  ## Returns ``transp`` remote socket address.
  if transp.kind != TransportKind.Socket:
    raise newException(TransportError, "Socket required!")
  if transp.remote.family == AddressFamily.None:
    var saddr: Sockaddr_storage
    var slen = SockLen(sizeof(saddr))
    if getpeername(SocketHandle(transp.fd), cast[ptr SockAddr](addr saddr),
                   addr slen) != 0:
      raiseTransportOsError(osLastError())
    fromSAddr(addr saddr, slen, transp.remote)
  result = transp.remote

proc localAddress*(transp: StreamTransport): TransportAddress {.
    raises: [Defect, TransportError].} =
  ## Returns ``transp`` local socket address.
  if transp.kind != TransportKind.Socket:
    raise newException(TransportError, "Socket required!")
  if transp.local.family == AddressFamily.None:
    var saddr: Sockaddr_storage
    var slen = SockLen(sizeof(saddr))
    if getsockname(SocketHandle(transp.fd), cast[ptr SockAddr](addr saddr),
                   addr slen) != 0:
      raiseTransportOsError(osLastError())
    fromSAddr(addr saddr, slen, transp.local)
  result = transp.local

proc localAddress*(server: StreamServer): TransportAddress =
  ## Returns ``server`` bound local socket address.
  result = server.local

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

template shiftBuffer(t, c: untyped) =
  if (t).offset > c:
    if c > 0:
      moveMem(addr((t).buffer[0]), addr((t).buffer[(c)]), (t).offset - (c))
      (t).offset = (t).offset - (c)
  else:
    (t).offset = 0

template shiftVectorBuffer(v: var StreamVector, o: untyped) =
  (v).buf = cast[pointer](cast[uint]((v).buf) + uint(o))
  (v).buflen -= int(o)

template shiftVectorFile(v: var StreamVector, o: untyped) =
  (v).buf = cast[pointer](cast[uint]((v).buf) - cast[uint](o))
  (v).offset += cast[uint]((o))

proc setupStreamTransportTracker(): StreamTransportTracker {.
     gcsafe, raises: [Defect].}
proc setupStreamServerTracker(): StreamServerTracker {.
     gcsafe, raises: [Defect].}

proc getStreamTransportTracker(): StreamTransportTracker {.inline.} =
  result = cast[StreamTransportTracker](getTracker(StreamTransportTrackerName))
  if isNil(result):
    result = setupStreamTransportTracker()

proc getStreamServerTracker(): StreamServerTracker {.inline.} =
  result = cast[StreamServerTracker](getTracker(StreamServerTrackerName))
  if isNil(result):
    result = setupStreamServerTracker()

proc dumpTransportTracking(): string {.gcsafe.} =
  var tracker = getStreamTransportTracker()
  result = "Opened transports: " & $tracker.opened & "\n" &
           "Closed transports: " & $tracker.closed

proc dumpServerTracking(): string {.gcsafe.} =
  var tracker = getStreamServerTracker()
  result = "Opened servers: " & $tracker.opened & "\n" &
           "Closed servers: " & $tracker.closed

proc leakTransport(): bool {.gcsafe.} =
  var tracker = getStreamTransportTracker()
  result = tracker.opened != tracker.closed

proc leakServer(): bool {.gcsafe.} =
  var tracker = getStreamServerTracker()
  result = tracker.opened != tracker.closed

proc trackStream(t: StreamTransport) {.inline.} =
  var tracker = getStreamTransportTracker()
  inc(tracker.opened)

proc untrackStream(t: StreamTransport) {.inline.}  =
  var tracker = getStreamTransportTracker()
  inc(tracker.closed)

proc trackServer(s: StreamServer) {.inline.} =
  var tracker = getStreamServerTracker()
  inc(tracker.opened)

proc untrackServer(s: StreamServer) {.inline.}  =
  var tracker = getStreamServerTracker()
  inc(tracker.closed)

proc setupStreamTransportTracker(): StreamTransportTracker {.gcsafe.} =
  result = new StreamTransportTracker
  result.opened = 0
  result.closed = 0
  result.dump = dumpTransportTracking
  result.isLeaked = leakTransport
  addTracker(StreamTransportTrackerName, result)

proc setupStreamServerTracker(): StreamServerTracker {.gcsafe.} =
  result = new StreamServerTracker
  result.opened = 0
  result.closed = 0
  result.dump = dumpServerTracking
  result.isLeaked = leakServer
  addTracker(StreamServerTrackerName, result)

proc completePendingWriteQueue(queue: var Deque[StreamVector],
                               v: int) {.inline.} =
  while len(queue) > 0:
    var vector = queue.popFirst()
    if not(vector.writer.finished()):
      vector.writer.complete(v)

proc failPendingWriteQueue(queue: var Deque[StreamVector],
                           error: ref CatchableError) {.inline.} =
  while len(queue) > 0:
    var vector = queue.popFirst()
    if not(vector.writer.finished()):
      vector.writer.fail(error)

proc clean(server: StreamServer) {.inline.} =
  if not(server.loopFuture.finished()):
    untrackServer(server)
    server.loopFuture.complete()
    if not(isNil(server.udata)) and (GCUserData in server.flags):
      GC_unref(cast[ref int](server.udata))
    GC_unref(server)

proc clean(transp: StreamTransport) {.inline.} =
  if not(transp.future.finished()):
    untrackStream(transp)
    transp.future.complete()
    GC_unref(transp)

when defined(nimdoc):
  proc pauseAccept(server: StreamServer) {.inline.} = discard
  proc resumeAccept(server: StreamServer) {.inline.} = discard
  proc resumeRead(transp: StreamTransport) {.inline.} = discard
  proc accept*(server: StreamServer): Future[StreamTransport] = discard
  proc resumeWrite(transp: StreamTransport) {.inline.} = discard
  proc newStreamPipeTransport(fd: AsyncFD, bufsize: int,
                              child: StreamTransport,
                             flags: set[TransportFlags] = {}): StreamTransport =
    discard
elif defined(windows):

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

  template setReaderWSABuffer(t: untyped) =
    (t).rwsabuf.buf = cast[cstring](
      cast[uint](addr t.buffer[0]) + uint((t).roffset))
    (t).rwsabuf.len = int32(len((t).buffer) - (t).roffset)

  template setWriterWSABuffer(t, v: untyped) =
    (t).wwsabuf.buf = cast[cstring](v.buf)
    (t).wwsabuf.len = cast[int32](v.buflen)

  proc isConnResetError(err: OSErrorCode): bool {.inline.} =
    result = (err == OSErrorCode(common.WSAECONNRESET)) or
             (err == OSErrorCode(common.WSAECONNABORTED)) or
             (err == OSErrorCode(common.ERROR_PIPE_NOT_CONNECTED))

  proc writeStreamLoop(udata: pointer) {.gcsafe, nimcall.} =
    var bytesCount: int32
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
          if err == OSErrorCode(-1):
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
                      vector.writer.complete(transp.wwsabuf.len)
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
                      vector.writer.complete(transp.wwsabuf.len)
          elif int(err) == ERROR_OPERATION_ABORTED:
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
              let ret = WSASend(sock, addr transp.wwsabuf, 1,
                                addr bytesCount, DWORD(0),
                                cast[POVERLAPPED](addr transp.wovl), nil)
              if ret != 0:
                let err = osLastError()
                if int(err) == ERROR_OPERATION_ABORTED:
                  # CancelIO() interrupt
                  transp.state.excl(WritePending)
                  transp.state.incl({WritePaused, WriteEof})
                  if not(vector.writer.finished()):
                    vector.writer.complete(0)
                  completePendingWriteQueue(transp.queue, 0)
                  break
                elif int(err) == ERROR_IO_PENDING:
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
              let loop = getThreadDispatcher()
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
                  transp.state.incl({WritePaused, WriteEof})
                  if not(vector.writer.finished()):
                    vector.writer.complete(0)
                  completePendingWriteQueue(transp.queue, 0)
                  break
                elif int(err) == ERROR_IO_PENDING:
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
            let pipe = Handle(transp.fd)
            var vector = transp.queue.popFirst()
            if vector.kind == VectorKind.DataBuffer:
              transp.wovl.zeroOvelappedOffset()
              transp.setWriterWSABuffer(vector)
              let ret = writeFile(pipe, cast[pointer](transp.wwsabuf.buf),
                                  DWORD(transp.wwsabuf.len), addr bytesCount,
                                  cast[POVERLAPPED](addr transp.wovl))
              if ret == 0:
                let err = osLastError()
                if int(err) in {ERROR_OPERATION_ABORTED, ERROR_NO_DATA}:
                  # CancelIO() interrupt
                  transp.state.excl(WritePending)
                  transp.state.incl({WritePaused, WriteEof})
                  if not(vector.writer.finished()):
                    vector.writer.complete(0)
                  completePendingWriteQueue(transp.queue, 0)
                  break
                elif int(err) == ERROR_IO_PENDING:
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
        elif int(err) in {ERROR_OPERATION_ABORTED, ERROR_CONNECTION_ABORTED,
                          ERROR_BROKEN_PIPE, ERROR_NETNAME_DELETED}:
          # CancelIO() interrupt or closeSocket() call.
          transp.state.incl(ReadPaused)
        elif transp.kind == TransportKind.Socket and
             (int(err) in {ERROR_NETNAME_DELETED, common.WSAECONNABORTED}):
          transp.state.incl({ReadEof, ReadPaused})
        elif transp.kind == TransportKind.Pipe and
             (int(err) in {ERROR_PIPE_NOT_CONNECTED}):
          transp.state.incl({ReadEof, ReadPaused})
        else:
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
          var bytesCount: int32 = 0
          transp.state.excl(ReadPaused)
          transp.state.incl(ReadPending)
          if transp.kind == TransportKind.Socket:
            let sock = SocketHandle(transp.fd)
            transp.roffset = transp.offset
            transp.setReaderWSABuffer()
            let ret = WSARecv(sock, addr transp.rwsabuf, 1,
                              addr bytesCount, addr flags,
                              cast[POVERLAPPED](addr transp.rovl), nil)
            if ret != 0:
              let err = osLastError()
              if int32(err) == ERROR_OPERATION_ABORTED:
                # CancelIO() interrupt
                transp.state.excl(ReadPending)
                transp.state.incl(ReadPaused)
              elif int32(err) in {common.WSAECONNRESET, common.WSAENETRESET,
                                  common.WSAECONNABORTED}:
                transp.state.excl(ReadPending)
                transp.state.incl({ReadEof, ReadPaused})
                transp.completeReader()
              elif int32(err) != ERROR_IO_PENDING:
                transp.state.excl(ReadPending)
                transp.state.incl(ReadPaused)
                transp.setReadError(err)
                transp.completeReader()
          elif transp.kind == TransportKind.Pipe:
            let pipe = Handle(transp.fd)
            transp.roffset = transp.offset
            transp.setReaderWSABuffer()
            let ret = readFile(pipe, cast[pointer](transp.rwsabuf.buf),
                               DWORD(transp.rwsabuf.len), addr bytesCount,
                               cast[POVERLAPPED](addr transp.rovl))
            if ret == 0:
              let err = osLastError()
              if int32(err) == ERROR_OPERATION_ABORTED:
                # CancelIO() interrupt
                transp.state.excl(ReadPending)
                transp.state.incl(ReadPaused)
              elif int32(err) in {ERROR_BROKEN_PIPE, ERROR_PIPE_NOT_CONNECTED}:
                transp.state.excl(ReadPending)
                transp.state.incl({ReadEof, ReadPaused})
                transp.completeReader()
              elif int32(err) != ERROR_IO_PENDING:
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
                                child: StreamTransport): StreamTransport =
    var transp: StreamTransport
    if not(isNil(child)):
      transp = child
    else:
      transp = StreamTransport(kind: TransportKind.Socket)
    transp.fd = sock
    transp.rovl.data = CompletionData(cb: readStreamLoop,
                                      udata: cast[pointer](transp))
    transp.wovl.data = CompletionData(cb: writeStreamLoop,
                                      udata: cast[pointer](transp))
    transp.buffer = newSeq[byte](bufsize)
    transp.state = {ReadPaused, WritePaused}
    transp.queue = initDeque[StreamVector]()
    transp.future = newFuture[void]("stream.socket.transport")
    GC_ref(transp)
    result = transp

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
    transp.buffer = newSeq[byte](bufsize)
    transp.flags = flags
    transp.state = {ReadPaused, WritePaused}
    transp.queue = initDeque[StreamVector]()
    transp.future = newFuture[void]("stream.pipe.transport")
    GC_ref(transp)
    result = transp

  proc bindToDomain(handle: AsyncFD, domain: Domain): bool =
    result = true
    if domain == Domain.AF_INET6:
      var saddr: Sockaddr_in6
      saddr.sin6_family = type(saddr.sin6_family)(toInt(domain))
      if bindAddr(SocketHandle(handle), cast[ptr SockAddr](addr(saddr)),
                  sizeof(saddr).SockLen) != 0'i32:
        result = false
    elif domain == Domain.AF_INET:
      var saddr: Sockaddr_in
      saddr.sin_family = type(saddr.sin_family)(toInt(domain))
      if bindAddr(SocketHandle(handle), cast[ptr SockAddr](addr(saddr)),
                  sizeof(saddr).SockLen) != 0'i32:
        result = false

  proc connect*(address: TransportAddress,
                bufferSize = DefaultStreamBufferSize,
                child: StreamTransport = nil,
                flags: set[TransportFlags] = {}): Future[StreamTransport] =
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
      sock = try: createAsyncSocket(raddress.getDomain(), SockType.SOCK_STREAM,
                               proto)
      except CatchableError as exc:
        retFuture.fail(exc)
        return retFuture
      if sock == asyncInvalidSocket:
        retFuture.fail(getTransportOsError(osLastError()))
        return retFuture

      if not(bindToDomain(sock, raddress.getDomain())):
        let err = wsaGetLastError()
        sock.closeSocket()
        retFuture.fail(getTransportOsError(err))
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
              let transp = newStreamSocketTransport(sock, bufferSize, child)
              # Start tracking transport
              trackStream(transp)
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
                               DWORD(slen), nil, 0, nil,
                               cast[POVERLAPPED](povl))
      # We will not process immediate completion, to avoid undefined behavior.
      if not(res):
        let err = osLastError()
        if int32(err) != ERROR_IO_PENDING:
          GC_unref(povl)
          sock.closeSocket()
          retFuture.fail(getTransportOsError(err))

      retFuture.cancelCallback = cancel

    elif address.family == AddressFamily.Unix:
      ## Unix domain socket emulation with Windows Named Pipes.
      var pipeHandle = INVALID_HANDLE_VALUE
      var pipeContinuation: proc (udata: pointer) {.gcsafe, raises: [Defect].}
      pipeContinuation = proc (udata: pointer) {.gcsafe, raises: [Defect].} =
        # Continue only if `retFuture` is not cancelled.
        if not(retFuture.finished()):
          var pipeSuffix = $cast[cstring](unsafeAddr address.address_un[0])
          var pipeName = newWideCString(r"\\.\pipe\" & pipeSuffix[1 .. ^1])
          pipeHandle = createFileW(pipeName, GENERIC_READ or GENERIC_WRITE,
                                   FILE_SHARE_READ or FILE_SHARE_WRITE,
                                   nil, OPEN_EXISTING,
                                   FILE_FLAG_OVERLAPPED, Handle(0))
          if pipeHandle == INVALID_HANDLE_VALUE:
            let err = osLastError()
            if int32(err) == ERROR_PIPE_BUSY:
              discard setTimer(Moment.fromNow(50.milliseconds),
                               pipeContinuation, nil)
            else:
              retFuture.fail(getTransportOsError(err))
          else:
            try:
              register(AsyncFD(pipeHandle))
            except CatchableError as exc:
              retFuture.fail(exc)
              return

            let transp = try: newStreamPipeTransport(AsyncFD(pipeHandle),
                                                bufferSize, child)
            except CatchableError as exc:
              retFuture.fail(exc)
              return
            # Start tracking transport
            trackStream(transp)
            retFuture.complete(transp)
      pipeContinuation(nil)

    return retFuture

  proc createAcceptPipe(server: StreamServer) {.
      raises: [Defect, CatchableError].} =
    let pipeSuffix = $cast[cstring](addr server.local.address_un)
    let pipeName = newWideCString(r"\\.\pipe\" & pipeSuffix[1 .. ^1])
    var openMode = PIPE_ACCESS_DUPLEX or FILE_FLAG_OVERLAPPED
    if FirstPipe notin server.flags:
      openMode = openMode or FILE_FLAG_FIRST_PIPE_INSTANCE
      server.flags.incl(FirstPipe)
    let pipeMode = int32(PIPE_TYPE_BYTE or PIPE_READMODE_BYTE or PIPE_WAIT)
    let pipeHandle = createNamedPipe(pipeName, openMode, pipeMode,
                                     PIPE_UNLIMITED_INSTANCES,
                                     DWORD(server.bufferSize),
                                     DWORD(server.bufferSize),
                                     DWORD(0), nil)
    if pipeHandle != INVALID_HANDLE_VALUE:
      server.sock = AsyncFD(pipeHandle)
      register(server.sock)
    else:
      server.sock = asyncInvalidPipe
      server.errorCode = osLastError()

  proc acceptPipeLoop(udata: pointer) {.gcsafe, nimcall.} =
    var ovl = cast[PtrCustomOverlapped](udata)
    var server = cast[StreamServer](ovl.data.udata)

    while true:
      if server.apending:
        ## Continuation
        server.apending = false
        if server.status notin {ServerStatus.Stopped, ServerStatus.Closed}:
          if ovl.data.errCode == OSErrorCode(-1):
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
            trackStream(ntransp)
            asyncCheck server.function(server, ntransp)
          elif int32(ovl.data.errCode) == ERROR_OPERATION_ABORTED:
            # CancelIO() interrupt or close call.
            if server.status in {ServerStatus.Closed, ServerStatus.Stopped}:
              server.clean()
            break
          else:
            # We should not raise defects in this loop.
            discard disconnectNamedPipe(Handle(server.sock))
            discard closeHandle(Handle(server.sock))
            raiseAssert osErrorMsg(osLastError())
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
          var pipeSuffix = $cast[cstring](addr server.local.address_un)
          var pipeName = newWideCString(r"\\.\pipe\" & pipeSuffix[1 .. ^1])
          var openMode = PIPE_ACCESS_DUPLEX or FILE_FLAG_OVERLAPPED
          if FirstPipe notin server.flags:
            openMode = openMode or FILE_FLAG_FIRST_PIPE_INSTANCE
            server.flags.incl(FirstPipe)
          let pipeMode = int32(PIPE_TYPE_BYTE or PIPE_READMODE_BYTE or PIPE_WAIT)
          let pipeHandle = createNamedPipe(pipeName, openMode, pipeMode,
                                           PIPE_UNLIMITED_INSTANCES,
                                           DWORD(server.bufferSize),
                                           DWORD(server.bufferSize),
                                           DWORD(0), nil)
          if pipeHandle == INVALID_HANDLE_VALUE:
            raiseAssert osErrorMsg(osLastError())
          server.sock = AsyncFD(pipeHandle)
          try: register(server.sock)
          except CatchableError as exc:
            raiseAsDefect exc, "register"
          let res = connectNamedPipe(pipeHandle,
                                     cast[POVERLAPPED](addr server.aovl))
          if res == 0:
            let err = osLastError()
            if int32(err) == ERROR_OPERATION_ABORTED:
              server.apending = false
              break
            elif int32(err) == ERROR_IO_PENDING:
              discard
            elif int32(err) == ERROR_PIPE_CONNECTED:
              discard
            else:
              raiseAssert osErrorMsg(err)
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
          if ovl.data.errCode == OSErrorCode(-1):
            if setsockopt(SocketHandle(server.asock), cint(SOL_SOCKET),
                          cint(SO_UPDATE_ACCEPT_CONTEXT), addr server.sock,
                          SockLen(sizeof(SocketHandle))) != 0'i32:
              let err = OSErrorCode(wsaGetLastError())
              server.asock.closeSocket()
              raiseAssert osErrorMsg(err)
            else:
              var ntransp: StreamTransport
              if not(isNil(server.init)):
                let transp = server.init(server, server.asock)
                ntransp = newStreamSocketTransport(server.asock,
                                                   server.bufferSize,
                                                   transp)
              else:
                ntransp = newStreamSocketTransport(server.asock,
                                                   server.bufferSize, nil)
              # Start tracking transport
              trackStream(ntransp)
              asyncCheck server.function(server, ntransp)

          elif int32(ovl.data.errCode) == ERROR_OPERATION_ABORTED:
            # CancelIO() interrupt or close.
            server.asock.closeSocket()
            if server.status in {ServerStatus.Closed, ServerStatus.Stopped}:
              # Stop tracking server
              if not(server.loopFuture.finished()):
                server.clean()
            break
          else:
            server.asock.closeSocket()
            raiseAssert $(ovl.data.errCode)
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
          server.asock =
            try:
              createAsyncSocket(server.domain, SockType.SOCK_STREAM,
                                Protocol.IPPROTO_TCP)
            except CatchableError as exc:
              raiseAsDefect exc, "createAsyncSocket"
          if server.asock == asyncInvalidSocket:
            raiseAssert osErrorMsg(OSErrorCode(wsaGetLastError()))

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
          if not(res):
            let err = osLastError()
            if int32(err) == ERROR_OPERATION_ABORTED:
              server.apending = false
              break
            elif int32(err) == ERROR_IO_PENDING:
              discard
            else:
              raiseAssert osErrorMsg(err)
          break
        else:
          # Server close happens in callback, and we are not started new
          # AcceptEx session.
          if not(server.loopFuture.finished()):
            server.clean()
          break

  proc resumeRead(transp: StreamTransport) {.inline.} =
    if ReadPaused in transp.state:
      transp.state.excl(ReadPaused)
      readStreamLoop(cast[pointer](addr transp.rovl))

  proc resumeWrite(transp: StreamTransport) {.inline.} =
    if WritePaused in transp.state:
      transp.state.excl(WritePaused)
      writeStreamLoop(cast[pointer](addr transp.wovl))

  proc pauseAccept(server: StreamServer) {.inline.} =
    if server.apending:
      discard cancelIo(Handle(server.sock))

  proc resumeAccept(server: StreamServer) {.inline.} =
    if not(server.apending):
      server.aovl.data.cb(addr server.aovl)

  proc accept*(server: StreamServer): Future[StreamTransport] =
    var retFuture = newFuture[StreamTransport]("stream.server.accept")

    doAssert(server.status != ServerStatus.Running,
             "You could not use accept() if server was already started")

    if server.status == ServerStatus.Closed:
      retFuture.fail(getServerUseClosedError())
      return retFuture

    proc continuationSocket(udata: pointer) {.gcsafe.} =
      var ovl = cast[PtrCustomOverlapped](udata)
      var server = cast[StreamServer](ovl.data.udata)

      server.apending = false
      if not(retFuture.finished()):
        if server.status in {ServerStatus.Stopped, ServerStatus.Closed}:
          retFuture.fail(getServerUseClosedError())
          server.asock.closeSocket()
          server.clean()
        else:
          case ovl.data.errCode
          of OSErrorCode(-1):
            if setsockopt(SocketHandle(server.asock), cint(SOL_SOCKET),
                          cint(SO_UPDATE_ACCEPT_CONTEXT), addr server.sock,
                          SockLen(sizeof(SocketHandle))) != 0'i32:
              let err = OSErrorCode(wsaGetLastError())
              server.asock.closeSocket()
              if int32(err) == WSAENOTSOCK:
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
                                                   transp)
              else:
                ntransp = newStreamSocketTransport(server.asock,
                                                   server.bufferSize, nil)
              # Start tracking transport
              trackStream(ntransp)
              retFuture.complete(ntransp)
          of OSErrorCode(ERROR_OPERATION_ABORTED):
            # CancelIO() interrupt or close.
            server.asock.closeSocket()
            retFuture.fail(getServerUseClosedError())
            server.clean()
          of OSErrorCode(common.WSAENETDOWN), OSErrorCode(common.WSAENETRESET),
             OSErrorCode(common.WSAECONNABORTED),
             OSErrorCode(common.WSAECONNRESET),
             OSErrorCode(common.WSAETIMEDOUT):
            server.asock.closeSocket()
            retFuture.fail(getConnectionAbortedError(int(ovl.data.errCode)))
            server.clean()
          else:
            server.asock.closeSocket()
            retFuture.fail(getTransportOsError(ovl.data.errCode))

    proc cancellationSocket(udata: pointer) {.gcsafe.} =
      if server.apending:
        server.apending = false
      server.asock.closeSocket()

    proc continuationPipe(udata: pointer) {.gcsafe.} =
      var ovl = cast[PtrCustomOverlapped](udata)
      var server = cast[StreamServer](ovl.data.udata)

      server.apending = false
      if not(retFuture.finished()):
        if server.status in {ServerStatus.Stopped, ServerStatus.Closed}:
          retFuture.fail(getServerUseClosedError())
          server.sock.closeHandle()
          server.clean()
        else:
          if ovl.data.errCode == OSErrorCode(-1):
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
            try:
              server.createAcceptPipe()
            except CatchableError as exc:
              closeHandle(server.sock)
              retFuture.fail(exc)
              return
            trackStream(ntransp)
            retFuture.complete(ntransp)

          elif int32(ovl.data.errCode) in {ERROR_OPERATION_ABORTED,
                                           ERROR_PIPE_NOT_CONNECTED}:
            # CancelIO() interrupt or close call.
            retFuture.fail(getServerUseClosedError())
            server.clean()
          else:
            let sock = server.sock
            try:
              server.createAcceptPipe()
            except CatchableError as exc:
              closeHandle(sock)
              retFuture.fail(exc)
              return
            closeHandle(sock)

            retFuture.fail(getTransportOsError(ovl.data.errCode))

    proc cancellationPipe(udata: pointer) {.gcsafe.} =
      if server.apending:
        server.apending = false
      server.sock.closeHandle()

    if server.local.family in {AddressFamily.IPv4, AddressFamily.IPv6}:
      # TCP Sockets part
      var loop = getThreadDispatcher()
      server.asock =
        try:
          createAsyncSocket(server.domain, SockType.SOCK_STREAM,
                            Protocol.IPPROTO_TCP)
        except CatchableError as exc:
          retFuture.fail(exc)
          return retFuture

      if server.asock == asyncInvalidSocket:
        let err = osLastError()
        case int(err)
        of ERROR_TOO_MANY_OPEN_FILES, WSAENOBUFS, WSAEMFILE:
          retFuture.fail(getTransportTooManyError(int(err)))
        else:
          retFuture.fail(getTransportOsError(err))
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
      if not(res):
        let err = osLastError()
        case int(err)
        of ERROR_OPERATION_ABORTED:
          server.apending = false
          retFuture.fail(getServerUseClosedError())
          return retFuture
        of ERROR_IO_PENDING:
          discard
        of common.WSAECONNRESET, common.WSAECONNABORTED, common.WSAENETDOWN,
           common.WSAENETRESET, common.WSAETIMEDOUT:
          server.apending = false
          retFuture.fail(getConnectionAbortedError(int(err)))
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
        if int32(err) == ERROR_TOO_MANY_OPEN_FILES:
          retFuture.fail(getTransportTooManyError())
        else:
          retFuture.fail(getTransportOsError(err))
        return retFuture

      server.aovl.data = CompletionData(cb: continuationPipe,
                                        udata: cast[pointer](server))
      server.apending = true
      let res = connectNamedPipe(Handle(server.sock),
                                 cast[POVERLAPPED](addr server.aovl))
      if res == 0:
        let err = osLastError()
        if int32(err) == ERROR_OPERATION_ABORTED:
          server.apending = false
          retFuture.fail(getServerUseClosedError())
          return retFuture
        elif int32(err) in {ERROR_IO_PENDING, ERROR_PIPE_CONNECTED}:
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
    result = (err == OSErrorCode(ECONNRESET)) or
             (err == OSErrorCode(EPIPE))

  proc removeWriter(transp: StreamTransport) =
    try:
      transp.fd.removeWriter()
      # For debugging, record that we're no longer getting write notifications
      transp.state.incl WritePaused
    except IOSelectorsException as exc:
      raiseAsDefect exc, "removeWriter"
    except ValueError as exc:
      raiseAsDefect exc, "removeWriter"

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
        transp.removeWriter()

        let error = getTransportUseClosedError()
        failPendingWriteQueue(transp.queue, error)
      return

    # We exit this loop in two ways:
    # * The queue is empty: we call removeWriter to disable further callbacks
    # * EWOULDBLOCK is returned and we need to wait for a new notification

    while len(transp.queue) > 0:
      template handleError() =
        let err = osLastError()

        if cint(err) == EINTR:
          # Signal happened while writing - try again with all data
          transp.queue.addFirst(vector)
          continue

        if cint(err) in [EWOULDBLOCK, EAGAIN]:
          # Socket buffer is full - wait until next write notification - in
          # particular, ensure removeWriter is not called
          transp.queue.addFirst(vector)
          return

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
            posix.send(fd, vector.buf, vector.buflen, MSG_NOSIGNAL)
          of TransportKind.Pipe:
            posix.write(cint(fd), vector.buf, vector.buflen)
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
    transp.removeWriter()

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
          var res = posix.recv(fd, addr transp.buffer[transp.offset],
                               len(transp.buffer) - transp.offset, cint(0))
          if res < 0:
            let err = osLastError()
            if int(err) == EINTR:
              continue
            elif int(err) in {ECONNRESET}:
              transp.state.incl({ReadEof, ReadPaused})
              try:
                transp.fd.removeReader()
              except IOSelectorsException as exc:
                raiseAsDefect exc, "removeReader"
              except ValueError as exc:
                raiseAsDefect exc, "removeReader"
            else:
              transp.state.incl(ReadPaused)
              transp.setReadError(err)
              try:
                transp.fd.removeReader()
              except IOSelectorsException as exc:
                raiseAsDefect exc, "removeReader"
              except ValueError as exc:
                raiseAsDefect exc, "removeReader"
          elif res == 0:
            transp.state.incl({ReadEof, ReadPaused})
            try:
              transp.fd.removeReader()
            except IOSelectorsException as exc:
              raiseAsDefect exc, "removeReader"
            except ValueError as exc:
              raiseAsDefect exc, "removeReader"
          else:
            transp.offset += res
            if transp.offset == len(transp.buffer):
              transp.state.incl(ReadPaused)
              try:
                transp.fd.removeReader()
              except IOSelectorsException as exc:
                raiseAsDefect exc, "removeReader"
              except ValueError as exc:
                raiseAsDefect exc, "removeReader"
          transp.completeReader()
          break
      elif transp.kind == TransportKind.Pipe:
        while true:
          var res = posix.read(cint(fd), addr transp.buffer[transp.offset],
                               len(transp.buffer) - transp.offset)
          if res < 0:
            let err = osLastError()
            if int(err) == EINTR:
              continue
            else:
              transp.state.incl(ReadPaused)
              transp.setReadError(err)
              try:
                transp.fd.removeReader()
              except IOSelectorsException as exc:
                raiseAsDefect exc, "removeReader"
              except ValueError as exc:
                raiseAsDefect exc, "removeReader"
          elif res == 0:
            transp.state.incl({ReadEof, ReadPaused})
            try:
              transp.fd.removeReader()
            except IOSelectorsException as exc:
              raiseAsDefect exc, "removeReader"
            except ValueError as exc:
              raiseAsDefect exc, "removeReader"
          else:
            transp.offset += res
            if transp.offset == len(transp.buffer):
              transp.state.incl(ReadPaused)
              try:
                transp.fd.removeReader()
              except IOSelectorsException as exc:
                raiseAsDefect exc, "removeReader"
              except ValueError as exc:
                raiseAsDefect exc, "removeReader"
          transp.completeReader()
          break

  proc newStreamSocketTransport(sock: AsyncFD, bufsize: int,
                                child: StreamTransport): StreamTransport =
    var transp: StreamTransport
    if not(isNil(child)):
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

  proc newStreamPipeTransport(fd: AsyncFD, bufsize: int,
                              child: StreamTransport): StreamTransport =
    var transp: StreamTransport
    if not(isNil(child)):
      transp = child
    else:
      transp = StreamTransport(kind: TransportKind.Pipe)

    transp.fd = fd
    transp.buffer = newSeq[byte](bufsize)
    transp.state = {ReadPaused, WritePaused}
    transp.queue = initDeque[StreamVector]()
    transp.future = newFuture[void]("pipe.stream.transport")
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
      proto: Protocol
    var retFuture = newFuture[StreamTransport]("stream.transport.connect")
    address.toSAddr(saddr, slen)
    proto = Protocol.IPPROTO_TCP
    if address.family == AddressFamily.Unix:
      # `Protocol` enum is missing `0` value, so we making here cast, until
      # `Protocol` enum will not support IPPROTO_IP == 0.
      proto = cast[Protocol](0)

    let sock = try: createAsyncSocket(address.getDomain(), SockType.SOCK_STREAM,
                              proto)
    except CatchableError as exc:
      retFuture.fail(exc)
      return retFuture

    if sock == asyncInvalidSocket:
      let err = osLastError()
      if int(err) == EMFILE:
        retFuture.fail(getTransportTooManyError())
      else:
        retFuture.fail(getTransportOsError(err))
      return retFuture

    proc continuation(udata: pointer) =
      if not(retFuture.finished()):
        var err = 0
        try:
          sock.removeWriter()
        except IOSelectorsException as exc:
          retFuture.fail(exc)
          return
        except ValueError as exc:
          retFuture.fail(exc)
          return

        if not(sock.getSocketError(err)):
          closeSocket(sock)
          retFuture.fail(getTransportOsError(osLastError()))
          return
        if err != 0:
          closeSocket(sock)
          retFuture.fail(getTransportOsError(OSErrorCode(err)))
          return
        let transp = newStreamSocketTransport(sock, bufferSize, child)
        # Start tracking transport
        trackStream(transp)
        retFuture.complete(transp)

    proc cancel(udata: pointer) =
      closeSocket(sock)

    while true:
      var res = posix.connect(SocketHandle(sock),
                              cast[ptr SockAddr](addr saddr), slen)
      if res == 0:
        let transp = newStreamSocketTransport(sock, bufferSize, child)
        # Start tracking transport
        trackStream(transp)
        retFuture.complete(transp)
        break
      else:
        let err = osLastError()
        # If connect() is interrupted by a signal that is caught while blocked
        # waiting to establish a connection, connect() shall fail and set
        # connect() to [EINTR], but the connection request shall not be aborted,
        # and the connection shall be established asynchronously.
        #
        # http://www.madore.org/~david/computers/connect-intr.html
        if int(err) == EINPROGRESS or int(err) == EINTR:
          try:
            sock.addWriter(continuation)
          except CatchableError as exc:
            closeSocket(sock)
            retFuture.fail(exc)
            return retFuture

          retFuture.cancelCallback = cancel
          break
        else:
          sock.closeSocket()

          retFuture.fail(getTransportOsError(err))
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
    while true:
      if server.status in {ServerStatus.Stopped, ServerStatus.Closed}:
        break

      let res = posix.accept(SocketHandle(server.sock),
                             cast[ptr SockAddr](addr saddr), addr slen)
      if int(res) > 0:
        let sock = try: wrapAsyncSocket(res)
        except CatchableError as exc:
          raiseAsDefect exc, "wrapAsyncSocket"
        if sock != asyncInvalidSocket:
          var ntransp: StreamTransport
          if not(isNil(server.init)):
            let transp = server.init(server, sock)
            ntransp = newStreamSocketTransport(sock, server.bufferSize, transp)
          else:
            ntransp = newStreamSocketTransport(sock, server.bufferSize, nil)
          # Start tracking transport
          trackStream(ntransp)
          asyncCheck server.function(server, ntransp)
        break
      else:
        let err = osLastError()
        if int(err) == EINTR:
          continue
        elif int(err) == EAGAIN:
          # This error appears only when server get closed, while acceptLoop()
          # reader callback is already scheduled.
          break
        else:
          ## Critical unrecoverable error
          raiseAssert $err

  proc resumeAccept(server: StreamServer) {.
      raises: [Defect, IOSelectorsException, ValueError].} =
    addReader(server.sock, acceptLoop, cast[pointer](server))

  proc pauseAccept(server: StreamServer) {.
      raises: [Defect, IOSelectorsException, ValueError].} =
    removeReader(server.sock)

  proc resumeRead(transp: StreamTransport) {.inline.} =
    if ReadPaused in transp.state:
      transp.state.excl(ReadPaused)
      # TODO reset flag on exception??
      try:
        addReader(transp.fd, readStreamLoop, cast[pointer](transp))
      except IOSelectorsException as exc:
        raiseAsDefect exc, "addReader"
      except ValueError as exc:
        raiseAsDefect exc, "addReader"

  proc resumeWrite(transp: StreamTransport) {.inline.} =
    if transp.queue.len() == 1:
      # writeStreamLoop keeps writing until queue is empty - we should not call
      # resumeWrite under any other condition than when the items are
      # added to a queue - if the flag is not set here, it means that the socket
      # was not removed from write notifications at the right time, and this
      # would mean an imbalance in registration and deregistration
      doAssert WritePaused in transp.state
      try:
        addWriter(transp.fd, writeStreamLoop, cast[pointer](transp))

        transp.state.excl WritePaused
      except IOSelectorsException as exc:
        raiseAsDefect exc, "addWriter"
      except ValueError as exc:
        raiseAsDefect exc, "addWriter"

  proc accept*(server: StreamServer): Future[StreamTransport] =
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
          while true:
            let res = posix.accept(SocketHandle(server.sock),
                                   cast[ptr SockAddr](addr saddr), addr slen)
            if int(res) > 0:
              let sock =
                try:
                  wrapAsyncSocket(res)
                except CatchableError as exc:
                  close(res)
                  retFuture.fail(getConnectionAbortedError($exc.msg))
                  return

              if sock != asyncInvalidSocket:
                var ntransp: StreamTransport
                if not(isNil(server.init)):
                  let transp = server.init(server, sock)
                  ntransp = newStreamSocketTransport(sock, server.bufferSize,
                                                     transp)
                else:
                  ntransp = newStreamSocketTransport(sock, server.bufferSize,
                                                     nil)
                # Start tracking transport
                trackStream(ntransp)
                retFuture.complete(ntransp)
              else:
                let errorMsg = osErrorMsg(osLastError())
                retFuture.fail(getConnectionAbortedError(errorMsg))
            else:
              let err = int(osLastError())
              if err == EINTR:
                continue
              elif err == EAGAIN:
                # This error appears only when server get closed, while accept()
                # continuation is already scheduled.
                retFuture.fail(getServerUseClosedError())
              elif err in {EMFILE, ENFILE, ENOBUFS, ENOMEM}:
                retFuture.fail(getTransportTooManyError(err))
              elif err in {ECONNABORTED, EPERM, ETIMEDOUT}:
                retFuture.fail(getConnectionAbortedError(err))
              else:
                retFuture.fail(getTransportOsError(OSErrorCode(err)))
            break

        try:
          removeReader(server.sock)
        except IOSelectorsException as exc:
          raiseAsDefect exc, "removeReader"
        except ValueError as exc:
          raiseAsDefect exc, "removeReader"

    proc cancellation(udata: pointer) =
      try:
        removeReader(server.sock)
      except IOSelectorsException as exc:
        raiseAsDefect exc, "removeReader"
      except ValueError as exc:
        raiseAsDefect exc, "removeReader"

    try:
      addReader(server.sock, continuation, nil)
    except IOSelectorsException as exc:
      raiseAsDefect exc, "addReader"
    except ValueError as exc:
      raiseAsDefect exc, "addReader"

    retFuture.cancelCallback = cancellation
    return retFuture

proc start*(server: StreamServer) {.
    raises: [Defect, IOSelectorsException, ValueError].} =
  ## Starts ``server``.
  doAssert(not(isNil(server.function)),
        "You should not start server, if you have not set processing callback!")
  if server.status == ServerStatus.Starting:
    server.resumeAccept()
    server.status = ServerStatus.Running

proc stop*(server: StreamServer) {.
    raises: [Defect, IOSelectorsException, ValueError].} =
  ## Stops ``server``.
  if server.status == ServerStatus.Running:
    if not(isNil(server.function)):
      server.pauseAccept()
    server.status = ServerStatus.Stopped
  elif server.status == ServerStatus.Starting:
    server.status = ServerStatus.Stopped

proc join*(server: StreamServer): Future[void] =
  ## Waits until ``server`` is not closed.
  var retFuture = newFuture[void]("stream.transport.server.join")

  proc continuation(udata: pointer) =
    retFuture.complete()

  proc cancel(udata: pointer) =
    server.loopFuture.removeCallback(continuation, cast[pointer](retFuture))

  if not(server.loopFuture.finished()):
    server.loopFuture.addCallback(continuation, cast[pointer](retFuture))
    retFuture.cancelCallback = cancel
  else:
    retFuture.complete()
  return retFuture

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
          discard flushFileBuffers(Handle(server.sock))
        discard disconnectNamedPipe(Handle(server.sock))
        server.sock.closeHandle(continuation)
    else:
      server.sock.closeSocket(continuation)

proc closeWait*(server: StreamServer): Future[void] =
  ## Close server ``server`` and release all resources.
  server.close()
  result = server.join()

proc createStreamServer*(host: TransportAddress,
                         cbproc: StreamCallback,
                         flags: set[ServerFlags] = {},
                         sock: AsyncFD = asyncInvalidSocket,
                         backlog: int = 100,
                         bufferSize: int = DefaultStreamBufferSize,
                         child: StreamServer = nil,
                         init: TransportInitCallback = nil,
                         udata: pointer = nil): StreamServer {.
    raises: [Defect, CatchableError].} =
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
    localAddress: TransportAddress

  when defined(nimdoc):
    discard
  elif defined(windows):
    # Windows
    if host.family in {AddressFamily.IPv4, AddressFamily.IPv6}:
      if sock == asyncInvalidSocket:
        serverSocket = createAsyncSocket(host.getDomain(),
                                         SockType.SOCK_STREAM,
                                         Protocol.IPPROTO_TCP)

        if serverSocket == asyncInvalidSocket:
          raiseTransportOsError(osLastError())
      else:
        if not(setSocketBlocking(SocketHandle(sock), false)):
          raiseTransportOsError(osLastError())
        register(sock)
        serverSocket = sock
      # SO_REUSEADDR is not useful for Unix domain sockets.
      if ServerFlags.ReuseAddr in flags:
        if not(setSockOpt(serverSocket, SOL_SOCKET, SO_REUSEADDR, 1)):
          let err = osLastError()
          if sock == asyncInvalidSocket:
            serverSocket.closeSocket()
          raiseTransportOsError(err)
      # TCP flags are not useful for Unix domain sockets.
      if ServerFlags.TcpNoDelay in flags:
        if not(setSockOpt(serverSocket, handles.IPPROTO_TCP,
                          handles.TCP_NODELAY, 1)):
          let err = osLastError()
          if sock == asyncInvalidSocket:
            serverSocket.closeSocket()
          raiseTransportOsError(err)
      host.toSAddr(saddr, slen)
      if bindAddr(SocketHandle(serverSocket), cast[ptr SockAddr](addr saddr),
                  slen) != 0:
        let err = osLastError()
        if sock == asyncInvalidSocket:
          serverSocket.closeSocket()
        raiseTransportOsError(err)

      slen = SockLen(sizeof(saddr))
      if getsockname(SocketHandle(serverSocket), cast[ptr SockAddr](addr saddr),
                     addr slen) != 0:
        let err = osLastError()
        if sock == asyncInvalidSocket:
          serverSocket.closeSocket()
        raiseTransportOsError(err)
      fromSAddr(addr saddr, slen, localAddress)

      if nativesockets.listen(SocketHandle(serverSocket), cint(backlog)) != 0:
        let err = osLastError()
        if sock == asyncInvalidSocket:
          serverSocket.closeSocket()
          raiseTransportOsError(err)
    elif host.family == AddressFamily.Unix:
      serverSocket = AsyncFD(0)
  else:
    # Posix
    if sock == asyncInvalidSocket:
      var proto = Protocol.IPPROTO_TCP
      if host.family == AddressFamily.Unix:
        # `Protocol` enum is missing `0` value, so we making here cast, until
        # `Protocol` enum will not support IPPROTO_IP == 0.
        proto = cast[Protocol](0)
      serverSocket = createAsyncSocket(host.getDomain(),
                                       SockType.SOCK_STREAM,
                                       proto)
      if serverSocket == asyncInvalidSocket:
        raiseTransportOsError(osLastError())
    else:
      if not(setSocketBlocking(SocketHandle(sock), false)):
        raiseTransportOsError(osLastError())
      register(sock)

      serverSocket = sock

    if host.family in {AddressFamily.IPv4, AddressFamily.IPv6}:
      # SO_REUSEADDR and SO_REUSEPORT are not useful for Unix domain sockets.
      if ServerFlags.ReuseAddr in flags:
        if not(setSockOpt(serverSocket, SOL_SOCKET, SO_REUSEADDR, 1)):
          let err = osLastError()
          if sock == asyncInvalidSocket:
            serverSocket.closeSocket()
          raiseTransportOsError(err)
      if ServerFlags.ReusePort in flags:
        if not(setSockOpt(serverSocket, SOL_SOCKET, SO_REUSEPORT, 1)):
          let err = osLastError()
          if sock == asyncInvalidSocket:
            serverSocket.closeSocket()
          raiseTransportOsError(err)
      # TCP flags are not useful for Unix domain sockets.
      if ServerFlags.TcpNoDelay in flags:
        if not(setSockOpt(serverSocket, handles.IPPROTO_TCP,
                          handles.TCP_NODELAY, 1)):
          let err = osLastError()
          if sock == asyncInvalidSocket:
            serverSocket.closeSocket()
          raiseTransportOsError(err)
    elif host.family in {AddressFamily.Unix}:
      # We do not care about result here, because if file cannot be removed,
      # `bindAddr` will return EADDRINUSE.
      discard posix.unlink(cast[cstring](unsafeAddr host.address_un[0]))

    host.toSAddr(saddr, slen)
    if bindAddr(SocketHandle(serverSocket), cast[ptr SockAddr](addr saddr),
                slen) != 0:
      let err = osLastError()
      if sock == asyncInvalidSocket:
        serverSocket.closeSocket()
      raiseTransportOsError(err)

    # Obtain real address
    slen = SockLen(sizeof(saddr))
    if getsockname(SocketHandle(serverSocket), cast[ptr SockAddr](addr saddr),
                   addr slen) != 0:
      let err = osLastError()
      if sock == asyncInvalidSocket:
        serverSocket.closeSocket()
      raiseTransportOsError(err)
    fromSAddr(addr saddr, slen, localAddress)

    if nativesockets.listen(SocketHandle(serverSocket), cint(backlog)) != 0:
      let err = osLastError()
      if sock == asyncInvalidSocket:
        serverSocket.closeSocket()
      raiseTransportOsError(err)

  if not(isNil(child)):
    result = child
  else:
    result = StreamServer()

  result.sock = serverSocket
  result.flags = flags
  result.function = cbproc
  result.init = init
  result.bufferSize = bufferSize
  result.status = Starting
  result.loopFuture = newFuture[void]("stream.transport.server")
  result.udata = udata
  if localAddress.family == AddressFamily.None:
    result.local = host
  else:
    result.local = localAddress

  when defined(windows):
    var cb: CallbackFunc
    if host.family in {AddressFamily.IPv4, AddressFamily.IPv6}:
      cb = acceptLoop
    elif host.family == AddressFamily.Unix:
      cb = acceptPipeLoop

    if not(isNil(cbproc)):
      result.aovl.data = CompletionData(cb: cb,
                                        udata: cast[pointer](result))
    else:
      if host.family == AddressFamily.Unix:
        result.createAcceptPipe()

    result.domain = host.getDomain()
    result.apending = false

  # Start tracking server
  trackServer(result)
  GC_ref(result)

proc createStreamServer*(host: TransportAddress,
                         flags: set[ServerFlags] = {},
                         sock: AsyncFD = asyncInvalidSocket,
                         backlog: int = 100,
                         bufferSize: int = DefaultStreamBufferSize,
                         child: StreamServer = nil,
                         init: TransportInitCallback = nil,
                         udata: pointer = nil): StreamServer {.
    raises: [Defect, CatchableError].} =
  result = createStreamServer(host, nil, flags, sock, backlog, bufferSize,
                              child, init, cast[pointer](udata))

proc createStreamServer*[T](host: TransportAddress,
                            cbproc: StreamCallback,
                            flags: set[ServerFlags] = {},
                            udata: ref T,
                            sock: AsyncFD = asyncInvalidSocket,
                            backlog: int = 100,
                            bufferSize: int = DefaultStreamBufferSize,
                            child: StreamServer = nil,
                            init: TransportInitCallback = nil): StreamServer {.
    raises: [Defect, CatchableError].} =
  var fflags = flags + {GCUserData}
  GC_ref(udata)
  result = createStreamServer(host, cbproc, fflags, sock, backlog, bufferSize,
                              child, init, cast[pointer](udata))

proc createStreamServer*[T](host: TransportAddress,
                            flags: set[ServerFlags] = {},
                            udata: ref T,
                            sock: AsyncFD = asyncInvalidSocket,
                            backlog: int = 100,
                            bufferSize: int = DefaultStreamBufferSize,
                            child: StreamServer = nil,
                            init: TransportInitCallback = nil): StreamServer {.
    raises: [Defect, CatchableError].} =
  var fflags = flags + {GCUserData}
  GC_ref(udata)
  result = createStreamServer(host, nil, fflags, sock, backlog, bufferSize,
                              child, init, cast[pointer](udata))

proc getUserData*[T](server: StreamServer): T {.inline.} =
  ## Obtain user data stored in ``server`` object.
  result = cast[T](server.udata)

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
            posix.send(SocketHandle(transp.fd), pbytes, rbytes,
                       MSG_NOSIGNAL)
          of TransportKind.Pipe:
            posix.write(cint(transp.fd), pbytes, rbytes)
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
          if cint(err) in [EAGAIN, EWOULDBLOCK]:
            break # No bytes written, add to queue

          if cint(err) == EINTR:
            continue

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
            nbytes: int): Future[int] =
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
  transp.resumeWrite()
  return retFuture

proc write*(transp: StreamTransport, msg: string, msglen = -1): Future[int] =
  ## Write data from string ``msg`` using transport ``transp``.
  var retFuture = newFutureStr[int]("stream.transport.write(string)")
  transp.checkClosed(retFuture)
  transp.checkWriteEof(retFuture)

  let
    nbytes = if msglen <= 0: len(msg) else: msglen

  var
    pbytes = cast[ptr byte](unsafeAddr msg[0])
    rbytes = nbytes

  fastWrite(transp, pbytes, rbytes, nbytes)

  let
    written = nbytes - rbytes # In case fastWrite wrote some

  pbytes = if not(isLiteral(msg)):
    shallowCopy(retFuture.gcholder, msg)
    cast[ptr byte](addr retFuture.gcholder[written])
  else:
    retFuture.gcholder = msg[written..<nbytes]
    cast[ptr byte](addr retFuture.gcholder[0])

  var vector = StreamVector(kind: DataBuffer, writer: retFuture,
                            buf: pbytes, buflen: rbytes, size: nbytes)
  transp.queue.addLast(vector)
  transp.resumeWrite()
  return retFuture

proc write*[T](transp: StreamTransport, msg: seq[T], msglen = -1): Future[int] =
  ## Write sequence ``msg`` using transport ``transp``.
  var retFuture = newFutureSeq[int, T]("stream.transport.write(seq)")
  transp.checkClosed(retFuture)
  transp.checkWriteEof(retFuture)

  let
    nbytes = if msglen <= 0: (len(msg) * sizeof(T)) else: (msglen * sizeof(T))

  var
    pbytes = cast[ptr byte](unsafeAddr msg[0])
    rbytes = nbytes

  fastWrite(transp, pbytes, rbytes, nbytes)

  let
    written = nbytes - rbytes # In case fastWrite wrote some

  pbytes = if not(isLiteral(msg)):
    shallowCopy(retFuture.gcholder, msg)
    cast[ptr byte](addr retFuture.gcholder[written])
  else:
    retFuture.gcholder = msg[written..<nbytes]
    cast[ptr byte](addr retFuture.gcholder[0])

  var vector = StreamVector(kind: DataBuffer, writer: retFuture,
                            buf: pbytes, buflen: rbytes, size: nbytes)
  transp.queue.addLast(vector)
  transp.resumeWrite()
  return retFuture

proc writeFile*(transp: StreamTransport, handle: int,
                offset: uint = 0, size: int = 0): Future[int] =
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
  transp.resumeWrite()
  return retFuture

proc atEof*(transp: StreamTransport): bool {.inline.} =
  ## Returns ``true`` if ``transp`` is at EOF.
  result = (transp.offset == 0) and (ReadEof in transp.state) and
           (ReadPaused in transp.state)

template prepareReader(transp: StreamTransport,
                       name: static string): Future[void] =
  checkPending(transp)
  var fut = newFuture[void](name)
  transp.reader = fut
  resumeRead(transp)
  fut

template readLoop(name, body: untyped): untyped =
  # Read data until a predicate is satisfied - the body should return a tuple
  # signalling how many bytes have been processed and whether we're done reading
  checkClosed(transp)
  checkPending(transp)
  while true:
    if ReadClosed in transp.state:
      raise newException(TransportUseClosedError,
                         "Attempt to read data from closed stream")
    if transp.offset == 0:
      # We going to raise an error, only if transport buffer is empty.
      if ReadError in transp.state:
        raise transp.getError()

    let (consumed, done) = body
    transp.shiftBuffer(consumed)
    if done:
      break
    else:
      await transp.prepareReader(name)

proc readExactly*(transp: StreamTransport, pbytes: pointer,
                  nbytes: int) {.async.} =
  ## Read exactly ``nbytes`` bytes from transport ``transp`` and store it to
  ## ``pbytes``. ``pbytes`` must not be ``nil`` pointer and ``nbytes`` should
  ## be Natural.
  ##
  ## If ``nbytes == 0`` this operation will return immediately.
  ##
  ## If EOF is received and ``nbytes`` is not yet readed, the procedure
  ## will raise ``TransportIncompleteError``, potentially with some bytes
  ## already written.
  doAssert(not(isNil(pbytes)), "pbytes must not be nil")
  doAssert(nbytes >= 0, "nbytes must be non-negative integer")

  if nbytes == 0:
    return

  var index = 0
  var pbuffer = cast[ptr UncheckedArray[byte]](pbytes)
  readLoop("stream.transport.readExactly"):
    if transp.offset == 0:
      if transp.atEof():
        raise newException(TransportIncompleteError, "Data incomplete!")
    let count = min(nbytes - index, transp.offset)
    if count > 0:
      copyMem(addr pbuffer[index], addr(transp.buffer[0]), count)
      index += count
    (consumed: count, done: index == nbytes)

proc readOnce*(transp: StreamTransport, pbytes: pointer,
               nbytes: int): Future[int] {.async.} =
  ## Perform one read operation on transport ``transp``.
  ##
  ## If internal buffer is not empty, ``nbytes`` bytes will be transferred from
  ## internal buffer, otherwise it will wait until some bytes will be received.
  doAssert(not(isNil(pbytes)), "pbytes must not be nil")
  doAssert(nbytes > 0, "nbytes must be positive integer")

  var count = 0
  readLoop("stream.transport.readOnce"):
    if transp.offset == 0:
      (0, transp.atEof())
    else:
      count = min(transp.offset, nbytes)
      copyMem(pbytes, addr(transp.buffer[0]), count)
      (count, true)
  return count

proc readUntil*(transp: StreamTransport, pbytes: pointer, nbytes: int,
                sep: seq[byte]): Future[int] {.async.} =
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

  var pbuffer = cast[ptr UncheckedArray[byte]](pbytes)
  var state = 0
  var k = 0

  readLoop("stream.transport.readUntil"):
    if transp.atEof():
      raise newException(TransportIncompleteError, "Data incomplete!")

    var index = 0

    while index < transp.offset:
      if k >= nbytes:
        raise newException(TransportLimitError, "Limit reached!")

      let ch = transp.buffer[index]
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

  return k

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
  let lim = if limit <= 0: -1 else: limit
  var state = 0

  readLoop("stream.transport.readLine"):
    if transp.atEof():
      (0, true)
    else:
      var index = 0
      while index < transp.offset:
        let ch = char(transp.buffer[index])
        index += 1

        if sep[state] == ch:
          inc(state)
          if state == len(sep):
            break
        else:
          if state != 0:
            if limit > 0:
              let missing = min(state, lim - len(result) - 1)
              result.add(sep[0 ..< missing])
            else:
              result.add(sep[0 ..< state])
            state = 0

          result.add(ch)
          if len(result) == lim:
            break

      (index, (state == len(sep)) or (lim == len(result)))

proc read*(transp: StreamTransport): Future[seq[byte]] {.async.} =
  ## Read all bytes from transport ``transp``.
  ##
  ## This procedure allocates buffer seq[byte] and return it as result.
  readLoop("stream.transport.read"):
    if transp.atEof():
      (0, true)
    else:
      result.add(transp.buffer.toOpenArray(0, transp.offset - 1))
      (transp.offset, false)

proc read*(transp: StreamTransport, n: int): Future[seq[byte]] {.async.} =
  ## Read all bytes (n <= 0) or exactly `n` bytes from transport ``transp``.
  ##
  ## This procedure allocates buffer seq[byte] and return it as result.
  if n <= 0:
    return await transp.read()
  else:
    readLoop("stream.transport.read"):
      if transp.atEof():
        (0, true)
      else:
        let count = min(transp.offset, n - len(result))
        result.add(transp.buffer.toOpenArray(0, count - 1))
        (count, len(result) == n)

proc consume*(transp: StreamTransport): Future[int] {.async.} =
  ## Consume all bytes from transport ``transp`` and discard it.
  ##
  ## Return number of bytes actually consumed and discarded.
  readLoop("stream.transport.consume"):
    if transp.atEof():
      (0, true)
    else:
      result += transp.offset
      (transp.offset, false)

proc consume*(transp: StreamTransport, n: int): Future[int] {.async.} =
  ## Consume all bytes (n <= 0) or ``n`` bytes from transport ``transp`` and
  ## discard it.
  ##
  ## Return number of bytes actually consumed and discarded.
  if n <= 0:
    return await transp.consume()
  else:
    readLoop("stream.transport.consume"):
      if transp.atEof():
        (0, true)
      else:
        let count = min(transp.offset, n - result)
        result += count
        (count, result == n)

proc readMessage*(transp: StreamTransport,
                  predicate: ReadMessagePredicate) {.async.} =
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
    if transp.offset == 0:
      if transp.atEof():
        predicate([])
      else:
        # Case, when transport's buffer is not yet filled with data.
        (0, false)
    else:
      predicate(transp.buffer.toOpenArray(0, transp.offset - 1))

proc join*(transp: StreamTransport): Future[void] =
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
  return retFuture

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
            discard flushFileBuffers(Handle(transp.fd))
          discard disconnectNamedPipe(Handle(transp.fd))
        else:
          if WinNoPipeFlash notin transp.flags:
            discard flushFileBuffers(Handle(transp.fd))
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

proc closeWait*(transp: StreamTransport): Future[void] =
  ## Close and frees resources of transport ``transp``.
  transp.close()
  result = transp.join()

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

proc fromPipe*(fd: AsyncFD, child: StreamTransport = nil,
               bufferSize = DefaultStreamBufferSize): StreamTransport {.
    raises: [Defect, CatchableError].} =
  ## Create new transport object using pipe's file descriptor.
  ##
  ## ``bufferSize`` is size of internal buffer for transport.
  register(fd)

  result = newStreamPipeTransport(fd, bufferSize, child)
  # Start tracking transport
  trackStream(result)

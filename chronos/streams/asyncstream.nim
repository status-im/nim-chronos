#
#            Chronos Asynchronous Streams
#             (c) Copyright 2019-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

{.push raises: [], gcsafe.}

import ../[config, asyncloop, asyncsync, bipbuffer]
import ../transports/[common, stream]
export asyncloop, asyncsync, stream, common

const
  AsyncStreamDefaultBufferSize* = chronosStreamDefaultBufferSize
    ## Default reading stream internal buffer size.
  AsyncStreamDefaultQueueSize* = 0
    ## Default writing stream internal queue size.
  AsyncStreamReaderTrackerName* = "async.stream.reader"
    ## AsyncStreamReader leaks tracker name
  AsyncStreamWriterTrackerName* = "async.stream.writer"
    ## AsyncStreamWriter leaks tracker name

type
  AsyncStreamReaderVtbl* = object
    atEof*: proc(rstream: AsyncStreamReader): bool {.gcsafe, raises: [].}
    stopped*: proc(rstream: AsyncStreamReader): bool {.gcsafe, raises: [].}
    running*: proc(rstream: AsyncStreamReader): bool {.gcsafe, raises: [].}
    failed*: proc(rstream: AsyncStreamReader): bool {.gcsafe, raises: [].}
    readExactly*: proc(rstream: AsyncStreamReader, pbytes: pointer, nbytes: int) {.
      async: (raises: [CancelledError, AsyncStreamError])
    .}
    readOnce*: proc(
      rstream: AsyncStreamReader, pbytes: pointer, nbytes: int
    ): Future[int] {.async: (raises: [CancelledError, AsyncStreamError]).}
    readUntil*: proc(
      rstream: AsyncStreamReader, pbytes: pointer, nbytes: int, sep: seq[byte]
    ): Future[int] {.async: (raises: [CancelledError, AsyncStreamError]).}
    readLine*: proc(rstream: AsyncStreamReader, limit = 0, sep = "\r\n"): Future[string] {.
      async: (raises: [CancelledError, AsyncStreamError])
    .}
    read*: proc(rstream: AsyncStreamReader): Future[seq[byte]] {.
      async: (raises: [CancelledError, AsyncStreamError])
    .}
    readN*: proc(rstream: AsyncStreamReader, n: int): Future[seq[byte]] {.
      async: (raises: [CancelledError, AsyncStreamError])
    .}
    consume*: proc(rstream: AsyncStreamReader): Future[int] {.
      async: (raises: [CancelledError, AsyncStreamError])
    .}
    consumeN*: proc(rstream: AsyncStreamReader, n: int): Future[int] {.
      async: (raises: [CancelledError, AsyncStreamError])
    .}
    readMessage*: proc(rstream: AsyncStreamReader, pred: ReadMessagePredicate) {.
      async: (raises: [CancelledError, AsyncStreamError])
    .}

  AsyncStreamWriterVtbl* = object
    atEof*: proc(wstream: AsyncStreamWriter): bool {.gcsafe, raises: [].}
    stopped*: proc(wstream: AsyncStreamWriter): bool {.gcsafe, raises: [].}
    running*: proc(wstream: AsyncStreamWriter): bool {.gcsafe, raises: [].}
    failed*: proc(wstream: AsyncStreamWriter): bool {.gcsafe, raises: [].}
    writePointer*: proc(wstream: AsyncStreamWriter, pbytes: pointer, nbytes: int) {.
      async: (raises: [CancelledError, AsyncStreamError])
    .}
    writeSeq*: proc(wstream: AsyncStreamWriter, sbytes: seq[byte], msglen: int) {.
      async: (raises: [CancelledError, AsyncStreamError])
    .}
    writeStr*: proc(wstream: AsyncStreamWriter, sbytes: string, msglen: int) {.
      async: (raises: [CancelledError, AsyncStreamError])
    .}
    finish*: proc(wstream: AsyncStreamWriter) {.
      async: (raises: [CancelledError, AsyncStreamError])
    .}

  AsyncStreamError* = object of AsyncError
  AsyncStreamIncorrectDefect* = object of Defect
  AsyncStreamIncompleteError* = object of AsyncStreamError
  AsyncStreamLimitError* = object of AsyncStreamError
  AsyncStreamUseClosedError* = object of AsyncStreamError
  AsyncStreamReadError* = object of AsyncStreamError
  AsyncStreamWriteError* = object of AsyncStreamError
  AsyncStreamWriteEOFError* = object of AsyncStreamWriteError

  AsyncBuffer* = object
    backend*: BipBuffer
    events*: array[2, AsyncEvent]

  AsyncBufferRef* = ref AsyncBuffer

  WriteType* = enum
    Pointer, Sequence, String

  WriteItem* = object
    case kind*: WriteType
    of Pointer:
      dataPtr*: pointer
    of Sequence:
      dataSeq*: seq[byte]
    of String:
      dataStr*: string
    size*: int
    offset*: int
    future*: Future[void].Raising([CancelledError, AsyncStreamError])

  AsyncStreamState* = enum
    Running,  ## Stream is online and working
    Error,    ## Stream has stored error
    Stopped,  ## Stream was closed while working
    Finished, ## Stream was properly finished
    Closing,  ## Stream is closing
    Closed    ## Stream was closed

  StreamReaderLoop* = proc (stream: AsyncStreamReader): Future[void] {.
    async: (raises: []).}
    ## Main read loop for read streams.
  StreamWriterLoop* = proc (stream: AsyncStreamWriter): Future[void] {.
    async: (raises: []).}
    ## Main write loop for write streams.

  AsyncStreamReader* = ref object of RootRef
    vtbl*: AsyncStreamReaderVtbl
    rsource* {.deprecated.}: AsyncStreamReader
    tsource* {.deprecated.}: StreamTransport
    readerLoop* {.deprecated.}: StreamReaderLoop
    state* {.deprecated.}: AsyncStreamState
    buffer* {.deprecated.}: AsyncBufferRef
    udata {.deprecated.}: pointer
    error* {.deprecated.}: ref AsyncStreamError
    bytesCount* {.deprecated.}: uint64
    future {.deprecated.}: Future[void].Raising([])

  AsyncStreamWriter* = ref object of RootRef
    vtbl*: AsyncStreamWriterVtbl
    wsource* {.deprecated.}: AsyncStreamWriter
    tsource* {.deprecated.}: StreamTransport
    writerLoop* {.deprecated.}: StreamWriterLoop
    state* {.deprecated.}: AsyncStreamState
    queue* {.deprecated.}: AsyncQueue[WriteItem]
    error* {.deprecated.}: ref AsyncStreamError
    udata {.deprecated.}: pointer
    bytesCount* {.deprecated.}: uint64
    future {.deprecated.}: Future[void].Raising([])

  AsyncStream* = object of RootObj
    reader*: AsyncStreamReader
    writer*: AsyncStreamWriter

  AsyncStreamRW* = AsyncStreamReader | AsyncStreamWriter

proc new*(t: typedesc[AsyncBufferRef], size: int): AsyncBufferRef =
  AsyncBufferRef(
    backend: BipBuffer.init(size),
    events: [newAsyncEvent(), newAsyncEvent()]
  )

template wait*(sb: AsyncBufferRef): untyped =
  sb.events[0].clear()
  sb.events[1].fire()
  sb.events[0].wait()

template transfer*(sb: AsyncBufferRef): untyped =
  sb.events[1].clear()
  sb.events[0].fire()
  sb.events[1].wait()

proc forget*(sb: AsyncBufferRef) {.inline.} =
  sb.events[1].clear()
  sb.events[0].fire()

proc upload*(sb: AsyncBufferRef, pbytes: ptr byte,
             nbytes: int): Future[void] {.
     async: (raises: [CancelledError]).} =
  ## You can upload any amount of bytes to the buffer. If size of internal
  ## buffer is not enough to fit all the data at once, data will be uploaded
  ## via chunks of size up to internal buffer size.
  var
    length = nbytes
    srcBuffer = pbytes.toUnchecked()
    offset = 0

  while length > 0:
    let size = min(length, sb.backend.availSpace())
    if size == 0:
      # Internal buffer is full, we need to notify consumer.
      await sb.transfer()
    else:
      let (data, _) = sb.backend.reserve()
      # Copy data from `pbytes` to internal buffer.
      copyMem(data, addr srcBuffer[offset], size)
      sb.backend.commit(size)
      offset = offset + size
      length = length - size
  # We notify consumers that new data is available.
  sb.forget()

template copyOut*(dest: pointer, item: WriteItem, length: int) =
  if item.kind == Pointer:
    let p = cast[pointer](cast[uint](item.dataPtr) + uint(item.offset))
    copyMem(dest, p, length)
  elif item.kind == Sequence:
    copyMem(dest, unsafeAddr item.dataSeq[item.offset], length)
  elif item.kind == String:
    copyMem(dest, unsafeAddr item.dataStr[item.offset], length)

proc newAsyncStreamReadError(
       p: ref TransportError
     ): ref AsyncStreamReadError {.noinline.} =
  var w = newException(AsyncStreamReadError, "Read stream failed")
  w.msg = w.msg & ", originated from [" & $p.name & "] " & p.msg
  w.parent = p
  w

proc newAsyncStreamWriteError(
       p: ref TransportError
     ): ref AsyncStreamWriteError {.noinline.} =
  var w = newException(AsyncStreamWriteError, "Write stream failed")
  w.msg = w.msg & ", originated from [" & $p.name & "] " & p.msg
  w.parent = p
  w

proc newAsyncStreamIncompleteError*(): ref AsyncStreamIncompleteError {.
     noinline.} =
  newException(AsyncStreamIncompleteError, "Incomplete data sent or received")

proc newAsyncStreamLimitError*(): ref AsyncStreamLimitError {.noinline.} =
  newException(AsyncStreamLimitError, "Buffer limit reached")

proc newAsyncStreamUseClosedError*(): ref AsyncStreamUseClosedError {.
     noinline.} =
  newException(AsyncStreamUseClosedError, "Stream is already closed")

proc raiseAsyncStreamUseClosedError*() {.
     noinline, noreturn, raises: [AsyncStreamUseClosedError].} =
  raise newAsyncStreamUseClosedError()

proc raiseAsyncStreamLimitError*() {.
     noinline, noreturn, raises: [AsyncStreamLimitError].} =
  raise newAsyncStreamLimitError()

proc raiseAsyncStreamIncompleteError*() {.
     noinline, noreturn, raises: [AsyncStreamIncompleteError].} =
  raise newAsyncStreamIncompleteError()

proc raiseEmptyMessageDefect*() {.noinline, noreturn.} =
  raise newException(AsyncStreamIncorrectDefect,
                     "Could not write empty message")

proc raiseAsyncStreamWriteEOFError*() {.
     noinline, noreturn, raises: [AsyncStreamWriteEOFError].} =
  raise newException(AsyncStreamWriteEOFError,
                     "Stream finished or remote side dropped connection")

proc atEof*(rstream: AsyncStreamReader): bool =
  ## Returns ``true`` is reading stream is closed or finished and internal
  ## buffer do not have any bytes left.
  rstream.vtbl.atEof(rstream)

proc atEof*(wstream: AsyncStreamWriter): bool =
  ## Returns ``true`` is writing stream ``wstream`` closed or finished.
  wstream.vtbl.atEof(wstream)

proc closed*(rw: AsyncStreamRW): bool =
  ## Returns ``true`` is reading/writing stream is closed.
  rw.state in {AsyncStreamState.Closing, Closed}

proc finished*(rw: AsyncStreamRW): bool =
  ## Returns ``true`` if reading/writing stream is finished (completed).
  rw.atEof() and rw.state == AsyncStreamState.Finished

proc stopped*(wstream: AsyncStreamWriter): bool =
  ## Returns ``true`` if reading/writing stream is stopped (interrupted).
  wstream.vtbl.stopped(wstream)

proc stopped*(rstream: AsyncStreamReader): bool =
  ## Returns ``true`` if reading/writing stream is stopped (interrupted).
  rstream.vtbl.stopped(rstream)

proc running*(rw: AsyncStreamWriter): bool =
  ## Returns ``true`` if reading/writing stream is still pending.
  rw.vtbl.running(rw)

proc running*(rstream: AsyncStreamReader): bool =
  ## Returns ``true`` if reading/writing stream is still pending.
  rstream.vtbl.running(rstream)

proc failed*(rw: AsyncStreamWriter): bool =
  ## Returns ``true`` if reading/writing stream is in failed state.
  rw.vtbl.failed(rw)

proc failed*(rstream: AsyncStreamReader): bool =
  ## Returns ``true`` if reading/writing stream is in failed state.
  rstream.vtbl.failed(rstream)

template checkStreamClosed*(t: untyped) =
  if t.closed(): raiseAsyncStreamUseClosedError()

template checkStreamFinished*(t: untyped) =
  if t.atEof(): raiseAsyncStreamWriteEOFError()

template readLoop(body: untyped): untyped =
  while true:
    if len(rstream.buffer.backend) == 0:
      if rstream.state == AsyncStreamState.Error:
        raise rstream.error

    let (consumed, done) = body
    rstream.buffer.backend.consume(consumed)
    rstream.bytesCount = rstream.bytesCount + uint64(consumed)
    if done:
      break
    else:
      if not (rstream.atEof()):
        await rstream.buffer.wait()

proc readExactly*(rstream: AsyncStreamReader, pbytes: pointer,
                  nbytes: int) {.
     async: (raises: [CancelledError, AsyncStreamError]).} =
  ## Read exactly ``nbytes`` bytes from read-only stream ``rstream`` and store
  ## it to ``pbytes``.
  ##
  ## If EOF is received and ``nbytes`` is not yet read, the procedure
  ## will raise ``AsyncStreamIncompleteError``.
  doAssert(not(isNil(pbytes)), "pbytes must not be nil")
  doAssert(nbytes >= 0, "nbytes must be non-negative integer")

  checkStreamClosed(rstream)

  if nbytes == 0:
    return

  await rstream.vtbl.readExactly(rstream, pbytes, nbytes)

proc readOnce*(rstream: AsyncStreamReader, pbytes: pointer,
               nbytes: int): Future[int] {.
     async: (raises: [CancelledError, AsyncStreamError]).} =
  ## Perform one read operation on read-only stream ``rstream``.
  ##
  ## If internal buffer is not empty, ``nbytes`` bytes will be transferred from
  ## internal buffer, otherwise it will wait until some bytes will be available.
  doAssert(not(isNil(pbytes)), "pbytes must not be nil")
  doAssert(nbytes > 0, "nbytes must be positive value")
  checkStreamClosed(rstream)

  await rstream.vtbl.readOnce(rstream, pbytes, nbytes)

proc readUntil*(rstream: AsyncStreamReader, pbytes: pointer, nbytes: int,
                sep: seq[byte]): Future[int] {.
     async: (raises: [CancelledError, AsyncStreamError]).} =
  ## Read data from the read-only stream ``rstream`` until separator ``sep`` is
  ## found.
  ##
  ## On success, the data and separator will be removed from the internal
  ## buffer (consumed). Returned data will include the separator at the end.
  ##
  ## If EOF is received, and `sep` was not found, procedure will raise
  ## ``AsyncStreamIncompleteError``.
  ##
  ## If ``nbytes`` bytes has been received and `sep` was not found, procedure
  ## will raise ``AsyncStreamLimitError``.
  ##
  ## Procedure returns actual number of bytes read.
  doAssert(not(isNil(pbytes)), "pbytes must not be nil")
  doAssert(len(sep) > 0, "separator must not be empty")
  doAssert(nbytes >= 0, "nbytes must be non-negative value")
  checkStreamClosed(rstream)

  if nbytes == 0:
    raise newAsyncStreamLimitError()

  await rstream.vtbl.readUntil(rstream, pbytes, nbytes, sep)

proc readLine*(rstream: AsyncStreamReader, limit = 0,
               sep = "\r\n"): Future[string] {.
     async: (raises: [CancelledError, AsyncStreamError]).} =
  ## Read one line from read-only stream ``rstream``, where ``"line"`` is a
  ## sequence of bytes ending with ``sep`` (default is ``"\r\n"``).
  ##
  ## If EOF is received, and ``sep`` was not found, the method will return the
  ## partial read bytes.
  ##
  ## If the EOF was received and the internal buffer is empty, return an
  ## empty string.
  ##
  ## If ``limit`` more then 0, then result string will be limited to ``limit``
  ## bytes.
  checkStreamClosed(rstream)

  await rstream.vtbl.readLine(rstream, limit, sep)

proc read*(rstream: AsyncStreamReader): Future[seq[byte]] {.
     async: (raises: [CancelledError, AsyncStreamError]).} =
  ## Read all bytes from read-only stream ``rstream``.
  ##
  ## This procedure allocates buffer seq[byte] and return it as result.
  checkStreamClosed(rstream)

  await rstream.vtbl.read(rstream, )

proc read*(rstream: AsyncStreamReader, n: int): Future[seq[byte]] {.
     async: (raises: [CancelledError, AsyncStreamError]).} =
  ## Read all bytes (n <= 0) or exactly `n` bytes from read-only stream
  ## ``rstream``.
  ##
  ## This procedure allocates buffer seq[byte] and return it as result.
  checkStreamClosed(rstream)

  await rstream.vtbl.readN(rstream, n)

proc consume*(rstream: AsyncStreamReader): Future[int] {.
     async: (raises: [CancelledError, AsyncStreamError]).} =
  ## Consume (discard) all bytes from read-only stream ``rstream``.
  ##
  ## Return number of bytes actually consumed (discarded).
  checkStreamClosed(rstream)

  await rstream.vtbl.consume(rstream, )

proc consume*(rstream: AsyncStreamReader, n: int): Future[int] {.
     async: (raises: [CancelledError, AsyncStreamError]).} =
  ## Consume (discard) all bytes (n <= 0) or ``n`` bytes from read-only stream
  ## ``rstream``.
  ##
  ## Return number of bytes actually consumed (discarded).
  checkStreamClosed(rstream)

  await rstream.vtbl.consumeN(rstream, n)

proc readMessage*(rstream: AsyncStreamReader, pred: ReadMessagePredicate) {.
     async: (raises: [CancelledError, AsyncStreamError]).} =
  ## Read all bytes from stream ``rstream`` until ``predicate`` callback
  ## will not be satisfied.
  ##
  ## ``predicate`` callback should return tuple ``(consumed, result)``, where
  ## ``consumed`` is the number of bytes processed and ``result`` is a
  ## completion flag (``true`` if readMessage() should stop reading data,
  ## or ``false`` if readMessage() should continue to read data from stream).
  ##
  ## ``predicate`` callback must copy all the data from ``data`` array and
  ## return number of bytes it is going to consume.
  ## ``predicate`` callback will receive (zero-length) openArray, if stream
  ## is at EOF.
  doAssert(not(isNil(pred)), "`predicate` callback should not be `nil`")
  checkStreamClosed(rstream)

  await rstream.vtbl.readMessage(rstream, pred)

proc write*(wstream: AsyncStreamWriter, pbytes: pointer,
            nbytes: int) {.
     async: (raises: [CancelledError, AsyncStreamError]).} =
  ## Write sequence of bytes pointed by ``pbytes`` of length ``nbytes`` to
  ## writer stream ``wstream``.
  ##
  ## ``nbytes`` must be more then zero.
  checkStreamClosed(wstream)
  checkStreamFinished(wstream)

  if nbytes <= 0:
    raiseEmptyMessageDefect()

  await wstream.vtbl.writePointer(wstream, pbytes, nbytes)

  wstream.bytesCount += uint64(nbytes)

proc write*(wstream: AsyncStreamWriter, sbytes: seq[byte],
            msglen = -1) {.
     async: (raises: [CancelledError, AsyncStreamError]).} =
  ## Write sequence of bytes ``sbytes`` of length ``msglen`` to writer
  ## stream ``wstream``.
  ##
  ## Sequence of bytes ``sbytes`` must not be zero-length.
  ##
  ## If ``msglen < 0`` whole sequence ``sbytes`` will be writen to stream.
  ## If ``msglen > len(sbytes)`` only ``len(sbytes)`` bytes will be written to
  ## stream.
  checkStreamClosed(wstream)
  checkStreamFinished(wstream)

  let length = if msglen <= 0: len(sbytes) else: min(msglen, len(sbytes))
  if length <= 0:
    raiseEmptyMessageDefect()

  await wstream.vtbl.writeSeq(wstream, sbytes, length)

  wstream.bytesCount += uint64(length)

proc write*(wstream: AsyncStreamWriter, sbytes: string,
            msglen = -1) {.
     async: (raises: [CancelledError, AsyncStreamError]).} =
  ## Write string ``sbytes`` of length ``msglen`` to writer stream ``wstream``.
  ##
  ## String ``sbytes`` must not be zero-length.
  ##
  ## If ``msglen < 0`` whole string ``sbytes`` will be writen to stream.
  ## If ``msglen > len(sbytes)`` only ``len(sbytes)`` bytes will be written to
  ## stream.
  checkStreamClosed(wstream)
  checkStreamFinished(wstream)

  let length = if msglen <= 0: len(sbytes) else: min(msglen, len(sbytes))
  if length <= 0:
    raiseEmptyMessageDefect()

  await wstream.vtbl.writeStr(wstream, sbytes, length)
  wstream.bytesCount += uint64(length)

proc finish*(wstream: AsyncStreamWriter) {.
     async: (raises: [CancelledError, AsyncStreamError]).} =
  ## Finish write stream ``wstream``.
  checkStreamClosed(wstream)
  # For AsyncStreamWriter Finished state could be set manually or by stream's
  # writeLoop, so we not going to raise exception here.
  if not(wstream.atEof()):
    await wstream.vtbl.finish(wstream)

proc join*(rw: AsyncStreamRW): Future[void] {.
     async: (raw: true, raises: [CancelledError]).} =
  ## Get Future[void] which will be completed when stream become finished or
  ## closed.
  rw.future.join()

proc close*(rw: AsyncStreamReader) =
  ## Close and frees resources of stream ``rw``.
  ##
  ## Note close() procedure is not completed immediately!
  if not(rw.closed()):
    rw.state = AsyncStreamState.Closing

    proc continuation(udata: pointer) {.raises: [].} =
      if not isNil(rw.udata):
        GC_unref(cast[ref int](rw.udata))
      if not(rw.future.finished()):
        rw.future.complete()
      untrackCounter(AsyncStreamReaderTrackerName)
      rw.state = AsyncStreamState.Closed

    if isNil(rw.rsource) or isNil(rw.readerLoop) or isNil(rw.future):
      callSoon(continuation)
    else:
      if rw.future.finished():
        callSoon(continuation)
      else:
        rw.future.addCallback(continuation)
        rw.future.cancelSoon()

proc close*(rw: AsyncStreamWriter) =
  ## Close and frees resources of stream ``rw``.
  ##
  ## Note close() procedure is not completed immediately!
  if not(rw.closed()):
    rw.state = AsyncStreamState.Closing

    proc continuation(udata: pointer) {.raises: [].} =
      if not isNil(rw.udata):
        GC_unref(cast[ref int](rw.udata))
      if not(rw.future.finished()):
        rw.future.complete()
      untrackCounter(AsyncStreamWriterTrackerName)
      rw.state = AsyncStreamState.Closed

    if isNil(rw.wsource) or isNil(rw.writerLoop) or isNil(rw.future):
      callSoon(continuation)
    else:
      if rw.future.finished():
        callSoon(continuation)
      else:
        rw.future.addCallback(continuation)
        rw.future.cancelSoon()

proc closeWait*(rw: AsyncStreamRW): Future[void] {.async: (raises: []).} =
  ## Close and frees resources of stream ``rw``.
  if not rw.closed():
    rw.close()
    await noCancel(rw.join())

proc startReader(rstream: AsyncStreamReader) =
  rstream.state = Running
  if not isNil(rstream.readerLoop):
    rstream.future = rstream.readerLoop(rstream)
  else:
    rstream.future = Future[void].Raising([]).init(
      "async.stream.empty.reader", {FutureFlag.OwnCancelSchedule})

proc startWriter(wstream: AsyncStreamWriter) =
  wstream.state = Running
  if not isNil(wstream.writerLoop):
    wstream.future = wstream.writerLoop(wstream)
  else:
    wstream.future = Future[void].Raising([]).init(
      "async.stream.empty.writer", {FutureFlag.OwnCancelSchedule})

proc init(T: type AsyncStreamReaderVtbl, rsource: AsyncStreamReader): T =
  proc atEofImpl(rstream: AsyncStreamReader): bool =
    rsource.atEof()

  proc stoppedImpl(rstream: AsyncStreamReader): bool =
    rsource.stopped()

  proc runningImpl(rstream: AsyncStreamReader): bool =
    rsource.running()

  proc failedImpl(rstream: AsyncStreamReader): bool =
    rsource.failed()

  proc readExactlyImpl(
      rstream: AsyncStreamReader, pbytes: pointer, nbytes: int
  ) {.async: (raises: [CancelledError, AsyncStreamError], raw: true).} =
    readExactly(rsource, pbytes, nbytes)

  proc readOnceImpl(
      rstream: AsyncStreamReader, pbytes: pointer, nbytes: int
  ): Future[int] {.async: (raises: [CancelledError, AsyncStreamError], raw: true).} =
    readOnce(rsource, pbytes, nbytes)

  proc readUntilImpl(
      rstream: AsyncStreamReader, pbytes: pointer, nbytes: int, sep: seq[byte]
  ): Future[int] {.async: (raises: [CancelledError, AsyncStreamError], raw: true).} =
    readUntil(rsource, pbytes, nbytes, sep)

  proc readLineImpl(
      rstream: AsyncStreamReader, limit = 0, sep = "\r\n"
  ): Future[string] {.async: (raises: [CancelledError, AsyncStreamError], raw: true).} =
    readLine(rsource, limit, sep)

  proc readImpl(
      rstream: AsyncStreamReader
  ): Future[seq[byte]] {.
      async: (raises: [CancelledError, AsyncStreamError], raw: true)
  .} =
    read(rsource)

  proc readNImpl(
      rstream: AsyncStreamReader, n: int
  ): Future[seq[byte]] {.
      async: (raises: [CancelledError, AsyncStreamError], raw: true)
  .} =
    read(rsource, n)

  proc consumeImpl(
      rstream: AsyncStreamReader
  ): Future[int] {.async: (raises: [CancelledError, AsyncStreamError], raw: true).} =
    consume(rsource)

  proc consumeNImpl(
      rstream: AsyncStreamReader, n: int
  ): Future[int] {.async: (raises: [CancelledError, AsyncStreamError], raw: true).} =
    consume(rsource, n)

  proc readMessageImpl(
      rstream: AsyncStreamReader, pred: ReadMessagePredicate
  ) {.async: (raises: [CancelledError, AsyncStreamError], raw: true).} =
    readMessage(rsource, pred)

  T(
    atEof: atEofImpl,
    stopped: stoppedImpl,
    running: runningImpl,
    failed: failedImpl,
    readExactly: readExactlyImpl,
    readOnce: readOnceImpl,
    readUntil: readUntilImpl,
    readLine: readLineImpl,
    read: readImpl,
    readN: readNImpl,
    consume: consumeImpl,
    consumeN: consumeNImpl,
    readMessage: readMessageImpl,
  )

proc init(T: type AsyncStreamReaderVtbl, tsource: StreamTransport): T =
  proc atEofImpl(rstream: AsyncStreamReader): bool =
    tsource.atEof()

  proc stoppedImpl(rstream: AsyncStreamReader): bool =
    false

  proc runningImpl(rstream: AsyncStreamReader): bool =
    tsource.running()

  proc failedImpl(rstream: AsyncStreamReader): bool =
    tsource.failed()

  proc readExactlyImpl(
      rstream: AsyncStreamReader, pbytes: pointer, nbytes: int
  ) {.async: (raises: [CancelledError, AsyncStreamError]).} =
    try:
      await readExactly(tsource, pbytes, nbytes)
    except TransportIncompleteError:
      raise newAsyncStreamIncompleteError()
    except TransportError as exc:
      raise newAsyncStreamReadError(exc)

  proc readOnceImpl(
      rstream: AsyncStreamReader, pbytes: pointer, nbytes: int
  ): Future[int] {.async: (raises: [CancelledError, AsyncStreamError]).} =
    try:
      await readOnce(tsource, pbytes, nbytes)
    except TransportError as exc:
      raise newAsyncStreamReadError(exc)

  proc readUntilImpl(
      rstream: AsyncStreamReader, pbytes: pointer, nbytes: int, sep: seq[byte]
  ): Future[int] {.async: (raises: [CancelledError, AsyncStreamError]).} =
    try:
      await readUntil(tsource, pbytes, nbytes, sep)
    except TransportIncompleteError:
      raise newAsyncStreamIncompleteError()
    except TransportLimitError:
      raise newAsyncStreamLimitError()
    except TransportError as exc:
      raise newAsyncStreamReadError(exc)

  proc readLineImpl(
      rstream: AsyncStreamReader, limit = 0, sep = "\r\n"
  ): Future[string] {.async: (raises: [CancelledError, AsyncStreamError]).} =
    try:
      return await readLine(tsource, limit, sep)
    except TransportError as exc:
      raise newAsyncStreamReadError(exc)

  proc readImpl(
      rstream: AsyncStreamReader
  ): Future[seq[byte]] {.async: (raises: [CancelledError, AsyncStreamError]).} =
    try:
      return await read(tsource)
    except TransportLimitError:
      raise newAsyncStreamLimitError()
    except TransportError as exc:
      raise newAsyncStreamReadError(exc)

  proc readNImpl(
      rstream: AsyncStreamReader, n: int
  ): Future[seq[byte]] {.async: (raises: [CancelledError, AsyncStreamError]).} =
    try:
      return await read(tsource, n)
    except TransportError as exc:
      raise newAsyncStreamReadError(exc)

  proc consumeImpl(
      rstream: AsyncStreamReader
  ): Future[int] {.async: (raises: [CancelledError, AsyncStreamError]).} =
    try:
      return await consume(tsource)
    except TransportLimitError:
      raise newAsyncStreamLimitError()
    except TransportError as exc:
      raise newAsyncStreamReadError(exc)

  proc consumeNImpl(
      rstream: AsyncStreamReader, n: int
  ): Future[int] {.async: (raises: [CancelledError, AsyncStreamError]).} =
    try:
      return await consume(tsource, n)
    except TransportLimitError:
      raise newAsyncStreamLimitError()
    except TransportError as exc:
      raise newAsyncStreamReadError(exc)

  proc readMessageImpl(
      rstream: AsyncStreamReader, pred: ReadMessagePredicate
  ) {.async: (raises: [CancelledError, AsyncStreamError]).} =
    try:
      await readMessage(tsource, pred)
    except TransportError as exc:
      raise newAsyncStreamReadError(exc)

  T(
    atEof: atEofImpl,
    stopped: stoppedImpl,
    running: runningImpl,
    failed: failedImpl,
    readExactly: readExactlyImpl,
    readOnce: readOnceImpl,
    readUntil: readUntilImpl,
    readLine: readLineImpl,
    read: readImpl,
    readN: readNImpl,
    consume: consumeImpl,
    consumeN: consumeNImpl,
    readMessage: readMessageImpl,
  )

proc init(
    T: type AsyncStreamReaderVtbl,
    rstream: AsyncStreamReader,
    readerLoop: StreamReaderLoop,
): T =
  proc atEofImpl(rstream: AsyncStreamReader): bool =
    (rstream.state != AsyncStreamState.Running) and (len(rstream.buffer.backend) == 0)

  proc stoppedImpl(rstream: AsyncStreamReader): bool =
    if isNil(rstream.future) or rstream.future.finished():
      false
    else:
      rstream.state == AsyncStreamState.Stopped

  proc runningImpl(rstream: AsyncStreamReader): bool =
    if isNil(rstream.future) or rstream.future.finished():
      false
    else:
      rstream.state == AsyncStreamState.Running

  proc failedImpl(rstream: AsyncStreamReader): bool =
    if isNil(rstream.future) or rstream.future.finished():
      false
    else:
      rstream.state == AsyncStreamState.Error

  proc readExactlyImpl(
      rstream: AsyncStreamReader, pbytes: pointer, nbytes: int
  ) {.async: (raises: [CancelledError, AsyncStreamError]).} =
    var
      index = 0
      pbuffer = pbytes.toUnchecked()
    readLoop:
      if len(rstream.buffer.backend) == 0:
        if rstream.atEof():
          raise newAsyncStreamIncompleteError()
      var bytesRead = 0
      for (region, rsize) in rstream.buffer.backend.regions():
        let count = min(nbytes - index, rsize)
        bytesRead += count
        if count > 0:
          copyMem(addr pbuffer[index], region, count)
          index += count
        if index == nbytes:
          break
      (consumed: bytesRead, done: index == nbytes)

  proc readOnceImpl(
      rstream: AsyncStreamReader, pbytes: pointer, nbytes: int
  ): Future[int] {.async: (raises: [CancelledError, AsyncStreamError]).} =
    var
      pbuffer = pbytes.toUnchecked()
      index = 0
    readLoop:
      if len(rstream.buffer.backend) == 0:
        (0, rstream.atEof())
      else:
        for (region, rsize) in rstream.buffer.backend.regions():
          let size = min(rsize, nbytes - index)
          copyMem(addr pbuffer[index], region, size)
          index += size
          if index >= nbytes:
            break
        (index, true)
    index

  proc readUntilImpl(
      rstream: AsyncStreamReader, pbytes: pointer, nbytes: int, sep: seq[byte]
  ): Future[int] {.async: (raises: [CancelledError, AsyncStreamError]).} =
    var
      pbuffer = pbytes.toUnchecked()
      state = 0
      k = 0
    readLoop:
      if rstream.atEof():
        raise newAsyncStreamIncompleteError()

      var index = 0
      for ch in rstream.buffer.backend:
        if k >= nbytes:
          raise newAsyncStreamLimitError()

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

  proc readLineImpl(
      rstream: AsyncStreamReader, limit = 0, sep = "\r\n"
  ): Future[string] {.async: (raises: [CancelledError, AsyncStreamError]).} =
    let lim = if limit <= 0: -1 else: limit
    var
      state = 0
      res = ""

    readLoop:
      if rstream.atEof():
        (0, true)
      else:
        var index = 0
        for ch in rstream.buffer.backend:
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

  proc readImpl(
      rstream: AsyncStreamReader
  ): Future[seq[byte]] {.async: (raises: [CancelledError, AsyncStreamError]).} =
    var res: seq[byte]
    readLoop:
      if rstream.atEof():
        (0, true)
      else:
        var bytesRead = 0
        for (region, rsize) in rstream.buffer.backend.regions():
          bytesRead += rsize
          res.add(region.toUnchecked().toOpenArray(0, rsize - 1))
        (bytesRead, false)
    res

  proc readNImpl(
      rstream: AsyncStreamReader, n: int
  ): Future[seq[byte]] {.async: (raises: [CancelledError, AsyncStreamError]).} =
    var res = newSeq[byte]()
    readLoop:
      if rstream.atEof():
        (0, true)
      else:
        var bytesRead = 0
        for (region, rsize) in rstream.buffer.backend.regions():
          let count = min(rsize, n - len(res))
          bytesRead += count
          res.add(region.toUnchecked().toOpenArray(0, count - 1))
        (bytesRead, len(res) == n)
    res

  proc consumeImpl(
      rstream: AsyncStreamReader
  ): Future[int] {.async: (raises: [CancelledError, AsyncStreamError]).} =
    var res = 0
    readLoop:
      if rstream.atEof():
        (0, true)
      else:
        let used = len(rstream.buffer.backend)
        res += used
        (used, false)
    res

  proc consumeNImpl(
      rstream: AsyncStreamReader, n: int
  ): Future[int] {.async: (raises: [CancelledError, AsyncStreamError]).} =
    if n <= 0:
      return await rstream.consume()
    else:
      var res = 0
      readLoop:
        let
          used = len(rstream.buffer.backend)
          count = min(used, n - res)
        res += count
        (count, res == n)
      res

  proc readMessageImpl(
      rstream: AsyncStreamReader, pred: ReadMessagePredicate
  ) {.async: (raises: [CancelledError, AsyncStreamError]).} =
    readLoop:
      if len(rstream.buffer.backend) == 0:
        if rstream.atEof():
          pred([])
        else:
          # Case, when transport's buffer is not yet filled with data.
          (0, false)
      else:
        var res: tuple[consumed: int, done: bool]
        for (region, rsize) in rstream.buffer.backend.regions():
          res = pred(region.toUnchecked().toOpenArray(0, rsize - 1))
          break
        res

  T(
    atEof: atEofImpl,
    stopped: stoppedImpl,
    running: runningImpl,
    failed: failedImpl,
    readExactly: readExactlyImpl,
    readOnce: readOnceImpl,
    readUntil: readUntilImpl,
    readLine: readLineImpl,
    read: readImpl,
    readN: readNImpl,
    consume: consumeImpl,
    consumeN: consumeNImpl,
    readMessage: readMessageImpl,
  )

proc init(T: type AsyncStreamWriterVtbl, wsource: AsyncStreamWriter): T =
  proc atEofImpl(wstream: AsyncStreamWriter): bool =
    wsource.atEof()

  proc stoppedImpl(rw: AsyncStreamWriter): bool =
    wsource.stopped()

  proc runningImpl(rw: AsyncStreamWriter): bool =
    ## Returns ``true`` if reading/writing stream is still pending.
    wsource.running()

  proc failedImpl(rw: AsyncStreamWriter): bool =
    ## Returns ``true`` if reading/writing stream is in failed state.
    wsource.failed()

  proc writeImpl(
      wstream: AsyncStreamWriter, pbytes: pointer, nbytes: int
  ) {.async: (raises: [CancelledError, AsyncStreamError], raw: true).} =
    write(wsource, pbytes, nbytes)

  proc writeImpl(
      wstream: AsyncStreamWriter, sbytes: seq[byte], length: int
  ) {.async: (raises: [CancelledError, AsyncStreamError, raw: true]).} =
    write(wsource, sbytes, length)

  proc writeImpl(
      wstream: AsyncStreamWriter, sbytes: string, length: int
  ) {.async: (raises: [CancelledError, AsyncStreamError], raw: true).} =
    write(wsource, sbytes, length)

  proc finishImpl(
      wstream: AsyncStreamWriter
  ) {.async: (raises: [CancelledError, AsyncStreamError], raw: true).} =
    wsource.finish()

  AsyncStreamWriterVtbl(
    atEof: atEofImpl,
    stopped: stoppedImpl,
    running: runningImpl,
    failed: failedImpl,
    writePointer: writeImpl,
    writeSeq: writeImpl,
    writeStr: writeImpl,
    finish: finishImpl,
  )

proc init(T: type AsyncStreamWriterVtbl, tsource: StreamTransport): T =
  proc atEofImpl(wstream: AsyncStreamWriter): bool =
    tsource.atEof()

  proc stoppedImpl(rw: AsyncStreamWriter): bool =
    false

  proc runningImpl(rw: AsyncStreamWriter): bool =
    tsource.running()

  proc failedImpl(rw: AsyncStreamWriter): bool =
    ## Returns ``true`` if reading/writing stream is in failed state.
    tsource.failed()

  proc writeImpl(
      wstream: AsyncStreamWriter, pbytes: pointer, nbytes: int
  ) {.async: (raises: [CancelledError, AsyncStreamError]).} =
    var res: int
    try:
      res = await write(tsource, pbytes, nbytes)
    except TransportError as exc:
      raise newAsyncStreamWriteError(exc)
    if res != nbytes:
      raise newAsyncStreamIncompleteError()

  proc writeImpl(
      wstream: AsyncStreamWriter, sbytes: seq[byte], length: int
  ) {.async: (raises: [CancelledError, AsyncStreamError]).} =
    var res: int
    try:
      res = await write(tsource, sbytes, length)
    except TransportError as exc:
      raise newAsyncStreamWriteError(exc)
    if res != length:
      raise newAsyncStreamIncompleteError()

  proc writeImpl(
      wstream: AsyncStreamWriter, sbytes: string, length: int
  ) {.async: (raises: [CancelledError, AsyncStreamError]).} =
    var res: int
    try:
      res = await write(tsource, sbytes, length)
    except TransportError as exc:
      raise newAsyncStreamWriteError(exc)
    if res != length:
      raise newAsyncStreamIncompleteError()

  proc finishImpl(
      wstream: AsyncStreamWriter
  ) {.async: (raises: [CancelledError, AsyncStreamError]).} =
    discard

  T(
    atEof: atEofImpl,
    stopped: stoppedImpl,
    running: runningImpl,
    failed: failedImpl,
    writePointer: writeImpl,
    writeSeq: writeImpl,
    writeStr: writeImpl,
    finish: finishImpl,
  )

proc init(
    T: type AsyncStreamWriterVtbl,
    wsource: AsyncStreamWriter,
    writerLoop: StreamWriterLoop,
): T =
  proc atEofImpl(wstream: AsyncStreamWriter): bool =
    if isNil(wstream.future) or wstream.future.finished():
      true
    else:
      wstream.state != AsyncStreamState.Running

  proc stoppedImpl(rw: AsyncStreamWriter): bool =
    if isNil(rw.future) or rw.future.finished():
      false
    else:
      rw.state == AsyncStreamState.Stopped

  proc runningImpl(rw: AsyncStreamWriter): bool =
    if isNil(rw.future) or rw.future.finished():
      false
    else:
      rw.state == AsyncStreamState.Running

  proc failedImpl(rw: AsyncStreamWriter): bool =
    if isNil(rw.future) or rw.future.finished():
      false
    else:
      rw.state == AsyncStreamState.Error

  proc writeImpl(
      wstream: AsyncStreamWriter, pbytes: pointer, nbytes: int
  ) {.async: (raises: [CancelledError, AsyncStreamError]).} =
    let item = WriteItem(
      kind: Pointer,
      dataPtr: pbytes,
      size: nbytes,
      future: Future[void].Raising([CancelledError, AsyncStreamError]).init(
          "async.stream.write(pointer)"
        ),
    )
    await wstream.queue.put(item)
    await item.future

  proc writeImpl(
      wstream: AsyncStreamWriter, sbytes: seq[byte], length: int
  ) {.async: (raises: [CancelledError, AsyncStreamError]).} =
    let item = WriteItem(
      kind: Sequence,
      dataSeq: sbytes,
      size: length,
      future: Future[void].Raising([CancelledError, AsyncStreamError]).init(
          "async.stream.write(seq)"
        ),
    )
    await wstream.queue.put(item)
    await item.future

  proc writeImpl(
      wstream: AsyncStreamWriter, sbytes: string, length: int
  ) {.async: (raises: [CancelledError, AsyncStreamError]).} =
    let item = WriteItem(
      kind: String,
      dataStr: sbytes,
      size: length,
      future: Future[void].Raising([CancelledError, AsyncStreamError]).init(
          "async.stream.write(string)"
        ),
    )
    await wstream.queue.put(item)
    await item.future

  proc finishImpl(
      wstream: AsyncStreamWriter
  ) {.async: (raises: [CancelledError, AsyncStreamError]).} =
    let item = WriteItem(
      kind: Pointer,
      size: 0,
      future: Future[void].Raising([CancelledError, AsyncStreamError]).init(
          "async.stream.finish"
        ),
    )
    await wstream.queue.put(item)
    await item.future

  T(
    atEof: atEofImpl,
    stopped: stoppedImpl,
    running: runningImpl,
    failed: failedImpl,
    writePointer: writeImpl,
    writeSeq: writeImpl,
    writeStr: writeImpl,
    finish: finishImpl,
  )

proc init*(child, wsource: AsyncStreamWriter, loop: StreamWriterLoop,
           queueSize = AsyncStreamDefaultQueueSize) =
  ## Initialize newly allocated object ``child`` with AsyncStreamWriter
  ## parameters.
  child.vtbl = AsyncStreamWriterVtbl.init(wsource, loop)

  child.writerLoop = loop
  child.wsource = wsource
  child.tsource = wsource.tsource
  child.queue = newAsyncQueue[WriteItem](queueSize)
  trackCounter(AsyncStreamWriterTrackerName)
  child.startWriter()

proc init*[T](child, wsource: AsyncStreamWriter, loop: StreamWriterLoop,
              queueSize = AsyncStreamDefaultQueueSize, udata: ref T) =
  ## Initialize newly allocated object ``child`` with AsyncStreamWriter
  ## parameters.
  child.writerLoop = loop
  child.wsource = wsource
  child.tsource = wsource.tsource
  child.queue = newAsyncQueue[WriteItem](queueSize)
  if not isNil(udata):
    GC_ref(udata)
    child.udata = cast[pointer](udata)
  trackCounter(AsyncStreamWriterTrackerName)
  child.startWriter()

proc init*(child, rsource: AsyncStreamReader, loop: StreamReaderLoop,
           bufferSize = AsyncStreamDefaultBufferSize) =
  ## Initialize newly allocated object ``child`` with AsyncStreamReader
  ## parameters.
  child.vtbl = AsyncStreamReaderVtbl.init(rsource, loop)

  child.readerLoop = loop
  child.rsource = rsource
  child.tsource = rsource.tsource
  let size = max(AsyncStreamDefaultBufferSize, bufferSize)
  child.buffer = AsyncBufferRef.new(size)
  trackCounter(AsyncStreamReaderTrackerName)
  child.startReader()

proc init*[T](child, rsource: AsyncStreamReader, loop: StreamReaderLoop,
              bufferSize = AsyncStreamDefaultBufferSize,
              udata: ref T) =
  ## Initialize newly allocated object ``child`` with AsyncStreamReader
  ## parameters.
  child.vtbl = AsyncStreamReaderVtbl.init(rsource, loop)
  child.readerLoop = loop
  child.rsource = rsource
  child.tsource = rsource.tsource
  let size = max(AsyncStreamDefaultBufferSize, bufferSize)
  child.buffer = AsyncBufferRef.new(size)
  if not isNil(udata):
    GC_ref(udata)
    child.udata = cast[pointer](udata)
  trackCounter(AsyncStreamReaderTrackerName)
  child.startReader()

proc init*(child: AsyncStreamWriter, tsource: StreamTransport) =
  ## Initialize newly allocated object ``child`` with AsyncStreamWriter
  ## parameters.
  child.vtbl = AsyncStreamWriterVtbl.init(tsource)
  child.writerLoop = nil
  child.wsource = nil
  child.tsource = tsource
  trackCounter(AsyncStreamWriterTrackerName)
  child.startWriter()

proc init*[T](child: AsyncStreamWriter, tsource: StreamTransport,
              udata: ref T) {.deprecated.} =
  ## Initialize newly allocated object ``child`` with AsyncStreamWriter
  ## parameters.
  child.vtbl = AsyncStreamWriterVtbl.init(tsource)
  child.writerLoop = nil
  child.wsource = nil
  child.tsource = tsource
  trackCounter(AsyncStreamWriterTrackerName)
  child.startWriter()

proc init*(child, wsource: AsyncStreamWriter) =
  ## Initialize newly allocated object ``child`` with AsyncStreamWriter
  ## parameters.
  child.vtbl = AsyncStreamWriterVtbl.init(wsource)
  child.writerLoop = nil
  child.wsource = wsource
  child.tsource = wsource.tsource
  trackCounter(AsyncStreamWriterTrackerName)
  child.startWriter()

proc init*[T](child, wsource: AsyncStreamWriter, udata: ref T) =
  ## Initialize newly allocated object ``child`` with AsyncStreamWriter
  ## parameters.
  child.vtbl = AsyncStreamWriterVtbl.init(wsource)

  child.writerLoop = nil
  child.wsource = wsource
  child.tsource = wsource.tsource
  if not isNil(udata):
    GC_ref(udata)
    child.udata = cast[pointer](udata)
  trackCounter(AsyncStreamWriterTrackerName)
  child.startWriter()

proc init*(child: AsyncStreamReader, tsource: StreamTransport) =
  ## Initialize newly allocated object ``child`` with AsyncStreamReader
  ## parameters.
  child.vtbl = AsyncStreamReaderVtbl.init(tsource)

  child.readerLoop = nil
  child.rsource = nil
  child.tsource = tsource
  trackCounter(AsyncStreamReaderTrackerName)
  child.startReader()

proc init*[T](child: AsyncStreamReader, tsource: StreamTransport,
              udata: ref T) =
  ## Initialize newly allocated object ``child`` with AsyncStreamReader
  ## parameters.
  child.readerLoop = nil
  child.rsource = nil
  child.tsource = tsource
  if not isNil(udata):
    GC_ref(udata)
    child.udata = cast[pointer](udata)
  trackCounter(AsyncStreamReaderTrackerName)
  child.startReader()

proc init*(child, rsource: AsyncStreamReader) =
  ## Initialize newly allocated object ``child`` with AsyncStreamReader
  ## parameters.
  child.vtbl = AsyncStreamReaderVtbl.init(rsource)
  child.readerLoop = nil
  child.rsource = rsource
  child.tsource = rsource.tsource
  trackCounter(AsyncStreamReaderTrackerName)
  child.startReader()

proc init*[T](child, rsource: AsyncStreamReader, udata: ref T) =
  ## Initialize newly allocated object ``child`` with AsyncStreamReader
  ## parameters.
  child.vtbl = AsyncStreamReaderVtbl.init(rsource)
  child.readerLoop = nil
  child.rsource = rsource
  child.tsource = rsource.tsource
  if not isNil(udata):
    GC_ref(udata)
    child.udata = cast[pointer](udata)
  trackCounter(AsyncStreamReaderTrackerName)
  child.startReader()

proc newAsyncStreamReader*[T](rsource: AsyncStreamReader,
                              loop: StreamReaderLoop,
                              bufferSize = AsyncStreamDefaultBufferSize,
                              udata: ref T): AsyncStreamReader =
  ## Create new AsyncStreamReader object, which will use other async stream
  ## reader ``rsource`` as source data channel.
  ##
  ## ``loop`` is main reading loop procedure.
  ##
  ## ``bufferSize`` is internal buffer size.
  ##
  ## ``udata`` - user object which will be associated with new AsyncStreamReader
  ## object.
  var res = AsyncStreamReader()
  res.init(rsource, loop, bufferSize, udata)
  res

proc newAsyncStreamReader*(rsource: AsyncStreamReader,
                           loop: StreamReaderLoop,
                           bufferSize = AsyncStreamDefaultBufferSize
                          ): AsyncStreamReader =
  ## Create new AsyncStreamReader object, which will use other async stream
  ## reader ``rsource`` as source data channel.
  ##
  ## ``loop`` is main reading loop procedure.
  ##
  ## ``bufferSize`` is internal buffer size.
  var res = AsyncStreamReader()
  res.init(rsource, loop, bufferSize)
  res

proc newAsyncStreamReader*[T](tsource: StreamTransport,
                              udata: ref T): AsyncStreamReader =
  ## Create new AsyncStreamReader object, which will use stream transport
  ## ``tsource`` as source data channel.
  ##
  ## ``udata`` - user object which will be associated with new AsyncStreamWriter
  ## object.
  var res = AsyncStreamReader()
  res.init(tsource, udata)
  res

proc newAsyncStreamReader*(tsource: StreamTransport): AsyncStreamReader =
  ## Create new AsyncStreamReader object, which will use stream transport
  ## ``tsource`` as source data channel.
  var res = AsyncStreamReader()
  res.init(tsource)
  res

proc newAsyncStreamReader*[T](rsource: AsyncStreamReader,
                              udata: ref T): AsyncStreamReader =
  ## Create copy of AsyncStreamReader object ``rsource``.
  ##
  ## ``udata`` - user object which will be associated with new AsyncStreamReader
  ## object.
  var res = AsyncStreamReader()
  res.init(rsource, udata)
  res

proc newAsyncStreamReader*(rsource: AsyncStreamReader): AsyncStreamReader =
  ## Create copy of AsyncStreamReader object ``rsource``.
  var res = AsyncStreamReader()
  res.init(rsource)
  res

proc newAsyncStreamWriter*[T](wsource: AsyncStreamWriter,
                              loop: StreamWriterLoop,
                              queueSize = AsyncStreamDefaultQueueSize,
                              udata: ref T): AsyncStreamWriter =
  ## Create new AsyncStreamWriter object which will use other AsyncStreamWriter
  ## object ``wsource`` as data channel.
  ##
  ## ``loop`` is main writing loop procedure.
  ##
  ## ``queueSize`` is writing queue size (default size is unlimited).
  ##
  ## ``udata`` - user object which will be associated with new AsyncStreamWriter
  ## object.
  var res = AsyncStreamWriter()
  res.init(wsource, loop, queueSize, udata)
  res

proc newAsyncStreamWriter*(wsource: AsyncStreamWriter,
                           loop: StreamWriterLoop,
                           queueSize = AsyncStreamDefaultQueueSize
                          ): AsyncStreamWriter =
  ## Create new AsyncStreamWriter object which will use other AsyncStreamWriter
  ## object ``wsource`` as data channel.
  ##
  ## ``loop`` is main writing loop procedure.
  ##
  ## ``queueSize`` is writing queue size (default size is unlimited).
  var res = AsyncStreamWriter()
  res.init(wsource, loop, queueSize)
  res

proc newAsyncStreamWriter*[T](tsource: StreamTransport,
                              udata: ref T): AsyncStreamWriter =
  ## Create new AsyncStreamWriter object which will use stream transport
  ## ``tsource`` as  data channel.
  ##
  ## ``udata`` - user object which will be associated with new AsyncStreamWriter
  ## object.
  var res = AsyncStreamWriter()
  res.init(tsource, udata)
  res

proc newAsyncStreamWriter*(tsource: StreamTransport): AsyncStreamWriter =
  ## Create new AsyncStreamWriter object which will use stream transport
  ## ``tsource`` as data channel.
  var res = AsyncStreamWriter()
  res.init(tsource)
  res

proc newAsyncStreamWriter*[T](wsource: AsyncStreamWriter,
                              udata: ref T): AsyncStreamWriter =
  ## Create copy of AsyncStreamWriter object ``wsource``.
  ##
  ## ``udata`` - user object which will be associated with new AsyncStreamWriter
  ## object.
  var res = AsyncStreamWriter()
  res.init(wsource, udata)
  res

proc newAsyncStreamWriter*(wsource: AsyncStreamWriter): AsyncStreamWriter =
  ## Create copy of AsyncStreamWriter object ``wsource``.
  var res = AsyncStreamWriter()
  res.init(wsource)
  res

proc getUserData*[T](rw: AsyncStreamRW): T {.inline.} =
  ## Obtain user data associated with AsyncStreamReader or AsyncStreamWriter
  ## object ``rw``.
  cast[T](rw.udata)

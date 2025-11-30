#
#            Chronos Asynchronous Streams
#             (c) Copyright 2019-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

{.push raises: [], gcsafe.}

import std/strutils
import stew/[ptrops, shims/sequninit]
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

template ignoreDeprecated(body: untyped) =
  {.push warning[Deprecated]: off.}
  body
  {.pop.}

type
  # The VTable implementation below contains a large number of operations that
  # for many stream types can be synthesized but exist for
  # backwards-compatiblity and efficiency reasons.
  #
  # In particular, we can divide operations into buffered and unbuffered -
  # `readOnce` for example does not require an intermediate buffer while
  # `readUntil` must buffer data so that it doesn't read too many bytes from its
  # source stream.
  #
  # While buffering is needed for correctness, it is also slow due to the extra
  # copies - therefore, when async streams are layered on top of each other,
  # we try to avoid using buffers in more than one layer.
  #
  # Many protocols start off with a buffered header operation only to go into
  # bulk transfer mode shortly thereafter - for such protocols, data from the
  # buffer is used up then we go back to unbuffered mode.
  #
  # Similarly, some of the operations like `atEof` historically either used
  # the `state` field or the underlying data source depending on the stream type,
  # so we retain both options and select implementation in the vtable - future
  # cleanups may simplify this setup.
  #
  # `initSimpleVtbl` creates a "standard" implementation that forwards most calls
  # to `readOnce`/`write` and lazily allocates a buffer for the operations that
  # need it.
  #
  # With that as a starting point, implementations may choose to override
  # specific operations if the underlying construct is known to perform them
  # more efficiently.
  #
  # The vtable approach has not yet ossified, ie it's beta and may change
  # between releases.

  ReadOnceProc* = proc(
    rstream: AsyncStreamReader, pbytes: pointer, nbytes: int
  ): Future[int] {.async: (raises: [CancelledError, AsyncStreamError]).}

  AsyncStreamReaderVtbl* = object
    atEof*: proc(rstream: AsyncStreamReader): bool {.gcsafe, raises: [].}
    stopped*: proc(rstream: AsyncStreamReader): bool {.gcsafe, raises: [].}
    running*: proc(rstream: AsyncStreamReader): bool {.gcsafe, raises: [].}
    failed*: proc(rstream: AsyncStreamReader): bool {.gcsafe, raises: [].}

    readOnce*: ReadOnceProc

    readExactly*: proc(rstream: AsyncStreamReader, pbytes: pointer, nbytes: int) {.
      async: (raises: [CancelledError, AsyncStreamError])
    .}
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

    close*: proc(rstream: AsyncStreamReader) {.async: (raises: []).}

  WriteProc* = proc(wstream: AsyncStreamWriter, pbytes: pointer, nbytes: int) {.
    async: (raises: [CancelledError, AsyncStreamError])
  .}
  AsyncStreamWriterVtbl* = object
    atEof*: proc(wstream: AsyncStreamWriter): bool {.gcsafe, raises: [].}
    stopped*: proc(wstream: AsyncStreamWriter): bool {.gcsafe, raises: [].}
    running*: proc(wstream: AsyncStreamWriter): bool {.gcsafe, raises: [].}
    failed*: proc(wstream: AsyncStreamWriter): bool {.gcsafe, raises: [].}

    write*: WriteProc

    finish*: proc(wstream: AsyncStreamWriter) {.
      async: (raises: [CancelledError, AsyncStreamError])
    .}

    close*: proc(wstream: AsyncStreamWriter) {.async: (raises: []).}

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
    rsource*: AsyncStreamReader
    tsource*: StreamTransport
    state*: AsyncStreamState
    buffer*: AsyncBufferRef
    udata: pointer
    error*: ref AsyncStreamError
    bytesCount* {.deprecated.}: uint64
      # Unmaintained, remains zero for all streams

    future: Future[void].Raising([])

  AsyncStreamWriter* = ref object of RootRef
    vtbl*: AsyncStreamWriterVtbl
    wsource*: AsyncStreamWriter
    tsource*: StreamTransport
    state*: AsyncStreamState
    queue* {.deprecated.}: AsyncQueue[WriteItem]
      # Only used with the deprecated loop approach
    error*: ref AsyncStreamError
    udata: pointer
    bytesCount* {.deprecated.}: uint64
      # Unmaintained, remains zero for all streams
    future: Future[void].Raising([])

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

proc newAsyncStreamWriteEOFError*(): ref AsyncStreamWriteEOFError {.noinline.} =
  newException(AsyncStreamWriteEOFError,
               "Stream finished or remote side dropped connection")

proc raiseAsyncStreamWriteEOFError*() {.
     noinline, noreturn, raises: [AsyncStreamWriteEOFError].} =
  raise newAsyncStreamWriteEOFError()

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

proc stopped*(rw: AsyncStreamRW): bool =
  ## Returns ``true`` if reading/writing stream is stopped (interrupted).
  rw.vtbl.stopped(rw)

proc running*(rw: AsyncStreamRW): bool =
  ## Returns ``true`` if reading/writing stream is still pending.
  rw.vtbl.running(rw)

proc failed*(rw: AsyncStreamRW): bool =
  ## Returns ``true`` if reading/writing stream is in failed state.
  rw.vtbl.failed(rw)

template checkStreamClosed(t: untyped) =
  if t.closed(): raiseAsyncStreamUseClosedError()

template checkStreamClosed(t: untyped, T: type) =
  if t.closed():
    var fut = newFuture[T]()
    fut.fail(newAsyncStreamUseClosedError())
    return fut


template checkStreamFinished(t: untyped, T: type) =
  if t.atEof():
    var fut = newFuture[T]()
    fut.fail(newAsyncStreamWriteEOFError())
    return fut

template readLoop(body: untyped): untyped =
  while true:
    if len(rstream.buffer.backend) == 0:
      if rstream.state == AsyncStreamState.Error:
        raise rstream.error

    let (consumed, done) = body
    rstream.buffer.backend.consume(consumed)
    if done:
      break
    else:
      if not(rstream.atEof()):
        await rstream.buffer.wait()

template drainBuffer(
    rstream: AsyncStreamReader, pbytes: pointer, nbytes: int
): (ptr byte, int) =
  let pbuffer = cast[ptr byte](pbytes)
  if rstream.buffer != nil and rstream.buffer.backend.len > 0:
    let n = rstream.buffer.backend.copyInto(pbuffer.makeOpenArray(nbytes))
    rstream.buffer.backend.consume(n)
    (pbuffer.offset(n), nbytes - n)
  else:
    (pbuffer, nbytes)

proc readExactly*(rstream: AsyncStreamReader, pbytes: pointer,
                  nbytes: int) {.
     async: (raises: [CancelledError, AsyncStreamError], raw: true).} =
  ## Read exactly ``nbytes`` bytes from read-only stream ``rstream`` and store
  ## it to ``pbytes``.
  ##
  ## If EOF is received and ``nbytes`` is not yet read, the procedure
  ## will raise ``AsyncStreamIncompleteError``.
  doAssert(not(isNil(pbytes)) or nbytes == 0, "pbytes must not be nil")
  doAssert(nbytes >= 0, "nbytes must be non-negative integer")

  checkStreamClosed(rstream, void)

  if nbytes == 0:
    let fut = newFuture[void]()
    fut.complete()
    return fut

  let (pbuffer, nbytes) = rstream.drainBuffer(pbytes, nbytes)
  rstream.vtbl.readExactly(rstream, pbuffer, nbytes)

proc readOnce*(rstream: AsyncStreamReader, pbytes: pointer,
               nbytes: int): Future[int] {.
     async: (raises: [CancelledError, AsyncStreamError], raw: true).} =
  ## Perform one read operation on read-only stream ``rstream``.
  ##
  ## If internal buffer is not empty, ``nbytes`` bytes will be transferred from
  ## internal buffer, otherwise it will wait until some bytes will be available.
  doAssert(not(isNil(pbytes)), "pbytes must not be nil")
  doAssert(nbytes > 0, "nbytes must be positive value")

  checkStreamClosed(rstream, int)

  let (pbuffer, nbytes2) = rstream.drainBuffer(pbytes, nbytes)
  if nbytes2 < nbytes: # If some bytes were read, we return immediately
    let fut = newFuture[int]()
    fut.complete(nbytes - nbytes2)
    return fut

  rstream.vtbl.readOnce(rstream, pbuffer, nbytes)

proc readUntil*(rstream: AsyncStreamReader, pbytes: pointer, nbytes: int,
                sep: seq[byte]): Future[int] {.
     async: (raises: [CancelledError, AsyncStreamError], raw: true).} =
  ## Read data from the read-only stream ``rstream`` until separator ``sep`` is
  ## found.
  ##
  ## On success, the data up to and including the separator will be copied to
  ## `pbytes` returning the number of bytes copied.
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

  checkStreamClosed(rstream, int)

  if nbytes == 0:
    var fut = newFuture[int]()
    fut.fail(newAsyncStreamLimitError())
    return fut

  rstream.vtbl.readUntil(rstream, pbytes, nbytes, sep)

proc readLine*(rstream: AsyncStreamReader, limit = 0,
               sep = "\r\n"): Future[string] {.
     async: (raises: [CancelledError, AsyncStreamError], raw: true).} =
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
  checkStreamClosed(rstream, string)

  rstream.vtbl.readLine(rstream, limit, sep)

proc read*(rstream: AsyncStreamReader): Future[seq[byte]] {.
     async: (raises: [CancelledError, AsyncStreamError], raw: true).} =
  ## Read all bytes from read-only stream ``rstream``.
  ##
  ## This procedure allocates buffer seq[byte] and return it as result.
  checkStreamClosed(rstream, seq[byte])

  rstream.vtbl.read(rstream)

proc read*(rstream: AsyncStreamReader, n: int): Future[seq[byte]] {.
     async: (raises: [CancelledError, AsyncStreamError], raw: true).} =
  ## Read all bytes (n <= 0) or exactly `n` bytes from read-only stream
  ## ``rstream``.
  ##
  ## This procedure allocates buffer seq[byte] and return it as result.
  checkStreamClosed(rstream, seq[byte])

  rstream.vtbl.readN(rstream, n)

proc consume*(rstream: AsyncStreamReader): Future[int] {.
     async: (raises: [CancelledError, AsyncStreamError], raw: true).} =
  ## Consume (discard) all bytes from read-only stream ``rstream``.
  ##
  ## Return number of bytes actually consumed (discarded).
  checkStreamClosed(rstream, int)

  rstream.vtbl.consume(rstream)

proc consume*(rstream: AsyncStreamReader, n: int): Future[int] {.
     async: (raises: [CancelledError, AsyncStreamError], raw: true).} =
  ## Consume (discard) all bytes (n <= 0) or ``n`` bytes from read-only stream
  ## ``rstream``.
  ##
  ## Return number of bytes actually consumed (discarded).
  checkStreamClosed(rstream, int)

  rstream.vtbl.consumeN(rstream, n)

proc readMessage*(rstream: AsyncStreamReader, pred: ReadMessagePredicate) {.
     async: (raises: [CancelledError, AsyncStreamError], raw: true).} =
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
  checkStreamClosed(rstream, void)

  rstream.vtbl.readMessage(rstream, pred)

proc write*(wstream: AsyncStreamWriter, pbytes: pointer,
            nbytes: int) {.
     async: (raises: [CancelledError, AsyncStreamError], raw: true).} =
  ## Write sequence of bytes pointed by ``pbytes`` of length ``nbytes`` to
  ## writer stream ``wstream``.
  ##
  ## ``nbytes`` must be more then zero.
  checkStreamClosed(wstream, void)
  checkStreamFinished(wstream, void)

  if nbytes <= 0:
    raiseEmptyMessageDefect()

  wstream.vtbl.write(wstream, pbytes, nbytes)

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
  let length = if msglen <= 0: len(sbytes) else: min(msglen, len(sbytes))
  await write(wstream, baseAddr sbytes, length) # await to keep memory around

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
  let length = if msglen <= 0: len(sbytes) else: min(msglen, len(sbytes))
  await write(wstream, baseAddr sbytes, length) # await to keep memory around

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

    let fut = rw.vtbl.close(rw)
    fut.addCallback(continuation)

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

    let fut = rw.vtbl.close(rw)
    fut.addCallback(continuation)

proc closeWait*(rw: AsyncStreamRW): Future[void] {.async: (raises: []).} =
  ## Close and frees resources of stream ``rw``.
  if not rw.closed():
    rw.close()
    await noCancel(rw.join())

proc startReader(rstream: AsyncStreamReader) =
  rstream.state = Running
  rstream.future = Future[void].Raising([]).init(
    "async.stream.empty.reader", {FutureFlag.OwnCancelSchedule})

proc startWriter(wstream: AsyncStreamWriter) =
  wstream.state = Running
  wstream.future = Future[void].Raising([]).init(
    "async.stream.empty.writer", {FutureFlag.OwnCancelSchedule})

proc init(T: type AsyncStreamReaderVtbl, rsource: AsyncStreamReader): T =
  # Trivial vtable that forwards all operations to another stream
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

  proc closeImpl(
    rstream: AsyncStreamReader
  ) {.async: (raises: []).} =
    close(rsource)

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
    close: closeImpl,
  )

proc init(T: type AsyncStreamReaderVtbl, tsource: StreamTransport): T =
  # VTable that forwards all operations to a StreamTransport, translating
  # excpetions as we go
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

  proc closeImpl(
    rstream: AsyncStreamReader
  ) {.async: (raises: []).} =
    discard # TODO cascade close?

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
    close: closeImpl,
  )

proc init(
    T: type AsyncStreamReaderVtbl,
    rstream: AsyncStreamReader,
    readerLoop: StreamReaderLoop,
): T =
  let readerLoopFut = readerLoop(rstream)

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
        total = 0
        pbuffer = cast[ptr byte](pbytes)
      readLoop():
        if len(rstream.buffer.backend) == 0:
          if rstream.atEof():
            raise newAsyncStreamIncompleteError()
        let consumed =
          rstream.buffer.backend.copyInto(pbuffer.makeOpenArray(nbytes - total))
        pbuffer = pbuffer.offset(consumed)
        total += consumed
        (consumed: consumed, done: total == nbytes)

  proc readOnceImpl(
      rstream: AsyncStreamReader, pbytes: pointer, nbytes: int
  ): Future[int] {.async: (raises: [CancelledError, AsyncStreamError]).} =
      var
        total = 0
        pbuffer = cast[ptr byte](pbytes)
      readLoop():
        if len(rstream.buffer.backend) == 0:
          (0, rstream.atEof())
        else:
          total = rstream.buffer.backend.copyInto(pbuffer.makeOpenArray(nbytes))
          (total, true)
      total

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

      if k == nbytes:
        raise newAsyncStreamLimitError()

      let (n, found) = rstream.buffer.backend.copyUntil(
        pbuffer.toOpenArray(k, nbytes - 1), state, sep)
      k += n

      (n, found)

    k

  proc readLineImpl(
      rstream: AsyncStreamReader, limit = 0, sep = "\r\n"
  ): Future[string] {.async: (raises: [CancelledError, AsyncStreamError]).} =
    var
      res = ""
      state = 0

    readLoop():
      if rstream.atEof():
        (0, true)
      else:
        rstream.buffer.backend.addLineInto(res, state, limit, sep)

    res

  proc readImpl(
      rstream: AsyncStreamReader
  ): Future[seq[byte]] {.async: (raises: [CancelledError, AsyncStreamError]).} =
    var res: seq[byte]
    readLoop():
      if rstream.atEof():
        (0, true)
      else:
        var pos = res.len
        res.setLenUninit(pos + rstream.buffer.backend.len())
        let bytesRead =
          rstream.buffer.backend.copyInto(res.toOpenArray(pos, res.high()))
        (bytesRead, false)
    res

  proc readNImpl(
      rstream: AsyncStreamReader, n: int
  ): Future[seq[byte]] {.async: (raises: [CancelledError, AsyncStreamError]).} =
    var res = newSeq[byte]()
    readLoop():
      if rstream.atEof():
        (0, true)
      else:
        var pos = res.len
        res.setLenUninit(pos + min(rstream.buffer.backend.len(), n - res.len))
        let bytesRead =
          rstream.buffer.backend.copyInto(res.toOpenArray(pos, res.high()))
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

  proc closeImpl(
    rstream: AsyncStreamReader
  ) {.async: (raises: [], raw: true).} =
    readerLoopFut.cancelAndWait()

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
    close: closeImpl,
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

  proc finishImpl(
      wstream: AsyncStreamWriter
  ) {.async: (raises: [CancelledError, AsyncStreamError], raw: true).} =
    wsource.finish()

  proc closeImpl(
      wstream: AsyncStreamWriter
  ) {.async: (raises: []).} =
    wsource.close()

  AsyncStreamWriterVtbl(
    atEof: atEofImpl,
    stopped: stoppedImpl,
    running: runningImpl,
    failed: failedImpl,
    write: writeImpl,
    finish: finishImpl,
    close: closeImpl,
  )

proc init(T: type AsyncStreamWriterVtbl, tsource: StreamTransport): T =
  proc atEofImpl(wstream: AsyncStreamWriter): bool =
    tsource.atEof()

  proc stoppedImpl(rw: AsyncStreamWriter): bool =
    false

  proc runningImpl(rw: AsyncStreamWriter): bool =
    tsource.running()

  proc failedImpl(rw: AsyncStreamWriter): bool =
    tsource.failed()

  proc writeImpl(
      wstream: AsyncStreamWriter, pbytes: pointer, nbytes: int
  ) {.async: (raises: [CancelledError, AsyncStreamError]).} =
    let res =
      try:
        await write(tsource, pbytes, nbytes)
      except TransportError as exc:
        raise newAsyncStreamWriteError(exc)
    if res != nbytes:
      raise newAsyncStreamIncompleteError()

  proc finishImpl(
      wstream: AsyncStreamWriter
  ) {.async: (raises: [CancelledError, AsyncStreamError]).} =
    discard # TODO shutdown?

  proc closeImpl(
      wstream: AsyncStreamWriter
  ) {.async: (raises: []).} =
    discard

  T(
    atEof: atEofImpl,
    stopped: stoppedImpl,
    running: runningImpl,
    failed: failedImpl,
    write: writeImpl,
    finish: finishImpl,
    close: closeImpl,
  )

proc init(
    T: type AsyncStreamWriterVtbl,
    wsource: AsyncStreamWriter,
    writerLoop: StreamWriterLoop,
): T =
  let writerLoopFut = writerLoop(wsource)
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
    ignoreDeprecated:
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
    ignoreDeprecated:
      await wstream.queue.put(item)
    await item.future

  proc closeImpl(
      wstream: AsyncStreamWriter
  ) {.async: (raises: [], raw: true).} =
    writerLoopFut.cancelAndWait()

  T(
    atEof: atEofImpl,
    stopped: stoppedImpl,
    running: runningImpl,
    failed: failedImpl,
    write: writeImpl,
    finish: finishImpl,
    close: closeImpl
  )

proc initUdata*[T](child: AsyncStreamRW, udata: ref T) =
  if not isNil(udata):
    GC_ref(udata)
    child.udata = cast[pointer](udata)

proc init*(child: AsyncStreamWriter, vtbl: AsyncStreamWriterVtbl) =
  ## Initialize newly allocated object ``child`` with AsyncStreamWriter
  ## parameters.
  trackCounter(AsyncStreamWriterTrackerName)
  child.startWriter()
  child.vtbl = vtbl

proc init*(child, wsource: AsyncStreamWriter, loop: StreamWriterLoop,
           queueSize = AsyncStreamDefaultQueueSize) {.deprecated: "initSimpleVtbl".} =
  ## Initialize newly allocated object ``child`` with AsyncStreamWriter
  ## parameters.

  ignoreDeprecated:
    child.wsource = wsource
    child.tsource = wsource.tsource
    child.queue = newAsyncQueue[WriteItem](queueSize)

  let vtbl = AsyncStreamWriterVtbl.init(wsource, loop)
  child.init(vtbl)

proc init*[T](child, wsource: AsyncStreamWriter, loop: StreamWriterLoop,
              queueSize = AsyncStreamDefaultQueueSize, udata: ref T) {.
            deprecated: "`udata` deprecated, use inheritance instead".} =
  ## Initialize newly allocated object ``child`` with AsyncStreamWriter
  ## parameters.
  child.initUdata(udata)
  child.init(child, wsource, loop, queueSize)

proc init*(child: AsyncStreamReader, vtbl: AsyncStreamReaderVtbl) =
  ## Initialize newly allocated object ``child`` with AsyncStreamReader
  ## parameters.
  trackCounter(AsyncStreamReaderTrackerName)
  child.startReader()
  child.vtbl = vtbl

proc init*(child, rsource: AsyncStreamReader, loop: StreamReaderLoop,
           bufferSize = AsyncStreamDefaultBufferSize) {.deprecated: "initSimpleVtbl".} =
  ## Initialize newly allocated object ``child`` with AsyncStreamReader
  ## parameters.

  child.rsource = rsource
  child.tsource = rsource.tsource
  let size = max(AsyncStreamDefaultBufferSize, bufferSize)
  child.buffer = AsyncBufferRef.new(size)
  child.init(AsyncStreamReaderVtbl.init(rsource, loop))

proc init*[T](child, rsource: AsyncStreamReader, loop: StreamReaderLoop,
              bufferSize = AsyncStreamDefaultBufferSize,
              udata: ref T) {.
            deprecated: "`udata` deprecated, use inheritance instead".} =
  ## Initialize newly allocated object ``child`` with AsyncStreamReader
  ## parameters.
  child.initUdata(udata)
  child.init(rsource, loop, bufferSize)

proc init*(child: AsyncStreamWriter, tsource: StreamTransport) =
  ## Initialize newly allocated object ``child`` with AsyncStreamWriter
  ## parameters.
  child.wsource = nil
  child.tsource = tsource

  let vtbl = AsyncStreamWriterVtbl.init(tsource)
  child.init(vtbl)

proc init*[T](child: AsyncStreamWriter, tsource: StreamTransport,
              udata: ref T) {.
            deprecated: "`udata` deprecated, use inheritance instead".} =
  ## Initialize newly allocated object ``child`` with AsyncStreamWriter
  ## parameters.
  child.initUdata(udata)
  child.init(tsource)

proc init*(child, wsource: AsyncStreamWriter) =
  ## Initialize newly allocated object ``child`` with AsyncStreamWriter
  ## parameters.
  child.wsource = wsource
  child.tsource = wsource.tsource
  let vtbl = AsyncStreamWriterVtbl.init(wsource)
  child.init(vtbl)

proc init*[T](child, wsource: AsyncStreamWriter, udata: ref T) {.
            deprecated: "`udata` deprecated, use inheritance instead".} =
  ## Initialize newly allocated object ``child`` with AsyncStreamWriter
  ## parameters.
  child.initUdata(udata)
  child.init(wsource)

proc init*(child: AsyncStreamReader, tsource: StreamTransport) =
  ## Initialize newly allocated object ``child`` with AsyncStreamReader
  ## parameters.
  child.rsource = nil
  child.tsource = tsource
  child.init(AsyncStreamReaderVtbl.init(tsource))

proc init*[T](child: AsyncStreamReader, tsource: StreamTransport,
              udata: ref T) {.
            deprecated: "`udata` deprecated, use inheritance instead".} =
  ## Initialize newly allocated object ``child`` with AsyncStreamReader
  ## parameters.
  child.initUdata(udata)
  child.init(tsource)

proc init*(child, rsource: AsyncStreamReader) =
  ## Initialize newly allocated object ``child`` with AsyncStreamReader
  ## parameters.
  child.rsource = rsource
  child.tsource = rsource.tsource

  child.init(AsyncStreamReaderVtbl.init(rsource))

proc init*[T](child, rsource: AsyncStreamReader, udata: ref T) {.
            deprecated: "`udata` deprecated, use inheritance instead".} =
  ## Initialize newly allocated object ``child`` with AsyncStreamReader
  ## parameters.
  child.initUdata(udata)
  child.init(rsource)

proc newAsyncStreamReader*[T](rsource: AsyncStreamReader,
                              loop: StreamReaderLoop,
                              bufferSize = AsyncStreamDefaultBufferSize,
                              udata: ref T): AsyncStreamReader {.
            deprecated: "`udata` deprecated, use inheritance instead".} =
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
                          ): AsyncStreamReader {.deprecated: "initSimpleVtbl".} =
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
                              udata: ref T): AsyncStreamReader {.
            deprecated: "`udata` deprecated, use inheritance instead".} =
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
                              udata: ref T): AsyncStreamReader {.
            deprecated: "`udata` deprecated, use inheritance instead".} =
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
                              udata: ref T): AsyncStreamWriter {.
            deprecated: "`udata` deprecated, use inheritance instead".} =
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
                          ): AsyncStreamWriter {.deprecated: "initSimpleVtbl".} =
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
                              udata: ref T): AsyncStreamWriter {.
            deprecated: "`udata` deprecated, use inheritance instead".} =
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
                              udata: ref T): AsyncStreamWriter {.
            deprecated: "`udata` deprecated, use inheritance instead".} =
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

proc getUserData*[T](rw: AsyncStreamRW): T {.inline, deprecated.} =
  ## Obtain user data associated with AsyncStreamReader or AsyncStreamWriter
  ## object ``rw``.
  cast[T](rw.udata)

proc setError*(rw: AsyncStreamRW, error: ref AsyncStreamError) =
  rw.state = AsyncStreamState.Error
  rw.error = error

proc setErrorAndRaise*(
    rw: AsyncStreamRW, error: ref AsyncStreamError
) {.noreturn, raises: [AsyncStreamError].} =
  # TODO there's probably no need to store the error here - after we raise the
  #      stream becomes defunct and the error can be dropped - this is just an
  #      intermediate solution not to change too much at once
  rw.state = AsyncStreamState.Error
  rw.error = error
  raise error

proc initSimpleVtbl*(
    T: type AsyncStreamReaderVtbl,
    readOnceImpl: ReadOnceProc,
    streamBufferSize = DefaultStreamBufferSize,
): T =
  template bufferedLoop(body: untyped): untyped =
    if rstream.buffer.isNil:
      rstream.buffer = AsyncBufferRef.new(streamBufferSize)
    while true:
      if len(rstream.buffer.backend) == 0:
        case rstream.state
        of Running:
          let (data, size) = rstream.buffer.backend.reserve()
          rstream.buffer.backend.commit(await readOnceImpl(rstream, data, size))
        of Error:
          let fut = newFuture[int]()
          fut.fail(rstream.error)
          return fut
        of Finished:
          let fut = newFuture[int]()
          fut.complete(0)
          return fut
        of Stopped, Closing, Closed:
          let fut = newFuture[int]()
          fut.fail(newAsyncStreamUseClosedError())
          return fut

      let (consumed, done) = body
      rstream.buffer.backend.consume(consumed)
      if done:
        break

  proc readOnceImplWrapper(
      rstream: AsyncStreamReader, pbytes: pointer, nbytes: int
  ): Future[int] {.async: (raises: [CancelledError, AsyncStreamError], raw: true).} =
    case rstream.state
    of Running:
      readOnceImpl(rstream, pbytes, nbytes)
    of Error:
      let fut = newFuture[int]()
      fut.fail(rstream.error)
      fut
    of Finished:
      let fut = newFuture[int]()
      fut.complete(0)
      fut
    of Stopped, Closing, Closed:
      let fut = newFuture[int]()
      fut.fail(newAsyncStreamUseClosedError())
      fut

  proc atEofImpl(rstream: AsyncStreamReader): bool =
    rstream.state != AsyncStreamState.Running
  proc stoppedImpl(rstream: AsyncStreamReader): bool =
    rstream.state == AsyncStreamState.Stopped
  proc runningImpl(rstream: AsyncStreamReader): bool =
    rstream.state == AsyncStreamState.Running
  proc failedImpl(rstream: AsyncStreamReader): bool =
    rstream.state == AsyncStreamState.Error

  proc readExactlyImpl(
      rstream: AsyncStreamReader, pbytes: pointer, nbytes: int
  ) {.async: (raises: [CancelledError, AsyncStreamError]).} =
    var
      pbuffer = cast[ptr byte](pbytes)
      k = 0

    while k < nbytes:
      let n = await readOnceImplWrapper(rstream, pbuffer, nbytes - k)
      if n == 0:
        raise newAsyncStreamIncompleteError()
      pbuffer = pbuffer.offset(n)
      k += n

  proc readUntilImpl(
      rstream: AsyncStreamReader, pbytes: pointer, nbytes: int, sep: seq[byte]
  ): Future[int] {.async: (raises: [CancelledError, AsyncStreamError]).} =
    var
      pbuffer = pbytes.toUnchecked()
      state = 0
      k = 0
    bufferedLoop:
      if rstream.atEof():
        raise newAsyncStreamIncompleteError()

      if k == nbytes:
        raise newAsyncStreamLimitError()

      let (n, found) =
        rstream.buffer.backend.copyUntil(pbuffer.toOpenArray(k, nbytes - 1), state, sep)
      k += n

      if not found and k == nbytes:
        raise newAsyncStreamLimitError()

      (n, found)

    k

  proc readLineImpl(
      rstream: AsyncStreamReader, limit = 0, sep = "\r\n"
  ): Future[string] {.async: (raises: [CancelledError, AsyncStreamError]).} =
    var
      res = ""
      state = 0

    bufferedLoop:
      if rstream.atEof():
        (0, true)
      else:
        rstream.buffer.backend.addLineInto(res, state, limit, sep)

    # TODO https://github.com/nim-lang/Nim/issues/25057
    move(res)

  proc readNImpl(
      rstream: AsyncStreamReader, n: int
  ): Future[seq[byte]] {.async: (raises: [CancelledError, AsyncStreamError]).} =
    var
      n = if n == 0: int.high else: n
      res = newSeqUninit[byte](min(n, 64 * 1024))
      total = 0
    while total < n:
      let b = await readOnceImplWrapper(rstream, addr res[total], res.len - total)
      if b == 0:
        break

      let newTotal = total + b
      if newTotal == res.len and newTotal < n:
        # TODO https://github.com/nim-lang/Nim/issues/25718
        var tmp = newSeqUninit[byte](min(res.len() + res.len(), n))
        copyMem(baseAddr tmp, baseAddr res, res.len)
        res = move(tmp)

      total = newTotal

    res.setLen(total)

    # TODO https://github.com/nim-lang/Nim/issues/25057
    move(res)

  proc readImpl(
      rstream: AsyncStreamReader
  ): Future[seq[byte]] {.async: (raises: [CancelledError, AsyncStreamError], raw: true).} =
    readNImpl(rstream, 0)

  proc consumeNImpl(
      rstream: AsyncStreamReader, n: int
  ): Future[int] {.async: (raises: [CancelledError, AsyncStreamError]).} =
    var
      tmp {.noinit.}: array[4096, byte]
      n = if n == 0: int.high else: n
      res: int
    while res < n:
      let b = await readOnceImplWrapper(rstream, addr tmp[0], min(tmp.len, n - res))
      if b == 0:
        break

      res += b

    res

  proc consumeImpl(
      rstream: AsyncStreamReader
  ): Future[int] {.async: (raises: [CancelledError, AsyncStreamError], raw: true).} =
    consumeNImpl(rstream, 0)

  proc readMessageImpl(
      rstream: AsyncStreamReader, pred: ReadMessagePredicate
  ) {.async: (raises: [CancelledError, AsyncStreamError]).} =
    bufferedLoop:
      if rstream.buffer.backend.len() == 0:
        pred([])
      else:
        var res: tuple[consumed: int, done: bool]
        for (region, rsize) in rstream.buffer.backend.regions:
          res = pred(region.toUnchecked().toOpenArray(0, rsize - 1))
          break
        res

  proc closeImpl(rstream: AsyncStreamReader) {.async: (raises: []).} =
    discard

  T(
    atEof: atEofImpl,
    stopped: stoppedImpl,
    running: runningImpl,
    failed: failedImpl,
    readExactly: readExactlyImpl,
    readOnce: readOnceImplWrapper,
    readUntil: readUntilImpl,
    readLine: readLineImpl,
    read: readImpl,
    readN: readNImpl,
    consume: consumeImpl,
    consumeN: consumeNImpl,
    readMessage: readMessageImpl,
    close: closeImpl,
  )

proc initSimpleVtbl*(
    T: type AsyncStreamWriterVtbl,
    writeImpl: WriteProc,
): T =
  proc writeImplWrapper(
      wstream: AsyncStreamWriter, pbytes: pointer, nbytes: int
  ) {.async: (raises: [CancelledError, AsyncStreamError], raw: true).} =
    case wstream.state
    of Running:
      writeImpl(wstream, pbytes, nbytes)
    of Error:
      let fut = newFuture[void]()
      fut.fail(wstream.error)
      fut
    of Stopped, Finished, Closing, Closed:
      let fut = newFuture[void]()
      fut.fail(newAsyncStreamUseClosedError())
      fut

  proc finishImpl(
    wstream: AsyncStreamWriter
  ) {.async: (raises: [CancelledError, AsyncStreamError]).} =
    wstream.state = AsyncStreamState.Finished

  AsyncStreamWriterVtbl(
    atEof: proc(wstream: AsyncStreamWriter): bool =
      wstream.state != AsyncStreamState.Running,
    stopped: proc(wstream: AsyncStreamWriter): bool =
      wstream.state == AsyncStreamState.Stopped,
    running: proc(wstream: AsyncStreamWriter): bool =
      wstream.state == AsyncStreamState.Running,
    failed: proc(wstream: AsyncStreamWriter): bool =
      wstream.state == AsyncStreamState.Error,
    write: writeImplWrapper,
    finish: finishImpl,
    close: proc(wstream: AsyncStreamWriter) {.async: (raises: []).} =
      discard,
  )

#
#            Chronos Asynchronous Streams
#             (c) Copyright 2019-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)
import ../asyncloop, ../asyncsync
import ../transports/common, ../transports/stream
export asyncsync, stream, common

const
  AsyncStreamDefaultBufferSize* = 4096
    ## Default reading stream internal buffer size.
  AsyncStreamDefaultQueueSize* = 0
    ## Default writing stream internal queue size.
  AsyncStreamReaderTrackerName* = "async.stream.reader"
    ## AsyncStreamReader leaks tracker name
  AsyncStreamWriterTrackerName* = "async.stream.writer"
    ## AsyncStreamWriter leaks tracker name

type
  AsyncBuffer* = object
    offset*: int
    buffer*: seq[byte]
    events*: array[2, AsyncEvent]

  WriteType* = enum
    Pointer, Sequence, String

  WriteItem* = object
    case kind*: WriteType
    of Pointer:
      data1*: pointer
    of Sequence:
      data2*: seq[byte]
    of String:
      data3*: string
    size*: int
    offset*: int
    future*: Future[void]

  AsyncStreamState* = enum
    Running,  ## Stream is online and working
    Error,    ## Stream has stored error
    Stopped,  ## Stream was closed while working
    Finished, ## Stream was properly finished
    Closed    ## Stream was closed

  StreamReaderLoop* = proc (stream: AsyncStreamReader): Future[void] {.gcsafe.}
    ## Main read loop for read streams.
  StreamWriterLoop* = proc (stream: AsyncStreamWriter): Future[void] {.gcsafe.}
    ## Main write loop for write streams.

  AsyncStreamReader* = ref object of RootRef
    rsource*: AsyncStreamReader
    tsource*: StreamTransport
    readerLoop*: StreamReaderLoop
    state*: AsyncStreamState
    buffer*: AsyncBuffer
    udata: pointer
    error*: ref Exception
    future: Future[void]

  AsyncStreamWriter* = ref object of RootRef
    wsource*: AsyncStreamWriter
    tsource*: StreamTransport
    writerLoop*: StreamWriterLoop
    state*: AsyncStreamState
    queue*: AsyncQueue[WriteItem]
    udata: pointer
    future: Future[void]

  AsyncStream* = object of RootObj
    reader*: AsyncStreamReader
    writer*: AsyncStreamWriter

  AsyncStreamTracker* = ref object of TrackerBase
    opened*: int64
    closed*: int64

  AsyncStreamRW* = AsyncStreamReader | AsyncStreamWriter

  AsyncStreamError* = object of CatchableError
  AsyncStreamIncompleteError* = object of AsyncStreamError
  AsyncStreamIncorrectError* = object of Defect
  AsyncStreamLimitError* = object of AsyncStreamError
  AsyncStreamReadError* = object of AsyncStreamError
    par*: ref Exception
  AsyncStreamWriteError* = object of AsyncStreamError
    par*: ref Exception

proc init*(t: typedesc[AsyncBuffer], size: int): AsyncBuffer =
  result.buffer = newSeq[byte](size)
  result.events[0] = newAsyncEvent()
  result.events[1] = newAsyncEvent()
  result.offset = 0

proc getBuffer*(sb: AsyncBuffer): pointer {.inline.} =
  result = unsafeAddr sb.buffer[sb.offset]

proc bufferLen*(sb: AsyncBuffer): int {.inline.} =
  result = len(sb.buffer) - sb.offset

proc getData*(sb: AsyncBuffer): pointer {.inline.} =
  result = unsafeAddr sb.buffer[0]

proc dataLen*(sb: AsyncBuffer): int {.inline.} =
  result = sb.offset

proc `[]`*(sb: AsyncBuffer, index: int): byte {.inline.} =
  doAssert(index < sb.offset)
  result = sb.buffer[index]

proc update*(sb: var AsyncBuffer, size: int) {.inline.} =
  sb.offset += size

proc wait*(sb: var AsyncBuffer): Future[void] =
  sb.events[0].clear()
  sb.events[1].fire()
  result = sb.events[0].wait()

proc transfer*(sb: var AsyncBuffer): Future[void] =
  sb.events[1].clear()
  sb.events[0].fire()
  result = sb.events[1].wait()

proc forget*(sb: var AsyncBuffer) {.inline.} =
  sb.events[1].clear()
  sb.events[0].fire()

proc shift*(sb: var AsyncBuffer, size: int) {.inline.} =
  if sb.offset > size:
    moveMem(addr sb.buffer[0], addr sb.buffer[size], sb.offset - size)
    sb.offset = sb.offset - size
  else:
    sb.offset = 0

proc copyData*(sb: AsyncBuffer, dest: pointer, offset, length: int) {.inline.} =
  copyMem(cast[pointer](cast[uint](dest) + cast[uint](offset)),
          unsafeAddr sb.buffer[0], length)

proc upload*(sb: ptr AsyncBuffer, pbytes: ptr byte,
             nbytes: int): Future[void] {.async.} =
  var length = nbytes
  while length > 0:
    let size = min(length, sb[].bufferLen())
    if size == 0:
      # Internal buffer is full, we need to transfer data to consumer.
      await sb[].transfer()
      continue
    else:
      copyMem(addr sb[].buffer[sb.offset], pbytes, size)
      sb[].offset = sb[].offset + size
      length = length - size
  # We notify consumers that new data is available.
  sb[].forget()

template toDataOpenArray*(sb: AsyncBuffer): auto =
  toOpenArray(sb.buffer, 0, sb.offset - 1)

template toBufferOpenArray*(sb: AsyncBuffer): auto =
  toOpenArray(sb.buffer, sb.offset, len(sb.buffer) - 1)

template copyOut*(dest: pointer, item: WriteItem, length: int) =
  if item.kind == Pointer:
    let p = cast[pointer](cast[uint](item.data1) + uint(item.offset))
    copyMem(dest, p, length)
  elif item.kind == Sequence:
    copyMem(dest, unsafeAddr item.data2[item.offset], length)
  elif item.kind == String:
    copyMem(dest, unsafeAddr item.data3[item.offset], length)

proc newAsyncStreamReadError(p: ref Exception): ref Exception {.inline.} =
  var w = newException(AsyncStreamReadError, "Read stream failed")
  w.msg = w.msg & ", originated from [" & $p.name & "] " & p.msg
  w.par = p
  result = w

proc newAsyncStreamWriteError(p: ref Exception): ref Exception {.inline.} =
  var w = newException(AsyncStreamWriteError, "Write stream failed")
  w.msg = w.msg & ", originated from [" & $p.name & "] " & p.msg
  w.par = p
  result = w

proc newAsyncStreamIncompleteError(): ref Exception {.inline.} =
  result = newException(AsyncStreamIncompleteError, "Incomplete data received")

proc newAsyncStreamLimitError(): ref Exception {.inline.} =
  result = newException(AsyncStreamLimitError, "Buffer limit reached")

proc newAsyncStreamIncorrectError(m: string): ref Exception {.inline.} =
  result = newException(AsyncStreamIncorrectError, m)

proc atEof*(rstream: AsyncStreamReader): bool =
  ## Returns ``true`` is reading stream is closed or finished and internal
  ## buffer do not have any bytes left.
  result = rstream.state in {AsyncStreamState.Stopped, Finished, Closed} and
           (rstream.buffer.dataLen() == 0)

proc atEof*(wstream: AsyncStreamWriter): bool =
  ## Returns ``true`` is writing stream ``wstream`` closed or finished.
  result = wstream.state in {AsyncStreamState.Stopped, Finished, Closed}

proc closed*(rw: AsyncStreamRW): bool {.inline.} =
  ## Returns ``true`` is reading/writing stream is closed.
  (rw.state == AsyncStreamState.Closed)

proc finished*(rw: AsyncStreamRW): bool {.inline.} =
  ## Returns ``true`` is reading/writing stream is finished (completed).
  (rw.state == AsyncStreamState.Finished)

proc stopped*(rw: AsyncStreamRW): bool {.inline.} =
  ## Returns ``true`` is reading/writing stream is stopped (interrupted).
  (rw.state == AsyncStreamState.Stopped)

proc running*(rw: AsyncStreamRW): bool {.inline.} =
  ## Returns ``true`` is reading/writing stream is still pending.
  (rw.state == AsyncStreamState.Running)

proc setupAsyncStreamReaderTracker(): AsyncStreamTracker {.gcsafe.}
proc setupAsyncStreamWriterTracker(): AsyncStreamTracker {.gcsafe.}

proc getAsyncStreamReaderTracker(): AsyncStreamTracker {.inline.} =
  result = cast[AsyncStreamTracker](getTracker(AsyncStreamReaderTrackerName))
  if isNil(result):
    result = setupAsyncStreamReaderTracker()

proc getAsyncStreamWriterTracker(): AsyncStreamTracker {.inline.} =
  result = cast[AsyncStreamTracker](getTracker(AsyncStreamWriterTrackerName))
  if isNil(result):
    result = setupAsyncStreamWriterTracker()

proc dumpAsyncStreamReaderTracking(): string {.gcsafe.} =
  var tracker = getAsyncStreamReaderTracker()
  result = "Opened async stream readers: " & $tracker.opened & "\n" &
           "Closed async stream readers: " & $tracker.closed

proc dumpAsyncStreamWriterTracking(): string {.gcsafe.} =
  var tracker = getAsyncStreamWriterTracker()
  result = "Opened async stream writers: " & $tracker.opened & "\n" &
           "Closed async stream writers: " & $tracker.closed

proc leakAsyncStreamReader(): bool {.gcsafe.} =
  var tracker = getAsyncStreamReaderTracker()
  result = tracker.opened != tracker.closed

proc leakAsyncStreamWriter(): bool {.gcsafe.} =
  var tracker = getAsyncStreamWriterTracker()
  result = tracker.opened != tracker.closed

proc trackAsyncStreamReader(t: AsyncStreamReader) {.inline.} =
  var tracker = getAsyncStreamReaderTracker()
  inc(tracker.opened)

proc untrackAsyncStreamReader*(t: AsyncStreamReader) {.inline.}  =
  var tracker = getAsyncStreamReaderTracker()
  inc(tracker.closed)

proc trackAsyncStreamWriter(t: AsyncStreamWriter) {.inline.} =
  var tracker = getAsyncStreamWriterTracker()
  inc(tracker.opened)

proc untrackAsyncStreamWriter*(t: AsyncStreamWriter) {.inline.}  =
  var tracker = getAsyncStreamWriterTracker()
  inc(tracker.closed)

proc setupAsyncStreamReaderTracker(): AsyncStreamTracker {.gcsafe.} =
  result = new AsyncStreamTracker
  result.opened = 0
  result.closed = 0
  result.dump = dumpAsyncStreamReaderTracking
  result.isLeaked = leakAsyncStreamReader
  addTracker(AsyncStreamReaderTrackerName, result)

proc setupAsyncStreamWriterTracker(): AsyncStreamTracker {.gcsafe.} =
  result = new AsyncStreamTracker
  result.opened = 0
  result.closed = 0
  result.dump = dumpAsyncStreamWriterTracking
  result.isLeaked = leakAsyncStreamWriter
  addTracker(AsyncStreamWriterTrackerName, result)

proc readExactly*(rstream: AsyncStreamReader, pbytes: pointer,
                  nbytes: int) {.async.} =
  ## Read exactly ``nbytes`` bytes from read-only stream ``rstream`` and store
  ## it to ``pbytes``.
  ##
  ## If EOF is received and ``nbytes`` is not yet readed, the procedure
  ## will raise ``AsyncStreamIncompleteError``.
  doAssert(not(isNil(pbytes)), "pbytes must not be nil")
  doAssert(nbytes >= 0, "nbytes must be non-negative integer")

  if nbytes == 0:
    return

  if not rstream.running():
    raise newAsyncStreamIncorrectError("Incorrect stream state")

  if isNil(rstream.rsource):
    try:
      await readExactly(rstream.tsource, pbytes, nbytes)
    except CancelledError:
      raise
    except TransportIncompleteError:
      raise newAsyncStreamIncompleteError()
    except CatchableError as exc:
      raise newAsyncStreamReadError(exc)
  else:
    if isNil(rstream.readerLoop):
      await readExactly(rstream.rsource, pbytes, nbytes)
    else:
      var index = 0
      while true:
        let datalen = rstream.buffer.dataLen()
        if rstream.state == Error:
          raise newAsyncStreamReadError(rstream.error)
        if datalen == 0 and rstream.atEof():
          raise newAsyncStreamIncompleteError()

        if datalen >= (nbytes - index):
          rstream.buffer.copyData(pbytes, index, nbytes - index)
          rstream.buffer.shift(nbytes - index)
          break
        else:
          rstream.buffer.copyData(pbytes, index, datalen)
          index += datalen
          rstream.buffer.shift(datalen)
        await rstream.buffer.wait()

proc readOnce*(rstream: AsyncStreamReader, pbytes: pointer,
               nbytes: int): Future[int] {.async.} =
  ## Perform one read operation on read-only stream ``rstream``.
  ##
  ## If internal buffer is not empty, ``nbytes`` bytes will be transferred from
  ## internal buffer, otherwise it will wait until some bytes will be received.
  doAssert(not(isNil(pbytes)), "pbytes must not be nil")
  doAssert(nbytes > 0, "nbytes must be positive value")

  if not rstream.running():
    raise newAsyncStreamIncorrectError("Incorrect stream state")

  if isNil(rstream.rsource):
    try:
      result = await readOnce(rstream.tsource, pbytes, nbytes)
    except CancelledError:
      raise
    except CatchableError as exc:
      raise newAsyncStreamReadError(exc)
  else:
    if isNil(rstream.readerLoop):
      result = await readOnce(rstream.rsource, pbytes, nbytes)
    else:
      while true:
        let datalen = rstream.buffer.dataLen()
        if rstream.state == Error:
          raise newAsyncStreamReadError(rstream.error)
        if datalen == 0:
          if rstream.atEof():
            result = 0
            break
          await rstream.buffer.wait()
        else:
          let size = min(datalen, nbytes)
          rstream.buffer.copyData(pbytes, 0, size)
          rstream.buffer.shift(size)
          result = size
          break

proc readUntil*(rstream: AsyncStreamReader, pbytes: pointer, nbytes: int,
                sep: seq[byte]): Future[int] {.async.} =
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

  if nbytes == 0:
    raise newAsyncStreamLimitError()

  if not rstream.running():
    raise newAsyncStreamIncorrectError("Incorrect stream state")

  if isNil(rstream.rsource):
    try:
      result = await readUntil(rstream.tsource, pbytes, nbytes, sep)
    except CancelledError:
      raise
    except TransportIncompleteError:
      raise newAsyncStreamIncompleteError()
    except TransportLimitError:
      raise newAsyncStreamLimitError()
    except CatchableError as exc:
      raise newAsyncStreamReadError(exc)
  else:
    if isNil(rstream.readerLoop):
      result = await readUntil(rstream.rsource, pbytes, nbytes, sep)
    else:
      var
        dest = cast[ptr UncheckedArray[byte]](pbytes)
        state = 0
        k = 0

      while true:
        let datalen = rstream.buffer.dataLen()
        if rstream.state == Error:
          raise newAsyncStreamReadError(rstream.error)
        if datalen == 0 and rstream.atEof():
          raise newAsyncStreamIncompleteError()

        var index = 0
        while index < datalen:
          let ch = rstream.buffer[index]
          if sep[state] == ch:
            inc(state)
          else:
            state = 0
          if k < nbytes:
            dest[k] = ch
            inc(k)
          else:
            raise newAsyncStreamLimitError()
          if state == len(sep):
            break
          inc(index)

        if state == len(sep):
          rstream.buffer.shift(index + 1)
          result = k
          break
        else:
          rstream.buffer.shift(datalen)
          await rstream.buffer.wait()

proc readLine*(rstream: AsyncStreamReader, limit = 0,
               sep = "\r\n"): Future[string] {.async.} =
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
  if not rstream.running():
    raise newAsyncStreamIncorrectError("Incorrect stream state")

  if isNil(rstream.rsource):
    try:
      result = await readLine(rstream.tsource, limit, sep)
    except CancelledError:
      raise
    except CatchableError as exc:
      raise newAsyncStreamReadError(exc)
  else:
    if isNil(rstream.readerLoop):
      result = await readLine(rstream.rsource, limit, sep)
    else:
      var res = ""
      var
        lim = if limit <= 0: -1 else: limit
        state = 0

      while true:
        let datalen = rstream.buffer.dataLen()
        if rstream.state == Error:
          raise newAsyncStreamReadError(rstream.error)
        if datalen == 0 and rstream.atEof():
          result = res
          break

        var index = 0
        while index < datalen:
          let ch = char(rstream.buffer[index])
          if sep[state] == ch:
            inc(state)
            if state == len(sep) or len(res) == lim:
              rstream.buffer.shift(index + 1)
              break
          else:
            state = 0
            res.add(ch)
            if len(res) == lim:
              rstream.buffer.shift(index + 1)
              break
          inc(index)

        if state == len(sep) or (lim == len(res)):
          result = res
          break
        else:
          rstream.buffer.shift(datalen)
          await rstream.buffer.wait()

proc read*(rstream: AsyncStreamReader, n = 0): Future[seq[byte]] {.async.} =
  ## Read all bytes (n <= 0) or exactly `n` bytes from read-only stream
  ## ``rstream``.
  ##
  ## This procedure allocates buffer seq[byte] and return it as result.
  if not rstream.running():
    raise newAsyncStreamIncorrectError("Incorrect stream state")

  if isNil(rstream.rsource):
    try:
      result = await read(rstream.tsource, n)
    except CancelledError:
      raise
    except CatchableError as exc:
      raise newAsyncStreamReadError(exc)
  else:
    if isNil(rstream.readerLoop):
      result = await read(rstream.rsource, n)
    else:
      var res = newSeq[byte]()
      while true:
        let datalen = rstream.buffer.dataLen()
        if rstream.state == Error:
          raise newAsyncStreamReadError(rstream.error)
        if datalen == 0 and rstream.atEof():
          result = res
          break

        if datalen > 0:
          let s = len(res)
          let o = s + datalen
          if n <= 0:
            res.setLen(o)
            rstream.buffer.copyData(addr res[s], 0, datalen)
            rstream.buffer.shift(datalen)
          else:
            let left = n - s
            if datalen >= left:
              res.setLen(n)
              rstream.buffer.copyData(addr res[s], 0, left)
              rstream.buffer.shift(left)
              result = res
              break
            else:
              res.setLen(o)
              rstream.buffer.copyData(addr res[s], 0, datalen)
              rstream.buffer.shift(datalen)

        await rstream.buffer.wait()

proc consume*(rstream: AsyncStreamReader, n = -1): Future[int] {.async.} =
  ## Consume (discard) all bytes (n <= 0) or ``n`` bytes from read-only stream
  ## ``rstream``.
  ##
  ## Return number of bytes actually consumed (discarded).
  if not rstream.running():
    raise newAsyncStreamIncorrectError("Incorrect stream state")

  if isNil(rstream.rsource):
    try:
      result = await consume(rstream.tsource, n)
    except CancelledError:
      raise
    except TransportLimitError:
      raise newAsyncStreamLimitError()
    except CatchableError as exc:
      raise newAsyncStreamReadError(exc)
  else:
    if isNil(rstream.readerLoop):
      result = await consume(rstream.rsource, n)
    else:
      var res = 0
      while true:
        let datalen = rstream.buffer.dataLen()
        if rstream.state == Error:
          raise newAsyncStreamReadError(rstream.error)
        if datalen == 0:
          if rstream.atEof():
            if n <= 0:
              result = res
              break
            else:
              raise newAsyncStreamLimitError()
        else:
          if n <= 0:
            res += datalen
            rstream.buffer.shift(datalen)
          else:
            let left = n - res
            if datalen >= left:
              res += left
              rstream.buffer.shift(left)
              result = res
              break
            else:
              res += datalen
              rstream.buffer.shift(datalen)

        await rstream.buffer.wait()

proc write*(wstream: AsyncStreamWriter, pbytes: pointer,
            nbytes: int) {.async.} =
  ## Write sequence of bytes pointed by ``pbytes`` of length ``nbytes`` to
  ## writer stream ``wstream``.
  ##
  ## ``nbytes` must be more then zero.
  if not wstream.running():
    raise newAsyncStreamIncorrectError("Incorrect stream state")
  if nbytes <= 0:
    raise newAsyncStreamIncorrectError("Zero length message")

  if isNil(wstream.wsource):
    var res: int
    try:
      res = await write(wstream.tsource, pbytes, nbytes)
    except CancelledError:
      raise
    except CatchableError as exc:
      raise newAsyncStreamWriteError(exc)
    if res != nbytes:
      raise newAsyncStreamIncompleteError()
  else:
    if isNil(wstream.writerLoop):
      await write(wstream.wsource, pbytes, nbytes)
    else:
      var item = WriteItem(kind: Pointer)
      item.data1 = pbytes
      item.size = nbytes
      item.future = newFuture[void]("async.stream.write(pointer)")
      await wstream.queue.put(item)
      try:
        await item.future
      except CancelledError:
        raise
      except:
        raise newAsyncStreamWriteError(item.future.error)

proc write*(wstream: AsyncStreamWriter, sbytes: seq[byte],
            msglen = -1) {.async.} =
  ## Write sequence of bytes ``sbytes`` of length ``msglen`` to writer
  ## stream ``wstream``.
  ##
  ## Sequence of bytes ``sbytes`` must not be zero-length.
  ##
  ## If ``msglen < 0`` whole sequence ``sbytes`` will be writen to stream.
  ## If ``msglen > len(sbytes)`` only ``len(sbytes)`` bytes will be written to
  ## stream.
  let length = if msglen <= 0: len(sbytes) else: min(msglen, len(sbytes))

  if not wstream.running():
    raise newAsyncStreamIncorrectError("Incorrect stream state")
  if length <= 0:
    raise newAsyncStreamIncorrectError("Zero length message")

  if isNil(wstream.wsource):
    var res: int
    try:
      res = await write(wstream.tsource, sbytes, msglen)
    except CancelledError:
      raise
    except CatchableError as exc:
      raise newAsyncStreamWriteError(exc)
    if res != length:
      raise newAsyncStreamIncompleteError()
  else:
    if isNil(wstream.writerLoop):
      await write(wstream.wsource, sbytes, msglen)
    else:
      var item = WriteItem(kind: Sequence)
      if not isLiteral(sbytes):
        shallowCopy(item.data2, sbytes)
      else:
        item.data2 = sbytes
      item.size = length
      item.future = newFuture[void]("async.stream.write(seq)")
      await wstream.queue.put(item)
      try:
        await item.future
      except CancelledError:
        raise
      except:
        raise newAsyncStreamWriteError(item.future.error)

proc write*(wstream: AsyncStreamWriter, sbytes: string,
            msglen = -1) {.async.} =
  ## Write string ``sbytes`` of length ``msglen`` to writer stream ``wstream``.
  ##
  ## String ``sbytes`` must not be zero-length.
  ##
  ## If ``msglen < 0`` whole string ``sbytes`` will be writen to stream.
  ## If ``msglen > len(sbytes)`` only ``len(sbytes)`` bytes will be written to
  ## stream.
  let length = if msglen <= 0: len(sbytes) else: min(msglen, len(sbytes))

  if not wstream.running():
    raise newAsyncStreamIncorrectError("Incorrect stream state")
  if length <= 0:
    raise newAsyncStreamIncorrectError("Zero length message")

  if isNil(wstream.wsource):
    var res: int
    try:
      res = await write(wstream.tsource, sbytes, msglen)
    except CancelledError:
      raise
    except CatchableError as exc:
      raise newAsyncStreamWriteError(exc)
    if res != length:
      raise newAsyncStreamIncompleteError()
  else:
    if isNil(wstream.writerLoop):
      await write(wstream.wsource, sbytes, msglen)
    else:
      var item = WriteItem(kind: String)
      if not isLiteral(sbytes):
        shallowCopy(item.data3, sbytes)
      else:
        item.data3 = sbytes
      item.size = length
      item.future = newFuture[void]("async.stream.write(string)")
      await wstream.queue.put(item)
      try:
        await item.future
      except CancelledError:
        raise
      except:
        raise newAsyncStreamWriteError(item.future.error)

proc finish*(wstream: AsyncStreamWriter) {.async.} =
  ## Finish write stream ``wstream``.
  if not wstream.running():
    raise newAsyncStreamIncorrectError("Incorrect stream state")

  if not isNil(wstream.wsource):
    if isNil(wstream.writerLoop):
      await wstream.wsource.finish()
    else:
      var item = WriteItem(kind: Pointer)
      item.size = 0
      item.future = newFuture[void]("async.stream.finish")
      await wstream.queue.put(item)
      try:
        await item.future
      except CancelledError:
        raise
      except:
        raise newAsyncStreamWriteError(item.future.error)

proc join*(rw: AsyncStreamRW): Future[void] =
  ## Get Future[void] which will be completed when stream become finished or
  ## closed.
  when rw is AsyncStreamReader:
    var retFuture = newFuture[void]("async.stream.reader.join")
  else:
    var retFuture = newFuture[void]("async.stream.writer.join")

  proc continuation(udata: pointer) {.gcsafe.} =
    retFuture.complete()

  proc cancel(udata: pointer) {.gcsafe.} =
    rw.future.removeCallback(continuation, cast[pointer](retFuture))

  if not(rw.future.finished()):
    rw.future.addCallback(continuation, cast[pointer](retFuture))
    rw.future.cancelCallback = cancel
  else:
    retFuture.complete()

  return retFuture

proc close*(rw: AsyncStreamRW) =
  ## Close and frees resources of stream ``rw``.
  ##
  ## Note close() procedure is not completed immediately!
  if rw.closed():
    raise newAsyncStreamIncorrectError("Stream is already closed!")

  rw.state = AsyncStreamState.Closed

  proc continuation(udata: pointer) =
    if not isNil(rw.udata):
      GC_unref(cast[ref int](rw.udata))
    if not(rw.future.finished()):
      rw.future.complete()
    when rw is AsyncStreamReader:
      untrackAsyncStreamReader(rw)
    elif rw is AsyncStreamWriter:
      untrackAsyncStreamWriter(rw)

  when rw is AsyncStreamReader:
    if isNil(rw.rsource) or isNil(rw.readerLoop) or isNil(rw.future):
      callSoon(continuation)
    else:
      if rw.future.finished():
        callSoon(continuation)
      else:
        rw.future.addCallback(continuation)
        rw.future.cancel()
  elif rw is AsyncStreamWriter:
    if isNil(rw.wsource) or isNil(rw.writerLoop) or isNil(rw.future):
      callSoon(continuation)
    else:
      if rw.future.finished():
        callSoon(continuation)
      else:
        rw.future.addCallback(continuation)
        rw.future.cancel()

proc closeWait*(rw: AsyncStreamRW): Future[void] =
  ## Close and frees resources of stream ``rw``.
  rw.close()
  result = rw.join()

proc startReader(rstream: AsyncStreamReader) =
  rstream.state = Running
  if not isNil(rstream.readerLoop):
    rstream.future = rstream.readerLoop(rstream)
  else:
    rstream.future = newFuture[void]("async.stream.empty.reader")

proc startWriter(wstream: AsyncStreamWriter) =
  wstream.state = Running
  if not isNil(wstream.writerLoop):
    wstream.future = wstream.writerLoop(wstream)
  else:
    wstream.future = newFuture[void]("async.stream.empty.writer")

proc init*(child, wsource: AsyncStreamWriter, loop: StreamWriterLoop,
           queueSize = AsyncStreamDefaultQueueSize) =
  ## Initialize newly allocated object ``child`` with AsyncStreamWriter
  ## parameters.
  child.writerLoop = loop
  child.wsource = wsource
  child.tsource = wsource.tsource
  child.queue = newAsyncQueue[WriteItem](queueSize)
  trackAsyncStreamWriter(child)
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
  trackAsyncStreamWriter(child)
  child.startWriter()

proc init*(child, rsource: AsyncStreamReader, loop: StreamReaderLoop,
           bufferSize = AsyncStreamDefaultBufferSize) =
  ## Initialize newly allocated object ``child`` with AsyncStreamReader
  ## parameters.
  child.readerLoop = loop
  child.rsource = rsource
  child.tsource = rsource.tsource
  child.buffer = AsyncBuffer.init(bufferSize)
  trackAsyncStreamReader(child)
  child.startReader()

proc init*[T](child, rsource: AsyncStreamReader, loop: StreamReaderLoop,
              bufferSize = AsyncStreamDefaultBufferSize,
              udata: ref T) =
  ## Initialize newly allocated object ``child`` with AsyncStreamReader
  ## parameters.
  child.readerLoop = loop
  child.rsource = rsource
  child.tsource = rsource.tsource
  child.buffer = AsyncBuffer.init(bufferSize)
  if not isNil(udata):
    GC_ref(udata)
    child.udata = cast[pointer](udata)
  trackAsyncStreamReader(child)
  child.startReader()

proc init*(child: AsyncStreamWriter, tsource: StreamTransport) =
  ## Initialize newly allocated object ``child`` with AsyncStreamWriter
  ## parameters.
  child.writerLoop = nil
  child.wsource = nil
  child.tsource = tsource
  trackAsyncStreamWriter(child)
  child.startWriter()

proc init*[T](child: AsyncStreamWriter, tsource: StreamTransport,
              udata: ref T) =
  ## Initialize newly allocated object ``child`` with AsyncStreamWriter
  ## parameters.
  child.writerLoop = nil
  child.wsource = nil
  child.tsource = tsource
  trackAsyncStreamWriter(child)
  child.startWriter()

proc init*(child, wsource: AsyncStreamWriter) =
  ## Initialize newly allocated object ``child`` with AsyncStreamWriter
  ## parameters.
  child.writerLoop = nil
  child.wsource = wsource
  child.tsource = wsource.tsource
  trackAsyncStreamWriter(child)
  child.startWriter()

proc init*[T](child, wsource: AsyncStreamWriter, udata: ref T) =
  ## Initialize newly allocated object ``child`` with AsyncStreamWriter
  ## parameters.
  child.writerLoop = nil
  child.wsource = wsource
  child.tsource = wsource.tsource
  if not isNil(udata):
    GC_ref(udata)
    child.udata = cast[pointer](udata)
  trackAsyncStreamWriter(child)
  child.startWriter()

proc init*(child: AsyncStreamReader, tsource: StreamTransport) =
  ## Initialize newly allocated object ``child`` with AsyncStreamReader
  ## parameters.
  child.readerLoop = nil
  child.rsource = nil
  child.tsource = tsource
  trackAsyncStreamReader(child)
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
  trackAsyncStreamReader(child)
  child.startReader()

proc init*(child, rsource: AsyncStreamReader) =
  ## Initialize newly allocated object ``child`` with AsyncStreamReader
  ## parameters.
  child.readerLoop = nil
  child.rsource = rsource
  child.tsource = rsource.tsource
  trackAsyncStreamReader(child)
  child.startReader()

proc init*[T](child, rsource: AsyncStreamReader, udata: ref T) =
  ## Initialize newly allocated object ``child`` with AsyncStreamReader
  ## parameters.
  child.readerLoop = nil
  child.rsource = rsource
  child.tsource = rsource.tsource
  if not isNil(udata):
    GC_ref(udata)
    child.udata = cast[pointer](udata)
  trackAsyncStreamReader(child)
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
  result = new AsyncStreamReader
  result.init(rsource, loop, bufferSize, udata)

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
  result = new AsyncStreamReader
  result.init(rsource, loop, bufferSize)

proc newAsyncStreamReader*[T](tsource: StreamTransport,
                              udata: ref T): AsyncStreamReader =
  ## Create new AsyncStreamReader object, which will use stream transport
  ## ``tsource`` as source data channel.
  ##
  ## ``udata`` - user object which will be associated with new AsyncStreamWriter
  ## object.
  result = new AsyncStreamReader
  result.init(tsource, udata)

proc newAsyncStreamReader*(tsource: StreamTransport): AsyncStreamReader =
  ## Create new AsyncStreamReader object, which will use stream transport
  ## ``tsource`` as source data channel.
  result = new AsyncStreamReader
  result.init(tsource)

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
  result = new AsyncStreamWriter
  result.init(wsource, loop, queueSize, udata)

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
  result = new AsyncStreamWriter
  result.init(wsource, loop, queueSize)

proc newAsyncStreamWriter*[T](tsource: StreamTransport,
                              udata: ref T): AsyncStreamWriter =
  ## Create new AsyncStreamWriter object which will use stream transport
  ## ``tsource`` as  data channel.
  ##
  ## ``udata`` - user object which will be associated with new AsyncStreamWriter
  ## object.
  result = new AsyncStreamWriter
  result.init(tsource, udata)

proc newAsyncStreamWriter*(tsource: StreamTransport): AsyncStreamWriter =
  ## Create new AsyncStreamWriter object which will use stream transport
  ## ``tsource`` as data channel.
  result = new AsyncStreamWriter
  result.init(tsource)

proc newAsyncStreamWriter*[T](wsource: AsyncStreamWriter,
                              udata: ref T): AsyncStreamWriter =
  ## Create copy of AsyncStreamWriter object ``wsource``.
  ##
  ## ``udata`` - user object which will be associated with new AsyncStreamWriter
  ## object.
  result = new AsyncStreamWriter
  result.init(wsource, udata)

proc newAsyncStreamWriter*(wsource: AsyncStreamWriter): AsyncStreamWriter =
  ## Create copy of AsyncStreamWriter object ``wsource``.
  result = new AsyncStreamWriter
  result.init(wsource)

proc newAsyncStreamReader*[T](rsource: AsyncStreamWriter,
                              udata: ref T): AsyncStreamWriter =
  ## Create copy of AsyncStreamReader object ``rsource``.
  ##
  ## ``udata`` - user object which will be associated with new AsyncStreamReader
  ## object.
  result = new AsyncStreamReader
  result.init(rsource, udata)

proc newAsyncStreamReader*(rsource: AsyncStreamReader): AsyncStreamReader =
  ## Create copy of AsyncStreamReader object ``rsource``.
  result = new AsyncStreamReader
  result.init(rsource)

proc getUserData*[T](rw: AsyncStreamRW): T {.inline.} =
  ## Obtain user data associated with AsyncStreamReader or AsyncStreamWriter
  ## object ``rw``.
  result = cast[T](rw.udata)

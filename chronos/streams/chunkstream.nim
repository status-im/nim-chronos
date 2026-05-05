#
#    Chronos Asynchronous Chunked-Encoding Stream
#             (c) Copyright 2019-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

## This module implements HTTP/1.1 chunked-encoded stream reading and writing.

{.push raises: [].}

import stew/ptrops
import ../[asyncloop, timer, bipbuffer, config]
import asyncstream, ../transports/[stream, common]
import results
export asyncloop, asyncstream, stream, timer, common, results

const
  ChunkBufferSize = chronosStreamDefaultBufferSize
  MaxChunkHeaderSize = 64
  ChunkHeaderValueSize = 8
    # This is limit for chunk size to 8 hexadecimal digits, so maximum
    # chunk size for this implementation become:
    # 2^32 == FFFF_FFFF'u32 == 4,294,967,295 bytes.
  CRLF = @[byte(0x0D), byte(0x0A)]

type
  ChunkedStreamReader* = ref object of AsyncStreamReader
    chunkSize: uint64
    endOfChunk: bool

  ChunkedStreamWriter* = ref object of AsyncStreamWriter
    lock: AsyncLock

  ChunkedStreamError* = object of AsyncStreamError
  ChunkedStreamProtocolError* = object of ChunkedStreamError
  ChunkedStreamIncompleteError* = object of ChunkedStreamError

proc `-`(x: uint32): uint32 {.inline.} =
  result = (0xFFFF_FFFF'u32 - x) + 1'u32

proc LT(x, y: uint32): uint32 {.inline.} =
  let z = x - y
  (z xor ((y xor x) and (y xor z))) shr 31

proc hexValue*(c: byte): int =
  # This is nim adaptation of
  # https://github.com/pornin/CTTK/blob/master/src/hex.c#L28-L52
  let x = uint32(c) - 0x30'u32
  let y = uint32(c) - 0x41'u32
  let z = uint32(c) - 0x61'u32
  let r = ((x + 1'u32) and -LT(x, 10)) or
          ((y + 11'u32) and -LT(y, 6)) or
          ((z + 11'u32) and -LT(z, 6))
  int(r) - 1

proc getChunkSize(buffer: openArray[byte]): Result[uint64, cstring] =
  # We using `uint64` representation, but allow only 2^32 chunk size,
  # ChunkHeaderValueSize.
  var res = 0'u64
  for i in 0 ..< min(len(buffer), ChunkHeaderValueSize + 1):
    let value = hexValue(buffer[i])
    if value < 0:
      if buffer[i] == byte(';'):
        # chunk-extension is present, so chunk size is already decoded in res.
        return ok(res)
      else:
        return err("Incorrect chunk size encoding")
    else:
      if i >= ChunkHeaderValueSize:
        return err("The chunk size exceeds the limit")
      res = (res shl 4) or uint64(value)
  ok(res)

proc setChunkSize(buffer: var openArray[byte], length: int64): int =
  # Store length as chunk header size (hexadecimal value) with CRLF.
  # Maximum stored value is ``0xFFFF_FFFF``.
  # Buffer ``buffer`` length must be at least 10 octets.
  doAssert(length <= int64(uint32.high))
  var n = 0xF000_0000'i64
  var i = 32
  var c = 0
  if length == 0:
    buffer[0] = byte('0')
    buffer[1] = byte(0x0D)
    buffer[2] = byte(0x0A)
    3
  else:
    while n != 0:
      var v = length and n
      if v != 0 or c != 0:
        let digit = byte((length and n) shr (i - 4))
        var ch = digit + byte('0')
        if ch > byte('9'):
          ch = ch + 0x07'u8
        buffer[c] = ch
        inc(c)
      n = n shr 4
      i = i - 4
    buffer[c] = byte(0x0D)
    buffer[c + 1] = byte(0x0A)
    (c + 2)

proc readCrlf(
    rstream: ChunkedStreamReader
): Future[Result[void, cstring]] {.async: (raises: [CancelledError, AsyncStreamError]).} =
  try:
    var buffer: array[2, byte]
    await rstream.rsource.readExactly(addr buffer[0], buffer.len)
    if buffer == CRLF:
      ok()
    else:
      err("Expected end-of-chunk marker")
  except AsyncStreamIncompleteError:
    err("Missing end-of-chunk marker")

proc readHeader(
    rstream: ChunkedStreamReader
): Future[Result[uint64, cstring]] {.
    async: (raises: [CancelledError, AsyncStreamError])
.} =
  var buffer: array[MaxChunkHeaderSize, byte]

  if rstream.endOfChunk:
    ?(await rstream.readCrlf())
  else:
    # subsequent calls will read the end-of-chunk marker
    rstream.endOfChunk = true

  # Reading chunk size
  let
    res =
      try:
        await rstream.rsource.readUntil(addr buffer[0], len(buffer), CRLF)
      except AsyncStreamLimitError:
        return err("Chunk header exceeds maximum size")
    chunkSize = ?getChunkSize(buffer.toOpenArray(0, res - len(CRLF) - 1))

  if chunkSize == 0'u64:
    # Reading trailing line for last chunk
    ?(await rstream.readCrlf())
    rstream.endOfChunk = false
  ok chunkSize

proc readOnce(
    rstream: ChunkedStreamReader, pbytes: pointer, nbytes: int
): Future[int] {.async: (raises: [CancelledError, AsyncStreamError]).} =
  if rstream.chunkSize == 0:
    rstream.chunkSize =
      try:
        await(rstream.readHeader()).valueOr:
          rstream.setErrorAndRaise(newException(ChunkedStreamProtocolError, $error))
      except CancelledError as exc:
        rstream.state = AsyncStreamState.Stopped
        raise exc
      except AsyncStreamError as exc:
        rstream.setErrorAndRaise(exc)

    if rstream.chunkSize == 0:
      rstream.state = AsyncStreamState.Finished
      return 0

  let bytes =
    try:
      await rstream.rsource.readOnce(pbytes, min(rstream.chunkSize, nbytes.uint64).int)
    except CancelledError as exc:
      rstream.state = AsyncStreamState.Stopped
      raise exc
    except AsyncStreamError as exc:
      rstream.setErrorAndRaise(exc)
  if bytes == 0:
    rstream.setErrorAndRaise(
      newException(ChunkedStreamIncompleteError, "Incomplete chunk received")
    )
  rstream.chunkSize -= bytes.uint64

  bytes

proc initReaderVtbl(bufferSize: int): AsyncStreamReaderVtbl =
  proc readOnceImpl(
      rstream: AsyncStreamReader, pbytes: pointer, nbytes: int
  ): Future[int] {.async: (raises: [CancelledError, AsyncStreamError], raw: true).} =
    ChunkedStreamReader(rstream).readOnce(pbytes, nbytes)

  var res = AsyncStreamReaderVtbl.initSimpleVtbl(readOnceImpl, bufferSize)

  res

proc init*[T](child: ChunkedStreamReader, rsource: AsyncStreamReader,
              bufferSize = ChunkBufferSize, udata: ref T) {.
            deprecated: "`udata` deprecated, use inheritance instead".} =
  child.initUdata(udata)
  child.init(rsource, bufferSize)

proc init*(child: ChunkedStreamReader, rsource: AsyncStreamReader,
           bufferSize = ChunkBufferSize) =
  var vtbl = initReaderVtbl(bufferSize)
  child.rsource = rsource
  init(AsyncStreamReader(child), vtbl)


proc newChunkedStreamReader*[T](rsource: AsyncStreamReader,
                                bufferSize = AsyncStreamDefaultBufferSize,
                                udata: ref T): ChunkedStreamReader {.
            deprecated: "`udata` deprecated, use inheritance instead".} =
  var res = ChunkedStreamReader()
  res.init(rsource, bufferSize, udata)
  res

proc newChunkedStreamReader*(rsource: AsyncStreamReader,
                             bufferSize = AsyncStreamDefaultBufferSize,
                            ): ChunkedStreamReader =
  var res = ChunkedStreamReader()
  res.init(rsource, bufferSize)
  res

proc write(
    wstream: ChunkedStreamWriter,
    pbytes: pointer,
    nbytes: int,
) {.async: (raises: [CancelledError, AsyncStreamError]).} =
  await wstream.lock.acquire() # Avoid interleaving writes
  try:
    var buffer: array[16, byte]

    let length = setChunkSize(buffer, int64(nbytes))

    # Writing chunk header: <length>CRLF
    await wstream.wsource.write(addr buffer[0], length)
    # Writing chunk data.
    await wstream.wsource.write(pbytes, nbytes)
    # Writing chunk footer: CRLF
    await wstream.wsource.write(CRLF)
  except CancelledError as exc:
    wstream.state = AsyncStreamState.Stopped
    raise exc
  except AsyncStreamError as exc:
    wstream.setErrorAndRaise(exc)
  finally:
    try:
      wstream.lock.release()
    except AsyncLockError:
      raiseAssert "just locked"

proc finish(
    wstream: ChunkedStreamWriter,
) {.async: (raises: [CancelledError, AsyncStreamError]).} =
  await wstream.lock.acquire() # Avoid interleaving writes

  try:
    var buffer: array[16, byte]
    let length = setChunkSize(buffer, 0)

    # Writing chunk header <length>CRLF.
    await wstream.wsource.write(addr buffer[0], length)
    # Writing chunk footer CRLF.
    await wstream.wsource.write(CRLF)
  except CancelledError as exc:
    wstream.state = AsyncStreamState.Stopped
    raise exc
  except AsyncStreamError as exc:
    wstream.state = AsyncStreamState.Error
    wstream.error = exc
    raise exc
  finally:
    try:
      wstream.lock.release()
    except AsyncLockError:
      raiseAssert "just locked"

proc initWriterVtbl(): AsyncStreamWriterVtbl =
  var res = AsyncStreamWriterVtbl.initSimpleVtbl(
    proc(
        wstream: AsyncStreamWriter, pbytes: pointer, nbytes: int
    ) {.async: (raises: [CancelledError, AsyncStreamError], raw: true).} =
      ChunkedStreamWriter(wstream).write(pbytes, nbytes)
  )

  res.finish = proc(
      wstream: AsyncStreamWriter
  ) {.async: (raises: [CancelledError, AsyncStreamError], raw: true).} =
    ChunkedStreamWriter(wstream).finish()

  res

proc init*[T](child: ChunkedStreamWriter, wsource: AsyncStreamWriter,
              queueSize = AsyncStreamDefaultQueueSize, udata: ref T) {.
            deprecated: "`udata` deprecated, use inheritance instead".} =
  let vtbl = initWriterVtbl()
  child.wsource = wsource
  init(AsyncStreamWriter(child), vtbl, udata)

proc init*(child: ChunkedStreamWriter, wsource: AsyncStreamWriter,
           queueSize = AsyncStreamDefaultQueueSize) =
  let vtbl = initWriterVtbl()
  child.wsource = wsource
  init(AsyncStreamWriter(child), vtbl)

proc newChunkedStreamWriter*[T](wsource: AsyncStreamWriter,
                                queueSize = AsyncStreamDefaultQueueSize,
                                udata: ref T): ChunkedStreamWriter {.
            deprecated: "`udata` deprecated, use inheritance instead".} =
  var res = ChunkedStreamWriter(lock: newAsyncLock())
  res.init(wsource, queueSize, udata)
  res

proc newChunkedStreamWriter*(wsource: AsyncStreamWriter,
                             queueSize = AsyncStreamDefaultQueueSize,
                            ): ChunkedStreamWriter =
  var res = ChunkedStreamWriter(lock: newAsyncLock())
  res.init(wsource, queueSize)
  res

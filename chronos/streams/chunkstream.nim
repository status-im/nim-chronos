#
#    Chronos Asynchronous Chunked-Encoding Stream
#             (c) Copyright 2019-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

## This module implements HTTP/1.1 chunked-encoded stream reading and writing.
import ../asyncloop, ../timer
import asyncstream, ../transports/stream, ../transports/common
export asyncstream, stream, timer, common

const
  ChunkBufferSize = 4096
  ChunkHeaderSize = 8
  CRLF = @[byte(0x0D), byte(0x0A)]

type
  ChunkedStreamReader* = ref object of AsyncStreamReader
  ChunkedStreamWriter* = ref object of AsyncStreamWriter

  ChunkedStreamError* = object of AsyncStreamError
  ChunkedStreamProtocolError* = object of ChunkedStreamError
  ChunkedStreamIncompleteError* = object of ChunkedStreamError

proc newChunkedProtocolError(): ref ChunkedStreamProtocolError {.inline.} =
  newException(ChunkedStreamProtocolError, "Protocol error!")

proc newChunkedIncompleteError(): ref ChunkedStreamIncompleteError {.inline.} =
  newException(ChunkedStreamIncompleteError, "Incomplete data received!")

proc `-`(x: uint32): uint32 {.inline.} =
  result = (0xFFFF_FFFF'u32 - x) + 1'u32

proc LT(x, y: uint32): uint32 {.inline.} =
  let z = x - y
  (z xor ((y xor x) and (y xor z))) shr 31

proc hexValue(c: byte): int =
  let x = uint32(c) - 0x30'u32
  let y = uint32(c) - 0x41'u32
  let z = uint32(c) - 0x61'u32
  let r = ((x + 1'u32) and -LT(x, 10)) or
          ((y + 11'u32) and -LT(y, 6)) or
          ((z + 11'u32) and -LT(z, 6))
  int(r) - 1

proc getChunkSize(buffer: openarray[byte]): uint64 =
  # We using `uint64` representation, but allow only 2^32 chunk size,
  # ChunkHeaderSize.
  var res = 0'u64
  for i in 0..<min(len(buffer), ChunkHeaderSize):
    let value = hexValue(buffer[i])
    if value >= 0:
      res = (res shl 4) or uint64(value)
    else:
      res = 0xFFFF_FFFF_FFFF_FFFF'u64
      break
  res

proc setChunkSize(buffer: var openarray[byte], length: int64): int =
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
    c + 2

proc chunkedReadLoop(stream: AsyncStreamReader) {.async.} =
  var rstream = cast[ChunkedStreamReader](stream)
  var buffer = newSeq[byte](1024)
  rstream.state = AsyncStreamState.Running

  while true:
    try:
      # Reading chunk size
      let res = await rstream.rsource.readUntil(addr buffer[0], 1024, CRLF)
      var chunksize = getChunkSize(buffer.toOpenArray(0, res - len(CRLF) - 1))

      if chunksize == 0xFFFF_FFFF_FFFF_FFFF'u64:
        rstream.error = newChunkedProtocolError()
        rstream.state = AsyncStreamState.Error
      elif chunksize > 0'u64:
        while chunksize > 0'u64:
          let toRead = min(int(chunksize), rstream.buffer.bufferLen())
          await rstream.rsource.readExactly(rstream.buffer.getBuffer(), toRead)
          rstream.buffer.update(toRead)
          await rstream.buffer.transfer()
          chunksize = chunksize - uint64(toRead)

        if rstream.state == AsyncStreamState.Running:
          # Reading chunk trailing CRLF
          await rstream.rsource.readExactly(addr buffer[0], 2)

          if buffer[0] != CRLF[0] or buffer[1] != CRLF[1]:
            rstream.error = newChunkedProtocolError()
            rstream.state = AsyncStreamState.Error
      else:
        # Reading trailing line for last chunk
        discard await rstream.rsource.readUntil(addr buffer[0],
                                                len(buffer), CRLF)
        rstream.state = AsyncStreamState.Finished
        await rstream.buffer.transfer()
    except CancelledError:
      rstream.state = AsyncStreamState.Stopped
    except AsyncStreamIncompleteError:
      rstream.state = AsyncStreamState.Error
      rstream.error = newChunkedIncompleteError()
    except AsyncStreamReadError as exc:
      rstream.state = AsyncStreamState.Error
      rstream.error = exc

    if rstream.state in {AsyncStreamState.Stopped, AsyncStreamState.Error}:
      # We need to notify consumer about error/close, but we do not care about
      # incoming data anymore.
      rstream.buffer.forget()
      break

proc chunkedWriteLoop(stream: AsyncStreamWriter) {.async.} =
  var wstream = cast[ChunkedStreamWriter](stream)
  var buffer: array[16, byte]
  var error: ref AsyncStreamError
  wstream.state = AsyncStreamState.Running

  while true:
    var item: WriteItem
    # Getting new item from stream's queue.
    try:
      item = await wstream.queue.get()
      # `item.size == 0` is marker of stream finish, while `item.size != 0` is
      # data's marker.
      if item.size > 0:
        let length = setChunkSize(buffer, int64(item.size))
        # Writing chunk header <length>CRLF.
        await wstream.wsource.write(addr buffer[0], length)
        # Writing chunk data.
        case item.kind
        of WriteType.Pointer:
          await wstream.wsource.write(item.data1, item.size)
        of WriteType.Sequence:
          await wstream.wsource.write(addr item.data2[0], item.size)
        of WriteType.String:
          await wstream.wsource.write(addr item.data3[0], item.size)
        # Writing chunk footer CRLF.
        await wstream.wsource.write(CRLF)
        # Everything is fine, completing queue item's future.
        item.future.complete()
      else:
        let length = setChunkSize(buffer, 0'i64)
        # Write finish chunk `0`.
        await wstream.wsource.write(addr buffer[0], length)
        # Write trailing CRLF.
        await wstream.wsource.write(CRLF)
        # Everything is fine, completing queue item's future.
        item.future.complete()
        # Set stream state to Finished.
        wstream.state = AsyncStreamState.Finished
    except CancelledError:
      wstream.state = AsyncStreamState.Stopped
      error = newAsyncStreamUseClosedError()
    except AsyncStreamError as exc:
      wstream.state = AsyncStreamState.Error
      error = exc

    if wstream.state != AsyncStreamState.Running:
      if wstream.state == AsyncStreamState.Finished:
        error = newAsyncStreamUseClosedError()
      else:
        if not(isNil(item.future)):
          if not(item.future.finished()):
            item.future.fail(error)
      while not(wstream.queue.empty()):
        let pitem = wstream.queue.popFirstNoWait()
        if not(pitem.future.finished()):
          pitem.future.fail(error)
      break

proc init*[T](child: ChunkedStreamReader, rsource: AsyncStreamReader,
              bufferSize = ChunkBufferSize, udata: ref T) =
  init(cast[AsyncStreamReader](child), rsource, chunkedReadLoop, bufferSize,
       udata)

proc init*(child: ChunkedStreamReader, rsource: AsyncStreamReader,
           bufferSize = ChunkBufferSize) =
  init(cast[AsyncStreamReader](child), rsource, chunkedReadLoop, bufferSize)

proc newChunkedStreamReader*[T](rsource: AsyncStreamReader,
                                bufferSize = AsyncStreamDefaultBufferSize,
                                udata: ref T): ChunkedStreamReader =
  var res = ChunkedStreamReader()
  res.init(rsource, bufferSize, udata)
  res

proc newChunkedStreamReader*(rsource: AsyncStreamReader,
                             bufferSize = AsyncStreamDefaultBufferSize,
                            ): ChunkedStreamReader =
  var res = ChunkedStreamReader()
  res.init(rsource, bufferSize)
  res

proc init*[T](child: ChunkedStreamWriter, wsource: AsyncStreamWriter,
              queueSize = AsyncStreamDefaultQueueSize, udata: ref T) =
  init(cast[AsyncStreamWriter](child), wsource, chunkedWriteLoop, queueSize,
       udata)

proc init*(child: ChunkedStreamWriter, wsource: AsyncStreamWriter,
           queueSize = AsyncStreamDefaultQueueSize) =
  init(cast[AsyncStreamWriter](child), wsource, chunkedWriteLoop, queueSize)

proc newChunkedStreamWriter*[T](wsource: AsyncStreamWriter,
                                queueSize = AsyncStreamDefaultQueueSize,
                                udata: ref T): ChunkedStreamWriter =
  var res = ChunkedStreamWriter()
  res.init(wsource, queueSize, udata)
  res

proc newChunkedStreamWriter*(wsource: AsyncStreamWriter,
                             queueSize = AsyncStreamDefaultQueueSize,
                            ): ChunkedStreamWriter =
  var res = ChunkedStreamWriter()
  res.init(wsource, queueSize)
  res

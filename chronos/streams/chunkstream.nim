#
#    Chronos Asynchronous Chunked-Encoding Stream
#             (c) Copyright 2019-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)
import ../asyncloop, ../timer
import asyncstream, ../transports/stream, ../transports/common
export asyncstream, stream, timer, common

const
  ChunkBufferSize = 4096
  ChunkHeaderSize = 8
  ChunkDefaultTimeout = 10.seconds
  CRLF = @[byte(0x0D), byte(0x0A)]

type
  ChunkedStreamReader* = ref object of AsyncStreamReader
    timeout: Duration

  ChunkedStreamWriter* = ref object of AsyncStreamWriter

  ChunkedStreamError* = object of Exception
  ChunkedStreamTimeoutError* = object of ChunkedStreamError
  ChunkedStreamProtocolError* = object of ChunkedStreamError

proc newTimeoutError(): ref Exception {.inline.} =
  newException(ChunkedStreamTimeoutError, "Timeout exceeded!")

proc newProtocolError(): ref Exception {.inline.} =
  newException(ChunkedStreamProtocolError, "Protocol error!")

proc oneOf*[A, B, C](fut1: Future[A], fut2: Future[B],
                     fut3: Future[C]): Future[void] =
  ## Wait for completion of one future from list [`fut1`, `fut2`, `fut3`],
  ## resulting future do not care about futures error, so you need to check
  ## `fut1`, `fut2`, `fut3` for error manually.
  var retFuture = newFuture[void]("chunked.oneOf()")
  proc cb(data: pointer) {.gcsafe.} =
    var index: int
    if not retFuture.finished:
      var fut = cast[FutureBase](data)
      if cast[pointer](fut1) == data:
        fut2.removeCallback(cb)
        fut3.removeCallback(cb)
      elif cast[pointer](fut2) == data:
        fut1.removeCallback(cb)
        fut3.removeCallback(cb)
      elif cast[pointer](fut3) == data:
        fut2.removeCallback(cb)
        fut3.removeCallback(cb)
      retFuture.complete()
  fut1.callback = cb
  fut2.callback = cb
  fut3.callback = cb
  return retFuture

proc oneOf*[A, B](fut1: Future[A], fut2: Future[B]): Future[void] =
  ## Wait for completion of `fut1` or `fut2`, resulting future do not care about
  ## error, so you need to check `fut1` and `fut2` for error.
  var retFuture = newFuture[void]("chunked.oneOf()")
  proc cb(data: pointer) {.gcsafe.} =
    var index: int
    if not retFuture.finished:
      var fut = cast[FutureBase](data)
      if cast[pointer](fut1) == data:
        fut2.removeCallback(cb)
      elif cast[pointer](fut2) == data:
        fut1.removeCallback(cb)
      retFuture.complete()
  fut1.callback = cb
  fut2.callback = cb
  return retFuture

proc getChunkSize(buffer: openarray[byte]): uint64 =
  # We using `uint64` representation, but allow only 2^32 chunk size,
  # ChunkHeaderSize.
  for i in 0..<min(len(buffer), ChunkHeaderSize):
    let ch = buffer[i]
    if char(ch) in {'0'..'9', 'a'..'f', 'A'..'F'}:
      if ch >= byte('0') and ch <= byte('9'):
        result = (result shl 4) or uint64(ch - byte('0'))
      else:
        result = (result shl 4) or uint64((ch and 0x0F) + 9)
    else:
      result = 0xFFFF_FFFF_FFFF_FFFF'u64
      break

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
    result = 3
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
    result = c + 2

proc chunkedReadLoop(stream: AsyncStreamReader) {.async.} =
  var rstream = cast[ChunkedStreamReader](stream)
  var exitFut = rstream.exevent.wait()
  var buffer = newSeq[byte](1024)
  var timerFut: Future[void]

  if rstream.timeout == InfiniteDuration:
    timerFut = newFuture[void]()

  while true:
    if rstream.timeout != InfiniteDuration:
      timerFut = sleepAsync(rstream.timeout)

    # Reading chunk size
    var ruFut1 = rstream.rsource.readUntil(addr buffer[0], 1024, CRLF)
    await oneOf(ruFut1, timerFut, exitFut)

    if exitFut.finished or timerFut.finished:
      if timerFut.finished:
        rstream.error = newTimeoutError()
        rstream.state = AsyncStreamState.Error
      else:
        rstream.state = AsyncStreamState.Stopped
      break

    if ruFut1.failed:
      rstream.error = ruFut1.error
      rstream.state = AsyncStreamState.Error
      break

    let length = ruFut1.read()
    var chunksize = getChunkSize(buffer.toOpenArray(0, length - len(CRLF) - 1))

    if chunksize == 0xFFFF_FFFF_FFFF_FFFF'u64:
      rstream.error = newProtocolError()
      rstream.state = AsyncStreamState.Error
      break
    elif chunksize > 0'u64:
      while chunksize > 0'u64:
        let toRead = min(int(chunksize), rstream.buffer.bufferLen())
        var reFut2 = rstream.rsource.readExactly(rstream.buffer.getBuffer(),
                                                 toRead)
        await oneOf(reFut2, timerFut, exitFut)

        if exitFut.finished or timerFut.finished:
          if timerFut.finished:
            rstream.error = newTimeoutError()
            rstream.state = AsyncStreamState.Error
          else:
            rstream.state = AsyncStreamState.Stopped
          break

        if reFut2.failed:
          rstream.error = reFut2.error
          rstream.state = AsyncStreamState.Error
          break

        rstream.buffer.update(toRead)
        await rstream.buffer.transfer() or exitFut
        if exitFut.finished:
          rstream.state = AsyncStreamState.Stopped
          break

        chunksize = chunksize - uint64(toRead)

      if rstream.state != AsyncStreamState.Running:
        break

      # Reading chunk trailing CRLF
      var reFut3 = rstream.rsource.readExactly(addr buffer[0], 2)
      await oneOf(reFut3, timerFut, exitFut)
      if exitFut.finished or timerFut.finished:
        if timerFut.finished:
          rstream.error = newTimeoutError()
          rstream.state = AsyncStreamState.Error
        else:
          rstream.state = AsyncStreamState.Stopped
        break

      if reFut3.failed:
        rstream.error = reFut3.error
        rstream.state = AsyncStreamState.Error
        break

      if buffer[0] != CRLF[0] or buffer[1] != CRLF[1]:
        rstream.error = newProtocolError()
        rstream.state = AsyncStreamState.Error
        break
    else:
      # Reading trailing line for last chunk
      var ruFut4 = rstream.rsource.readUntil(addr buffer[0], len(buffer), CRLF)
      await oneOf(ruFut4, timerFut, exitFut)

      if exitFut.finished or timerFut.finished:
        if timerFut.finished:
          rstream.error = newTimeoutError()
          rstream.state = AsyncStreamState.Error
        else:
          rstream.state = AsyncStreamState.Stopped
        break

      if ruFut4.failed:
        rstream.error = ruFut4.error
        rstream.state = AsyncStreamState.Error
        break

      rstream.state = AsyncStreamState.Finished
      await rstream.buffer.transfer() or exitFut
      if exitFut.finished:
        rstream.state = AsyncStreamState.Stopped
      break

  if rstream.state in {AsyncStreamState.Stopped, AsyncStreamState.Error}:
    # We need to notify consumer about error/close, but we do not care about
    # incoming data anymore.
    rstream.buffer.forget()

  untrackAsyncStreamReader(rstream)

proc chunkedWriteLoop(stream: AsyncStreamWriter) {.async.} =
  var wstream = cast[ChunkedStreamWriter](stream)
  var exitFut = wstream.exevent.wait()
  var buffer: array[16, byte]
  var error: ref Exception
  var wFut1, wFut2, wFut3: Future[void]

  wstream.state = AsyncStreamState.Running
  while true:
    # Getting new item from stream's queue.
    var getFut = wstream.queue.get()
    await oneOf(getFut, exitFut)
    if exitFut.finished:
      wstream.state = AsyncStreamState.Stopped
      break
    var item = getFut.read()
    # `item.size == 0` is marker of stream finish, while `item.size != 0` is
    # data's marker.
    if item.size > 0:
      let length = setChunkSize(buffer, int64(item.size))
      # Writing chunk header <length>CRLF.
      wFut1 = wstream.wsource.write(addr buffer[0], length)
      await oneOf(wFut1, exitFut)

      if exitFut.finished:
        wstream.state = AsyncStreamState.Stopped
        break

      if wFut1.failed:
        item.future.fail(wFut1.error)
        continue

      # Writing chunk data.
      if item.kind == Pointer:
        wFut2 = wstream.wsource.write(item.data1, item.size)
      elif item.kind == Sequence:
        wFut2 = wstream.wsource.write(addr item.data2[0], item.size)
      elif item.kind == String:
        wFut2 = wstream.wsource.write(addr item.data3[0], item.size)

      await oneOf(wFut2, exitFut)
      if exitFut.finished:
        wstream.state = AsyncStreamState.Stopped
        break

      if wFut2.failed:
        item.future.fail(wFut2.error)
        continue

      # Writing chunk footer CRLF.
      var wFut3 = wstream.wsource.write(CRLF)
      await oneOf(wFut3, exitFut)
      if exitFut.finished:
        wstream.state = AsyncStreamState.Stopped
        break

      if wFut3.failed:
        item.future.fail(wFut3.error)
        continue

      # Everything is fine, completing queue item's future.
      item.future.complete()
    else:
      let length = setChunkSize(buffer, 0'i64)

      # Write finish chunk `0`.
      wFut1 = wstream.wsource.write(addr buffer[0], length)
      await oneOf(wFut1, exitFut)
      if exitFut.finished:
        wstream.state = AsyncStreamState.Stopped
        break

      if wFut1.failed:
        item.future.fail(wFut1.error)
        # We break here, because this is last chunk
        break

      # Write trailing CRLF.
      wFut2 = wstream.wsource.write(CRLF)
      await oneOf(wFut2, exitFut)

      if exitFut.finished:
        wstream.state = AsyncStreamState.Stopped
        break

      if wFut2.failed:
        item.future.fail(wFut2.error)
        # We break here, because this is last chunk
        break

      # Everything is fine, completing queue item's future.
      item.future.complete()

      # Set stream state to Finished.
      wstream.state = AsyncStreamState.Finished
      break

  untrackAsyncStreamWriter(wstream)

proc init*[T](child: ChunkedStreamReader, rsource: AsyncStreamReader,
              bufferSize = ChunkBufferSize, timeout = ChunkDefaultTimeout,
              udata: ref T) =
  child.timeout = timeout
  init(cast[AsyncStreamReader](child), rsource, chunkedReadLoop, bufferSize,
       udata)

proc init*(child: ChunkedStreamReader, rsource: AsyncStreamReader,
           bufferSize = ChunkBufferSize, timeout = ChunkDefaultTimeout) =
  child.timeout = timeout
  init(cast[AsyncStreamReader](child), rsource, chunkedReadLoop, bufferSize)

proc newChunkedStreamReader*[T](rsource: AsyncStreamReader,
                                bufferSize = AsyncStreamDefaultBufferSize,
                                timeout = ChunkDefaultTimeout,
                                udata: ref T): ChunkedStreamReader =
  result = new ChunkedStreamReader
  result.init(rsource, bufferSize, timeout, udata)

proc newChunkedStreamReader*(rsource: AsyncStreamReader,
                             bufferSize = AsyncStreamDefaultBufferSize,
                             timeout = ChunkDefaultTimeout,
                            ): ChunkedStreamReader =
  result = new ChunkedStreamReader
  result.init(rsource, bufferSize, timeout)

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
  result = new ChunkedStreamWriter
  result.init(wsource, queueSize, udata)

proc newChunkedStreamWriter*(wsource: AsyncStreamWriter,
                             queueSize = AsyncStreamDefaultQueueSize,
                            ): ChunkedStreamWriter =
  result = new ChunkedStreamWriter
  result.init(wsource, queueSize)

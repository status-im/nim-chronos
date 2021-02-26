#
#         Chronos Asynchronous Bound Stream
#             (c) Copyright 2021-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

## This module implements bounded stream reading and writing.
##
## For stream reading it means that you should read exactly bounded size of
## bytes or you should read all bytes until specific boundary.
##
## For stream writing it means that you should write exactly bounded size
## of bytes.
import ../asyncloop, ../timer
import asyncstream, ../transports/stream, ../transports/common
export asyncstream, stream, timer, common

type
  BoundCmp* {.pure.} = enum
    Equal, LessOrEqual

  BoundedStreamReader* = ref object of AsyncStreamReader
    boundSize: int
    boundary: seq[byte]
    offset: int
    cmpop: BoundCmp

  BoundedStreamWriter* = ref object of AsyncStreamWriter
    boundSize: int
    offset: int
    cmpop: BoundCmp

  BoundedStreamError* = object of AsyncStreamError
  BoundedStreamIncompleteError* = object of BoundedStreamError
  BoundedStreamOverflowError* = object of BoundedStreamError

  BoundedStreamRW* = BoundedStreamReader | BoundedStreamWriter

const
  BoundedBufferSize* = 4096

proc newBoundedStreamIncompleteError*(): ref BoundedStreamError {.noinline.} =
  newException(BoundedStreamIncompleteError,
               "Stream boundary is not reached yet")

proc readUntilBoundary*(rstream: AsyncStreamReader, pbytes: pointer,
                        nbytes: int, sep: seq[byte]): Future[int] {.async.} =
  doAssert(not(isNil(pbytes)), "pbytes must not be nil")
  doAssert(nbytes >= 0, "nbytes must be non-negative value")
  checkStreamClosed(rstream)

  if nbytes == 0:
    return 0

  var k = 0
  var state = 0
  var pbuffer = cast[ptr UncheckedArray[byte]](pbytes)

  proc predicate(data: openarray[byte]): tuple[consumed: int, done: bool] =
    if len(data) == 0:
      (0, true)
    else:
      var index = 0
      while index < len(data):
        if k >= nbytes:
          return (index, true)
        let ch = data[index]
        inc(index)
        pbuffer[k] = ch
        inc(k)
        if len(sep) > 0:
          if sep[state] == ch:
            inc(state)
            if state == len(sep):
              break
          else:
            state = 0
      (index, (state == len(sep)) or (k == nbytes))

  await rstream.readMessage(predicate)
  return k

func endsWith(s, suffix: openarray[byte]): bool =
  var i = 0
  var j = len(s) - len(suffix)
  while i + j >= 0 and i + j < len(s):
    if s[i + j] != suffix[i]: return false
    inc(i)
  if i >= len(suffix): return true

proc boundedReadLoop(stream: AsyncStreamReader) {.async.} =
  var rstream = BoundedStreamReader(stream)
  rstream.state = AsyncStreamState.Running
  var buffer = newSeq[byte](rstream.buffer.bufferLen())
  while true:
    # r1 is `true` if `boundSize` was not set.
    let r1 = rstream.boundSize < 0
    # r2 is `true` if number of bytes read is less then `boundSize`.
    let r2 = (rstream.boundSize > 0) and (rstream.offset < rstream.boundSize)
    if r1 or r2:
      let toRead =
        if rstream.boundSize < 0:
          len(buffer)
        else:
          min(rstream.boundSize - rstream.offset, len(buffer))
      try:
        let res = await readUntilBoundary(rstream.rsource, addr buffer[0],
                                          toRead, rstream.boundary)
        if res > 0:
          if len(rstream.boundary) > 0:
            if endsWith(buffer.toOpenArray(0, res - 1), rstream.boundary):
              let length = res - len(rstream.boundary)
              rstream.offset = rstream.offset + length
              await upload(addr rstream.buffer, addr buffer[0], length)
              rstream.state = AsyncStreamState.Finished
            else:
              if (res < toRead) and rstream.rsource.atEof():
                case rstream.cmpop
                of BoundCmp.Equal:
                  rstream.state = AsyncStreamState.Error
                  rstream.error = newBoundedStreamIncompleteError()
                of BoundCmp.LessOrEqual:
                  rstream.state = AsyncStreamState.Finished
              rstream.offset = rstream.offset + res
              await upload(addr rstream.buffer, addr buffer[0], res)
          else:
            if (res < toRead) and rstream.rsource.atEof():
              case rstream.cmpop
              of BoundCmp.Equal:
                rstream.state = AsyncStreamState.Error
                rstream.error = newBoundedStreamIncompleteError()
              of BoundCmp.LessOrEqual:
                rstream.state = AsyncStreamState.Finished
            rstream.offset = rstream.offset + res
            await upload(addr rstream.buffer, addr buffer[0], res)
        else:
          case rstream.cmpop
          of BoundCmp.Equal:
            rstream.state = AsyncStreamState.Error
            rstream.error = newBoundedStreamIncompleteError()
          of BoundCmp.LessOrEqual:
            rstream.state = AsyncStreamState.Finished

      except AsyncStreamReadError as exc:
        rstream.state = AsyncStreamState.Error
        rstream.error = exc
      except CancelledError:
        rstream.state = AsyncStreamState.Stopped

      if rstream.state != AsyncStreamState.Running:
        if rstream.state == AsyncStreamState.Finished:
          # This is state when BoundCmp.LessOrEqual and readExactly returned
          # `AsyncStreamIncompleteError`.
          await rstream.buffer.transfer()
        break
    else:
      rstream.state = AsyncStreamState.Finished
      break

  # We need to notify consumer about error/close, but we do not care about
  # incoming data anymore.
  rstream.buffer.forget()

proc boundedWriteLoop(stream: AsyncStreamWriter) {.async.} =
  var wstream = BoundedStreamWriter(stream)

  wstream.state = AsyncStreamState.Running
  while true:
    var
      item: WriteItem
      error: ref AsyncStreamError

    try:
      item = await wstream.queue.get()
      if item.size > 0:
        if item.size <= (wstream.boundSize - wstream.offset):
          # Writing chunk data.
          case item.kind
          of WriteType.Pointer:
            await wstream.wsource.write(item.dataPtr, item.size)
          of WriteType.Sequence:
            await wstream.wsource.write(addr item.dataSeq[0], item.size)
          of WriteType.String:
            await wstream.wsource.write(addr item.dataStr[0], item.size)
          wstream.offset = wstream.offset + item.size
          item.future.complete()
        else:
          wstream.state = AsyncStreamState.Error
          error = newException(BoundedStreamOverflowError,
                               "Stream boundary exceeded")
      else:
        if wstream.offset != wstream.boundSize:
          case wstream.cmpop
          of BoundCmp.Equal:
            wstream.state = AsyncStreamState.Error
            error = newBoundedStreamIncompleteError()
          of BoundCmp.LessOrEqual:
            wstream.state = AsyncStreamState.Finished
            item.future.complete()
        else:
          wstream.state = AsyncStreamState.Finished
          item.future.complete()
    except CancelledError:
      wstream.state = AsyncStreamState.Stopped
      error = newAsyncStreamUseClosedError()
    except AsyncStreamWriteError as exc:
      wstream.state = AsyncStreamState.Error
      error = exc
    except AsyncStreamIncompleteError as exc:
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

proc bytesLeft*(stream: BoundedStreamRW): uint64 =
  ## Returns number of bytes left in stream.
  uint64(stream.boundSize) - stream.bytesCount

proc init*[T](child: BoundedStreamReader, rsource: AsyncStreamReader,
              bufferSize = BoundedBufferSize, udata: ref T) =
  init(AsyncStreamReader(child), rsource, boundedReadLoop, bufferSize,
       udata)

proc init*(child: BoundedStreamReader, rsource: AsyncStreamReader,
           bufferSize = BoundedBufferSize) =
  init(AsyncStreamReader(child), rsource, boundedReadLoop, bufferSize)

proc newBoundedStreamReader*[T](rsource: AsyncStreamReader,
                                boundSize: int,
                                boundary: openarray[byte] = [],
                                comparison = BoundCmp.Equal,
                                bufferSize = BoundedBufferSize,
                                udata: ref T): BoundedStreamReader =
  doAssert(not(boundSize <= 0 and (len(boundary) == 0)),
           "At least one type of boundary should be set")
  var res = BoundedStreamReader(boundSize: boundSize, boundary: @boundary,
                                cmpop: comparison)
  res.init(rsource, bufferSize, udata)
  res

proc newBoundedStreamReader*(rsource: AsyncStreamReader,
                             boundSize: int,
                             boundary: openarray[byte] = [],
                             comparison = BoundCmp.Equal,
                             bufferSize = BoundedBufferSize,
                             ): BoundedStreamReader =
  doAssert(not(boundSize <= 0 and (len(boundary) == 0)),
           "At least one type of boundary should be set")
  var res = BoundedStreamReader(boundSize: boundSize, boundary: @boundary,
                                cmpop: comparison)
  res.init(rsource, bufferSize)
  res

proc init*[T](child: BoundedStreamWriter, wsource: AsyncStreamWriter,
              queueSize = AsyncStreamDefaultQueueSize, udata: ref T) =
  init(AsyncStreamWriter(child), wsource, boundedWriteLoop, queueSize,
       udata)

proc init*(child: BoundedStreamWriter, wsource: AsyncStreamWriter,
           queueSize = AsyncStreamDefaultQueueSize) =
  init(AsyncStreamWriter(child), wsource, boundedWriteLoop, queueSize)

proc newBoundedStreamWriter*[T](wsource: AsyncStreamWriter,
                                boundSize: int,
                                comparison = BoundCmp.Equal,
                                queueSize = AsyncStreamDefaultQueueSize,
                                udata: ref T): BoundedStreamWriter =
  doAssert(boundSize > 0, "Bound size must be bigger then zero")
  var res = BoundedStreamWriter(boundSize: boundSize, cmpop: comparison)
  res.init(wsource, queueSize, udata)
  res

proc newBoundedStreamWriter*(wsource: AsyncStreamWriter,
                             boundSize: int,
                             comparison = BoundCmp.Equal,
                             queueSize = AsyncStreamDefaultQueueSize,
                             ): BoundedStreamWriter =
  doAssert(boundSize > 0, "Bound size must be bigger then zero")
  var res = BoundedStreamWriter(boundSize: boundSize, cmpop: comparison)
  res.init(wsource, queueSize)
  res

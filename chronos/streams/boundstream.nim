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
  BoundedStreamReader* = ref object of AsyncStreamReader
    boundSize: int
    boundary: seq[byte]
    offset: int

  BoundedStreamWriter* = ref object of AsyncStreamWriter
    boundSize: int
    offset: int

  BoundedStreamError* = object of AsyncStreamError
  BoundedStreamIncompleteError* = object of BoundedStreamError
  BoundedStreamOverflowError* = object of BoundedStreamError

  BoundedStreamRW* = BoundedStreamReader | BoundedStreamWriter

const
  BoundedBufferSize* = 4096

template newBoundedStreamIncompleteError*(): ref BoundedStreamError =
  newException(BoundedStreamIncompleteError,
               "Stream boundary is not reached yet")
template newBoundedStreamOverflowError*(): ref BoundedStreamError =
  newException(BoundedStreamOverflowError, "Stream boundary exceeded")

proc readUntilBoundary*(rstream: AsyncStreamReader, pbytes: pointer,
                        nbytes: int, sep: seq[byte]): Future[int] {.async.} =
  doAssert(not(isNil(pbytes)), "pbytes must not be nil")
  doAssert(len(sep) > 0, "separator must not be empty")
  doAssert(nbytes >= 0, "nbytes must be non-negative value")
  checkStreamClosed(rstream)

  var k = 0
  var state = 0
  var pbuffer = cast[ptr UncheckedArray[byte]](pbytes)
  var error: ref AsyncStreamIncompleteError

  proc predicate(data: openarray[byte]): tuple[consumed: int, done: bool] =
    if len(data) == 0:
      error = newAsyncStreamIncompleteError()
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
        if sep[state] == ch:
          inc(state)
          if state == len(sep):
            break
        else:
          state = 0
      (index, state == len(sep) or (k == nbytes))

  await rstream.readMessage(predicate)
  if not isNil(error):
    raise error
  else:
    return k

func endsWith(s, suffix: openarray[byte]): bool =
  var i = 0
  var j = len(s) - len(suffix)
  while i + j >= 0 and i + j < len(s):
    if s[i + j] != suffix[i]: return false
    inc(i)
  if i >= len(suffix): return true

proc boundedReadLoop(stream: AsyncStreamReader) {.async.} =
  var rstream = cast[BoundedStreamReader](stream)
  rstream.state = AsyncStreamState.Running
  var buffer = newSeq[byte](rstream.buffer.bufferLen())
  while true:
    if len(rstream.boundary) == 0:
      # Only size boundary set
      if rstream.offset < rstream.boundSize:
        let toRead = min(rstream.boundSize - rstream.offset,
                         rstream.buffer.bufferLen())
        try:
          await rstream.rsource.readExactly(rstream.buffer.getBuffer(), toRead)
          rstream.offset = rstream.offset + toRead
          rstream.buffer.update(toRead)
          await rstream.buffer.transfer()
        except AsyncStreamIncompleteError:
          rstream.state = AsyncStreamState.Error
          rstream.error = newBoundedStreamIncompleteError()
        except AsyncStreamReadError as exc:
          rstream.state = AsyncStreamState.Error
          rstream.error = exc
        except CancelledError:
          rstream.state = AsyncStreamState.Stopped

        if rstream.state != AsyncStreamState.Running:
          break
      else:
        rstream.state = AsyncStreamState.Finished
        await rstream.buffer.transfer()
        break
    else:
      # Sequence boundary set
      if ((rstream.boundSize >= 0) and (rstream.offset < rstream.boundSize)) or
         (rstream.boundSize < 0):
        let toRead =
          if rstream.boundSize < 0:
            len(buffer)
          else:
            min(rstream.boundSize - rstream.offset, len(buffer))
        try:
          let res = await readUntilBoundary(rstream.rsource, addr buffer[0],
                                            toRead, rstream.boundary)
          if endsWith(buffer.toOpenArray(0, res - 1), rstream.boundary):
            let length = res - len(rstream.boundary)
            rstream.offset = rstream.offset + length
            await upload(addr rstream.buffer, addr buffer[0], length)
            rstream.state = AsyncStreamState.Finished
          else:
            rstream.offset = rstream.offset + res
            await upload(addr rstream.buffer, addr buffer[0], res)
        except AsyncStreamIncompleteError:
          rstream.state = AsyncStreamState.Error
          rstream.error = newBoundedStreamIncompleteError()
        except AsyncStreamReadError as exc:
          rstream.state = AsyncStreamState.Error
          rstream.error = exc
        except CancelledError:
          rstream.state = AsyncStreamState.Stopped

        if rstream.state != AsyncStreamState.Running:
          break
      else:
        rstream.state = AsyncStreamState.Finished
        break

  # Without this additional wait, procedures such as `read()` could got stuck
  # in `await.buffer.wait()` because procedures are unable to detect EOF while
  # inside readLoop body.
  await stepsAsync(1)
  # We need to notify consumer about error/close, but we do not care about
  # incoming data anymore.
  rstream.buffer.forget()

proc boundedWriteLoop(stream: AsyncStreamWriter) {.async.} =
  var wstream = cast[BoundedStreamWriter](stream)

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
            await wstream.wsource.write(item.data1, item.size)
          of WriteType.Sequence:
            await wstream.wsource.write(addr item.data2[0], item.size)
          of WriteType.String:
            await wstream.wsource.write(addr item.data3[0], item.size)
          wstream.offset = wstream.offset + item.size
          item.future.complete()
        else:
          wstream.state = AsyncStreamState.Error
          error = newBoundedStreamOverflowError()
      else:
        if wstream.offset != wstream.boundSize:
          wstream.state = AsyncStreamState.Error
          error = newBoundedStreamIncompleteError()
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
  stream.boundSize - stream.bytesCount

proc init*[T](child: BoundedStreamReader, rsource: AsyncStreamReader,
              bufferSize = BoundedBufferSize, udata: ref T) =
  init(cast[AsyncStreamReader](child), rsource, boundedReadLoop, bufferSize,
       udata)

proc init*(child: BoundedStreamReader, rsource: AsyncStreamReader,
           bufferSize = BoundedBufferSize) =
  init(cast[AsyncStreamReader](child), rsource, boundedReadLoop, bufferSize)

proc newBoundedStreamReader*[T](rsource: AsyncStreamReader,
                                boundSize: int,
                                boundary: openarray[byte] = [],
                                bufferSize = BoundedBufferSize,
                                udata: ref T): BoundedStreamReader =
  doAssert(boundSize >= 0 or len(boundary) > 0,
           "At least one type of boundary should be set")
  var res = BoundedStreamReader(boundSize: boundSize, boundary: @boundary)
  res.init(rsource, bufferSize, udata)
  res

proc newBoundedStreamReader*(rsource: AsyncStreamReader,
                             boundSize: int,
                             boundary: openarray[byte] = [],
                             bufferSize = BoundedBufferSize,
                             ): BoundedStreamReader =
  doAssert(boundSize >= 0 or len(boundary) > 0,
           "At least one type of boundary should be set")
  var res = BoundedStreamReader(boundSize: boundSize, boundary: @boundary)
  res.init(rsource, bufferSize)
  res

proc init*[T](child: BoundedStreamWriter, wsource: AsyncStreamWriter,
              queueSize = AsyncStreamDefaultQueueSize, udata: ref T) =
  init(cast[AsyncStreamWriter](child), wsource, boundedWriteLoop, queueSize,
       udata)

proc init*(child: BoundedStreamWriter, wsource: AsyncStreamWriter,
           queueSize = AsyncStreamDefaultQueueSize) =
  init(cast[AsyncStreamWriter](child), wsource, boundedWriteLoop, queueSize)

proc newBoundedStreamWriter*[T](wsource: AsyncStreamWriter,
                                boundSize: int,
                                queueSize = AsyncStreamDefaultQueueSize,
                                udata: ref T): BoundedStreamWriter =
  var res = BoundedStreamWriter(boundSize: boundSize)
  res.init(wsource, queueSize, udata)
  res

proc newBoundedStreamWriter*(wsource: AsyncStreamWriter,
                             boundSize: int,
                             queueSize = AsyncStreamDefaultQueueSize,
                             ): BoundedStreamWriter =
  var res = BoundedStreamWriter(boundSize: boundSize)
  res.init(wsource, queueSize)
  res

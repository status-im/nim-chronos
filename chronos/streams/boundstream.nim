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
## bytes.
##
## For stream writing it means that you should write exactly bounded size
## of bytes, and if you wrote not enough bytes error will appear on stream
## close.
import ../asyncloop, ../timer
import asyncstream, ../transports/stream, ../transports/common
export asyncstream, stream, timer, common

type
  BoundedStreamReader* = ref object of AsyncStreamReader
    boundSize: uint64
    offset: uint64

  BoundedStreamWriter* = ref object of AsyncStreamWriter
    boundSize: uint64
    offset: uint64

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

proc boundedReadLoop(stream: AsyncStreamReader) {.async.} =
  var rstream = cast[BoundedStreamReader](stream)
  rstream.state = AsyncStreamState.Running
  while true:
    if rstream.offset < rstream.boundSize:
      let toRead = int(min(rstream.boundSize - rstream.offset,
                           uint64(rstream.buffer.bufferLen())))
      try:
        await rstream.rsource.readExactly(rstream.buffer.getBuffer(), toRead)
        rstream.offset = rstream.offset + uint64(toRead)
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

  if rstream.state in {AsyncStreamState.Stopped, AsyncStreamState.Error}:
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
        if uint64(item.size) <= (wstream.boundSize - wstream.offset):
          # Writing chunk data.
          case item.kind
          of WriteType.Pointer:
            await wstream.wsource.write(item.data1, item.size)
          of WriteType.Sequence:
            await wstream.wsource.write(addr item.data2[0], item.size)
          of WriteType.String:
            await wstream.wsource.write(addr item.data3[0], item.size)
          wstream.offset = wstream.offset + uint64(item.size)
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
                                boundSize: uint64,
                                bufferSize = BoundedBufferSize,
                                udata: ref T): BoundedStreamReader =
  var res = BoundedStreamReader(boundSize: boundSize)
  res.init(rsource, bufferSize, udata)
  res

proc newBoundedStreamReader*(rsource: AsyncStreamReader,
                             boundSize: uint64,
                             bufferSize = BoundedBufferSize,
                             ): BoundedStreamReader =
  doAssert(boundSize >= 0)
  var res = BoundedStreamReader(boundSize: boundSize)
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
                                boundSize: uint64,
                                queueSize = AsyncStreamDefaultQueueSize,
                                udata: ref T): BoundedStreamWriter =
  var res = BoundedStreamWriter(boundSize: boundSize)
  res.init(wsource, queueSize, udata)
  res

proc newBoundedStreamWriter*(wsource: AsyncStreamWriter,
                             boundSize: uint64,
                             queueSize = AsyncStreamDefaultQueueSize,
                             ): BoundedStreamWriter =
  var res = BoundedStreamWriter(boundSize: boundSize)
  res.init(wsource, queueSize)
  res

proc close*(rw: BoundedStreamRW) =
  ## Close and frees resources of stream ``rw``.
  ##
  ## Note close() procedure is not completed immediately.
  if rw.closed():
    raise newAsyncStreamIncorrectError("Stream is already closed!")
  # We do not want to raise one more IncompleteError if it was already raised
  # by one of the read()/write() primitives.
  if rw.state != AsyncStreamState.Error:
    if rw.bytesLeft() != 0'u64:
      raise newBoundedStreamIncompleteError()
  when rw is BoundedStreamReader:
    cast[AsyncStreamReader](rw).close()
  elif rw is BoundedStreamWriter:
    cast[AsyncStreamWriter](rw).close()

proc closeWait*(rw: BoundedStreamRW): Future[void] =
  ## Close and frees resources of stream ``rw``.
  rw.close()
  when rw is BoundedStreamReader:
    cast[AsyncStreamReader](rw).join()
  elif rw is BoundedStreamWriter:
    cast[AsyncStreamWriter](rw).join()

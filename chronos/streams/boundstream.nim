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

{.push raises: [].}

import stew/shims/sequninit
import results
import ../[asyncloop, timer, bipbuffer, config]
import asyncstream, ../transports/[stream, common]
export asyncloop, asyncstream, stream, timer, common

type
  BoundCmp* {.pure.} = enum
    Equal, LessOrEqual

  BoundedStreamReader* = ref object of AsyncStreamReader
    boundSize: Opt[uint64]
    boundary: seq[byte]
    offset: uint64
    cmpop: BoundCmp
    bstate: int
      # the number of boundary bytes that been matched so far

  BoundedStreamWriter* = ref object of AsyncStreamWriter
    boundSize: uint64
    offset: uint64
    cmpop: BoundCmp

  BoundedStreamError* = object of AsyncStreamError
  BoundedStreamIncompleteError* = object of BoundedStreamError
  BoundedStreamOverflowError* = object of BoundedStreamError

  BoundedStreamRW* = BoundedStreamReader | BoundedStreamWriter

const
  BoundedBufferSize* = chronosStreamDefaultBufferSize
  BoundarySizeDefectMessage = "Boundary must not be empty array"

template newBoundedStreamIncompleteError(): ref BoundedStreamError =
  newException(BoundedStreamIncompleteError, "Stream boundary is not reached yet")

template newBoundedStreamOverflowError(): ref BoundedStreamOverflowError =
  newException(BoundedStreamOverflowError, "Stream boundary exceeded")

proc readUntilBoundary(
    rstream: BoundedStreamReader, pbytes: pointer, nbytes: int
): Future[int] {.async: (raises: [CancelledError, AsyncStreamError]).} =
  doAssert(not(isNil(pbytes)), "pbytes must not be nil")
  doAssert(nbytes > 0, "nbytes must be positive")

  var k = 0
  var pbuffer = cast[ptr UncheckedArray[byte]](pbytes)

  proc predicateSep(data: openArray[byte]): tuple[consumed: int, done: bool] =
    if len(data) == 0:
      if rstream.bstate < rstream.boundary.len:
        for c in rstream.boundary.toOpenArray(0, rstream.bstate - 1):
          # Since we didn't match a full separator ..
          pbuffer[k] = c
          inc(k)
      (0, true)
    else:
      var index = 0
      while index < len(data):
        let ch = data[index]
        inc(index)

        if rstream.boundary[rstream.bstate] == ch:
          inc(rstream.bstate)
          if k + rstream.bstate == nbytes:
            return (index, k > 0 or rstream.bstate == len(rstream.boundary))

          if rstream.bstate == len(rstream.boundary):
            if k == 0:
              rstream.bstate = 0
            return (index, true)
        else:
          for c in rstream.boundary.toOpenArray(0, rstream.bstate - 1):
            pbuffer[k] = c
            inc(k)
          rstream.bstate = 0

          pbuffer[k] = ch
          inc(k)

          if k >= nbytes:
            return (index, true)
      # need to read at least one byte or it looks like EOF
      (index, k > 0)

  await rstream.rsource.readMessage(predicateSep)

  return k

proc readOnce(
    rstream: BoundedStreamReader, pbytes: pointer, nbytes: int
): Future[int] {.async: (raises: [CancelledError, AsyncStreamError]).} =
  if rstream.boundary.len > 0 and rstream.bstate == rstream.boundary.len:
    if rstream.boundSize.isSome() and (rstream.offset) != rstream.boundSize[]:
      case rstream.cmpop
      of BoundCmp.Equal:
        rstream.setErrorAndRaise(newBoundedStreamIncompleteError())
      of BoundCmp.LessOrEqual:
        rstream.state = AsyncStreamState.Finished
        return 0
    else:
      rstream.state = AsyncStreamState.Finished
      return 0

  if nbytes == 0:
    return 0
  let
    nbytes =
      if rstream.boundSize.isSome():
        if rstream.boundSize[] == rstream.offset:
          rstream.state = AsyncStreamState.Finished
          return 0

        min(int(rstream.boundSize[] - rstream.offset), nbytes)
      else:
        nbytes

    readFut =
      if rstream.boundary.len == 0:
        rstream.rsource.readOnce(pbytes, nbytes)
      else:
        rstream.readUntilBoundary(pbytes, nbytes)

    n =
      try:
        await readFut
      except CancelledError as exc:
        rstream.state = AsyncStreamState.Stopped
        raise exc
      except AsyncStreamError as exc:
        rstream.setErrorAndRaise(exc)

  if n == 0:
    if rstream.boundSize.isSome() and rstream.offset != rstream.boundSize[]:
      case rstream.cmpop
      of BoundCmp.Equal:
        rstream.setErrorAndRaise(newBoundedStreamIncompleteError())
      of BoundCmp.LessOrEqual:
        rstream.state = AsyncStreamState.Finished
    elif rstream.boundary.len > 0 and rstream.bstate != rstream.boundary.len and rstream.rsource.atEof():
      case rstream.cmpop
      of BoundCmp.Equal:
        rstream.setErrorAndRaise(newBoundedStreamIncompleteError())
      of BoundCmp.LessOrEqual:
        rstream.state = AsyncStreamState.Finished

  rstream.offset += n.uint64

  n

proc readBounded(
    rstream: BoundedStreamReader
): Future[seq[byte]] {.async: (raises: [CancelledError, AsyncStreamError]).} =
  # Fast path for reading all bytes up to the count-baased boundary
  let n = (rstream.boundSize.get() - rstream.offset).int
  var res = newSeqUninit[byte](n)
  if res.len > 0:
    try:
      await rstream.readExactly(addr res[0], res.len)
    except CancelledError as exc:
      rstream.state = AsyncStreamState.Stopped
      raise exc
    except AsyncStreamIncompleteError:
      raise newBoundedStreamIncompleteError()
  rstream.offset += n.uint

  # TODO https://github.com/nim-lang/Nim/issues/25057
  move(res)

proc initReaderVtbl(bufferSize: int): AsyncStreamReaderVtbl =
  proc readOnceImpl(
      rstream: AsyncStreamReader, pbytes: pointer, nbytes: int
  ): Future[int] {.async: (raises: [CancelledError, AsyncStreamError], raw: true).} =
    BoundedStreamReader(rstream).readOnce(pbytes, nbytes)

  var res = AsyncStreamReaderVtbl.initSimpleVtbl(readOnceImpl, bufferSize)

  # If we know the size upfront, we can pre-allocate the full return value
  let readNOrig = res.readN
  proc readNImpl(
      rstream: AsyncStreamReader, n: int
  ): Future[seq[byte]] {.async: (raises: [CancelledError, AsyncStreamError], raw: true).} =
    let rstream = BoundedStreamReader(rstream)
    if rstream.boundSize.isSome() and rstream.boundary.len == 0 and
        rstream.cmpop == BoundCmp.Equal and
        (n == 0 or n == (rstream.boundSize.get - rstream.offset).int):
      # Special case for draining the rest of the stream, as happens when
      # reading a http body for example
      readBounded(rstream)
    else:
      readNOrig(rstream, n)

  proc readImpl(
      rstream: AsyncStreamReader
  ): Future[seq[byte]] {.async: (raises: [CancelledError, AsyncStreamError], raw: true).} =
    readNImpl(rstream, 0)

  res.readN = readNImpl
  res.read = readImpl

  res

proc write(
    wstream: BoundedStreamWriter, pbytes: pointer, nbytes: int
) {.async: (raises: [CancelledError, AsyncStreamError]).} =
  if wstream.offset + nbytes.uint64 > wstream.boundSize:
    wstream.state = AsyncStreamState.Error
    wstream.error = newBoundedStreamOverflowError()
    raise wstream.error

  # We assume writes happen in the order that we initiate them which allows us
  # to do the accounting up-front - if the write fails, the stream breaks so the
  # offset no longer matters
  wstream.offset += nbytes.uint64

  try:
    await wstream.wsource.write(pbytes, nbytes)
  except CancelledError as exc:
    wstream.state = AsyncStreamState.Stopped
    raise exc
  except AsyncStreamError as exc:
    wstream.setErrorAndRaise(exc)

proc initWriterVtbl(): AsyncStreamWriterVtbl =
  proc writeImpl(
      wstream: AsyncStreamWriter, pbytes: pointer, nbytes: int
  ) {.async: (raises: [CancelledError, AsyncStreamError], raw: true).} =
    BoundedStreamWriter(wstream).write(pbytes, nbytes)

  var res = AsyncStreamWriterVtbl.initSimpleVtbl(writeImpl)

  res.finish = proc(
      wstream: AsyncStreamWriter
  ) {.async: (raises: [CancelledError, AsyncStreamError]).} =
    let wstream = BoundedStreamWriter(wstream)
    if wstream.offset == wstream.boundSize:
      wstream.state = AsyncStreamState.Finished
    else:
      case wstream.cmpop
      of BoundCmp.Equal:
        wstream.setErrorAndRaise(newBoundedStreamIncompleteError())
      of BoundCmp.LessOrEqual:
        wstream.state = AsyncStreamState.Finished

  res

proc bytesLeft*(stream: BoundedStreamRW): uint64 {.deprecated: "unused".} =
  ## Returns number of bytes left in stream.
  if stream.boundSize.isSome():
    stream.boundSize.get() - stream.offset
  else:
    0'u64

proc init*[T](child: BoundedStreamReader, rsource: AsyncStreamReader,
              boundSize: uint64, comparison = BoundCmp.Equal,
              bufferSize = BoundedBufferSize, udata: ref T) {.
            deprecated: "`udata` deprecated, use inheritance instead".} =
  child.boundSize = Opt.some(boundSize)
  child.cmpop = comparison
  child.rsource = rsource
  let vtbl = initReaderVtbl(bufferSize)
  init(AsyncStreamReader(child), vtbl, udata)
  if boundSize == 0:
    child.state = AsyncStreamState.Finished

proc init*[T](child: BoundedStreamReader, rsource: AsyncStreamReader,
              boundary: openArray[byte], comparison = BoundCmp.Equal,
              bufferSize = BoundedBufferSize, udata: ref T) {.
            deprecated: "`udata` deprecated, use inheritance instead".} =
  doAssert(len(boundary) > 0, BoundarySizeDefectMessage)
  child.boundary = @boundary
  child.cmpop = comparison
  child.rsource = rsource
  let vtbl = initReaderVtbl(bufferSize)
  init(AsyncStreamReader(child), vtbl, udata)

proc init*[T](child: BoundedStreamReader, rsource: AsyncStreamReader,
              boundSize: uint64, boundary: openArray[byte],
              comparison = BoundCmp.Equal,
              bufferSize = BoundedBufferSize, udata: ref T) {.
            deprecated: "`udata` deprecated, use inheritance instead".} =
  doAssert(len(boundary) > 0, BoundarySizeDefectMessage)
  child.boundSize = Opt.some(boundSize)
  child.boundary = @boundary
  child.cmpop = comparison
  child.rsource = rsource
  let vtbl = initReaderVtbl(bufferSize)
  init(AsyncStreamReader(child), vtbl, udata)
  if boundSize == 0:
    child.state = AsyncStreamState.Finished

proc init*(child: BoundedStreamReader, rsource: AsyncStreamReader,
           boundSize: uint64, comparison = BoundCmp.Equal,
           bufferSize = BoundedBufferSize) =
  child.boundSize = Opt.some(boundSize)
  child.cmpop = comparison
  child.rsource = rsource

  let vtbl = initReaderVtbl(bufferSize)
  init(AsyncStreamReader(child), vtbl)
  if boundSize == 0:
    child.state = AsyncStreamState.Finished

proc init*(child: BoundedStreamReader, rsource: AsyncStreamReader,
           boundary: openArray[byte], comparison = BoundCmp.Equal,
           bufferSize = BoundedBufferSize) =
  doAssert(len(boundary) > 0, BoundarySizeDefectMessage)
  child.boundary = @boundary
  child.cmpop = comparison
  child.rsource = rsource
  let vtbl = initReaderVtbl(bufferSize)
  init(AsyncStreamReader(child), vtbl)

proc init*(child: BoundedStreamReader, rsource: AsyncStreamReader,
           boundSize: uint64, boundary: openArray[byte],
           comparison = BoundCmp.Equal, bufferSize = BoundedBufferSize) =
  doAssert(len(boundary) > 0, BoundarySizeDefectMessage)
  child.boundSize = Opt.some(boundSize)
  child.boundary = @boundary
  child.cmpop = comparison
  child.rsource = rsource
  let vtbl = initReaderVtbl(bufferSize)
  init(AsyncStreamReader(child), vtbl)
  if boundSize == 0:
    child.state = AsyncStreamState.Finished

proc newBoundedStreamReader*[T](rsource: AsyncStreamReader,
                                boundSize: uint64,
                                comparison = BoundCmp.Equal,
                                bufferSize = BoundedBufferSize,
                                udata: ref T): BoundedStreamReader {.
            deprecated: "`udata` deprecated, use inheritance instead".} =
  ## Create new stream reader which will be limited by size ``boundSize``. When
  ## number of bytes readed by consumer reaches ``boundSize``,
  ## BoundedStreamReader will enter EOF state (no more bytes will be returned
  ## to the consumer).
  ##
  ## If ``comparison`` operator is ``BoundCmp.Equal`` and number of bytes readed
  ## from source stream reader ``rsource`` is less than ``boundSize`` -
  ## ``BoundedStreamIncompleteError`` will be raised. But comparison operator
  ## ``BoundCmp.LessOrEqual`` allows to consume less bytes without
  ## ``BoundedStreamIncompleteError`` exception.
  var res = BoundedStreamReader()
  res.init(rsource, boundSize, comparison, bufferSize, udata)
  res

proc newBoundedStreamReader*[T](rsource: AsyncStreamReader,
                                boundary: openArray[byte],
                                comparison = BoundCmp.Equal,
                                bufferSize = BoundedBufferSize,
                                udata: ref T): BoundedStreamReader {.
            deprecated: "`udata` deprecated, use inheritance instead".} =
  ## Create new stream reader which will be limited by binary boundary
  ## ``boundary``. As soon as reader reaches ``boundary`` BoundedStreamReader
  ## will enter EOF state (no more bytes will be returned to the consumer).
  ##
  ## If ``comparison`` operator is ``BoundCmp.Equal`` and number of bytes readed
  ## from source stream reader ``rsource`` is less than ``boundSize`` -
  ## ``BoundedStreamIncompleteError`` will be raised. But comparison operator
  ## ``BoundCmp.LessOrEqual`` allows to consume less bytes without
  ## ``BoundedStreamIncompleteError`` exception.
  var res = BoundedStreamReader()
  res.init(rsource, boundary, comparison, bufferSize, udata)
  res

proc newBoundedStreamReader*[T](rsource: AsyncStreamReader,
                                boundSize: uint64,
                                boundary: openArray[byte],
                                comparison = BoundCmp.Equal,
                                bufferSize = BoundedBufferSize,
                                udata: ref T): BoundedStreamReader {.
            deprecated: "`udata` deprecated, use inheritance instead".} =
  ## Create new stream reader which will be limited by size ``boundSize`` or
  ## boundary ``boundary``. As soon as reader reaches ``boundary`` ``OR`` number
  ## of bytes readed from source stream reader ``rsource`` reaches ``boundSize``
  ## BoundStreamReader will enter EOF state (no more bytes will be returned to
  ## the consumer).
  ##
  ## If ``comparison`` operator is ``BoundCmp.Equal`` and number of bytes readed
  ## from source stream reader ``rsource`` is less than ``boundSize`` -
  ## ``BoundedStreamIncompleteError`` will be raised. But comparison operator
  ## ``BoundCmp.LessOrEqual`` allows to consume less bytes without
  ## ``BoundedStreamIncompleteError`` exception.
  var res = BoundedStreamReader()
  res.init(rsource, boundSize, boundary, comparison, bufferSize, udata)
  res

proc newBoundedStreamReader*(rsource: AsyncStreamReader,
                             boundSize: uint64,
                             comparison = BoundCmp.Equal,
                             bufferSize = BoundedBufferSize,
                            ): BoundedStreamReader =
  ## Create new stream reader which will be limited by size ``boundSize``. When
  ## number of bytes readed by consumer reaches ``boundSize``,
  ## BoundedStreamReader will enter EOF state (no more bytes will be returned
  ## to the consumer).
  ##
  ## If ``comparison`` operator is ``BoundCmp.Equal`` and number of bytes readed
  ## from source stream reader ``rsource`` is less than ``boundSize`` -
  ## ``BoundedStreamIncompleteError`` will be raised. But comparison operator
  ## ``BoundCmp.LessOrEqual`` allows to consume less bytes without
  ## ``BoundedStreamIncompleteError`` exception.
  var res = BoundedStreamReader()
  res.init(rsource, boundSize, comparison, bufferSize)
  res

proc newBoundedStreamReader*(rsource: AsyncStreamReader,
                             boundary: openArray[byte],
                             comparison = BoundCmp.Equal,
                             bufferSize = BoundedBufferSize,
                            ): BoundedStreamReader =
  ## Create new stream reader which will be limited by binary boundary
  ## ``boundary``. As soon as reader reaches ``boundary`` BoundedStreamReader
  ## will enter EOF state (no more bytes will be returned to the consumer).
  ##
  ## If ``comparison`` operator is ``BoundCmp.Equal`` and number of bytes readed
  ## from source stream reader ``rsource`` is less than ``boundSize`` -
  ## ``BoundedStreamIncompleteError`` will be raised. But comparison operator
  ## ``BoundCmp.LessOrEqual`` allows to consume less bytes without
  ## ``BoundedStreamIncompleteError`` exception.
  var res = BoundedStreamReader()
  res.init(rsource, boundary, comparison, bufferSize)
  res

proc newBoundedStreamReader*(rsource: AsyncStreamReader,
                             boundSize: uint64,
                             boundary: openArray[byte],
                             comparison = BoundCmp.Equal,
                             bufferSize = BoundedBufferSize,
                            ): BoundedStreamReader =
  ## Create new stream reader which will be limited by size ``boundSize`` or
  ## boundary ``boundary``. As soon as reader reaches ``boundary`` ``OR`` number
  ## of bytes readed from source stream reader ``rsource`` reaches ``boundSize``
  ## BoundStreamReader will enter EOF state (no more bytes will be returned to
  ## the consumer).
  ##
  ## If ``comparison`` operator is ``BoundCmp.Equal`` and number of bytes readed
  ## from source stream reader ``rsource`` is less than ``boundSize`` -
  ## ``BoundedStreamIncompleteError`` will be raised. But comparison operator
  ## ``BoundCmp.LessOrEqual`` allows to consume less bytes without
  ## ``BoundedStreamIncompleteError`` exception.
  var res = BoundedStreamReader()
  res.init(rsource, boundSize, boundary, comparison, bufferSize)
  res

proc init*[T](child: BoundedStreamWriter, wsource: AsyncStreamWriter,
              boundSize: uint64, comparison = BoundCmp.Equal,
              queueSize = AsyncStreamDefaultQueueSize, udata: ref T) {.
            deprecated: "`udata` deprecated, use inheritance instead".} =
  child.boundSize = boundSize
  child.cmpop = comparison
  child.wsource = wsource
  let vtbl = initWriterVtbl()
  init(AsyncStreamWriter(child), vtbl, udata)

proc init*(child: BoundedStreamWriter, wsource: AsyncStreamWriter,
           boundSize: uint64, comparison = BoundCmp.Equal,
           queueSize = AsyncStreamDefaultQueueSize) =
  child.boundSize = boundSize
  child.cmpop = comparison
  child.wsource = wsource
  let vtbl = initWriterVtbl()
  init(AsyncStreamWriter(child), vtbl)

proc newBoundedStreamWriter*[T](wsource: AsyncStreamWriter,
                                boundSize: uint64,
                                comparison = BoundCmp.Equal,
                                queueSize = AsyncStreamDefaultQueueSize,
                                udata: ref T): BoundedStreamWriter {.
            deprecated: "`udata` deprecated, use inheritance instead".} =
  ## Create new stream writer which will be limited by size ``boundSize``. As
  ## soon as number of bytes written to the destination stream ``wsource``
  ## reaches ``boundSize`` stream will enter EOF state (no more bytes will be
  ## sent to remote destination stream ``wsource``).
  ##
  ## If ``comparison`` operator is ``BoundCmp.Equal`` and number of bytes
  ## written to destination stream ``wsource`` is less than ``boundSize`` -
  ## ``BoundedStreamIncompleteError`` will be raised on stream finishing. But
  ## comparison operator ``BoundCmp.LessOrEqual`` allows to send less bytes
  ## without ``BoundedStreamIncompleteError`` exception.
  ##
  ## For both comparison operators any attempt to write more bytes than
  ## ``boundSize`` will be interrupted with ``BoundedStreamOverflowError``
  ## exception.
  var res = BoundedStreamWriter()
  res.init(wsource, boundSize, comparison, queueSize, udata)
  res

proc newBoundedStreamWriter*(wsource: AsyncStreamWriter,
                             boundSize: uint64,
                             comparison = BoundCmp.Equal,
                             queueSize = AsyncStreamDefaultQueueSize,
                             ): BoundedStreamWriter =
  ## Create new stream writer which will be limited by size ``boundSize``. As
  ## soon as number of bytes written to the destination stream ``wsource``
  ## reaches ``boundSize`` stream will enter EOF state (no more bytes will be
  ## sent to remote destination stream ``wsource``).
  ##
  ## If ``comparison`` operator is ``BoundCmp.Equal`` and number of bytes
  ## written to destination stream ``wsource`` is less than ``boundSize`` -
  ## ``BoundedStreamIncompleteError`` will be raised on stream finishing. But
  ## comparison operator ``BoundCmp.LessOrEqual`` allows to send less bytes
  ## without ``BoundedStreamIncompleteError`` exception.
  ##
  ## For both comparison operators any attempt to write more bytes than
  ## ``boundSize`` will be interrupted with ``BoundedStreamOverflowError``
  ## exception.
  var res = BoundedStreamWriter()
  res.init(wsource, boundSize, comparison, queueSize)
  res

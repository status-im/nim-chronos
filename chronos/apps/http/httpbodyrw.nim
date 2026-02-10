#
#         Chronos HTTP/S body reader/writer
#             (c) Copyright 2021-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

{.push raises: [].}

import ../../asyncloop, ../../asyncsync
import ../../streams/[asyncstream, boundstream]
import httpcommon

const
  HttpBodyReaderTrackerName* = "http.body.reader" ## HTTP body reader leaks tracker name
  HttpBodyWriterTrackerName* = "http.body.writer" ## HTTP body writer leaks tracker name

type
  HttpBodyReader* = ref object of AsyncStreamReader
    bstate*: HttpState
    streams*: seq[AsyncStreamReader]

  HttpBodyWriter* = ref object of AsyncStreamWriter
    bstate*: HttpState
    streams*: seq[AsyncStreamWriter]

proc newHttpBodyReader*(streams: varargs[AsyncStreamReader]): HttpBodyReader =
  ## HttpBodyReader is AsyncStreamReader which holds references to all the
  ## ``streams``. Also on close it will close all the ``streams``.
  ##
  ## First stream in sequence will be used as a source.
  doAssert(len(streams) > 0, "At least one stream must be added")
  var res = HttpBodyReader(bstate: HttpState.Alive, streams: @streams)
  res.init(streams[0])
  trackCounter(HttpBodyReaderTrackerName)
  res

proc closeWait*(bstream: HttpBodyReader) {.async: (raises: []).} =
  ## Close and free resource allocated by body reader.
  if bstream.bstate == HttpState.Alive:
    bstream.bstate = HttpState.Closing
    var res = newSeq[Future[void].Raising([])]()
    # We closing streams in reversed order because stream at position [0], uses
    # data from stream at position [1].
    for index in countdown((len(bstream.streams) - 1), 0):
      res.add(bstream.streams[index].closeWait())
    res.add(procCall(closeWait(AsyncStreamReader(bstream))))
    await noCancel(allFutures(res))
    bstream.bstate = HttpState.Closed
    untrackCounter(HttpBodyReaderTrackerName)

proc newHttpBodyWriter*(streams: varargs[AsyncStreamWriter]): HttpBodyWriter =
  ## HttpBodyWriter is AsyncStreamWriter which holds references to all the
  ## ``streams``. Also on close it will close all the ``streams``.
  ##
  ## First stream in sequence will be used as a destination.
  doAssert(len(streams) > 0, "At least one stream must be added")
  var res = HttpBodyWriter(bstate: HttpState.Alive, streams: @streams)
  res.init(streams[0])
  trackCounter(HttpBodyWriterTrackerName)
  res

proc closeWait*(bstream: HttpBodyWriter) {.async: (raises: []).} =
  ## Close and free all the resources allocated by body writer.
  if bstream.bstate == HttpState.Alive:
    bstream.bstate = HttpState.Closing
    var res = newSeq[Future[void].Raising([])]()
    for index in countdown(len(bstream.streams) - 1, 0):
      res.add(bstream.streams[index].closeWait())
    await noCancel(allFutures(res))
    await procCall(closeWait(AsyncStreamWriter(bstream)))
    bstream.bstate = HttpState.Closed
    untrackCounter(HttpBodyWriterTrackerName)

proc hasOverflow*(bstream: HttpBodyReader): bool =
  if len(bstream.streams) == 1:
    # If HttpBodyReader has only one stream it has ``BoundedStreamReader``, in
    # such case its impossible to get more bytes then expected amount.
    false
  else:
    # If HttpBodyReader has two or more streams, we check if
    # ``BoundedStreamReader`` at EOF.
    if bstream.streams[0].atEof():
      for i in 1 ..< len(bstream.streams):
        if not (bstream.streams[i].atEof()):
          return true
      false
    else:
      false

proc closed*(bstream: HttpBodyReader | HttpBodyWriter): bool =
  bstream.bstate != HttpState.Alive

#
#           Chronos HTTP/S multipart/form
#      encoding and decoding helper procedures
#             (c) Copyright 2019-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)
import std/[monotimes, strutils]
import stew/results
import ../../asyncloop
import ../../streams/[asyncstream, boundstream, chunkstream]
import httptable, httpcommon
export httptable, httpcommon, asyncstream

type
  MultiPartSource {.pure.} = enum
    Stream, Buffer

  MultiPartReader* = object
    case kind: MultiPartSource
    of MultiPartSource.Stream:
      stream: AsyncStreamReader
    of MultiPartSource.Buffer:
      discard
    firstTime: bool
    buffer: seq[byte]
    offset: int
    boundary: seq[byte]
    counter: int

  MultiPartReaderRef* = ref MultiPartReader

  MultiPart* = object
    case kind: MultiPartSource
    of MultiPartSource.Stream:
      stream*: BoundedStreamReader
    of MultiPartSource.Buffer:
      discard
    buffer: seq[byte]
    headers: HttpTable
    counter: int
    name*: string
    filename*: string

  MultipartError* = object of HttpCriticalError
  MultipartEoM* = object of MultipartError
  MultipartIncorrectError* = object of MultipartError
  MultipartIncompleteError* = object of MultipartError
  MultipartReadError* = object of MultipartError

  BChar* = byte | char

proc newMultipartReadError(msg: string): ref MultipartReadError =
  newException(MultipartReadError, msg)

proc startsWith*(s, prefix: openarray[byte]): bool =
  var i = 0
  while true:
    if i >= len(prefix): return true
    if i >= len(s) or s[i] != prefix[i]: return false
    inc(i)

proc parseUntil*(s, until: openarray[byte]): int =
  var i = 0
  while i < len(s):
    if len(until) > 0 and s[i] == until[0]:
      var u = 1
      while i + u < len(s) and u < len(until) and s[i + u] == until[u]:
        inc u
      if u >= len(until): return i
    inc(i)
  -1

proc init*[A: BChar, B: BChar](mpt: typedesc[MultiPartReader],
                               buffer: openarray[A],
                               boundary: openarray[B]): MultiPartReader =
  # Boundary should not be empty.
  doAssert(len(boundary) > 0)
  # Our internal boundary has format `<CR><LF><-><-><boundary>`, so we can reuse
  # different parts of this sequence for processing.
  var fboundary = newSeq[byte](len(boundary) + 4)
  fboundary[0] = 0x0D'u8
  fboundary[1] = 0x0A'u8
  fboundary[2] = byte('-')
  fboundary[3] = byte('-')
  copyMem(addr fboundary[4], unsafeAddr boundary[0], len(boundary))
  # Make copy of buffer, because all the returned parts depending on it.
  var buf = newSeq[byte](len(buffer))
  if len(buf) > 0:
    copyMem(addr buf[0], unsafeAddr buffer[0], len(buffer))
  MultiPartReader(kind: MultiPartSource.Buffer,
                  buffer: buf, offset: 0, boundary: fboundary)

proc new*[B: BChar](mpt: typedesc[MultiPartReaderRef],
                     stream: AsyncStreamReader,
                     boundary: openarray[B],
                     partHeadersMaxSize = 4096): MultiPartReaderRef =
  # Boundary should not be empty.
  doAssert(len(boundary) > 0)
  # Our internal boundary has format `<CR><LF><-><-><boundary>`, so we can reuse
  # different parts of this sequence for processing.
  var fboundary = newSeq[byte](len(boundary) + 4)
  fboundary[0] = 0x0D'u8
  fboundary[1] = 0x0A'u8
  fboundary[2] = byte('-')
  fboundary[3] = byte('-')
  copyMem(addr fboundary[4], unsafeAddr boundary[0], len(boundary))
  MultiPartReaderRef(kind: MultiPartSource.Stream, firstTime: true,
                     stream: stream, offset: 0, boundary: fboundary,
                     buffer: newSeq[byte](partHeadersMaxSize))

func setPartNames*(part: var MultiPart): HttpResult[void] =
  if part.headers.count("content-disposition") != 1:
    return err("Content-Disposition header is incorrect")
  var header = part.headers.getString("content-disposition")
  let disp = parseDisposition(header, false)
  if disp.failed():
    return err("Content-Disposition header value is incorrect")
  let dtype = disp.dispositionType(header.toOpenArrayByte(0, len(header) - 1))
  if dtype.toLowerAscii() != "form-data":
    return err("Content-Disposition type is incorrect")
  for k, v in disp.fields(header.toOpenArrayByte(0, len(header) - 1)):
    case k.toLowerAscii()
    of "name":
      part.name = v
    of "filename":
      part.filename = v
    else:
      discard
  if len(part.name) == 0:
    part.name = $part.counter
  ok()

proc readPart*(mpr: MultiPartReaderRef): Future[MultiPart] {.async.} =
  doAssert(mpr.kind == MultiPartSource.Stream)
  if mpr.firstTime:
    try:
      # Read and verify initial <-><-><boundary><CR><LF>
      await mpr.stream.readExactly(addr mpr.buffer[0], len(mpr.boundary) - 2)
      mpr.firstTime = false
      if not(startsWith(mpr.buffer.toOpenArray(0, len(mpr.boundary) - 3),
                        mpr.boundary.toOpenArray(2, len(mpr.boundary) - 1))):
        raise newException(MultiPartIncorrectError,
                           "Unexpected boundary encountered")
    except CancelledError as exc:
      raise exc
    except AsyncStreamIncompleteError:
      raise newMultipartReadError("Error reading multipart message")
    except AsyncStreamReadError:
      raise newMultipartReadError("Error reading multipart message")

  # Reading part's headers
  try:
    await mpr.stream.readExactly(addr mpr.buffer[0], 2)
    if mpr.buffer[0] == byte('-') and mpr.buffer[1] == byte('-'):
      raise newException(MultiPartEoM,
                         "End of multipart message")
    if mpr.buffer[0] != 0x0D'u8 or mpr.buffer[1] != 0x0A'u8:
      raise newException(MultiPartIncorrectError,
                         "Unexpected boundary suffix")
    let res = await mpr.stream.readUntil(addr mpr.buffer[0], len(mpr.buffer),
                                         HeadersMark)
    var headersList = parseHeaders(mpr.buffer.toOpenArray(0, res - 1), false)
    if headersList.failed():
      raise newException(MultiPartIncorrectError,
                         "Incorrect part headers found")
    var part = MultiPart(
      kind: MultiPartSource.Stream,
      headers: HttpTable.init(),
      stream: newBoundedStreamReader(mpr.stream, -1, mpr.boundary),
      counter: mpr.counter
    )
    inc(mpr.counter)

    for k, v in headersList.headers(mpr.buffer.toOpenArray(0, res - 1)):
      part.headers.add(k, v)

    let sres = part.setPartNames()
    if sres.isErr():
      raise newException(MultiPartIncorrectError, sres.error)
    return part

  except CancelledError as exc:
    raise exc
  except AsyncStreamIncompleteError:
    raise newMultipartReadError("Error reading multipart message")
  except AsyncStreamLimitError:
    raise newMultipartReadError("Multipart message headers size too big")
  except AsyncStreamReadError:
    raise newMultipartReadError("Error reading multipart message")

proc getBody*(mp: MultiPart): Future[seq[byte]] {.async.} =
  case mp.kind
  of MultiPartSource.Stream:
    try:
      let res = await mp.stream.read()
      return res
    except AsyncStreamError:
      raise newException(HttpCriticalError, "Could not read multipart body")
  of MultiPartSource.Buffer:
    return mp.buffer

proc consumeBody*(mp: MultiPart) {.async.} =
  case mp.kind
  of MultiPartSource.Stream:
    try:
      await mp.stream.consume()
    except AsyncStreamError:
      raise newException(HttpCriticalError, "Could not consume multipart body")
  of MultiPartSource.Buffer:
    discard

proc getBytes*(mp: MultiPart): seq[byte] =
  ## Returns MultiPart value as sequence of bytes.
  case mp.kind
  of MultiPartSource.Buffer:
    mp.buffer
  of MultiPartSource.Stream:
    doAssert(not(mp.stream.atEof()), "Value is not obtained yet")
    mp.buffer

proc getString*(mp: MultiPart): string =
  ## Returns MultiPart value as string.
  case mp.kind
  of MultiPartSource.Buffer:
    if len(mp.buffer) > 0:
      var res = newString(len(mp.buffer))
      copyMem(addr res[0], unsafeAddr mp.buffer[0], len(mp.buffer))
      res
    else:
      ""
  of MultiPartSource.Stream:
    doAssert(not(mp.stream.atEof()), "Value is not obtained yet")
    if len(mp.buffer) > 0:
      var res = newString(len(mp.buffer))
      copyMem(addr res[0], unsafeAddr mp.buffer[0], len(mp.buffer))
      res
    else:
      ""

proc getPart*(mpr: var MultiPartReader): Result[MultiPart, string] =
  doAssert(mpr.kind == MultiPartSource.Buffer)
  if mpr.offset >= len(mpr.buffer):
    return err("End of multipart form encountered")

  if startsWith(mpr.buffer.toOpenArray(mpr.offset, len(mpr.buffer) - 1),
                mpr.boundary.toOpenArray(2, len(mpr.boundary) - 1)):
    # Buffer must start at <-><-><boundary>
    mpr.offset += (len(mpr.boundary) - 2)

    # After boundary there should be at least 2 symbols <-><-> or <CR><LF>.
    if len(mpr.buffer) <= mpr.offset + 1:
      return err("Incomplete multipart form")

    if mpr.buffer[mpr.offset] == byte('-') and
       mpr.buffer[mpr.offset + 1] == byte('-'):
      # If we have <-><-><boundary><-><-> it means we have found last boundary
      # of multipart message.
      mpr.offset += 2
      return err("End of multipart form encountered")

    if mpr.buffer[mpr.offset] == 0x0D'u8 and
       mpr.buffer[mpr.offset + 1] == 0x0A'u8:
      # If we have <-><-><boundary><CR><LF> it means that we have found another
      # part of multipart message.
      mpr.offset += 2
      # Multipart form must always have at least single Content-Disposition
      # header, so we searching position where all the headers should be
      # finished <CR><LF><CR><LF>.
      let pos1 = parseUntil(
        mpr.buffer.toOpenArray(mpr.offset, len(mpr.buffer) - 1),
        [0x0D'u8, 0x0A'u8, 0x0D'u8, 0x0A'u8]
      )

      if pos1 < 0:
        return err("Incomplete multipart form")

      # parseUntil returns 0-based position without `until` sequence.
      let start = mpr.offset + pos1 + 4

      # Multipart headers position
      let hstart = mpr.offset
      let hfinish = mpr.offset + pos1 + 4 - 1

      let headersList = parseHeaders(mpr.buffer.toOpenArray(hstart, hfinish),
                                     false)
      if headersList.failed():
        return err("Incorrect or incomplete multipart headers received")

      # Searching for value's boundary <CR><LF><-><-><boundary>.
      let pos2 = parseUntil(
        mpr.buffer.toOpenArray(start, len(mpr.buffer) - 1),
        mpr.boundary.toOpenArray(0, len(mpr.boundary) - 1)
      )

      if pos2 < 0:
        return err("Incomplete multipart form")

      # We set reader's offset to the place right after <CR><LF>
      mpr.offset = start + pos2 + 2
      var part = MultiPart(
        kind: MultiPartSource.Buffer,
        headers: HttpTable.init(),
        buffer: @(mpr.buffer.toOpenArray(start, start + pos2 - 1)),
        counter: mpr.counter
      )
      inc(mpr.counter)

      for k, v in headersList.headers(mpr.buffer.toOpenArray(hstart, hfinish)):
        part.headers.add(k, v)

      ? part.setPartNames()

      ok(part)
    else:
      err("Incorrect multipart form")
  else:
    err("Incorrect multipart form")

func getMultipartBoundary*(ch: openarray[string]): HttpResult[string] =
  if len(ch) > 1:
    err("Multiple Content-Type headers found")
  else:
    if len(ch) == 0:
      err("Content-Type header is missing")
    else:
      let mparts = ch[0].split(";")
      if strip(mparts[0]).toLowerAscii() != "multipart/form-data":
        return err("Content-Type is not multipart")
      if len(mparts) < 2:
        return err("Content-Type missing boundary value")
      let stripped = strip(mparts[1])
      if not(stripped.toLowerAscii().startsWith("boundary")):
        return err("Incorrect Content-Type boundary format")
      let bparts = stripped.split("=")
      if len(bparts) < 2:
        err("Missing Content-Type boundary")
      else:
        let candidate = strip(bparts[1])
        if len(candidate) > 70:
          err("Content-Type boundary must be less then 70 characters")
        else:
          for ch in candidate:
            if ch notin {'a'..'z', 'A' .. 'Z', '0' .. '9',
                         '\'' .. ')', '+' .. '/', ':', '=', '?', '_'}:
              return err("Content-Type boundary alphabat incorrect")
          ok(candidate)

when isMainModule:
  var buf = "--------------------------5e7d0dd0ed6eb849\r\nContent-Disposition: form-data; =\"key1\"\r\n\r\nvalue1\r\n--------------------------5e7d0dd0ed6eb849\r\nContent-Disposition: form-data; name=\"key2\"\r\n\r\nvalue2\r\n--------------------------5e7d0dd0ed6eb849--"
  var reader = MultiPartReader.init(buf, "------------------------5e7d0dd0ed6eb849")
  echo getPart(reader)
  echo "===="
  echo getPart(reader)
  echo "===="
  echo getPart(reader)

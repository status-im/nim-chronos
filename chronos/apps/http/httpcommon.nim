#
#            Chronos HTTP/S common types
#             (c) Copyright 2021-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)
import stew/results, httputils, strutils, uri
import ../../asyncloop, ../../asyncsync
import ../../streams/[asyncstream, boundstream]
export results, httputils, strutils

const
  HeadersMark* = @[byte(0x0D), byte(0x0A), byte(0x0D), byte(0x0A)]
  PostMethods* = {MethodPost, MethodPatch, MethodPut, MethodDelete}

type
  HttpResult*[T] = Result[T, string]
  HttpResultCode*[T] = Result[T, HttpCode]

  HttpDefect* = object of Defect
  HttpError* = object of CatchableError
  HttpCriticalError* = object of HttpError
    code*: HttpCode
  HttpRecoverableError* = object of HttpError
    code*: HttpCode
  HttpDisconnectError* = object of HttpError

  TransferEncodingFlags* {.pure.} = enum
    Identity, Chunked, Compress, Deflate, Gzip

  ContentEncodingFlags* {.pure.} = enum
    Identity, Br, Compress, Deflate, Gzip

  HttpBodyReader* = ref object of AsyncStreamReader
    streams*: seq[AsyncStreamReader]

proc newHttpBodyReader*(streams: varargs[AsyncStreamReader]): HttpBodyReader =
  ## HttpBodyReader is AsyncStreamReader which holds references to all the
  ## ``streams``. Also on close it will close all the ``streams``.
  ##
  ## First stream in sequence will be used as a source.
  doAssert(len(streams) > 0, "At least one stream must be added")
  var res = HttpBodyReader(streams: @streams)
  res.init(streams[0])
  res

proc closeWait*(bstream: HttpBodyReader) {.async.} =
  ## Close and free resource allocated by body reader.
  if len(bstream.streams) > 0:
    var res = newSeq[Future[void]]()
    for item in bstream.streams.items():
      res.add(item.closeWait())
    await allFutures(res)
  await procCall(AsyncStreamReader(bstream).closeWait())

proc atBound*(bstream: HttpBodyReader): bool {.
     raises: [Defect].} =
  ## Returns ``true`` if lowest stream is at EOF.
  let lreader = bstream.streams[^1]
  doAssert(lreader of BoundedStreamReader)
  let breader = cast[BoundedStreamReader](lreader)
  breader.atEof() and (breader.bytesLeft() == 0)

proc raiseHttpCriticalError*(msg: string,
                             code = Http400) {.noinline, noreturn.} =
  raise (ref HttpCriticalError)(code: code, msg: msg)

proc raiseHttpDisconnectError*() {.noinline, noreturn.} =
  raise (ref HttpDisconnectError)(msg: "Remote peer disconnected")

proc raiseHttpDefect*(msg: string) {.noinline, noreturn.} =
  raise (ref HttpDefect)(msg: msg)

iterator queryParams*(query: string): tuple[key: string, value: string] {.
         raises: [Defect].} =
  ## Iterate over url-encoded query string.
  for pair in query.split('&'):
    let items = pair.split('=', maxsplit = 1)
    let k = items[0]
    if len(k) > 0:
      let v = if len(items) > 1: items[1] else: ""
      yield (decodeUrl(k), decodeUrl(v))

func getTransferEncoding*(ch: openarray[string]): HttpResult[
                                                  set[TransferEncodingFlags]] {.
     raises: [Defect].} =
  ## Parse value of multiple HTTP headers ``Transfer-Encoding`` and return
  ## it as set of ``TransferEncodingFlags``.
  var res: set[TransferEncodingFlags] = {}
  if len(ch) == 0:
    res.incl(TransferEncodingFlags.Identity)
    ok(res)
  else:
    for header in ch:
      for item in header.split(","):
        case strip(item.toLowerAscii())
        of "identity":
          res.incl(TransferEncodingFlags.Identity)
        of "chunked":
          res.incl(TransferEncodingFlags.Chunked)
        of "compress":
          res.incl(TransferEncodingFlags.Compress)
        of "deflate":
          res.incl(TransferEncodingFlags.Deflate)
        of "gzip":
          res.incl(TransferEncodingFlags.Gzip)
        of "x-gzip":
          res.incl(TransferEncodingFlags.Gzip)
        of "":
          res.incl(TransferEncodingFlags.Identity)
        else:
          return err("Incorrect Transfer-Encoding value")
    ok(res)

func getContentEncoding*(ch: openarray[string]): HttpResult[
                                                   set[ContentEncodingFlags]] {.
     raises: [Defect].} =
  ## Parse value of multiple HTTP headers ``Content-Encoding`` and return
  ## it as set of ``ContentEncodingFlags``.
  var res: set[ContentEncodingFlags] = {}
  if len(ch) == 0:
    res.incl(ContentEncodingFlags.Identity)
    ok(res)
  else:
    for header in ch:
      for item in header.split(","):
        case strip(item.toLowerAscii()):
        of "identity":
          res.incl(ContentEncodingFlags.Identity)
        of "br":
          res.incl(ContentEncodingFlags.Br)
        of "compress":
          res.incl(ContentEncodingFlags.Compress)
        of "deflate":
          res.incl(ContentEncodingFlags.Deflate)
        of "gzip":
          res.incl(ContentEncodingFlags.Gzip)
        of "x-gzip":
          res.incl(ContentEncodingFlags.Gzip)
        of "":
          res.incl(ContentEncodingFlags.Identity)
        else:
          return err("Incorrect Content-Encoding value")
    ok(res)

func getContentType*(ch: openarray[string]): HttpResult[string]  {.
     raises: [Defect].} =
  ## Check and prepare value of ``Content-Type`` header.
  if len(ch) == 0:
    err("No Content-Type values found")
  elif len(ch) > 1:
    err("Multiple Content-Type values found")
  else:
    let mparts = ch[0].split(";")
    ok(strip(mparts[0]).toLowerAscii())

proc bytesToString*(src: openarray[byte], dst: var openarray[char]) =
  ## Convert array of bytes to array of characters.
  ##
  ## Note, that this procedure assume that `sizeof(byte) == sizeof(char) == 1`.
  ## If this equation is not correct this procedures MUST not be used.
  doAssert(len(src) == len(dst))
  if len(src) > 0:
    copyMem(addr dst[0], unsafeAddr src[0], len(src))

proc stringToBytes*(src: openarray[char], dst: var openarray[byte]) =
  ## Convert array of characters to array of bytes.
  ##
  ## Note, that this procedure assume that `sizeof(byte) == sizeof(char) == 1`.
  ## If this equation is not correct this procedures MUST not be used.
  doAssert(len(src) == len(dst))
  if len(src) > 0:
    copyMem(addr dst[0], unsafeAddr src[0], len(src))

func bytesToString*(src: openarray[byte]): string =
  ## Convert array of bytes to a string.
  ##
  ## Note, that this procedure assume that `sizeof(byte) == sizeof(char) == 1`.
  ## If this equation is not correct this procedures MUST not be used.
  var default: string
  if len(src) > 0:
    var dst = newString(len(src))
    bytesToString(src, dst)
    dst
  else:
    default

func stringToBytes*(src: openarray[char]): seq[byte] =
  ## Convert string to sequence of bytes.
  ##
  ## Note, that this procedure assume that `sizeof(byte) == sizeof(char) == 1`.
  ## If this equation is not correct this procedures MUST not be used.
  var default: seq[byte]
  if len(src) > 0:
    var dst = newSeq[byte](len(src))
    stringToBytes(src, dst)
    dst
  else:
    default

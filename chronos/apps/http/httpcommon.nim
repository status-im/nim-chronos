#
#            Chronos HTTP/S common types
#             (c) Copyright 2019-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)
import stew/results, httputils, strutils, uri
export results, httputils, strutils

const
  useChroniclesLogging* {.booldefine.} = false

  HeadersMark* = @[byte(0x0D), byte(0x0A), byte(0x0D), byte(0x0A)]
  PostMethods* = {MethodPost, MethodPatch, MethodPut, MethodDelete}

type
  HttpResult*[T] = Result[T, string]
  HttpResultCode*[T] = Result[T, HttpCode]

  HttpError* = object of CatchableError
  HttpCriticalError* = object of HttpError
  HttpRecoverableError* = object of HttpError

  TransferEncodingFlags* {.pure.} = enum
    Identity, Chunked, Compress, Deflate, Gzip

  ContentEncodingFlags* {.pure.} = enum
    Identity, Br, Compress, Deflate, Gzip

template log*(body: untyped) =
  when defined(useChroniclesLogging):
    body

proc newHttpCriticalError*(msg: string): ref HttpCriticalError =
  newException(HttpCriticalError, msg)

proc newHttpRecoverableError*(msg: string): ref HttpRecoverableError =
  newException(HttpRecoverableError, msg)

iterator queryParams*(query: string): tuple[key: string, value: string] =
  ## Iterate over url-encoded query string.
  for pair in query.split('&'):
    let items = pair.split('=', maxsplit = 1)
    let k = items[0]
    if len(k) > 0:
      let v = if len(items) > 1: items[1] else: ""
      yield (decodeUrl(k), decodeUrl(v))

func getTransferEncoding*(ch: openarray[string]): HttpResult[
                                                   set[TransferEncodingFlags]] =
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
        of "":
          res.incl(TransferEncodingFlags.Identity)
        else:
          return err("Incorrect Transfer-Encoding value")
    ok(res)

func getContentEncoding*(ch: openarray[string]): HttpResult[
                                                    set[ContentEncodingFlags]] =
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
        of "":
          res.incl(ContentEncodingFlags.Identity)
        else:
          return err("Incorrect Content-Encoding value")
    ok(res)

func getContentType*(ch: openarray[string]): HttpResult[string] =
  ## Check and prepare value of ``Content-Type`` header.
  if len(ch) > 1:
    err("Multiple Content-Type values found")
  else:
    let mparts = ch[0].split(";")
    ok(strip(mparts[0]).toLowerAscii())

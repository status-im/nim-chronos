#
#            Chronos HTTP/S common types
#             (c) Copyright 2019-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)
import stew/results, httputils
export results, httputils

const
  useChroniclesLogging* {.booldefine.} = false

  HeadersMark* = @[byte(0x0D), byte(0x0A), byte(0x0D), byte(0x0A)]

type
  HttpResult*[T] = Result[T, string]
  HttpResultCode*[T] = Result[T, HttpCode]

  HttpError* = object of CatchableError
  HttpCriticalFailure* = object of HttpError
  HttpRecoverableFailure* = object of HttpError

template log*(body: untyped) =
  when defined(useChroniclesLogging):
    body

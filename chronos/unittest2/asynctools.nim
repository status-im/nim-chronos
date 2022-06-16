#
#              Chronos Unittest2 Helpers
#             (c) Copyright 2022-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)
import unittest2
import ".."/asyncloop

export unittest2

template asyncTest*(name: string, body: untyped): untyped =
  test name:
    waitFor((
      proc() {.async, gcsafe.} =
        body
    )())

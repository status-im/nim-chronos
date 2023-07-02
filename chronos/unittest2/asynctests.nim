#
#              Chronos Unittest2 Helpers
#             (c) Copyright 2022-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)
import unittest2
import ../../chronos

export unittest2, chronos

template asyncTest*(name: string, body: untyped): untyped =
  test name:
    waitFor((
      proc() {.async, gcsafe.} =
        body
    )())

template checkLeaks*(name: string): untyped =
  let tracker = getTrackerCounter(name)
  if tracker.opened != tracker.closed:
    echo "[" & name & "] opened = ", tracker.opened,
         ", closed = ", tracker.closed
  check tracker.opened == tracker.closed

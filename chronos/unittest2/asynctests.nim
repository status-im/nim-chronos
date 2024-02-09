#
#              Chronos Unittest2 Helpers
#             (c) Copyright 2022-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)
import std/tables
import unittest2
import ../../chronos

export unittest2, chronos

template asyncTest*(name: string, body: untyped): untyped =
  test name:
    waitFor(
      (
        proc() {.async, gcsafe.} =
          body
      )()
    )

template checkLeaks*(name: string): untyped =
  let counter = getTrackerCounter(name)
  checkpoint:
    "[" & name & "] opened = " & $counter.opened & ", closed = " & $counter.closed
  check counter.opened == counter.closed

proc checkLeaks*() =
  for key in getThreadDispatcher().trackerCounterKeys():
    checkLeaks(key)
  GC_fullCollect()

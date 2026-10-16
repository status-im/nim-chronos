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
    waitFor((
      proc() {.async, gcsafe.} =
        body
    )())

template checkLeaks*(name: string, pre, post: TrackerCounter): untyped =
  checkpoint:
    "[" & name & "] opened = " & $(post.opened - pre.opened) &
         ", closed = " & $ (post.closed - post.opened)
  check (post.opened - post.closed) == (pre.opened - pre.closed)

proc checkLeaks*(pre: TrackerCounters) =
  ## Compare current tracker counter state against a prestate and fail the test
  ## if there's a leak.
  ##
  ## When used in `unittest`, a `setup`/`teardown` pair automates leak checking
  ## for each test individually (see also the chronosTestLeakCheck compile-time
  ## option):
  ##
  ## setup:
  ##   let counters = getTrackerCounters()
  ## teardown:
  ##   checkLeaks(counters)
  for key, value in getTrackerCounters():
    checkLeaks(key, pre.getOrDefault(key, TrackerCounter()), value)

  GC_fullCollect()

template checkLeaks*(name: string): untyped {.deprecated: "Use pre/post version instead".} =
  let counter = getTrackerCounter(name)
  checkpoint:
    "[" & name & "] opened = " & $counter.opened &
         ", closed = " & $ counter.closed
  check counter.opened == counter.closed

{.push warning[Deprecated]: false.}
proc checkLeaks*() {.deprecated: "Use pre/post version instead".} =
  for key in getThreadDispatcher().trackerCounterKeys():
    checkLeaks(key)
  GC_fullCollect()
{.pop.}

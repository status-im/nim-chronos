#              Asyncdispatch2 Test Suite
#                 (c) Copyright 2018
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

import unittest
import ../asyncdispatch2

const CallSoonTests = 10
var soonTest1 = 0
var timeoutsTest1 = 0
var timeoutsTest2 = 0

proc callback1(udata: pointer) {.gcsafe.} =
  soonTest1 += int(cast[uint](udata))

proc test1(): int =
  callSoon(callback1, cast[pointer](0x01234567))
  callSoon(callback1, cast[pointer](0x02345678))
  callSoon(callback1, cast[pointer](0x03456789))
  callSoon(callback1, cast[pointer](0x0456789A))
  callSoon(callback1, cast[pointer](0x056789AB))
  callSoon(callback1, cast[pointer](0x06789ABC))
  callSoon(callback1, cast[pointer](0x0789ABCD))
  callSoon(callback1, cast[pointer](0x089ABCDE))
  callSoon(callback1, cast[pointer](0x09ABCDEF))
  callSoon(callback1, cast[pointer](0x0ABCDEF1))
  callSoon(callback1, cast[pointer](0x0BCDEF12))
  callSoon(callback1, cast[pointer](0x0CDEF123))
  callSoon(callback1, cast[pointer](0x0DEF1234))
  callSoon(callback1, cast[pointer](0x0EF12345))
  callSoon(callback1, cast[pointer](0x0F123456))
  ## All callbacks must be processed exactly with 1 poll() call.
  poll()
  result = soonTest1

proc testProc() {.async.} =
  for i in 1..CallSoonTests:
    await sleepAsync(100)
    timeoutsTest1 += 1

proc callbackProc(udata: pointer) {.gcsafe.} =
  timeoutsTest2 += 1
  callSoon(callbackProc)

proc test2(): int =
  discard testProc()
  callSoon(callbackProc)
  ## Test must be completed exactly with (CallSoonTests * 2) poll() calls.
  for i in 1..(CallSoonTests * 2):
    poll()
  result = timeoutsTest2 - timeoutsTest1

when isMainModule:
  suite "callSoon() tests suite":
    test "User-defined callback argument test":
      var expect = 0x01234567 + 0x02345678 + 0x03456789 + 0x0456789A +
                   0x056789AB + 0x06789ABC + 0x0789ABCD + 0x089ABCDE +
                   0x09ABCDEF + 0x0ABCDEF1 + 0x0BCDEF12 + 0x0CDEF123 +
                   0x0DEF1234 + 0x0EF12345 + 0x0F123456
      check test1() == expect
    test "callSoon() behavior test":
      check test2() == CallSoonTests

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
  callSoon(callback1, cast[pointer](0x12345678))
  callSoon(callback1, cast[pointer](0x23456789))
  callSoon(callback1, cast[pointer](0x3456789A))
  callSoon(callback1, cast[pointer](0x456789AB))
  callSoon(callback1, cast[pointer](0x56789ABC))
  callSoon(callback1, cast[pointer](0x6789ABCD))
  callSoon(callback1, cast[pointer](0x789ABCDE))
  callSoon(callback1, cast[pointer](0x89ABCDEF))
  callSoon(callback1, cast[pointer](0x9ABCDEF1))
  callSoon(callback1, cast[pointer](0xABCDEF12))
  callSoon(callback1, cast[pointer](0xBCDEF123))
  callSoon(callback1, cast[pointer](0xCDEF1234))
  callSoon(callback1, cast[pointer](0xDEF12345))
  callSoon(callback1, cast[pointer](0xEF123456))
  callSoon(callback1, cast[pointer](0xF1234567))
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
      var expect = 0x12345678 + 0x23456789 + 0x3456789A + 0x456789AB +
                   0x56789ABC + 0x6789ABCD + 0x789ABCDE + 0x89ABCDEF +
                   0x9ABCDEF1 + 0xABCDEF12 + 0xBCDEF123 + 0xCDEF1234 +
                   0xDEF12345 + 0xEF123456 + 0xF1234567
      check test1() == expect
    test "callSoon() behavior test":
      check test2() == CallSoonTests

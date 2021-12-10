#                Chronos Test Suite
#            (c) Copyright 2018-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)
import unittest2
import ../chronos

when defined(nimHasUsed): {.used.}

suite "callSoon() tests suite":
  const CallSoonTests = 10
  var soonTest1 = 0'u
  var timeoutsTest1 = 0
  var timeoutsTest2 = 0
  var soonTest2 = 0

  proc callback1(udata: pointer) {.gcsafe.} =
    soonTest1 = soonTest1 xor cast[uint](udata)

  proc test1(): uint =
    callSoon(callback1, cast[pointer](0x12345678'u))
    callSoon(callback1, cast[pointer](0x23456789'u))
    callSoon(callback1, cast[pointer](0x3456789A'u))
    callSoon(callback1, cast[pointer](0x456789AB'u))
    callSoon(callback1, cast[pointer](0x56789ABC'u))
    callSoon(callback1, cast[pointer](0x6789ABCD'u))
    callSoon(callback1, cast[pointer](0x789ABCDE'u))
    callSoon(callback1, cast[pointer](0x89ABCDEF'u))
    callSoon(callback1, cast[pointer](0x9ABCDEF1'u))
    callSoon(callback1, cast[pointer](0xABCDEF12'u))
    callSoon(callback1, cast[pointer](0xBCDEF123'u))
    callSoon(callback1, cast[pointer](0xCDEF1234'u))
    callSoon(callback1, cast[pointer](0xDEF12345'u))
    callSoon(callback1, cast[pointer](0xEF123456'u))
    callSoon(callback1, cast[pointer](0xF1234567'u))
    callSoon(callback1, cast[pointer](0x12345678'u))
    ## All callbacks must be processed exactly with 1 poll() call.
    poll()
    result = soonTest1

  proc testProc() {.async.} =
    for i in 1..CallSoonTests:
      await sleepAsync(100.milliseconds)
      timeoutsTest1 += 1

  var callbackproc: proc(udata: pointer) {.gcsafe, raises: [Defect].}
  callbackproc = proc (udata: pointer) {.gcsafe, raises: [Defect].} =
    timeoutsTest2 += 1
    {.gcsafe.}:
      callSoon(callbackproc)

  proc test2(timers, callbacks: var int) =
    callSoon(callbackproc)
    waitFor(testProc())
    timers = timeoutsTest1
    callbacks = timeoutsTest2

  proc testCallback(udata: pointer) =
    soonTest2 = 987654321

  proc test3(): bool =
    callSoon(testCallback)
    poll()
    result = soonTest2 == 987654321

  test "User-defined callback argument test":
    var values = [0x12345678'u, 0x23456789'u, 0x3456789A'u, 0x456789AB'u,
                  0x56789ABC'u, 0x6789ABCD'u, 0x789ABCDE'u, 0x89ABCDEF'u,
                  0x9ABCDEF1'u, 0xABCDEF12'u, 0xBCDEF123'u, 0xCDEF1234'u,
                  0xDEF12345'u, 0xEF123456'u, 0xF1234567'u, 0x12345678'u]
    var expect = 0'u
    for item in values:
      expect = expect xor item
    check test1() == expect
  test "`Asynchronous dead end` #7193 test":
    var timers, callbacks: int
    test2(timers, callbacks)
    check:
      timers == CallSoonTests
      callbacks > CallSoonTests * 2
  test "`callSoon() is not working prior getGlobalDispatcher()` #7192 test":
    check test3() == true

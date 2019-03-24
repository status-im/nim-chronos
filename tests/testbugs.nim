#                Chronos Test Suite
#            (c) Copyright 2018-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

import unittest
import ../chronos

const HELLO_PORT = 45679
const TEST_MSG = "testmsg"
const MSG_LEN = TEST_MSG.len()

type
  CustomData = ref object
    test: string

proc udp4DataAvailable(transp: DatagramTransport,
                       data: seq[byte],
                       remote: TransportAddress,
                       error: OSErrorCode): Future[void] {.async, gcsafe.} =
  var udata = getUserData[CustomData](transp)
  var expect = TEST_MSG
  if udata.test == "CHECK" and len(data) == MSG_LEN and
     equalMem(unsafeAddr data[0], addr expect[0], len(data)):
    udata.test = "OK"
  transp.close()

proc issue6(): Future[bool] {.async.} =
  var myself = initTAddress("127.0.0.1:" & $HELLO_PORT)
  var data = CustomData()
  data.test = "CHECK"
  var dsock4 = newDatagramTransport(udp4DataAvailable, udata = data,
                                    local = myself)
  await dsock4.sendTo(myself, TEST_MSG, MSG_LEN)
  await dsock4.join()
  if data.test == "OK":
    result = true

when isMainModule:
  suite "Asynchronous issues test suite":
    test "Issue #6":
      var res = waitFor(issue6())
      check res == true

#              Asyncdispatch2 Test Suite
#                 (c) Copyright 2018
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

import strutils, unittest
import ../asyncdispatch2, ../asyncdispatch2/timer

const TimeoutPeriod = 2000

proc serveClient1(server: StreamServer,
                  transp: StreamTransport, udata: pointer) {.async.} =
  var data = await transp.readLine()
  if len(data) == 0:
    doAssert(transp.atEof())
  if data == "PAUSE":
    server.pause()
    data = "DONE\r\n"
    var res = await transp.write(cast[pointer](addr data[0]), len(data))
    doAssert(res == len(data))
    await sleepAsync(TimeoutPeriod)
    server.start()
  elif data == "CHECK":
    data = "CONFIRM\r\n"
    var res = await transp.write(cast[pointer](addr data[0]), len(data))
    doAssert(res == len(data))
    transp.close()

proc swarmWorker1(address: TransportAddress): Future[int] {.async.} =
  var transp1 = await connect(address)
  var data = "PAUSE\r\n"
  var res = await transp1.write(cast[pointer](addr data[0]), len(data))
  doAssert(res == len(data))
  var answer = await transp1.readLine()
  doAssert(answer == "DONE")
  var st = fastEpochTime()
  var transp2 = await connect(address)
  data = "CHECK\r\n"
  res = await transp2.write(cast[pointer](addr data[0]), len(data))
  doAssert(res == len(data))
  var confirm = await transp2.readLine()
  doAssert(confirm == "CONFIRM")
  var et = fastEpochTime()
  result = int(et - st)

proc test1(): Future[int] {.async.} =
  var ta = initTAddress("127.0.0.1:31354")
  var server = createStreamServer(ta, serveClient1, {ReuseAddr})
  server.start()
  result = await swarmWorker1(ta)
  server.stop()
  server.close()

when isMainModule:
  suite "Server's test suite":
    test "Server pause/resume test":
      check waitFor(test1()) >= TimeoutPeriod

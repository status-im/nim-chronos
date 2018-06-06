#              Asyncdispatch2 Test Suite
#                 (c) Copyright 2018
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

import strutils, unittest
import ../asyncdispatch2

proc serveStreamClient(server: StreamServer,
                       transp: StreamTransport) {.async.} =
  discard

proc serveDatagramClient(transp: DatagramTransport,
                         pbytes: pointer, nbytes: int,
                         raddr: TransportAddress,
                         udata: pointer): Future[void] {.async.} =
  discard

proc test1(): bool =
  var ta = initTAddress("127.0.0.1:31354")
  var server1 = createStreamServer(ta, serveStreamClient, {ReuseAddr})
  server1.start()
  server1.stop()
  server1.close()
  var server2 = createStreamServer(ta, serveStreamClient, {ReuseAddr})
  server2.start()
  server2.stop()
  server2.close()
  result = true

proc test2(): bool =
  var ta = initTAddress("127.0.0.1:31354")
  var server1 = createDatagramServer(ta, serveDatagramClient, {ReuseAddr})
  server1.start()
  server1.stop()
  server1.close()
  var server2 = createDatagramServer(ta, serveDatagramClient, {ReuseAddr})
  server2.start()
  server2.stop()
  server2.close()
  result = true

when isMainModule:
  suite "Server's test suite":
    test "Stream Server start/stop test":
      check test1() == true
    test "Datagram Server start/stop test":
      check test2() == true

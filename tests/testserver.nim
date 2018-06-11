#              Asyncdispatch2 Test Suite
#                 (c) Copyright 2018
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

import strutils, unittest
import ../asyncdispatch2

type
  CustomServer = ref object of StreamServer
    test1: string
    test2: string
    test3: string

  CustomTransport = ref object of StreamTransport
    test: string

  CustomData = ref object
    test: string

proc serveStreamClient(server: StreamServer,
                       transp: StreamTransport) {.async.} =
  discard

proc serveCustomStreamClient(server: StreamServer,
                             transp: StreamTransport) {.async.} =
  var cserver = cast[CustomServer](server)
  var ctransp = cast[CustomTransport](transp)
  cserver.test1 = "CONNECTION"
  cserver.test2 = ctransp.test
  cserver.test3 = await transp.readLine()
  var answer = "ANSWER\r\n"
  discard await transp.write(answer)
  transp.close()

proc serveUdataStreamClient(server: StreamServer,
                            transp: StreamTransport) {.async.} =
  var udata = getUserData[CustomData](server)
  var line = await transp.readLine()
  var msg = line & udata.test & "\r\n"
  discard await transp.write(msg)
  transp.close()

proc customServerTransport(server: StreamServer,
                           fd: AsyncFD): StreamTransport =
  var transp = CustomTransport()
  transp.test = "CUSTOM"
  result = cast[StreamTransport](transp)

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

proc client1(server: CustomServer, ta: TransportAddress) {.async.} =
  var transp = CustomTransport()
  transp.test = "CLIENT"
  server.start()
  var ptransp = await connect(ta, child = transp)
  var etransp = cast[CustomTransport](ptransp)
  doAssert(etransp.test == "CLIENT")
  var msg = "TEST\r\n"
  discard await transp.write(msg)
  var line = await transp.readLine()
  transp.close()
  server.stop()
  server.close()

proc client2(server: StreamServer,
             ta: TransportAddress): Future[bool] {.async.} =
  server.start()
  var transp = await connect(ta)
  var msg = "TEST\r\n"
  discard await transp.write(msg)
  var line = await transp.readLine()
  result = (line == "TESTCUSTOMDATA")
  transp.close()
  server.stop()
  server.close()

proc test3(): bool =
  var server = CustomServer()
  server.test1 = "TEST"
  var ta = initTAddress("127.0.0.1:31354")
  var pserver = createStreamServer(ta, serveCustomStreamClient, {ReuseAddr},
                                   child = cast[StreamServer](server),
                                   init = customServerTransport)
  waitFor client1(server, ta)
  result = (server.test1 == "CONNECTION") and (server.test2 == "CUSTOM")

proc test4(): bool =
  var co = CustomData()
  co.test = "CUSTOMDATA"
  var ta = initTAddress("127.0.0.1:31354")
  var server = createStreamServer(ta, serveUdataStreamClient, {ReuseAddr},
                                  udata = co)
  result = waitFor client2(server, ta)

when isMainModule:
  suite "Server's test suite":
    test "Stream Server start/stop test":
      check test1() == true
    test "Stream Server inherited object test":
      check test3() == true
    test "Datagram Server start/stop test":
      check test2() == true
    test "StreamServer[T] test":
      check test4() == true

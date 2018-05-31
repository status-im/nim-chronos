#              Asyncdispatch2 Test Suite
#                 (c) Copyright 2018
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

import strutils, net, unittest
import ../asyncdispatch2

const
  TestsCount = 10000
  ClientsCount = 100
  MessagesCount = 100

proc client1(transp: DatagramTransport, pbytes: pointer, nbytes: int,
             raddr: TransportAddress, udata: pointer): Future[void] {.async.} =
  if not isNil(pbytes):
    var data = newString(nbytes + 1)
    copyMem(addr data[0], pbytes, nbytes)
    data.setLen(nbytes)
    if data.startsWith("REQUEST"):
      var numstr = data[7..^1]
      var num = parseInt(numstr)
      var ans = "ANSWER" & $num
      await transp.sendTo(addr ans[0], len(ans), raddr)
    else:
      var err = "ERROR"
      await transp.sendTo(addr err[0], len(err), raddr)
  else:
    ## Read operation failed with error
    var counterPtr = cast[ptr int](udata)
    counterPtr[] = -1
    transp.close()

proc client2(transp: DatagramTransport, pbytes: pointer, nbytes: int,
             raddr: TransportAddress, udata: pointer): Future[void] {.async.} =
  if not isNil(pbytes):
    var data = newString(nbytes + 1)
    copyMem(addr data[0], pbytes, nbytes)
    data.setLen(nbytes)
    if data.startsWith("ANSWER"):
      var counterPtr = cast[ptr int](udata)
      counterPtr[] = counterPtr[] + 1
      if counterPtr[] == TestsCount:
        transp.close()
      else:
        var ta = strAddress("127.0.0.1:33336")
        var req = "REQUEST" & $counterPtr[]
        await transp.sendTo(addr req[0], len(req), ta)
    else:
      var counterPtr = cast[ptr int](udata)
      counterPtr[] = -1
      transp.close()
  else:
    ## Read operation failed with error
    var counterPtr = cast[ptr int](udata)
    counterPtr[] = -1
    transp.close()

proc client3(transp: DatagramTransport, pbytes: pointer, nbytes: int,
             raddr: TransportAddress, udata: pointer): Future[void] {.async.} =
  if not isNil(pbytes):
    var data = newString(nbytes + 1)
    copyMem(addr data[0], pbytes, nbytes)
    data.setLen(nbytes)
    if data.startsWith("ANSWER"):
      var counterPtr = cast[ptr int](udata)
      counterPtr[] = counterPtr[] + 1
      if counterPtr[] == TestsCount:
        transp.close()
      else:
        var req = "REQUEST" & $counterPtr[]
        await transp.send(addr req[0], len(req))
    else:
      var counterPtr = cast[ptr int](udata)
      counterPtr[] = -1
      transp.close()
  else:
    ## Read operation failed with error
    var counterPtr = cast[ptr int](udata)
    counterPtr[] = -1
    transp.close()

proc client4(transp: DatagramTransport, pbytes: pointer, nbytes: int,
             raddr: TransportAddress, udata: pointer): Future[void] {.async.} =
  if not isNil(pbytes):
    var data = newString(nbytes + 1)
    copyMem(addr data[0], pbytes, nbytes)
    data.setLen(nbytes)
    if data.startsWith("ANSWER"):
      var counterPtr = cast[ptr int](udata)
      counterPtr[] = counterPtr[] + 1
      if counterPtr[] == MessagesCount:
        transp.close()
      else:
        var req = "REQUEST" & $counterPtr[]
        await transp.send(addr req[0], len(req))
    else:
      var counterPtr = cast[ptr int](udata)
      counterPtr[] = -1
      transp.close()
  else:
    ## Read operation failed with error
    var counterPtr = cast[ptr int](udata)
    counterPtr[] = -1
    transp.close()

proc client5(transp: DatagramTransport, pbytes: pointer, nbytes: int,
             raddr: TransportAddress, udata: pointer): Future[void] {.async.} =
  if not isNil(pbytes):
    var data = newString(nbytes + 1)
    copyMem(addr data[0], pbytes, nbytes)
    data.setLen(nbytes)
    if data.startsWith("ANSWER"):
      var counterPtr = cast[ptr int](udata)
      counterPtr[] = counterPtr[] + 1
      if counterPtr[] == MessagesCount:
        transp.close()
      else:
        var ta = strAddress("127.0.0.1:33337")
        var req = "REQUEST" & $counterPtr[]
        await transp.sendTo(addr req[0], len(req), ta)
    else:
      var counterPtr = cast[ptr int](udata)
      counterPtr[] = -1
      transp.close()
  else:
    ## Read operation failed with error
    var counterPtr = cast[ptr int](udata)
    counterPtr[] = -1
    transp.close()

proc test1(): Future[int] {.async.} =
  var ta = strAddress("127.0.0.1:33336")
  var counter = 0
  var dgram1 = newDatagramTransport(client1, udata = addr counter, local = ta)
  var dgram2 = newDatagramTransport(client2, udata = addr counter)
  var data = "REQUEST0"
  await dgram2.sendTo(addr data[0], len(data), ta)
  await dgram2.join()
  dgram1.close()
  result = counter

proc test2(): Future[int] {.async.} =
  var ta = strAddress("127.0.0.1:33337")
  var counter = 0
  var dgram1 = newDatagramTransport(client1, udata = addr counter, local = ta)
  var dgram2 = newDatagramTransport(client3, udata = addr counter, remote = ta)
  var data = "REQUEST0"
  await dgram2.send(addr data[0], len(data))
  await dgram2.join()
  dgram1.close()
  result = counter

proc waitAll(futs: seq[Future[void]]): Future[void] =
  var counter = len(futs)
  var retFuture = newFuture[void]("waitAll")
  proc cb(udata: pointer) =
    dec(counter)
    if counter == 0:
      retFuture.complete()
  for fut in futs:
    fut.addCallback(cb)
  return retFuture

proc test3(bounded: bool): Future[int] {.async.} =
  var ta = strAddress("127.0.0.1:33337")
  var counter = 0
  var dgram1 = newDatagramTransport(client1, udata = addr counter, local = ta)
  var clients = newSeq[Future[void]](ClientsCount)
  var counters = newSeq[int](ClientsCount)
  var dgram: DatagramTransport
  for i in 0..<ClientsCount:
    var data = "REQUEST0"
    if bounded:
      dgram = newDatagramTransport(client4, udata = addr counters[i],
                                   remote = ta)
      await dgram.send(addr data[0], len(data))
    else:
      dgram = newDatagramTransport(client5, udata = addr counters[i])
      await dgram.sendTo(addr data[0], len(data), ta)
    clients[i] = dgram.join()

  await waitAll(clients)
  dgram1.close()
  result = 0
  for i in 0..<ClientsCount:
    result += counters[i]

proc swarmWorker(address: TransportAddress): Future[int] {.async.} =
  var counter = 0
  var results = newSeq[int](MessagesCount)
  var future = newFuture[void]("testdatagram.client.wait")

  proc receiver(transp: DatagramTransport,
                pbytes: pointer, nbytes: int,
                raddr: TransportAddress,
                udata: pointer): Future[void] {.async.} =
    if not isNil(pbytes) and nbytes > 0:
      var answer = newString(nbytes + 1)
      copyMem(addr answer[0], pbytes, nbytes)
      answer.setLen(nbytes)
      doAssert(answer.startsWith("ANSWER"))
      var numstr = answer[6..^1]
      var num = parseInt(numstr)
      doAssert(num < MessagesCount)
      results[num] = 1
      inc(counter)
      if not future.finished:
        future.complete()

  var transp = newDatagramTransport(receiver,
                                    udata = addr counter,
                                    remote = address)
  for i in 0..<MessagesCount:
    var data = "REQUEST" & $i
    await transp.send(addr data[0], len(data))
    # We need to wait answer here, or we can overflow OS network
    # buffer and some datagrams will be dropped.
    await future
    future = newFuture[void]("testdatagram.client.wait")

  transp.close()
  result = 0
  for i in 0..<MessagesCount:
    if results[i] == 1:
      inc(result)

proc waitAll[T](futs: seq[Future[T]]): Future[void] =
  var counter = len(futs)
  var retFuture = newFuture[void]("waitAll")
  proc cb(udata: pointer) =
    dec(counter)
    if counter == 0:
      retFuture.complete()
  for fut in futs:
    fut.addCallback(cb)
  return retFuture

proc swarmManager(address: TransportAddress): Future[int] {.async.} =
  var retFuture = newFuture[void]("swarm.manager.datagram")
  var workers = newSeq[Future[int]](ClientsCount)
  var count = ClientsCount
  for i in 0..<ClientsCount:
    workers[i] = swarmWorker(address)
  await waitAll(workers)
  for i in 0..<ClientsCount:
    var res = workers[i].read()
    result += res

proc serveDatagramClient(transp: DatagramTransport,
                         pbytes: pointer, nbytes: int,
                         raddr: TransportAddress,
                         udata: pointer): Future[void] {.async.} =
  doAssert(not isNil(pbytes) and nbytes > 0)
  var request = newString(nbytes + 1)
  copyMem(addr request[0], pbytes, nbytes)
  request.setLen(nbytes)
  doAssert(request.startsWith("REQUEST"))
  var numstr = request[7..^1]
  var num = parseInt(numstr)
  var answer = "ANSWER" & $num
  await transp.sendTo(addr answer[0], len(answer), raddr)

proc test4(): Future[int] {.async.} =
  var ta = strAddress("127.0.0.1:31346")
  var counter = 0
  var server = createDatagramServer(ta, serveDatagramClient, {ReuseAddr})
  server.start()
  result = await swarmManager(ta)
  server.stop()
  server.close()

when isMainModule:
  echo waitFor(test4())
  const
    m1 = "Unbounded test (" & $TestsCount & " messages)"
    m2 = "Bounded test (" & $TestsCount & " messages)"
    m3 = "Unbounded multiple clients with messages (" & $ClientsCount &
         " clients x " & $MessagesCount & " messages)"
    m4 = "Bounded multiple clients with messages (" & $ClientsCount &
         " clients x " & $MessagesCount & " messages)"
    m5 = "DatagramServer multiple clients with messages (" & $ClientsCount &
         " clients x " & $MessagesCount & " messages)"
  suite "Datagram Transport test suite":
    test m1:
      check waitFor(test1()) == TestsCount
    test m2:
      check waitFor(test2()) == TestsCount
    test m3:
      check waitFor(test3(false)) == ClientsCount * MessagesCount
    test m4:
      check waitFor(test3(true)) == ClientsCount * MessagesCount
    test m5:
      check waitFor(test4()) == ClientsCount * MessagesCount

import strutils, net, unittest
import ../asyncdispatch2

const
  TestsCount = 5000
  ClientsCount = 2
  MessagesCount = 1000

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
    echo "SERVER ERROR HAPPENS QUITING"
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
        var ta: TransportAddress
        ta.address = parseIpAddress("127.0.0.1")
        ta.port = Port(33336)
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
        echo $counterPtr[] & "-SEND"
        await transp.send(addr req[0], len(req))
    else:
      echo "ERROR1 [" & $data & "]"
      var counterPtr = cast[ptr int](udata)
      counterPtr[] = -1
      transp.close()
  else:
    ## Read operation failed with error
    echo "ERROR2"
    var counterPtr = cast[ptr int](udata)
    counterPtr[] = -1
    transp.close()    

proc test1(): Future[int] {.async.} =
  var ta: TransportAddress
  var counter = 0
  ta.address = parseIpAddress("127.0.0.1")
  ta.port = Port(33336)
  var dgram1 = newDatagramTransport(client1, udata = addr counter, local = ta)
  var dgram2 = newDatagramTransport(client2, udata = addr counter)
  var data = "REQUEST0"
  await dgram2.sendTo(addr data[0], len(data), ta)
  await dgram2.join()
  dgram1.close()
  result = counter

proc test2(): Future[int] {.async.} =
  var ta: TransportAddress
  var counter = 0
  ta.address = parseIpAddress("127.0.0.1")
  ta.port = Port(33337)
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

proc test3(): Future[int] {.async.} =
  var ta: TransportAddress
  ta.address = parseIpAddress("127.0.0.1")
  ta.port = Port(33337)
  var counter = 0
  var dgram1 = newDatagramTransport(client1, udata = addr counter, local = ta)
  var clients = newSeq[Future[void]](ClientsCount)
  var counters = newSeq[int](ClientsCount)
  for i in 0..<ClientsCount:
    var dgram = newDatagramTransport(client4, udata = addr counters[i],
                                     remote = ta)
    echo "FIRST SEND at " & toHex(cast[uint](dgram))
    var data = "REQUEST0"
    await dgram.sendTo(addr data[0], len(data), ta)
    clients[i] = dgram.join()
  # await dgram1.join()
  await waitAll(clients)
  dgram1.close()
  result = 0
  for i in 0..<ClientsCount:
    result += counters[i]

when isMainModule:
  suite "Datagram Transport test suite":
    # test "Unbounded test (5000 times)":
    #   check waitFor(test1()) == TestsCount
    # test "Bound test (5000 times)":
    #   check waitFor(test2()) == TestsCount
    test "Multiple clients with messages":
      echo waitFor(test3())

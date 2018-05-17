import strutils, net, unittest
import ../asyncdispatch2

const
  ClientsCount = 1
  MessagesCount = 100000

proc serveClient1(transp: StreamTransport, udata: pointer) {.async.} =
  echo "SERVER STARTING (0x" & toHex[uint](cast[uint](transp)) & ")"
  while not transp.atEof():
    var data = await transp.readLine()
    echo "SERVER READ [" & data & "]"
    if data.startsWith("REQUEST"):
      var numstr = data[7..^1]
      var num = parseInt(numstr)
      var ans = "ANSWER" & $num & "\r\n"
      var res = await transp.write(cast[pointer](addr ans[0]), len(ans))
      # doAssert(res == len(ans))
  echo "SERVER EXITING (0x" & toHex[uint](cast[uint](transp)) & ")"

proc swarmWorker(address: TransportAddress) {.async.} =
  echo "CONNECTING TO " & $address
  var transp = await connect(address)
  echo "CONNECTED"
  for i in 0..<MessagesCount:
    echo "MESSAGE " & $i
    var data = "REQUEST" & $i & "\r\n"
    var res = await transp.write(cast[pointer](addr data[0]), len(data))
    echo "CLIENT WRITE COMPLETED"
    assert(res == len(data))
    var ans = await transp.readLine()
    if ans.startsWith("ANSWER"):
      var numstr = ans[6..^1]
      var num = parseInt(numstr)
      doAssert(num == i)
  transp.close()

proc swarmManager(address: TransportAddress): Future[void] =
  var retFuture = newFuture[void]("swarm.manager")
  var workers = newSeq[Future[void]](ClientsCount)
  var count = ClientsCount
  proc cb(data: pointer) {.gcsafe.} =
    if not retFuture.finished:
      dec(count)
      if count == 0:
        retFuture.complete()
  for i in 0..<ClientsCount:
    workers[i] = swarmWorker(address)
    workers[i].addCallback(cb)
  return retFuture

when isMainModule:
  var ta: TransportAddress
  ta.address = parseIpAddress("127.0.0.1")
  ta.port = Port(31344)
  var server = createStreamServer(ta, {ReuseAddr}, serveClient1)
  server.start()
  waitFor(swarmManager(ta))



# proc processClient*(t: StreamTransport, udata: pointer) {.async.} =
#   var data = newSeq[byte](10)
#   var f: File
#   echo "CONNECTED FROM ", $t.remoteAddress()
#   if not f.open("timer.nim"):
#     echo "ERROR OPENING FILE"
#   echo f.getFileHandle()
#   # try:
#   when defined(windows):
#     await t.writeFile(int(get_osfhandle(f.getFileHandle())))
#   else:
#     await t.writeFile(int(f.getFileHandle()))

# proc test2() {.async.} =
#   var s = createStreamServer(parseIpAddress("0.0.0.0"), Port(31337),
#                              {ReusePort}, processClient)
#   s.start()
#   await s.join()

# when isMainModule:
#   waitFor(test2())

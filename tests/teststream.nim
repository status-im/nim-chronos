#              Asyncdispatch2 Test Suite
#                 (c) Copyright 2018
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

import strutils, net, unittest, os
import ../asyncdispatch2

when defined(windows):
  import winlean
else:
  import posix

const
  ClientsCount = 50
  MessagesCount = 50
  MessageSize = 20
  FilesCount = 50
  FilesTestName = "tests/teststream.nim"

proc serveClient1(transp: StreamTransport, udata: pointer) {.async.} =
  while not transp.atEof():
    var data = await transp.readLine()
    if len(data) == 0:
      doAssert(transp.atEof())
      break
    doAssert(data.startsWith("REQUEST"))
    var numstr = data[7..^1]
    var num = parseInt(numstr)
    var ans = "ANSWER" & $num & "\r\n"
    var res = await transp.write(cast[pointer](addr ans[0]), len(ans))
    doAssert(res == len(ans))
  transp.close()

proc serveClient2(transp: StreamTransport, udata: pointer) {.async.} =
  var buffer: array[20, char]
  var check = "REQUEST"
  while not transp.atEof():
    zeroMem(addr buffer[0], MessageSize)
    try:
      await transp.readExactly(addr buffer[0], MessageSize)
    except TransportIncompleteError:
      break
    doAssert(equalMem(addr buffer[0], addr check[0], len(check)))
    var numstr = ""
    var i = 7
    while i < MessageSize and (buffer[i] in {'0'..'9'}):
      numstr.add(buffer[i])
      inc(i)
    var num = parseInt(numstr)
    var ans = "ANSWER" & $num
    zeroMem(addr buffer[0], MessageSize)
    copyMem(addr buffer[0], addr ans[0], len(ans))
    var res = await transp.write(cast[pointer](addr buffer[0]), MessageSize)
    doAssert(res == MessageSize)
  transp.close()

proc serveClient3(transp: StreamTransport, udata: pointer) {.async.} =
  var buffer: array[20, char]
  var check = "REQUEST"
  var suffixStr = "SUFFIX"
  var suffix = newSeq[byte](6)
  copyMem(addr suffix[0], addr suffixStr[0], len(suffixStr))
  while not transp.atEof():
    zeroMem(addr buffer[0], MessageSize)
    var res = await transp.readUntil(addr buffer[0], MessageSize, suffix)
    doAssert(equalMem(addr buffer[0], addr check[0], len(check)))
    var numstr = ""
    var i = 7
    while i < MessageSize and (buffer[i] in {'0'..'9'}):
      numstr.add(buffer[i])
      inc(i)
    var num = parseInt(numstr)
    doAssert(len(numstr) < 8)
    var ans = "ANSWER" & $num & "SUFFIX"
    zeroMem(addr buffer[0], MessageSize)
    copyMem(addr buffer[0], addr ans[0], len(ans))
    res = await transp.write(cast[pointer](addr buffer[0]), len(ans))
    doAssert(res == len(ans))
  transp.close()

proc serveClient4(transp: StreamTransport, udata: pointer) {.async.} =
  var pathname = await transp.readLine()
  var size = await transp.readLine()
  var sizeNum = parseInt(size)
  doAssert(sizeNum >= 0)
  var rbuffer = newSeq[byte](sizeNum)
  await transp.readExactly(addr rbuffer[0], sizeNum)
  var lbuffer = readFile(pathname)
  doAssert(len(lbuffer) == sizeNum)
  doAssert(equalMem(addr rbuffer[0], addr lbuffer[0], sizeNum))
  var answer = "OK\r\n"
  var res = await transp.write(cast[pointer](addr answer[0]), len(answer))
  doAssert(res == len(answer))

proc swarmWorker1(address: TransportAddress): Future[int] {.async.} =
  var transp = await connect(address)
  for i in 0..<MessagesCount:
    var data = "REQUEST" & $i & "\r\n"
    var res = await transp.write(cast[pointer](addr data[0]), len(data))
    assert(res == len(data))
    var ans = await transp.readLine()
    doAssert(ans.startsWith("ANSWER"))
    var numstr = ans[6..^1]
    var num = parseInt(numstr)
    doAssert(num == i)
    inc(result)
  transp.close()

proc swarmWorker2(address: TransportAddress): Future[int] {.async.} =
  var transp = await connect(address)
  var buffer: array[MessageSize, char]
  var check = "ANSWER"
  for i in 0..<MessagesCount:
    var data = "REQUEST" & $i & "\r\n"
    zeroMem(addr buffer[0], MessageSize)
    copyMem(addr buffer[0], addr data[0], min(MessageSize, len(data)))
    var res = await transp.write(cast[pointer](addr buffer[0]), MessageSize)
    doAssert(res == MessageSize)
    zeroMem(addr buffer[0], MessageSize)
    await transp.readExactly(addr buffer[0], MessageSize)
    doAssert(equalMem(addr buffer[0], addr check[0], len(check)))
    var numstr = ""
    var k = 6
    while k < MessageSize and (buffer[k] in {'0'..'9'}):
      numstr.add(buffer[k])
      inc(k)
    var num = parseInt(numstr)
    doAssert(num == i)
    inc(result)
  transp.close()

proc swarmWorker3(address: TransportAddress): Future[int] {.async.} =
  var transp = await connect(address)
  var buffer: array[MessageSize, char]
  var check = "ANSWER"
  var suffixStr = "SUFFIX"
  var suffix = newSeq[byte](6)
  copyMem(addr suffix[0], addr suffixStr[0], len(suffixStr))
  for i in 0..<MessagesCount:
    var data = "REQUEST" & $i & "SUFFIX"
    doAssert(len(data) <= MessageSize)
    zeroMem(addr buffer[0], MessageSize)
    copyMem(addr buffer[0], addr data[0], len(data))
    var res = await transp.write(cast[pointer](addr buffer[0]), len(data))
    doAssert(res == len(data))
    zeroMem(addr buffer[0], MessageSize)
    res = await transp.readUntil(addr buffer[0], MessageSize, suffix)
    doAssert(equalMem(addr buffer[0], addr check[0], len(check)))
    var numstr = ""
    var k = 6
    while k < MessageSize and (buffer[k] in {'0'..'9'}):
      numstr.add(buffer[k])
      inc(k)
    var num = parseInt(numstr)
    doAssert(num == i)
    inc(result)
  transp.close()

proc swarmWorker4(address: TransportAddress): Future[int] {.async.} =
  var transp = await connect(address)
  var ssize: string
  var handle = 0
  var name = FilesTestName
  var size = int(getFileSize(FilesTestName))
  var fhandle = open(FilesTestName)
  when defined(windows):
    handle = int(get_osfhandle(getFileHandle(fhandle)))
  else:
    handle = int(getFileHandle(fhandle))
  doAssert(handle > 0)
  name = name & "\r\n"
  ssize = $size & "\r\n"
  var res = await transp.write(cast[pointer](addr name[0]), len(name))
  doAssert(res == len(name))
  res = await transp.write(cast[pointer](addr ssize[0]), len(ssize))
  doAssert(res == len(ssize))
  await transp.writeFile(handle, 0'u, size)
  var ans = await transp.readLine()
  doAssert(ans == "OK")
  result = 1
  transp.close()

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

proc swarmManager1(address: TransportAddress): Future[int] {.async.} =
  var retFuture = newFuture[void]("swarm.manager.readLine")
  var workers = newSeq[Future[int]](ClientsCount)
  var count = ClientsCount
  for i in 0..<ClientsCount:
    workers[i] = swarmWorker1(address)
  await waitAll(workers)
  for i in 0..<ClientsCount:
    var res = workers[i].read()
    result += res

proc swarmManager2(address: TransportAddress): Future[int] {.async.} =
  var retFuture = newFuture[void]("swarm.manager.readExactly")
  var workers = newSeq[Future[int]](ClientsCount)
  var count = ClientsCount
  for i in 0..<ClientsCount:
    workers[i] = swarmWorker2(address)
  await waitAll(workers)
  for i in 0..<ClientsCount:
    var res = workers[i].read()
    result += res

proc swarmManager3(address: TransportAddress): Future[int] {.async.} =
  var retFuture = newFuture[void]("swarm.manager.readUntil")
  var workers = newSeq[Future[int]](ClientsCount)
  var count = ClientsCount
  for i in 0..<ClientsCount:
    workers[i] = swarmWorker3(address)
  await waitAll(workers)
  for i in 0..<ClientsCount:
    var res = workers[i].read()
    result += res

proc swarmManager4(address: TransportAddress): Future[int] {.async.} =
  var retFuture = newFuture[void]("swarm.manager.writeFile")
  var workers = newSeq[Future[int]](FilesCount)
  var count = FilesCount
  for i in 0..<FilesCount:
    workers[i] = swarmWorker4(address)
  await waitAll(workers)
  for i in 0..<FilesCount:
    var res = workers[i].read()
    result += res

proc test1(): Future[int] {.async.} =
  var ta = strAddress("127.0.0.1:31344")
  var server = createStreamServer(ta, {ReuseAddr}, serveClient1)
  server.start()
  result = await swarmManager1(ta)
  server.stop()
  server.close()

proc test2(): Future[int] {.async.} =
  var ta = strAddress("127.0.0.1:31345")
  var counter = 0
  var server = createStreamServer(ta, {ReuseAddr}, serveClient2)
  server.start()
  result = await swarmManager2(ta)
  server.stop()
  server.close()

proc test3(): Future[int] {.async.} =
  var ta = strAddress("127.0.0.1:31346")
  var counter = 0
  var server = createStreamServer(ta, {ReuseAddr}, serveClient3)
  server.start()
  result = await swarmManager3(ta)
  server.stop()
  server.close()

proc test4(): Future[int] {.async.} =
  var ta = strAddress("127.0.0.1:31347")
  var counter = 0
  var server = createStreamServer(ta, {ReuseAddr}, serveClient4)
  server.start()
  result = await swarmManager4(ta)
  server.stop()
  server.close()

when isMainModule:
  const
    m1 = "readLine() multiple clients with messages (" & $ClientsCount &
         " clients x " & $MessagesCount & " messages)"
    m2 = "readExactly() multiple clients with messages (" & $ClientsCount &
         " clients x " & $MessagesCount & " messages)"
    m3 = "readUntil() multiple clients with messages (" & $ClientsCount &
         " clients x " & $MessagesCount & " messages)"
    m4 = "writeFile() multiple clients (" & $FilesCount & " files)"

  suite "Stream Transport test suite":
    test m1:
      check waitFor(test1()) == ClientsCount * MessagesCount
    test m2:
      check waitFor(test2()) == ClientsCount * MessagesCount
    test m3:
      check waitFor(test3()) == ClientsCount * MessagesCount
    test m4:
      check waitFor(test4()) == FilesCount

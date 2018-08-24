#              Asyncdispatch2 Test Suite
#                 (c) Copyright 2018
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

import strutils, unittest, os
import ../asyncdispatch2

when defined(windows):
  import winlean
else:
  import posix

const
  ConstantMessage = "SOMEDATA"
  BigMessagePattern = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  FilesTestName = "tests/teststream.nim"
when sizeof(int) == 8:
  const
    BigMessageCount = 1000
    ClientsCount = 100
    MessagesCount = 100
    MessageSize = 20
    FilesCount = 100
elif sizeof(int) == 4:
  const
    BigMessageCount = 200
    ClientsCount = 20
    MessagesCount = 20
    MessageSize = 20
    FilesCount = 10

proc serveClient1(server: StreamServer, transp: StreamTransport) {.async.} =
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
  await transp.join()

proc serveClient2(server: StreamServer, transp: StreamTransport) {.async.} =
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
  await transp.join()

proc serveClient3(server: StreamServer, transp: StreamTransport) {.async.} =
  var buffer: array[20, char]
  var check = "REQUEST"
  var suffixStr = "SUFFIX"
  var suffix = newSeq[byte](6)
  copyMem(addr suffix[0], addr suffixStr[0], len(suffixStr))
  var counter = MessagesCount
  while counter > 0:
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
    dec(counter)
  transp.close()
  await transp.join()

proc serveClient4(server: StreamServer, transp: StreamTransport) {.async.} =
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
  transp.close()
  await transp.join()

proc serveClient5(server: StreamServer, transp: StreamTransport) {.async.} =
  var data = await transp.read()
  doAssert(len(data) == len(ConstantMessage) * MessagesCount)
  transp.close()
  var expect = ""
  for i in 0..<MessagesCount:
    expect.add(ConstantMessage)
  doAssert(equalMem(addr expect[0], addr data[0], len(data)))
  var counter = cast[ptr int](server.udata)
  dec(counter[])
  if counter[] == 0:
    server.stop()
    server.close()
    await server.join()

proc serveClient6(server: StreamServer, transp: StreamTransport) {.async.} =
  var expect = ConstantMessage
  var skip = await transp.consume(len(ConstantMessage) * (MessagesCount - 1))
  doAssert(skip == len(ConstantMessage) * (MessagesCount - 1))
  var data = await transp.read()
  doAssert(len(data) == len(ConstantMessage))
  transp.close()
  doAssert(equalMem(addr data[0], addr expect[0], len(expect)))
  var counter = cast[ptr int](server.udata)
  dec(counter[])
  if counter[] == 0:
    server.stop()
    server.close()
    await server.join()

proc serveClient7(server: StreamServer, transp: StreamTransport) {.async.} =
  var answer = "DONE\r\n"
  var expect = ""
  var line = await transp.readLine()
  doAssert(len(line) == BigMessageCount * len(BigMessagePattern))
  for i in 0..<BigMessageCount:
    expect.add(BigMessagePattern)
  doAssert(line == expect)
  var res = await transp.write(answer)
  doAssert(res == len(answer))
  transp.close()
  await transp.join()

proc serveClient8(server: StreamServer, transp: StreamTransport) {.async.} =
  var answer = "DONE\r\n"
  var strpattern = BigMessagePattern
  var pattern = newSeq[byte](len(BigMessagePattern))
  var expect = newSeq[byte]()
  var data = newSeq[byte]((BigMessageCount + 1) * len(BigMessagePattern))
  var sep = @[0x0D'u8, 0x0A'u8]
  copyMem(addr pattern[0], addr strpattern[0], len(BigMessagePattern))
  var count = await transp.readUntil(addr data[0], len(data), sep = sep)
  doAssert(count == BigMessageCount * len(BigMessagePattern) + 2)
  for i in 0..<BigMessageCount:
    expect.add(pattern)
  expect.add(sep)
  data.setLen(count)
  doAssert(expect == data)
  var res = await transp.write(answer)
  doAssert(res == len(answer))
  transp.close()
  server.stop()
  server.close()
  await server.join()

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
  await transp.join()

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
  await transp.join()

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
  await transp.join()

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
  var res = await transp.write(cast[pointer](addr name[0]), len(name))
  doAssert(res == len(name))
  ssize = $size & "\r\n"
  res = await transp.write(cast[pointer](addr ssize[0]), len(ssize))
  doAssert(res == len(ssize))
  var checksize = await transp.writeFile(handle, 0'u, size)
  doAssert(checksize == size)
  close(fhandle)
  var ans = await transp.readLine()
  doAssert(ans == "OK")
  result = 1
  transp.close()
  await transp.join()

proc swarmWorker5(address: TransportAddress): Future[int] {.async.} =
  var transp = await connect(address)
  var data = ConstantMessage
  for i in 0..<MessagesCount:
    var res = await transp.write(data)
  result = MessagesCount
  transp.close()
  await transp.join()

proc swarmWorker6(address: TransportAddress): Future[int] {.async.} =
  var transp = await connect(address)
  var data = ConstantMessage
  var seqdata = newSeq[byte](len(data))
  copyMem(addr seqdata[0], addr data[0], len(data))
  for i in 0..<MessagesCount:
    var res = await transp.write(seqdata)
  result = MessagesCount
  transp.close()
  await transp.join()

proc swarmWorker7(address: TransportAddress): Future[int] {.async.} =
  var transp = await connect(address)
  var data = BigMessagePattern
  var crlf = "\r\n"
  for i in 0..<BigMessageCount:
    var res = await transp.write(data)
    doAssert(res == len(data))
  var res = await transp.write(crlf)
  var line = await transp.readLine()
  doAssert(line == "DONE")
  result = 1
  transp.close()
  await transp.join()

proc swarmWorker8(address: TransportAddress): Future[int] {.async.} =
  var transp = await connect(address)
  var data = BigMessagePattern
  var crlf = "\r\n"
  for i in 0..<BigMessageCount:
    var res = await transp.write(data)
    doAssert(res == len(data))
  var res = await transp.write(crlf)
  var line = await transp.readLine()
  doAssert(line == "DONE")
  result = 1
  transp.close()
  await transp.join()

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

proc swarmManager5(address: TransportAddress): Future[int] {.async.} =
  var retFuture = newFuture[void]("swarm.manager.read")
  var workers = newSeq[Future[int]](ClientsCount)
  var count = ClientsCount
  for i in 0..<ClientsCount:
    workers[i] = swarmWorker5(address)
  await waitAll(workers)
  for i in 0..<ClientsCount:
    var res = workers[i].read()
    result += res

proc swarmManager6(address: TransportAddress): Future[int] {.async.} =
  var retFuture = newFuture[void]("swarm.manager.consume")
  var workers = newSeq[Future[int]](ClientsCount)
  var count = ClientsCount
  for i in 0..<ClientsCount:
    workers[i] = swarmWorker6(address)
  await waitAll(workers)
  for i in 0..<ClientsCount:
    var res = workers[i].read()
    result += res

proc test1(): Future[int] {.async.} =
  var ta = initTAddress("127.0.0.1:31344")
  var server = createStreamServer(ta, serveClient1, {ReuseAddr})
  server.start()
  result = await swarmManager1(ta)
  server.stop()
  server.close()
  await server.join()

proc test2(): Future[int] {.async.} =
  var ta = initTAddress("127.0.0.1:31345")
  var counter = 0
  var server = createStreamServer(ta, serveClient2, {ReuseAddr})
  server.start()
  result = await swarmManager2(ta)
  server.stop()
  server.close()
  await server.join()

proc test3(): Future[int] {.async.} =
  var ta = initTAddress("127.0.0.1:31346")
  var counter = 0
  var server = createStreamServer(ta, serveClient3, {ReuseAddr})
  server.start()
  result = await swarmManager3(ta)
  server.stop()
  server.close()
  await server.join()

proc test4(): Future[int] {.async.} =
  var ta = initTAddress("127.0.0.1:31347")
  var server = createStreamServer(ta, serveClient4, {ReuseAddr})
  server.start()
  result = await swarmManager4(ta)
  server.stop()
  server.close()
  await server.join()

proc test5(): Future[int] {.async.} =
  var ta = initTAddress("127.0.0.1:31348")
  var counter = ClientsCount
  var server = createStreamServer(ta, serveClient5, {ReuseAddr},
                                  udata = cast[pointer](addr counter))
  server.start()
  result = await swarmManager5(ta)

proc test6(): Future[int] {.async.} =
  var ta = initTAddress("127.0.0.1:31349")
  var counter = ClientsCount
  var server = createStreamServer(ta, serveClient6, {ReuseAddr},
                                  udata = cast[pointer](addr counter))
  server.start()
  result = await swarmManager6(ta)

proc test7(): Future[int] {.async.} =
  var ta = initTAddress("127.0.0.1:31350")
  var server = createStreamServer(ta, serveClient7, {ReuseAddr})
  server.start()
  result = await swarmWorker7(ta)
  server.stop()
  server.close()
  await server.join()

proc test8(): Future[int] {.async.} =
  var ta = initTAddress("127.0.0.1:31350")
  var server = createStreamServer(ta, serveClient8, {ReuseAddr})
  server.start()
  result = await swarmWorker8(ta)
  server.stop()
  server.close()
  await server.join()

proc serveClient9(server: StreamServer, transp: StreamTransport) {.async.} =
  var expect = ""
  for i in 0..<BigMessageCount:
    expect.add(BigMessagePattern)
  var res = await transp.write(expect)
  doAssert(res == len(expect))
  transp.close()
  await transp.join()

proc swarmWorker9(address: TransportAddress): Future[int] {.async.} =
  var transp = await connect(address)
  var expect = ""
  for i in 0..<BigMessageCount:
    expect.add(BigMessagePattern)
  var line = await transp.readLine()
  if line == expect:
    result = 1
  else:
    result = 0
  transp.close()
  await transp.join()

proc test9(): Future[int] {.async.} =
  var ta = initTAddress("127.0.0.1:31351")
  var server = createStreamServer(ta, serveClient9, {ReuseAddr})
  server.start()
  result = await swarmWorker9(ta)
  server.stop()
  server.close()
  await server.join()

proc serveClient10(server: StreamServer, transp: StreamTransport) {.async.} =
  var expect = ""
  for i in 0..<BigMessageCount:
    expect.add(BigMessagePattern)
  var res = await transp.write(expect)
  doAssert(res == len(expect))
  transp.close()
  await transp.join()

proc swarmWorker10(address: TransportAddress): Future[int] {.async.} =
  var transp = await connect(address)
  var expect = ""
  for i in 0..<BigMessageCount:
    expect.add(BigMessagePattern)
  var line = await transp.read()
  if equalMem(addr line[0], addr expect[0], len(expect)):
    result = 1
  else:
    result = 0
  transp.close()
  await transp.join()

proc test10(): Future[int] {.async.} =
  var ta = initTAddress("127.0.0.1:31351")
  var server = createStreamServer(ta, serveClient10, {ReuseAddr})
  server.start()
  result = await swarmWorker10(ta)
  server.stop()
  server.close()
  await server.join()

proc serveClient11(server: StreamServer, transp: StreamTransport) {.async.} =
  var res = await transp.write(BigMessagePattern)
  doAssert(res == len(BigMessagePattern))
  transp.close()
  await transp.join()

proc swarmWorker11(address: TransportAddress): Future[int] {.async.} =
  var buffer: array[len(BigMessagePattern) + 1, byte]
  var transp = await connect(address)
  try:
    await transp.readExactly(addr buffer[0], len(buffer))
  except TransportIncompleteError:
    result = 1
  transp.close()
  await transp.join()

proc test11(): Future[int] {.async.} =
  var ta = initTAddress("127.0.0.1:31352")
  var server = createStreamServer(ta, serveClient11, {ReuseAddr})
  server.start()
  result = await swarmWorker11(ta)
  server.stop()
  server.close()
  await server.join()

proc serveClient12(server: StreamServer, transp: StreamTransport) {.async.} =
  var res = await transp.write(BigMessagePattern)
  doAssert(res == len(BigMessagePattern))
  transp.close()
  await transp.join()

proc swarmWorker12(address: TransportAddress): Future[int] {.async.} =
  var buffer: array[len(BigMessagePattern), byte]
  var sep = @[0x0D'u8, 0x0A'u8]
  var transp = await connect(address)
  try:
    var res = await transp.readUntil(addr buffer[0], len(buffer), sep)
  except TransportIncompleteError:
    result = 1
  transp.close()
  await transp.join()

proc test12(): Future[int] {.async.} =
  var ta = initTAddress("127.0.0.1:31353")
  var server = createStreamServer(ta, serveClient12, {ReuseAddr})
  server.start()
  result = await swarmWorker12(ta)
  server.stop()
  server.close()
  await server.join()

proc serveClient13(server: StreamServer, transp: StreamTransport) {.async.} =
  transp.close()
  await transp.join()

proc swarmWorker13(address: TransportAddress): Future[int] {.async.} =
  var transp = await connect(address)
  var line = await transp.readLine()
  if line == "":
    result = 1
  else:
    result = 0
  transp.close()
  await transp.join()

proc test13(): Future[int] {.async.} =
  var ta = initTAddress("127.0.0.1:31354")
  var server = createStreamServer(ta, serveClient13, {ReuseAddr})
  server.start()
  result = await swarmWorker13(ta)
  server.stop()
  server.close()
  await server.join()

proc serveClient14(server: StreamServer, transp: StreamTransport) {.async.} =
  discard

proc test14(): Future[int] {.async.} =
  var subres = 0
  var ta = initTAddress("127.0.0.1:31354")
  var server = createStreamServer(ta, serveClient13, {ReuseAddr})

  proc swarmWorker(transp: StreamTransport): Future[void] {.async.} =
    var line = await transp.readLine()
    if line == "":
      subres = 1
    else:
      subres = 0

  server.start()
  var transp = await connect(ta)
  var fut = swarmWorker(transp)
  transp.close()
  await fut
  server.stop()
  server.close()
  await server.join()
  result = subres

when isMainModule:
  const
    m1 = "readLine() multiple clients with messages (" & $ClientsCount &
         " clients x " & $MessagesCount & " messages)"
    m2 = "readExactly() multiple clients with messages (" & $ClientsCount &
         " clients x " & $MessagesCount & " messages)"
    m3 = "readUntil() multiple clients with messages (" & $ClientsCount &
         " clients x " & $MessagesCount & " messages)"
    m4 = "writeFile() multiple clients (" & $FilesCount & " files)"
    m5 = "write(string)/read(int) multiple clients (" & $ClientsCount &
         " clients x " & $MessagesCount & " messages)"
    m6 = "write(seq[byte])/consume(int)/read(int) multiple clients (" &
         $ClientsCount & " clients x " & $MessagesCount & " messages)"
    m7 = "readLine() buffer overflow test"
    m8 = "readUntil() buffer overflow test"
    m9 = "readLine() unexpected disconnect test"
    m10 = "read() unexpected disconnect test"
    m11 = "readExactly() unexpected disconnect test"
    m12 = "readUntil() unexpected disconnect test"
    m13 = "readLine() unexpected disconnect empty string test"
    m14 = "Closing socket while operation pending test (issue #8)"
  suite "Stream Transport test suite":
    test m8:
      check waitFor(test8()) == 1
    test m7:
      check waitFor(test7()) == 1
    test m9:
      check waitFor(test9()) == 1
    test m10:
      check waitFor(test10()) == 1
    test m11:
      check waitFor(test11()) == 1
    test m12:
      check waitFor(test12()) == 1
    test m13:
      check waitFor(test13()) == 1
    test m14:
      check waitFor(test14()) == 1
    test m1:
      check waitFor(test1()) == ClientsCount * MessagesCount
    test m2:
      check waitFor(test2()) == ClientsCount * MessagesCount
    test m3:
      check waitFor(test3()) == ClientsCount * MessagesCount
    test m5:
      check waitFor(test5()) == ClientsCount * MessagesCount
    test m6:
      check waitFor(test6()) == ClientsCount * MessagesCount
    test m4:
      check waitFor(test4()) == FilesCount

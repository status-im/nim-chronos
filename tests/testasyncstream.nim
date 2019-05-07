#                Chronos Test Suite
#            (c) Copyright 2019-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)
import strutils, unittest, os
import hexdump
import ../chronos

suite "AsyncStream test suite":
  test "AsyncStream(StreamTransport) readExactly() test":
    proc testReadExactly(address: TransportAddress): Future[bool] {.async.} =
      proc serveClient(server: StreamServer,
                       transp: StreamTransport) {.async.} =
        var wstream = newAsyncStreamWriter(transp)
        await wstream.write("000000000011111111112222222222")
        await wstream.finish()
        await wstream.closeWait()
        await transp.closeWait()
        server.stop()
        server.close()

      var buffer = newSeq[byte](10)
      var server = createStreamServer(address, serveClient, {ReuseAddr})
      server.start()
      var transp = await connect(address)
      var rstream = newAsyncStreamReader(transp)
      await rstream.readExactly(addr buffer[0], 10)
      check cast[string](buffer) == "0000000000"
      await rstream.readExactly(addr buffer[0], 10)
      check cast[string](buffer) == "1111111111"
      await rstream.readExactly(addr buffer[0], 10)
      check cast[string](buffer) == "2222222222"
      await rstream.closeWait()
      await transp.closeWait()
      await server.join()
      result = true
    check waitFor(testReadExactly(initTAddress("127.0.0.1:46001"))) == true
  test "AsyncStream(StreamTransport) readUntil() test":
    proc testReadUntil(address: TransportAddress): Future[bool] {.async.} =
      proc serveClient(server: StreamServer,
                       transp: StreamTransport) {.async.} =
        var wstream = newAsyncStreamWriter(transp)
        await wstream.write("0000000000NNz1111111111NNz2222222222NNz")
        await wstream.finish()
        await wstream.closeWait()
        await transp.closeWait()
        server.stop()
        server.close()

      var buffer = newSeq[byte](13)
      var sep = @[byte('N'), byte('N'), byte('z')]
      var server = createStreamServer(address, serveClient, {ReuseAddr})
      server.start()
      var transp = await connect(address)
      var rstream = newAsyncStreamReader(transp)
      var r1 = await rstream.readUntil(addr buffer[0], len(buffer), sep)
      check:
        r1 == 13
        cast[string](buffer) == "0000000000NNz"
      var r2 = await rstream.readUntil(addr buffer[0], len(buffer), sep)
      check:
        r2 == 13
        cast[string](buffer) == "1111111111NNz"
      var r3 = await rstream.readUntil(addr buffer[0], len(buffer), sep)
      check:
        r3 == 13
        cast[string](buffer) == "2222222222NNz"

      await rstream.closeWait()
      await transp.closeWait()
      await server.join()
      result = true
    check waitFor(testReadUntil(initTAddress("127.0.0.1:46001"))) == true
  test "AsyncStream(StreamTransport) readLine() test":
    proc testReadLine(address: TransportAddress): Future[bool] {.async.} =
      proc serveClient(server: StreamServer,
                       transp: StreamTransport) {.async.} =
        var wstream = newAsyncStreamWriter(transp)
        await wstream.write("0000000000\r\n1111111111\r\n2222222222\r\n")
        await wstream.finish()
        await wstream.closeWait()
        await transp.closeWait()
        server.stop()
        server.close()

      var server = createStreamServer(address, serveClient, {ReuseAddr})
      server.start()
      var transp = await connect(address)
      var rstream = newAsyncStreamReader(transp)
      var r1 = await rstream.readLine()
      check r1 == "0000000000"
      var r2 = await rstream.readLine()
      check r2 == "1111111111"
      var r3 = await rstream.readLine()
      check r3 == "2222222222"
      await rstream.closeWait()
      await transp.closeWait()
      await server.join()
      result = true
    check waitFor(testReadLine(initTAddress("127.0.0.1:46001"))) == true
  test "AsyncStream(StreamTransport) read() test":
    proc testRead(address: TransportAddress): Future[bool] {.async.} =
      proc serveClient(server: StreamServer,
                       transp: StreamTransport) {.async.} =
        var wstream = newAsyncStreamWriter(transp)
        await wstream.write("000000000011111111112222222222")
        await wstream.finish()
        await wstream.closeWait()
        await transp.closeWait()
        server.stop()
        server.close()

      var server = createStreamServer(address, serveClient, {ReuseAddr})
      server.start()
      var transp = await connect(address)
      var rstream = newAsyncStreamReader(transp)
      var buf1 = await rstream.read(10)
      check cast[string](buf1) == "0000000000"
      var buf2 = await rstream.read()
      check cast[string](buf2) == "11111111112222222222"
      await rstream.closeWait()
      await transp.closeWait()
      await server.join()
      result = true
    check waitFor(testRead(initTAddress("127.0.0.1:46001"))) == true
  test "AsyncStream(StreamTransport) consume() test":
    proc testConsume(address: TransportAddress): Future[bool] {.async.} =
      proc serveClient(server: StreamServer,
                       transp: StreamTransport) {.async.} =
        var wstream = newAsyncStreamWriter(transp)
        await wstream.write("0000000000111111111122222222223333333333")
        await wstream.finish()
        await wstream.closeWait()
        await transp.closeWait()
        server.stop()
        server.close()

      var server = createStreamServer(address, serveClient, {ReuseAddr})
      server.start()
      var transp = await connect(address)
      var rstream = newAsyncStreamReader(transp)
      var res1 = await rstream.consume(10)
      check:
        res1 == 10
      var buf1 = await rstream.read(10)
      check cast[string](buf1) == "1111111111"
      var res2 = await rstream.consume(10)
      check:
        res2 == 10
      var buf2 = await rstream.read(10)
      check cast[string](buf2) == "3333333333"
      await rstream.closeWait()
      await transp.closeWait()
      await server.join()
      result = true
    check waitFor(testConsume(initTAddress("127.0.0.1:46001"))) == true
  test "AsyncStream(StreamTransport) leaks test":
    check:
      getTracker("async.stream.reader").isLeaked() == false
      getTracker("async.stream.writer").isLeaked() == false
      getTracker("stream.server").isLeaked() == false
      getTracker("stream.transport").isLeaked() == false

  test "AsyncStream(AsyncStream) readExactly() test":
    proc testReadExactly2(address: TransportAddress): Future[bool] {.async.} =
      proc serveClient(server: StreamServer,
                       transp: StreamTransport) {.async.} =
        var wstream = newAsyncStreamWriter(transp)
        var wstream2 = newChunkedStreamWriter(wstream)
        var s1 = "00000"
        var s2 = "11111"
        var s3 = "22222"
        await wstream2.write("00000")
        await wstream2.write(addr s1[0], len(s1))
        await wstream2.write("11111")
        await wstream2.write(cast[seq[byte]](s2))
        await wstream2.write("22222")
        await wstream2.write(addr s3[0], len(s3))

        await wstream2.finish()
        await wstream.finish()
        await wstream2.closeWait()
        await wstream.closeWait()
        await transp.closeWait()
        server.stop()
        server.close()

      var buffer = newSeq[byte](10)
      var server = createStreamServer(address, serveClient, {ReuseAddr})
      server.start()
      var transp = await connect(address)
      var rstream = newAsyncStreamReader(transp)
      var rstream2 = newChunkedStreamReader(rstream)
      await rstream2.readExactly(addr buffer[0], 10)
      check cast[string](buffer) == "0000000000"
      await rstream2.readExactly(addr buffer[0], 10)
      check cast[string](buffer) == "1111111111"
      await rstream2.readExactly(addr buffer[0], 10)
      check cast[string](buffer) == "2222222222"
      await rstream2.closeWait()
      await rstream.closeWait()
      await transp.closeWait()
      await server.join()
      result = true
    check waitFor(testReadExactly2(initTAddress("127.0.0.1:46001"))) == true
  test "AsyncStream(AsyncStream) readUntil() test":
    proc testReadUntil2(address: TransportAddress): Future[bool] {.async.} =
      proc serveClient(server: StreamServer,
                       transp: StreamTransport) {.async.} =
        var wstream = newAsyncStreamWriter(transp)
        var wstream2 = newChunkedStreamWriter(wstream)
        var s1 = "00000NNz"
        var s2 = "11111NNz"
        var s3 = "22222NNz"
        await wstream2.write("00000")
        await wstream2.write(addr s1[0], len(s1))
        await wstream2.write("11111")
        await wstream2.write(s2)
        await wstream2.write("22222")
        await wstream2.write(cast[seq[byte]](s3))
        await wstream2.finish()
        await wstream.finish()
        await wstream2.closeWait()
        await wstream.closeWait()
        await transp.closeWait()
        server.stop()
        server.close()

      var buffer = newSeq[byte](13)
      var sep = @[byte('N'), byte('N'), byte('z')]
      var server = createStreamServer(address, serveClient, {ReuseAddr})
      server.start()
      var transp = await connect(address)
      var rstream = newAsyncStreamReader(transp)
      var rstream2 = newChunkedStreamReader(rstream)

      var r1 = await rstream2.readUntil(addr buffer[0], len(buffer), sep)
      check:
        r1 == 13
        cast[string](buffer) == "0000000000NNz"
      var r2 = await rstream2.readUntil(addr buffer[0], len(buffer), sep)
      check:
        r2 == 13
        cast[string](buffer) == "1111111111NNz"
      var r3 = await rstream2.readUntil(addr buffer[0], len(buffer), sep)
      check:
        r3 == 13
        cast[string](buffer) == "2222222222NNz"
      await rstream2.closeWait()
      await rstream.closeWait()
      await transp.closeWait()
      await server.join()
      result = true
    check waitFor(testReadUntil2(initTAddress("127.0.0.1:46001"))) == true
  test "AsyncStream(AsyncStream) readLine() test":
    proc testReadLine2(address: TransportAddress): Future[bool] {.async.} =
      proc serveClient(server: StreamServer,
                       transp: StreamTransport) {.async.} =
        var wstream = newAsyncStreamWriter(transp)
        var wstream2 = newChunkedStreamWriter(wstream)
        await wstream2.write("00000")
        await wstream2.write("00000\r\n")
        await wstream2.write("11111")
        await wstream2.write("11111\r\n")
        await wstream2.write("22222")
        await wstream2.write("22222\r\n")
        await wstream2.finish()
        await wstream.finish()
        await wstream2.closeWait()
        await wstream.closeWait()
        await transp.closeWait()
        server.stop()
        server.close()

      var server = createStreamServer(address, serveClient, {ReuseAddr})
      server.start()
      var transp = await connect(address)
      var rstream = newAsyncStreamReader(transp)
      var rstream2 = newChunkedStreamReader(rstream)
      var r1 = await rstream2.readLine()
      check r1 == "0000000000"
      var r2 = await rstream2.readLine()
      check r2 == "1111111111"
      var r3 = await rstream2.readLine()
      check r3 == "2222222222"
      await rstream2.closeWait()
      await rstream.closeWait()
      await transp.closeWait()
      await server.join()
      result = true
    check waitFor(testReadLine2(initTAddress("127.0.0.1:46001"))) == true
  test "AsyncStream(AsyncStream) read() test":
    proc testRead2(address: TransportAddress): Future[bool] {.async.} =
      proc serveClient(server: StreamServer,
                       transp: StreamTransport) {.async.} =
        var wstream = newAsyncStreamWriter(transp)
        var wstream2 = newChunkedStreamWriter(wstream)
        var s2 = "1111111111"
        var s3 = "2222222222"
        await wstream2.write("0000000000")
        await wstream2.write(s2)
        await wstream2.write(cast[seq[byte]](s3))
        await wstream2.finish()
        await wstream.finish()
        await wstream2.closeWait()
        await wstream.closeWait()
        await transp.closeWait()
        server.stop()
        server.close()

      var server = createStreamServer(address, serveClient, {ReuseAddr})
      server.start()
      var transp = await connect(address)
      var rstream = newAsyncStreamReader(transp)
      var rstream2 = newChunkedStreamReader(rstream)
      var buf1 = await rstream2.read(10)
      check cast[string](buf1) == "0000000000"
      var buf2 = await rstream2.read()
      check cast[string](buf2) == "11111111112222222222"
      await rstream2.closeWait()
      await rstream.closeWait()
      await transp.closeWait()
      await server.join()
      result = true
    check waitFor(testRead2(initTAddress("127.0.0.1:46001"))) == true
  test "AsyncStream(AsyncStream) consume() test":
    proc testConsume2(address: TransportAddress): Future[bool] {.async.} =
      proc serveClient(server: StreamServer,
                       transp: StreamTransport) {.async.} =
        const
          S4 = @[byte('3'), byte('3'), byte('3'), byte('3'), byte('3')]
        var wstream = newAsyncStreamWriter(transp)
        var wstream2 = newChunkedStreamWriter(wstream)

        var s1 = "00000"
        var s2 = cast[seq[byte]]("11111")
        var s3 = "22222"

        await wstream2.write("00000")
        await wstream2.write(s1)
        await wstream2.write("11111")
        await wstream2.write(s2)
        await wstream2.write("22222")
        await wstream2.write(addr s3[0], len(s3))
        await wstream2.write("33333")
        await wstream2.write(S4)
        await wstream2.finish()
        await wstream.finish()
        await wstream2.closeWait()
        await wstream.closeWait()
        await transp.closeWait()
        server.stop()
        server.close()

      var server = createStreamServer(address, serveClient, {ReuseAddr})
      server.start()
      var transp = await connect(address)
      var rstream = newAsyncStreamReader(transp)
      var rstream2 = newChunkedStreamReader(rstream)

      var res1 = await rstream2.consume(10)
      check:
        res1 == 10
      var buf1 = await rstream2.read(10)
      check cast[string](buf1) == "1111111111"
      var res2 = await rstream2.consume(10)
      check:
        res2 == 10
      var buf2 = await rstream2.read(10)
      check cast[string](buf2) == "3333333333"
      await rstream2.closeWait()
      await rstream.closeWait()
      await transp.closeWait()
      await server.join()
      result = true
    check waitFor(testConsume2(initTAddress("127.0.0.1:46001"))) == true
  test "AsyncStream(AsyncStream) leaks test":
    check:
      getTracker("async.stream.reader").isLeaked() == false
      getTracker("async.stream.writer").isLeaked() == false
      getTracker("stream.server").isLeaked() == false
      getTracker("stream.transport").isLeaked() == false

suite "ChunkedStream test suite":
  test "ChunkedStream test vectors":
    const ChunkedVectors = [
      ["4\r\nWiki\r\n5\r\npedia\r\nE\r\n in\r\n\r\nchunks.\r\n0\r\n\r\n",
       "Wikipedia in\r\n\r\nchunks."],
      ["4\r\nWiki\r\n5\r\npedia\r\nE\r\n in\r\n\r\nchunks.\r\n0\r\n\r\n0\r\n\r\n",
       "Wikipedia in\r\n\r\nchunks."],
    ]
    proc checkVector(address: TransportAddress,
                     inputstr: string): Future[string] {.async.} =
      proc serveClient(server: StreamServer,
                       transp: StreamTransport) {.async.} =
        var wstream = newAsyncStreamWriter(transp)
        var data = inputstr
        await wstream.write(data)
        await wstream.finish()
        await wstream.closeWait()
        await transp.closeWait()
        server.stop()
        server.close()

      var server = createStreamServer(address, serveClient, {ReuseAddr})
      server.start()
      var transp = await connect(address)
      var rstream = newAsyncStreamReader(transp)
      var rstream2 = newChunkedStreamReader(rstream)
      var res = await rstream2.read()
      var ress = cast[string](res)
      await rstream2.closeWait()
      await rstream.closeWait()
      await transp.closeWait()
      await server.join()
      result = ress

    proc testVectors(address: TransportAddress): Future[bool] {.async.} =
      var res = true
      for i in 0..<len(ChunkedVectors):
        var r = await checkVector(address, ChunkedVectors[i][0])
        if r != ChunkedVectors[i][1]:
          res = false
          break
      result = res
    check waitFor(testVectors(initTAddress("127.0.0.1:46001"))) == true
  test "ChunkedStream incorrect chunk test":
    const BadVectors = [
      ["100000000 \r\n1"],
      ["z\r\n1"]
    ]
    proc checkVector(address: TransportAddress,
                     inputstr: string): Future[bool] {.async.} =
      proc serveClient(server: StreamServer,
                       transp: StreamTransport) {.async.} =
        var wstream = newAsyncStreamWriter(transp)
        var data = inputstr
        await wstream.write(data)
        await wstream.finish()
        await wstream.closeWait()
        await transp.closeWait()
        server.stop()
        server.close()

      var res = false
      var server = createStreamServer(address, serveClient, {ReuseAddr})
      server.start()
      var transp = await connect(address)
      var rstream = newAsyncStreamReader(transp)
      var rstream2 = newChunkedStreamReader(rstream)
      try:
        var r = await rstream2.read()
      except AsyncStreamReadError as e:
        res = true
      await rstream2.closeWait()
      await rstream.closeWait()
      await transp.closeWait()
      await server.join()
      result = res

    proc testVectors2(address: TransportAddress): Future[bool] {.async.} =
      var res = true
      for i in 0..<len(BadVectors):
        var r = await checkVector(address, BadVectors[i][0])
        if not(r):
          res = false
          break
      result = res
    check waitFor(testVectors2(initTAddress("127.0.0.1:46001"))) == true

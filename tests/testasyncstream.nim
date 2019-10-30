#                Chronos Test Suite
#            (c) Copyright 2019-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)
import strutils, unittest
import ../chronos, ../chronos/streams/tlsstream

when defined(nimHasUsed): {.used.}

const SelfSignedRsaKey = """
-----BEGIN PRIVATE KEY-----
MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQDSXcKMR6zIIHSy
+UUjgyIlJWzEu3JFCEN+qBpjmwbuae3GNed0YgPels6AKe0AlWQNgpqoWfMQrWco
qNf9dcm9OIdUK5FGMWYC8mJu6OjwnexSXt0R/k07lc5ePPDUbGvkbvgDyHzl1Ynj
jYhe/2ujL0E99/KAuA7cvRILEl4rLpnngE+MMYNrFWmsSDzC+w0Hv5Fuyc8wZoSy
nzODvojvFXTva9Nx4LxPF1W79WidwJHwrJghVlGUUhSeRGLHQWRY+954rj6TavoJ
6gLYSHx6ELnRkFMbqxRrCJ0wAbrV8SwcPHjKSc6LQGRMzBRqxT45DoKmzH9Pwdnw
6P0PGJyPAgMBAAECggEAd5Ck39hpIwIXchXtrwZ8ZMKFtLeZdhUBT7656P0XDnEU
nQDMQcDn1B7A1eV+eENwr6EYyDD/zu3P4TM+OCg3dp3nhPaSRmQTR/995O3qX8BS
rmqOmgiA2yoFNljKxOGu3RIZUwUjv/oDulsaNGxWQFS+bzs7EOAMSngIBlT1QvLc
1etvGOW6hc4nzacrXpzhzWem6EzOabPZBmIy0DDz2ARlND1YSd2P5IMpOv0terNF
ZwYl5SZ6Rnbv6GJWKl5IIpJOOtRtwyIhKNU/bd835vOfW07aaHVAT6GNYlyEoGWT
36UjOyl3YxSLNvQOeIz4Y0n+vupBu/YL+mFtQdxJgQKBgQDtjEi0cNlt+Vz5sp4q
wAVBJ/6h7hu3KJkY+xDpdrLyFTcxttKM9q/dR8V2bEaqMYT/mTvADfmW2BBcfi2J
3VdR1lQ5pXeKAuxt1/Vc+Q4UCnX5OX7UXpP9aSetDdo5FXUC9X2H0hO0BqOcc+h2
khVyXjKt6TdBwV94dP9bmQp9QQKBgQDitPVqRHGepYBYasScyTUXPp7vL9T7PMSu
PGjqEkwvauhICpUbWpE/j8M0UXk64zwSmOYwQ37uiPpws88GL57oy1ZQZnhF/Hi3
tM00Mn4x0xbyONbWu/AcFIZwSeSL6QhHYfeyVj7Jb/lqUg8sMiGmO25JjlAQBfTb
vvBgEpcVzwKBgQCwgz87JWfLejIGMR2qcoj1A30IYmAh1377uwO0F0mc7PrYbBtE
N8IyUTR/bLGNocJME1b8vOWrmt19fRzlhp1t6C8prrSGzulULdbawQ4fAi7rhDek
Iqsg8FRVGSgAptsN2dDvbcDKUuycQtyHzsE0/J338IXozIHehkGBlNTggQKBgQCF
RDTj5BoaVVWuJA0x0UGJSYFqP2bmzWEcv1w5BMqOMT0cZEQkkUfC4oKwdZhbGosM
r57ZDkRGenUl3T08eK/kTuuNVb8r/O8Fpp3eKjRum5TojKsWDeJmz1X8GiPkbvcz
5w4RYouEJHOsoVJT+6A2NMdvK946nRXEO2jYQPVZlwKBgBro8qGm0+T0T2xNP21q
IzjP/EHT7iIkM5kiUCc2bPIrfzAGxXImakDzd6AgpgxhhficJOpp792Upe/b/Hwy
bwfmbdWlT7/hPCnlVVH2dgO/ysDyEfxPigBMd+MmucRm6fzGIU7XSQw4KJqH4vQN
9IASWlgzyQ1RytAduzRuepzB
-----END PRIVATE KEY-----
"""

const SelfSignedRsaCert = """
-----BEGIN CERTIFICATE-----
MIIDkzCCAnugAwIBAgIUEFovLJkPSn4T8BBZMYBrXPDajF0wDQYJKoZIhvcNAQEL
BQAwWTELMAkGA1UEBhMCQVUxEzARBgNVBAgMClNvbWUtU3RhdGUxITAfBgNVBAoM
GEludGVybmV0IFdpZGdpdHMgUHR5IEx0ZDESMBAGA1UEAwwJbG9jYWxob3N0MB4X
DTE5MTAxMjA1NDQ0N1oXDTIwMTAxMTA1NDQ0OFowWTELMAkGA1UEBhMCQVUxEzAR
BgNVBAgMClNvbWUtU3RhdGUxITAfBgNVBAoMGEludGVybmV0IFdpZGdpdHMgUHR5
IEx0ZDESMBAGA1UEAwwJbG9jYWxob3N0MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8A
MIIBCgKCAQEA0l3CjEesyCB0svlFI4MiJSVsxLtyRQhDfqgaY5sG7mntxjXndGID
3pbOgCntAJVkDYKaqFnzEK1nKKjX/XXJvTiHVCuRRjFmAvJibujo8J3sUl7dEf5N
O5XOXjzw1Gxr5G74A8h85dWJ442IXv9roy9BPffygLgO3L0SCxJeKy6Z54BPjDGD
axVprEg8wvsNB7+RbsnPMGaEsp8zg76I7xV072vTceC8TxdVu/VoncCR8KyYIVZR
lFIUnkRix0FkWPveeK4+k2r6CeoC2Eh8ehC50ZBTG6sUawidMAG61fEsHDx4yknO
i0BkTMwUasU+OQ6Cpsx/T8HZ8Oj9DxicjwIDAQABo1MwUTAdBgNVHQ4EFgQUMM+1
FZ6KmN2eCJfDxY+8xa1JKnYwHwYDVR0jBBgwFoAUMM+1FZ6KmN2eCJfDxY+8xa1J
KnYwDwYDVR0TAQH/BAUwAwEB/zANBgkqhkiG9w0BAQsFAAOCAQEASglh98fXvPwA
KMaEezCUqTeE7DehLlhZ8n6ETKaBDcP3JR4+KTEh9y7gRGJ7DXGFAYfU3itgjyZo
kbgpZIhrTKyYCAsF96Q1mHf/cBQ96UXr0U0SbYXSSJFeeMthMvki556dJZajtxcA
9xR/U0PxPjhC9NIfpVSAv/7ocnXh73qOiFHoN9Cr2smzcGPxsifys2iv1qm5LwDr
Dx5h/RfyfuAjS8e1ZCAhS++PYjb8BX54NilW2lTYF3pwpXL8znc4eBmklBkw5L60
99jrK7LSQT9Nk8Mf9t4P/77N4hXCqsHIxZIqJlbdgdKfvBF3vRomxm3/aWtGlTVD
vvzZPnlYfQ==
-----END CERTIFICATE-----
"""

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

      # We need to consume all the stream with finish markers, but there will
      # be no actual data.
      let left = await rstream2.consume()
      check:
        left == 0
        rstream2.atEof() == true

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

      # We need to consume all the stream with finish markers, but there will
      # be no actual data.
      let left = await rstream2.consume()
      check:
        left == 0
        rstream2.atEof() == true

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

      # We need to consume all the stream with finish markers, but there will
      # be no actual data.
      let left = await rstream2.consume()
      check:
        left == 0
        rstream2.atEof() == true

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

      # read() call will consume all the bytes and finish markers too, so
      # we just check stream for EOF.
      check rstream2.atEof() == true

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

      # We need to consume all the stream with finish markers, but there will
      # be no actual data.
      let left = await rstream2.consume()
      check:
        left == 0
        rstream2.atEof() == true

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
        doAssert(len(r) > 0)
      except AsyncStreamReadError:
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

  test "ChunkedStream leaks test":
    check:
      getTracker("async.stream.reader").isLeaked() == false
      getTracker("async.stream.writer").isLeaked() == false
      getTracker("stream.server").isLeaked() == false
      getTracker("stream.transport").isLeaked() == false

suite "TLSStream test suite":
  const HttpHeadersMark = @[byte(0x0D), byte(0x0A), byte(0x0D), byte(0x0A)]
  test "Simple HTTPS connection":
    proc headerClient(address: TransportAddress,
                      name: string): Future[bool] {.async.} =
      var mark = "HTTP/1.1 "
      var buffer = newSeq[byte](8192)
      var transp = await connect(address)
      var reader = newAsyncStreamReader(transp)
      var writer = newAsyncStreamWriter(transp)
      var tlsstream = newTLSClientAsyncStream(reader, writer, name)

      await tlsstream.writer.write("GET / HTTP/1.1\r\nHost: " & name &
                                   "\r\nConnection: close\r\n\r\n")
      var readFut = tlsstream.reader.readUntil(addr buffer[0], len(buffer),
                                               HttpHeadersMark)
      let res = await withTimeout(readFut, 5.seconds)
      if res:
        var length = readFut.read()
        buffer.setLen(length)
        if len(buffer) > len(mark):
          if equalMem(addr buffer[0], addr mark[0], len(mark)):
            result = true

      await tlsstream.reader.closeWait()
      await tlsstream.writer.closeWait()
      await reader.closeWait()
      await writer.closeWait()
      await transp.closeWait()

    let res = waitFor(headerClient(resolveTAddress("www.google.com:443")[0],
                      "www.google.com"))
    check res == true

  proc checkSSLServer(address: TransportAddress,
                        pemkey, pemcert: string): Future[bool] {.async.} =
    var key: TLSPrivateKey
    var cert: TLSCertificate
    let testMessage = "TEST MESSAGE"

    proc serveClient(server: StreamServer,
                     transp: StreamTransport) {.async.} =
      var reader = newAsyncStreamReader(transp)
      var writer = newAsyncStreamWriter(transp)
      var sstream = newTLSServerAsyncStream(reader, writer, key, cert)
      await handshake(sstream)
      await sstream.writer.write(testMessage & "\r\n")
      await sstream.writer.closeWait()
      await sstream.reader.closeWait()
      await reader.closeWait()
      await writer.closeWait()
      await transp.closeWait()
      server.stop()
      server.close()

    key = TLSPrivateKey.init(pemkey)
    cert = TLSCertificate.init(pemcert)

    var server = createStreamServer(address, serveClient, {ReuseAddr})
    server.start()
    var conn = await connect(address)
    var creader = newAsyncStreamReader(conn)
    var cwriter = newAsyncStreamWriter(conn)
    # We are using self-signed certificate
    let flags = {NoVerifyHost, NoVerifyServerName}
    var cstream = newTLSClientAsyncStream(creader, cwriter, "", flags = flags)
    let res = await cstream.reader.readLine()
    await cstream.reader.closeWait()
    await cstream.writer.closeWait()
    await creader.closeWait()
    await cwriter.closeWait()
    await conn.closeWait()
    await server.join()
    result = res == testMessage

  test "Simple server with RSA self-signed certificate":
    let res = waitFor(checkSSLServer(initTAddress("127.0.0.1:43808"),
                                     SelfSignedRsaKey, SelfSignedRsaCert))
    check res == true
  test "TLSStream leaks test":
    check:
      getTracker("async.stream.reader").isLeaked() == false
      getTracker("async.stream.writer").isLeaked() == false
      getTracker("stream.server").isLeaked() == false
      getTracker("stream.transport").isLeaked() == false

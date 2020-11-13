#                Chronos Test Suite
#            (c) Copyright 2019-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)
import unittest
import ../chronos, ../chronos/streams/tlsstream

when defined(nimHasUsed): {.used.}

# To create self-signed certificate and key you can use openssl
# openssl req -new -x509 -sha256 -newkey rsa:2048 -nodes \
# -keyout example-com.key.pem -days 3650 -out example-com.cert.pem

const SelfSignedRsaKey = """
-----BEGIN PRIVATE KEY-----
MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQCn7tXGLKMIMzOG
tVzUixax1/ftlSLcpEAkZMORuiCCnYjtIJhGZdzRFZC8fBlfAJZpLIAOfX2L2f1J
ZuwpwDkOIvNqKMBrl5Mvkl5azPT0rtnjuwrcqN5NFtbmZPKFYvbjex2aXGqjl5MW
nQIs/ZA++DVEXmaN9oDxcZsvRMDKfrGQf9iLeoVL47Gx9KpqNqD/JLIn4LpieumV
yYidm6ukTOqHRvrWm36y6VvKW4TE97THacULmkeahtTf8zDJbbh4EO+gifgwgJ2W
BUS0+5hMcWu8111mXmanlOVlcoW8fH8RmPjL1eK1Z3j3SVHEf7oWZtIVW5gGA0jQ
nfA4K51RAgMBAAECggEANZ7/R13tWKrwouy6DWuz/WlWUtgx333atUQvZhKmWs5u
cDjeJmxUC7b1FhoSB9GqNT7uTLIpKkSaqZthgRtNnIPwcU890Zz+dEwqMJgNByvl
it+oYjjRco/+YmaNQaYN6yjelPE5Y678WlYb4b29Fz4t0/zIhj/VgEKkKH2tiXpS
TIicoM7pSOscEUfaW3yp5bS5QwNU6/AaF1wws0feBACd19ZkcdPvr52jopbhxlXw
h3XTV/vXIJd5zWGp0h/Jbd4xcD4MVo2GjfkeORKY6SjDaNzt8OGtePcKnnbUVu8b
2XlDxukhDQXqJ3g0sHz47mhvo4JeIM+FgymRm+3QmQKBgQDTawrEA3Zy9WvucaC7
Zah02oE9nuvpF12lZ7WJh7+tZ/1ss+Fm7YspEKaUiEk7nn1CAVFtem4X4YCXTBiC
Oqq/o+ipv1yTur0ae6m4pwLm5wcMWBh3H5zjfQTfrClNN8yjWv8u3/sq8KesHPnT
R92/sMAptAChPgTzQphWbxFiYwKBgQDLWFaBqXfZYVnTyUvKX8GorS6jGWc6Eh4l
lAFA+2EBWDICrUxsDPoZjEXrWCixdqLhyehaI3KEFIx2bcPv6X2c7yx3IG5lA/Gx
TZiKlY74c6jOTstkdLW9RJbg1VUHUVZMf/Owt802YmEfUI5S5v7jFmKW6VG+io+K
+5KYeHD1uwKBgQDMf53KPA82422jFwYCPjLT1QduM2q97HwIomhWv5gIg63+l4BP
rzYMYq6+vZUYthUy41OAMgyLzPQ1ZMXQMi83b7R9fTxvKRIBq9xfYCzObGnE5vHD
SDDZWvR75muM5Yxr9nkfPkgVIPMO6Hg+hiVYZf96V0LEtNjU9HWmJYkLQQKBgQCQ
ULGUdGHKtXy7AjH3/t3CiKaAupa4cANVSCVbqQy/l4hmvfdu+AbH+vXkgTzgNgKD
nHh7AI1Vj//gTSayLlQn/Nbh9PJkXtg5rYiFUn+VdQBo6yMOuIYDPZqXFtCx0Nge
kvCwisHpxwiG4PUhgS+Em259DDonsM8PJFx2OYRx4QKBgEQpGhg71Oi9MhPJshN7
dYTowaMS5eLTk2264ARaY+hAIV7fgvUa+5bgTVaWL+Cfs33hi4sMRqlEwsmfds2T
cnQiJ4cU20Euldfwa5FLnk6LaWdOyzYt/ICBJnKFRwfCUbS4Bu5rtMEM+3t0wxnJ
IgaD04WhoL9EX0Qo3DC1+0kG
-----END PRIVATE KEY-----
"""

# This SSL certificate will expire 13 October 2030.
const SelfSignedRsaCert = """
-----BEGIN CERTIFICATE-----
MIIDnzCCAoegAwIBAgIUUdcusjDd3XQi3FPM8urdFG3qI+8wDQYJKoZIhvcNAQEL
BQAwXzELMAkGA1UEBhMCQVUxEzARBgNVBAgMClNvbWUtU3RhdGUxITAfBgNVBAoM
GEludGVybmV0IFdpZGdpdHMgUHR5IEx0ZDEYMBYGA1UEAwwPMTI3LjAuMC4xOjQz
ODA4MB4XDTIwMTAxMjIxNDUwMVoXDTMwMTAxMDIxNDUwMVowXzELMAkGA1UEBhMC
QVUxEzARBgNVBAgMClNvbWUtU3RhdGUxITAfBgNVBAoMGEludGVybmV0IFdpZGdp
dHMgUHR5IEx0ZDEYMBYGA1UEAwwPMTI3LjAuMC4xOjQzODA4MIIBIjANBgkqhkiG
9w0BAQEFAAOCAQ8AMIIBCgKCAQEAp+7VxiyjCDMzhrVc1IsWsdf37ZUi3KRAJGTD
kboggp2I7SCYRmXc0RWQvHwZXwCWaSyADn19i9n9SWbsKcA5DiLzaijAa5eTL5Je
Wsz09K7Z47sK3KjeTRbW5mTyhWL243sdmlxqo5eTFp0CLP2QPvg1RF5mjfaA8XGb
L0TAyn6xkH/Yi3qFS+OxsfSqajag/ySyJ+C6YnrplcmInZurpEzqh0b61pt+sulb
yluExPe0x2nFC5pHmobU3/MwyW24eBDvoIn4MICdlgVEtPuYTHFrvNddZl5mp5Tl
ZXKFvHx/EZj4y9XitWd490lRxH+6FmbSFVuYBgNI0J3wOCudUQIDAQABo1MwUTAd
BgNVHQ4EFgQUBKha84woY5WkFxKw7qx1cONg1H8wHwYDVR0jBBgwFoAUBKha84wo
Y5WkFxKw7qx1cONg1H8wDwYDVR0TAQH/BAUwAwEB/zANBgkqhkiG9w0BAQsFAAOC
AQEAHZMYt9Ry+Xj3vTbzpGFQzYQVTJlfJWSN6eWNOivRFQE5io9kOBEe5noa8aLo
dLkw6ztxRP2QRJmlhGCO9/HwS17ckrkgZp3EC2LFnzxcBmoZu+owfxOT1KqpO52O
IKOl8eVohi1pEicE4dtTJVcpI7VCMovnXUhzx1Ci4Vibns4a6H+BQa19a1JSpifN
tO8U5jkjJ8Jprs/VPFhJj2O3di53oDHaYSE5eOrm2ZO14KFHSk9cGcOGmcYkUv8B
nV5vnGadH5Lvfxb/BCpuONabeRdOxMt9u9yQ89vNpxFtRdZDCpGKZBCfmUP+5m3m
N8r5CwGcIX/XPC3lKazzbZ8baA==
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

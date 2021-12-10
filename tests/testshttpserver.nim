#                Chronos Test Suite
#            (c) Copyright 2021-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)
import std/[strutils, strutils]
import unittest2
import ../chronos, ../chronos/apps/http/shttpserver
import stew/base10

when defined(nimHasUsed): {.used.}

# To create self-signed certificate and key you can use openssl
# openssl req -new -x509 -sha256 -newkey rsa:2048 -nodes \
# -keyout example-com.key.pem -days 3650 -out example-com.cert.pem
const HttpsSelfSignedRsaKey = """
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
const HttpsSelfSignedRsaCert = """
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


suite "Secure HTTP server testing suite":

  proc httpsClient(address: TransportAddress,
                   data: string, flags = {NoVerifyHost, NoVerifyServerName}
                  ): Future[string] {.async.} =
    var
      transp: StreamTransport
      tlsstream: TLSAsyncStream
      reader: AsyncStreamReader
      writer: AsyncStreamWriter

    try:
      transp = await connect(address)
      reader = newAsyncStreamReader(transp)
      writer = newAsyncStreamWriter(transp)
      tlsstream = newTLSClientAsyncStream(reader, writer, "", flags = flags)
      if len(data) > 0:
        await tlsstream.writer.write(data)
      var rres = await tlsstream.reader.read()
      return bytesToString(rres)
    except CatchableError:
      return "EXCEPTION"
    finally:
      if not(isNil(tlsstream)):
        await allFutures(tlsstream.reader.closeWait(),
                         tlsstream.writer.closeWait())
      if not(isNil(reader)):
        await allFutures(reader.closeWait(), writer.closeWait(),
                         transp.closeWait())

  test "HTTPS server (successful handshake) test":
    proc testHTTPS(address: TransportAddress): Future[bool] {.async.} =
      var serverRes = false
      proc process(r: RequestFence): Future[HttpResponseRef] {.
           async.} =
        if r.isOk():
          let request = r.get()
          serverRes = true
          return await request.respond(Http200, "TEST_OK:" & $request.meth,
                                       HttpTable.init())
        else:
          serverRes = false
          return dumbResponse()

      let socketFlags = {ServerFlags.TcpNoDelay, ServerFlags.ReuseAddr}
      let serverFlags = {Secure}
      let secureKey = TLSPrivateKey.init(HttpsSelfSignedRsaKey)
      let secureCert = TLSCertificate.init(HttpsSelfSignedRsaCert)
      let res = SecureHttpServerRef.new(address, process,
                                        socketFlags = socketFlags,
                                        serverFlags = serverFlags,
                                        tlsPrivateKey = secureKey,
                                        tlsCertificate = secureCert)
      if res.isErr():
        return false

      let server = res.get()
      server.start()
      let message = "GET / HTTP/1.0\r\nHost: https://127.0.0.1:80\r\n\r\n"
      let data = await httpsClient(address, message)

      await server.stop()
      await server.closeWait()
      return serverRes and (data.find("TEST_OK:GET") >= 0)

    check waitFor(testHTTPS(initTAddress("127.0.0.1:30080"))) == true

  test "HTTPS server (failed handshake) test":
    proc testHTTPS2(address: TransportAddress): Future[bool] {.async.} =
      var serverRes = false
      var testFut = newFuture[void]()
      proc process(r: RequestFence): Future[HttpResponseRef] {.
           async.} =
        if r.isOk():
          let request = r.get()
          serverRes = false
          return await request.respond(Http200, "TEST_OK:" & $request.meth,
                                       HttpTable.init())
        else:
          serverRes = true
          testFut.complete()
          return dumbResponse()

      let socketFlags = {ServerFlags.TcpNoDelay, ServerFlags.ReuseAddr}
      let serverFlags = {Secure}
      let secureKey = TLSPrivateKey.init(HttpsSelfSignedRsaKey)
      let secureCert = TLSCertificate.init(HttpsSelfSignedRsaCert)
      let res = SecureHttpServerRef.new(address, process,
                                        socketFlags = socketFlags,
                                        serverFlags = serverFlags,
                                        tlsPrivateKey = secureKey,
                                        tlsCertificate = secureCert)
      if res.isErr():
        return false

      let server = res.get()
      server.start()
      let message = "GET / HTTP/1.0\r\nHost: https://127.0.0.1:80\r\n\r\n"
      let data = await httpsClient(address, message, {NoVerifyServerName})
      await testFut
      await server.stop()
      await server.closeWait()
      return serverRes and data == "EXCEPTION"

    check waitFor(testHTTPS2(initTAddress("127.0.0.1:30080"))) == true

#                Chronos Test Suite
#            (c) Copyright 2019-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)
import unittest2
import bearssl/[ssl, x509]
import stew/byteutils
import ../chronos/unittest2/asynctests
import ../chronos/streams/[tlsstream, chunkstream, boundstream]

{.used.}

# To create self-signed certificate and key you can use openssl
# openssl req -new -x509 -sha256 -newkey rsa:2048 -nodes \
# -keyout example-com.key.pem -days 3650 -out example-com.cert.pem
#
# To create EC (P-256) self-signed certificate and key:
# openssl ecparam -genkey -name prime256v1 | \
# openssl pkcs8 -topk8 -nocrypt -outform PEM > ec.key.pem
# openssl req -new -x509 -sha256 -key ec.key.pem -days 3650 -out ec.cert.pem

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

const SelfSignedRsaKey2 = """
-----BEGIN PRIVATE KEY-----
MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQDVllWKY+YCjBNY
FZNtAHgTfZ8B5ONBMGKrwvP25ka7VAj2uowYYog0CAh+s3I1he3yIrNIbAqbdx/b
y2fTJOgLInj+cLBPdt0ws72qqaUWinj39veWigJScPsQC2xel+dNEOv0spakyQDF
UmM3QoZA0B0hiuX+0pdnH/aJ/wU7+kpgPXp7ZEm/rrItDkU8mSbg8cHiEpDzh3gf
m17vxg7RfkUk9iZ1FauybcZec9fgioglobWnBui9gbzod5z3bhXM5h6DBO4tE4ay
S/+RMc9jBrdyj9McvySzJD0ca1FUDx+bPhr//DH+ZdKujbpnSTo6MYGzGR2OjDOR
RAJKBuAdAgMBAAECggEAL9lgDILY0pVC+CbNQkwqmmM4Lhpy9vW6BTTFpvhrvCfV
YkDkhcn9LXrnPEtDOM5qQiaX94+MyMtlLb5h4iGQgn4UkRv5w7OjVffOc99Rhr06
4IJJcUY1wvZgqHWGr6JkRRWXZthje0M0kwAkDgsvPHHjNNKDOBVBqe61MrEZIRhG
q0XUAIaFHXqyNzPjBkAxHWCpiMf1jXBC/1gAoCG6/rCjR4FwpE0w8vHkEEV9y6uZ
j9A1oHPbwWT4Yc55Kr5eraOB6eSNsh9sGNJZOlIYfjiB9K6heeYrRAUz9Ah+w/ZE
MX565mCgnTcc5HuYelaoQGdjvnzuZgHQ69Zhv04sQQKBgQDuLN+BZa75H7bDZb0u
CvHvDaCLKDztj58t0RoGd1R5JNrGbHqgV1kymDkqGQOikDDi7dKk35yz7JgKYjHH
W/XOIn8leY/hZXqMHmpXoYo/eiOIu87JVV1cknLTFAIxwgr1VeXiPll4dSKdQznl
WkPUDPqPkb060SpnogocPmqYNQKBgQDlkmLnFZgz2t8kw1/Wd8u0tjzDM9zZ3y91
LAid+CQc5zI6rn8UDWJFR32L4Napss5goj5+TWeNZ9Q4P1yfxxGXEgpb4F5+l5fk
2Qawm5aifcawPrZUXLZ3kZFMBVWCz1bYbdHrmmmELw1CQmnR8sbulHGiRiwzCPtt
45dCiHS1SQKBgAzCfKra/re7+jeXoL3xuipbaYlq+3CirB1xQVqtU+o1jj7pGtyy
MUYjn5RgyLAR13ygzxMkI6oD99U+k3ohtBZ6BKPGUm352Mne60WMkvJ5oaO2pApn
N1w5QEuMm918jse79VfcjUCFzffs3RIrdszKcTX10dRv1jy9EpuWwHEtAoGBAJ6c
5XiDkwVA06uy0SR84GGbB6BW1OAzM7bhFZMPPuQ5WJrytRpFpP/4xOVAExBsWeqq
LkNVd5ZbhmTWYkiCYcTe0glom+EbG/che13KIelivURID/F5nRg/mwPLK6mVV4tx
VPhTV1Pcrmx5NmO4OXndViWoFiGsswrZlEiDvx8BAoGBAOGgIVpOt1KhlSxzpmM1
rsuE0cJNlRGEuIOmhvCq43PBEso2MgZFV+qoS1+GmeDHH+ARFWnGppOdZZR160d4
S1lcvzu66e4v8747og4QYRJyNfLNlOzuemLB/9QC/UArX6IWIpGgq8NPuj3KDYKQ
+UrjQ3In7R6YQnucK9fy/fdI
-----END PRIVATE KEY-----
"""

# This SSL certificate will expire April 3 2046.
const SelfSignedRsaCert2 = """
-----BEGIN CERTIFICATE-----
MIIDrzCCApegAwIBAgIUaRmvDOkSWBhRABcd6u9Cc2HCY/QwDQYJKoZIhvcNAQEL
BQAwZzELMAkGA1UEBhMCQVUxEzARBgNVBAgMClNvbWUtU3RhdGUxITAfBgNVBAoM
GEludGVybmV0IFdpZGdpdHMgUHR5IEx0ZDEgMB4GA1UEAwwXY2hyb25vcy1zZXJ2
ZXItdGVzdC5jb20wHhcNMjYwNDA4MTAxOTE0WhcNNDYwNDAzMTAxOTE0WjBnMQsw
CQYDVQQGEwJBVTETMBEGA1UECAwKU29tZS1TdGF0ZTEhMB8GA1UECgwYSW50ZXJu
ZXQgV2lkZ2l0cyBQdHkgTHRkMSAwHgYDVQQDDBdjaHJvbm9zLXNlcnZlci10ZXN0
LmNvbTCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBANWWVYpj5gKME1gV
k20AeBN9nwHk40EwYqvC8/bmRrtUCPa6jBhiiDQICH6zcjWF7fIis0hsCpt3H9vL
Z9Mk6AsieP5wsE923TCzvaqppRaKePf295aKAlJw+xALbF6X500Q6/SylqTJAMVS
YzdChkDQHSGK5f7Sl2cf9on/BTv6SmA9entkSb+usi0ORTyZJuDxweISkPOHeB+b
Xu/GDtF+RST2JnUVq7Jtxl5z1+CKiCWhtacG6L2BvOh3nPduFczmHoME7i0ThrJL
/5Exz2MGt3KP0xy/JLMkPRxrUVQPH5s+Gv/8Mf5l0q6NumdJOjoxgbMZHY6MM5FE
AkoG4B0CAwEAAaNTMFEwHQYDVR0OBBYEFBc7U60NfyXJcL7if2E8Ogcw6e2aMB8G
A1UdIwQYMBaAFBc7U60NfyXJcL7if2E8Ogcw6e2aMA8GA1UdEwEB/wQFMAMBAf8w
DQYJKoZIhvcNAQELBQADggEBALcP+zZPzkVtzuMZF1KK6R/bWZ39MUCwoAxR+SYg
+c9BtNOnIee2P9k5DehUAFnH9j+txG5p4LYkuedbpYeq1EEbLXXatL739xpbHqL1
RbWnPo6grAxiBPalgPR0Sti/vpzxfGfVD++VCgM80s2FNOdjieIFDhtuQr+HbzFX
NXq+JQUI2a7Ol4pgj7gp9K1I1PjjRjYrUq+xkO2445H+zuiI1GUj3SfbSqF2cZcf
cJ3KsbbS6BGOtIpVQOmTtz0H6oZDikwnrTfzMsBoc4x/TnGfFtVe1Fnaz6A47ne9
RDRrJe3ArYBM/DsrTq5qrSVPBSevknbpG77hDMeZh4FXsac=
-----END CERTIFICATE-----
"""

# This SSL EC certificate will expire 31 March 2036.
const SelfSignedEcKey = """
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgC9VcD8axNnS+wzKg
Ng62Lb3LmOiLcUHt7yOS7pY/isyhRANCAARqirbb0fF2B7hLtXUNWFhE49OtAb9X
QrDOboBNumfzsE/kxgaQ3/T7EQAaaXMOVLRFtOKdLBOEsx51wZJZEICU
-----END PRIVATE KEY-----
"""

const SelfSignedEcCert = """
-----BEGIN CERTIFICATE-----
MIICEzCCAbmgAwIBAgIUHYNpklhNSMzLR3zBV4jDbwCX/NgwCgYIKoZIzj0EAwIw
XzELMAkGA1UEBhMCQVUxEzARBgNVBAgMClNvbWUtU3RhdGUxITAfBgNVBAoMGElu
dGVybmV0IFdpZGdpdHMgUHR5IEx0ZDEYMBYGA1UEAwwPMTI3LjAuMC4xOjQzODA4
MB4XDTI2MDQwMzA0NTc1MVoXDTM2MDMzMTA0NTc1MVowXzELMAkGA1UEBhMCQVUx
EzARBgNVBAgMClNvbWUtU3RhdGUxITAfBgNVBAoMGEludGVybmV0IFdpZGdpdHMg
UHR5IEx0ZDEYMBYGA1UEAwwPMTI3LjAuMC4xOjQzODA4MFkwEwYHKoZIzj0CAQYI
KoZIzj0DAQcDQgAEaoq229Hxdge4S7V1DVhYROPTrQG/V0Kwzm6ATbpn87BP5MYG
kN/0+xEAGmlzDlS0RbTinSwThLMedcGSWRCAlKNTMFEwHQYDVR0OBBYEFOy8CFwI
iU3eg8xtAMrHJFmX59bcMB8GA1UdIwQYMBaAFOy8CFwIiU3eg8xtAMrHJFmX59bc
MA8GA1UdEwEB/wQFMAMBAf8wCgYIKoZIzj0EAwIDSAAwRQIhAPJKbWOf7MWgfCky
vf85DkBfIBMo2PM8WrgJYYSRkMmqAiBOcPebl59ZX11s4OhNa9BETOuCIE6kVtNm
GaLrNaHO6A==
-----END CERTIFICATE-----
"""

let SelfSignedTrustAnchors {.importc: "SelfSignedTAs".}: array[1, X509TrustAnchor]
let SelfSignedEcTrustAnchors {.importc: "SelfSignedEcTAs".}:
  array[1, X509TrustAnchor]
{.compile: "testasyncstream.c".}

proc createBigMessage(message: string, size: int): seq[byte] =
  var res = newSeq[byte](size)
  for i in 0 ..< len(res):
    res[i] = byte(ord(message[i mod len(message)]))
  res

suite "AsyncStream/StreamTransport":
  teardown:
    checkLeaks()

  asyncTest "readExactly":
    proc serveClient(server: StreamServer,
                      transp: StreamTransport) {.async: (raises: []).} =
      try:
        var wstream = newAsyncStreamWriter(transp)
        await wstream.write("000000000011111111112222222222")
        await wstream.finish()
        await wstream.closeWait()
        await transp.closeWait()
        server.stop()
        server.close()
      except CatchableError as exc:
        raiseAssert exc.msg

    var buffer = newSeq[byte](10)
    var server = createStreamServer(initTAddress("127.0.0.1:0"),
                                    serveClient, {ReuseAddr})
    server.start()
    var transp = await connect(server.localAddress())
    var rstream = newAsyncStreamReader(transp)
    await rstream.readExactly(addr buffer[0], 10)
    check string.fromBytes(buffer) == "0000000000"
    await rstream.readExactly(addr buffer[0], 10)
    check string.fromBytes(buffer) == "1111111111"
    await rstream.readExactly(addr buffer[0], 10)
    check string.fromBytes(buffer) == "2222222222"
    await rstream.closeWait()
    await transp.closeWait()
    await server.join()

  asyncTest "readUntil":
    proc serveClient(server: StreamServer,
                      transp: StreamTransport) {.async: (raises: []).} =
      try:
        var wstream = newAsyncStreamWriter(transp)
        await wstream.write("0000000000NNz1111111111NNz2222222222NNz")
        await wstream.finish()
        await wstream.closeWait()
        await transp.closeWait()
        server.stop()
        server.close()
      except CatchableError as exc:
        raiseAssert exc.msg

    var buffer = newSeq[byte](13)
    var sep = @[byte('N'), byte('N'), byte('z')]
    var server = createStreamServer(initTAddress("127.0.0.1:0"),
                                    serveClient, {ReuseAddr})
    server.start()
    var transp = await connect(server.localAddress())
    var rstream = newAsyncStreamReader(transp)
    var r1 = await rstream.readUntil(addr buffer[0], len(buffer), sep)
    check:
      r1 == 13
      string.fromBytes(buffer) == "0000000000NNz"
    var r2 = await rstream.readUntil(addr buffer[0], len(buffer), sep)
    check:
      r2 == 13
      string.fromBytes(buffer) == "1111111111NNz"
    var r3 = await rstream.readUntil(addr buffer[0], len(buffer), sep)
    check:
      r3 == 13
      string.fromBytes(buffer) == "2222222222NNz"

    await rstream.closeWait()
    await transp.closeWait()
    await server.join()

  asyncTest "readLine":
    proc serveClient(server: StreamServer,
                      transp: StreamTransport) {.async: (raises: []).} =
      try:
        var wstream = newAsyncStreamWriter(transp)
        await wstream.write("0000000000\r\n1111111111\r\n2222222222\r\n")
        await wstream.finish()
        await wstream.closeWait()
        await transp.closeWait()
        server.stop()
        server.close()
      except CatchableError as exc:
        raiseAssert exc.msg

    var server = createStreamServer(initTAddress("127.0.0.1:0"),
                                    serveClient, {ReuseAddr})
    server.start()
    var transp = await connect(server.localAddress())
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

  asyncTest "read":
    proc serveClient(server: StreamServer,
                      transp: StreamTransport) {.async: (raises: []).} =
      try:
        var wstream = newAsyncStreamWriter(transp)
        await wstream.write("000000000011111111112222222222")
        await wstream.finish()
        await wstream.closeWait()
        await transp.closeWait()
        server.stop()
        server.close()
      except CatchableError as exc:
        raiseAssert exc.msg

    var server = createStreamServer(initTAddress("127.0.0.1:0"),
                                    serveClient, {ReuseAddr})
    server.start()
    var transp = await connect(server.localAddress())
    var rstream = newAsyncStreamReader(transp)
    var buf1 = await rstream.read(10)
    check string.fromBytes(buf1) == "0000000000"
    var buf2 = await rstream.read()
    check string.fromBytes(buf2) == "11111111112222222222"
    await rstream.closeWait()
    await transp.closeWait()
    await server.join()

  asyncTest "consume":
    proc serveClient(server: StreamServer,
                      transp: StreamTransport) {.async: (raises: []).} =
      try:
        var wstream = newAsyncStreamWriter(transp)
        await wstream.write("0000000000111111111122222222223333333333")
        await wstream.finish()
        await wstream.closeWait()
        await transp.closeWait()
        server.stop()
        server.close()
      except CatchableError as exc:
        raiseAssert exc.msg

    var server = createStreamServer(initTAddress("127.0.0.1:0"),
                                    serveClient, {ReuseAddr})
    server.start()
    var transp = await connect(server.localAddress())
    var rstream = newAsyncStreamReader(transp)
    var res1 = await rstream.consume(10)
    check:
      res1 == 10
    var buf1 = await rstream.read(10)
    check string.fromBytes(buf1) == "1111111111"
    var res2 = await rstream.consume(10)
    check:
      res2 == 10
    var buf2 = await rstream.read(10)
    check string.fromBytes(buf2) == "3333333333"
    await rstream.closeWait()
    await transp.closeWait()
    await server.join()

suite "AsyncStream/ChunkedStream":
  teardown:
    checkLeaks()

  asyncTest "readExactly":
    proc serveClient(server: StreamServer,
                      transp: StreamTransport) {.async: (raises: []).} =
      try:
        var wstream = newAsyncStreamWriter(transp)
        var wstream2 = newChunkedStreamWriter(wstream)
        var s1 = "00000"
        var s2 = "11111"
        var s3 = "22222"
        await wstream2.write("00000")
        await wstream2.write(addr s1[0], len(s1))
        await wstream2.write("11111")
        await wstream2.write(s2.toBytes())
        await wstream2.write("22222")
        await wstream2.write(addr s3[0], len(s3))

        await wstream2.finish()
        await wstream.finish()
        await wstream2.closeWait()
        await wstream.closeWait()
        await transp.closeWait()
        server.stop()
        server.close()
      except CatchableError as exc:
        raiseAssert exc.msg

    var buffer = newSeq[byte](10)
    var server = createStreamServer(initTAddress("127.0.0.1:0"),
                                    serveClient, {ReuseAddr})
    server.start()
    var transp = await connect(server.localAddress())
    var rstream = newAsyncStreamReader(transp)
    var rstream2 = newChunkedStreamReader(rstream)
    await rstream2.readExactly(addr buffer[0], 10)
    check string.fromBytes(buffer) == "0000000000"
    await rstream2.readExactly(addr buffer[0], 10)
    check string.fromBytes(buffer) == "1111111111"
    await rstream2.readExactly(addr buffer[0], 10)
    check string.fromBytes(buffer) == "2222222222"

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

  asyncTest "readUntil":
    proc serveClient(server: StreamServer,
                      transp: StreamTransport) {.async: (raises: []).} =
      try:
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
        await wstream2.write(s3.toBytes())
        await wstream2.finish()
        await wstream.finish()
        await wstream2.closeWait()
        await wstream.closeWait()
        await transp.closeWait()
        server.stop()
        server.close()
      except CatchableError as exc:
        raiseAssert exc.msg

    var buffer = newSeq[byte](13)
    var sep = @[byte('N'), byte('N'), byte('z')]
    var server = createStreamServer(initTAddress("127.0.0.1:0"),
                                    serveClient, {ReuseAddr})
    server.start()
    var transp = await connect(server.localAddress())
    var rstream = newAsyncStreamReader(transp)
    var rstream2 = newChunkedStreamReader(rstream)

    var r1 = await rstream2.readUntil(addr buffer[0], len(buffer), sep)
    check:
      r1 == 13
      string.fromBytes(buffer) == "0000000000NNz"
    var r2 = await rstream2.readUntil(addr buffer[0], len(buffer), sep)
    check:
      r2 == 13
      string.fromBytes(buffer) == "1111111111NNz"
    var r3 = await rstream2.readUntil(addr buffer[0], len(buffer), sep)
    check:
      r3 == 13
      string.fromBytes(buffer) == "2222222222NNz"

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

  asyncTest "readLine":
    proc serveClient(server: StreamServer,
                      transp: StreamTransport) {.async: (raises: []).} =
      try:
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
      except CatchableError as exc:
        raiseAssert exc.msg

    var server = createStreamServer(initTAddress("127.0.0.1:0"),
                                    serveClient, {ReuseAddr})
    server.start()
    var transp = await connect(server.localAddress())
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

  asyncTest "read":
    proc serveClient(server: StreamServer,
                      transp: StreamTransport) {.async: (raises: []).} =
      try:
        var wstream = newAsyncStreamWriter(transp)
        var wstream2 = newChunkedStreamWriter(wstream)
        var s2 = "1111111111"
        var s3 = "2222222222"
        await wstream2.write("0000000000")
        await wstream2.write(s2)
        await wstream2.write(s3.toBytes())
        await wstream2.finish()
        await wstream.finish()
        await wstream2.closeWait()
        await wstream.closeWait()
        await transp.closeWait()
        server.stop()
        server.close()
      except CatchableError as exc:
        raiseAssert exc.msg

    var server = createStreamServer(initTAddress("127.0.0.1:0"),
                                    serveClient, {ReuseAddr})
    server.start()
    var transp = await connect(server.localAddress())
    var rstream = newAsyncStreamReader(transp)
    var rstream2 = newChunkedStreamReader(rstream)
    var buf1 = await rstream2.read(10)
    check string.fromBytes(buf1) == "0000000000"
    var buf2 = await rstream2.read()
    check string.fromBytes(buf2) == "11111111112222222222"

    # read() call will consume all the bytes and finish markers too, so
    # we just check stream for EOF.
    check rstream2.atEof() == true

    await rstream2.closeWait()
    await rstream.closeWait()
    await transp.closeWait()
    await server.join()

  asyncTest "consume":
    proc serveClient(server: StreamServer,
                      transp: StreamTransport) {.async: (raises: []).} =
      try:
        const
          S4 = @[byte('3'), byte('3'), byte('3'), byte('3'), byte('3')]
        var wstream = newAsyncStreamWriter(transp)
        var wstream2 = newChunkedStreamWriter(wstream)

        var s1 = "00000"
        var s2 = "11111".toBytes()
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
      except CatchableError as exc:
        raiseAssert exc.msg

    var server = createStreamServer(initTAddress("127.0.0.1:0"),
                                    serveClient, {ReuseAddr})
    server.start()
    var transp = await connect(server.localAddress())
    var rstream = newAsyncStreamReader(transp)
    var rstream2 = newChunkedStreamReader(rstream)

    var res1 = await rstream2.consume(10)
    check:
      res1 == 10
    var buf1 = await rstream2.read(10)
    check string.fromBytes(buf1) == "1111111111"
    var res2 = await rstream2.consume(10)
    check:
      res2 == 10
    var buf2 = await rstream2.read(10)
    check string.fromBytes(buf2) == "3333333333"

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

  asyncTest "write(eof)":
    let
      size = 10240
      message = createBigMessage("ABCDEFGHIJKLMNOP", size)

    proc processClient(server: StreamServer,
                        transp: StreamTransport) {.async: (raises: []).} =
      try:
        var wstream = newAsyncStreamWriter(transp)
        var wbstream = newBoundedStreamWriter(wstream, uint64(size))
        try:
          check wbstream.atEof() == false
          await wbstream.write(message)
          check wbstream.atEof() == false
          await wbstream.finish()
          check wbstream.atEof() == true
          expect AsyncStreamWriteEOFError:
            await wbstream.write(message)
          expect AsyncStreamWriteEOFError:
            await wbstream.write(message)
          expect AsyncStreamWriteEOFError:
            await wbstream.write(message)
          check wbstream.atEof() == true
          await wbstream.closeWait()
          check wbstream.atEof() == true
        finally:
          await wstream.closeWait()
          await transp.closeWait()
      except CatchableError as exc:
        raiseAssert exc.msg

    let flags = {ServerFlags.ReuseAddr, ServerFlags.TcpNoDelay}
    var server = createStreamServer(initTAddress("127.0.0.1:0"),
                                    processClient, flags = flags)
    server.start()
    var conn = await connect(server.localAddress())
    try:
      discard await conn.consume()
    finally:
      await conn.closeWait()
      server.stop()
      await server.closeWait()

  asyncTest "test vectors":
    const ChunkedVectors = [
      ["4\r\nWiki\r\n5\r\npedia\r\nE\r\n in\r\n\r\nchunks.\r\n0\r\n\r\n",
       "Wikipedia in\r\n\r\nchunks."],
      ["4\r\nWiki\r\n5\r\npedia\r\nE\r\n in\r\n\r\nchunks.\r\n0\r\n\r\n0\r\n\r\n",
       "Wikipedia in\r\n\r\nchunks."],
      ["3b\r\n--f98f0\r\nContent-Disposition: form-data; name=\"key1\"" &
       "\r\n\r\nA\r\n\r\n" &
       "3b\r\n--f98f0\r\nContent-Disposition: form-data; name=\"key2\"" &
       "\r\n\r\nB\r\n\r\n" &
       "3b\r\n--f98f0\r\nContent-Disposition: form-data; name=\"key3\"" &
       "\r\n\r\nC\r\n\r\n" &
       "b\r\n--f98f0--\r\n\r\n" &
       "0\r\n\r\n",
       "--f98f0\r\nContent-Disposition: form-data; name=\"key1\"" &
       "\r\n\r\nA\r\n" &
       "--f98f0\r\nContent-Disposition: form-data; name=\"key2\"" &
       "\r\n\r\nB\r\n" &
       "--f98f0\r\nContent-Disposition: form-data; name=\"key3\"" &
       "\r\n\r\nC\r\n" &
       "--f98f0--\r\n"
      ],
      ["4;position=1\r\nWiki\r\n5;position=2\r\npedia\r\nE;position=3\r\n" &
       " in\r\n\r\nchunks.\r\n0;position=4\r\n\r\n",
       "Wikipedia in\r\n\r\nchunks."],
    ]
    proc checkVector(inputstr: string): Future[string] {.async.} =
      proc serveClient(server: StreamServer,
                       transp: StreamTransport) {.async: (raises: []).} =
        try:
          var wstream = newAsyncStreamWriter(transp)
          var data = inputstr
          await wstream.write(data)
          await wstream.finish()
          await wstream.closeWait()
          await transp.closeWait()
          server.stop()
          server.close()
        except CatchableError as exc:
          raiseAssert exc.msg

      var server = createStreamServer(initTAddress("127.0.0.1:0"),
                                      serveClient, {ReuseAddr})
      server.start()
      var transp = await connect(server.localAddress())
      var rstream = newAsyncStreamReader(transp)
      var rstream2 = newChunkedStreamReader(rstream)
      var res = await rstream2.read()
      var ress = string.fromBytes(res)
      await rstream2.closeWait()
      await rstream.closeWait()
      await transp.closeWait()
      await server.join()
      result = ress

    for i in 0..<len(ChunkedVectors):
      var r = await checkVector(ChunkedVectors[i][0])
      check:
        r == ChunkedVectors[i][1]

  asyncTest "incorrect chunk":
    const IncompleteVectors = [
      "10000000;\r\n1",
      "10000000\r\n1",
      "FFFFFFFF;extension1=value1;extension2=value2\r\n1",
      "FFFFFFFF\r\n1",
    ]
    const ProtocolErrorVectors = [
      "100000000\r\n1",
      "10000000 \r\n1",
      "100000000 ;\r\n",
      "FFFFFFFF0\r\n1",
      "FFFFFFFF \r\n1",
      "FFFFFFFF ;\r\n1",
      "z\r\n1"
    ]
    proc checkVector(inputstr: string) {.async.} =
      proc serveClient(server: StreamServer,
                       transp: StreamTransport) {.async: (raises: []).} =
        try:
          var wstream = newAsyncStreamWriter(transp)
          var data = inputstr
          await wstream.write(data)
          await wstream.finish()
          await wstream.closeWait()
          await transp.closeWait()
          server.stop()
          server.close()
        except CatchableError as exc:
          raiseAssert exc.msg

      var server = createStreamServer(initTAddress("127.0.0.1:0"),
                                      serveClient, {ReuseAddr})
      server.start()
      var transp = await connect(server.localAddress())
      var rstream = newAsyncStreamReader(transp)
      var rstream2 = newChunkedStreamReader(rstream)
      try:
        discard await rstream2.read()
      finally:
        await rstream2.closeWait()
        await rstream.closeWait()
        await transp.closeWait()
        await server.join()

    for v in IncompleteVectors:
      expect(ChunkedStreamIncompleteError):
        checkpoint(v)
        await checkVector(v)

    for v in ProtocolErrorVectors:
      expect(ChunkedStreamProtocolError):
        checkpoint(v)
        await checkVector(v)

  test "hex decoding":
    for i in 0 ..< 256:
      let ch = char(i)
      case ch
      of '0' .. '9':
        check hexValue(byte(ch)) == ord(ch) - ord('0')
      of 'a' .. 'f':
        check hexValue(byte(ch)) == ord(ch) - ord('a') + 10
      of 'A' .. 'F':
        check hexValue(byte(ch)) == ord(ch) - ord('A') + 10
      else:
        check hexValue(byte(ch)) == -1

  asyncTest "too big chunk header":
    proc checkTooBigChunkHeader(inputstr: seq[byte]) {.async.} =
      proc serveClient(server: StreamServer,
                       transp: StreamTransport) {.async: (raises: []).} =
        try:
          var wstream = newAsyncStreamWriter(transp)
          await wstream.write(inputstr)
          await wstream.finish()
          await wstream.closeWait()
          await transp.closeWait()
          server.stop()
          server.close()
        except CatchableError as exc:
          raiseAssert exc.msg

      var server = createStreamServer(initTAddress("127.0.0.1:0"),
                                      serveClient, {ReuseAddr})
      server.start()
      var transp = await connect(server.localAddress())
      var rstream = newAsyncStreamReader(transp)
      var rstream2 = newChunkedStreamReader(rstream)
      expect(ChunkedStreamProtocolError):
        discard await rstream2.read()
      await rstream2.closeWait()
      await rstream.closeWait()
      await transp.closeWait()
      await server.join()

    var data1 = createBigMessage("REQUESTSTREAMMESSAGE", 65600)
    var data2 = createBigMessage("REQUESTSTREAMMESSAGE", 262400)
    await checkTooBigChunkHeader(data1)
    await checkTooBigChunkHeader(data2)

  asyncTest "read/write":
    proc checkVector(inputstr: seq[byte],
                     chunkSize: int): Future[seq[byte]] {.async.} =
      proc serveClient(server: StreamServer,
                       transp: StreamTransport) {.async: (raises: []).} =
        try:
          var wstream = newAsyncStreamWriter(transp)
          var wstream2 = newChunkedStreamWriter(wstream)
          var data = inputstr
          var offset = 0
          while true:
            if len(data) == offset:
              break
            let toWrite = min(chunkSize, len(data) - offset)
            await wstream2.write(addr data[offset], toWrite)
            offset = offset + toWrite
          await wstream2.finish()
          await wstream2.closeWait()
          await wstream.closeWait()
          await transp.closeWait()
          server.stop()
          server.close()
        except CatchableError as exc:
          raiseAssert exc.msg

      var server = createStreamServer(initTAddress("127.0.0.1:0"),
                                      serveClient, {ReuseAddr})
      server.start()
      var transp = await connect(server.localAddress())
      var rstream = newAsyncStreamReader(transp)
      var rstream2 = newChunkedStreamReader(rstream)
      var res = await rstream2.read()
      await rstream2.closeWait()
      await rstream.closeWait()
      await transp.closeWait()
      await server.join()
      return res

    proc testBigData(datasize: int, chunksize: int) {.async.} =
      var data = createBigMessage("REQUESTSTREAMMESSAGE", datasize)
      var check = await checkVector(data, chunksize)
      check:
        data == check

    await testBigData(65600, 1024)
    await testBigData(262400, 4096)
    await testBigData(767309, 4457)

  asyncTest "read chunks":
    proc checkVector(inputstr: seq[byte],
                     writeChunkSize: int,
                     readChunkSize: int): Future[seq[byte]] {.async.} =
      proc serveClient(server: StreamServer,
                       transp: StreamTransport) {.async: (raises: []).} =
        try:
          var wstream = newAsyncStreamWriter(transp)
          var wstream2 = newChunkedStreamWriter(wstream)
          var offset = 0
          while true:
            if len(inputstr) == offset:
              break
            let toWrite = min(writeChunkSize, len(inputstr) - offset)
            await wstream2.write(unsafeAddr inputstr[offset], toWrite)
            offset = offset + toWrite
          await wstream2.finish()
          await wstream2.closeWait()
          await wstream.closeWait()
          await transp.closeWait()
          server.stop()
          server.close()
        except CatchableError as exc:
          raiseAssert exc.msg

      var server = createStreamServer(initTAddress("127.0.0.1:0"),
                                      serveClient, {ReuseAddr})
      server.start()
      var transp = await connect(server.localAddress())
      var rstream = newAsyncStreamReader(transp)
      var rstream2 = newChunkedStreamReader(rstream)
      var res: seq[byte]
      while not(rstream2.atEof()):
        var chunk = await rstream2.read(readChunkSize)
        res.add(chunk)
      await rstream2.closeWait()
      await rstream.closeWait()
      await transp.closeWait()
      await server.join()
      return res

    proc testChunk(datasize: int,
                        writeChunkSize: int,
                        readChunkSize: int): Future[bool] {.async.} =
      var data = createBigMessage("REQUESTSTREAMMESSAGE", datasize)
      var check = await checkVector(data, writeChunkSize, readChunkSize)
      return (data == check)

    check waitFor(testChunk(4457, 128, 1)) == true
    check waitFor(testChunk(65600, 1024, 17)) == true
    check waitFor(testChunk(262400, 4096, 61)) == true
    check waitFor(testChunk(767309, 4457, 173)) == true
    check waitFor(testChunk(767309, 4457, 173)) == true
    check waitFor(testChunk(767309, 67000, 67001)) == true

suite "AsyncStream/TLSStream":
  teardown:
    checkLeaks()

  asyncTest "Simple server with RSA self-signed certificate":
    let key = TLSPrivateKey.init(SelfSignedRsaKey)
    let cert = TLSCertificate.init(SelfSignedRsaCert)
    let testMessage = "TEST MESSAGE"

    proc serveClient(server: StreamServer,
                     transp: StreamTransport) {.async: (raises: []).} =
      try:
        var reader = newAsyncStreamReader(transp)
        var writer = newAsyncStreamWriter(transp)
        var sstream = newTLSServerAsyncStream(reader, writer, key, cert)
        await handshake(sstream)
        await sstream.writer.write(testMessage & "\r\n")
        await sstream.writer.finish()
        await sstream.writer.closeWait()
        await sstream.reader.closeWait()
        await reader.closeWait()
        await writer.closeWait()
        await transp.closeWait()
        server.stop()
        server.close()
      except CatchableError as exc:
        raiseAssert exc.msg

    var server = createStreamServer(initTAddress("127.0.0.1:0"),
                                    serveClient, {ServerFlags.ReuseAddr})
    server.start()
    var conn = await connect(server.localAddress())
    var creader = newAsyncStreamReader(conn)
    var cwriter = newAsyncStreamWriter(conn)
    # We are using self-signed certificate
    let flags = {NoVerifyHost, NoVerifyServerName}
    var cstream = newTLSClientAsyncStream(creader, cwriter, "", flags = flags)
    let res = await cstream.reader.read()
    await cstream.reader.closeWait()
    await cstream.writer.closeWait()
    await creader.closeWait()
    await cwriter.closeWait()
    await conn.closeWait()
    await server.join()
    check string.fromBytes(res) == (testMessage & "\r\n")

  const TestVectors = [
    ("test", 56, "X509BadServerName"),
    ("chronos-server-test.com", 62, "X509NotTrusted")
  ]

  for testVector in TestVectors:
    asyncTest "Server certificate check failure [" & testVector[2] & "]":
      let key = TLSPrivateKey.init(SelfSignedRsaKey2)
      let cert = TLSCertificate.init(SelfSignedRsaCert2)

      proc serveClient(server: StreamServer,
                       transp: StreamTransport) {.async: (raises: []).} =
        try:
          var reader = newAsyncStreamReader(transp)
          var writer = newAsyncStreamWriter(transp)
          var sstream = newTLSServerAsyncStream(reader, writer, key, cert)
          expect(AsyncStreamError):
            await handshake(sstream)
          await sstream.writer.closeWait()
          await sstream.reader.closeWait()
          await reader.closeWait()
          await writer.closeWait()
          await transp.closeWait()
          server.stop()
          server.close()
        except CatchableError as exc:
          raiseAssert $exc.msg

      var server = createStreamServer(initTAddress("127.0.0.1:0"),
                                      serveClient, {ServerFlags.ReuseAddr})
      server.start()
      var conn = await connect(server.localAddress())
      var creader = newAsyncStreamReader(conn)
      var cwriter = newAsyncStreamWriter(conn)
      # We are using self-signed certificate
      var cstream =
        newTLSClientAsyncStream(creader, cwriter, testVector[0])
      try:
        discard await cstream.reader.read()
        raiseAssert "should raise"
      except TLSStreamProtocolError as exc:
        check exc.errCode == testVector[1]
      await cstream.reader.closeWait()
      await cstream.writer.closeWait()
      await creader.closeWait()
      await cwriter.closeWait()
      await conn.closeWait()
      await server.join()

  for (datasize, writeChunkSize, readChunkSize) in [
    (4457, 128, 1),
    (65600, 1024, 17),
    (262400, 4096, 61),
    (767309, 4457, 173),
    (767309, 4457, 173),
    (767309, 67000, 67001),
  ]:
    asyncTest "chunks/" & $datasize & "/" & $writeChunkSize & "/" & $readChunkSize:
      let key = TLSPrivateKey.init(SelfSignedRsaKey)
      let cert = TLSCertificate.init(SelfSignedRsaCert)
      proc checkVector(inputstr: seq[byte],
                      writeChunkSize: int,
                      readChunkSize: int): Future[seq[byte]] {.async.} =

        proc serveClient(server: StreamServer,
                        transp: StreamTransport) {.async: (raises: []).} =
          try:
            var reader = newAsyncStreamReader(transp)
            var writer = newAsyncStreamWriter(transp)
            var sstream = newTLSServerAsyncStream(reader, writer, key, cert)
            var offset = 0
            while true:
              if len(inputstr) == offset:
                break
              let toWrite = min(writeChunkSize, len(inputstr) - offset)
              await sstream.writer.write(unsafeAddr inputstr[offset], toWrite)
              offset = offset + toWrite

            await sstream.writer.finish()
            await sstream.writer.closeWait()
            await sstream.reader.closeWait()
            await reader.closeWait()
            await writer.closeWait()
            await transp.closeWait()
            server.stop()
            server.close()
          except CatchableError as exc:
            raiseAssert exc.msg

        var server = createStreamServer(initTAddress("127.0.0.1:0"),
                                        serveClient, {ServerFlags.ReuseAddr, ServerFlags.TcpNoDelay})
        server.start()
        var conn = await connect(server.localAddress(), flags = {SocketFlags.TcpNoDelay})
        var creader = newAsyncStreamReader(conn)
        var cwriter = newAsyncStreamWriter(conn)
        # We are using self-signed certificate
        let flags = {NoVerifyHost, NoVerifyServerName}
        var cstream = newTLSClientAsyncStream(creader, cwriter, "", flags = flags)
        var res: seq[byte]
        while not(cstream.reader.atEof()):
          var chunk = await cstream.reader.read(readChunkSize)
          res.add(chunk)
        await cstream.reader.closeWait()
        await cstream.writer.closeWait()
        await creader.closeWait()
        await cwriter.closeWait()
        await conn.closeWait()
        await server.join()
        return res

      var data = createBigMessage("REQUESTSTREAMMESSAGE", datasize)
      var check = await checkVector(data, writeChunkSize, readChunkSize)
      check:
        data.len == check.len
        string.fromBytes(data) == string.fromBytes(check)

  asyncTest "Custom TrustAnchors":
    let key = TLSPrivateKey.init(SelfSignedRsaKey)
    let cert = TLSCertificate.init(SelfSignedRsaCert)
    let trustAnchors = TrustAnchorStore.new(SelfSignedTrustAnchors)
    const testMessage = "Some message\r\n"
    proc serveClient(server: StreamServer,
                    transp: StreamTransport) {.async: (raises: []).} =
      try:
        var reader = newAsyncStreamReader(transp)
        var writer = newAsyncStreamWriter(transp)
        var sstream = newTLSServerAsyncStream(reader, writer, key, cert)
        await handshake(sstream)
        await sstream.writer.write(testMessage)
        await sstream.writer.finish()
        await sstream.writer.closeWait()
        await sstream.reader.closeWait()
        await reader.closeWait()
        await writer.closeWait()
        await transp.closeWait()
        server.stop()
        server.close()
      except CatchableError as exc:
        raiseAssert exc.msg

    var server = createStreamServer(initTAddress("127.0.0.1:0"),
                                    serveClient, {ReuseAddr})
    server.start()
    var conn = await connect(server.localAddress())
    var creader = newAsyncStreamReader(conn)
    var cwriter = newAsyncStreamWriter(conn)
    let flags = {NoVerifyServerName}
    var cstream = newTLSClientAsyncStream(creader, cwriter, "", flags = flags,
      trustAnchors = trustAnchors)
    let res = await cstream.reader.read()
    await cstream.reader.closeWait()
    await cstream.writer.closeWait()
    await creader.closeWait()
    await cwriter.closeWait()
    await conn.closeWait()
    await server.join()
    check: string.fromBytes(res) == testMessage

  asyncTest "Client certificate authentication":
    let key = TLSPrivateKey.init(SelfSignedRsaKey)
    let cert = TLSCertificate.init(SelfSignedRsaCert)
    const testMessage = "Client cert test\r\n"

    proc serveClient(server: StreamServer,
                    transp: StreamTransport) {.async: (raises: []).} =
      try:
        var reader = newAsyncStreamReader(transp)
        var writer = newAsyncStreamWriter(transp)
        var sstream = newTLSServerAsyncStream(reader, writer, key, cert,
          flags = {TLSFlags.NoRenegotiation})
        # Configure client certificate authentication via BearSSL API.
        # serverX509 must be stored on TLSAsyncStream to ensure it
        # outlives the TLS session (BearSSL holds a pointer to it).
        x509MinimalInitFull(sstream.x509,
                            unsafeAddr SelfSignedTrustAnchors[0],
                            uint(len(SelfSignedTrustAnchors)))
        sslEngineSetDefaultRsavrfy(sstream.scontext.eng)
        sslEngineSetDefaultEcdsa(sstream.scontext.eng)
        sslServerSetTrustAnchorNamesAlt(sstream.scontext,
          unsafeAddr SelfSignedTrustAnchors[0],
          uint(len(SelfSignedTrustAnchors)))
        sslEngineSetX509(sstream.scontext.eng,
          X509ClassPointerConst(addr sstream.x509.vtable))
        discard sslServerReset(sstream.scontext)
        await handshake(sstream)
        await sstream.writer.write(testMessage)
        await sstream.writer.finish()
        await sstream.writer.closeWait()
        await sstream.reader.closeWait()
        await reader.closeWait()
        await writer.closeWait()
        await transp.closeWait()
        server.stop()
        server.close()
      except CatchableError as exc:
        raiseAssert exc.msg

    var server = createStreamServer(initTAddress("127.0.0.1:0"),
                                    serveClient, {ReuseAddr})
    server.start()
    var conn = await connect(server.localAddress())
    var creader = newAsyncStreamReader(conn)
    var cwriter = newAsyncStreamWriter(conn)
    let flags = {NoVerifyHost, NoVerifyServerName}
    var cstream = newTLSClientAsyncStream(creader, cwriter, "",
      flags = flags, certificate = cert, privateKey = key)
    let res = await cstream.reader.read()
    await cstream.reader.closeWait()
    await cstream.writer.closeWait()
    await creader.closeWait()
    await cwriter.closeWait()
    await conn.closeWait()
    await server.join()
    check:
      string.fromBytes(res) == testMessage

  asyncTest "Client certificate authentication (EC)":
    let key = TLSPrivateKey.init(SelfSignedEcKey)
    let cert = TLSCertificate.init(SelfSignedEcCert)
    const testMessage = "EC client cert test\r\n"
    proc serveClient(server: StreamServer,
                    transp: StreamTransport) {.async: (raises: []).} =
      try:
        var reader = newAsyncStreamReader(transp)
        var writer = newAsyncStreamWriter(transp)
        var sstream = newTLSServerAsyncStream(reader, writer, key, cert,
          flags = {TLSFlags.NoRenegotiation})
        # Configure client certificate authentication via BearSSL API.
        # serverX509 must be stored on TLSAsyncStream to ensure it
        # outlives the TLS session (BearSSL holds a pointer to it).
        x509MinimalInitFull(sstream.x509,
                            unsafeAddr SelfSignedEcTrustAnchors[0],
                            uint(len(SelfSignedEcTrustAnchors)))
        sslEngineSetDefaultRsavrfy(sstream.scontext.eng)
        sslEngineSetDefaultEcdsa(sstream.scontext.eng)
        sslServerSetTrustAnchorNamesAlt(sstream.scontext,
          unsafeAddr SelfSignedEcTrustAnchors[0],
          uint(len(SelfSignedEcTrustAnchors)))
        sslEngineSetX509(sstream.scontext.eng,
          X509ClassPointerConst(addr sstream.x509.vtable))
        discard sslServerReset(sstream.scontext)
        await handshake(sstream)
        await sstream.writer.write(testMessage)
        await sstream.writer.finish()
        await sstream.writer.closeWait()
        await sstream.reader.closeWait()
        await reader.closeWait()
        await writer.closeWait()
        await transp.closeWait()
        server.stop()
        server.close()
      except CatchableError as exc:
        raiseAssert exc.msg

    var server = createStreamServer(initTAddress("127.0.0.1:0"),
                                    serveClient, {ReuseAddr})
    server.start()
    var conn = await connect(server.localAddress())
    var creader = newAsyncStreamReader(conn)
    var cwriter = newAsyncStreamWriter(conn)
    let flags = {NoVerifyHost, NoVerifyServerName}
    var cstream = newTLSClientAsyncStream(creader, cwriter, "",
      flags = flags, certificate = cert, privateKey = key)
    let res = await cstream.reader.read()
    await cstream.reader.closeWait()
    await cstream.writer.closeWait()
    await creader.closeWait()
    await cwriter.closeWait()
    await conn.closeWait()
    await server.join()
    check:
      string.fromBytes(res) == testMessage

  asyncTest "ALPN negotiation":
    var key = TLSPrivateKey.init(SelfSignedRsaKey)
    var cert = TLSCertificate.init(SelfSignedRsaCert)
    var serverAlpn = ""

    proc serveClient(server: StreamServer,
                     transp: StreamTransport) {.async: (raises: []).} =
      try:
        var reader = newAsyncStreamReader(transp)
        var writer = newAsyncStreamWriter(transp)
        var sstream = newTLSServerAsyncStream(reader, writer, key, cert,
          alpnProtocols = ["h2", "http/1.1"])
        await handshake(sstream)
        serverAlpn = getSelectedAlpnProtocol(sstream)
        await sstream.writer.write(serverAlpn & "\r\n")
        await sstream.writer.finish()
        await sstream.writer.closeWait()
        await sstream.reader.closeWait()
        await reader.closeWait()
        await writer.closeWait()
        await transp.closeWait()
        server.stop()
        server.close()
      except CatchableError as exc:
        raiseAssert exc.msg

    let flags = {NoVerifyHost, NoVerifyServerName}
    var server = createStreamServer(initTAddress("127.0.0.1:0"),
                                    serveClient, {ServerFlags.ReuseAddr})
    server.start()
    var conn = await connect(server.localAddress())
    var creader = newAsyncStreamReader(conn)
    var cwriter = newAsyncStreamWriter(conn)
    var cstream = newTLSClientAsyncStream(creader, cwriter, "",
      flags = flags, alpnProtocols = ["h2", "http/1.1"])
    await handshake(cstream)
    let clientAlpn = getSelectedAlpnProtocol(cstream)
    let res = await cstream.reader.read()
    await cstream.reader.closeWait()
    await cstream.writer.closeWait()
    await creader.closeWait()
    await cwriter.closeWait()
    await conn.closeWait()
    await server.join()
    check serverAlpn == "h2"
    check clientAlpn == "h2"
    check string.fromBytes(res) == "h2\r\n"

suite "AsyncStream/BoundedStream":
  teardown:
    checkLeaks()

  type
    BoundarySizeTest = enum
      SizeReadWrite, SizeOverflow, SizeIncomplete, SizeEmpty
    BoundaryBytesTest = enum
      BoundaryRead, BoundaryDouble, BoundarySize, BoundaryIncomplete,
      BoundaryEmpty

  for itemComp in [BoundCmp.Equal, BoundCmp.LessOrEqual]:
    for itemSize in [100, 60000]:

      proc boundaryTest(btest: BoundaryBytesTest,
                        size: int, boundary: seq[byte],
                        cmp: BoundCmp) {.async.} =
        var message = createBigMessage("ABCDEFGHIJKLMNOP", size)
        var clientRes = false

        proc processClient(server: StreamServer,
                           transp: StreamTransport) {.async: (raises: []).} =
          try:
            var wstream = newAsyncStreamWriter(transp)
            case btest
            of BoundaryRead:
              await wstream.write(message)
              await wstream.write(boundary)
              await wstream.finish()
              await wstream.closeWait()
              clientRes = true
            of BoundaryDouble:
              await wstream.write(message)
              await wstream.write(boundary)
              await wstream.write(message)
              await wstream.finish()
              await wstream.closeWait()
              clientRes = true
            of BoundarySize:
              var ncmessage = message
              ncmessage.setLen(len(message) - 2)
              await wstream.write(ncmessage)
              await wstream.write(@[0x2D'u8, 0x2D'u8])
              await wstream.finish()
              await wstream.closeWait()
              clientRes = true
            of BoundaryIncomplete:
              var ncmessage = message
              ncmessage.setLen(len(message) - 2)
              await wstream.write(ncmessage)
              await wstream.finish()
              await wstream.closeWait()
              clientRes = true
            of BoundaryEmpty:
              await wstream.write(boundary)
              await wstream.finish()
              await wstream.closeWait()
              clientRes = true

            await transp.closeWait()
            server.stop()
            server.close()
          except CatchableError as exc:
            raiseAssert exc.msg

        let flags = {ServerFlags.ReuseAddr, ServerFlags.TcpNoDelay}
        var server = createStreamServer(initTAddress("127.0.0.1:0"),
                                        processClient, flags = flags)
        server.start()
        var conn = await connect(server.localAddress())
        var rstream = newAsyncStreamReader(conn)
        case btest
        of BoundaryRead:
          var rbstream = newBoundedStreamReader(rstream, boundary)
          let response = await rbstream.read()
          check response == message
          await rbstream.closeWait()
        of BoundaryDouble:
          var rbstream = newBoundedStreamReader(rstream, boundary)
          let response1 = await rbstream.read()
          await rbstream.closeWait()
          let response2 = await rstream.read()
          check:
            response1 == message
            response2 == message

        of BoundarySize:
          var expectMessage = message
          expectMessage[^2] = 0x2D'u8
          expectMessage[^1] = 0x2D'u8
          var rbstream = newBoundedStreamReader(rstream, uint64(size), boundary)
          let response = await rbstream.read()
          await rbstream.closeWait()
          check:
            response == expectMessage
        of BoundaryIncomplete:
          var rbstream = newBoundedStreamReader(rstream, boundary)
          expect(BoundedStreamIncompleteError):
            discard await rbstream.read()
          await rbstream.closeWait()
        of BoundaryEmpty:
          var rbstream = newBoundedStreamReader(rstream, boundary)
          let response = await rbstream.read()
          await rbstream.closeWait()
          check: len(response) == 0

        await rstream.closeWait()
        await conn.closeWait()
        await server.join()
        check clientRes

      proc boundedTest(stest: BoundarySizeTest,
                       size: int, cmp: BoundCmp) {.async.} =
        let messagePart = createBigMessage("ABCDEFGHIJKLMNOP",
                                           int(itemSize) div 10)
        var message: seq[byte]
        for i in 0 ..< 10:
          message.add(messagePart)

        proc processClient(server: StreamServer,
                           transp: StreamTransport) {.async: (raises: []).} =
          try:
            var wstream = newAsyncStreamWriter(transp)
            var wbstream = newBoundedStreamWriter(wstream, uint64(size),
                                                  comparison = cmp)
            case stest
            of SizeReadWrite:
              for i in 0 ..< 10:
                await wbstream.write(messagePart)
              await wbstream.finish()
              await wbstream.closeWait()
            of SizeOverflow:
              for i in 0 ..< 10:
                await wbstream.write(messagePart)
              expect(BoundedStreamOverflowError):
                await wbstream.write(messagePart)
              await wbstream.closeWait()
            of SizeIncomplete:
              for i in 0 ..< 9:
                await wbstream.write(messagePart)
              case cmp
              of BoundCmp.Equal:
                expect(BoundedStreamIncompleteError):
                  await wbstream.finish()
              of BoundCmp.LessOrEqual:
                await wbstream.finish()
              await wbstream.closeWait()
            of SizeEmpty:
              case cmp
              of BoundCmp.Equal:
                expect(BoundedStreamIncompleteError):
                  await wbstream.finish()
              of BoundCmp.LessOrEqual:
                await wbstream.finish()
              await wbstream.closeWait()

            await wstream.closeWait()
            await transp.closeWait()
            server.stop()
            server.close()
          except CatchableError as exc:
            raiseAssert exc.msg

        let flags = {ServerFlags.ReuseAddr, ServerFlags.TcpNoDelay}
        var server = createStreamServer(initTAddress("127.0.0.1:0"),
                                        processClient, flags = flags)
        server.start()
        var conn = await connect(server.localAddress())
        var rstream = newAsyncStreamReader(conn)
        var rbstream = newBoundedStreamReader(rstream, uint64(size),
                                              comparison = cmp)
        case stest
        of SizeReadWrite:
          let response = await rbstream.read()
          await rbstream.closeWait()
          check response == message

        of SizeOverflow:
          let response = await rbstream.read()
          await rbstream.closeWait()
          check response == message
        of SizeIncomplete:
          case cmp
          of BoundCmp.Equal:
            expect(BoundedStreamIncompleteError):
              discard await rbstream.read()
          of BoundCmp.LessOrEqual:
            let response = await rbstream.read()
            check len(response) == 9 * len(messagePart)
          await rbstream.closeWait()
        of SizeEmpty:
          case cmp
          of BoundCmp.Equal:
            expect(BoundedStreamIncompleteError):
              discard await rbstream.read()
          of BoundCmp.LessOrEqual:
            let response = await rbstream.read()
            check len(response) == 0
          await rbstream.closeWait()

        await rstream.closeWait()
        await conn.closeWait()
        await server.join()

      let suffix =
        case itemComp
        of BoundCmp.Equal:
          "== " & $itemSize
        of BoundCmp.LessOrEqual:
          "<= " & $itemSize

      asyncTest "BoundedStream(size) reading/writing test [" & suffix & "]":
        await boundedTest(SizeReadWrite, itemSize, itemComp)
      asyncTest "BoundedStream(size) overflow test [" & suffix & "]":
        await boundedTest(SizeOverflow, itemSize, itemComp)
      asyncTest "BoundedStream(size) incomplete test [" & suffix & "]":
        await(boundedTest(SizeIncomplete, itemSize, itemComp))
      asyncTest "BoundedStream(size) empty message test [" & suffix & "]":
        await(boundedTest(SizeEmpty, itemSize, itemComp))
      asyncTest "BoundedStream(boundary) reading test [" & suffix & "]":
        await(boundaryTest(BoundaryRead, itemSize,
                             @[0x2D'u8, 0x2D'u8, 0x2D'u8], itemComp))
      asyncTest "BoundedStream(boundary) double message test [" & suffix & "]":
        await(boundaryTest(BoundaryDouble, itemSize,
                             @[0x2D'u8, 0x2D'u8, 0x2D'u8], itemComp))
      asyncTest "BoundedStream(size+boundary) reading size-bound test [" &
           suffix & "]":
        await(boundaryTest(BoundarySize, itemSize,
                             @[0x2D'u8, 0x2D'u8, 0x2D'u8], itemComp))
      asyncTest "BoundedStream(boundary) reading incomplete test [" &
           suffix & "]":
        await(boundaryTest(BoundaryIncomplete, itemSize,
                             @[0x2D'u8, 0x2D'u8, 0x2D'u8], itemComp))
      asyncTest "BoundedStream(boundary) empty message test [" &
           suffix & "]":
        await(boundaryTest(BoundaryEmpty, itemSize,
                             @[0x2D'u8, 0x2D'u8, 0x2D'u8], itemComp))

  asyncTest "read small chunks":
    proc checkVector(inputstr: seq[byte],
                     writeChunkSize: int,
                     readChunkSize: int): Future[seq[byte]] {.async.} =
      proc serveClient(server: StreamServer,
                       transp: StreamTransport) {.async: (raises: []).} =
        try:
          var wstream = newAsyncStreamWriter(transp)
          var wstream2 = newBoundedStreamWriter(wstream, uint64(len(inputstr)))
          var data = inputstr
          var offset = 0
          while true:
            if len(data) == offset:
              break
            let toWrite = min(writeChunkSize, len(data) - offset)
            await wstream2.write(addr data[offset], toWrite)
            offset = offset + toWrite
          await wstream2.finish()
          await wstream2.closeWait()
          await wstream.closeWait()
          await transp.closeWait()
          server.stop()
          server.close()
        except CatchableError as exc:
          raiseAssert exc.msg

      var server = createStreamServer(initTAddress("127.0.0.1:0"),
                                      serveClient, {ReuseAddr})
      server.start()
      var transp = await connect(server.localAddress())
      var rstream = newAsyncStreamReader(transp)
      var rstream2 = newBoundedStreamReader(rstream, 1048576,
                                            comparison = BoundCmp.LessOrEqual)
      var res: seq[byte]
      while not(rstream2.atEof()):
        var chunk = await rstream2.read(readChunkSize)
        res.add(chunk)
      await rstream2.closeWait()
      await rstream.closeWait()
      await transp.closeWait()
      await server.join()
      return res

    proc testSmallChunk(datasize: int, writeChunkSize: int,
                        readChunkSize: int) {.async.} =
      var data = createBigMessage("0123456789ABCDEFGHI", datasize)
      var check = await checkVector(data, writeChunkSize, readChunkSize)
      check (data == check)

    await testSmallChunk(4457, 128, 1)
    await testSmallChunk(65600, 1024, 17)
    await testSmallChunk(262400, 4096, 61)
    await testSmallChunk(767309, 4457, 173)

  asyncTest "zero-sized streams":
    proc serveClient(server: StreamServer,
                      transp: StreamTransport) {.async: (raises: []).} =
      try:
        var wstream = newAsyncStreamWriter(transp)
        var wstream2 = newBoundedStreamWriter(wstream, 0'u64)
        await wstream2.finish()
        check: wstream2.atEof()
        await wstream2.closeWait()
        await wstream.closeWait()
        await transp.closeWait()
        server.stop()
        server.close()
      except CatchableError as exc:
        raiseAssert exc.msg

    var server = createStreamServer(initTAddress("127.0.0.1:0"),
                                    serveClient, {ReuseAddr})
    server.start()
    var transp = await connect(server.localAddress())
    var rstream = newAsyncStreamReader(transp)
    var wstream3 = newAsyncStreamWriter(transp)
    var rstream2 = newBoundedStreamReader(rstream, 0'u64)
    var wstream4 = newBoundedStreamWriter(wstream3, 0'u64)

    check rstream2.atEof()

    expect(BoundedStreamOverflowError):
      await wstream4.write("data")

    await wstream4.closeWait()
    await wstream3.closeWait()
    await rstream2.closeWait()
    await rstream.closeWait()
    await transp.closeWait()
    await server.join()

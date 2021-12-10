#
#        Chronos HTTP/S server implementation
#             (c) Copyright 2021-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)
import httpserver
import ../../asyncloop, ../../asyncsync
import ../../streams/[asyncstream, tlsstream]
export asyncloop, asyncsync, httpserver, asyncstream, tlsstream

type
  SecureHttpServer* = object of HttpServer
    secureFlags*: set[TLSFlags]
    tlsPrivateKey: TLSPrivateKey
    tlsCertificate: TLSCertificate

  SecureHttpServerRef* = ref SecureHttpServer

  SecureHttpConnection* = object of HttpConnection
    tlsStream*: TLSAsyncStream

  SecureHttpConnectionRef* = ref SecureHttpConnection

proc new*(ht: typedesc[SecureHttpConnectionRef], server: SecureHttpServerRef,
          transp: StreamTransport): SecureHttpConnectionRef =
  var res = SecureHttpConnectionRef()
  HttpConnection(res[]).init(HttpServerRef(server), transp)
  let tlsStream =
    newTLSServerAsyncStream(res.mainReader, res.mainWriter,
                            server.tlsPrivateKey,
                            server.tlsCertificate,
                            minVersion = TLSVersion.TLS12,
                            flags = server.secureFlags)
  res.tlsStream = tlsStream
  res.reader = AsyncStreamReader(tlsStream.reader)
  res.writer = AsyncStreamWriter(tlsStream.writer)
  res

proc createSecConnection(server: HttpServerRef,
                         transp: StreamTransport): Future[HttpConnectionRef] {.
     async.} =
  let secureServ = cast[SecureHttpServerRef](server)
  var sconn = SecureHttpConnectionRef.new(secureServ, transp)
  try:
    await handshake(sconn.tlsStream)
    return HttpConnectionRef(sconn)
  except CancelledError as exc:
    await HttpConnectionRef(sconn).closeWait()
    raise exc
  except TLSStreamError:
    await HttpConnectionRef(sconn).closeWait()
    raiseHttpCriticalError("Unable to establish secure connection")

proc new*(htype: typedesc[SecureHttpServerRef],
          address: TransportAddress,
          processCallback: HttpProcessCallback,
          tlsPrivateKey: TLSPrivateKey,
          tlsCertificate: TLSCertificate,
          serverFlags: set[HttpServerFlags] = {},
          socketFlags: set[ServerFlags] = {ReuseAddr},
          serverUri = Uri(),
          serverIdent = "",
          secureFlags: set[TLSFlags] = {},
          maxConnections: int = -1,
          bufferSize: int = 4096,
          backlogSize: int = 100,
          httpHeadersTimeout = 10.seconds,
          maxHeadersSize: int = 8192,
          maxRequestBodySize: int = 1_048_576
         ): HttpResult[SecureHttpServerRef] =

  doAssert(not(isNil(tlsPrivateKey)), "TLS private key must not be nil!")
  doAssert(not(isNil(tlsCertificate)), "TLS certificate must not be nil!")

  let serverUri =
    if len(serverUri.hostname) > 0:
      serverUri
    else:
      try:
        parseUri("https://" & $address & "/")
      except TransportAddressError as exc:
        return err(exc.msg)

  let serverInstance =
    try:
      createStreamServer(address, flags = socketFlags, bufferSize = bufferSize,
                         backlog = backlogSize)
    except TransportOsError as exc:
      return err(exc.msg)
    except CatchableError as exc:
      return err(exc.msg)

  var res = SecureHttpServerRef()
  HttpServer(res[]).init(address, serverInstance, processCallback,
                         createSecConnection, serverUri, serverFlags,
                         socketFlags, serverIdent, maxConnections,
                         bufferSize, backlogSize, httpHeadersTimeout,
                         maxHeadersSize, maxRequestBodySize)
  res.tlsCertificate = tlsCertificate
  res.tlsPrivateKey = tlsPrivateKey
  res.secureFlags = secureFlags
  ok(res)

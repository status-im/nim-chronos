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

proc closeSecConnection(conn: HttpConnectionRef) {.async.} =
  if conn.state == HttpState.Alive:
    conn.state = HttpState.Closing
    var pending: seq[Future[void]]
    pending.add(conn.writer.closeWait())
    pending.add(conn.reader.closeWait())
    pending.add(conn.mainReader.closeWait())
    pending.add(conn.mainWriter.closeWait())
    pending.add(conn.transp.closeWait())
    await noCancel(allFutures(pending))
    reset(cast[SecureHttpConnectionRef](conn)[])
    untrackCounter(HttpServerSecureConnectionTrackerName)
    conn.state = HttpState.Closed

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
  res.closeCb = closeSecConnection
  trackCounter(HttpServerSecureConnectionTrackerName)
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
  except TLSStreamError as exc:
    await HttpConnectionRef(sconn).closeWait()
    let msg = "Unable to establish secure connection, reason [" &
              $exc.msg & "]"
    raiseHttpCriticalError(msg)
  except CatchableError as exc:
    await HttpConnectionRef(sconn).closeWait()
    let msg = "Unexpected error while trying to establish secure connection, " &
              "reason [" & $exc.msg & "]"
    raiseHttpCriticalError(msg)

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
          backlogSize: int = DefaultBacklogSize,
          httpHeadersTimeout = 10.seconds,
          maxHeadersSize: int = 8192,
          maxRequestBodySize: int = 1_048_576,
          dualstack = DualStackType.Auto
         ): HttpResult[SecureHttpServerRef] {.raises: [].} =

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
                         backlog = backlogSize, dualstack = dualstack)
    except TransportOsError as exc:
      return err(exc.msg)
    except CatchableError as exc:
      return err(exc.msg)

  let res = SecureHttpServerRef(
    address: address,
    instance: serverInstance,
    processCallback: processCallback,
    createConnCallback: createSecConnection,
    baseUri: serverUri,
    serverIdent: serverIdent,
    flags: serverFlags + {HttpServerFlags.Secure},
    socketFlags: socketFlags,
    maxConnections: maxConnections,
    bufferSize: bufferSize,
    backlogSize: backlogSize,
    headersTimeout: httpHeadersTimeout,
    maxHeadersSize: maxHeadersSize,
    maxRequestBodySize: maxRequestBodySize,
    # semaphore:
    #   if maxConnections > 0:
    #     newAsyncSemaphore(maxConnections)
    #   else:
    #     nil
    lifetime: newFuture[void]("http.server.lifetime"),
    connections: initOrderedTable[string, HttpConnectionHolderRef](),
    tlsCertificate: tlsCertificate,
    tlsPrivateKey: tlsPrivateKey,
    secureFlags: secureFlags
  )
  ok(res)

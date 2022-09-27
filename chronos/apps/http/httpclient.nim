#
#                Chronos HTTP/S client
#             (c) Copyright 2021-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)
import std/[uri, tables, strutils, sequtils]
import stew/[results, base10, base64], httputils
import ../../asyncloop, ../../asyncsync
import ../../streams/[asyncstream, tlsstream, chunkstream, boundstream]
import httptable, httpcommon, httpagent, httpbodyrw, multipart
import nimSocks/[client, types]
export results, asyncloop, asyncsync, asyncstream, tlsstream, chunkstream,
       boundstream, httptable, httpcommon, httpagent, httpbodyrw, multipart,
       httputils

const
  HttpMaxHeadersSize* = 8192
    ## Maximum size of HTTP headers in octets
  HttpConnectTimeout* = 12.seconds
    ## Timeout for connecting to host (12 sec)
  HttpHeadersTimeout* = 120.seconds
    ## Timeout for receiving response headers (120 sec)
  HttpMaxRedirections* = 10
    ## Maximum number of Location redirections.
  HttpClientConnectionTrackerName* = "httpclient.connection"
    ## HttpClient connection leaks tracker name
  HttpClientRequestTrackerName* = "httpclient.request"
    ## HttpClient request leaks tracker name
  HttpClientResponseTrackerName* = "httpclient.response"
    ## HttpClient response leaks tracker name
  ProxyTimeout* = 10.seconds

type
  HttpClientConnectionState* {.pure.} = enum
    Closed                    ## Connection has been closed
    Closing,                  ## Connection is closing
    Resolving,                ## Resolving remote hostname
    Connecting,               ## Connecting to remote server
    Ready,                    ## Connected to remote server
    Acquired,                 ## Connection is acquired for use
    RequestHeadersSending,    ## Sending request headers
    RequestHeadersSent,       ## Request headers has been sent
    RequestBodySending,       ## Sending request body
    RequestBodySent,          ## Request body has been sent
    ResponseHeadersReceiving, ## Receiving response headers
    ResponseHeadersReceived,  ## Response headers has been received
    ResponseBodyReceiving,    ## Receiving response body
    ResponseBodyReceived,     ## Response body has been received
    Error                     ## Error happens

  HttpClientScheme* {.pure.} = enum
    NonSecure,                ## Non-secure connection
    Secure                    ## Secure TLS connection

  HttpReqRespState* {.pure.} = enum
    Closed,                   ## Request/response has been closed
    Closing,                  ## Request/response is closing
    Ready,                    ## Request/response is ready
    Open,                     ## Request/response started
    Finished,                 ## Request/response has been sent/received
    Error                     ## Request/response in error state

  HttpClientBodyFlag* {.pure.} = enum
    Sized,                    ## `Content-Length` present
    Chunked,                  ## `Transfer-Encoding: chunked` present
    Custom                    ## None of the above

  HttpClientRequestFlag* {.pure.} = enum
    CloseConnection,          ## Send `Connection: close` in request

  HttpClientConnectionFlag* {.pure.} = enum
    Request,                  ## Connection has pending request
    Response,                 ## Connection has pending response
    KeepAlive,                ## Connection should be kept alive
    NoBody                    ## Connection response do not have body

  HttpHeaderTuple* = tuple
    key: string
    value: string

  HttpResponseTuple* = tuple
    status: int
    data: seq[byte]
    redirects: seq[string]

  Proxy* = object
    address*: HttpAddress
    auth*: ProxyAuthentication
    timeout*: Duration
    kind*: ProxyKind

  ProxyRef* = ref Proxy

  HttpClientConnection* = object of RootObj
    id*: uint64
    case kind*: HttpClientScheme
    of HttpClientScheme.NonSecure:
      discard
    of HttpClientScheme.Secure:
      treader*: AsyncStreamReader
      twriter*: AsyncStreamWriter
      tls*: TLSAsyncStream
    transp*: StreamTransport
    reader*: AsyncStreamReader
    writer*: AsyncStreamWriter
    state*: HttpClientConnectionState
    error*: ref HttpError
    remoteHostname*: string
    flags*: set[HttpClientConnectionFlag]
    proxyConn*: HttpClientConnectionRef

  HttpClientConnectionRef* = ref HttpClientConnection

  HttpSessionRef* = ref object
    connections*: Table[string, seq[HttpClientConnectionRef]]
    counter*: uint64
    maxRedirections*: int
    connectTimeout*: Duration
    headersTimeout*: Duration
    connectionBufferSize*: int
    maxConnections*: int
    flags*: HttpClientFlags
    proxy*: ProxyRef

  HttpAddress* = object
    id*: string
    scheme*: HttpClientScheme
    hostname*: string
    port*: uint16
    path*: string
    query*: string
    anchor*: string
    username*: string
    password*: string
    addresses*: seq[TransportAddress]

  HttpClientRequest* = object
    state: HttpReqRespState
    meth*: HttpMethod
    address*: HttpAddress
    version*: HttpVersion
    headers*: HttpTable
    bodyFlag: HttpClientBodyFlag
    flags: set[HttpClientRequestFlag]
    connection*: HttpClientConnectionRef
    session*: HttpSessionRef
    error*: ref HttpError
    buffer*: seq[byte]
    writer*: HttpBodyWriter
    redirectCount: int

  HttpClientRequestRef* = ref HttpClientRequest

  HttpClientResponse* = object
    state: HttpReqRespState
    requestMethod*: HttpMethod
    address*: HttpAddress
    status*: int
    reason*: string
    version*: HttpVersion
    headers*: HttpTable
    connection*: HttpClientConnectionRef
    session*: HttpSessionRef
    reader*: HttpBodyReader
    error*: ref HttpError
    bodyFlag*: HttpClientBodyFlag
    contentEncoding*: set[ContentEncodingFlags]
    transferEncoding*: set[TransferEncodingFlags]
    contentLength*: uint64
    contentType*: Opt[ContentTypeData]

  HttpClientResponseRef* = ref HttpClientResponse

  HttpClientFlag* {.pure.} = enum
    NoVerifyHost,        ## Skip remote server certificate verification
    NoVerifyServerName,  ## Skip remote server name CN verification
    NoInet4Resolution,   ## Do not resolve server hostname to IPv4 addresses
    NoInet6Resolution,   ## Do not resolve server hostname to IPv6 addresses
    NoAutomaticRedirect, ## Do not handle HTTP redirection automatically
    NewConnectionAlways  ## Always create new connection to HTTP server

  HttpClientFlags* = set[HttpClientFlag]

  HttpClientTracker* = ref object of TrackerBase
    opened*: int64
    closed*: int64

# HttpClientRequestRef valid states are:
# Ready -> Open -> (Finished, Error) -> (Closing, Closed)
#
# HttpClientResponseRef valid states are
# Open -> (Finished, Error) -> (Closing, Closed)

proc setupHttpClientConnectionTracker(): HttpClientTracker {.
     gcsafe, raises: [Defect].}
proc setupHttpClientRequestTracker(): HttpClientTracker {.
     gcsafe, raises: [Defect].}
proc setupHttpClientResponseTracker(): HttpClientTracker {.
     gcsafe, raises: [Defect].}

proc getHttpClientConnectionTracker(): HttpClientTracker {.inline.} =
  var res = cast[HttpClientTracker](getTracker(HttpClientConnectionTrackerName))
  if isNil(res):
    res = setupHttpClientConnectionTracker()
  res

proc getHttpClientRequestTracker(): HttpClientTracker {.inline.} =
  var res = cast[HttpClientTracker](getTracker(HttpClientRequestTrackerName))
  if isNil(res):
    res = setupHttpClientRequestTracker()
  res

proc getHttpClientResponseTracker(): HttpClientTracker {.inline.} =
  var res = cast[HttpClientTracker](getTracker(HttpClientResponseTrackerName))
  if isNil(res):
    res = setupHttpClientResponseTracker()
  res

proc dumpHttpClientConnectionTracking(): string {.gcsafe.} =
  let tracker = getHttpClientConnectionTracker()
  "Opened HTTP client connections: " & $tracker.opened & "\n" &
  "Closed HTTP client connections: " & $tracker.closed

proc dumpHttpClientRequestTracking(): string {.gcsafe.} =
  let tracker = getHttpClientRequestTracker()
  "Opened HTTP client requests: " & $tracker.opened & "\n" &
  "Closed HTTP client requests: " & $tracker.closed

proc dumpHttpClientResponseTracking(): string {.gcsafe.} =
  let tracker = getHttpClientResponseTracker()
  "Opened HTTP client responses: " & $tracker.opened & "\n" &
  "Closed HTTP client responses: " & $tracker.closed

proc leakHttpClientConnection(): bool {.gcsafe.} =
  var tracker = getHttpClientConnectionTracker()
  tracker.opened != tracker.closed

proc leakHttpClientRequest(): bool {.gcsafe.} =
  var tracker = getHttpClientRequestTracker()
  tracker.opened != tracker.closed

proc leakHttpClientResponse(): bool {.gcsafe.} =
  var tracker = getHttpClientResponseTracker()
  tracker.opened != tracker.closed

proc trackHttpClientConnection(t: HttpClientConnectionRef) {.inline.} =
  inc(getHttpClientConnectionTracker().opened)

proc untrackHttpClientConnection*(t: HttpClientConnectionRef) {.inline.}  =
  inc(getHttpClientConnectionTracker().closed)

proc trackHttpClientRequest(t: HttpClientRequestRef) {.inline.} =
  inc(getHttpClientRequestTracker().opened)

proc untrackHttpClientRequest*(t: HttpClientRequestRef) {.inline.}  =
  inc(getHttpClientRequestTracker().closed)

proc trackHttpClientResponse(t: HttpClientResponseRef) {.inline.} =
  inc(getHttpClientResponseTracker().opened)

proc untrackHttpClientResponse*(t: HttpClientResponseRef) {.inline.}  =
  inc(getHttpClientResponseTracker().closed)

proc setupHttpClientConnectionTracker(): HttpClientTracker {.gcsafe.} =
  var res = HttpClientTracker(opened: 0, closed: 0,
    dump: dumpHttpClientConnectionTracking,
    isLeaked: leakHttpClientConnection
  )
  addTracker(HttpClientConnectionTrackerName, res)
  res

proc setupHttpClientRequestTracker(): HttpClientTracker {.gcsafe.} =
  var res = HttpClientTracker(opened: 0, closed: 0,
    dump: dumpHttpClientRequestTracking,
    isLeaked: leakHttpClientRequest
  )
  addTracker(HttpClientRequestTrackerName, res)
  res

proc setupHttpClientResponseTracker(): HttpClientTracker {.gcsafe.} =
  var res = HttpClientTracker(opened: 0, closed: 0,
    dump: dumpHttpClientResponseTracking,
    isLeaked: leakHttpClientResponse
  )
  addTracker(HttpClientResponseTrackerName, res)
  res

template checkClosed(reqresp: untyped): untyped =
  if reqresp.connection.state in {HttpClientConnectionState.Closing,
                                  HttpClientConnectionState.Closed}:
    let e = newHttpUseClosedError()
    reqresp.setError(e)
    raise e

proc parseProxyKind(scheme: string): HttpResult[ProxyKind] =
  let kind =
    case scheme:
      of "http": ProxyKind.Http
      of "https", "tls", "ssl": ProxyKind.Tls
      of "socks5", "s5", "socks": ProxyKind.Socks5
      else:
        return err("Proxy scheme not understood.")
  ok(kind)

proc new(t: typedesc[ProxyRef], url: string, auth: ProxyAuthentication, timeout: Duration): ProxyRef =
  if url.len > 0:
    let uri = parseUri(url)
    new(result)
    result.address = uri.getAddress.get
    result.auth = auth
    result.kind = parseProxyKind(uri.scheme).get
    result.timeout = timeout

proc new*(t: typedesc[HttpSessionRef],
          flags: HttpClientFlags = {},
          maxRedirections = HttpMaxRedirections,
          connectTimeout = HttpConnectTimeout,
          headersTimeout = HttpHeadersTimeout,
          connectionBufferSize = DefaultStreamBufferSize,
          proxy = "",
          proxyAuth = Basic,
          proxyTimeout = ProxyTimeout,
          maxConnections = -1): HttpSessionRef {.
     raises: [Defect] .} =
  ## Create new HTTP session object.
  ##
  ## ``maxRedirections`` - maximum number of HTTP 3xx redirections
  ## ``connectTimeout`` - timeout for ongoing HTTP connection
  ## ``headersTimeout`` - timeout for receiving HTTP response headers
  doAssert(maxRedirections >= 0, "maxRedirections should not be negative")
  HttpSessionRef(
    proxy: new(ProxyRef, proxy, proxyAuth, proxyTimeout),
    flags: flags,
    maxRedirections: maxRedirections,
    connectTimeout: connectTimeout,
    headersTimeout: headersTimeout,
    connectionBufferSize: connectionBufferSize,
    maxConnections: maxConnections,
    connections: initTable[string, seq[HttpClientConnectionRef]]()
  )

proc getTLSFlags(flags: HttpClientFlags): set[TLSFlags] {.raises: [Defect] .} =
  var res: set[TLSFlags]
  if HttpClientFlag.NoVerifyHost in flags:
    res.incl(TLSFlags.NoVerifyHost)
  if HttpClientFlag.NoVerifyServerName in flags:
    res.incl(TLSFlags.NoVerifyServerName)
  res

proc getAddress*(session: HttpSessionRef, url: Uri): HttpResult[HttpAddress] {.
     raises: [Defect] .} =
  let scheme =
    if len(url.scheme) == 0:
      HttpClientScheme.NonSecure
    else:
      case toLowerAscii(url.scheme)
      of "http":
        HttpClientScheme.NonSecure
      of "https":
        HttpClientScheme.Secure
      else:
        return err("URL scheme not supported")

  let port =
    if len(url.port) == 0:
      case scheme
      of HttpClientScheme.NonSecure:
        80'u16
      of HttpClientScheme.Secure:
        443'u16
    else:
      let res = Base10.decode(uint16, url.port)
      if res.isErr():
        return err("Invalid URL port number")
      res.get()

  let hostname =
    block:
      if len(url.hostname) == 0:
        return err("URL hostname is missing")
      url.hostname

  let id = hostname & ":" & Base10.toString(port)

  let addresses =
    try:
      if (HttpClientFlag.NoInet4Resolution in session.flags) and
         (HttpClientFlag.NoInet6Resolution in session.flags):
        # DNS resolution is disabled.
        @[initTAddress(hostname, Port(port))]
      else:
        if (HttpClientFlag.NoInet4Resolution notin session.flags) and
           (HttpClientFlag.NoInet6Resolution notin session.flags):
          # DNS resolution for both IPv4 and IPv6 addresses.
          resolveTAddress(hostname, Port(port))
        else:
          if HttpClientFlag.NoInet6Resolution in session.flags:
            # DNS resolution only for IPv4 addresses.
            resolveTAddress(hostname, Port(port), AddressFamily.IPv4)
          else:
            # DNS resolution only for IPv6 addresses
            resolveTAddress(hostname, Port(port), AddressFamily.IPv6)
    except TransportAddressError:
      return err("Could not resolve address of remote server")

  if len(addresses) == 0:
    return err("Could not resolve address of remote server")

  ok(HttpAddress(id: id, scheme: scheme, hostname: hostname, port: port,
                 path: url.path, query: url.query, anchor: url.anchor,
                 username: url.username, password: url.password,
                 addresses: addresses))

proc getAddress*(session: HttpSessionRef,
                 url: string): HttpResult[HttpAddress] {.raises: [Defect].} =
  ## Create new HTTP address using URL string ``url`` and .
  session.getAddress(parseUri(url))

proc getAddress*(address: TransportAddress,
                 ctype: HttpClientScheme = HttpClientScheme.NonSecure,
                 queryString: string = "/"): HttpAddress {.raises: [Defect].} =
  ## Create new HTTP address using Transport address ``address``, connection
  ## type ``ctype`` and query string ``queryString``.
  let uri = parseUri(queryString)
  HttpAddress(id: $address, scheme: ctype, hostname: address.host,
    port: uint16(address.port), path: uri.path, query: uri.query,
    anchor: uri.anchor, username: "", password: "", addresses: @[address]
  )

proc getAddress*(uri: Uri): HttpResult[HttpAddress] {.raises: [Defect].} =
  var address: TransportAddress
  try:
    var turi = initUri()
    turi.hostname = uri.hostname
    turi.port = uri.port
    address = resolveTAddress($turi)[0]
  except TransportAddressError:
    return err("Invalid url.")
  let ctype = if uri.scheme == "https":
                HttpClientScheme.Secure
              else:
                HttpClientScheme.NonSecure
  HttpAddress(id: $address, scheme: ctype, hostname: address.host,
    port: uint16(address.port), path: uri.path, query: uri.query,
    anchor: uri.anchor, username: uri.username, password: uri.password, addresses: @[address]
  ).ok

proc hasProxy*(session: HttpSessionRef): bool {.inline.} = not session.proxy.isnil
proc hasProxy*(request: HttpClientRequestRef): bool {.inline.} = request.session.hasProxy
proc hasProxyAuth*(session: HttpSessionRef): bool {.inline.} = session.proxy.address.username != ""

proc getAddress*(request: HttpClientRequestRef): HttpAddress =
  if request.hasProxy:
    request.session.proxy.address
  else:
    request.address

proc proxyAuthHeaderData(session: HttpSessionRef): string=
  let v =
    session.proxy.address.username &
    ":" &
    session.proxy.address.password
  result.add $session.proxy.auth
  result.add " "
  result.add Base64Pad.encode(v.stringToBytes)

proc getUri*(address: HttpAddress): Uri =
  ## Retrieve URI from ``address``.
  let scheme =
    case address.scheme
    of HttpClientScheme.NonSecure:
      "http"
    of HttpClientScheme.Secure:
      "https"
  Uri(
    scheme: scheme, username: address.username, password: address.password,
    hostname: address.hostname, port: Base10.toString(address.port),
    path: address.path, query: address.query, anchor: address.anchor,
    opaque: false
  )

proc redirect*(srcuri, dsturi: Uri): Uri =
  ## Transform original's URL ``srcuri`` to ``dsturi``.
  if (len(dsturi.scheme) > 0) and (len(dsturi.hostname) > 0):
    # `dsturi` is absolute URL, replace
    dsturi
  else:
    # `dsturi` is relative URL, combine
    var tmpuri = dsturi
    tmpuri.username = ""
    tmpuri.password = ""
    combine(srcuri, tmpuri)

proc redirect*(session: HttpSessionRef,
               srcaddr: HttpAddress, uri: Uri): HttpResult[HttpAddress] =
  ## Transform original address ``srcaddr`` using redirected url ``uri`` and
  ## session ``session`` parameters.
  let srcuri = srcaddr.getUri()
  var newuri = srcuri.redirect(uri)
  if newuri.hostname != srcuri.hostname:
    session.getAddress(newuri)
  else:
    let scheme =
      case newuri.scheme
      of "http":
        HttpClientScheme.NonSecure
      of "https":
        HttpClientScheme.Secure
      else:
        return err("URL scheme not supported")

    let port =
      if len(newuri.port) == 0:
        case scheme:
        of HttpClientScheme.NonSecure:
          80'u16
        of HttpClientScheme.Secure:
          443'u16
      else:
        let res = Base10.decode(uint16, newuri.port)
        if res.isErr():
          return err("Invalid URL port number")
        res.get()

    if len(newuri.hostname) == 0:
      return err("URL hostname is missing")

    let id = newuri.hostname & ":" & Base10.toString(port)

    ok(HttpAddress(
      id: id, scheme: scheme, hostname: newuri.hostname, port: port,
      path: newuri.path, query: newuri.query, anchor: newuri.anchor,
      username: newuri.username, password: newuri.password,
      addresses: srcaddr.addresses
    ))

proc getUniqueConnectionId(session: HttpSessionRef): uint64 =
  inc(session.counter)
  session.counter

proc new(t: typedesc[HttpClientConnectionRef], session: HttpSessionRef,
         ha: HttpAddress, transp: StreamTransport, reader: AsyncStreamReader, writer:AsyncStreamWriter): HttpClientConnectionRef =
  case ha.scheme
  of HttpClientScheme.NonSecure:
    let res = HttpClientConnectionRef(
      id: session.getUniqueConnectionId(),
      kind: HttpClientScheme.NonSecure,
      transp: transp,
      reader: reader,
      writer: writer,
      state: HttpClientConnectionState.Connecting,
      remoteHostname: ha.id
    )
    trackHttpClientConnection(res)
    res
  of HttpClientScheme.Secure:
    let
      treader = reader
      twriter = writer

    let tls = newTLSClientAsyncStream(treader, twriter, ha.hostname,
                                      flags = session.flags.getTLSFlags())
    let res = HttpClientConnectionRef(
      id: session.getUniqueConnectionId(),
      kind: HttpClientScheme.Secure,
      transp: transp,
      treader: treader,
      twriter: twriter,
      reader: tls.reader,
      writer: tls.writer,
      tls: tls,
      state: HttpClientConnectionState.Connecting,
      remoteHostname: ha.id
    )
    trackHttpClientConnection(res)
    res

proc new(t: typedesc[HttpClientConnectionRef], session: HttpSessionRef,
         ha: HttpAddress, transp: StreamTransport): HttpClientConnectionRef =
  let reader = newAsyncStreamReader(transp)
  let writer = newAsyncStreamWriter(transp)
  HttpClientConnectionRef.new(session, ha, transp, reader, writer)

proc new(t: typedesc[HttpClientConnectionRef], session: HttpSessionRef,
         ha: HttpAddress, transp: StreamTransport, proxyConn: HttpClientConnectionRef): HttpClientConnectionRef =
  result = HttpClientConnectionRef.new(session, ha, transp, proxyConn.reader, proxyConn.writer)
  result.proxyConn = proxyConn

proc setError(request: HttpClientRequestRef, error: ref HttpError) {.
     raises: [Defect] .} =
  request.error = error
  request.state = HttpReqRespState.Error
  if not(isNil(request.connection)):
    request.connection.state = HttpClientConnectionState.Error
    request.connection.error = error

proc setError(response: HttpClientResponseRef, error: ref HttpError) {.
     raises: [Defect] .} =
  response.error = error
  response.state = HttpReqRespState.Error
  if not(isNil(response.connection)):
    response.connection.state = HttpClientConnectionState.Error
    response.connection.error = error

proc closeWait(conn: HttpClientConnectionRef) {.async.} =
  ## Close HttpClientConnectionRef instance ``conn`` and free all the resources.
  if conn.state notin {HttpClientConnectionState.Closing,
                       HttpClientConnectionState.Closed}:
    conn.state = HttpClientConnectionState.Closing
    let pending =
      block:
        var res: seq[Future[void]]
        if not(isNil(conn.reader)) and not(conn.reader.closed()):
          res.add(conn.reader.closeWait())
        if not(isNil(conn.writer)) and not(conn.writer.closed()):
          res.add(conn.writer.closeWait())
        res
    if len(pending) > 0: await allFutures(pending)
    case conn.kind
    of HttpClientScheme.Secure:
      await allFutures(conn.treader.closeWait(), conn.twriter.closeWait())
    of HttpClientScheme.NonSecure:
      discard
    await conn.transp.closeWait()
    conn.state = HttpClientConnectionState.Closed
    untrackHttpClientConnection(conn)

proc connectHeaders(session: HttpSessionRef, ha: HttpAddress): string =
  var res: string
  let host = ha.hostname & ":" & $ha.port
  var headers: HttpTable
  headers.add(HostHeader, host)
  headers.add(UserAgentHeader, ChronosIdent)
  if NewConnectionAlways notin session.flags:
    headers.add(ProxyConnectionHeader, "keep-alive")
  if session.hasProxyAuth:
    headers.add(ProxyAuthorizationHeader, session.proxyAuthHeaderData)
  res.add "CONNECT "
  res.add host
  res.add " "
  res.add $HttpVersion11
  res.add "\r\n"
  for (k, v) in headers.stringItems():
    res.add k
    res.add ": "
    res.add v
    res.add "\r\n"
  res.add "\r\n"
  return res

template doTlsHandshake(conn) =
  try:
    await conn.tls.handshake()
    conn.state = HttpClientConnectionState.Ready
  except CancelledError as exc:
    await conn.closeWait()
    raise exc
  except AsyncStreamError:
    await conn.closeWait()
    conn.state = HttpClientConnectionState.Error

template doProxyConnect(reader, writer) =
  block:
    await writer.write(connectHeaders(session, ha))
    var buffer: array[HttpMaxHeadersSize, byte]
    let bytesRead = await reader.readUntil(addr buffer, session.connectionBufferSize, HeadersMark)
    let resp = buffer.toOpenArray(0, bytesRead - 1).parseResponse(false)
    if resp.code != 200:
      raiseHttpConnectionError("Proxy connect failed, bad response.")

proc proxyHandshake(session: HttpSessionRef, ha: HttpAddress, transp: StreamTransport): Future[HttpClientConnectionRef] {.async.} =
  template closeTransp() =
    if not transp.closed:
      await transp.closeWait()
  return case session.proxy.kind:
    of Socks5:
      # socks5 handshake to server
      if not await transp.doSocksHandshake(
        username = session.proxy.address.username,
        password = session.proxy.address.password,
        # the "best" auth supported gets choosen by the server!
        methods = {NO_AUTHENTICATION_REQUIRED, USERNAME_PASSWORD}
        ):
        closeTransp()
        raiseHttpConnectionError("Socks5 handshake failed.")
      # connect request to end host
      if not await transp.doSocksConnect(ha.hostname, Port ha.port):
        closeTransp()
        raiseHttpConnectionError("Socks5 connection failed.")
      HttpClientConnectionRef.new(session, ha, transp)
    of Tls:
      let proxyConn = HttpClientConnectionRef.new(session, session.proxy.address, transp)
      try:
        doProxyConnect(proxyConn.tls.reader, proxyConn.tls.writer)
        # keep the proxy connection since the end connection uses its tls stream
        let id =  session.proxy.address.id & proxyConn.remoteHostname
        var default: seq[HttpClientConnectionRef]
        session.connections.mgetOrPut(id, default).add(proxyConn)
      except CatchableError:
          await proxyConn.closeWait()
          raiseHttpConnectionError("Proxy https handshake failed.")
      # make a new connection wrapping the proxy tls stream
      HttpClientConnectionRef.new(session, ha, transp, proxyConn.reader, proxyConn.writer)
    of Http:
      # Http -> Https: uses CONNECT and then tls handshake to end host.
      if ha.scheme == Secure:
        let
          writer = newAsyncStreamWriter(transp)
          reader = newAsyncStreamReader(transp)
        try:
          doProxyConnect(reader, writer)
          await allFutures(reader.closeWait(), writer.closeWait())
          # FIXME: tested on
          # https://ipinfo.io/ip OK
          # https://httpbin.org/get OK
          # https://api.ipify.org FAIL: tls handshake stalls
          HttpClientConnectionRef.new(session, ha, transp)
        except CatchableError:
          var pending: seq[Future[void]]
          if not reader.closed:
            pending.add(reader.closeWait)
          if not writer.closed:
            pending.add(writer.closeWait)
          await allFutures(pending)
          raiseHttpConnectionError("Proxy http handshake failed.")
      # Http -> Http: is a normal http request with full url in the headers after the http method.
      else: HttpClientConnectionRef.new(session, ha, transp)
    else: HttpClientConnectionRef.new(session, ha, transp)


proc doConnect(session: HttpSessionRef, ha: HttpAddress, address: TransportAddress): Future[HttpClientConnectionRef] {.async.} =
  let transp =
    try:
      await connect(address, bufferSize = session.connectionBufferSize)
    except CancelledError as exc:
      raise exc
    except CatchableError:
      nil
  if not(isNil(transp)):
    let res =
      if session.hasProxy:
        await proxyHandshake(session, ha, transp).wait(session.proxy.timeout)
      else:
        HttpClientConnectionRef.new(session, ha, transp)
    let conn =
      block:
        case res.kind
        of HttpClientScheme.Secure:
          doTlsHandshake(res)
        of HttpClientScheme.Nonsecure:
          res.state = HttpClientConnectionState.Ready
        res
    if conn.state == HttpClientConnectionState.Ready:
      return conn

proc connect(session: HttpSessionRef,
             ha: HttpAddress): Future[HttpClientConnectionRef] {.async.} =
  ## Establish new connection with remote server using ``url`` and ``flags``.
  ## On success returns ``HttpClientConnectionRef`` object.

  let proxiedHa =
    if session.hasProxy:
      session.proxy.address
    else:
      ha
  # Here we trying to connect to every possible remote host address we got after
  # DNS resolution.
  for address in proxiedHa.addresses:
    let conn = await session.doConnect(ha, address)
    if not conn.isnil:
      return conn

  # If all attempts to connect to the remote host have failed.
  raiseHttpConnectionError("Could not connect to remote host")

proc acquireConnection(session: HttpSessionRef,
                       ha: HttpAddress): Future[HttpClientConnectionRef] {.
     async.} =
  ## Obtain connection from ``session`` or establish a new one.
  if HttpClientFlag.NewConnectionAlways in session.flags:
    var default: seq[HttpClientConnectionRef]
    let res =
      try:
        await session.connect(ha).wait(session.connectTimeout)
      except AsyncTimeoutError:
        raiseHttpConnectionError("Connection timed out")
    res[].state = HttpClientConnectionState.Acquired
    session.connections.mgetOrPut(ha.id, default).add(res)
    return res
  else:
    let conn =
      block:
        let conns = session.connections.getOrDefault(ha.id)
        if len(conns) > 0:
          var res: HttpClientConnectionRef = nil
          for item in conns:
            if item.state == HttpClientConnectionState.Ready:
              res = item
              break
          res
        else:
          nil
    if not(isNil(conn)):
      conn[].state = HttpClientConnectionState.Acquired
      return conn
    else:
      var default: seq[HttpClientConnectionRef]
      let res =
        try:
          await session.connect(ha).wait(session.connectTimeout)
        except AsyncTimeoutError:
          raiseHttpConnectionError("Connection timed out")
      res[].state = HttpClientConnectionState.Acquired
      session.connections.mgetOrPut(ha.id, default).add(res)
      return res

proc removeConnection(session: HttpSessionRef,
                      conn: HttpClientConnectionRef) {.async.} =
  session.connections.withValue(conn.remoteHostname, connections):
    connections[].keepItIf(it != conn)
  var pending: seq[Future[void]]
  pending.add conn.closeWait()
  if not conn.proxyConn.isnil:
    pending.add conn.proxyConn.closeWait()
  await allFutures(pending)


proc releaseConnection(session: HttpSessionRef,
                       connection: HttpClientConnectionRef) {.async.} =
  ## Return connection back to the ``session``.
  let removeConnection =
    case connection.state
    of HttpClientConnectionState.ResponseBodyReceived:
      if HttpClientConnectionFlag.KeepAlive in connection.flags:
        # HTTP response body has been received and "Connection: keep-alive" is
        # present in response headers.
        false
      else:
        # HTTP response body has been received, but "Connection: keep-alive" is
        # not present or not supported.
        true
    of HttpClientConnectionState.ResponseHeadersReceived:
      if (HttpClientConnectionFlag.NoBody in connection.flags) and
         (HttpClientConnectionFlag.KeepAlive in connection.flags):
        # HTTP response headers received with an empty response body and
        # "Connection: keep-alive" is present in response headers.
        false
      else:
        # HTTP response body is not received or "Connection: keep-alive" is not
        # present or not supported.
        true
    else:
      # Connection not in proper state.
      true

  if removeConnection:
    await session.removeConnection(connection)
  else:
    connection.state = HttpClientConnectionState.Ready
    connection.flags = {}

proc releaseConnection(request: HttpClientRequestRef) {.async.} =
  let
    session = request.session
    connection = request.connection

  if not(isNil(connection)):
    request.connection = nil
    request.session = nil
    connection.flags.excl(HttpClientConnectionFlag.Request)
    if HttpClientConnectionFlag.Response notin connection.flags:
      await session.releaseConnection(connection)

proc releaseConnection(response: HttpClientResponseRef) {.async.} =
  let
    session = response.session
    connection = response.connection

  if not(isNil(connection)):
    response.connection = nil
    response.session = nil
    connection.flags.excl(HttpClientConnectionFlag.Response)
    if HttpClientConnectionFlag.Request notin connection.flags:
      await session.releaseConnection(connection)

proc closeWait*(session: HttpSessionRef) {.async.} =
  ## Closes HTTP session object.
  ##
  ## This closes all the connections opened to remote servers.
  var pending: seq[Future[void]]
  for items in session.connections.values():
    for item in items:
      pending.add(closeWait(item))
  await allFutures(pending)

proc closeWait*(request: HttpClientRequestRef) {.async.} =
  if request.state notin {HttpReqRespState.Closing, HttpReqRespState.Closed}:
    request.state = HttpReqRespState.Closing
    if not(isNil(request.writer)):
      if not(request.writer.closed()):
        await request.writer.closeWait()
      request.writer = nil
    await request.releaseConnection()
    request.session = nil
    request.error = nil
    request.state = HttpReqRespState.Closed
    untrackHttpClientRequest(request)

proc closeWait*(response: HttpClientResponseRef) {.async.} =
  if response.state notin {HttpReqRespState.Closing, HttpReqRespState.Closed}:
    response.state = HttpReqRespState.Closing
    if not(isNil(response.reader)):
      if not(response.reader.closed()):
        await response.reader.closeWait()
      response.reader = nil
    await response.releaseConnection()
    response.session = nil
    response.error = nil
    response.state = HttpReqRespState.Closed
    untrackHttpClientResponse(response)

proc prepareResponse(request: HttpClientRequestRef, data: openArray[byte]
                    ): HttpResult[HttpClientResponseRef] {.raises: [Defect] .} =
  ## Process response headers.
  let resp = parseResponse(data, false)
  if resp.failed():
    return err("Invalid headers received")

  let headers =
    block:
      var res = HttpTable.init()
      for key, value in resp.headers(data):
        res.add(key, value)
      if res.count(ContentTypeHeader) > 1:
        return err("Invalid headers received, too many `Content-Type`")
      if res.count(ContentLengthHeader) > 1:
        return err("Invalid headers received, too many `Content-Length`")
      if res.count(TransferEncodingHeader) > 1:
        return err("Invalid headers received, too many `Transfer-Encoding`")
      res

  # Preprocessing "Content-Encoding" header.
  let contentEncoding =
    block:
      let res = getContentEncoding(headers.getList(ContentEncodingHeader))
      if res.isErr():
        return err("Invalid headers received, invalid `Content-Encoding`")
      else:
        res.get()

  # Preprocessing "Transfer-Encoding" header.
  let transferEncoding =
    block:
      let res = getTransferEncoding(headers.getList(TransferEncodingHeader))
      if res.isErr():
        return err("Invalid headers received, invalid `Transfer-Encoding`")
      else:
        res.get()

  # Preprocessing "Content-Length" header.
  let (contentLength, bodyFlag, nobodyFlag) =
    if ContentLengthHeader in headers:
      let length = headers.getInt(ContentLengthHeader)
      (length, HttpClientBodyFlag.Sized, length == 0)
    else:
      if TransferEncodingFlags.Chunked in transferEncoding:
        (0'u64, HttpClientBodyFlag.Chunked, false)
      else:
        (0'u64, HttpClientBodyFlag.Custom, false)

  # Preprocessing "Connection" header.
  let connectionFlag =
    block:
      case resp.version
      of HttpVersion11, HttpVersion20:
        let header = toLowerAscii(headers.getString(ConnectionHeader))
        if header == "keep-alive":
          true
        else:
          false
      else:
        false

  let contentType =
    block:
      let list = headers.getList(ContentTypeHeader)
      if len(list) > 0:
        let res = getContentType(list)
        if res.isErr():
          return err("Invalid headers received, invalid `Content-Type`")
        else:
          Opt.some(res.get())
      else:
        Opt.none(ContentTypeData)

  let res = HttpClientResponseRef(
    state: HttpReqRespState.Open, status: resp.code,
    address: request.address, requestMethod: request.meth,
    reason: resp.reason(data), version: resp.version, session: request.session,
    connection: request.connection, headers: headers,
    contentEncoding: contentEncoding, transferEncoding: transferEncoding,
    contentLength: contentLength, contentType: contentType, bodyFlag: bodyFlag
  )
  res.connection.state = HttpClientConnectionState.ResponseHeadersReceived
  if nobodyFlag:
    res.connection.flags.incl(HttpClientConnectionFlag.NoBody)
  if connectionFlag:
    res.connection.flags.incl(HttpClientConnectionFlag.KeepAlive)
  res.connection.flags.incl(HttpClientConnectionFlag.Response)
  trackHttpClientResponse(res)
  ok(res)

proc getResponse(req: HttpClientRequestRef): Future[HttpClientResponseRef] {.
     async.} =
  var buffer: array[HttpMaxHeadersSize, byte]
  let bytesRead =
    try:
      await req.connection.reader.readUntil(addr buffer[0],
                                            len(buffer), HeadersMark).wait(
                                            req.session.headersTimeout)
    except CancelledError as exc:
      raise exc
    except AsyncTimeoutError:
      raiseHttpReadError("Reading response headers timed out")
    except AsyncStreamError:
      raiseHttpReadError("Could not read response headers")

  let response = prepareResponse(req, buffer.toOpenArray(0, bytesRead - 1))
  if response.isErr():
    raiseHttpProtocolError(response.error())
  return response.get()

proc new*(t: typedesc[HttpClientRequestRef], session: HttpSessionRef,
          ha: HttpAddress, meth: HttpMethod = MethodGet,
          version: HttpVersion = HttpVersion11,
          flags: set[HttpClientRequestFlag] = {},
          headers: openArray[HttpHeaderTuple] = [],
          body: openArray[byte] = []): HttpClientRequestRef {.
     raises: [Defect].} =
  let res = HttpClientRequestRef(
    state: HttpReqRespState.Ready, session: session, meth: meth,
    version: version, flags: flags, headers: HttpTable.init(headers),
    address: ha, bodyFlag: HttpClientBodyFlag.Custom, buffer: @body
  )
  trackHttpClientRequest(res)
  res

proc new*(t: typedesc[HttpClientRequestRef], session: HttpSessionRef,
          url: string, meth: HttpMethod = MethodGet,
          version: HttpVersion = HttpVersion11,
          flags: set[HttpClientRequestFlag] = {},
          headers: openArray[HttpHeaderTuple] = [],
          body: openArray[byte] = []): HttpResult[HttpClientRequestRef] {.
     raises: [Defect].} =
  let address = ? session.getAddress(parseUri(url))
  let res = HttpClientRequestRef(
    state: HttpReqRespState.Ready, session: session, meth: meth,
    version: version, flags: flags, headers: HttpTable.init(headers),
    address: address, bodyFlag: HttpClientBodyFlag.Custom, buffer: @body
  )
  trackHttpClientRequest(res)
  ok(res)

proc get*(t: typedesc[HttpClientRequestRef], session: HttpSessionRef,
          url: string, version: HttpVersion = HttpVersion11,
          flags: set[HttpClientRequestFlag] = {},
          headers: openArray[HttpHeaderTuple] = []
         ): HttpResult[HttpClientRequestRef] {.raises: [Defect].} =
  HttpClientRequestRef.new(session, url, MethodGet, version, flags, headers)

proc get*(t: typedesc[HttpClientRequestRef], session: HttpSessionRef,
          ha: HttpAddress, version: HttpVersion = HttpVersion11,
          flags: set[HttpClientRequestFlag] = {},
          headers: openArray[HttpHeaderTuple] = []
         ): HttpClientRequestRef {.raises: [Defect].} =
  HttpClientRequestRef.new(session, ha, MethodGet, version, flags, headers)

proc post*(t: typedesc[HttpClientRequestRef], session: HttpSessionRef,
           url: string, version: HttpVersion = HttpVersion11,
           flags: set[HttpClientRequestFlag] = {},
           headers: openArray[HttpHeaderTuple] = [],
           body: openArray[byte] = []
          ): HttpResult[HttpClientRequestRef] {.raises: [Defect].} =
  HttpClientRequestRef.new(session, url, MethodPost, version, flags, headers,
                           body)

proc post*(t: typedesc[HttpClientRequestRef], session: HttpSessionRef,
           url: string, version: HttpVersion = HttpVersion11,
           flags: set[HttpClientRequestFlag] = {},
           headers: openArray[HttpHeaderTuple] = [],
           body: openArray[char] = []): HttpResult[HttpClientRequestRef] {.
     raises: [Defect].} =
  HttpClientRequestRef.new(session, url, MethodPost, version, flags, headers,
                           body.toOpenArrayByte(0, len(body) - 1))

proc post*(t: typedesc[HttpClientRequestRef], session: HttpSessionRef,
           ha: HttpAddress, version: HttpVersion = HttpVersion11,
           flags: set[HttpClientRequestFlag] = {},
           headers: openArray[HttpHeaderTuple] = [],
           body: openArray[byte] = []): HttpClientRequestRef {.
     raises: [Defect].} =
  HttpClientRequestRef.new(session, ha, MethodPost, version, flags, headers,
                           body)

proc post*(t: typedesc[HttpClientRequestRef], session: HttpSessionRef,
           ha: HttpAddress, version: HttpVersion = HttpVersion11,
           flags: set[HttpClientRequestFlag] = {},
           headers: openArray[HttpHeaderTuple] = [],
           body: openArray[char] = []): HttpClientRequestRef {.
     raises: [Defect].} =
  HttpClientRequestRef.new(session, ha, MethodPost, version, flags, headers,
                           body.toOpenArrayByte(0, len(body) - 1))

proc prepareRequest(request: HttpClientRequestRef): string {.
     raises: [Defect].} =
  template hasChunkedEncoding(request: HttpClientRequestRef): bool =
    toLowerAscii(request.headers.getString(TransferEncodingHeader)) == "chunked"

  # We use ChronosIdent as `User-Agent` string if its not set.
  discard request.headers.hasKeyOrPut(UserAgentHeader, ChronosIdent)
  # We use request's hostname as `Host` string if its not set.
  discard request.headers.hasKeyOrPut(HostHeader, request.address.hostname)
  # We set `Connection` to value according to flags if its not set.
  if ConnectionHeader notin request.headers:
    if HttpClientRequestFlag.CloseConnection in request.flags:
      request.headers.add(ConnectionHeader, "close")
    else:
      request.headers.add(ConnectionHeader, "keep-alive")
  # We set `Accept` to accept any content if its not set.
  discard request.headers.hasKeyOrPut(AcceptHeaderName, "*/*")

  # We will send `Authorization` information only if username or password set,
  # and `Authorization` header is not present in request's headers.
  if len(request.address.username) > 0 or len(request.address.password) > 0:
    if AuthorizationHeader notin request.headers:
      let auth = request.address.username & ":" & request.address.password
      let header = "Basic " &
                   Base64Pad.encode(auth.toOpenArrayByte(0, len(auth) - 1))
      request.headers.add(AuthorizationHeader, header)

  # Here we perform automatic detection: if request was created with non-zero
  # body and `Content-Length` header is missing we will create one with size
  # of body stored in request.
  if ContentLengthHeader notin request.headers:
    if len(request.buffer) > 0:
      let slength = Base10.toString(uint64(len(request.buffer)))
      request.headers.add(ContentLengthHeader, slength)

  request.bodyFlag =
    if ContentLengthHeader in request.headers:
      HttpClientBodyFlag.Sized
    else:
      if request.hasChunkedEncoding():
        HttpClientBodyFlag.Chunked
      else:
        HttpClientBodyFlag.Custom

  let entity =
    block:
      var res: string
      if request.hasProxy and request.session.proxy.kind == Http:
        if request.session.hasProxyAuth and ProxyAuthorizationHeader notin request.headers:
          request.headers.add(ProxyAuthorizationHeader, request.session.proxyAuthHeaderData)
        res.add "http://"
        res.add request.address.hostname
        res.add ":"
        res.add $request.address.port
      if len(request.address.path) > 0:
        res.add request.address.path
      else:
        res.add "/"
      if len(request.address.query) > 0:
        res.add("?")
        res.add(request.address.query)
      if len(request.address.anchor) > 0:
        res.add("#")
        res.add(request.address.anchor)
      res

  var res = $request.meth
  res.add(" ")
  res.add(entity)
  res.add(" ")
  res.add($request.version)
  res.add("\r\n")
  for k, v in request.headers.stringItems():
    if len(v) > 0:
      res.add(normalizeHeaderName(k))
      res.add(": ")
      res.add(v)
      res.add("\r\n")
  res.add("\r\n")
  res

proc send*(request: HttpClientRequestRef): Future[HttpClientResponseRef] {.
     async.} =
  doAssert(request.state == HttpReqRespState.Ready,
           "Request's state is " & $request.state)
  let connection =
    try:
      await request.session.acquireConnection(request.address)
    except CancelledError as exc:
      request.setError(newHttpInterruptError())
      raise exc
    except HttpError as exc:
      request.setError(exc)
      raise exc

  connection.flags.incl(HttpClientConnectionFlag.Request)
  request.connection = connection

  try:
    let headers = request.prepareRequest()
    request.connection.state = HttpClientConnectionState.RequestHeadersSending
    request.state = HttpReqRespState.Open
    await request.connection.writer.write(headers)
    request.connection.state = HttpClientConnectionState.RequestHeadersSent
    request.connection.state = HttpClientConnectionState.RequestBodySending
    if len(request.buffer) > 0:
      await request.connection.writer.write(request.buffer)
    request.connection.state = HttpClientConnectionState.RequestBodySent
    request.state = HttpReqRespState.Finished
  except CancelledError as exc:
    request.setError(newHttpInterruptError())
    raise exc
  except AsyncStreamError as exc:
    let error = newHttpWriteError("Could not send request headers")
    request.setError(error)
    raise error

  let resp =
    try:
      await request.getResponse()
    except CancelledError as exc:
      request.setError(newHttpInterruptError())
      raise exc
    except HttpError as exc:
      request.setError(exc)
      raise exc
  return resp

proc open*(request: HttpClientRequestRef): Future[HttpBodyWriter] {.
     async.} =
  ## Start sending request's headers and return `HttpBodyWriter`, which can be
  ## used to send request's body.
  doAssert(request.state == HttpReqRespState.Ready,
           "Request's state is " & $request.state)
  doAssert(len(request.buffer) == 0,
           "Request should not have static body content (len(buffer) == 0)")
  let connection =
    try:
      await request.session.acquireConnection(request.address)
    except CancelledError as exc:
      request.setError(newHttpInterruptError())
      raise exc
    except HttpError as exc:
      request.setError(exc)
      raise exc

  connection.flags.incl(HttpClientConnectionFlag.Request)
  request.connection = connection

  try:
    let headers = request.prepareRequest()
    request.connection.state = HttpClientConnectionState.RequestHeadersSending
    await request.connection.writer.write(headers)
    request.connection.state = HttpClientConnectionState.RequestHeadersSent
  except CancelledError as exc:
    request.setError(newHttpInterruptError())
    raise exc
  except AsyncStreamError as exc:
    let error = newHttpWriteError("Could not send request headers")
    request.setError(error)
    raise error

  let writer =
    case request.bodyFlag
    of HttpClientBodyFlag.Sized:
      let size = Base10.decode(uint64,
                               request.headers.getString("content-length"))
      let writer = newBoundedStreamWriter(request.connection.writer, size.get())
      newHttpBodyWriter([AsyncStreamWriter(writer)])
    of HttpClientBodyFlag.Chunked:
      let writer = newChunkedStreamWriter(request.connection.writer)
      newHttpBodyWriter([AsyncStreamWriter(writer)])
    of HttpClientBodyFlag.Custom:
      let writer = newAsyncStreamWriter(request.connection.writer)
      newHttpBodyWriter([writer])

  request.writer = writer
  request.state = HttpReqRespState.Open
  request.connection.state = HttpClientConnectionState.RequestBodySending
  return writer

proc finish*(request: HttpClientRequestRef): Future[HttpClientResponseRef] {.
     async.} =
  ## Finish sending request and receive response.
  doAssert(not(isNil(request.connection)),
           "Request missing connection instance")
  request.checkClosed()
  doAssert(request.state == HttpReqRespState.Open,
           "Request's state is " & $request.state)
  doAssert(request.connection.state ==
           HttpClientConnectionState.RequestBodySending,
           "Connection's state is " & $request.connection.state)
  doAssert(request.writer.closed(),
           "Body writer instance must be closed before finish(request) call")
  request.state = HttpReqRespState.Finished
  request.connection.state = HttpClientConnectionState.RequestBodySent
  let response =
    try:
      await request.getResponse()
    except CancelledError as exc:
      request.setError(newHttpInterruptError())
      raise exc
    except HttpError as exc:
      request.setError(exc)
      raise exc
  return response

proc getNewLocation*(resp: HttpClientResponseRef): HttpResult[HttpAddress] =
  ## Returns new address according to response's `Location` header value.
  if "location" in resp.headers:
    let location = resp.headers.getString("location")
    if len(location) > 0:
      resp.session.redirect(resp.address, parseUri(location))
    else:
      err("Location header with empty value")
  else:
    err("Location header is missing")

proc getBodyReader*(response: HttpClientResponseRef): HttpBodyReader =
  ## Returns stream's reader instance which can be used to read response's body.
  ##
  ## Streams which was obtained using this procedure must be closed to avoid
  ## leaks.
  doAssert(not(isNil(response.connection)),
           "Response missing connection instance")
  response.checkClosed()
  doAssert(response.state == HttpReqRespState.Open,
           "Response's state is " & $response.state)
  doAssert(response.connection.state in
           {HttpClientConnectionState.ResponseHeadersReceived,
            HttpClientConnectionState.ResponseBodyReceiving},
           "Connection state is " & $response.connection.state)
  if isNil(response.reader):
    let reader =
      case response.bodyFlag
      of HttpClientBodyFlag.Sized:
        let bstream = newBoundedStreamReader(response.connection.reader,
                                             response.contentLength)
        newHttpBodyReader(bstream)
      of HttpClientBodyFlag.Chunked:
        newHttpBodyReader(newChunkedStreamReader(response.connection.reader))
      of HttpClientBodyFlag.Custom:
        newHttpBodyReader(newAsyncStreamReader(response.connection.reader))
    response.connection.state = HttpClientConnectionState.ResponseBodyReceiving
    response.reader = reader
  response.reader

proc finish*(response: HttpClientResponseRef) {.async.} =
  ## Finish receiving response.
  ##
  ## Because ``finish()`` returns nothing, this operation become NOP for
  ## response which is not in ``Open`` state.
  if response.state == HttpReqRespState.Open:
    doAssert(not(isNil(response.connection)),
             "Response missing connection instance")
    response.checkClosed()
    doAssert(response.connection.state ==
             HttpClientConnectionState.ResponseBodyReceiving,
             "Connection state is " & $response.connection.state)
    doAssert(response.reader.closed(),
             "Body reader instance must be closed before finish(response) call")
    response.connection.state = HttpClientConnectionState.ResponseBodyReceived
    response.state = HttpReqRespState.Finished

proc getBodyBytes*(response: HttpClientResponseRef): Future[seq[byte]] {.
     async.} =
  ## Read all bytes from response ``response``.
  ##
  ## Note: This procedure performs automatic finishing for ``response``.
  var reader = response.getBodyReader()
  try:
    let data = await reader.read()
    await reader.closeWait()
    reader = nil
    await response.finish()
    return data
  except CancelledError as exc:
    if not(isNil(reader)):
      await reader.closeWait()
    response.setError(newHttpInterruptError())
    raise exc
  except AsyncStreamError as exc:
    if not(isNil(reader)):
      await reader.closeWait()
    let error = newHttpReadError("Could not read response")
    response.setError(error)
    raise error

proc getBodyBytes*(response: HttpClientResponseRef,
                   nbytes: int): Future[seq[byte]] {.async.} =
  ## Read all bytes (nbytes <= 0) or exactly `nbytes` bytes from response
  ## ``response``.
  ##
  ## Note: This procedure performs automatic finishing for ``response``.
  var reader = response.getBodyReader()
  try:
    let data = await reader.read(nbytes)
    await reader.closeWait()
    reader = nil
    await response.finish()
    return data
  except CancelledError as exc:
    if not(isNil(reader)):
      await reader.closeWait()
    response.setError(newHttpInterruptError())
    raise exc
  except AsyncStreamError as exc:
    if not(isNil(reader)):
      await reader.closeWait()
    let error = newHttpReadError("Could not read response")
    response.setError(error)
    raise error

proc consumeBody*(response: HttpClientResponseRef): Future[int] {.async.} =
  ## Consume/discard response and return number of bytes consumed.
  ##
  ## Note: This procedure performs automatic finishing for ``response``.
  var reader = response.getBodyReader()
  try:
    let res = await reader.consume()
    await reader.closeWait()
    reader = nil
    await response.finish()
    return res
  except CancelledError as exc:
    if not(isNil(reader)):
      await reader.closeWait()
    response.setError(newHttpInterruptError())
    raise exc
  except AsyncStreamError as exc:
    if not(isNil(reader)):
      await reader.closeWait()
    let error = newHttpReadError("Could not read response")
    response.setError(error)
    raise error

proc redirect*(request: HttpClientRequestRef,
               ha: HttpAddress): HttpResult[HttpClientRequestRef] =
  ## Create new request object using original request object ``request`` and
  ## new redirected address ``ha``.
  ##
  ## This procedure could return an error if number of redirects exceeded
  ## maximum allowed number of redirects in request's session.
  let redirectCount = request.redirectCount + 1
  if redirectCount > request.session.maxRedirections:
    err("Maximum number of redirects exceeded")
  else:
    if HostHeader in request.headers and ha.hostname != request.address.hostname:
      request.headers.set HostHeader, ha.hostname
    var res = HttpClientRequestRef.new(request.session, ha, request.meth,
      request.version, request.flags, request.headers.toList(), request.buffer)
    res.redirectCount = redirectCount
    ok(res)

proc redirect*(request: HttpClientRequestRef,
               uri: Uri): HttpResult[HttpClientRequestRef] =
  ## Create new request object using original request object ``request`` and
  ## redirected URL ``uri``.
  ##
  ## This procedure could return an error if number of redirects exceeded
  ## maximum allowed number of redirects in request's session or ``uri`` is
  ## incorrect or not supported.
  let redirectCount = request.redirectCount + 1
  if redirectCount > request.session.maxRedirections:
    err("Maximum number of redirects exceeded")
  else:
    let address = ? request.session.redirect(request.address, uri)
    if HostHeader in request.headers and address.hostname != request.address.hostname:
      request.headers.set HostHeader, uri.hostname
    var res = HttpClientRequestRef.new(request.session, address, request.meth,
      request.version, request.flags, request.headers.toList(), request.buffer)
    res.redirectCount = redirectCount
    ok(res)

proc fetchOnce*(request: HttpClientRequestRef): Future[HttpResponseTuple] {.
     async.} =
  var response: HttpClientResponseRef
  try:
    response = await request.send()
    let buffer = await response.getBodyBytes()
    let status = response.status
    await response.closeWait()
    response = nil
    return (status, buffer, @[])
  except HttpError as exc:
    if not(isNil(response)): await response.closeWait()
    raise exc
  except CancelledError as exc:
    if not(isNil(response)): await response.closeWait()
    raise exc

proc fetch*(request: HttpClientRequestRef, followRedirects=false): Future[HttpResponseTuple] {.
     async.} =
  ## Fetch ``request``.
  ##
  ## This procedure supports HTTP redirections.

  if not followRedirects:
    return await fetchOnce(request)

  var
    request = request
    response: HttpClientResponseRef = nil
    redirect: HttpClientRequestRef = nil
    redirectUrls: seq[string]

  while true:
    try:
      response = await request.send()
      if response.status >= 300 and response.status < 400:
        redirect =
          block:
            if "location" in response.headers:
              let location = response.headers.getString("location")
              if len(location) > 0:
                let res = request.redirect(parseUri(location))
                if res.isErr():
                  raiseHttpRedirectError(res.error())
                redirectUrls.add location
                res.get()
              else:
                raiseHttpRedirectError("Location header with an empty value")
            else:
              raiseHttpRedirectError("Location header missing")
        discard await response.consumeBody()
        await response.closeWait()
        response = nil
        await request.closeWait()
        request = nil
        request = redirect
        redirect = nil
      else:
        let data = await response.getBodyBytes()
        let code = response.status
        await response.closeWait()
        response = nil
        await request.closeWait()
        request = nil
        return (code, data, redirectUrls)
    except CancelledError as exc:
      if not(isNil(response)): await closeWait(response)
      if not(isNil(request)): await closeWait(request)
      if not(isNil(redirect)): await closeWait(redirect)
      raise exc
    except HttpError as exc:
      if not(isNil(response)): await closeWait(response)
      if not(isNil(request)): await closeWait(request)
      if not(isNil(redirect)): await closeWait(redirect)
      raise exc

proc fetch*(session: HttpSessionRef, url: Uri): Future[HttpResponseTuple] {.async.} =
  ## Fetch resource pointed by ``url`` using HTTP GET method and ``session``
  ## parameters.
  ##
  ## This procedure supports HTTP redirections.

  let address =
    block:
      let res = session.getAddress(url)
      if res.isErr():
        raiseHttpAddressError(res.error())
      res.get()
  return await fetch(HttpClientRequestRef.new(session, address))

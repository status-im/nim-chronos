#
#                Chronos HTTP/S client
#             (c) Copyright 2021-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

{.push raises: [].}

import std/[uri, tables, sequtils]
import stew/[base10, base64, byteutils], httputils, results
import ../../asyncloop, ../../asyncsync
import ../../streams/[asyncstream, tlsstream, chunkstream, boundstream]
import httptable, httpcommon, httpagent, httpbodyrw, multipart
export results, asyncloop, asyncsync, asyncstream, tlsstream, chunkstream,
       boundstream, httptable, httpcommon, httpagent, httpbodyrw, multipart,
       httputils, uri, results
export SocketFlags

const
  HttpMaxHeadersSize* = 8192
    ## Maximum size of HTTP headers in octets
  HttpConnectTimeout* = 12.seconds
    ## Timeout for connecting to host (12 sec)
  HttpHeadersTimeout* = 120.seconds
    ## Timeout for receiving response headers (120 sec)
  HttpConnectionIdleTimeout* = 60.seconds
    ## Time after which idle connections are removed from the HttpSession's
    ## connections pool (120 sec)
  HttpConnectionCheckPeriod* = 10.seconds
    ## Period of time between idle connections checks in HttpSession's
    ## connection pool (10 sec)
  HttpMaxRedirections* = 10
    ## Maximum number of Location redirections.
  HttpClientConnectionTrackerName* = "httpclient.connection"
    ## HttpClient connection leaks tracker name
  HttpClientRequestTrackerName* = "httpclient.request"
    ## HttpClient request leaks tracker name
  HttpClientResponseTrackerName* = "httpclient.response"
    ## HttpClient response leaks tracker name

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
    DedicatedConnection,      ## Create new HTTP connection for request
    CloseConnection           ## Send `Connection: close` in request

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
    timestamp*: Moment
    duration*: Duration

  HttpClientConnectionRef* = ref HttpClientConnection

  HttpSessionRef* = ref object
    connections*: Table[string, seq[HttpClientConnectionRef]]
    counter*: uint64
    maxRedirections*: int
    connectTimeout*: Duration
    headersTimeout*: Duration
    idleTimeout: Duration
    idlePeriod: Duration
    watcherFut: Future[void].Raising([])
    connectionBufferSize*: int
    maxConnections*: int
    connectionsCount*: int
    socketFlags*: set[SocketFlags]
    flags*: HttpClientFlags
    dualstack*: DualStackType

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
    timestamp*: Moment
    duration*: Duration
    headersBuffer: seq[byte]

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
    timestamp*: Moment
    duration*: Duration

  HttpClientResponseRef* = ref HttpClientResponse

  HttpClientFlag* {.pure.} = enum
    NoVerifyHost,        ## Skip remote server certificate verification
    NoVerifyServerName,  ## Skip remote server name CN verification
    NoInet4Resolution,   ## Do not resolve server hostname to IPv4 addresses
    NoInet6Resolution,   ## Do not resolve server hostname to IPv6 addresses
    NoAutomaticRedirect, ## Do not handle HTTP redirection automatically
    NewConnectionAlways, ## Always create new connection to HTTP server
    Http11Pipeline       ## Enable HTTP/1.1 pipelining

  HttpClientFlags* = set[HttpClientFlag]

  ServerSentEvent* = object
    name*: string
    data*: string

  HttpAddressResult* = Result[HttpAddress, HttpAddressErrorType]

# HttpClientRequestRef valid states are:
# Ready -> Open -> (Finished, Error) -> (Closing, Closed)
#
# HttpClientResponseRef valid states are
# Open -> (Finished, Error) -> (Closing, Closed)

template checkClosed(reqresp: untyped): untyped =
  if reqresp.connection.state in {HttpClientConnectionState.Closing,
                                  HttpClientConnectionState.Closed}:
    let e = newHttpUseClosedError()
    reqresp.setError(e)
    raise e

template setTimestamp(conn: HttpClientConnectionRef,
                      moment: Moment): untyped =
  if not(isNil(conn)):
    conn.timestamp = moment

template setTimestamp(
           reqresp: HttpClientRequestRef|HttpClientRequestRef
         ): untyped =
  if not(isNil(reqresp)):
    let timestamp = Moment.now()
    reqresp.timestamp = timestamp
    reqresp.connection.setTimestamp(timestamp)

template setTimestamp(resp: HttpClientResponseRef, moment: Moment): untyped =
  if not(isNil(resp)):
    resp.timestamp = moment
    resp.connection.setTimestamp(moment)

template setDuration(
           reqresp: HttpClientRequestRef|HttpClientResponseRef
         ): untyped =
  if not(isNil(reqresp)):
    let timestamp = Moment.now()
    reqresp.duration = timestamp - reqresp.timestamp
    reqresp.connection.setTimestamp(timestamp)

template setDuration(conn: HttpClientConnectionRef): untyped =
  if not(isNil(conn)):
    let timestamp = Moment.now()
    conn.duration = timestamp - conn.timestamp
    conn.setTimestamp(timestamp)

template isReady(conn: HttpClientConnectionRef): bool =
  (conn.state == HttpClientConnectionState.Ready) and
  (HttpClientConnectionFlag.KeepAlive in conn.flags) and
  (HttpClientConnectionFlag.Request notin conn.flags) and
  (HttpClientConnectionFlag.Response notin conn.flags)

template isIdle(conn: HttpClientConnectionRef, timestamp: Moment,
                timeout: Duration): bool =
  (timestamp - conn.timestamp) >= timeout

proc sessionWatcher(session: HttpSessionRef) {.async: (raises: []).}

proc new*(t: typedesc[HttpSessionRef],
          flags: HttpClientFlags = {},
          maxRedirections = HttpMaxRedirections,
          connectTimeout = HttpConnectTimeout,
          headersTimeout = HttpHeadersTimeout,
          connectionBufferSize = DefaultStreamBufferSize,
          maxConnections = -1,
          idleTimeout = HttpConnectionIdleTimeout,
          idlePeriod = HttpConnectionCheckPeriod,
          socketFlags: set[SocketFlags] = {},
          dualstack = DualStackType.Auto): HttpSessionRef =
  ## Create new HTTP session object.
  ##
  ## ``maxRedirections`` - maximum number of HTTP 3xx redirections
  ## ``connectTimeout`` - timeout for ongoing HTTP connection
  ## ``headersTimeout`` - timeout for receiving HTTP response headers
  ## ``idleTimeout`` - timeout to consider HTTP connection as idle
  ## ``idlePeriod`` - period of time to check HTTP connections for inactivity
  doAssert(maxRedirections >= 0, "maxRedirections should not be negative")
  var res = HttpSessionRef(
    flags: flags,
    maxRedirections: maxRedirections,
    connectTimeout: connectTimeout,
    headersTimeout: headersTimeout,
    connectionBufferSize: connectionBufferSize,
    maxConnections: maxConnections,
    idleTimeout: idleTimeout,
    idlePeriod: idlePeriod,
    connections: initTable[string, seq[HttpClientConnectionRef]](),
    socketFlags: socketFlags,
    dualstack: dualstack
  )
  res.watcherFut =
    if HttpClientFlag.Http11Pipeline in flags:
      sessionWatcher(res)
    else:
      nil
  res

proc getTLSFlags(flags: HttpClientFlags): set[TLSFlags] =
  var res: set[TLSFlags]
  if HttpClientFlag.NoVerifyHost in flags:
    res.incl(TLSFlags.NoVerifyHost)
  if HttpClientFlag.NoVerifyServerName in flags:
    res.incl(TLSFlags.NoVerifyServerName)
  res

proc getHttpAddress*(
       url: Uri,
       flags: HttpClientFlags = {}
     ): HttpAddressResult =
  let
    scheme =
      if len(url.scheme) == 0:
        HttpClientScheme.NonSecure
      else:
        case toLowerAscii(url.scheme)
        of "http":
          HttpClientScheme.NonSecure
        of "https":
          HttpClientScheme.Secure
        else:
          return err(HttpAddressErrorType.InvalidUrlScheme)
    port =
      if len(url.port) == 0:
        case scheme
        of HttpClientScheme.NonSecure:
          80'u16
        of HttpClientScheme.Secure:
          443'u16
      else:
        Base10.decode(uint16, url.port).valueOr:
          return err(HttpAddressErrorType.InvalidPortNumber)
    hostname =
      block:
        if len(url.hostname) == 0:
          return err(HttpAddressErrorType.MissingHostname)
        url.hostname
    id = hostname & ":" & Base10.toString(port)
    addresses =
      if (HttpClientFlag.NoInet4Resolution in flags) and
         (HttpClientFlag.NoInet6Resolution in flags):
        # DNS resolution is disabled.
        try:
          @[initTAddress(hostname, Port(port))]
        except TransportAddressError:
          return err(HttpAddressErrorType.InvalidIpHostname)
      else:
        try:
          if (HttpClientFlag.NoInet4Resolution notin flags) and
             (HttpClientFlag.NoInet6Resolution notin flags):
            # DNS resolution for both IPv4 and IPv6 addresses.
            resolveTAddress(hostname, Port(port))
          else:
            if HttpClientFlag.NoInet6Resolution in flags:
              # DNS resolution only for IPv4 addresses.
              resolveTAddress(hostname, Port(port), AddressFamily.IPv4)
            else:
              # DNS resolution only for IPv6 addresses
              resolveTAddress(hostname, Port(port), AddressFamily.IPv6)
        except TransportAddressError:
          return err(HttpAddressErrorType.NameLookupFailed)

  if len(addresses) == 0:
    return err(HttpAddressErrorType.NoAddressResolved)

  ok(HttpAddress(id: id, scheme: scheme, hostname: hostname, port: port,
                 path: url.path, query: url.query, anchor: url.anchor,
                 username: url.username, password: url.password,
                 addresses: addresses))

proc getHttpAddress*(
       url: string,
       flags: HttpClientFlags = {}
     ): HttpAddressResult =
  getHttpAddress(parseUri(url), flags)

proc getHttpAddress*(
       session: HttpSessionRef,
       url: Uri
     ): HttpAddressResult =
  getHttpAddress(url, session.flags)

proc getHttpAddress*(
       session: HttpSessionRef,
       url: string
     ): HttpAddressResult =
  ## Create new HTTP address using URL string ``url`` and .
  getHttpAddress(parseUri(url), session.flags)

proc getAddress*(session: HttpSessionRef, url: Uri): HttpResult[HttpAddress] =
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
                 url: string): HttpResult[HttpAddress] =
  ## Create new HTTP address using URL string ``url`` and .
  session.getAddress(parseUri(url))

proc getAddress*(address: TransportAddress,
                 ctype: HttpClientScheme = HttpClientScheme.NonSecure,
                 queryString: string = "/"): HttpAddress =
  ## Create new HTTP address using Transport address ``address``, connection
  ## type ``ctype`` and query string ``queryString``.
  let uri = parseUri(queryString)
  HttpAddress(id: $address, scheme: ctype, hostname: address.host,
    port: uint16(address.port), path: uri.path, query: uri.query,
    anchor: uri.anchor, username: "", password: "", addresses: @[address]
  )

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

proc new(
       t: typedesc[HttpClientConnectionRef],
       session: HttpSessionRef,
       ha: HttpAddress,
       transp: StreamTransport
     ): Result[HttpClientConnectionRef, string] =
  case ha.scheme
  of HttpClientScheme.NonSecure:
    let res = HttpClientConnectionRef(
      id: session.getUniqueConnectionId(),
      kind: HttpClientScheme.NonSecure,
      transp: transp,
      reader: newAsyncStreamReader(transp),
      writer: newAsyncStreamWriter(transp),
      state: HttpClientConnectionState.Connecting,
      remoteHostname: ha.id
    )
    trackCounter(HttpClientConnectionTrackerName)
    ok(res)
  of HttpClientScheme.Secure:
    let
      treader = newAsyncStreamReader(transp)
      twriter = newAsyncStreamWriter(transp)
      tls =
        try:
          newTLSClientAsyncStream(treader, twriter, ha.hostname,
                                  flags = session.flags.getTLSFlags(),
                                  bufferSize = session.connectionBufferSize)
        except TLSStreamInitError as exc:
          return err(exc.msg)

      res = HttpClientConnectionRef(
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
    trackCounter(HttpClientConnectionTrackerName)
    ok(res)

proc setError(request: HttpClientRequestRef, error: ref HttpError) =
  request.error = error
  request.state = HttpReqRespState.Error
  if not(isNil(request.connection)):
    request.connection.state = HttpClientConnectionState.Error
    request.connection.error = error

proc setError(response: HttpClientResponseRef, error: ref HttpError) =
  response.error = error
  response.state = HttpReqRespState.Error
  if not(isNil(response.connection)):
    response.connection.state = HttpClientConnectionState.Error
    response.connection.error = error

proc closeWait(conn: HttpClientConnectionRef) {.async: (raises: []).} =
  ## Close HttpClientConnectionRef instance ``conn`` and free all the resources.
  if conn.state notin {HttpClientConnectionState.Closing,
                       HttpClientConnectionState.Closed}:
    conn.state = HttpClientConnectionState.Closing
    let pending =
      block:
        var res: seq[Future[void].Raising([])]
        if not(isNil(conn.reader)) and not(conn.reader.closed()):
          res.add(conn.reader.closeWait())
        if not(isNil(conn.writer)) and not(conn.writer.closed()):
          res.add(conn.writer.closeWait())
        if conn.kind == HttpClientScheme.Secure:
          res.add(conn.treader.closeWait())
          res.add(conn.twriter.closeWait())
        res.add(conn.transp.closeWait())
        res
    if len(pending) > 0: await noCancel(allFutures(pending))
    conn.state = HttpClientConnectionState.Closed
    untrackCounter(HttpClientConnectionTrackerName)

proc connect(session: HttpSessionRef,
             ha: HttpAddress): Future[HttpClientConnectionRef] {.
     async: (raises: [CancelledError, HttpConnectionError]).} =
  ## Establish new connection with remote server using ``url`` and ``flags``.
  ## On success returns ``HttpClientConnectionRef`` object.
  var lastError = ""
  # Here we trying to connect to every possible remote host address we got after
  # DNS resolution.
  for address in ha.addresses:
    let transp =
      try:
        await connect(address, bufferSize = session.connectionBufferSize,
                      flags = session.socketFlags,
                      dualstack = session.dualstack)
      except CancelledError as exc:
        raise exc
      except TransportError:
        nil
    if not(isNil(transp)):
      let conn =
        block:
          let res = HttpClientConnectionRef.new(session, ha, transp).valueOr:
            raiseHttpConnectionError(
              "Could not connect to remote host, reason: " & error)
          if res.kind == HttpClientScheme.Secure:
            try:
              await res.tls.handshake()
              res.state = HttpClientConnectionState.Ready
            except CancelledError as exc:
              await res.closeWait()
              raise exc
            except TLSStreamProtocolError as exc:
              await res.closeWait()
              res.state = HttpClientConnectionState.Error
              lastError = $exc.msg
            except AsyncStreamError as exc:
              await res.closeWait()
              res.state = HttpClientConnectionState.Error
              lastError = $exc.msg
          else:
            res.state = HttpClientConnectionState.Ready
          res
      if conn.state == HttpClientConnectionState.Ready:
        return conn

  # If all attempts to connect to the remote host have failed.
  if len(lastError) > 0:
    raiseHttpConnectionError("Could not connect to remote host, reason: " &
                             lastError)
  else:
    raiseHttpConnectionError("Could not connect to remote host")

proc removeConnection(session: HttpSessionRef,
                      conn: HttpClientConnectionRef) {.async: (raises: []).} =
  let removeHost =
    block:
      var res = false
      session.connections.withValue(conn.remoteHostname, connections):
        connections[].keepItIf(it != conn)
        if len(connections[]) == 0:
          res = true
      res
  if removeHost:
    session.connections.del(conn.remoteHostname)
  dec(session.connectionsCount)
  await conn.closeWait()

func connectionPoolEnabled(session: HttpSessionRef,
                           flags: set[HttpClientRequestFlag]): bool =
  (HttpClientFlag.NewConnectionAlways notin session.flags) and
  (HttpClientRequestFlag.DedicatedConnection notin flags) and
  (HttpClientFlag.Http11Pipeline in session.flags)

proc acquireConnection(
       session: HttpSessionRef,
       ha: HttpAddress,
       flags: set[HttpClientRequestFlag]
     ): Future[HttpClientConnectionRef] {.
     async: (raises: [CancelledError, HttpConnectionError]).} =
  ## Obtain connection from ``session`` or establish a new one.
  var default: seq[HttpClientConnectionRef]
  let timestamp = Moment.now()
  if session.connectionPoolEnabled(flags):
    # Trying to reuse existing connection from our connection's pool.
    # We looking for non-idle connection at `Ready` state, all idle connections
    # will be freed by sessionWatcher().
    for connection in session.connections.getOrDefault(ha.id):
      if connection.isReady() and
         not(connection.isIdle(timestamp, session.idleTimeout)):
        connection.state = HttpClientConnectionState.Acquired
        return connection

  let connection =
    try:
      await session.connect(ha).wait(session.connectTimeout)
    except AsyncTimeoutError:
      raiseHttpConnectionError("Connection timed out")
  connection.state = HttpClientConnectionState.Acquired
  session.connections.mgetOrPut(ha.id, default).add(connection)
  inc(session.connectionsCount)
  connection.setTimestamp(timestamp)
  connection.setDuration()
  connection

proc releaseConnection(session: HttpSessionRef,
                       connection: HttpClientConnectionRef) {.
     async: (raises: []).} =
  ## Return connection back to the ``session``.
  let removeConnection =
    if HttpClientFlag.Http11Pipeline notin session.flags:
      true
    else:
      case connection.state
      of HttpClientConnectionState.ResponseBodyReceived:
        if HttpClientConnectionFlag.KeepAlive in connection.flags:
          # HTTP response body has been received and "Connection: keep-alive" is
          # present in response headers.
          false
        else:
          # HTTP response body has been received, but "Connection: keep-alive"
          # is not present or not supported.
          true
      of HttpClientConnectionState.ResponseHeadersReceived:
        if (HttpClientConnectionFlag.NoBody in connection.flags) and
           (HttpClientConnectionFlag.KeepAlive in connection.flags):
          # HTTP response headers received with an empty response body and
          # "Connection: keep-alive" is present in response headers.
          false
        else:
          # HTTP response body is not received or "Connection: keep-alive" is
          # not present or not supported.
          true
      else:
        # Connection not in proper state.
        true

  if removeConnection:
    await session.removeConnection(connection)
  else:
    connection.state = HttpClientConnectionState.Ready
    connection.flags.excl({HttpClientConnectionFlag.Request,
                           HttpClientConnectionFlag.Response,
                           HttpClientConnectionFlag.NoBody})

proc releaseConnection(request: HttpClientRequestRef) {.async: (raises: []).} =
  let
    session = request.session
    connection = request.connection

  if not(isNil(connection)):
    request.connection = nil
    request.session = nil
    connection.flags.excl(HttpClientConnectionFlag.Request)
    if HttpClientConnectionFlag.Response notin connection.flags:
      await session.releaseConnection(connection)

proc releaseConnection(response: HttpClientResponseRef) {.
     async: (raises: []).} =
  let
    session = response.session
    connection = response.connection

  if not(isNil(connection)):
    response.connection = nil
    response.session = nil
    connection.flags.excl(HttpClientConnectionFlag.Response)
    if HttpClientConnectionFlag.Request notin connection.flags:
      await session.releaseConnection(connection)

proc closeWait*(session: HttpSessionRef) {.async: (raises: []).} =
  ## Closes HTTP session object.
  ##
  ## This closes all the connections opened to remote servers.
  var pending: seq[Future[void]]
  # Closing sessionWatcher to avoid race condition.
  if not(isNil(session.watcherFut)):
    await cancelAndWait(session.watcherFut)
  for connections in session.connections.values():
    for conn in connections:
      pending.add(closeWait(conn))
  await noCancel(allFutures(pending))

proc sessionWatcher(session: HttpSessionRef) {.async: (raises: []).} =
  while true:
    let firstBreak =
      try:
        await sleepAsync(session.idlePeriod)
        false
      except CancelledError:
        true

    if firstBreak:
      break

    var idleConnections: seq[HttpClientConnectionRef]
    let timestamp = Moment.now()
    for _, connections in session.connections.mpairs():
      connections.keepItIf(
        if isNil(it):
          false
        else:
          if it.isReady() and it.isIdle(timestamp, session.idleTimeout):
            idleConnections.add(it)
            false
          else:
            true
        )

    if len(idleConnections) > 0:
      dec(session.connectionsCount, len(idleConnections))
      var pending: seq[Future[void]]
      let secondBreak =
        try:
          for conn in idleConnections:
            pending.add(conn.closeWait())
          await allFutures(pending)
          false
        except CancelledError:
          # We still want to close connections to avoid socket leaks.
          await noCancel(allFutures(pending))
          true

      if secondBreak:
        break

proc closeWait*(request: HttpClientRequestRef) {.async: (raises: []).} =
  var pending: seq[Future[void].Raising([])]
  if request.state notin {HttpReqRespState.Closing, HttpReqRespState.Closed}:
    request.state = HttpReqRespState.Closing
    if not(isNil(request.writer)):
      if not(request.writer.closed()):
        pending.add(request.writer.closeWait())
      request.writer = nil
    pending.add(request.releaseConnection())
    await noCancel(allFutures(pending))
    request.session = nil
    request.error = nil
    request.headersBuffer.reset()
    request.state = HttpReqRespState.Closed
    untrackCounter(HttpClientRequestTrackerName)

proc closeWait*(response: HttpClientResponseRef) {.async: (raises: []).} =
  var pending: seq[Future[void].Raising([])]
  if response.state notin {HttpReqRespState.Closing, HttpReqRespState.Closed}:
    response.state = HttpReqRespState.Closing
    if not(isNil(response.reader)):
      if not(response.reader.closed()):
        pending.add(response.reader.closeWait())
      response.reader = nil
    pending.add(response.releaseConnection())
    await noCancel(allFutures(pending))
    response.session = nil
    response.error = nil
    response.state = HttpReqRespState.Closed
    untrackCounter(HttpClientResponseTrackerName)

proc prepareResponse(
       request: HttpClientRequestRef,
       data: openArray[byte]
     ): HttpResult[HttpClientResponseRef] =
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
      of HttpVersion11:
        # Keeping a connection open is the default on HTTP/1.1 requests.
        # https://www.rfc-editor.org/rfc/rfc2068.html#section-19.7.1
        let header = toLowerAscii(headers.getString(ConnectionHeader))
        if header == "close":
          false
        else:
          true
      of HttpVersion10:
        # This is the default on HTTP/1.0 requests.
        false
      else:
        # HTTP/2 does not use the Connection header field (Section 7.6.1 of
        # [HTTP]) to indicate connection-specific header fields.
        # https://httpwg.org/specs/rfc9113.html#rfc.section.8.2.2
        #
        # HTTP/3 does not use the Connection header field to indicate
        # connection-specific fields;
        # https://httpwg.org/specs/rfc9114.html#rfc.section.4.2
        true

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
  let
    newConnectionAlways =
      HttpClientFlag.NewConnectionAlways in request.session.flags
    httpPipeline =
      HttpClientFlag.Http11Pipeline in request.session.flags
    closeConnection =
      HttpClientRequestFlag.CloseConnection in request.flags
  if connectionFlag and not(newConnectionAlways) and not(closeConnection) and
     httpPipeline:
    res.connection.flags.incl(HttpClientConnectionFlag.KeepAlive)
  res.connection.flags.incl(HttpClientConnectionFlag.Response)
  trackCounter(HttpClientResponseTrackerName)
  ok(res)

proc getResponse(req: HttpClientRequestRef): Future[HttpClientResponseRef] {.
     async: (raises: [CancelledError, HttpError]).} =
  let timestamp = Moment.now()
  req.connection.setTimestamp(timestamp)
  let
    bytesRead =
      try:
        await req.connection.reader.readUntil(addr req.headersBuffer[0],
                                              len(req.headersBuffer),
                                              HeadersMark).wait(
                                              req.session.headersTimeout)
      except AsyncTimeoutError:
        raiseHttpReadError("Reading response headers timed out")
      except AsyncStreamError as exc:
        raiseHttpReadError(
          "Could not read response headers, reason: " & $exc.msg)

  let response =
    prepareResponse(req,
                    req.headersBuffer.toOpenArray(0, bytesRead - 1)).valueOr:
      raiseHttpProtocolError(error)
  response.setTimestamp(timestamp)
  response

proc new*(t: typedesc[HttpClientRequestRef], session: HttpSessionRef,
          ha: HttpAddress, meth: HttpMethod = MethodGet,
          version: HttpVersion = HttpVersion11,
          flags: set[HttpClientRequestFlag] = {},
          maxResponseHeadersSize: int = HttpMaxHeadersSize,
          headers: openArray[HttpHeaderTuple] = [],
          body: openArray[byte] = []): HttpClientRequestRef =
  let res = HttpClientRequestRef(
    state: HttpReqRespState.Ready, session: session, meth: meth,
    version: version, flags: flags, headers: HttpTable.init(headers),
    address: ha, bodyFlag: HttpClientBodyFlag.Custom, buffer: @body,
    headersBuffer: newSeq[byte](max(maxResponseHeadersSize, HttpMaxHeadersSize))
  )
  trackCounter(HttpClientRequestTrackerName)
  res

proc new*(t: typedesc[HttpClientRequestRef], session: HttpSessionRef,
          url: string, meth: HttpMethod = MethodGet,
          version: HttpVersion = HttpVersion11,
          flags: set[HttpClientRequestFlag] = {},
          maxResponseHeadersSize: int = HttpMaxHeadersSize,
          headers: openArray[HttpHeaderTuple] = [],
          body: openArray[byte] = []): HttpResult[HttpClientRequestRef] =
  let address = ? session.getAddress(parseUri(url))
  let res = HttpClientRequestRef(
    state: HttpReqRespState.Ready, session: session, meth: meth,
    version: version, flags: flags, headers: HttpTable.init(headers),
    address: address, bodyFlag: HttpClientBodyFlag.Custom, buffer: @body,
    headersBuffer: newSeq[byte](max(maxResponseHeadersSize, HttpMaxHeadersSize))
  )
  trackCounter(HttpClientRequestTrackerName)
  ok(res)

proc get*(t: typedesc[HttpClientRequestRef], session: HttpSessionRef,
          url: string, version: HttpVersion = HttpVersion11,
          flags: set[HttpClientRequestFlag] = {},
          maxResponseHeadersSize: int = HttpMaxHeadersSize,
          headers: openArray[HttpHeaderTuple] = []
         ): HttpResult[HttpClientRequestRef] =
  HttpClientRequestRef.new(session, url, MethodGet, version, flags,
                           maxResponseHeadersSize, headers)

proc get*(t: typedesc[HttpClientRequestRef], session: HttpSessionRef,
          ha: HttpAddress, version: HttpVersion = HttpVersion11,
          flags: set[HttpClientRequestFlag] = {},
          maxResponseHeadersSize: int = HttpMaxHeadersSize,
          headers: openArray[HttpHeaderTuple] = []
         ): HttpClientRequestRef =
  HttpClientRequestRef.new(session, ha, MethodGet, version, flags,
                           maxResponseHeadersSize, headers)

proc post*(t: typedesc[HttpClientRequestRef], session: HttpSessionRef,
           url: string, version: HttpVersion = HttpVersion11,
           flags: set[HttpClientRequestFlag] = {},
           maxResponseHeadersSize: int = HttpMaxHeadersSize,
           headers: openArray[HttpHeaderTuple] = [],
           body: openArray[byte] = []
          ): HttpResult[HttpClientRequestRef] =
  HttpClientRequestRef.new(session, url, MethodPost, version, flags,
                           maxResponseHeadersSize, headers, body)

proc post*(t: typedesc[HttpClientRequestRef], session: HttpSessionRef,
           url: string, version: HttpVersion = HttpVersion11,
           flags: set[HttpClientRequestFlag] = {},
           maxResponseHeadersSize: int = HttpMaxHeadersSize,
           headers: openArray[HttpHeaderTuple] = [],
           body: openArray[char] = []): HttpResult[HttpClientRequestRef] =
  HttpClientRequestRef.new(session, url, MethodPost, version, flags,
                           maxResponseHeadersSize, headers,
                           body.toOpenArrayByte(0, len(body) - 1))

proc post*(t: typedesc[HttpClientRequestRef], session: HttpSessionRef,
           ha: HttpAddress, version: HttpVersion = HttpVersion11,
           flags: set[HttpClientRequestFlag] = {},
           maxResponseHeadersSize: int = HttpMaxHeadersSize,
           headers: openArray[HttpHeaderTuple] = [],
           body: openArray[byte] = []): HttpClientRequestRef =
  HttpClientRequestRef.new(session, ha, MethodPost, version, flags,
                           maxResponseHeadersSize, headers, body)

proc post*(t: typedesc[HttpClientRequestRef], session: HttpSessionRef,
           ha: HttpAddress, version: HttpVersion = HttpVersion11,
           flags: set[HttpClientRequestFlag] = {},
           maxResponseHeadersSize: int = HttpMaxHeadersSize,
           headers: openArray[HttpHeaderTuple] = [],
           body: openArray[char] = []): HttpClientRequestRef =
  HttpClientRequestRef.new(session, ha, MethodPost, version, flags,
                           maxResponseHeadersSize, headers,
                           body.toOpenArrayByte(0, len(body) - 1))

proc prepareRequest(request: HttpClientRequestRef): string =
  template hasChunkedEncoding(request: HttpClientRequestRef): bool =
    toLowerAscii(request.headers.getString(TransferEncodingHeader)) == "chunked"

  # We use ChronosIdent as `User-Agent` string if its not set.
  discard request.headers.hasKeyOrPut(UserAgentHeader, ChronosIdent)
  # We use request's hostname as `Host` string if its not set.
  discard request.headers.hasKeyOrPut(HostHeader, request.address.hostname)
  # We set `Connection` to value according to flags if its not set.
  if ConnectionHeader notin request.headers:
    if (HttpClientFlag.Http11Pipeline notin request.session.flags) or
       (HttpClientRequestFlag.CloseConnection in request.flags):
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
      var res =
        if len(request.address.path) > 0:
          request.address.path
        else:
          "/"
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
     async: (raises: [CancelledError, HttpError]).} =
  doAssert(request.state == HttpReqRespState.Ready,
           "Request's state is " & $request.state)
  let connection =
    try:
      await request.session.acquireConnection(request.address, request.flags)
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
    request.setTimestamp()
    await request.connection.writer.write(headers)
    request.connection.state = HttpClientConnectionState.RequestHeadersSent
    request.connection.state = HttpClientConnectionState.RequestBodySending
    if len(request.buffer) > 0:
      await request.connection.writer.write(request.buffer)
    request.connection.state = HttpClientConnectionState.RequestBodySent
    request.state = HttpReqRespState.Finished
    request.setDuration()
  except CancelledError as exc:
    request.setDuration()
    request.setError(newHttpInterruptError())
    raise exc
  except AsyncStreamError as exc:
    request.setDuration()
    let error = newHttpWriteError(
      "Could not send request headers, reason: " & $exc.msg)
    request.setError(error)
    raise error

  try:
    await request.getResponse()
  except CancelledError as exc:
    request.setError(newHttpInterruptError())
    raise exc
  except HttpError as exc:
    request.setError(exc)
    raise exc

proc open*(request: HttpClientRequestRef): Future[HttpBodyWriter] {.
     async: (raises: [CancelledError, HttpError]).} =
  ## Start sending request's headers and return `HttpBodyWriter`, which can be
  ## used to send request's body.
  doAssert(request.state == HttpReqRespState.Ready,
           "Request's state is " & $request.state)
  doAssert(len(request.buffer) == 0,
           "Request should not have static body content (len(buffer) == 0)")
  let connection =
    try:
      await request.session.acquireConnection(request.address, request.flags)
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
    request.setTimestamp()
    await request.connection.writer.write(headers)
    request.connection.state = HttpClientConnectionState.RequestHeadersSent
  except CancelledError as exc:
    request.setDuration()
    request.setError(newHttpInterruptError())
    raise exc
  except AsyncStreamError as exc:
    let error = newHttpWriteError(
      "Could not send request headers, reason: " & $exc.msg)
    request.setDuration()
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
  writer

proc finish*(request: HttpClientRequestRef): Future[HttpClientResponseRef] {.
     async: (raises: [CancelledError, HttpError]).} =
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
  request.setDuration()
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

proc getBodyReader*(response: HttpClientResponseRef): HttpBodyReader {.
     raises: [HttpUseClosedError].} =
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
        newHttpBodyReader(
          newBoundedStreamReader(
            response.connection.reader, response.contentLength,
            bufferSize = response.session.connectionBufferSize))
      of HttpClientBodyFlag.Chunked:
        newHttpBodyReader(
          newChunkedStreamReader(
            response.connection.reader,
            bufferSize = response.session.connectionBufferSize))
      of HttpClientBodyFlag.Custom:
        newHttpBodyReader(
          newAsyncStreamReader(response.connection.reader))
    response.connection.state = HttpClientConnectionState.ResponseBodyReceiving
    response.reader = reader
  response.reader

proc finish*(response: HttpClientResponseRef) {.
     async: (raises: [HttpUseClosedError]).} =
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
    response.setDuration()

proc getBodyBytes*(response: HttpClientResponseRef): Future[seq[byte]] {.
     async: (raises: [CancelledError, HttpError]).} =
  ## Read all bytes from response ``response``.
  ##
  ## Note: This procedure performs automatic finishing for ``response``.
  var reader = response.getBodyReader()
  try:
    let data = await reader.read()
    await reader.closeWait()
    reader = nil
    await response.finish()
    data
  except CancelledError as exc:
    if not(isNil(reader)):
      await reader.closeWait()
    response.setError(newHttpInterruptError())
    raise exc
  except AsyncStreamError as exc:
    let error = newHttpReadError("Could not read response, reason: " & $exc.msg)
    if not(isNil(reader)):
      await reader.closeWait()
    response.setError(error)
    raise error

proc getBodyBytes*(response: HttpClientResponseRef,
                   nbytes: int): Future[seq[byte]] {.
     async: (raises: [CancelledError, HttpError]).} =
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
    data
  except CancelledError as exc:
    if not(isNil(reader)):
      await reader.closeWait()
    response.setError(newHttpInterruptError())
    raise exc
  except AsyncStreamError as exc:
    let error = newHttpReadError("Could not read response, reason: " & $exc.msg)
    if not(isNil(reader)):
      await reader.closeWait()
    response.setError(error)
    raise error

proc consumeBody*(response: HttpClientResponseRef): Future[int] {.
     async: (raises: [CancelledError, HttpError]).} =
  ## Consume/discard response and return number of bytes consumed.
  ##
  ## Note: This procedure performs automatic finishing for ``response``.
  var reader = response.getBodyReader()
  try:
    let res = await reader.consume()
    await reader.closeWait()
    reader = nil
    await response.finish()
    res
  except CancelledError as exc:
    if not(isNil(reader)):
      await reader.closeWait()
    response.setError(newHttpInterruptError())
    raise exc
  except AsyncStreamError as exc:
    let error = newHttpReadError(
      "Could not consume response, reason: " & $exc.msg)
    if not(isNil(reader)):
      await reader.closeWait()
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
    let headers =
      block:
        var res = request.headers
        res.set(HostHeader, ha.hostname)
        res
    var res =
      HttpClientRequestRef.new(request.session, ha, request.meth,
        request.version, request.flags, headers = headers.toList(),
        body = request.buffer)
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
    # Update Host header to redirected URL hostname
    let headers =
      block:
        var res = request.headers
        res.set(HostHeader, address.hostname)
        res
    var res =
      HttpClientRequestRef.new(request.session, address, request.meth,
        request.version, request.flags, headers = headers.toList(),
        body = request.buffer)
    res.redirectCount = redirectCount
    ok(res)

proc fetch*(request: HttpClientRequestRef): Future[HttpResponseTuple] {.
     async: (raises: [CancelledError, HttpError]).} =
  var response: HttpClientResponseRef
  try:
    response = await request.send()
    let buffer = await response.getBodyBytes()
    let status = response.status
    await response.closeWait()
    response = nil
    (status, buffer)
  except HttpError as exc:
    if not(isNil(response)): await response.closeWait()
    raise exc
  except CancelledError as exc:
    if not(isNil(response)): await response.closeWait()
    raise exc

proc fetch*(session: HttpSessionRef, url: Uri): Future[HttpResponseTuple] {.
     async: (raises: [CancelledError, HttpError]).} =
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

  var
    request = HttpClientRequestRef.new(session, address)
    response: HttpClientResponseRef = nil
    redirect: HttpClientRequestRef = nil

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
        let
          data = await response.getBodyBytes()
          code = response.status
        await response.closeWait()
        response = nil
        await request.closeWait()
        request = nil
        return (code, data)
    except CancelledError as exc:
      var pending: seq[Future[void]]
      if not(isNil(response)): pending.add(closeWait(response))
      if not(isNil(request)): pending.add(closeWait(request))
      if not(isNil(redirect)): pending.add(closeWait(redirect))
      await noCancel(allFutures(pending))
      raise exc
    except HttpError as exc:
      var pending: seq[Future[void]]
      if not(isNil(response)): pending.add(closeWait(response))
      if not(isNil(request)): pending.add(closeWait(request))
      if not(isNil(redirect)): pending.add(closeWait(redirect))
      await noCancel(allFutures(pending))
      raise exc

proc getServerSentEvents*(
       response: HttpClientResponseRef,
       maxEventSize: int = -1
     ): Future[seq[ServerSentEvent]] {.
     async: (raises: [CancelledError, HttpError]).} =
  ## Read number of server-sent events (SSE) from HTTP response ``response``.
  ##
  ## ``maxEventSize`` - maximum size of events chunk in one message, use
  ## `-1` or `0` to set size to unlimited.
  ##
  ## Server-sent events parsing is done according to:
  ## https://html.spec.whatwg.org/multipage/server-sent-events.html#parsing-an-event-stream
  ##
  ## Note: Server-sent event comments are ignored and silently skipped.
  const
    CR = byte(0x0D)
    LF = byte(0x0A)
    COLON = byte(':')
    SPACE = byte(' ')

  let reader = response.getBodyReader()

  var
    error: ref HttpReadError = nil
    res: seq[ServerSentEvent]
    buffer: seq[byte]

  proc consumeBuffer() =
    if len(buffer) == 0: return

    let pos = buffer.find(COLON)
    if pos == 0:
      # comment line
      discard
    elif pos > 0:
      # field_name: field_value
      let
        name = string.fromBytes(buffer.toOpenArray(0, pos - 1))
        value =
          if (pos + 1) < len(buffer):
            let spos = if buffer[pos + 1] == SPACE: pos + 2 else: pos + 1
            string.fromBytes(buffer.toOpenArray(spos, len(buffer) - 1))
          else:
            ""
      res.add(ServerSentEvent(name: name, data: value))
    else:
      # field_name only
      let name = string.fromBytes(buffer.toOpenArray(0, len(buffer) - 1))
      res.add(ServerSentEvent(name: name, data: ""))

    # Reset internal buffer to zero length.
    buffer.setLen(0)

  proc discardBuffer() =
    if len(buffer) == 0: return
    # Reset internal buffer to 1 byte length to keep comment sign.
    buffer.setLen(1)

  proc predicate(data: openArray[byte]): tuple[consumed: int, done: bool] =
    var i = 0
    while i < len(data):
      if data[i] in {CR, LF}:
        # CR or LF encountered
        inc(i)
        if (data[i - 1] == CR) and ((i < len(data)) and data[i] == LF):
          # We trying to check for CRLF
          inc(i)

        if len(buffer) == 0:
          if len(res) == 0:
            res.add(ServerSentEvent(name: "", data: ""))
          return (i, true)
        consumeBuffer()
      else:
        buffer.add(data[i])
        if (maxEventSize >= 0) and (len(buffer) > maxEventSize):
          if buffer[0] != COLON:
            # We only check limits for events and ignore comments size.
            error = newException(HttpReadLimitError,
                                 "Size of event exceeded maximum size")
            return (0, true)
          discardBuffer()

        inc(i)

    if len(data) == 0:
      # Stream is at EOF
      consumeBuffer()
      return (0, true)

    (i, false)

  try:
    await reader.readMessage(predicate)
  except CancelledError as exc:
    raise exc
  except AsyncStreamError as exc:
    raiseHttpReadError($exc.msg)

  if not isNil(error):
    raise error

  res

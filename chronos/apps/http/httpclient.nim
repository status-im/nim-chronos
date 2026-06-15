#
#                Chronos HTTP/S client
#             (c) Copyright 2021-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

{.push raises: [].}

import std/[uri, tables, sequtils, strutils]
import stew/[assign2, base10, byteutils, ptrops, shims/sequninit], httputils, results
import ../../[asyncloop, asyncsync, config]
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
    ## connections pool (60 sec)
    ## TODO Persistent connections currently must be explicitly enabled due to
    ##      the lack of idle connection monitoring (via MSG_PEEK, to discover EOF)
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
    # https://www.rfc-editor.org/info/rfc9112/#section-6.3
    NoBody,
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
    remoteHostname*: string # sourced from HttpAddress.id
    flags*: set[HttpClientConnectionFlag]
    timestamp*: Moment
    duration*: Duration

  HttpClientConnectionRef* = ref HttpClientConnection

  HttpConnectionProvider* = proc(
    request: HttpClientRequestRef
  ): Future[HttpClientConnectionRef] {.
    async: (raises: [CancelledError, HttpConnectionError])
  .}

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
    provider: HttpConnectionProvider

  HttpAddress* = object
    id*: string # authority ("hostname:port" without username/password)
    scheme*: HttpClientScheme
    hostname*: string
    port*: uint16
    path*: string
    query*: string
    anchor*: string
    username*: string
    password*: string
    addresses*: seq[TransportAddress]
      ## If addresses are set, name resolution is not performed and the client
      ## will instead attempt to connect to the given addresses (in order)

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
    NewConnectionAlways, ## Disable HTTP Persistent connections
    Http11Pipeline {.deprecated.} ## (deprecated, pipelining is not implemented)

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
  (conn.state == HttpClientConnectionState.Ready)

template isIdle(conn: HttpClientConnectionRef, timestamp: Moment,
                timeout: Duration): bool =
  (timestamp - conn.timestamp) >= timeout or conn.transp.atEof()

proc sessionWatcher(session: HttpSessionRef) {.async: (raises: []).}
proc directProvider*(): HttpConnectionProvider
proc new*(t: typedesc[HttpSessionRef],
          flags: HttpClientFlags = {NewConnectionAlways},
          maxRedirections = HttpMaxRedirections,
          connectTimeout = HttpConnectTimeout,
          headersTimeout = HttpHeadersTimeout,
          connectionBufferSize = DefaultStreamBufferSize,
          maxConnections = -1,
          idleTimeout = HttpConnectionIdleTimeout,
          idlePeriod = HttpConnectionCheckPeriod,
          socketFlags: set[SocketFlags] = {},
          dualstack = DualStackType.Auto,
          provider: HttpConnectionProvider = nil,): HttpSessionRef =
  ## Create new HTTP session object.
  ##
  ## ``maxRedirections`` - maximum number of HTTP 3xx redirections
  ## ``connectTimeout`` - timeout for ongoing HTTP connection
  ## ``headersTimeout`` - timeout for receiving HTTP response headers
  ## ``idleTimeout`` - timeout to consider HTTP connection as idle
  ## ``idlePeriod`` - period of time to check HTTP connections for inactivity
  doAssert(maxRedirections >= 0, "maxRedirections should not be negative")
  let res = HttpSessionRef(
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
    dualstack: dualstack,
    provider:
      if provider.isNil:
        directProvider()
      else:
        provider
  )
  res.watcherFut =
    if HttpClientFlag.NewConnectionAlways notin flags:
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

  ok(HttpAddress(id: id, scheme: scheme, hostname: hostname, port: port,
                 path: url.path, query: url.query, anchor: url.anchor,
                 username: url.username, password: url.password))

proc getHttpAddress*(
       uri: Uri,
       flags: HttpClientFlags
     ): HttpAddressResult {.deprecated: "No DNS resolution in getHttpAddress, no flags needed".} =
  getHttpAddress(uri)

proc getHttpAddress*(
       url: string,
     ): HttpAddressResult =
  getHttpAddress(parseUri(url))

proc getHttpAddress*(
       url: string,
       flags: HttpClientFlags
     ): HttpAddressResult {.deprecated: "No DNS resolution in getHttpAddress, no flags needed".} =
  getHttpAddress(parseUri(url), flags)

proc getHttpAddress*(
       session: HttpSessionRef,
       url: Uri
     ): HttpAddressResult {.deprecated: "No DNS resolution in getHttpAddress, no session needed".} =
  getHttpAddress(url, session.flags)

proc getHttpAddress*(
       session: HttpSessionRef,
       url: string
     ): HttpAddressResult {.deprecated: "No DNS resolution in getHttpAddress, no session needed".} =
  ## Create new HTTP address using URL string ``url`` and .
  getHttpAddress(parseUri(url))

proc getAddress*(session: HttpSessionRef, url: Uri): HttpResult[HttpAddress] {.deprecated: "use getHttpAddress".} =
  let res = getHttpAddress(url).valueOr:
    return err($error)
  ok res

proc getAddress*(session: HttpSessionRef,
                 url: string): HttpResult[HttpAddress] {.deprecated: "use getHttpAddress".} =
  ## Create new HTTP address using URL string ``url`` and .
  let res = getHttpAddress(url).valueOr:
    return err($error)
  ok res

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
        Base10.decode(uint16, newuri.port).valueOr:
          return err("Invalid URL port number")

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
       stream: AsyncStream,
       transp: StreamTransport
     ): Result[HttpClientConnectionRef, string] =
  # caller responsible for closing stream/transp in case of error
  let res =
    case ha.scheme
    of HttpClientScheme.NonSecure:
      HttpClientConnectionRef(
        id: session.getUniqueConnectionId(),
        kind: HttpClientScheme.NonSecure,
        transp: transp,
        reader: stream.reader,
        writer: stream.writer,
        state: HttpClientConnectionState.Connecting,
        remoteHostname: ha.id
      )
    of HttpClientScheme.Secure:
      let tls =
        try:
          newTLSClientAsyncStream(stream.reader, stream.writer, ha.hostname,
                                  flags = session.flags.getTLSFlags(),
                                  bufferSize = session.connectionBufferSize)
        except TLSStreamInitError as exc:
          return err(exc.msg)

      HttpClientConnectionRef(
        id: session.getUniqueConnectionId(),
        kind: HttpClientScheme.Secure,
        transp: transp,
        treader: stream.reader,
        twriter: stream.writer,
        reader: tls.reader,
        writer: tls.writer,
        tls: tls,
        state: HttpClientConnectionState.Connecting,
        remoteHostname: ha.id
      )
  trackCounter(HttpClientConnectionTrackerName)
  ok(res)

proc setError(conn: HttpClientConnectionRef, error: ref HttpError) =
  if conn.state notin {
    HttpClientConnectionState.Error, HttpClientConnectionState.Closing,
    HttpClientConnectionState.Closed,
  }:
    conn.state = HttpClientConnectionState.Error
    conn.error = error

proc setError(request: HttpClientRequestRef, error: ref HttpError) =
  if request.state notin
      {HttpReqRespState.Error, HttpReqRespState.Closing, HttpReqRespState.Closed}:
    request.error = error
    request.state = HttpReqRespState.Error
  if not(isNil(request.connection)):
    request.connection.setError(error)

proc setError(response: HttpClientResponseRef, error: ref HttpError) =
  if response.state notin
      {HttpReqRespState.Error, HttpReqRespState.Closing, HttpReqRespState.Closed}:
    response.error = error
    response.state = HttpReqRespState.Error
  if not(isNil(response.connection)):
    response.connection.setError(error)

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
          if not(isNil(conn.treader)) and not(conn.treader.closed()):
            res.add(conn.treader.closeWait())
          if not(isNil(conn.twriter)) and not(conn.twriter.closed()):
            res.add(conn.twriter.closeWait())
        if not(isNil(conn.transp)):
          res.add(conn.transp.closeWait())
        res
    if len(pending) > 0: await noCancel(allFutures(pending))
    conn.state = HttpClientConnectionState.Closed
    untrackCounter(HttpClientConnectionTrackerName)

proc resolve(
    session: HttpSessionRef, address: HttpAddress
): Result[seq[TransportAddress], HttpAddressErrorType] =
  if address.addresses.len == 0:
    if (HttpClientFlag.NoInet4Resolution in session.flags) and
        (HttpClientFlag.NoInet6Resolution in session.flags):
      # DNS resolution is disabled.
      try:
        ok @[initTAddress(address.hostname, Port(address.port))]
      except TransportAddressError:
        err(HttpAddressErrorType.InvalidIpHostname)
    else:
      let addresses =
        try:
          if (HttpClientFlag.NoInet4Resolution notin session.flags) and
              (HttpClientFlag.NoInet6Resolution notin session.flags):
            # DNS resolution for both IPv4 and IPv6 addresses.
            resolveTAddress(address.hostname, Port(address.port))
          else:
            if HttpClientFlag.NoInet6Resolution in session.flags:
              # DNS resolution only for IPv4 addresses.
              resolveTAddress(address.hostname, Port(address.port), AddressFamily.IPv4)
            else:
              # DNS resolution only for IPv6 addresses
              resolveTAddress(address.hostname, Port(address.port), AddressFamily.IPv6)
        except TransportAddressError:
          return err(HttpAddressErrorType.NameLookupFailed)

      if len(addresses) == 0:
        return err(HttpAddressErrorType.NoAddressResolved)
      ok addresses
  else:
    ok address.addresses

proc handshake(session: HttpSessionRef, ha: HttpAddress,
               stream: sink AsyncStream, transp: sink StreamTransport):
                 Future[HttpClientConnectionRef] {.
     async: (raises: [CancelledError, HttpConnectionError]).} =
  # takes ownership of stream/transp even if there's an error
  let conn = HttpClientConnectionRef.new(session, ha, stream, transp).valueOr:
    var pending = @[stream.reader.closeWait(), stream.writer.closeWait()]
    if transp != nil:
      pending.add transp.closeWait()
    await noCancel allFutures(pending)
    raiseHttpConnectionError(error)

  var connected = false
  try:
    case conn.kind
    of HttpClientScheme.NonSecure:
      discard # No special handshake needed
    of HttpClientScheme.Secure:
      try:
        await conn.tls.handshake()
      except AsyncStreamError as exc:
        raiseHttpConnectionError(exc.msg)
    conn.state = HttpClientConnectionState.Ready
    connected = true
    conn
  finally:
    if not connected:
      await noCancel conn.closeWait()

proc connect(session: HttpSessionRef,
             ha: HttpAddress): Future[HttpClientConnectionRef] {.
     async: (raises: [CancelledError, HttpConnectionError]).} =
  ## Establish new connection with remote server using ``ha``.
  ## On success returns ``HttpClientConnectionRef`` object.
  let addresses = session.resolve(ha).valueOr:
    raiseHttpConnectionError(error.toString())

  var lastError = ""
  # Here we trying to connect to every possible remote host address we got after
  # DNS resolution.
  for address in addresses:
    let
      transp =
        try:
          await connect(
            address,
            bufferSize = session.connectionBufferSize,
            flags = session.socketFlags,
            dualstack = session.dualstack,
          )
        except TransportError as exc:
          lastError = exc.msg
          continue
      stream = AsyncStream(
        reader: newAsyncStreamReader(transp), writer: newAsyncStreamWriter(transp)
      )

    # `handshake` takes ownership of stream/transp even in case of failure so we 
    # don't need to close hem here
    try:
      return await session.handshake(ha, stream, transp)
    except HttpConnectionError as exc:
      lastError = exc.msg

  # If all attempts to connect to the remote host have failed.
  if len(lastError) > 0:
    raiseHttpConnectionError("Could not connect to remote host: " &
                             lastError)
  else:
    raiseHttpConnectionError("Could not connect to remote host")

proc removeConnection(session: HttpSessionRef,
                      conn: HttpClientConnectionRef,
                      ha: HttpAddress) {.async: (raises: []).} =
  let removeHost =
    block:
      var res = false
      session.connections.withValue(ha.id, connections):
        connections[].keepItIf(it != conn)
        if len(connections[]) == 0:
          res = true
      res
  if removeHost:
    session.connections.del(ha.id)
  dec(session.connectionsCount)
  await conn.closeWait()

func connectionPoolEnabled(session: HttpSessionRef,
                           flags: set[HttpClientRequestFlag]): bool =
  (HttpClientFlag.NewConnectionAlways notin session.flags) and
  (HttpClientRequestFlag.DedicatedConnection notin flags)

proc reuseOrConnect(
       session: HttpSessionRef,
       ha: HttpAddress,
       flags: set[HttpClientRequestFlag]
     ): Future[HttpClientConnectionRef] {.
     async: (raises: [CancelledError, HttpConnectionError]).} =
  ## Obtain connection from ``session`` or establish a new one.
  let timestamp = Moment.now()
  if session.connectionPoolEnabled(flags):
    # Trying to reuse existing connection from our connection's pool.
    # We looking for non-idle connection at `Ready` state, all idle connections
    # will be freed by sessionWatcher().
    for connection in session.connections.getOrDefault(ha.id):
      if connection.isReady() and
         not(connection.isIdle(timestamp, session.idleTimeout)):
        connection.setTimestamp(timestamp)
        connection.flags.incl(HttpClientConnectionFlag.KeepAlive)
        connection.state = HttpClientConnectionState.Acquired
        return connection

  let connection =
    try:
      await session.connect(ha).wait(session.connectTimeout)
    except AsyncTimeoutError:
      raiseHttpConnectionError("Connection timed out")
  connection.state = HttpClientConnectionState.Acquired
  session.connections.mgetOrPut(ha.id, default(seq[HttpClientConnectionRef])).add(
    connection
  )
  inc(session.connectionsCount)
  if HttpClientRequestFlag.CloseConnection notin flags:
    connection.flags.incl(HttpClientConnectionFlag.KeepAlive)
  connection.setTimestamp(timestamp)
  connection.setDuration()
  connection

proc releaseConnection(session: HttpSessionRef,
                       connection: HttpClientConnectionRef,
                       ha: HttpAddress) {.
     async: (raises: []).} =
  ## Return connection back to the ``session``.
  let removeConnection =
    if HttpClientFlag.NewConnectionAlways in session.flags or
        HttpClientConnectionFlag.KeepAlive notin connection.flags:
      true
    else:
      case connection.state
      of HttpClientConnectionState.ResponseBodyReceived:
        # HTTP response body has been received and connection is persistent
        false
      of HttpClientConnectionState.ResponseHeadersReceived:
        if (HttpClientConnectionFlag.NoBody in connection.flags):
          # HTTP response headers received with an empty response body and
          # connection is persistent
          false
        else:
          # Expected HTTP body not received yet
          true
      else:
        # Connection not in proper state.
        true
  if removeConnection:
    await session.removeConnection(connection, ha)
  else:
    connection.state = HttpClientConnectionState.Ready
    connection.flags.reset()

proc releaseConnection(request: HttpClientRequestRef) {.async: (raises: []).} =
  let
    session = request.session
    connection = request.connection
  if not(isNil(connection)):
    request.connection = nil
    request.session = nil
    connection.flags.excl(HttpClientConnectionFlag.Request)
    if HttpClientConnectionFlag.Response notin connection.flags:
      await session.releaseConnection(connection, request.address)

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
      await session.releaseConnection(connection, response.address)

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
    if response.connection == nil: # CONNECT tunnels take over the connection
      response.state = HttpReqRespState.Closed
    else:
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
  let (contentLength, bodyFlag) =
    # https://www.rfc-editor.org/info/rfc9112/#section-6.3
    if (
      request.meth == MethodHead or (resp.code >= 100 and resp.code < 200) or
      resp.code == 204 or resp.code == 304
    ) or (request.meth == MethodConnect and (resp.code >= 200 and resp.code < 300)):
      # Responses that have no body still may have an informative Content-Length
      # header
      let length = headers.getInt(ContentLengthHeader)
      (length, HttpClientBodyFlag.NoBody)
    elif transferEncoding != {TransferEncodingFlags.Identity}:
      # "Transfer-Encoding overrides the Content-Length"
      if TransferEncodingFlags.Chunked in transferEncoding:
        (0'u64, HttpClientBodyFlag.Chunked)
      else:
        (0'u64, HttpClientBodyFlag.Custom)
    elif ContentLengthHeader in headers:
      let length = headers.getInt(ContentLengthHeader)
      (length, HttpClientBodyFlag.Sized)
    else:
      # response message without a declared message body length
      (0'u64, HttpClientBodyFlag.Custom)

  # Preprocessing "Connection" header.
  let persistent = isPersistent(resp.version, headers)

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

  # Transfer connection ownership to response (allowing request to be closed
  # independently)
  let connection = move(request.connection)
  assert request.connection == nil, "move should reset"

  if not persistent:
    connection.flags.excl(HttpClientConnectionFlag.KeepAlive)

  connection.flags.excl(HttpClientConnectionFlag.Request)
  connection.flags.incl(HttpClientConnectionFlag.Response)

  connection.state = HttpClientConnectionState.ResponseHeadersReceived
  if bodyFlag == HttpClientBodyFlag.NoBody:
    connection.flags.incl(HttpClientConnectionFlag.NoBody)
  else:
    connection.flags.excl(HttpClientConnectionFlag.NoBody)

  trackCounter(HttpClientResponseTrackerName)
  ok HttpClientResponseRef(
    state: HttpReqRespState.Open, status: resp.code,
    address: request.address, requestMethod: request.meth,
    reason: resp.reason(data), version: resp.version, session: request.session,
    connection: connection, headers: headers,
    contentEncoding: contentEncoding, transferEncoding: transferEncoding,
    contentLength: contentLength, contentType: contentType, bodyFlag: bodyFlag
  )

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
      except CancelledError as exc:
        req.setError(newHttpInterruptError())
        raise exc
      except AsyncTimeoutError:
        let error = (ref HttpReadError)(msg: "Reading response headers timed out")
        req.setError(error)
        raise error
      except AsyncStreamError as exc:
        let error = (ref HttpReadError)(
          msg: "Could not read response headers: " & $exc.msg)
        req.setError(error)
        raise error

  let response =
    prepareResponse(req,
                    req.headersBuffer.toOpenArray(0, bytesRead - 1)).valueOr:
      let err = (ref HttpProtocolError)(msg: error, code: Http400)
      req.setError(err)
      raise err

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
    address: ha, bodyFlag: HttpClientBodyFlag.Custom,
    buffer: newSeqUninit[byte](body.len),
    headersBuffer:
      newSeqUninit[byte](max(maxResponseHeadersSize, HttpMaxHeadersSize))
  )
  # `@`, `setLenUninit` etc are all slow pre-2.2.10, ie
  # https://github.com/nim-lang/Nim/issues/25719
  assign(res.buffer, body)
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
  ok HttpClientRequestRef.new(
    session, address, meth, version, flags, maxResponseHeadersSize, headers,
    body)

when chronosUseSink:
  proc new*(t: typedesc[HttpClientRequestRef], session: HttpSessionRef,
            ha: HttpAddress, meth: HttpMethod = MethodGet,
            version: HttpVersion = HttpVersion11,
            flags: set[HttpClientRequestFlag] = {},
            maxResponseHeadersSize: int = HttpMaxHeadersSize,
            headers: openArray[HttpHeaderTuple] = [],
            body: sink seq[byte]): HttpClientRequestRef =
    let res = HttpClientRequestRef(
      state: HttpReqRespState.Ready, session: session, meth: meth,
      version: version, flags: flags, headers: HttpTable.init(headers),
      address: ha, bodyFlag: HttpClientBodyFlag.Custom,
      buffer: move(body),
      headersBuffer:
        newSeqUninit[byte](max(maxResponseHeadersSize, HttpMaxHeadersSize))
    )
    trackCounter(HttpClientRequestTrackerName)
    res

  proc new*(t: typedesc[HttpClientRequestRef], session: HttpSessionRef,
            url: string, meth: HttpMethod = MethodGet,
            version: HttpVersion = HttpVersion11,
            flags: set[HttpClientRequestFlag] = {},
            maxResponseHeadersSize: int = HttpMaxHeadersSize,
            headers: openArray[HttpHeaderTuple] = [],
            body: sink seq[byte]):
              HttpResult[HttpClientRequestRef] =
    let ha = ? session.getAddress(parseUri(url))
    ok HttpClientRequestRef.new(
      session, ha, meth, version, flags, maxResponseHeadersSize, headers,
      move(body))

template get*(t: typedesc[HttpClientRequestRef], session: HttpSessionRef,
              address: HttpAddress | string, version: HttpVersion = HttpVersion11,
              flags: set[HttpClientRequestFlag] = {},
              maxResponseHeadersSize: int = HttpMaxHeadersSize,
              headers: openArray[HttpHeaderTuple] = []
            ): auto =
  HttpClientRequestRef.new(session, address, MethodGet, version, flags,
                           maxResponseHeadersSize, headers)

# TODO https://github.com/nim-lang/Nim/issues/25726
#      template works around ..
template post*(t: typedesc[HttpClientRequestRef], session: HttpSessionRef,
              address: HttpAddress | string, version: HttpVersion = HttpVersion11,
              flags: set[HttpClientRequestFlag] = {},
              maxResponseHeadersSize: int = HttpMaxHeadersSize,
              headers: openArray[HttpHeaderTuple] = [],
              body: openArray[byte] | seq[byte]): auto =
  HttpClientRequestRef.new(session, address, MethodPost, version, flags,
                           maxResponseHeadersSize, headers, body)
proc post*(t: typedesc[HttpClientRequestRef], session: HttpSessionRef,
           address: HttpAddress | string, version: HttpVersion = HttpVersion11,
           flags: set[HttpClientRequestFlag] = {},
           maxResponseHeadersSize: int = HttpMaxHeadersSize,
           headers: openArray[HttpHeaderTuple] = [],
           body: openArray[char] = []): auto =
  HttpClientRequestRef.new(session, address, MethodPost, version, flags,
                           maxResponseHeadersSize, headers,
                           body.toOpenArrayByte(0, body.high()))

proc prepareRequest(request: HttpClientRequestRef): string =
  template hasChunkedEncoding(request: HttpClientRequestRef): bool =
    toLowerAscii(request.headers.getString(TransferEncodingHeader)).endsWith("chunked")

  # We use ChronosIdent as `User-Agent` string if its not set.
  discard request.headers.hasKeyOrPut(UserAgentHeader, ChronosIdent)
  if request.meth == MethodConnect:
    # For CONNECT we must use authority form
    discard request.headers.hasKeyOrPut(HostHeader, request.address.id)
  else:
    discard request.headers.hasKeyOrPut(HostHeader, request.address.hostname)

    # In HTTP/1.1, we'll send `Connction: close` if we intend to close the
    # connection - in other cases, we use protocol defaults and don't send
    # anything to maximise compatibility:
    # https://www.rfc-editor.org/info/rfc9112/#compatibility.with.http.1.0.persistent.connections
    if request.version == HttpVersion11 and ConnectionHeader notin request.headers:
      if (HttpClientFlag.NewConnectionAlways in request.session.flags) or
        (HttpClientRequestFlag.CloseConnection in request.flags):
        request.headers.add(ConnectionHeader, "close")

    # We set `Accept` to accept any content if its not set.
    discard request.headers.hasKeyOrPut(AcceptHeaderName, "*/*")

  # We will send `Authorization` information only if username or password set,
  # and `Authorization` header is not present in request's headers.
  if (len(request.address.username) > 0 or len(request.address.password) > 0) and
      AuthorizationHeader notin request.headers:
    request.headers.add(
      AuthorizationHeader,
      encodeBasicAuth(request.address.username, request.address.password),
    )

  # Here we perform automatic detection: if request was created with non-zero
  # body and `Content-Length` header is missing we will create one with size
  # of body stored in request.
  if ContentLengthHeader notin request.headers:
    if len(request.buffer) > 0:
      let slength = Base10.toString(uint64(len(request.buffer)))
      request.headers.add(ContentLengthHeader, slength)

  request.bodyFlag =
    # Chunked transfer encoding takes precedence over `Content-Length`:
    # https://www.rfc-editor.org/info/rfc9112/#section-6.1
    if request.hasChunkedEncoding():
      HttpClientBodyFlag.Chunked
    elif ContentLengthHeader in request.headers:
      HttpClientBodyFlag.Sized
    else:
      HttpClientBodyFlag.Custom

  # https://www.rfc-editor.org/info/rfc9112/#section-3
  var res = $request.meth
  res.add(" ")

  if request.meth == MethodConnect:
    res.add(request.address.id) # authority form
  elif request.connection.remoteHostname != request.address.id:
    # The connection is a proxy - use absolute-form
    let scheme =
      case request.address.scheme
      of HttpClientScheme.NonSecure: "http"
      of HttpClientScheme.Secure: "https"

    res.add scheme
    res.add "://"
    res.add request.address.id

    if len(request.address.path) > 0:
      res.add(request.address.path)
    else:
      res.add("/")
  else:
    if len(request.address.path) > 0:
      res.add(request.address.path)
    else:
      res.add("/")

  if len(request.address.query) > 0:
    res.add("?")
    res.add(request.address.query)

  # Per RFC 9110/9112, a request-target MUST NOT include a URI fragment.
  # The fragment identifier is for user agents only and is not sent in HTTP requests.
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

proc acquireConnection(request: HttpClientRequestRef) {.
     async: (raises: [CancelledError, HttpError]).} =
  doAssert(request.state == HttpReqRespState.Ready,
           "Request's state is " & $request.state)

  let connection =
    try:
      await request.session.provider(request)
    except CancelledError as exc:
      request.setError(newHttpInterruptError())
      raise exc
    except HttpError as exc:
      request.setError(exc)
      raise exc

  connection.flags.incl(HttpClientConnectionFlag.Request)
  request.connection = connection
  request.setTimestamp()

proc sendHeaders(request: HttpClientRequestRef) {.
     async: (raises: [CancelledError, HttpError]).} =
  let headers = request.prepareRequest()
  request.connection.state = HttpClientConnectionState.RequestHeadersSending

  try:
    await request.connection.writer.write(headers)
  except CancelledError as exc:
    request.setError(newHttpInterruptError())
    raise exc
  except AsyncStreamError as exc:
    let error = newHttpWriteError("Could not send request headers: " & $exc.msg)
    request.setError(error)
    raise error

  request.connection.state = HttpClientConnectionState.RequestHeadersSent

proc open*(request: HttpClientRequestRef): Future[HttpBodyWriter] {.
     async: (raises: [CancelledError, HttpError]).} =
  ## Start sending request's headers and return `HttpBodyWriter`, which can be
  ## used to send request's body.
  doAssert(request.state == HttpReqRespState.Ready,
           "Request's state is " & $request.state)
  await request.acquireConnection()

  try:
    await request.sendHeaders()
  except CancelledError as exc:
    request.setDuration()
    raise exc
  except HttpError as exc:
    request.setDuration()
    raise exc

  let writer =
    case request.bodyFlag
    of HttpClientBodyFlag.NoBody:
      let writer = newBoundedStreamWriter(request.connection.writer, 0)
      newHttpBodyWriter([AsyncStreamWriter(writer)])
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

  await request.getResponse()

proc send*(request: HttpClientRequestRef): Future[HttpClientResponseRef] {.
     async: (raises: [CancelledError, HttpError]).} =
  doAssert(request.state == HttpReqRespState.Ready,
           "Request's state is " & $request.state)
  let writer = await request.open()
  try:
    if len(request.buffer) > 0:
    # TODO https://github.com/status-im/nim-chronos/issues/578
      await writer.write(baseAddr request.buffer, request.buffer.len)
      request.buffer.reset()
  except CancelledError as exc:
    request.setError(newHttpInterruptError())
    raise exc
  except AsyncStreamError as exc:
    let error = newHttpWriteError("Could not send request body: " & $exc.msg)
    request.setError(error)
    raise error
  finally:
    await writer.closeWait()

  await request.finish()

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
      of HttpClientBodyFlag.NoBody:
        newHttpBodyReader(
          newBoundedStreamReader(
            response.connection.reader, 0,
            bufferSize = response.session.connectionBufferSize))
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

proc tunnel*(response: HttpClientResponseRef): Future[AsyncStream] {.
     async: (raises: [CancelledError, HttpError]).} =
  ## After a CONNECT request, extract the underlying connection tunnel from
  ## the session and return it to the caller.
  ##
  ## The caller is responsible for closing both the returned stream and the 
  ## `response` itself.
  ## 
  ## After a successful call to `tunnel`, closing `response` will not close the
  ## returned tunnel.
  doAssert(response.requestMethod == MethodConnect,
           "Must use CONNECT method for tunneling")

  response.checkClosed()

  doAssert(not(isNil(response.connection)),
           "Response missing connection instance")
  doAssert(response.state == HttpReqRespState.Open,
           "Response's state is " & $response.state)
  doAssert(response.connection.state ==
           HttpClientConnectionState.ResponseHeadersReceived,
           "Connection state is " & $response.connection.state)

  # https://www.rfc-editor.org/info/rfc9110/#section-9.3.6
  # Any 2xx (Successful) response indicates that the sender (and all inbound
  # proxies) will switch to tunnel mode immediately after the response header 
  # section
  if response.status < 200 or response.status >= 300:
    raiseHttpProtocolError("CONNECT request failed with status: " & $response.status)

  let
    connection = response.connection
    # Take ownership of the streams / transports in the connection
    transp = move(connection.transp)
    reader = move(connection.reader)
    writer = move(connection.writer)
    (treader, twriter) = case connection.kind
      of HttpClientScheme.NonSecure:
        (nil, nil)
      of HttpClientScheme.Secure:
        (move(connection.treader), move(connection.twriter))
    rclose = newAsyncStreamReader(reader)
    wclose = newAsyncStreamWriter(writer)

  # Create a stream wrapper that will close the underlying streams and eventually
  # the transport too
  var otherClosed = false
  rclose.vtbl.close = block:
    var inner = rclose.vtbl.close
    proc closeInnerReader(
        rstream: AsyncStreamReader
    ) {.async: (raises: [], raw: true).} =
      var pending = @[reader.closeWait()]
      if treader != nil:
        pending.add treader.closeWait()
      if otherClosed:
        if transp != nil:
          pending.add transp.closeWait()
      else:
        otherClosed = true
      pending.add inner(rstream)
      noCancel allFutures(pending)

    closeInnerReader

  wclose.vtbl.close = block:
    var inner = wclose.vtbl.close
    proc closeInnerWriter(
        wstream: AsyncStreamWriter
    ) {.async: (raises: [], raw: true).} =
      var pending = @[writer.closeWait()]
      if twriter != nil:
        pending.add twriter.closeWait()
      if otherClosed: # Close socket once both underlying streams are closed
        if transp != nil:
          pending.add transp.closeWait()
      else:
        otherClosed = true
      pending.add inner(wstream)
      noCancel allFutures(pending)

    closeInnerWriter

  response.state = HttpReqRespState.Finished

  AsyncStream(reader: rclose, writer: wclose)

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
    # TODO https://github.com/status-im/nim-chronos/issues/601
    var buffer = await response.getBodyBytes()
    let status = response.status
    await response.closeWait()
    response = nil
    # TODO https://github.com/nim-lang/Nim/issues/25057
    (status, move(buffer))
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
  let address = getHttpAddress(url).valueOr:
    raiseHttpAddressError($error)

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
        var
          # TODO https://github.com/status-im/nim-chronos/issues/601
          data = await response.getBodyBytes()
          code = response.status
        await response.closeWait()
        response = nil
        await request.closeWait()
        request = nil
        # TODO https://github.com/nim-lang/Nim/issues/25057
        return (code, move(data))
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
  except AsyncStreamError as exc:
    raiseHttpReadError($exc.msg)

  if not isNil(error):
    raise error

  res

proc directProvider*(): HttpConnectionProvider =
  ## Return a connection provider that supplies connections directly to the
  ## requested address.
  return proc(
      request: HttpClientRequestRef
  ): Future[HttpClientConnectionRef] {.
      async: (raises: [CancelledError, HttpConnectionError], raw: true)
  .} =
    request.session.reuseOrConnect(request.address, request.flags)

proc httpProxyProvider*(proxy: HttpAddress): HttpConnectionProvider =
  ## Return a connection provider that supplies connections via a forwarding
  ## HTTP proxy.
  ##
  ## The connection to the proxy can be established via TLS enabling the use
  ## of secure proxies.
  return proc(
      request: HttpClientRequestRef
  ): Future[HttpClientConnectionRef] {.
      async: (raises: [CancelledError, HttpConnectionError], raw: true)
  .} =
    # Resolve the proxy on every connection attempt
    if (len(proxy.username) > 0 or len(proxy.password) > 0) and
        ProxyAuthorizationHeader notin request.headers:
      request.headers.add(
        ProxyAuthorizationHeader, encodeBasicAuth(proxy.username, proxy.password)
      )

    # Unlike a direct provider, we'll use the proxy address instead of the
    # request address for establishing the connection - the proxy becomes
    # responsible for resolving the request target name. Typically, a proxy
    # will reject HTTPS connections.
    request.session.reuseOrConnect(proxy, request.flags)

proc httpConnectProvider*(proxy: HttpAddress): HttpConnectionProvider =
  ## Return a provider that establishes HTTP CONNECT tunnel connections through
  ## the given proxy

  let proxySession = HttpSessionRef.new(provider = httpProxyProvider(proxy))

  return proc(
      request: HttpClientRequestRef
  ): Future[HttpClientConnectionRef] {.
      async: (raises: [CancelledError, HttpConnectionError])
  .} =
    let 
      # The target address is in the original request - CONNECT will use the
      # authority from this address to perform the connection - however, the
      # initial connection will be performed via the proxy provided by
      # httpProxyProvider above
      targetHa = request.address
      req = HttpClientRequestRef.new(proxySession, targetHa, MethodConnect)
      resp =
        try:
          await req.send()
        except HttpError as exc:
          raiseHttpConnectionError("Could not connect to proxy: " & exc.msg)
        finally:
          await req.closeWait()

      # `send` means we received the headers - if the request was successful,
      # we can extract a stream that we can use to establish the end-to-end
      # connection - both the proxy and the inner connections can be
      # using TLS but typically only the inner connection will be
      stream =
        try:
          await resp.tunnel()
        except HttpError as exc:
          raiseHttpConnectionError("Could not connect to proxy: " & exc.msg)
        finally:
          await resp.closeWait()

    # If targetHa was a TLS connection, we'll establish a secure connection -
    # handshake takes ownership of the stream so we don't need to close it.
    await proxySession.handshake(targetHa, stream, nil)

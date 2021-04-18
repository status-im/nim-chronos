import std/[uri, tables, strutils, sequtils]
import stew/[results, base10], httputils
import ../../asyncloop, ../../asyncsync
import ../../streams/[asyncstream, tlsstream, chunkstream, boundstream]
import httptable, httpcommon, httpagent, multipart
export httptable, httpcommon, httpagent, multipart

const
  HttpMaxHeadersSize* = 8192
    ## Maximum size of HTTP headers in octets
  HttpConnectTimeout* = 12.seconds
    ## Timeout for connecting to host (12 sec)
  HttpHeadersTimeout* = 120.seconds
    ## Timeout for receiving response headers (120 sec)
  HttpMaxRedirections* = 10
    ## Maximum number of Location redirections.

type
  HttpClientConnectionState* {.pure.} = enum
    Closed                    ## Connection has been closed
    Resolving,                ## Resolving remote hostname
    Connecting,               ## Connecting to remote server
    Ready,                    ## Connected to remote server
    RequestHeadersSending,    ## Sending request headers
    RequestHeadersSent,       ## Request headers has been sent
    RequestBodySending,       ## Sending request body
    RequestBodySent,          ## Request body has been sent
    ResponseHeadersReceiving, ## Receiving response headers
    ResponseHeadersReceived,  ## Response headers has been received
    ResponseBodyReceiving,    ## Receiving response body
    ResponseBodyReceived,     ## Response body has been received
    Error                     ## Error happens

  HttpClientConnectionType* {.pure.} = enum
    NonSecure,                ## Non-secure connection
    Secure                    ## Secure TLS connection

  HttpClientRequestState* {.pure.} = enum
    Closed,                   ## Request has been closed
    Created,                  ## Request created
    Connecting,               ## Connecting to remote host
    HeadersSending,           ## Sending request headers
    HeadersSent,              ## Request headers has been sent
    BodySending,              ## Sending request body
    BodySent,                 ## Request body has been sent
    Error,                    ## Error happens

  HttpClientResponseState* {.pure.} = enum
    Closed,                   ## Response has been closed
    HeadersReceived,          ## Response headers received
    BodyReceiving,            ## Response body receiving
    BodyReceived,             ## Response body received
    Error                     ## Error happens

  HttpClientBodyFlag* {.pure.} = enum
    Sized,                    ## `Content-Length` present
    Chunked,                  ## `Transfer-Encoding: chunked` present
    Custom                    ## None of the above

  HttpClientRequestFlag* {.pure.} = enum
    CloseConnection           ## Send `Connection: close` in request

  HttpHeaderTuple* = tuple
    key: string
    value: string

  HttpClientConnection* = object of RootObj
    case kind*: HttpClientConnectionType
    of HttpClientConnectionType.NonSecure:
      discard
    of HttpClientConnectionType.Secure:
      treader*: AsyncStreamReader
      twriter*: AsyncStreamWriter
      tls*: TLSAsyncStream
    transp*: StreamTransport
    reader*: AsyncStreamReader
    writer*: AsyncStreamWriter
    state*: HttpClientConnectionState
    error*: ref HttpError
    remoteHostname*: string

  HttpClientConnectionRef* = ref HttpClientConnection

  HttpSessionRef* = ref object
    connections*: Table[string, seq[HttpClientConnectionRef]]
    maxRedirections*: int
    connectTimeout*: Duration
    headersTimeout*: Duration
    connectionBufferSize*: int
    maxConnections*: int
    flags*: HttpClientFlags

  HttpClientScheme* {.pure.} = enum
    Nonsecure, Secure

  HttpAddress* = object
    id*: string
    scheme*: HttpClientConnectionType
    hostname*: string
    port*: uint16
    path*: string
    query*: string
    anchor*: string
    username*: string
    password*: string
    addresses*: seq[TransportAddress]

  HttpClientRequest* = object
    meth*: HttpMethod
    address: HttpAddress
    state: HttpClientRequestState
    version*: HttpVersion
    headers*: HttpTable
    bodyFlag: HttpClientBodyFlag
    flags: set[HttpClientRequestFlag]
    connection*: HttpClientConnectionRef
    session*: HttpSessionRef
    error*: ref HttpError
    buffer*: seq[byte]
    writer*: HttpBodyWriter

  HttpClientRequestRef* = ref HttpClientRequest

  HttpClientResponse* = object
    state: HttpClientResponseState
    status*: int
    reason*: string
    version*: HttpVersion
    headers*: HttpTable
    connection*: HttpClientConnectionRef
    session*: HttpSessionRef
    request*: HttpClientRequestRef
    error*: ref HttpError
    bodyFlag*: HttpClientBodyFlag
    contentEncoding*: set[ContentEncodingFlags]
    transferEncoding*: set[TransferEncodingFlags]
    contentLength*: uint64

  HttpClientResponseRef* = ref HttpClientResponse

  HttpClientFlag* {.pure.} = enum
    NoVerifyHost,        ## Skip remote server certificate verification
    NoVerifyServerName,  ## Skip remote server name CN verification
    NoInet4Resolution,   ## Do not resolve server hostname to IPv4 addresses
    NoInet6Resolution,   ## Do not resolve server hostname to IPv6 addresses
    NoAutomaticRedirect  ## Do not handle HTTP redirection automatically

  HttpClientFlags* = set[HttpClientFlag]

proc new*(t: typedesc[HttpSessionRef],
          flags: HttpClientFlags = {},
          maxRedirections = HttpMaxRedirections,
          connectTimeout = HttpConnectTimeout,
          headersTimeout = HttpHeadersTimeout,
          connectionBufferSize = DefaultStreamBufferSize,
          maxConnections = -1): HttpSessionRef {.
     raises: [Defect] .} =
  ## Create new HTTP session object.
  ##
  ## ``maxRedirections`` - maximum number of HTTP 3xx redirections
  ## ``connectTimeout`` - timeout for ongoing HTTP connection
  ## ``headersTimeout`` - timeout for receiving HTTP response headers
  HttpSessionRef(
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

proc getAddress(session: HttpSessionRef, url: Uri): HttpResult[HttpAddress] {.
     raises: [Defect] .} =
  let scheme =
    if len(url.scheme) == 0:
      HttpClientConnectionType.NonSecure
    else:
      case toLowerAscii(url.scheme)
      of "http":
        HttpClientConnectionType.NonSecure
      of "https":
        HttpClientConnectionType.Secure
      else:
        return err("URL scheme not supported")

  let port =
    if len(url.port) == 0:
      case scheme
      of HttpClientConnectionType.NonSecure:
        80'u16
      of HttpClientConnectionType.Secure:
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

proc new(t: typedesc[HttpClientConnectionRef], session: HttpSessionRef,
         ha: HttpAddress, transp: StreamTransport): HttpClientConnectionRef =
  case ha.scheme
  of HttpClientConnectionType.NonSecure:
    HttpClientConnectionRef(
      kind: HttpClientConnectionType.NonSecure,
      transp: transp,
      reader: newAsyncStreamReader(transp),
      writer: newAsyncStreamWriter(transp),
      state: HttpClientConnectionState.Connecting,
      remoteHostname: ha.id
    )
  of HttpClientConnectionType.Secure:
    let treader = newAsyncStreamReader(transp)
    let twriter = newAsyncStreamWriter(transp)
    let tls = newTLSClientAsyncStream(treader, twriter, ha.hostname,
                                      flags = session.flags.getTLSFlags())
    HttpClientConnectionRef(
      kind: HttpClientConnectionType.Secure,
      transp: transp,
      treader: treader,
      twriter: twriter,
      reader: tls.reader,
      writer: tls.writer,
      tls: tls,
      state: HttpClientConnectionState.Connecting,
      remoteHostname: ha.id
    )

proc setState(request: HttpClientRequestRef, state: HttpClientRequestState) {.
     raises: [Defect] .} =
  request.state = state
  case state
  of HttpClientRequestState.HeadersSending:
    request.connection.state = HttpClientConnectionState.RequestHeadersSending
  of HttpClientRequestState.HeadersSent:
    request.connection.state = HttpClientConnectionState.RequestHeadersSent
  of HttpClientRequestState.BodySending:
    request.connection.state = HttpClientConnectionState.RequestBodySending
  of HttpClientRequestState.BodySent:
    request.connection.state = HttpClientConnectionState.RequestBodySent
  else:
    discard

proc setState(response: HttpClientResponseRef,
              state: HttpClientResponseState) {.raises: [Defect] .} =
  response.state = state
  case state
  of HttpClientResponseState.HeadersReceived:
    response.connection.state =
      HttpClientConnectionState.ResponseHeadersReceived
  of HttpClientResponseState.BodyReceiving:
    response.connection.state = HttpClientConnectionState.ResponseBodyReceiving
  of HttpClientResponseState.BodyReceived:
    response.connection.state = HttpClientConnectionState.ResponseBodyReceived
  else:
    discard

proc setError(request: HttpClientRequestRef, error: ref HttpError) {.
     raises: [Defect] .} =
  request.error = error
  request.setState(HttpClientRequestState.Error)
  if not(isNil(request.connection)):
    request.connection.state = HttpClientConnectionState.Error
    request.connection.error = error

proc setError(response: HttpClientResponseRef, error: ref HttpError) {.
     raises: [Defect] .} =
  response.error = error
  response.setState(HttpClientResponseState.Error)
  if not(isNil(response.request)):
    # This call will set an error for corresponding connection too.
    response.request.setError(error)

proc closeWait*(conn: HttpClientConnectionRef) {.async.} =
  ## Close HttpClientConnectionRef instance ``conn`` and free all the resources.
  if conn.state != HttpClientConnectionState.Closed:
    await allFutures(conn.reader.closeWait(), conn.writer.closeWait())
    case conn.kind
    of HttpClientConnectionType.Secure:
      await allFutures(conn.treader.closeWait(), conn.twriter.closeWait())
    of HttpClientConnectionType.NonSecure:
      discard
    await conn.transp.closeWait()
    conn.state = HttpClientConnectionState.Closed

proc closeWait*(req: HttpClientRequestRef) {.async.} =
  ## Close HttpClientResponseRef instance ``req`` and free all the resources.
  discard

proc closeWait*(resp: HttpClientResponseRef) {.async.} =
  ## Close HttpClientResponseRef instance ``resp`` and free all the resources.
  discard

proc connect(session: HttpSessionRef,
             ha: HttpAddress): Future[HttpClientConnectionRef] {.async.} =
  ## Establish connection with remote server using ``url`` and ``flags``.
  ## On success returns ``HttpClientConnectionRef`` object.

  # Here we trying to connect to every possible remote host address we got after
  # DNS resolution.
  for address in ha.addresses:
    let transp =
      try:
        await connect(address, bufferSize = session.connectionBufferSize)
      except CancelledError as exc:
        raise exc
      except CatchableError:
        nil
    if not(isNil(transp)):
      let conn =
        block:
          let res = HttpClientConnectionRef.new(session, ha, transp)
          case res.kind
          of HttpClientConnectionType.Secure:
            try:
              await res.tls.handshake()
              res.state = HttpClientConnectionState.Ready
            except CancelledError as exc:
              await res.closeWait()
              raise exc
            except AsyncStreamError:
              await res.closeWait()
          of HttpClientConnectionType.Nonsecure:
            res.state = HttpClientConnectionState.Ready
          res
      if conn.state == HttpClientConnectionState.Ready:
        return conn

  # If all attempts to connect to the remote host have failed.
  raiseHttpConnectionError("Could not connect to remote host")

proc acquireConnection(session: HttpSessionRef,
                   ha: HttpAddress): Future[HttpClientConnectionRef] {.
     async.} =
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
    return conn
  else:
    var default: seq[HttpClientConnectionRef]
    let res =
      try:
        await session.connect(ha).wait(session.connectTimeout)
      except AsyncTimeoutError:
        raiseHttpConnectionError("Connection timed out")
    session.connections.mgetOrPut(ha.id, default).add(res)
    return res

proc releaseConnection(session: HttpSessionRef,
                       conn: HttpClientConnectionRef) {.async.} =
  if conn.state != HttpClientConnectionState.Ready:
    var conns = session.connections.getOrDefault(conn.remoteHostname)
    conns.keepItIf(it != conn)
    session.connections[conn.remoteHostname] = conns
    await conn.closeWait()

proc prepareResponse(request: HttpClientRequestRef,
                    data: openarray[byte]): HttpResult[HttpClientResponseRef] {.
     raises: [Defect] .} =
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
    if ContentLengthHeader in request.headers:
      let length = request.headers.getInt(ContentLengthHeader)
      (length, HttpClientBodyFlag.Sized)
    else:
      if TransferEncodingFlags.Chunked in transferEncoding:
        (0'u64, HttpClientBodyFlag.Chunked)
      else:
        (0'u64, HttpClientBodyFlag.Custom)

  ok(HttpClientResponseRef(
    state: HttpClientResponseState.HeadersReceived, status: resp.code,
    reason: resp.reason(data), version: resp.version, session: request.session,
    connection: request.connection, request: request, headers: headers,
    contentEncoding: contentEncoding, transferEncoding: transferEncoding,
    contentLength: contentLength, bodyFlag: bodyFlag
  ))

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
  let resp = prepareResponse(req, buffer.toOpenArray(0, bytesRead - 1))
  if resp.isErr():
    raiseHttpProtocolError(resp.error())
  return resp.get()

proc new*(t: typedesc[HttpClientRequestRef], session: HttpSessionRef,
          ha: HttpAddress, meth: HttpMethod = MethodGet,
          version: HttpVersion = HttpVersion11,
          flags: set[HttpClientRequestFlag] = {},
          headers: openarray[HttpHeaderTuple] = [],
          body: openarray[byte] = []): HttpClientRequestRef {.
     raises: [Defect].} =
  HttpClientRequestRef(
    state: HttpClientRequestState.Created, session: session, meth: meth,
    version: version, flags: flags, headers: HttpTable.init(headers),
    address: ha, bodyFlag: HttpClientBodyFlag.Custom, buffer: @body
  )

proc new*(t: typedesc[HttpClientRequestRef], session: HttpSessionRef,
          url: string, meth: HttpMethod = MethodGet,
          version: HttpVersion = HttpVersion11,
          flags: set[HttpClientRequestFlag] = {},
          headers: openarray[HttpHeaderTuple] = [],
          body: openarray[byte] = []): HttpResult[HttpClientRequestRef] {.
     raises: [Defect].} =
  let address = ? session.getAddress(parseUri(url))
  ok(HttpClientRequestRef(
    state: HttpClientRequestState.Created, session: session, meth: meth,
    version: version, flags: flags, headers: HttpTable.init(headers),
    address: address, bodyFlag: HttpClientBodyFlag.Custom, buffer: @body
  ))

proc get*(t: typedesc[HttpClientRequestRef], session: HttpSessionRef,
          url: string, version: HttpVersion = HttpVersion11,
          flags: set[HttpClientRequestFlag] = {},
          headers: openarray[HttpHeaderTuple] = []
         ): HttpResult[HttpClientRequestRef] {.raises: [Defect].} =
  HttpClientRequestRef.new(session, url, MethodGet, version, flags, headers)

proc get*(t: typedesc[HttpClientRequestRef], session: HttpSessionRef,
          ha: HttpAddress, version: HttpVersion = HttpVersion11,
          flags: set[HttpClientRequestFlag] = {},
          headers: openarray[HttpHeaderTuple] = []
         ): HttpClientRequestRef {.raises: [Defect].} =
  HttpClientRequestRef.new(session, ha, MethodGet, version, flags, headers)

proc post*(t: typedesc[HttpClientRequestRef], session: HttpSessionRef,
           url: string, version: HttpVersion = HttpVersion11,
           flags: set[HttpClientRequestFlag] = {},
           headers: openarray[HttpHeaderTuple] = [],
           body: openarray[byte] = []
          ): HttpResult[HttpClientRequestRef] {.raises: [Defect].} =
  HttpClientRequestRef.new(session, url, MethodPost, version, flags, headers,
                           body)

proc post*(t: typedesc[HttpClientRequestRef], session: HttpSessionRef,
           url: string, version: HttpVersion = HttpVersion11,
           flags: set[HttpClientRequestFlag] = {},
           headers: openarray[HttpHeaderTuple] = [],
           body: openarray[char] = []): HttpResult[HttpClientRequestRef] {.
     raises: [Defect].} =
  HttpClientRequestRef.new(session, url, MethodPost, version, flags, headers,
                           body.toOpenArrayByte(0, len(body) - 1))

proc post*(t: typedesc[HttpClientRequestRef], session: HttpSessionRef,
           ha: HttpAddress, version: HttpVersion = HttpVersion11,
           flags: set[HttpClientRequestFlag] = {},
           headers: openarray[HttpHeaderTuple] = [],
           body: openarray[byte] = []): HttpClientRequestRef {.
     raises: [Defect].} =
  HttpClientRequestRef.new(session, ha, MethodPost, version, flags, headers,
                           body)

proc post*(t: typedesc[HttpClientRequestRef], session: HttpSessionRef,
           ha: HttpAddress, version: HttpVersion = HttpVersion11,
           flags: set[HttpClientRequestFlag] = {},
           headers: openarray[HttpHeaderTuple] = [],
           body: openarray[char] = []): HttpClientRequestRef {.
     raises: [Defect].} =
  HttpClientRequestRef.new(session, ha, MethodPost, version, flags, headers,
                           body.toOpenArrayByte(0, len(body) - 1))

proc prepareRequest(request: HttpClientRequestRef): string {.
     raises: [Defect].} =
  template hasChunkedEncoding(request: HttpClientRequestRef): bool =
    toLowerAscii(request.headers.getString(TransferEncodingHeader)) == "chunked"

  # We use ChronosIdent as `User-Agent` string if its not set.
  if UserAgentHeader notin request.headers:
    discard request.headers.hasKeyOrPut(UserAgentHeader, ChronosIdent)
  # We use request's hostname as `Host` string if its not set.
  if HostHeader notin request.headers:
    discard request.headers.hasKeyOrPut(HostHeader, request.address.hostname)
  # We set `Connection` to value according to flags if its not set.
  if ConnectionHeader notin request.headers:
    if HttpClientRequestFlag.CloseConnection in request.flags:
      discard request.headers.hasKeyOrPut(ConnectionHeader, "close")
    else:
      discard request.headers.hasKeyOrPut(ConnectionHeader, "keep-alive")
  # We set `Accept` to accept any content if its not set.
  if AcceptHeader notin request.headers:
    discard request.headers.hasKeyOrPut(AcceptHeader, "*/*")

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

proc open*(request: HttpClientRequestRef): Future[HttpBodyWriter] {.
     async.} =
  request.setState(HttpClientRequestState.Connecting)
  request.connection =
    try:
      await request.session.acquireConnection(request.address)
    except CancelledError as exc:
      let error = newHttpInterruptError()
      request.setError(error)
      raise exc
    except HttpError as exc:
      request.setError(exc)
      raise exc

  let headers = request.prepareRequest()

  request.setState(HttpClientRequestState.HeadersSending)
  try:
    await request.connection.writer.write(headers)
  except CancelledError as exc:
    let error = newHttpInterruptError()
    request.error = error
    request.connection.error = error
    request.setState(HttpClientRequestState.Error)
    raise exc
  except AsyncStreamError as exc:
    request.error = newHttpWriteError("Could not send request headers")
    request.state = HttpClientRequestState.Error
    raise request.error
  request.setState(HttpClientRequestState.HeadersSent)

  let writer =
    case request.bodyFlag
    of HttpClientBodyFlag.Sized:
      let size = Base10.decode(uint64,
                               request.headers.getString("content-length"))
      let writer = newBoundedStreamWriter(request.connection.writer,
                                          int(size.get()))
      newHttpBodyWriter([AsyncStreamWriter(writer)])
    of HttpClientBodyFlag.Chunked:
      let writer = newChunkedStreamWriter(request.connection.writer)
      newHttpBodyWriter([AsyncStreamWriter(writer)])
    of HttpClientBodyFlag.Custom:
      let writer = newAsyncStreamWriter(request.connection.writer)
      newHttpBodyWriter([writer])

  request.writer = writer
  request.setState(HttpClientRequestState.BodySending)
  return writer

proc finish*(request: HttpClientRequestRef): Future[HttpClientResponseRef] {.
     async.} =
  doAssert(request.state == HttpClientRequestState.BodySending)
  request.setState(HttpClientRequestState.BodySent)

  let resp =
    try:
      await request.getResponse()
    except CancelledError as exc:
      request.setError(newHttpInterruptError())
      raise exc
    except HttpError as exc:
      request.setError(exc)
      raise exc

  if HttpClientFlag.NoAutomaticRedirect notin request.session.flags:
    return resp

proc getBodyReader*(resp: HttpClientResponseRef): HttpResult[HttpBodyReader] =
  ## Returns stream's reader instance which can be used to read response's body.
  ##
  ## Streams which was obtained using this procedure must be closed to avoid
  ## leaks.
  case resp.bodyFlag
  of HttpClientBodyFlag.Sized:
    let bstream = newBoundedStreamReader(response.connection.reader,
                                         response.contentLength)
  of HttpClientBodyFlag.Chunked:
    discard
  of HttpClientBodyFlag.Custom:
    discard

  if HttpRequestFlags.BoundBody in request.requestFlags:
    let bstream = newBoundedStreamReader(request.connection.reader,
                                         request.contentLength)
    ok(newHttpBodyReader(bstream))
  elif HttpRequestFlags.UnboundBody in request.requestFlags:
    let maxBodySize = request.connection.server.maxRequestBodySize
    let bstream = newBoundedStreamReader(request.connection.reader, maxBodySize,
                                         comparison = BoundCmp.LessOrEqual)
    let cstream = newChunkedStreamReader(bstream)
    ok(newHttpBodyReader(cstream, bstream))
  else:
    err("Request do not have body available")


# proc send*(request: HttpClientRequestRef): Future[HttpClientResponseRef] {.
#      async.} =
#   if request.meth in PostMethods:
#     if len(request.body) > 0:
#       discard
#     else:
#       discard
#   else:
#     discard


proc testClient*(address: string) {.async.} =
  var session = HttpSessionRef.new()
  let ha = session.getAddress(parseUri(address)).tryGet()
  var request = HttpClientRequestRef.get(session, ha)
  var writer = await request.open()
  var resp = await request.finish()
  echo resp.status
  echo resp.reason
  echo resp.version
  echo resp.headers
  echo ""
  echo resp.contentEncoding
  echo resp.transferEncoding
  echo resp.bodyFlag

when isMainModule:
  # var value = "HTTP/1.1 301 Moved Permanently\r\n" &
  #   "Location: http://www.google.com/\r\n" &
  #   "Content-Type: text/html; charset=UTF-8\r\n" &
  #   "Date: Sun, 26 Apr 2009 11:11:49 GMT\r\n" &
  #   "Expires: Tue, 26 May 2009 11:11:49 GMT\r\n" &
  #   "X-$PrototypeBI-Version: 1.6.0.3\r\n" &
  #   "Cache-Control: public, max-age=2592000\r\n" &
  #   "Server: gws\r\n" &
  #   "Content-Length:  219  \r\n" &
  #   "\r\n"

  # var buffer: array[4096, byte]

  # copyMem(addr buffer[0], addr value[0], len(value))
  # let resp = parseResponse(buffer.toOpenArray(0, len(value) - 1), false)
  # echo resp.success()
  # for k, v in resp.headers(buffer.toOpenArray(0, len(value) - 1)):
  #   echo k, ": ", v

  waitFor(testClient("https://www.google.com"))

  # var session = HttpSessionRef.new()
  # let r1 = session.newBufferRequest("https://www.google.com")
  # let r2 = session.newBufferRequest("https://www.google.com/")
  # let r3 = session.newBufferRequest("https://www.google.com/?a=b#a")
  # let r4 = session.newBufferRequest("https://www.google.com/index.html?a=b#a")
  # #waitFor testClient("https://www.google.com")
  # echo r1.tryGet().prepareRequest()
  # echo ""
  # echo r2.tryGet().prepareRequest()
  # echo ""
  # echo r3.tryGet().prepareRequest()
  # echo ""
  # echo r4.tryGet().prepareRequest()
  # echo ""

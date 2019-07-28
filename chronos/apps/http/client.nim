#
#        Chronos Application Protocols (HTTP)
#              (c) Copyright 2018-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)
import uri, strutils
import httputils
import ../../asyncloop, ../../version
import ../../streams/asyncstream, ../../streams/chunkstream

export uri, httputils

const
  HttpMaxHeadersSize* = 8192        # maximum size of HTTP headers in octets
  HttpConnectTimeout* = 12.seconds  # timeout for connecting to host (12 sec)
  HttpHeadersTimeout* = 120.seconds # timeout for receiving headers (120 sec)
  HttpHeadersMark* = @[byte(0x0D), byte(0x0A), byte(0x0D), byte(0x0A)]

type
  HttpState* {.pure.} = enum
    Closed           # Connection closed
    Resolving,       # Resolving remote hostname
    Connecting,      # Connecting to remote server
    Ready,           # Connected to remote server and ready to process requests
    RequestSending,  # Sending request
    RequestSent,     # Request was sent
    HeadersReceived, # Response headers received
    BodyReceived,    # Response body received
    Error            # Error happens

  HttpError* = object of CatchableError
    ## Base HTTP error
  HttpTimeoutError* = object of HttpError
    ## Timeout exceeded error
  HttpResolveHostError* = object of HttpError
    ## Remote address could not be resolved
  HttpIncorrectUrlError* = object of HttpError
    ## Incorrect URL
  HttpConnectionFailedError* = object of HttpError
    ## Connection to remote host failed
  HttpProtocolError* = object of HttpError
    ## HTTP protocol error
  HttpNetworkError* = object of HttpError
    ## Networking error (remote peer disconnected or local network shutdown)
  HttpBreachProtocolError* = object of HttpError
    ## Attempt to breach some buffer limits
  HttpNoSupportError* = object of HttpError
    ## Some HTTP features are not yet supportet

  HHeader* = tuple[name: string, value: string]
  HttpHeaders* = object
    list*: seq[HHeader]

  HttpRequest* = ref object
    version*: HttpVersion
    meth*: HttpMethod
    origurl*: Uri
    url*: Uri
    stream*: AsyncStream
    headers*: HttpHeaders
    body*: seq[byte]

  HttpResponse* = ref object
    code*: int
    version*: HttpVersion
    reason*: string
    request*: HttpRequest
    headers*: HttpResponseHeader
    stream*: AsyncStream
    bodyTimeout*: Duration
    conn*: HttpConnection

  HttpConnection* = ref object
    transp*: StreamTransport
    stream*: AsyncStream
    bstream*: AsyncStreamReader
    s: HttpState
    error*: ref HttpError
    lastreq*: HttpRequest

  HttpSession* = ref object
    conn*: HttpConnection
    maxRedirections*: int
    connectTimeout*: Duration
    headersTimeout*: Duration

proc contains*(a: HttpHeaders, name: string): bool =
  ## Returns ``true`` if HTTP headers collection has header with name ``name``.
  for item in a.list:
    if cmpIgnoreCase(item.name, name) == 0:
      result = true
      break

proc `[]=`*(a: var HttpHeaders, name: string, value: string) =
  ## Add HTTP header with name ``name`` and value ``value`` to collection ``a``.
  if not(checkHeaderName(name)) or not(checkHeaderValue(value)):
    raise newException(ValueError, "Incorrect header name or value!")

  var processed = false
  for i in 0..<len(a.list):
    if cmpIgnoreCase(a.list[i].name, name) == 0:
      a.list[i].value = value
      processed = true
      break
  if not processed:
    a.list.add((name: name, value: value))

proc `[]`*(a: HttpHeaders, name: string): string =
  ## Returns value of HTTP header with name ``name`` in collection ``a``.
  for item in a.list:
    if cmpIgnoreCase(item.name, name) == 0:
      result = item.value
      break

proc init*(t: typedesc[HttpRequest], meth: HttpMethod, url: string,
           version: HttpVersion = HttpVersion11,
           headers: seq[HHeader] = @[], body: seq[byte] = @[]): HttpRequest =
  result = HttpRequest()
  result.meth = meth
  result.origurl = parseUri(url)
  result.url = result.origurl

  result.version = version
  result.body = body

  if len(result.url.hostname) == 0:
    raise newException(ValueError, "Incorrect URL")

  for item in headers:
    result.headers[item.name] = item.value

  if "User-Agent" notin result.headers:
    result.headers["User-Agent"] = ChronosIdent

  if "Date" notin result.headers:
    result.headers["Date"] = httpDate()

  if "Content-Type" notin result.headers:
    result.headers["Content-Type"] = "text/html"

  if "Host" notin result.headers:
    if version in {HttpVersion11, HttpVersion20}:
      if len(result.url.port) > 0:
        result.headers["Host"] = result.url.hostname & ":" & result.url.port
      else:
        result.headers["Host"] = result.url.hostname

  if version in {HttpVersion09, HttpVersion10}:
    result.headers["Content-Length"] = $len(result.body)
  else:
    if len(result.body) > 0:
      result.headers["Content-Length"] = $len(result.body)

proc init*(t: typedesc[HttpSession],
           maxRedirections = 10,
           connectTimeout = HttpConnectTimeout,
           headersTimeout = HttpHeadersTimeout): HttpSession =
  ## Create new HTTP session object.
  ##
  ## ``maxRedirections`` - maximum number of HTTP 3xx redirections
  ## (default: 10).
  ## ``connectTimeout`` - timeout for ongoing HTTP connection
  ## (default: 12 seconds).
  ## ``headersTimeout`` - timeout for receiving HTTP response headers
  ## (default: 120 seconds).
  result = HttpSession()
  result.maxRedirections = maxRedirections
  result.connectTimeout = connectTimeout
  result.headersTimeout = headersTimeout
  result.conn = HttpConnection()

proc `$`*(resp: HttpResponse): string =
  ## Return string representation of HTTP response object.
  ##
  ## Please note, that response body is not included.
  if resp.code != 0:
    result = "Response code:\n"
    result.add("  ")
    result.add($resp.code)
    result.add(" ")
    result.add($resp.reason)
    result.add("\n")
    result.add("Response version:\n")
    result.add("  ")
    result.add($resp.version)
    result.add("\n")
    result.add("Response headers:\n")
    for item in resp.headers.headers():
      result.add("  ")
      result.add(item.name)
      result.add(": ")
      result.add(item.value)
      result.add("\n")

proc `$`*(req: HttpRequest): string =
  ## Return string representation of HTTP request object.
  ##
  ## Please note, that request body is not included.
  if len(req.url.hostname) != 0:
    result = "Request method:\n"
    result.add("  ")
    result.add($req.meth)
    result.add("\n")
    result.add("Request url:\n")
    result.add("  ")
    result.add($req.url)
    result.add("\n")
    result.add("Request version:\n")
    result.add("  ")
    result.add($req.version)
    result.add("\n")
    result.add("Request headers:\n")
    for item in req.headers.list:
      result.add("  ")
      result.add(item.name)
      result.add(": ")
      result.add(item.value)
      result.add("\n")

# proc add*(a: var HttpHeaders, name: string, value: string) =
#   a.list.add((name: name, value: value))

iterator items*(a: HttpHeaders): HHeader =
  for item in a.list:
    yield item

proc byteLen*(a: HttpHeaders): int =
  ## Returns size of serialized headers.
  result = 0
  for item in a.list:
    # Every header line consist of <name>[: ]<value>CRLF
    result += len(item.name) + len(item.value) + 2 + 2
  # last CRLF
  result += 2

proc send(stream: AsyncStreamWriter, req: HttpRequest) {.async.} =
  var h = $req.meth
  h.add(" ")
  if len(req.url.path) == 0:
    h.add("/")
  else:
    h.add(req.url.path)
  if len(req.url.query) > 0:
    h.add("?")
    h.add(req.url.query)
  if len(req.url.anchor) > 0:
    h.add("#")
    h.add(req.url.anchor)
  h.add(" ")
  h.add($req.version)
  h.add("\r\n")

  var request = newSeq[byte](len(h) + req.headers.byteLen())
  copyMem(addr request[0], addr h[0], len(h))
  var offset = len(h)
  for item in req.headers.list.mitems():
    copyMem(addr request[offset], addr item.name[0], len(item.name))
    offset += len(item.name)
    request[offset] = byte(':')
    offset += 1
    request[offset] = byte(' ')
    offset += 1
    copyMem(addr request[offset], addr item.value[0], len(item.value))
    offset += len(item.value)
    request[offset] = byte(0x0D)
    offset += 1
    request[offset] = byte(0x0A)
    offset += 1
  request[offset] = byte(0x0D)
  offset += 1
  request[offset] = byte(0x0A)
  offset += 1

  await stream.write(request)
  if len(req.body) > 0:
    await stream.write(req.body)

proc `state=`(conn: HttpConnection, state: HttpState) {.inline.} =
  conn.s = state

proc state*(conn: HttpConnection): HttpState {.inline.} = conn.s

proc validate(header: HttpResponseHeader, request: HttpRequest): bool =
  if header.failed():
    return false
  if header.version != request.version:
    return false
  if request.version in {HttpVersion11, HttpVersion20}:
    if "Content-Length" in header:
      if "chunked" in header["Transfer-Encoding"].toLowerAscii():
        return false
    else:
      if header["Connection"].toLowerAscii() != "close":
        if "chunked" notin header["Transfer-Encoding"].toLowerAscii():
          return false
  # RFC 7230
  # 3.3.2. Content-Length
  # A server MUST NOT send a Content-Length header field in any response
  # with a status code of 1xx (Informational) or 204 (No Content).  A
  # server MUST NOT send a Content-Length header field in any 2xx
  # (Successful) response to a CONNECT request (Section 4.3.6 of
  # [RFC7231]).
  if ((request.meth == MethodConnect and
      (header.code >= 200 and header.code < 300))) or
     ((header.code >= 100 and header.code < 200) or header.code == 204)
    if "Content-Length" in header:
      return false
  return true

proc request(conn: HttpConnection,
             request: HttpRequest,
             timeout: Duration): Future[HttpResponse] {.async.} =
  if conn.state != HttpState.Ready:
    raise newException(AssertionError, "Connection is not yet ready!")

  var buffer = newSeq[byte](HttpMaxHeadersSize)
  try:
    conn.state = HttpState.RequestSending
    await conn.stream.writer.send(request)
  except AsyncStreamWriteError:
    var exc = newException(HttpNetworkError,
                           "Network error or remote peer disconnected")
    conn.error = exc
    conn.state = HttpState.Error
    raise exc

  conn.state = HttpState.RequestSent
  try:
    var readfut = conn.stream.reader.readUntil(addr buffer[0],
                                               HttpMaxHeadersSize,
                                               HttpHeadersMark)
    var res = await withTimeout(readfut, timeout)
    if not(res):
      var exc = newException(HttpTimeoutError,
                             "Timeout exceeded while receiving headers")
      conn.error = exc
      conn.state = HttpState.Error
      raise exc
    else:
      var length = readfut.read()
      buffer.setLen(length)
      result = new HttpResponse
      result.headers = buffer.parseResponse()

      if not result.headers.validate(request):
        var exc = newException(HttpProtocolError, "Incorrect HTTP headers")
        conn.error = exc
        conn.state = HttpState.Error
        raise exc

      result.code = result.headers.code
      result.version = result.headers.version
      result.reason = result.headers.reason()
      result.stream = conn.stream
      result.conn = conn
      result.request = request
      conn.state = HttpState.HeadersReceived

  except AsyncStreamIncompleteError:
    var exc = newException(HttpNetworkError,
                           "Network error or remote peer disconnected")
    conn.error = exc
    conn.state = HttpState.Error
    raise exc
  except AsyncStreamLimitError:
    var exc = newException(HttpBreachProtocolError,
                           "Response headers size limit reached")
    conn.error = exc
    conn.state = HttpState.Error
    raise exc
  except AsyncStreamReadError:
    var exc = newException(HttpNetworkError,
                           "Network error or remote peer disconnected")
    conn.error = exc
    conn.state = HttpState.Error
    raise exc

proc processRedirection(session: HttpSession, req: HttpRequest,
                        resp: HttpResponse, redirections: var seq[Uri]): bool =
  ## Processes 3xx response codes and returns ``true`` if reconnection is needed
  ## or ``false`` if reconnection is not needed.
  ##
  ## If error happens ``false`` will be returned and fill error in connection
  ## ``s.conn``
  case resp.code
  of 301, 302, 307, 308:
    discard
  of 303:
    req.meth = MethodGet
  else:
    var exc = newException(HttpNoSupportError,
                           "Response code is not supported")
    session.conn.state = HttpState.Error
    session.conn.error = exc
    return false

  if "Location" notin resp.headers:
    var exc = newException(HttpProtocolError,
                           "Location header expected!")
    session.conn.state = HttpState.Error
    session.conn.error = exc
    return false

  var location = parseUri(resp.headers["Location"])
  if not(location.isAbsolute()):
    location = combine(req.url, location)

  for item in redirections:
    if location == item:
      var exc = newException(HttpBreachProtocolError,
                             "HTTP redirection recursion detected")
      session.conn.state = HttpState.Error
      session.conn.error = exc
      return false

  redirections.add(location)

  if len(redirections) >= session.maxRedirections:
    var exc = newException(HttpProtocolError,
                           "Maximum amount of redirections reached")
    session.conn.state = HttpState.Error
    session.conn.error = exc
    return false

  if (location.scheme == req.url.scheme) or
     (location.hostname == req.url.hostname) or
     (location.port == req.url.port):
    result = false
  else:
    result = true
  req.url = location

proc connect*(request: HttpRequest,
              timeout: Duration): Future[HttpConnection] {.async.} =
  ## Establish connection with request's hostname and return HttpConnection
  ## instance.
  var
    addresses: seq[TransportAddress]
    port = 0

  result = new HttpConnection

  if request.url.scheme.toLowerAscii() == "http":
    port = 80
  elif request.url.scheme.toLowerAscii() == "https":
    # port = 443
    result.error = newException(HttpNoSupportError,
                             "HTTPS connection is not yet supported!")
    result.state = HttpState.Error
    return

  if len(request.url.port) > 0:
    try:
      port = parseInt(request.url.port)
    except OverflowError:
      result.error = newException(HttpIncorrectUrlError,
                                  "Incorrect URL port number")
      result.state = HttpState.Error
      return
    if port <= 0 or port > 65535:
      result.error = newException(HttpIncorrectUrlError,
                                  "Incorrect URL port number")
      result.state = HttpState.Error
      return

  result.state = HttpState.Resolving

  try:
    addresses = resolveTAddress(request.url.hostname, Port(port))
  except:
    discard

  if len(addresses) == 0:
    result.error = newException(HttpResolveHostError,
                                "Could not resolve URL hostname")
    result.state = HttpState.Error
    return

  result.state = HttpState.Connecting
  for host in addresses:
    var confut = connect(host)
    var res = await withTimeout(confut, timeout)
    if not(res):
      result.error = newException(HttpTimeoutError,
                                  "Timeout exceeded while connecting")
      result.state = HttpState.Error
      return
    else:
      if not(confut.failed()):
        result.transp = confut.read()
        result.state = HttpState.Ready
        var reader = newAsyncStreamReader(result.transp)
        var writer = newAsyncStreamWriter(result.transp)
        result.stream = AsyncStream(reader: reader, writer: writer)
        break

  if result.state != HttpState.Ready:
    result.state = HttpState.Error
    result.error = newException(HttpConnectionFailedError,
                                "Could not establish connection to host")

proc close*(conn: HttpConnection) {.async.} =
  ## Closes connection ``conn``.
  if conn.state != HttpState.Closed:
    if not isNil(conn.bstream):
      await closeWait(conn.bstream)
    await closeWait(conn.stream.writer)
    await closeWait(conn.stream.reader)
    await closeWait(conn.transp)
    conn.state = HttpState.Closed

proc close*(session: HttpSession) {.async.} =
  ## Closes session ``session``.
  await session.conn.close()

proc request*(stream: AsyncStream,
              req: HttpRequest,
              timeout = HttpHeadersTimeout): Future[HttpResponse] =
  var conn = HttpConnection(s: HttpState.Ready, stream: stream)
  result = conn.request(req, timeout)

proc getBodyStream*(resp: HttpResponse): AsyncStreamReader =
  ## Returns stream for HTTP response body ``resp``.
  if resp.version in {HttpVersion11, HttpVersion20}:
    if "chunked" in resp.headers["Transfer-Encoding"].toLowerAscii():
      result = newChunkedStreamReader(resp.stream.reader)
  if isNil(result):
    result = newAsyncStreamReader(resp.stream.reader)
  resp.conn.bstream = result

proc getBody*(resp: HttpResponse): Future[seq[byte]] {.async.} =
  ## Get body of HTTP response ``resp``.
  var untileof = false
  var length: int
  if resp.version in {HttpVersion11, HttpVersion20}:
    if "chunked" in resp.headers["Transfer-Encoding"].toLowerAscii():
      untileof = true
    else:
      if "Content-Length" notin resp.headers:
        untileof = true
      else:
        length = resp.headers.contentLength()
  elif resp.version in {HttpVersion10, HttpVersion09}:
    if "Content-Length" notin resp.headers:
      if resp.request.meth != MethodHead:
        untileof = true
      else:
        # This branch must not be happens, because of validate().
        discard
    else:
      length = resp.headers.contentLength()

  if untileof or length > 0:
    var n = if untileof: -1 else: length
    var stream = resp.getBodyStream()
    try:
      result = await stream.read(n)
      resp.conn.state = HttpState.BodyReceived
      await stream.closeWait()
    except AsyncStreamReadError:
      var exc = newException(HttpNetworkError,
                             "Network error or remote peer disconnected")
      resp.conn.error = exc
      resp.conn.state = HttpState.Error
      await stream.closeWait()
      raise exc
  else:
    resp.conn.state = HttpState.BodyReceived
    result = newSeq[byte]()

proc consumeBody*(resp: HttpResponse) {.async.} =
  ## Consume body of HTTP response ``resp``.
  var untileof = false
  var length: int
  if resp.version in {HttpVersion11, HttpVersion20}:
    if "chunked" in resp.headers["Transfer-Encoding"].toLowerAscii():
      untileof = true
    else:
      if "Content-Length" notin resp.headers:
        untileof = true
      else:
        length = resp.headers.contentLength()
  elif resp.version in {HttpVersion10, HttpVersion09}:
    if "Content-Length" notin resp.headers:
      if resp.request.meth != MethodHead:
        untileof = true
      else:
        # This branch must not be happens, because of validate().
        discard
    else:
      length = resp.headers.contentLength()
  if untileof or length > 0:
    var n = if untileof: -1 else: length
    var stream = resp.getBodyStream()
    try:
      discard await stream.consume(n)
      resp.conn.state = HttpState.BodyReceived
      await stream.closeWait()
    except AsyncStreamReadError:
      var exc = newException(HttpNetworkError,
                             "Network error or remote peer disconnected")
      resp.conn.error = exc
      resp.conn.state = HttpState.Error
      await stream.closeWait()
      raise exc
  else:
    resp.conn.state = HttpState.BodyReceived

proc `==`*(a, b: Uri): bool =
  ## Returns ``true`` if ``a`` and ``b`` are equal.
  result = (a.scheme == b.scheme) and
           (a.username == b.username) and
           (a.password == b.password) and
           (a.hostname == b.hostname) and
           (a.port == b.port) and
           (a.path == b.path) and
           (a.query == b.query)

proc request*(session: HttpSession,
              req: HttpRequest): Future[HttpResponse] {.async.} =
  ## Perform HTTP request ``req`` using session ``session``.
  var redirections = newSeq[Uri]()
  while true:
    if session.conn.state in {HttpState.Ready, HttpState.BodyReceived}:
      ## Connection is present
      if session.conn.state == HttpState.BodyReceived:
        ## Here we checking detached stream to be properly read
        if not(isNil(session.conn.bstream)):
          if session.conn.bstream.closed():
            session.conn.bstream = nil
          else:
            raise newException(AssertionError, "Connection is not yet ready")
        session.conn.state = HttpState.Ready

      if (session.conn.lastreq.url.scheme != req.url.scheme) or
         (session.conn.lastreq.url.hostname != req.url.hostname) or
         (session.conn.lastreq.url.port != req.url.port):
        await session.conn.close()
        session.conn = await req.connect(session.connectTimeout)
        if session.conn.state == HttpState.Error:
          raise session.conn.error
    elif session.conn.state == HttpState.Closed:
      ## Connection is not yet established
      session.conn = await req.connect(session.connectTimeout)
      if session.conn.state == HttpState.Error:
        raise session.conn.error
    elif session.conn.state == HttpState.Error:
      ## Connection has an error.
      raise session.conn.error
    else:
      raise newException(AssertionError, "Connection is not yet ready")

    var reconnectNeeded = false
    var resp = await session.conn.request(req, session.headersTimeout)
    session.conn.lastreq = req
    if (resp.code >= 300) and (resp.code < 400):
      let res = processRedirection(session, req, resp, redirections)
      if not res:
        if session.conn.state == HttpState.Error:
          raise session.conn.error
      else:
        reconnectNeeded = true
      await resp.consumeBody()
    else:
      result = resp
      break

    if reconnectNeeded or
       (resp.version in {HttpVersion09, HttpVersion10}) or
       resp.headers["Connection"].toLowerAscii() == "close":
      await session.conn.close()

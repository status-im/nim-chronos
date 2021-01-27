#
#        Chronos HTTP/S server implementation
#             (c) Copyright 2019-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)
import std/[tables, options, uri, strutils]
import stew/results, httputils
import ../../asyncloop, ../../asyncsync
import ../../streams/[asyncstream, boundstream, chunkstream]
import httptable, httpcommon
export httpcommon

when defined(useChroniclesLogging):
  echo "Importing chronicles"
  import chronicles

type
  HttpServerFlags* = enum
    Secure

  TransferEncodingFlags* {.pure.} = enum
    Identity, Chunked, Compress, Deflate, Gzip

  ContentEncodingFlags* {.pure.} = enum
    Identity, Br, Compress, Deflate, Gzip

  HttpRequestFlags* {.pure.} = enum
    BoundBody, UnboundBody, MultipartForm, UrlencodedForm

  HttpServer* = ref object of RootRef
    instance*: StreamServer
    # semaphore*: AsyncSemaphore
    maxConnections*: int
    baseUri*: Uri
    flags*: set[HttpServerFlags]
    connections*: Table[string, Future[void]]
    acceptLoop*: Future[void]
    lifetime*: Future[void]
    headersTimeout: Duration
    bodyTimeout: Duration
    maxHeadersSize: int
    maxRequestBodySize: int

  HttpServerState* = enum
    ServerRunning, ServerStopped, ServerClosed

  HttpRequest* = object
    headersTable: HttpTable
    queryTable: HttpTable
    postTable: HttpTable
    rawPath*: string
    rawQuery*: string
    uri*: Uri
    scheme*: string
    version*: HttpVersion
    meth*: HttpMethod
    contentEncoding*: set[ContentEncodingFlags]
    transferEncoding*: set[TransferEncodingFlags]
    requestFlags*: set[HttpRequestFlags]
    contentLength: int
    connection*: HttpConnection
    mainReader*: AsyncStreamReader

  HttpConnection* = ref object of RootRef
    server: HttpServer
    transp: StreamTransport
    buffer: seq[byte]

const
  HeadersMark = @[byte(0x0D), byte(0x0A), byte(0x0D), byte(0x0A)]

proc new*(htype: typedesc[HttpServer],
          address: TransportAddress,
          flags: set[HttpServerFlags] = {},
          serverUri = Uri(),
          maxConnections: int = -1,
          bufferSize: int = 4096,
          backlogSize: int = 100,
          httpHeadersTimeout = 10.seconds,
          httpBodyTimeout = 30.seconds,
          maxHeadersSize: int = 8192,
          maxRequestBodySize: int = 1_048_576): HttpResult[HttpServer] =
  var res = HttpServer(
    maxConnections: maxConnections,
    headersTimeout: httpHeadersTimeout,
    bodyTimeout: httpBodyTimeout,
    maxHeadersSize: maxHeadersSize,
    maxRequestBodySize: maxRequestBodySize
  )

  res.baseUri =
    if len(serverUri.hostname) > 0 and isAbsolute(serverUri):
      serverUri
    else:
      if HttpServerFlags.Secure in flags:
        parseUri("https://" & $address & "/")
      else:
        parseUri("http://" & $address & "/")

  try:
    res.instance = createStreamServer(address, flags = {ReuseAddr},
                                      bufferSize = bufferSize,
                                      backlog = backlogSize)
    # if maxConnections > 0:
    #   res.semaphore = newAsyncSemaphore(maxConnections)
    res.lifetime = newFuture[void]("http.server.lifetime")
    res.connections = initTable[string, Future[void]]()
    return ok(res)
  except TransportOsError as exc:
    return err(exc.msg)
  except CatchableError as exc:
    return err(exc.msg)

proc getId(transp: StreamTransport): string {.inline.} =
  ## Returns string unique transport's identifier as string.
  $transp.remoteAddress() & "_" & $transp.localAddress()

proc newHttpCriticalFailure*(msg: string): ref HttpCriticalFailure =
  newException(HttpCriticalFailure, msg)

proc newHttpRecoverableFailure*(msg: string): ref HttpRecoverableFailure =
  newException(HttpRecoverableFailure, msg)

iterator queryParams(query: string): tuple[key: string, value: string] =
  for pair in query.split('&'):
    let items = pair.split('=', maxsplit = 1)
    let k = items[0]
    let v = if len(items) > 1: items[1] else: ""
    yield (decodeUrl(k), decodeUrl(v))

func getMultipartBoundary*(contentType: string): HttpResult[string] =
  let mparts = contentType.split(";")
  if strip(mparts[0]).toLowerAscii() != "multipart/form-data":
    return err("Content-Type is not multipart")
  if len(mparts) < 2:
    return err("Content-Type missing boundary value")
  let stripped = strip(mparts[1])
  if not(stripped.toLowerAscii().startsWith("boundary")):
    return err("Incorrect Content-Type boundary format")
  let bparts = stripped.split("=")
  if len(bparts) < 2:
    err("Missing Content-Type boundary")
  else:
    ok(strip(bparts[1]))

func getContentType*(contentHeader: seq[string]): HttpResult[string] =
  if len(contentHeader) > 1:
    return err("Multiple Content-Type values found")
  let mparts = contentHeader[0].split(";")
  ok(strip(mparts[0]).toLowerAscii())

func getTransferEncoding(contentHeader: seq[string]): HttpResult[
                                                   set[TransferEncodingFlags]] =
  var res: set[TransferEncodingFlags] = {}
  if len(contentHeader) == 0:
    res.incl(TransferEncodingFlags.Identity)
    ok(res)
  else:
    for header in contentHeader:
      for item in header.split(","):
        case strip(item.toLowerAscii())
        of "identity":
          res.incl(TransferEncodingFlags.Identity)
        of "chunked":
          res.incl(TransferEncodingFlags.Chunked)
        of "compress":
          res.incl(TransferEncodingFlags.Compress)
        of "deflate":
          res.incl(TransferEncodingFlags.Deflate)
        of "gzip":
          res.incl(TransferEncodingFlags.Gzip)
        of "":
          res.incl(TransferEncodingFlags.Identity)
        else:
          return err("Incorrect Transfer-Encoding value")
    ok(res)

func getContentEncoding(contentHeader: seq[string]): HttpResult[
                                                    set[ContentEncodingFlags]] =
  var res: set[ContentEncodingFlags] = {}
  if len(contentHeader) == 0:
    res.incl(ContentEncodingFlags.Identity)
    ok(res)
  else:
    for header in contentHeader:
      for item in header.split(","):
        case strip(item.toLowerAscii()):
        of "identity":
          res.incl(ContentEncodingFlags.Identity)
        of "br":
          res.incl(ContentEncodingFlags.Br)
        of "compress":
          res.incl(ContentEncodingFlags.Compress)
        of "deflate":
          res.incl(ContentEncodingFlags.Deflate)
        of "gzip":
          res.incl(ContentEncodingFlags.Gzip)
        of "":
          res.incl(ContentEncodingFlags.Identity)
        else:
          return err("Incorrect Content-Encoding value")
    ok(res)

proc hasBody*(request: HttpRequest): bool =
  ## Returns ``true`` if request has body.
  request.requestFlags * {HttpRequestFlags.BoundBody,
                          HttpRequestFlags.UnboundBody} != {}

proc prepareRequest(conn: HttpConnection,
                    req: HttpRequestHeader): HttpResultCode[HttpRequest] =
  var request = HttpRequest()

  if req.version notin {HttpVersion10, HttpVersion11}:
    return err(Http505)

  request.version = req.version
  request.meth = req.meth

  request.rawPath =
    block:
      let res = req.uri()
      if len(res) == 0:
        return err(Http400)
      res

  request.uri =
    if request.rawPath != "*":
      let uri = parseUri(request.rawPath)
      if uri.scheme notin ["http", "https", ""]:
        return err(Http400)
      uri
    else:
      var uri = initUri()
      uri.path = "*"
      uri

  request.queryTable =
    block:
      var table = HttpTable.init()
      for key, value in queryParams(request.uri.query):
        table.add(key, value)
      table

  request.headersTable =
    block:
      var table = HttpTable.init()
      # Retrieve headers and values
      for key, value in req.headers():
        table.add(key, value)
      # Validating HTTP request headers
      # Some of the headers must be present only once.
      if table.count("content-type") > 1:
        return err(Http400)
      if table.count("content-length") > 1:
        return err(Http400)
      if table.count("transfer-encoding") > 1:
        return err(Http400)
      table

  # Preprocessing "Content-Encoding" header.
  request.contentEncoding =
    block:
      let res = getContentEncoding(
                  request.headersTable.getList("content-encoding"))
      if res.isErr():
        return err(Http400)
      else:
        res.get()

  # Preprocessing "Transfer-Encoding" header.
  request.transferEncoding =
    block:
      let res = getTransferEncoding(
                  request.headersTable.getList("transfer-encoding"))
      if res.isErr():
        return err(Http400)
      else:
        res.get()

  # Almost all HTTP requests could have body (except TRACE), we perform some
  # steps to reveal information about body.
  if "content-length" in request.headersTable:
    let length = request.headersTable.getInt("content-length")
    if length > 0:
      if request.meth == MethodTrace:
        return err(Http400)
      if length > uint64(high(int)):
        return err(Http413)
      if length > uint64(conn.server.maxRequestBodySize):
        return err(Http413)
      request.contentLength = int(length)
      request.requestFlags.incl(HttpRequestFlags.BoundBody)
  else:
    if TransferEncodingFlags.Chunked in request.transferEncoding:
      if request.meth == MethodTrace:
        return err(Http400)
      request.requestFlags.incl(HttpRequestFlags.UnboundBody)

  if request.hasBody():
    # If request has body, we going to understand how its encoded.
    const
      UrlEncodedType = "application/x-www-form-urlencoded"
      MultipartType = "multipart/form-data"

    if "content-type" in request.headersTable:
      let contentType = request.headersTable.getString("content-type")
      let tmp = strip(contentType).toLowerAscii()
      if tmp.startsWith(UrlEncodedType):
        request.requestFlags.incl(UrlencodedForm)
      elif tmp.startsWith(MultipartType):
        request.requestFlags.incl(MultipartForm)

  request.mainReader = newAsyncStreamReader(conn.transp)
  ok(request)

proc getBodyStream*(request: HttpRequest): HttpResult[AsyncStreamReader] =
  if HttpRequestFlags.BoundBody in request.requestFlags:
    ok(newBoundedStreamReader(request.mainReader, request.contentLength))
  elif HttpRequestFlags.UnboundBody in request.requestFlags:
    ok(newChunkedStreamReader(request.mainReader))
  else:
    err("Request do not have body available")

proc getBody*(request: HttpRequest): Future[seq[byte]] {.async.} =
  ## Obtain request's body as sequence of bytes.
  let res = request.getBodyStream()
  if res.isErr():
    return @[]
  else:
    try:
      return await read(res.get())
    except AsyncStreamError:
      raise newHttpCriticalFailure("Read failure")

proc consumeBody*(request: HttpRequest): Future[void] {.async.} =
  ## Consume/discard request's body.
  let res = request.getBodyStream()
  if res.isErr():
    return
  else:
    let reader = res.get()
    try:
      discard await reader.consume()
      return
    except AsyncStreamError:
      raise newHttpCriticalFailure("Read failure")

proc sendErrorResponse(conn: HttpConnection, version: HttpVersion,
                       code: HttpCode, keepAlive = true,
                       datatype = "text/text",
                       databody = ""): Future[bool] {.async.} =
  var answer = $version & " " & $code & "\r\n"
  answer.add("Date: " & httpDate() & "\r\n")
  if len(databody) > 0:
    answer.add("Content-Type: " & datatype & "\r\n")
  answer.add("Content-Length: " & $len(databody) & "\r\n")
  if keepAlive:
    answer.add("Connection: keep-alive\r\n")
  else:
    answer.add("Connection: close\r\n")
  answer.add("\r\n")
  if len(databody) > 0:
    answer.add(databody)
  try:
    let res {.used.} = await conn.transp.write(answer)
    return true
  except CancelledError:
    return false
  except TransportOsError:
    return false
  except CatchableError:
    return false

proc sendErrorResponse(request: HttpRequest, code: HttpCode, keepAlive = true,
                       datatype = "text/text",
                       databody = ""): Future[bool] =
  sendErrorResponse(request.connection, request.version, code, keepAlive,
                    datatype, databody)

proc getRequest*(conn: HttpConnection): Future[HttpRequest] {.async.} =
  when defined(useChroniclesLogging):
    logScope:
      peer = $conn.transp.remoteAddress

  try:
    conn.buffer.setLen(conn.server.maxHeadersSize)
    let res = await conn.transp.readUntil(addr conn.buffer[0], len(conn.buffer),
                                          HeadersMark)
    conn.buffer.setLen(res)
    let header = parseRequest(conn.buffer)
    if header.failed():
      log debug "Malformed header received"
      discard await conn.sendErrorResponse(HttpVersion11, Http400, false)
      raise newHttpCriticalFailure("Malformed request recieved")
    else:
      let res = prepareRequest(conn, header)
      if res.isErr():
        discard await conn.sendErrorResponse(HttpVersion11, Http400, false)
        raise newHttpCriticalFailure("Invalid request received")
      else:
        return res.get()
  except TransportOsError:
    log debug "Unexpected OS error"
    raise newHttpCriticalFailure("Unexpected OS error")
  except TransportIncompleteError:
    log debug "Remote peer disconnected"
    raise newHttpCriticalFailure("Remote peer disconnected")
  except TransportLimitError:
    log debug "Maximum size of request headers reached"
    discard await conn.sendErrorResponse(HttpVersion11, Http413, false)
    raise newHttpCriticalFailure("Maximum size of request headers reached")

proc processLoop(server: HttpServer, transp: StreamTransport) {.async.} =
  when defined(useChroniclesLogging):
    logScope:
      peer = $transp.remoteAddress

  var conn = HttpConnection(
    transp: transp, buffer: newSeq[byte](server.maxHeadersSize),
    server: server
  )

  log info "Client connected"
  var breakLoop = false
  while true:
    try:
      let request = await conn.getRequest().wait(server.headersTimeout)
      echo "== HEADERS TABLE"
      echo request.headersTable
      echo "== QUERY TABLE"
      echo request.queryTable
      echo "== TRANSFER ENCODING ", request.transferEncoding
      echo "== CONTENT ENCODING ", request.contentEncoding
      echo "== REQUEST FLAGS ", request.requestFlags
      var stream = await request.getBody()
      echo cast[string](stream)
      discard await conn.sendErrorResponse(HttpVersion11, Http200, true,
                                           databody = "OK")
      log debug "Response sent"
    except AsyncTimeoutError:
      log debug "Timeout reached while reading headers"
      discard await conn.sendErrorResponse(HttpVersion11, Http408, false)
      breakLoop = true

    except CancelledError:
      breakLoop = true

    except HttpRecoverableFailure:
      breakLoop = false

    except HttpCriticalFailure:
      breakLoop = true

    except CatchableError as exc:
      echo "CatchableError received ", exc.name

    if breakLoop:
      break

  await transp.closeWait()
  server.connections.del(transp.getId())
  # if server.maxConnections > 0:
  #   server.semaphore.release()
  log info "Client got disconnected"

proc acceptClientLoop(server: HttpServer) {.async.} =
  var breakLoop = false
  while true:
    try:
      # if server.maxConnections > 0:
      #   await server.semaphore.acquire()

      let transp = await server.instance.accept()
      server.connections[transp.getId()] = processLoop(server, transp)

    except CancelledError:
      # Server was stopped
      breakLoop = true
    except TransportOsError:
      # This is some critical unrecoverable error.
      breakLoop = true
    except TransportTooManyError:
      # Non critical error
      breakLoop = false
    except CatchableError:
      # Unexpected error
      breakLoop = true
      discard

    if breakLoop:
      break

proc state*(server: HttpServer): HttpServerState =
  ## Returns current HTTP server's state.
  if server.lifetime.finished():
    ServerClosed
  else:
    if isNil(server.acceptLoop):
      ServerStopped
    else:
      if server.acceptLoop.finished():
        ServerStopped
      else:
        ServerRunning

proc start*(server: HttpServer) =
  ## Starts HTTP server.
  if server.state == ServerStopped:
    server.acceptLoop = acceptClientLoop(server)

proc stop*(server: HttpServer) {.async.} =
  ## Stop HTTP server from accepting new connections.
  if server.state == ServerRunning:
    await server.acceptLoop.cancelAndWait()

proc drop*(server: HttpServer) {.async.} =
  ## Drop all pending HTTP connections.
  if server.state in {ServerStopped, ServerRunning}:
    discard

proc close*(server: HttpServer) {.async.} =
  ## Stop HTTP server and drop all the pending connections.
  if server.state != ServerClosed:
    await server.stop()
    await server.drop()
    await server.instance.closeWait()
    server.lifetime.complete()

proc join*(server: HttpServer): Future[void] =
  ## Wait until HTTP server will not be closed.
  var retFuture = newFuture[void]("http.server.join")

  proc continuation(udata: pointer) {.gcsafe.} =
    if not(retFuture.finished()):
      retFuture.complete()

  proc cancellation(udata: pointer) {.gcsafe.} =
    if not(retFuture.finished()):
      server.lifetime.removeCallback(continuation, cast[pointer](retFuture))

  if server.state == ServerClosed:
    retFuture.complete()
  else:
    server.lifetime.addCallback(continuation, cast[pointer](retFuture))
    retFuture.cancelCallback = cancellation

  retFuture

when isMainModule:
  let res = HttpServer.new(initTAddress("127.0.0.1:30080"), maxConnections = 1)
  if res.isOk():
    let server = res.get()
    server.start()
    echo "HTTP server was started"
    waitFor server.join()
  else:
    echo "Failed to start server: ", res.error

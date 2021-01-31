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
import httptable, httpcommon, multipart
export httpcommon, multipart

when defined(useChroniclesLogging):
  echo "Importing chronicles"
  import chronicles

type
  HttpServerFlags* {.pure.} = enum
    Secure, NoExpectHandler

  HttpStatus* = enum
    DropConnection, KeepConnection

  HTTPServerError* {.pure.} = enum
    TimeoutError, CatchableError, RecoverableError, CriticalError

  HttpProcessError* = object
    error*: HTTPServerError
    exc*: ref CatchableError
    remote*: TransportAddress

  RequestFence*[T] = Result[T, HttpProcessError]

  HttpRequestFlags* {.pure.} = enum
    BoundBody, UnboundBody, MultipartForm, UrlencodedForm,
    ClientExpect

  HttpResponseFlags* {.pure.} = enum
    Prepared, DataSent, DataSending, KeepAlive

  HttpProcessCallback* =
    proc(req: RequestFence[HttpRequest]): Future[HttpStatus] {.gcsafe.}

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
    processCallback: HttpProcessCallback

  HttpServerState* = enum
    ServerRunning, ServerStopped, ServerClosed

  HttpRequest* = ref object of RootRef
    headersTable: HttpTable
    queryTable: HttpTable
    postTable: Option[HttpTable]
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
    mainWriter*: AsyncStreamWriter
    response*: Option[HttpResponse]

  HttpResponse* = ref object of RootRef
    status*: HttpCode
    version*: HttpVersion
    headersTable: HttpTable
    body*: seq[byte]
    responseFlags*: set[HttpResponseFlags]
    connection*: HttpConnection
    mainWriter: AsyncStreamWriter

  HttpConnection* = ref object of RootRef
    server*: HttpServer
    transp: StreamTransport
    buffer: seq[byte]

proc init(htype: typedesc[HttpProcessError], error: HTTPServerError,
          exc: ref CatchableError,
          remote: TransportAddress): HttpProcessError =
  HttpProcessError(error: error, exc: exc, remote: remote)

proc new*(htype: typedesc[HttpResponse], req: HttpRequest): HttpResponse =
  HttpResponse(
    status: Http200,
    version: req.version,
    headersTable: HttpTable.init(),
    connection: req.connection,
    mainWriter: req.mainWriter
  )

proc new*(htype: typedesc[HttpServer],
          address: TransportAddress,
          processCallback: HttpProcessCallback,
          serverFlags: set[HttpServerFlags] = {},
          socketFlags: set[ServerFlags] = {ReuseAddr},
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
    maxRequestBodySize: maxRequestBodySize,
    processCallback: processCallback,
    flags: serverFlags
  )

  res.baseUri =
    if len(serverUri.hostname) > 0 and isAbsolute(serverUri):
      serverUri
    else:
      if HttpServerFlags.Secure in serverFlags:
        parseUri("https://" & $address & "/")
      else:
        parseUri("http://" & $address & "/")

  try:
    res.instance = createStreamServer(address, flags = socketFlags,
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

proc hasBody*(request: HttpRequest): bool =
  ## Returns ``true`` if request has body.
  request.requestFlags * {HttpRequestFlags.BoundBody,
                          HttpRequestFlags.UnboundBody} != {}

proc prepareRequest(conn: HttpConnection,
                    req: HttpRequestHeader): HttpResultCode[HttpRequest] =
  var request = HttpRequest(connection: conn)

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
        request.requestFlags.incl(HttpRequestFlags.UrlencodedForm)
      elif tmp.startsWith(MultipartType):
        request.requestFlags.incl(HttpRequestFlags.MultipartForm)

    if "expect" in request.headersTable:
      let expectHeader = request.headersTable.getString("expect")
      if strip(expectHeader).toLowerAscii() == "100-continue":
        request.requestFlags.incl(HttpRequestFlags.ClientExpect)

  request.mainReader = newAsyncStreamReader(conn.transp)
  request.mainWriter = newAsyncStreamWriter(conn.transp)
  ok(request)

proc clear*(request: HttpRequest) {.async.} =
  await allFutures(
    request.mainReader.closeWait(),
    request.mainWriter.closeWait(),
  )

proc getBodyStream*(request: HttpRequest): HttpResult[AsyncStreamReader] =
  ## Returns stream's reader instance which can be used to read request's body.
  ##
  ## Please be sure to handle ``Expect`` header properly.
  if HttpRequestFlags.BoundBody in request.requestFlags:
    ok(newBoundedStreamReader(request.mainReader, request.contentLength))
  elif HttpRequestFlags.UnboundBody in request.requestFlags:
    ok(newChunkedStreamReader(request.mainReader))
  else:
    err("Request do not have body available")

proc handleExpect*(request: HttpRequest) {.async.} =
  ## Handle expectation for ``Expect`` header.
  ## https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Expect
  if HttpServerFlags.NoExpectHandler notin request.connection.server.flags:
    if HttpRequestFlags.ClientExpect in request.requestFlags:
      if request.version == HttpVersion11:
        try:
          let message = $request.version & " " & $Http100 & "\r\n\r\n"
          await request.mainWriter.write(message)
        except CancelledError as exc:
          raise exc
        except AsyncStreamWriteError, AsyncStreamIncompleteError:
          raise newHttpCriticalError("Unable to send `100-continue` response")

proc getBody*(request: HttpRequest): Future[seq[byte]] {.async.} =
  ## Obtain request's body as sequence of bytes.
  let res = request.getBodyStream()
  if res.isErr():
    return @[]
  else:
    try:
      await request.handleExpect()
      return await read(res.get())
    except AsyncStreamError:
      raise newHttpCriticalError("Unable to read request's body")

proc consumeBody*(request: HttpRequest): Future[void] {.async.} =
  ## Consume/discard request's body.
  let res = request.getBodyStream()
  if res.isErr():
    return
  else:
    let reader = res.get()
    try:
      await request.handleExpect()
      discard await reader.consume()
      return
    except AsyncStreamError:
      raise newHttpCriticalError("Unable to consume request's body")

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

proc sendErrorResponse*(request: HttpRequest, code: HttpCode, keepAlive = true,
                        datatype = "text/text",
                        databody = ""): Future[bool] =
  sendErrorResponse(request.connection, request.version, code, keepAlive,
                    datatype, databody)

proc getRequest*(conn: HttpConnection): Future[HttpRequest] {.async.} =
  try:
    conn.buffer.setLen(conn.server.maxHeadersSize)
    let res = await conn.transp.readUntil(addr conn.buffer[0], len(conn.buffer),
                                          HeadersMark)
    conn.buffer.setLen(res)
    let header = parseRequest(conn.buffer)
    if header.failed():
      discard await conn.sendErrorResponse(HttpVersion11, Http400, false)
      raise newHttpCriticalError("Malformed request recieved")
    else:
      let res = prepareRequest(conn, header)
      if res.isErr():
        discard await conn.sendErrorResponse(HttpVersion11, Http400, false)
        raise newHttpCriticalError("Invalid request received")
      else:
        return res.get()
  except TransportOsError:
    raise newHttpCriticalError("Unexpected OS error")
  except TransportIncompleteError:
    raise newHttpCriticalError("Remote peer disconnected")
  except TransportLimitError:
    discard await conn.sendErrorResponse(HttpVersion11, Http413, false)
    raise newHttpCriticalError("Maximum size of request headers reached")

proc processLoop(server: HttpServer, transp: StreamTransport) {.async.} =
  var conn = HttpConnection(
    transp: transp, buffer: newSeq[byte](server.maxHeadersSize),
    server: server
  )

  var breakLoop = false
  while true:
    var
      arg: RequestFence[HttpRequest]
      resp = HttpStatus.DropConnection

    try:
      let request = await conn.getRequest().wait(server.headersTimeout)
      arg = RequestFence[HttpRequest].ok(request)
    except CancelledError:
      breakLoop = true
    except AsyncTimeoutError as exc:
      let error = HttpProcessError.init(HTTPServerError.TimeoutError, exc,
                                        transp.remoteAddress())
      arg = RequestFence[HttpRequest].err(error)
    except HttpRecoverableError as exc:
      let error = HttpProcessError.init(HTTPServerError.RecoverableError, exc,
                                        transp.remoteAddress())
      arg = RequestFence[HttpRequest].err(error)
    except HttpCriticalError as exc:
      let error = HttpProcessError.init(HTTPServerError.CriticalError, exc,
                                        transp.remoteAddress())
      arg = RequestFence[HttpRequest].err(error)
    except CatchableError as exc:
      let error = HttpProcessError.init(HTTPServerError.CatchableError, exc,
                                        transp.remoteAddress())
      arg = RequestFence[HttpRequest].err(error)

    if breakLoop:
      break

    breakLoop = false
    var lastError: ref CatchableError

    try:
      resp = await conn.server.processCallback(arg)
    except CancelledError:
      breakLoop = true
    except CatchableError as exc:
      resp = DropConnection
      echo "Exception received from processor callback ", exc.name
      lastError = exc

    if breakLoop:
      break

    let keepConn =
      case resp
        of DropConnection:
          false
        of KeepConnection:
          false

    if arg.isErr():
      case arg.error().error
      of HTTPServerError.TimeoutError:
        discard await conn.sendErrorResponse(HttpVersion11, Http408, keepConn)
      of HTTPServerError.RecoverableError:
        discard await conn.sendErrorResponse(HttpVersion11, Http400, keepConn)
      of HTTPServerError.CriticalError:
        discard await conn.sendErrorResponse(HttpVersion11, Http400, keepConn)
      of HTTPServerError.CatchableError:
        discard await conn.sendErrorResponse(HttpVersion11, Http400, keepConn)
      if not(keepConn):
        break
    else:
      if isNil(lastError):
        echo "lastError = nil"
        echo "mainWriter.bytesCount = ", arg.get().mainWriter.bytesCount

        if arg.get().mainWriter.bytesCount == 0'u64:
          echo "Sending 404 keepConn = ", keepConn
          # Processor callback finished without an error, but response was not
          # sent to client, so we going to send HTTP404 error.
          discard await conn.sendErrorResponse(HttpVersion11, Http404, keepConn)
          echo "bytesCount = ", arg.get().mainWriter.bytesCount
      else:
        if arg.get().mainWriter.bytesCount == 0'u64:
          # Processor callback finished with an error, but response was not
          # sent to client, so we going to send HTTP503 error.
          discard await conn.sendErrorResponse(HttpVersion11, Http503, true)

      ## Perform cleanup of request instance
      await arg.get().clear()

      if not(keepConn):
        break

  await transp.closeWait()
  server.connections.del(transp.getId())
  # if server.maxConnections > 0:
  #   server.semaphore.release()

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

proc post*(req: HttpRequest): Future[HttpTable] {.async.} =
  ## Return POST parameters
  if req.postTable.isSome():
    return req.postTable.get()
  else:
    if req.meth notin PostMethods:
      return HttpTable.init()

    if UrlencodedForm in req.requestFlags:
      var table = HttpTable.init()
      # getBody() will handle `Expect`.
      var body = await req.getBody()
      ## TODO (cheatfate) double copy here.
      var strbody = newString(len(body))
      if len(body) > 0:
        copyMem(addr strbody[0], addr body[0], len(body))
      for key, value in queryParams(strbody):
        table.add(key, value)
      req.postTable = some(table)
      return table
    elif MultipartForm in req.requestFlags:
      let cres = getContentType(req.headersTable.getList("content-type"))
      if cres.isErr():
        raise newHttpCriticalError(cres.error)
      let bres = getMultipartBoundary(req.headersTable.getList("content-type"))
      if bres.isErr():
        raise newHttpCriticalError(bres.error)
      # We must handle `Expect`.
      await req.handleExpect()
      var reader = req.getBodyStream()
      if reader.isErr():
        raise newHttpCriticalError(reader.error)
      var mpreader = MultiPartReaderRef.new(reader.get(), bres.get())
      var table = HttpTable.init()
      var runLoop = true
      while runLoop:
        try:
          let res = await mpreader.readPart()
          var value = await res.getBody()
          ## TODO (cheatfate) double copy here.
          var strvalue = newString(len(value))
          if len(value) > 0:
            copyMem(addr strvalue[0], addr value[0], len(value))
          table.add(res.name, strvalue)
        except MultiPartEoM:
          runLoop = false
      req.postTable = some(table)
      return table
    else:
      if HttpRequestFlags.BoundBody in req.requestFlags:
        if req.contentLength != 0:
          raise newHttpCriticalError("Unsupported request body")
        return HttpTable.init()
      elif HttpRequestFlags.UnboundBody in req.requestFlags:
        raise newHttpCriticalError("Unsupported request body")

proc `keepalive=`*(resp: HttpResponse, value: bool) =
  if value:
    resp.responseFlags.incl(KeepAlive)
  else:
    resp.responseFlags.excl(KeepAlive)

proc keepalive*(resp: HttpResponse): bool =
  KeepAlive in resp.responseFlags

proc setHeader*(resp: HttpResponse, key, value: string) =
  resp.httpTable.set(key, value)

proc addHeader*(resp: HttpResponse, key, value: string) =
  resp.httpTable.add(key, value)

proc getHeader*(resp: HttpResponse, key: string): string =
  resp.httpTable.getString(key)

proc getHeaderOrDefault*(resp: HttpResponse, key: string,
                         default: string = ""): string =


proc sendBody*(resp: HttpResponse, pbytes: pointer, nbytes: int) {.async.} =
  resp.headersTable

proc sendBody*(resp: HttpResponse, data: string) {.async.}
  var answer = resp.version & " " & resp.status & "\r\n"
  answer.add("")
proc prepare*(resp: HttpResponse) {.async.} =
  discard

proc sendChunk*(resp: HttpResponse) {.async.} =
  discard

proc finish*(resp: HttpResponse) {.async.} =
  discard


when isMainModule:
  proc processCallback(req: RequestFence[HttpRequest]): Future[HttpStatus] {.
       async.} =
    if req.isOk():
      let request = req.get()
      echo "Got ", request.meth, " request"
      let post = await request.post()
      echo "post = ", post
    else:
      echo "Got FAILURE", req.error()
    echo "process callback"

  let res = HttpServer.new(initTAddress("127.0.0.1:30080"), processCallback,
                           maxConnections = 1)
  if res.isOk():
    let server = res.get()
    server.start()
    echo "HTTP server was started"
    waitFor server.join()
  else:
    echo "Failed to start server: ", res.error

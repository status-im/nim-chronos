#
#        Chronos HTTP/S server implementation
#             (c) Copyright 2021-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

{.push raises: [].}

import std/[tables, uri, strutils]
import stew/[base10], httputils, results
import ../../[asyncloop, asyncsync, config]
import ../../streams/[asyncstream, boundstream, chunkstream]
import "."/[httptable, httpcommon, multipart]
from ../../transports/common import TransportAddress, ServerFlags, `$`, `==`

export asyncloop, asyncsync, httptable, httpcommon, httputils, multipart,
       asyncstream, boundstream, chunkstream, uri, tables, results
export TransportAddress, ServerFlags, `$`, `==`

type
  HttpServerFlags* {.pure.} = enum
    Secure,
      ## Internal flag which indicates that server working in secure TLS mode
    NoExpectHandler,
      ## Do not handle `Expect` header automatically
    NotifyDisconnect,
      ## Notify user-callback when remote client disconnects.
    QueryCommaSeparatedArray
      ## Enable usage of comma as an array item delimiter in url-encoded
      ## entities (e.g. query string or POST body).
    Http11Pipeline
      ## Enable HTTP/1.1 pipelining.

  HttpServerError* {.pure.} = enum
    InterruptError, TimeoutError, ProtocolError, DisconnectError

  HttpServerState* {.pure.} = enum
    ServerRunning, ServerStopped, ServerClosed

  HttpProcessError* = object
    kind*: HttpServerError
    code*: HttpCode
    exc*: ref HttpError
    remote*: Opt[TransportAddress]

  ConnectionFence* = Result[HttpConnectionRef, HttpProcessError]
  RequestFence* = Result[HttpRequestRef, HttpProcessError]

  HttpRequestFlags* {.pure.} = enum
    BoundBody, UnboundBody, MultipartForm, UrlencodedForm, ClientExpect

  HttpResponseFlags* {.pure.} = enum
    KeepAlive, Stream

  HttpResponseStreamType* {.pure.} = enum
    Plain, SSE, Chunked

  HttpProcessExitType* {.pure.} = enum
    KeepAlive, Graceful, Immediate

  HttpResponseState* {.pure.} = enum
    Empty, Prepared, Sending, Finished, Failed, Cancelled, ErrorCode, Default

  HttpProcessCallback* =
    proc(req: RequestFence): Future[HttpResponseRef] {.
      gcsafe, raises: [].}

  HttpProcessCallback2* =
    proc(req: RequestFence): Future[HttpResponseRef] {.
      async: (raises: [CancelledError]).}

  HttpConnectionCallback* =
    proc(server: HttpServerRef,
         transp: StreamTransport): Future[HttpConnectionRef] {.
      async: (raises: [CancelledError, HttpConnectionError]).}

  HttpCloseConnectionCallback* =
    proc(connection: HttpConnectionRef): Future[void] {.
      async: (raises: []).}

  HttpConnectionHolder* = object of RootObj
    connection*: HttpConnectionRef
    server*: HttpServerRef
    future*: Future[void]
    transp*: StreamTransport
    acceptMoment*: Moment
    connectionId*: string

  HttpConnectionHolderRef* = ref HttpConnectionHolder

  HttpServer* = object of RootObj
    instance*: StreamServer
    address*: TransportAddress
    # semaphore*: AsyncSemaphore
    maxConnections*: int
    backlogSize*: int
    baseUri*: Uri
    serverIdent*: string
    flags*: set[HttpServerFlags]
    socketFlags*: set[ServerFlags]
    connections*: OrderedTable[string, HttpConnectionHolderRef]
    acceptLoop*: Future[void].Raising([])
    lifetime*: Future[void]
    headersTimeout*: Duration
    bufferSize*: int
    maxHeadersSize*: int
    maxRequestBodySize*: int
    processCallback*: HttpProcessCallback2
    createConnCallback*: HttpConnectionCallback
    middlewares: seq[HttpProcessCallback2]

  HttpServerRef* = ref HttpServer

  HttpRequest* = object of RootObj
    state*: HttpState
    headers*: HttpTable
    query*: HttpTable
    postTable: Opt[HttpTable]
    rawPath*: string
    uri*: Uri
    scheme*: string
    version*: HttpVersion
    meth*: HttpMethod
    contentEncoding*: set[ContentEncodingFlags]
    transferEncoding*: set[TransferEncodingFlags]
    requestFlags*: set[HttpRequestFlags]
    contentLength*: int
    contentTypeData*: Opt[ContentTypeData]
    connection*: HttpConnectionRef
    response*: Opt[HttpResponseRef]

  HttpRequestRef* = ref HttpRequest

  HttpResponse* = object of RootObj
    status*: HttpCode
    version*: HttpVersion
    headersTable: HttpTable
    body: seq[byte]
    flags: set[HttpResponseFlags]
    state*: HttpResponseState # TODO (cheatfate): Make this field private
    connection*: HttpConnectionRef
    streamType*: HttpResponseStreamType
    writer: AsyncStreamWriter

  HttpResponseRef* = ref HttpResponse

  HttpConnection* = object of RootObj
    state*: HttpState
    server*: HttpServerRef
    transp*: StreamTransport
    mainReader*: AsyncStreamReader
    mainWriter*: AsyncStreamWriter
    reader*: AsyncStreamReader
    writer*: AsyncStreamWriter
    closeCb*: HttpCloseConnectionCallback
    createMoment*: Moment
    currentRawQuery*: Opt[string]
    buffer: seq[byte]

  HttpConnectionRef* = ref HttpConnection

  MiddlewareHandleCallback* = proc(
    middleware: HttpServerMiddlewareRef, request: RequestFence,
    handler: HttpProcessCallback2): Future[HttpResponseRef] {.
      async: (raises: [CancelledError]).}

  HttpServerMiddleware* = object of RootObj
    handler*: MiddlewareHandleCallback

  HttpServerMiddlewareRef* = ref HttpServerMiddleware

  ByteChar* = string | seq[byte]

proc init(htype: typedesc[HttpProcessError], error: HttpServerError,
          exc: ref HttpError, remote: Opt[TransportAddress],
          code: HttpCode): HttpProcessError =
  HttpProcessError(kind: error, exc: exc, remote: remote, code: code)

proc init(htype: typedesc[HttpProcessError], error: HttpServerError,
          remote: Opt[TransportAddress], code: HttpCode): HttpProcessError =
  HttpProcessError(kind: error, remote: remote, code: code)

proc init(htype: typedesc[HttpProcessError],
          error: HttpServerError): HttpProcessError =
  HttpProcessError(kind: error)

proc defaultResponse*(exc: ref CatchableError): HttpResponseRef

proc defaultResponse*(msg: HttpMessage): HttpResponseRef

proc new(htype: typedesc[HttpConnectionHolderRef], server: HttpServerRef,
         transp: StreamTransport,
         connectionId: string): HttpConnectionHolderRef =
  HttpConnectionHolderRef(
    server: server, transp: transp, acceptMoment: Moment.now(),
    connectionId: connectionId)

proc error*(e: HttpProcessError): HttpServerError = e.kind

proc createConnection(server: HttpServerRef,
                      transp: StreamTransport): Future[HttpConnectionRef] {.
     async: (raises: [CancelledError, HttpConnectionError]).}

proc prepareMiddlewares(
       requestProcessCallback: HttpProcessCallback2,
       middlewares: openArray[HttpServerMiddlewareRef]
     ): seq[HttpProcessCallback2] =
  var
    handlers: seq[HttpProcessCallback2]
    currentHandler = requestProcessCallback

  if len(middlewares) == 0:
    return handlers

  let mws = @middlewares
  handlers = newSeq[HttpProcessCallback2](len(mws))

  for index in countdown(len(mws) - 1, 0):
    let processor =
      block:
        var res: HttpProcessCallback2
        closureScope:
          let
            middleware = mws[index]
            realHandler = currentHandler
          res =
            proc(request: RequestFence): Future[HttpResponseRef] {.
              async: (raises: [CancelledError], raw: true).} =
              middleware.handler(middleware, request, realHandler)
        res
    handlers[index] = processor
    currentHandler = processor
  handlers

proc new*(
       htype: typedesc[HttpServerRef],
       address: TransportAddress,
       processCallback: HttpProcessCallback2,
       serverFlags: set[HttpServerFlags] = {},
       socketFlags: set[ServerFlags] = {ReuseAddr},
       serverUri = Uri(),
       serverIdent = "",
       maxConnections: int = -1,
       bufferSize: int = chronosTransportDefaultBufferSize,
       backlogSize: int = DefaultBacklogSize,
       httpHeadersTimeout = 10.seconds,
       maxHeadersSize: int = 8192,
       maxRequestBodySize: int = 1_048_576,
       dualstack = DualStackType.Auto,
       middlewares: openArray[HttpServerMiddlewareRef] = []
     ): HttpResult[HttpServerRef] =
  let
    serverInstance =
      try:
        createStreamServer(address, flags = socketFlags, bufferSize = bufferSize,
                           backlog = backlogSize, dualstack = dualstack)
      except TransportOsError as exc:
        return err(exc.msg)
    serverUri =
      if len(serverUri.hostname) > 0:
        serverUri
      else:
        parseUri("http://" & $serverInstance.localAddress() & "/")
    res = HttpServerRef(
      address: serverInstance.localAddress(),
      instance: serverInstance,
      processCallback: processCallback,
      createConnCallback: createConnection,
      baseUri: serverUri,
      serverIdent: serverIdent,
      flags: serverFlags,
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
      middlewares: prepareMiddlewares(processCallback, middlewares)
    )
  ok(res)

proc new*(
       htype: typedesc[HttpServerRef],
       address: TransportAddress,
       processCallback: HttpProcessCallback,
       serverFlags: set[HttpServerFlags] = {},
       socketFlags: set[ServerFlags] = {ReuseAddr},
       serverUri = Uri(),
       serverIdent = "",
       maxConnections: int = -1,
       bufferSize: int = chronosTransportDefaultBufferSize,
       backlogSize: int = DefaultBacklogSize,
       httpHeadersTimeout = 10.seconds,
       maxHeadersSize: int = 8192,
       maxRequestBodySize: int = 1_048_576,
       dualstack = DualStackType.Auto,
       middlewares: openArray[HttpServerMiddlewareRef] = []
     ): HttpResult[HttpServerRef] {.
     deprecated: "Callback could raise only CancelledError, annotate with " &
                 "{.async: (raises: [CancelledError]).}".} =

  proc wrap(req: RequestFence): Future[HttpResponseRef] {.
       async: (raises: [CancelledError]).} =
    try:
      await processCallback(req)
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      defaultResponse(exc)

  HttpServerRef.new(address, wrap, serverFlags, socketFlags, serverUri,
                    serverIdent, maxConnections, bufferSize, backlogSize,
                    httpHeadersTimeout, maxHeadersSize, maxRequestBodySize,
                    dualstack, middlewares)

proc getServerFlags(req: HttpRequestRef): set[HttpServerFlags] =
  var defaultFlags: set[HttpServerFlags] = {}
  if isNil(req): return defaultFlags
  if isNil(req.connection): return defaultFlags
  if isNil(req.connection.server): return defaultFlags
  req.connection.server.flags

proc getResponseFlags(req: HttpRequestRef): set[HttpResponseFlags] =
  var defaultFlags: set[HttpResponseFlags] = {}
  case req.version
  of HttpVersion11:
    if HttpServerFlags.Http11Pipeline notin req.getServerFlags():
      return defaultFlags
    let header = req.headers.getString(ConnectionHeader, "keep-alive")
    if header == "keep-alive":
      {HttpResponseFlags.KeepAlive}
    else:
      defaultFlags
  else:
    defaultFlags

proc getResponseState*(response: HttpResponseRef): HttpResponseState =
  response.state

proc setResponseState(response: HttpResponseRef, state: HttpResponseState) =
  response.state = state

proc getResponseVersion(reqFence: RequestFence): HttpVersion =
  if reqFence.isErr():
    HttpVersion11
  else:
    reqFence.get().version

proc getResponse*(req: HttpRequestRef): HttpResponseRef =
  if req.response.isNone():
    var resp = HttpResponseRef(
      status: Http200,
      state: HttpResponseState.Empty,
      version: req.version,
      headersTable: HttpTable.init(),
      connection: req.connection,
      flags: req.getResponseFlags()
    )
    req.response = Opt.some(resp)
    resp
  else:
    req.response.get()

proc getHostname*(server: HttpServerRef): string =
  if len(server.baseUri.port) > 0:
    server.baseUri.hostname & ":" & server.baseUri.port
  else:
    server.baseUri.hostname

proc defaultResponse*(): HttpResponseRef =
  ## Create an empty response to return when request processor got no request.
  HttpResponseRef(state: HttpResponseState.Default, version: HttpVersion11)

proc defaultResponse*(exc: ref CatchableError): HttpResponseRef =
  ## Create response with error code based on exception type.
  if exc of AsyncTimeoutError:
    HttpResponseRef(state: HttpResponseState.ErrorCode, status: Http408)
  elif exc of HttpTransportError:
    HttpResponseRef(state: HttpResponseState.Failed)
  elif exc of HttpProtocolError:
    let code = cast[ref HttpProtocolError](exc).code
    HttpResponseRef(state: HttpResponseState.ErrorCode, status: code)
  else:
    HttpResponseRef(state: HttpResponseState.ErrorCode, status: Http503)

proc defaultResponse*(msg: HttpMessage): HttpResponseRef =
  HttpResponseRef(state: HttpResponseState.ErrorCode, status: msg.code)

proc defaultResponse*(err: HttpProcessError): HttpResponseRef =
  HttpResponseRef(state: HttpResponseState.ErrorCode, status: err.code)

proc dropResponse*(): HttpResponseRef =
  HttpResponseRef(state: HttpResponseState.Failed)

proc codeResponse*(status: HttpCode): HttpResponseRef =
  HttpResponseRef(state: HttpResponseState.ErrorCode, status: status)

proc dumbResponse*(): HttpResponseRef {.
     deprecated: "Please use defaultResponse() instead".} =
  ## Create an empty response to return when request processor got no request.
  defaultResponse()

proc getId(transp: StreamTransport): Result[string, string] {.inline.} =
  ## Returns string unique transport's identifier as string.
  try:
    ok($transp.remoteAddress() & "_" & $transp.localAddress())
  except TransportOsError as exc:
    err($exc.msg)

proc hasBody*(request: HttpRequestRef): bool =
  ## Returns ``true`` if request has body.
  request.requestFlags * {HttpRequestFlags.BoundBody,
                          HttpRequestFlags.UnboundBody} != {}

func new(t: typedesc[HttpRequestRef], conn: HttpConnectionRef): HttpRequestRef =
  HttpRequestRef(connection: conn, state: HttpState.Alive)

proc updateRequest*(request: HttpRequestRef, scheme: string, meth: HttpMethod,
                    version: HttpVersion, requestUri: string,
                    headers: HttpTable): HttpResultMessage[void] =
  ## Update HTTP request object using base request object with new properties.

  # Store request version and call method.
  request.scheme = scheme
  request.version = version
  request.meth = meth

  # Processing request's URI
  request.rawPath = requestUri
  request.uri =
    if request.rawPath != "*":
      let uri = parseUri(request.rawPath)
      if uri.scheme notin ["http", "https", ""]:
        return err(HttpMessage.init(Http400, "Unsupported URI scheme"))
      uri
    else:
      var uri = initUri()
      uri.path = "*"
      uri

  # Conversion of request query string to HttpTable.
  request.query =
    block:
      let queryFlags =
        if QueryCommaSeparatedArray in request.connection.server.flags:
          {QueryParamsFlag.CommaSeparatedArray}
        else:
          {}
      var table = HttpTable.init()
      for key, value in queryParams(request.uri.query, queryFlags):
        table.add(key, value)
      table

  # Store request headers
  request.headers = headers

  # Preprocessing "Content-Encoding" header.
  request.contentEncoding =
    getContentEncoding(
      request.headers.getList(ContentEncodingHeader)).valueOr:
        let msg = "Incorrect or unsupported Content-Encoding header value"
        return err(HttpMessage.init(Http400, msg))

  # Preprocessing "Transfer-Encoding" header.
  request.transferEncoding =
    getTransferEncoding(
      request.headers.getList(TransferEncodingHeader)).valueOr:
        let msg = "Incorrect or unsupported Transfer-Encoding header value"
        return err(HttpMessage.init(Http400, msg))

  # Almost all HTTP requests could have body (except TRACE), we perform some
  # steps to reveal information about body.
  request.contentLength =
    if ContentLengthHeader in request.headers:
      # Request headers has `Content-Length` header present.
      let length = request.headers.getInt(ContentLengthHeader)
      if length != 0:
        if request.meth == MethodTrace:
          let msg = "TRACE requests could not have request body"
          return err(HttpMessage.init(Http400, msg))
        # Because of coversion to `int` we should avoid unexpected
        # OverflowError.
        if length > uint64(high(int)):
          return err(HttpMessage.init(Http413, "Unsupported content length"))
        if length > uint64(request.connection.server.maxRequestBodySize):
          return err(HttpMessage.init(Http413, "Content length exceeds limits"))
        request.requestFlags.incl(HttpRequestFlags.BoundBody)
        int(length)
      else:
        0
    else:
      if TransferEncodingFlags.Chunked in request.transferEncoding:
        # Request headers has "Transfer-Encoding: chunked" header present.
        if request.meth == MethodTrace:
          let msg = "TRACE requests could not have request body"
          return err(HttpMessage.init(Http400, msg))
        request.requestFlags.incl(HttpRequestFlags.UnboundBody)
      0

  if request.hasBody():
    # If the request has a body, we will determine how it is encoded.
    if ContentTypeHeader in request.headers:
      # Request headers has "Content-Type" header present.
      let contentType =
        getContentType(request.headers.getList(ContentTypeHeader)).valueOr:
          let msg = "Incorrect or missing Content-Type header"
          return err(HttpMessage.init(Http415, msg))
      if contentType == UrlEncodedContentType:
        request.requestFlags.incl(HttpRequestFlags.UrlencodedForm)
      elif contentType == MultipartContentType:
        request.requestFlags.incl(HttpRequestFlags.MultipartForm)
      request.contentTypeData = Opt.some(contentType)
    # If `Expect` header is present, we will handle expectation procedure.
    if ExpectHeader in request.headers:
      let expectHeader = request.headers.getString(ExpectHeader)
      if strip(expectHeader).toLowerAscii() == "100-continue":
        request.requestFlags.incl(HttpRequestFlags.ClientExpect)

  ok()

proc updateRequest*(request: HttpRequestRef, meth: HttpMethod,
                    requestUri: string,
                    headers: HttpTable): HttpResultMessage[void] =
  ## Update HTTP request object using base request object with new properties.
  updateRequest(request, request.scheme, meth, request.version, requestUri,
                headers)

proc updateRequest*(request: HttpRequestRef, requestUri: string,
                    headers: HttpTable): HttpResultMessage[void] =
  ## Update HTTP request object using base request object with new properties.
  updateRequest(request, request.scheme, request.meth, request.version,
                requestUri, headers)

proc updateRequest*(request: HttpRequestRef,
                    requestUri: string): HttpResultMessage[void] =
  ## Update HTTP request object using base request object with new properties.
  updateRequest(request, request.scheme, request.meth, request.version,
                requestUri, request.headers)

proc updateRequest*(request: HttpRequestRef,
                    headers: HttpTable): HttpResultMessage[void] =
  ## Update HTTP request object using base request object with new properties.
  updateRequest(request, request.scheme, request.meth, request.version,
                request.rawPath, headers)

proc prepareRequest(conn: HttpConnectionRef,
                    req: HttpRequestHeader): HttpResultMessage[HttpRequestRef] =
  let
    request = HttpRequestRef.new(conn)
    scheme =
      if HttpServerFlags.Secure in conn.server.flags:
        "https"
      else:
        "http"
    headers =
      block:
        var table = HttpTable.init()
        # Retrieve headers and values
        for key, value in req.headers():
          table.add(key, value)
        # Validating HTTP request headers
        # Some of the headers must be present only once.
        if table.count(ContentTypeHeader) > 1:
          return err(HttpMessage.init(Http400,
                                      "Multiple Content-Type headers"))
        if table.count(ContentLengthHeader) > 1:
          return err(HttpMessage.init(Http400,
                                      "Multiple Content-Length headers"))
        if table.count(TransferEncodingHeader) > 1:
          return err(HttpMessage.init(Http400,
                                      "Multuple Transfer-Encoding headers"))
        table
  ? updateRequest(request, scheme, req.meth, req.version, req.uri(), headers)
  trackCounter(HttpServerRequestTrackerName)
  ok(request)

proc getBodyReader*(request: HttpRequestRef): HttpResult[HttpBodyReader] =
  ## Returns stream's reader instance which can be used to read request's body.
  ##
  ## Please be sure to handle ``Expect`` header properly.
  ##
  ## Streams which was obtained using this procedure must be closed to avoid
  ## leaks.
  if HttpRequestFlags.BoundBody in request.requestFlags:
    let bstream = newBoundedStreamReader(request.connection.reader,
                                         uint64(request.contentLength))
    ok(newHttpBodyReader(bstream))
  elif HttpRequestFlags.UnboundBody in request.requestFlags:
    let
      maxBodySize = request.connection.server.maxRequestBodySize
      cstream = newChunkedStreamReader(request.connection.reader)
      bstream = newBoundedStreamReader(cstream, uint64(maxBodySize),
                                       comparison = BoundCmp.LessOrEqual)
    ok(newHttpBodyReader(bstream, cstream))
  else:
    err("Request do not have body available")

proc handleExpect*(request: HttpRequestRef) {.
     async: (raises: [CancelledError, HttpWriteError]).} =
  ## Handle expectation for ``Expect`` header.
  ## https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Expect
  if HttpServerFlags.NoExpectHandler notin request.connection.server.flags:
    if HttpRequestFlags.ClientExpect in request.requestFlags:
      if request.version == HttpVersion11:
        try:
          let message = $request.version & " " & $Http100 & "\r\n\r\n"
          await request.connection.writer.write(message)
        except AsyncStreamError as exc:
          raiseHttpWriteError(
            "Unable to send `100-continue` response, reason: " & $exc.msg)

proc getBody*(request: HttpRequestRef): Future[seq[byte]] {.
     async: (raises: [CancelledError,
                      HttpTransportError, HttpProtocolError]).} =
  ## Obtain request's body as sequence of bytes.
  let reader = request.getBodyReader().valueOr:
    return @[]
  try:
    await request.handleExpect()
    let res = await reader.read()
    if reader.hasOverflow():
      raiseHttpRequestBodyTooLargeError()
    res
  except AsyncStreamError as exc:
    let msg = "Unable to read request's body, reason: " & $exc.msg
    raiseHttpReadError(msg)
  finally:
    await reader.closeWait()

proc consumeBody*(request: HttpRequestRef): Future[void] {.
     async: (raises: [CancelledError, HttpTransportError,
                      HttpProtocolError]).} =
  ## Consume/discard request's body.
  let reader = request.getBodyReader().valueOr:
    return
  try:
    await request.handleExpect()
    discard await reader.consume()
    if reader.hasOverflow(): raiseHttpRequestBodyTooLargeError()
  except AsyncStreamError as exc:
    let msg = "Unable to consume request's body, reason: " & $exc.msg
    raiseHttpReadError(msg)
  finally:
    await reader.closeWait()

proc getAcceptInfo*(request: HttpRequestRef): Result[AcceptInfo, cstring] =
  ## Returns value of `Accept` header as `AcceptInfo` object.
  ##
  ## If ``Accept`` header is missing in request headers, ``*/*`` content
  ## type will be returned.
  getAcceptInfo(request.headers.getString(AcceptHeaderName))

proc preferredContentMediaType*(acceptHeader: string): MediaType =
  ## Returns preferred content-type using ``Accept`` header value specified by
  ## string ``acceptHeader``.
  let res = getAcceptInfo(acceptHeader)
  if res.isErr():
    # If `Accept` header is incorrect, client accepts any type of content.
    MediaType.init("*", "*")
  else:
    let mediaTypes = res.get().data
    if len(mediaTypes) > 0:
      mediaTypes[0].mediaType
    else:
      MediaType.init("*", "*")

proc preferredContentType*(acceptHeader: string,
                           types: varargs[MediaType]
                          ): Result[MediaType, cstring] =
  ## Match or obtain preferred content type using ``Accept`` header specified by
  ## string ``acceptHeader`` and server preferred content types ``types``.
  ##
  ## If ``Accept`` header is missing in client's request - ``types[0]`` or
  ## ``*/*`` value will be returned as result.
  ##
  ## If ``Accept`` header has incorrect format in client's request -
  ## ``types[0]`` or ``*/*`` value will be returned as result.
  ##
  ## If ``Accept`` header is present in request to server and it has one or more
  ## content types supported by client, the best value will be selected from
  ## ``types`` using position and quality value (weight) reported in ``Accept``
  ## header. If client do not support any methods in ``types`` error
  ## will be returned.
  ##
  ## Note: Quality value (weight) for content type has priority over server's
  ## preferred content-type.
  if len(types) == 0:
    if len(acceptHeader) == 0:
      # If `Accept` header is missing, return `*/*`.
      ok(wildCardMediaType)
    else:
      let res = getAcceptInfo(acceptHeader)
      if res.isErr():
        # If `Accept` header is incorrect, client accepts any type of content.
        ok(wildCardMediaType)
      else:
        let mediaTypes = res.get().data
        var
          currentType = MediaType()
          currentWeight = 0.0
        # `Accept` header values array is not sorted, so we need to find value
        # with the biggest ``q-value``.
        for item in mediaTypes:
          if currentWeight < item.qvalue:
            currentType = item.mediaType
            currentWeight = item.qvalue
        if len(currentType.media) == 0 and len(currentType.subtype) == 0:
          ok(wildCardMediaType)
        else:
          ok(currentType)
  else:
    if len(acceptHeader) == 0:
      # If `Accept` header is missing, client accepts any type of content.
      ok(types[0])
    else:
      let ares = getAcceptInfo(acceptHeader)
      if ares.isErr():
        # If `Accept` header is incorrect, client accepts any type of content.
        ok(types[0])
      else:
        # ``maxWeight`` represents maximum possible weight value which can be
        # obtained.
        let maxWeight = (1.0, 0)
        var
          currentType = MediaType()
          currentIndex = -1
          currentWeight = (-1.0, 0)

        for itemType in ares.get().data:
          let preferredIndex = types.find(itemType.mediaType)
          if preferredIndex != -1:
            let weight = (itemType.qvalue, -preferredIndex)
            if currentWeight < weight:
              currentType = types[preferredIndex]
              currentWeight = weight
              currentIndex = preferredIndex

          if currentWeight == maxWeight:
            # There is no reason to continue search, because maximum possible
            # weight is already achieved, so this is the best match.
            break

        if currentIndex == -1:
          err("Preferred content type not found")
        else:
          ok(currentType)

proc preferredContentMediaType*(request: HttpRequestRef): MediaType =
  ## Returns preferred content-type using ``Accept`` header specified by
  ## client in request ``request``.
  preferredContentMediaType(request.headers.getString(AcceptHeaderName))

proc preferredContentType*(request: HttpRequestRef,
                           types: varargs[MediaType]
                          ): Result[MediaType, cstring] =
  ## Match or obtain preferred content-type using ``Accept`` header specified by
  ## client in request ``request``.
  preferredContentType(request.headers.getString(AcceptHeaderName), types)

proc sendErrorResponse(conn: HttpConnectionRef, version: HttpVersion,
                       code: HttpCode, keepAlive = true,
                       datatype = "text/plain",
                       databody = "") {.
     async: (raises: [CancelledError]).} =
  var answer = $version & " " & $code & "\r\n"
  answer.add(DateHeader)
  answer.add(": ")
  answer.add(httpDate())
  answer.add("\r\n")
  if len(datatype) > 0:
    answer.add(ContentTypeHeader)
    answer.add(": ")
    answer.add(datatype)
    answer.add("\r\n")
  answer.add(ContentLengthHeader)
  answer.add(": ")
  answer.add(Base10.toString(uint64(len(databody))))
  answer.add("\r\n")
  if keepAlive:
    answer.add(ConnectionHeader)
    answer.add(": keep-alive\r\n")
  else:
    answer.add(ConnectionHeader)
    answer.add(": close\r\n")
  answer.add("\r\n")
  if len(databody) > 0:
    answer.add(databody)
  try:
    await conn.writer.write(answer)
  except AsyncStreamError:
    # We ignore errors here, because we indicating error already.
    discard

proc sendDefaultResponse(
       conn: HttpConnectionRef,
       reqFence: RequestFence,
       response: HttpResponseRef
     ): Future[HttpProcessExitType] {.async: (raises: []).} =
  let
    version = getResponseVersion(reqFence)
    keepConnection =
      if isNil(response) or (HttpResponseFlags.KeepAlive notin response.flags):
        HttpProcessExitType.Graceful
      else:
        HttpProcessExitType.KeepAlive

  template toBool(hpet: HttpProcessExitType): bool =
    case hpet
    of HttpProcessExitType.KeepAlive:
      true
    of HttpProcessExitType.Immediate:
      false
    of HttpProcessExitType.Graceful:
      false

  try:
    if reqFence.isOk():
      if isNil(response):
        await conn.sendErrorResponse(version, Http404, keepConnection.toBool())
        return keepConnection

      case response.state
      of HttpResponseState.Empty, HttpResponseState.Default:
        # Response was ignored, so we respond with not found.
        await conn.sendErrorResponse(version, Http404,
                                     keepConnection.toBool())
        keepConnection
      of HttpResponseState.Prepared:
        # Response was prepared but not sent, so we can respond with some
        # error code
        await conn.sendErrorResponse(version, Http409,
                                     keepConnection.toBool())
        keepConnection
      of HttpResponseState.ErrorCode:
        # Response with error code
        await conn.sendErrorResponse(version, response.status, false)
        HttpProcessExitType.Immediate
      of HttpResponseState.Sending, HttpResponseState.Failed,
         HttpResponseState.Cancelled:
        # Just drop connection, because we dont know at what stage we are
        HttpProcessExitType.Immediate
      of HttpResponseState.Finished:
        keepConnection
    else:
      case reqFence.error.kind
      of HttpServerError.TimeoutError, HttpServerError.ProtocolError:
        await conn.sendErrorResponse(version, reqFence.error.code, false)
        HttpProcessExitType.Graceful
      of HttpServerError.DisconnectError:
        # When `HttpServerFlags.NotifyDisconnect` is set.
        HttpProcessExitType.Immediate
      of HttpServerError.InterruptError:
        # InterruptError should be handled earlier
        raiseAssert("Unexpected request error: " & $reqFence.error.kind)
  except CancelledError:
    HttpProcessExitType.Immediate

proc getRequest(conn: HttpConnectionRef): Future[HttpRequestRef] {.
     async: (raises: [CancelledError, HttpDisconnectError,
                      HttpProtocolError]).} =
  try:
    conn.buffer.setLen(conn.server.maxHeadersSize)
    let res = await conn.reader.readUntil(addr conn.buffer[0], len(conn.buffer),
                                          HeadersMark)
    conn.buffer.setLen(res)
    let header = parseRequest(conn.buffer)
    if header.failed():
      raiseHttpProtocolError(Http400, "Malformed request recieved")
    prepareRequest(conn, header).valueOr:
      raiseHttpProtocolError(error)
  except AsyncStreamLimitError:
    raiseHttpProtocolError(Http431, "Maximum size of request headers reached")
  except AsyncStreamError:
    raiseHttpDisconnectError()

proc init*(value: var HttpConnection, server: HttpServerRef,
           transp: StreamTransport) =
  value = HttpConnection(
    state: HttpState.Alive,
    server: server,
    transp: transp,
    buffer: newSeq[byte](server.maxHeadersSize),
    mainReader: newAsyncStreamReader(transp),
    mainWriter: newAsyncStreamWriter(transp)
  )

proc closeUnsecureConnection(conn: HttpConnectionRef) {.async: (raises: []).} =
  if conn.state == HttpState.Alive:
    conn.state = HttpState.Closing
    var pending: seq[Future[void]]
    pending.add(conn.mainReader.closeWait())
    pending.add(conn.mainWriter.closeWait())
    pending.add(conn.transp.closeWait())
    await noCancel(allFutures(pending))
    untrackCounter(HttpServerUnsecureConnectionTrackerName)
    reset(conn[])
    conn.state = HttpState.Closed

proc new(ht: typedesc[HttpConnectionRef], server: HttpServerRef,
         transp: StreamTransport): HttpConnectionRef =
  var res = HttpConnectionRef()
  res[].init(server, transp)
  res.reader = res.mainReader
  res.writer = res.mainWriter
  res.closeCb = closeUnsecureConnection
  res.createMoment = Moment.now()
  trackCounter(HttpServerUnsecureConnectionTrackerName)
  res

proc gracefulCloseWait*(conn: HttpConnectionRef) {.async: (raises: []).} =
  try:
    await noCancel(conn.transp.shutdownWait())
  except TransportError:
    # We try to gracefully close connection, so we ignore any errors here,
    # because right after this operation we closing connection.
    discard
  await conn.closeCb(conn)

proc closeWait*(conn: HttpConnectionRef): Future[void] {.
     async: (raw: true, raises: []).} =
  conn.closeCb(conn)

proc closeWait*(req: HttpRequestRef) {.async: (raises: []).} =
  if req.state == HttpState.Alive:
    if req.response.isSome():
      req.state = HttpState.Closing
      let resp = req.response.get()
      if (HttpResponseFlags.Stream in resp.flags) and not(isNil(resp.writer)):
        await closeWait(resp.writer)
      reset(resp[])
    untrackCounter(HttpServerRequestTrackerName)
    reset(req[])
    req.state = HttpState.Closed

proc createConnection(server: HttpServerRef,
                      transp: StreamTransport): Future[HttpConnectionRef] {.
     async: (raises: [CancelledError, HttpConnectionError]).} =
  HttpConnectionRef.new(server, transp)

proc `keepalive=`*(resp: HttpResponseRef, value: bool) =
  doAssert(resp.getResponseState() == HttpResponseState.Empty)
  if value:
    resp.flags.incl(HttpResponseFlags.KeepAlive)
  else:
    resp.flags.excl(HttpResponseFlags.KeepAlive)

proc keepalive*(resp: HttpResponseRef): bool =
  HttpResponseFlags.KeepAlive in resp.flags

proc getRemoteAddress(transp: StreamTransport): Opt[TransportAddress] =
  if isNil(transp): return Opt.none(TransportAddress)
  try:
    Opt.some(transp.remoteAddress())
  except TransportOsError:
    Opt.none(TransportAddress)

proc getRemoteAddress(connection: HttpConnectionRef): Opt[TransportAddress] =
  if isNil(connection): return Opt.none(TransportAddress)
  getRemoteAddress(connection.transp)

proc getLocalAddress(transp: StreamTransport): Opt[TransportAddress] =
  if isNil(transp): return Opt.none(TransportAddress)
  try:
    Opt.some(transp.localAddress())
  except TransportOsError:
    Opt.none(TransportAddress)

proc getLocalAddress(connection: HttpConnectionRef): Opt[TransportAddress] =
  if isNil(connection): return Opt.none(TransportAddress)
  getLocalAddress(connection.transp)

proc remote*(request: HttpRequestRef): Opt[TransportAddress] =
  ## Returns remote address of HTTP request's connection.
  request.connection.getRemoteAddress()

proc local*(request: HttpRequestRef): Opt[TransportAddress] =
  ## Returns local address of HTTP request's connection.
  request.connection.getLocalAddress()

proc getRequestFence*(server: HttpServerRef,
                      connection: HttpConnectionRef): Future[RequestFence] {.
     async: (raises: []).} =
  try:
    let res =
      if server.headersTimeout.isInfinite():
        await connection.getRequest()
      else:
        await connection.getRequest().wait(server.headersTimeout)
    connection.currentRawQuery = Opt.some(res.rawPath)
    RequestFence.ok(res)
  except CancelledError:
    RequestFence.err(HttpProcessError.init(HttpServerError.InterruptError))
  except AsyncTimeoutError:
    let address = connection.getRemoteAddress()
    RequestFence.err(
      HttpProcessError.init(HttpServerError.TimeoutError, address, Http408))
  except HttpProtocolError as exc:
    let address = connection.getRemoteAddress()
    RequestFence.err(
      HttpProcessError.init(HttpServerError.ProtocolError, exc, address,
                            exc.code))
  except HttpDisconnectError:
    let address = connection.getRemoteAddress()
    RequestFence.err(
      HttpProcessError.init(HttpServerError.DisconnectError, address, Http400))

proc getConnectionFence*(server: HttpServerRef,
                         transp: StreamTransport): Future[ConnectionFence] {.
     async: (raises: []).} =
  try:
    let res = await server.createConnCallback(server, transp)
    ConnectionFence.ok(res)
  except CancelledError:
    ConnectionFence.err(HttpProcessError.init(HttpServerError.InterruptError))
  except HttpConnectionError as exc:
    # On error `transp` will be closed by `createConnCallback()` call.
    let address = Opt.none(TransportAddress)
    ConnectionFence.err(HttpProcessError.init(
      HttpServerError.DisconnectError, exc, address, Http400))

proc invokeProcessCallback(server: HttpServerRef,
                           req: RequestFence): Future[HttpResponseRef] {.
     async: (raw: true, raises: [CancelledError]).} =
  if len(server.middlewares) > 0:
    server.middlewares[0](req)
  else:
    server.processCallback(req)

proc processRequest(server: HttpServerRef,
                    connection: HttpConnectionRef,
                    connId: string): Future[HttpProcessExitType] {.
     async: (raises: []).} =
  let requestFence = await getRequestFence(server, connection)
  if requestFence.isErr():
    case requestFence.error.kind
    of HttpServerError.InterruptError:
      # Cancelled, exiting
      return HttpProcessExitType.Immediate
    of HttpServerError.DisconnectError:
      # Remote peer disconnected
      if HttpServerFlags.NotifyDisconnect notin server.flags:
        return HttpProcessExitType.Immediate
    else:
      # Request is incorrect or unsupported, sending notification
      discard

  let response =
    try:
      await invokeProcessCallback(connection.server, requestFence)
    except CancelledError:
      # Cancelled, exiting
      if requestFence.isOk():
        await requestFence.get().closeWait()
      return HttpProcessExitType.Immediate

  let res = await connection.sendDefaultResponse(requestFence, response)
  if requestFence.isOk():
    await requestFence.get().closeWait()
  res

proc processLoop(holder: HttpConnectionHolderRef) {.async: (raises: []).} =
  let
    server = holder.server
    transp = holder.transp
    connectionId = holder.connectionId
    connection =
      block:
        let res = await getConnectionFence(server, transp)
        if res.isErr():
          if res.error.kind != HttpServerError.InterruptError:
            discard await noCancel(
              invokeProcessCallback(server, RequestFence.err(res.error)))
          server.connections.del(connectionId)
          return
        res.get()

  holder.connection = connection

  var runLoop = HttpProcessExitType.KeepAlive
  while runLoop == HttpProcessExitType.KeepAlive:
    runLoop = await server.processRequest(connection, connectionId)

  case runLoop
  of HttpProcessExitType.KeepAlive:
    await connection.closeWait()
  of HttpProcessExitType.Immediate:
    await connection.closeWait()
  of HttpProcessExitType.Graceful:
    await connection.gracefulCloseWait()
  server.connections.del(connectionId)

proc acceptClientLoop(server: HttpServerRef) {.async: (raises: []).} =
  block mainLoop:
    while true:
      block clientLoop:
        # if server.maxConnections > 0:
        #   await server.semaphore.acquire()
        let transp =
          try:
            await server.instance.accept()
          except TransportTooManyError:
            # Too many FDs used by process
            break clientLoop
          except TransportAbortedError:
            # Remote peer disconnected
            break clientLoop
          except TransportUseClosedError:
            # accept() call invoked when server is stopped
            break mainLoop
          except TransportOsError:
            # Critical OS error
            break mainLoop
          except CancelledError:
            # Server being closed, exiting
            break mainLoop

        doAssert(not(isNil(transp)), "Stream transport should be present!")

        let
          connectionId = transp.getId().valueOr:
            # We are unable to identify remote peer, it means that remote peer
            # disconnected before.
            await transp.closeWait()
            break clientLoop
          holder = HttpConnectionHolderRef.new(server, transp, connectionId)

        server.connections[connectionId] = holder
        holder.future = processLoop(holder)

proc state*(server: HttpServerRef): HttpServerState =
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

proc start*(server: HttpServerRef) =
  ## Starts HTTP server.
  if server.state == ServerStopped:
    server.acceptLoop = acceptClientLoop(server)

proc stop*(server: HttpServerRef) {.async: (raises: []).} =
  ## Stop HTTP server from accepting new connections.
  if server.state == ServerRunning:
    await server.acceptLoop.cancelAndWait()

proc drop*(server: HttpServerRef) {.async: (raises: []).} =
  ## Drop all pending HTTP connections.
  var pending: seq[Future[void]]
  if server.state in {ServerStopped, ServerRunning}:
    for holder in server.connections.values():
      if not(isNil(holder.future)) and not(holder.future.finished()):
        pending.add(holder.future.cancelAndWait())
    await noCancel(allFutures(pending))
    server.connections.clear()

proc closeWait*(server: HttpServerRef) {.async: (raises: []).} =
  ## Stop HTTP server and drop all the pending connections.
  if server.state != ServerClosed:
    await server.stop()
    await server.drop()
    await server.instance.closeWait()
    server.lifetime.complete()

proc join*(server: HttpServerRef): Future[void] {.
     async: (raw: true, raises: [CancelledError]).} =
  ## Wait until HTTP server will not be closed.
  server.lifetime.join()

proc getMultipartReader*(req: HttpRequestRef): HttpResult[MultiPartReaderRef] =
  ## Create new MultiPartReader interface for specific request.
  if req.meth in PostMethods:
    if MultipartForm in req.requestFlags:
      if req.contentTypeData.isSome():
        let boundary = ? getMultipartBoundary(req.contentTypeData.get())
        var stream = ? req.getBodyReader()
        ok(MultiPartReaderRef.new(stream, boundary))
      else:
        err("Content type is missing or invalid")
    else:
      err("Request's data is not multipart encoded")
  else:
    err("Request's method do not supports multipart")

proc post*(req: HttpRequestRef): Future[HttpTable] {.
     async: (raises: [CancelledError, HttpTransportError,
                      HttpProtocolError]).} =
  ## Return POST parameters
  if req.postTable.isSome():
    return req.postTable.get()

  if req.meth notin PostMethods:
    return HttpTable.init()

  if UrlencodedForm in req.requestFlags:
    let queryFlags =
      if QueryCommaSeparatedArray in req.connection.server.flags:
        {QueryParamsFlag.CommaSeparatedArray}
      else:
        {}
    var table = HttpTable.init()
    # getBody() will handle `Expect`.
    var body = await req.getBody()
    # TODO (cheatfate) double copy here, because of `byte` to `char`
    # conversion.
    var strbody = newString(len(body))
    if len(body) > 0:
      copyMem(addr strbody[0], addr body[0], len(body))
    for key, value in queryParams(strbody, queryFlags):
      table.add(key, value)
    req.postTable = Opt.some(table)
    return table
  elif MultipartForm in req.requestFlags:
    var table = HttpTable.init()
    let mpreader = getMultipartReader(req).valueOr:
      raiseHttpProtocolError(Http400,
        "Unable to retrieve multipart form data, reason: " & $error)
    # Reading multipart/form-data parts.
    var runLoop = true
    while runLoop:
      var part: MultiPart
      try:
        part = await mpreader.readPart()
        var value = await part.getBody()

        # TODO (cheatfate) double copy here, because of `byte` to `char`
        # conversion.
        var strvalue = newString(len(value))
        if len(value) > 0:
          copyMem(addr strvalue[0], addr value[0], len(value))
        table.add(part.name, strvalue)
        await part.closeWait()
      except MultipartEOMError:
        runLoop = false
      except HttpWriteError as exc:
        if not(part.isEmpty()):
          await part.closeWait()
        await mpreader.closeWait()
        raise exc
      except HttpProtocolError as exc:
        if not(part.isEmpty()):
          await part.closeWait()
        await mpreader.closeWait()
        raise exc
      except CancelledError as exc:
        if not(part.isEmpty()):
          await part.closeWait()
        await mpreader.closeWait()
        raise exc
    await mpreader.closeWait()
    req.postTable = Opt.some(table)
    return table
  else:
    if HttpRequestFlags.BoundBody in req.requestFlags:
      if req.contentLength != 0:
        raiseHttpProtocolError(Http400, "Unsupported request body")
      return HttpTable.init()
    elif HttpRequestFlags.UnboundBody in req.requestFlags:
      raiseHttpProtocolError(Http400, "Unsupported request body")

template checkPending(t: untyped) =
  let currentState = t.getResponseState()
  doAssert(currentState == HttpResponseState.Empty,
           "Response body was already sent [" & $currentState & "]")

template checkStreamResponse(t: untyped) =
  doAssert(HttpResponseFlags.Stream in t.flags,
           "Response was not prepared")

template checkStreamResponseState(t: untyped) =
  doAssert(t.getResponseState() in
           {HttpResponseState.Prepared, HttpResponseState.Sending},
           "Response is in the wrong state")

template checkResponseCanBeModified(t: untyped) =
  doAssert(t.getResponseState() in
           {HttpResponseState.Empty, HttpResponseState.ErrorCode},
           "Response could not be modified at this stage")

template checkPointerLength(t1, t2: untyped) =
  doAssert(not(isNil(t1)), "pbytes must not be nil")
  doAssert(t2 >= 0, "nbytes should be bigger or equal to zero")

proc setHeader*(resp: HttpResponseRef, key, value: string) =
  ## Sets value of header ``key`` to ``value``.
  checkResponseCanBeModified(resp)
  resp.headersTable.set(key, value)

proc setHeaderDefault*(resp: HttpResponseRef, key, value: string) =
  ## Sets value of header ``key`` to ``value``, only if header ``key`` is not
  ## present in the headers table.
  checkResponseCanBeModified(resp)
  discard resp.headersTable.hasKeyOrPut(key, value)

proc addHeader*(resp: HttpResponseRef, key, value: string) =
  ## Adds value ``value`` to header's ``key`` value.
  checkResponseCanBeModified(resp)
  resp.headersTable.add(key, value)

proc getHeader*(resp: HttpResponseRef, key: string,
                default: string = ""): string =
  ## Returns value of header with name ``name`` or ``default``, if header is
  ## not present in the table.
  resp.headersTable.getString(key, default)

proc hasHeader*(resp: HttpResponseRef, key: string): bool =
  ## Returns ``true`` if header with name ``key`` present in the headers table.
  key in resp.headersTable

func createHeaders(resp: HttpResponseRef): string =
  var answer = $(resp.version) & " " & $(resp.status) & "\r\n"
  for k, v in resp.headersTable.stringItems():
    if len(v) > 0:
      answer.add(normalizeHeaderName(k))
      answer.add(": ")
      answer.add(v)
      answer.add("\r\n")
  answer.add("\r\n")
  answer

proc prepareLengthHeaders(resp: HttpResponseRef, length: int): string =
  if not(resp.hasHeader(DateHeader)):
    resp.setHeader(DateHeader, httpDate())
  if length > 0:
    if not(resp.hasHeader(ContentTypeHeader)):
      resp.setHeader(ContentTypeHeader, "text/html; charset=utf-8")
  if not(resp.hasHeader(ContentLengthHeader)):
    resp.setHeader(ContentLengthHeader, Base10.toString(uint64(length)))
  if not(resp.hasHeader(ServerHeader)):
    resp.setHeader(ServerHeader, resp.connection.server.serverIdent)
  if not(resp.hasHeader(ConnectionHeader)):
    if HttpResponseFlags.KeepAlive in resp.flags:
      resp.setHeader(ConnectionHeader, "keep-alive")
    else:
      resp.setHeader(ConnectionHeader, "close")
  resp.createHeaders()

proc prepareChunkedHeaders(resp: HttpResponseRef): string =
  if not(resp.hasHeader(DateHeader)):
    resp.setHeader(DateHeader, httpDate())
  if not(resp.hasHeader(ContentTypeHeader)):
    resp.setHeader(ContentTypeHeader, "text/html; charset=utf-8")
  if not(resp.hasHeader(TransferEncodingHeader)):
    resp.setHeader(TransferEncodingHeader, "chunked")
  if not(resp.hasHeader(ServerHeader)):
    resp.setHeader(ServerHeader, resp.connection.server.serverIdent)
  if not(resp.hasHeader(ConnectionHeader)):
    if HttpResponseFlags.KeepAlive in resp.flags:
      resp.setHeader(ConnectionHeader, "keep-alive")
    else:
      resp.setHeader(ConnectionHeader, "close")
  resp.createHeaders()

proc prepareServerSideEventHeaders(resp: HttpResponseRef): string =
  if not(resp.hasHeader(DateHeader)):
    resp.setHeader(DateHeader, httpDate())
  if not(resp.hasHeader(ContentTypeHeader)):
    resp.setHeader(ContentTypeHeader, "text/event-stream")
  if not(resp.hasHeader(ServerHeader)):
    resp.setHeader(ServerHeader, resp.connection.server.serverIdent)
  if not(resp.hasHeader(ConnectionHeader)):
    resp.flags.excl(HttpResponseFlags.KeepAlive)
    resp.setHeader(ConnectionHeader, "close")
  resp.createHeaders()

proc preparePlainHeaders(resp: HttpResponseRef): string =
  if not(resp.hasHeader(DateHeader)):
    resp.setHeader(DateHeader, httpDate())
  if not(resp.hasHeader(ServerHeader)):
    resp.setHeader(ServerHeader, resp.connection.server.serverIdent)
  if not(resp.hasHeader(ConnectionHeader)):
    resp.flags.excl(HttpResponseFlags.KeepAlive)
    resp.setHeader(ConnectionHeader, "close")
  resp.createHeaders()

proc sendBody*(resp: HttpResponseRef, pbytes: pointer, nbytes: int) {.
     async: (raises: [CancelledError, HttpWriteError]).} =
  ## Send HTTP response at once by using bytes pointer ``pbytes`` and length
  ## ``nbytes``.
  checkPointerLength(pbytes, nbytes)
  checkPending(resp)
  let responseHeaders = resp.prepareLengthHeaders(nbytes)
  resp.setResponseState(HttpResponseState.Prepared)
  try:
    resp.setResponseState(HttpResponseState.Sending)
    await resp.connection.writer.write(responseHeaders)
    if nbytes > 0:
      await resp.connection.writer.write(pbytes, nbytes)
    resp.setResponseState(HttpResponseState.Finished)
  except CancelledError as exc:
    resp.setResponseState(HttpResponseState.Cancelled)
    raise exc
  except AsyncStreamError as exc:
    resp.setResponseState(HttpResponseState.Failed)
    raiseHttpWriteError("Unable to send response body, reason: " & $exc.msg)

proc sendBody*(resp: HttpResponseRef, data: ByteChar) {.
     async: (raises: [CancelledError, HttpWriteError]).} =
  ## Send HTTP response at once by using data ``data``.
  checkPending(resp)
  let responseHeaders = resp.prepareLengthHeaders(len(data))
  resp.setResponseState(HttpResponseState.Prepared)
  try:
    resp.setResponseState(HttpResponseState.Sending)
    await resp.connection.writer.write(responseHeaders)
    if len(data) > 0:
      await resp.connection.writer.write(data)
    resp.setResponseState(HttpResponseState.Finished)
  except CancelledError as exc:
    resp.setResponseState(HttpResponseState.Cancelled)
    raise exc
  except AsyncStreamError as exc:
    resp.setResponseState(HttpResponseState.Failed)
    raiseHttpWriteError("Unable to send response body, reason: " & $exc.msg)

proc sendError*(resp: HttpResponseRef, code: HttpCode, body = "") {.
     async: (raises: [CancelledError, HttpWriteError]).} =
  ## Send HTTP error status response.
  checkPending(resp)
  resp.status = code
  let responseHeaders = resp.prepareLengthHeaders(len(body))
  resp.setResponseState(HttpResponseState.Prepared)
  try:
    resp.setResponseState(HttpResponseState.Sending)
    await resp.connection.writer.write(responseHeaders)
    if len(body) > 0:
      await resp.connection.writer.write(body)
    resp.setResponseState(HttpResponseState.Finished)
  except CancelledError as exc:
    resp.setResponseState(HttpResponseState.Cancelled)
    raise exc
  except AsyncStreamError as exc:
    resp.setResponseState(HttpResponseState.Failed)
    raiseHttpWriteError(
      "Unable to send error response body, reason: " & $exc.msg)

proc prepare*(resp: HttpResponseRef,
              streamType = HttpResponseStreamType.Chunked) {.
     async: (raises: [CancelledError, HttpWriteError]).} =
  ## Prepare for HTTP stream response.
  ##
  ## Such responses will be sent chunk by chunk using ``chunked`` encoding.
  resp.checkPending()
  let responseHeaders =
    case streamType
    of HttpResponseStreamType.Plain:
      resp.preparePlainHeaders()
    of HttpResponseStreamType.SSE:
      resp.prepareServerSideEventHeaders()
    of HttpResponseStreamType.Chunked:
      resp.prepareChunkedHeaders()
  resp.streamType = streamType
  resp.setResponseState(HttpResponseState.Prepared)
  try:
    resp.setResponseState(HttpResponseState.Sending)
    await resp.connection.writer.write(responseHeaders)
    case streamType
    of HttpResponseStreamType.Plain, HttpResponseStreamType.SSE:
      resp.writer = newAsyncStreamWriter(resp.connection.writer)
    of HttpResponseStreamType.Chunked:
      resp.writer = newChunkedStreamWriter(resp.connection.writer)
    resp.flags.incl(HttpResponseFlags.Stream)
  except CancelledError as exc:
    resp.setResponseState(HttpResponseState.Cancelled)
    raise exc
  except AsyncStreamError as exc:
    resp.setResponseState(HttpResponseState.Failed)
    raiseHttpWriteError("Unable to send response headers, reason: " & $exc.msg)

proc prepareChunked*(resp: HttpResponseRef): Future[void] {.
     async: (raw: true, raises: [CancelledError, HttpWriteError]).} =
  ## Prepare for HTTP chunked stream response.
  ##
  ## Such responses will be sent chunk by chunk using ``chunked`` encoding.
  resp.prepare(HttpResponseStreamType.Chunked)

proc preparePlain*(resp: HttpResponseRef): Future[void] {.
     async: (raw: true, raises: [CancelledError, HttpWriteError]).} =
  ## Prepare for HTTP plain stream response.
  ##
  ## Such responses will be sent without any encoding.
  resp.prepare(HttpResponseStreamType.Plain)

proc prepareSSE*(resp: HttpResponseRef): Future[void] {.
     async: (raw: true, raises: [CancelledError, HttpWriteError]).} =
  ## Prepare for HTTP server-side event stream response.
  resp.prepare(HttpResponseStreamType.SSE)

proc send*(resp: HttpResponseRef, pbytes: pointer, nbytes: int) {.
     async: (raises: [CancelledError, HttpWriteError]).} =
  ## Send single chunk of data pointed by ``pbytes`` and ``nbytes``.
  checkPointerLength(pbytes, nbytes)
  resp.checkStreamResponse()
  resp.checkStreamResponseState()
  try:
    resp.setResponseState(HttpResponseState.Sending)
    await resp.writer.write(pbytes, nbytes)
  except CancelledError as exc:
    resp.setResponseState(HttpResponseState.Cancelled)
    raise exc
  except AsyncStreamError as exc:
    resp.setResponseState(HttpResponseState.Failed)
    raiseHttpWriteError("Unable to send response data, reason: " & $exc.msg)

proc send*(resp: HttpResponseRef, data: ByteChar) {.
     async: (raises: [CancelledError, HttpWriteError]).} =
  ## Send single chunk of data ``data``.
  resp.checkStreamResponse()
  resp.checkStreamResponseState()
  try:
    resp.setResponseState(HttpResponseState.Sending)
    await resp.writer.write(data)
  except CancelledError as exc:
    resp.setResponseState(HttpResponseState.Cancelled)
    raise exc
  except AsyncStreamError as exc:
    resp.setResponseState(HttpResponseState.Failed)
    raiseHttpWriteError("Unable to send response data, reason: " & $exc.msg)

proc sendChunk*(resp: HttpResponseRef, pbytes: pointer,
                nbytes: int): Future[void] {.
     async: (raw: true, raises: [CancelledError, HttpWriteError]).} =
  resp.send(pbytes, nbytes)

proc sendChunk*(resp: HttpResponseRef, data: ByteChar): Future[void] {.
     async: (raw: true, raises: [CancelledError, HttpWriteError]).} =
  resp.send(data)

proc sendEvent*(resp: HttpResponseRef, eventName: string,
                data: string): Future[void] {.
     async: (raw: true, raises: [CancelledError, HttpWriteError]).} =
  ## Send server-side event with name ``eventName`` and payload ``data`` to
  ## remote peer.
  var res = ""
  if len(eventName) > 0:
    res.add("event: ")
    res.add(eventName)
    res.add("\r\n")
  res.add("data: ")
  res.add(data)
  res.add("\r\n\r\n")
  resp.send(res)

proc finish*(resp: HttpResponseRef) {.
     async: (raises: [CancelledError, HttpWriteError]).} =
  ## Sending last chunk of data, so it will indicate end of HTTP response.
  resp.checkStreamResponse()
  resp.checkStreamResponseState()
  try:
    resp.setResponseState(HttpResponseState.Sending)
    await resp.writer.finish()
    resp.setResponseState(HttpResponseState.Finished)
  except CancelledError as exc:
    resp.setResponseState(HttpResponseState.Cancelled)
    raise exc
  except AsyncStreamError as exc:
    resp.setResponseState(HttpResponseState.Failed)
    raiseHttpWriteError("Unable to finish response data, reason: " & $exc.msg)

proc respond*(req: HttpRequestRef, code: HttpCode, content: ByteChar,
              headers: HttpTable): Future[HttpResponseRef] {.
     async: (raises: [CancelledError, HttpWriteError]).} =
  ## Responds to the request with the specified ``HttpCode``, HTTP ``headers``
  ## and ``content``.
  let response = req.getResponse()
  response.status = code
  for k, v in headers.stringItems():
    response.addHeader(k, v)
  await response.sendBody(content)
  response

proc respond*(req: HttpRequestRef, code: HttpCode,
              content: ByteChar): Future[HttpResponseRef] {.
     async: (raw: true, raises: [CancelledError, HttpWriteError]).} =
  ## Responds to the request with specified ``HttpCode`` and ``content``.
  respond(req, code, content, HttpTable.init())

proc respond*(req: HttpRequestRef, code: HttpCode): Future[HttpResponseRef] {.
     async: (raw: true, raises: [CancelledError, HttpWriteError]).} =
  ## Responds to the request with specified ``HttpCode`` only.
  respond(req, code, "", HttpTable.init())

proc redirect*(req: HttpRequestRef, code: HttpCode,
               location: string, headers: HttpTable): Future[HttpResponseRef] {.
     async: (raw: true, raises: [CancelledError, HttpWriteError]).} =
  ## Responds to the request with redirection to location ``location`` and
  ## additional headers ``headers``.
  ##
  ## Note, ``location`` argument's value has priority over "Location" header's
  ## value in ``headers`` argument.
  var mheaders = headers
  mheaders.set("location", location)
  respond(req, code, "", mheaders)

proc redirect*(req: HttpRequestRef, code: HttpCode,
               location: Uri, headers: HttpTable): Future[HttpResponseRef] {.
     async: (raw: true, raises: [CancelledError, HttpWriteError]).} =
  ## Responds to the request with redirection to location ``location`` and
  ## additional headers ``headers``.
  ##
  ## Note, ``location`` argument's value has priority over "Location" header's
  ## value in ``headers`` argument.
  redirect(req, code, $location, headers)

proc redirect*(req: HttpRequestRef, code: HttpCode,
               location: Uri): Future[HttpResponseRef] {.
     async: (raw: true, raises: [CancelledError, HttpWriteError]).} =
  ## Responds to the request with redirection to location ``location``.
  redirect(req, code, location, HttpTable.init())

proc redirect*(req: HttpRequestRef, code: HttpCode,
               location: string): Future[HttpResponseRef] {.
     async: (raw: true, raises: [CancelledError, HttpWriteError]).} =
  ## Responds to the request with redirection to location ``location``.
  redirect(req, code, location, HttpTable.init())

proc responded*(req: HttpRequestRef): bool =
  ## Returns ``true`` if request ``req`` has been responded or responding.
  if isSome(req.response):
    if req.response.get().state == HttpResponseState.Empty:
      false
    else:
      true
  else:
    false

proc remoteAddress*(conn: HttpConnectionRef): TransportAddress {.
     raises: [HttpAddressError].} =
  ## Returns address of the remote host that established connection ``conn``.
  try:
    conn.transp.remoteAddress()
  except TransportOsError as exc:
    raiseHttpAddressError($exc.msg)

proc remoteAddress*(request: HttpRequestRef): TransportAddress {.
     raises: [HttpAddressError].} =
  ## Returns address of the remote host that made request ``request``.
  request.connection.remoteAddress()

proc requestInfo*(req: HttpRequestRef, contentType = "text/plain"): string =
  ## Returns comprehensive information about request for specific content
  ## type.
  ##
  ## Only two content-types are supported: "text/text" and "text/html".
  proc h(t: string): string =
    case contentType
    of "text/text":
      "\r\n" & t & " ===\r\n"
    of "text/html":
      "<h3>" & t & "</h3>"
    else:
      t
  proc kv(k, v: string): string =
    case contentType
    of "text/text":
      k & ": " & v & "\r\n"
    of "text/html":
      "<div><code><b>" & k & "</b></code><code>" & v & "</code></div>"
    else:
      k & ": " & v

  let header =
    case contentType
    of "text/html":
      "<html><head><title>Request Information</title>" &
      "<style>code {padding-left: 30px;}</style>" &
      "</head><body>"
    else:
      ""

  let footer =
    case contentType
    of "text/html":
      "</body></html>"
    else:
      ""

  var res = h("Request information")
  res.add(kv("request.scheme", $req.scheme))
  res.add(kv("request.method", $req.meth))
  res.add(kv("request.version", $req.version))
  res.add(kv("request.uri", $req.uri))
  res.add(kv("request.flags", $req.requestFlags))
  res.add(kv("request.TransferEncoding", $req.transferEncoding))
  res.add(kv("request.ContentEncoding", $req.contentEncoding))

  let body =
    if req.hasBody():
      if req.contentLength == 0:
        "present, size not available"
      else:
        "present, size = " & $req.contentLength
    else:
      "not available"
  res.add(kv("request.body", body))

  if not(req.query.isEmpty()):
    res.add(h("Query arguments"))
    for k, v in req.query.stringItems():
      res.add(kv(k, v))

  if not(req.headers.isEmpty()):
    res.add(h("HTTP headers"))
    for k, v in req.headers.stringItems(true):
      res.add(kv(k, v))

  if req.meth in PostMethods:
    if req.postTable.isSome():
      let postTable = req.postTable.get()
      if not(postTable.isEmpty()):
        res.add(h("POST arguments"))
        for k, v in postTable.stringItems():
          res.add(kv(k, v))

  res.add(h("Connection information"))
  let localAddress =
    try:
      $req.connection.transp.localAddress()
    except TransportError:
      "incorrect address"
  let remoteAddress =
    try:
      $req.connection.transp.remoteAddress()
    except TransportError:
      "incorrect address"

  res.add(kv("local.address", localAddress))
  res.add(kv("remote.address", remoteAddress))

  res.add(h("Server configuration"))
  let maxConn =
    if req.connection.server.maxConnections < 0:
      "unlimited"
    else:
      $req.connection.server.maxConnections
  res.add(kv("server.maxConnections", $maxConn))
  res.add(kv("server.maxHeadersSize", $req.connection.server.maxHeadersSize))
  res.add(kv("server.maxRequestBodySize",
             $req.connection.server.maxRequestBodySize))
  res.add(kv("server.backlog", $req.connection.server.backlogSize))
  res.add(kv("server.headersTimeout", $req.connection.server.headersTimeout))
  res.add(kv("server.baseUri", $req.connection.server.baseUri))
  res.add(kv("server.flags", $req.connection.server.flags))
  res.add(kv("server.socket.flags", $req.connection.server.socketFlags))
  header & res & footer

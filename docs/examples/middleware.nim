import chronos/apps/http/httpserver

{.push raises: [].}

proc firstMiddlewareHandler(
    middleware: HttpServerMiddlewareRef,
    reqfence: RequestFence,
    nextHandler: HttpProcessCallback2
): Future[HttpResponseRef] {.async: (raises: [CancelledError]).} =
  if reqfence.isErr():
    # Ignore request errors
    return await nextHandler(reqfence)

  let request = reqfence.get()
  var headers = request.headers

  if request.uri.path.startsWith("/path/to/hidden/resources"):
    headers.add("X-Filter", "drop")
  elif request.uri.path.startsWith("/path/to/blocked/resources"):
    headers.add("X-Filter", "block")
  else:
    headers.add("X-Filter", "pass")

  # Updating request by adding new HTTP header `X-Filter`.
  let res = request.updateRequest(headers)
  if res.isErr():
    # We use default error handler in case of error which will respond with
    # proper HTTP status code error.
    return defaultResponse(res.error)

  # Calling next handler.
  await nextHandler(reqfence)

proc secondMiddlewareHandler(
    middleware: HttpServerMiddlewareRef,
    reqfence: RequestFence,
    nextHandler: HttpProcessCallback2
): Future[HttpResponseRef] {.async: (raises: [CancelledError]).} =
  if reqfence.isErr():
    # Ignore request errors
    return await nextHandler(reqfence)

  let
    request = reqfence.get()
    filtered = request.headers.getString("X-Filter", "pass")

  if filtered == "drop":
    # Force HTTP server to drop connection with remote peer.
    dropResponse()
  elif filtered == "block":
    # Force HTTP server to respond with HTTP `404 Not Found` error code.
    codeResponse(Http404)
  else:
    # Calling next handler.
    await nextHandler(reqfence)

proc thirdMiddlewareHandler(
    middleware: HttpServerMiddlewareRef,
    reqfence: RequestFence,
    nextHandler: HttpProcessCallback2
): Future[HttpResponseRef] {.async: (raises: [CancelledError]).} =
  if reqfence.isErr():
    # Ignore request errors
    return await nextHandler(reqfence)

  let request = reqfence.get()
  echo "QUERY = [", request.rawPath, "]"
  echo request.headers
  try:
    if request.uri.path == "/path/to/plugin/resources/page1":
      await request.respond(Http200, "PLUGIN PAGE1")
    elif request.uri.path == "/path/to/plugin/resources/page2":
      await request.respond(Http200, "PLUGIN PAGE2")
    else:
      # Calling next handler.
      await nextHandler(reqfence)
  except HttpWriteError as exc:
    # We use default error handler if we unable to send response.
    defaultResponse(exc)

proc mainHandler(
    reqfence: RequestFence
): Future[HttpResponseRef] {.async: (raises: [CancelledError]).} =
  if reqfence.isErr():
    return defaultResponse()

  let request = reqfence.get()
  try:
    if request.uri.path == "/path/to/original/page1":
      await request.respond(Http200, "ORIGINAL PAGE1")
    elif request.uri.path == "/path/to/original/page2":
      await request.respond(Http200, "ORIGINAL PAGE2")
    else:
      # Force HTTP server to respond with `404 Not Found` status code.
      codeResponse(Http404)
  except HttpWriteError as exc:
    defaultResponse(exc)

proc middlewareExample() {.async: (raises: []).} =
  let
    middlewares = [
      HttpServerMiddlewareRef(handler: firstMiddlewareHandler),
      HttpServerMiddlewareRef(handler: secondMiddlewareHandler),
      HttpServerMiddlewareRef(handler: thirdMiddlewareHandler)
    ]
    socketFlags = {ServerFlags.TcpNoDelay, ServerFlags.ReuseAddr}
    boundAddress =
      if isAvailable(AddressFamily.IPv6):
        AnyAddress6
      else:
        AnyAddress
    res = HttpServerRef.new(boundAddress, mainHandler,
                            socketFlags = socketFlags,
                            middlewares = middlewares)

  doAssert(res.isOk(), "Unable to start HTTP server")
  let server = res.get()
  server.start()
  let address = server.instance.localAddress()
  echo "HTTP server running on ", address
  try:
    await server.join()
  except CancelledError:
    discard
  finally:
    await server.stop()
    await server.closeWait()

when isMainModule:
  waitFor(middlewareExample())

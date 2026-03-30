# ANCHOR: all
# ANCHOR: import
import chronos/apps/http/httpserver
import std/[json, tables, times, strutils]
# ANCHOR_END: import

var reports {.threadvar.}: Table[string, string]

# ANCHOR: middleware
proc loggingMiddleware(
    middleware: HttpServerMiddlewareRef,
    reqfence: RequestFence,
    nextHandler: HttpProcessCallback2
): Future[HttpResponseRef] {.async: (raises: [CancelledError]).} =
  let startTime = now()
  
  # Pass the request to the next handler in the chain
  let response = await nextHandler(reqfence)
  
  let duration = now() - startTime
  if reqfence.isOk():
    let request = reqfence.get()
    echo "$# $# processed in $#ms" % [$request.meth, request.uri.path, $duration.inMilliseconds]
  
  return response
# ANCHOR_END: middleware

# ANCHOR: handler
proc handler(reqfence: RequestFence): Future[HttpResponseRef] {.async: (raises: [CancelledError]).} =
  if reqfence.isErr():
    return defaultResponse()

  let request = reqfence.get()
  
  try:
    case request.uri.path
    of "/":
      return await request.respond(Http200, "Welcome to the Status Dashboard!")
    of "/status":
      var output = "Current Service Status:\n"
      if reports.len == 0:
        output.add("- No reports available.")
      else:
        for name, status in reports.pairs:
          output.add("- " & name & ": " & status & "\n")
      return await request.respond(Http200, output)
    of "/report":
      if request.meth != MethodPost:
        return await request.respond(Http405, "Method Not Allowed")

      let body = await request.getBody()
      let data =
        try:
          parseJson(bytesToString(body))
        except JsonParsingError:
          return await request.respond(Http400, "Invalid JSON.")
      
      let name = data["name"].getStr()
      let status = data["status"].getStr()
      reports[name] = status
      return await request.respond(Http200, "Report received.")
    else:
      return await request.respond(Http404, "Page not found.")
  except HttpWriteError, HttpTransportError, HttpProtocolError:
    return defaultResponse()
# ANCHOR_END: handler

# ANCHOR: main
proc main() {.async: (raises: [TransportAddressError, CancelledError]).} =
  reports = initTable[string, string]()
  let
    # ANCHOR: setup_middleware
    middlewares = [
      HttpServerMiddlewareRef(handler: loggingMiddleware)
    ]
    # ANCHOR_END: setup_middleware
    address = initTAddress("127.0.0.1:8080")
    res = HttpServerRef.new(address, handler, middlewares = middlewares)

  if res.isErr():
    echo "Unable to start HTTP server: " & res.error
    return

  let server = res.get()
  server.start()
  echo "HTTP server running on http://127.0.0.1:8080"
  
  try:
    await server.join()
  finally:
    await server.stop()
    await server.closeWait()
# ANCHOR_END: main

when isMainModule:
  waitFor main()
# ANCHOR_END: all

# ANCHOR: all
import chronos/apps/http/httpserver

# ANCHOR: handler
proc handler(reqfence: RequestFence): Future[HttpResponseRef] {.async: (raises: [CancelledError]).} =
  if reqfence.isErr():
    return defaultResponse()

  let request = reqfence.get()
  
  # ANCHOR: routing
  try:
    case request.uri.path
    of "/":
      return await request.respond(Http200, "Welcome to the Status Dashboard!")
    of "/status":
      return await request.respond(Http200, "The server is operational.")
    else:
      return await request.respond(Http404, "Page not found.")
  except HttpWriteError:
    return defaultResponse()
  # ANCHOR_END: routing
# ANCHOR_END: handler

# ANCHOR: main
proc main() {.async: (raises: [TransportAddressError, CancelledError]).} =
  let
    address = initTAddress("127.0.0.1:8080")
    res = HttpServerRef.new(address, handler)

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

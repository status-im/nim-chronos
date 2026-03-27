# ANCHOR: all
# ANCHOR: import
import chronos/apps/http/httpserver
# ANCHOR_END: import

# ANCHOR: handler
proc mainHandler(reqfence: RequestFence): Future[HttpResponseRef] {.async: (raises: [CancelledError]).} =
  if reqfence.isErr():
    return defaultResponse()

  let request = reqfence.get()
  
  try:
    return await request.respond(Http200, "Hello, Chronos!")
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    return defaultResponse(exc)
# ANCHOR_END: handler

# ANCHOR: main
proc main() {.async: (raises: [TransportAddressError, CancelledError]).} =
  let
    address = initTAddress("127.0.0.1:8080")
    res = HttpServerRef.new(address, mainHandler)

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

# ANCHOR: run
when isMainModule:
  waitFor main()
# ANCHOR_END: run
# ANCHOR_END: all

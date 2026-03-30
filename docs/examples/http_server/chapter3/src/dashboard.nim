# ANCHOR: all
# ANCHOR: import
import chronos/apps/http/httpserver
import std/[json, tables]
# ANCHOR_END: import

# ANCHOR: data
var reports {.threadvar.}: Table[string, string]
# ANCHOR_END: data

# ANCHOR: handler
proc handler(reqfence: RequestFence): Future[HttpResponseRef] {.async: (raises: [CancelledError]).} =
  if reqfence.isErr():
    return defaultResponse()

  let request = reqfence.get()
  
  try:
    case request.uri.path
    of "/":
      return await request.respond(Http200, "Welcome to the Status Dashboard!")
    
    # ANCHOR: status_get
    of "/status":
      var output = "Current Service Status:\n"
      if reports.len == 0:
        output.add("- No reports available.")
      else:
        for name, status in reports.pairs:
          output.add("- " & name & ": " & status & "\n")
      return await request.respond(Http200, output)
    # ANCHOR_END: status_get

    # ANCHOR: report_post
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
      echo "Received report: " & name & " is " & status
      
      return await request.respond(Http200, "Report received.")
    # ANCHOR_END: report_post

    else:
      return await request.respond(Http404, "Page not found.")
  except HttpWriteError, HttpTransportError, HttpProtocolError:
    return defaultResponse()
# ANCHOR_END: handler

# ANCHOR: main
proc main() {.async: (raises: [TransportAddressError, CancelledError]).} =
  reports = initTable[string, string]()
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

# ANCHOR: all
# ANCHOR: import
import chronos/apps/http/httpserver
import std/[json, tables]
# ANCHOR_END: import

# ANCHOR: handler_closure
proc handler(reports: TableRef[string, string]): HttpProcessCallback2 =
  proc(
      reqfence: RequestFence
  ): Future[HttpResponseRef] {.async: (raises: [CancelledError]).} =
# ANCHOR_END: handler_closure
    let request = reqfence.valueOr:
      return defaultResponse()

    try:
      case request.uri.path
      of "/":
        await request.respond(Http200, "Welcome to the Status Dashboard!")

      # ANCHOR: status_get
      of "/status":
        var output = "Current Service Status:\n"
        if reports.len == 0:
          output.add("- No reports available.")
        else:
          for name, status in reports:
            output.add("- " & name & ": " & status & "\n")
        await request.respond(Http200, output)
      # ANCHOR_END: status_get

      # ANCHOR: report_post
      of "/report":
        if request.meth != MethodPost:
          return await request.respond(Http405, "Method Not Allowed")

        let
          body = await request.getBody()
          data =
            try:
              parseJson(bytesToString(body))
            except CatchableError:
              return await request.respond(Http400, "Invalid JSON.")
          name =
            try:
              data["name"].getStr()
            except KeyError:
              return await request.respond(Http400, "Missing 'name' field.")
          status =
            try:
              data["status"].getStr()
            except KeyError:
              return await request.respond(Http400, "Missing 'status' field.")

        reports[name] = status
        echo "Received report: " & name & " is " & status

        await request.respond(Http200, "Report received.")
      # ANCHOR_END: report_post
      else:
        await request.respond(Http404, "Page not found.")
    except HttpError as exc:
      defaultResponse(exc)

proc main() {.async: (raises: [TransportAddressError, CancelledError]).} =
  # ANCHOR: reports_table
  var reports = newTable[string, string]()

  let
    address = initTAddress("127.0.0.1:8080")
    server = HttpServerRef.new(address, handler(reports)).valueOr:
      echo "Unable to start HTTP server: " & error
      return

  server.start()
  echo "HTTP server running on http://127.0.0.1:8080"
  # ANCHOR_END: reports_table

  try:
    await server.join()
  finally:
    await server.stop()
    await server.closeWait()

when isMainModule:
  waitFor main()
# ANCHOR_END: all

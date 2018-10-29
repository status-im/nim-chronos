import mofuw, packedjson, threadpool, os

proc h(ctx: MofuwCtx) {.async.} =
  case ctx.getPath
  of "/plaintext":
    mofuwResp(HTTP200, "text/plain", "Hello, World!")
  of "/json":
    mofuwResp(HTTP200, "application/json", $(%{"message": %"Hello, World!"}))
  else:
    mofuwResp(HTTP404, "text/plain", "NOT FOUND")

proc serveSingleThread*(ctx: ServeCtx) =
  if ctx.handler.isNil:
    raise newException(Exception, "Callback is nil. please set callback.")

  echo "SERVER RUNNING"
  spawn ctx.runServer(ctx.isSSL)

  when not defined noSync:
    sync()

proc main() =
  var srv = newServeCtx(port = 8080, handler = h)
  if os.getEnv("USE_THREADS") == "1":
    echo "use threads"
    srv.serve()
  else:
    echo "no threads"
    srv.serveSingleThread()

main()

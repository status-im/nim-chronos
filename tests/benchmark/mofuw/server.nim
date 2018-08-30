import mofuw, packedjson, threadpool

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

newServeCtx(
  port = 8080,
  handler = h
).serveSingleThread()

# use this if you want multithread mode
#).serve()


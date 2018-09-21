import strutils, posix, deques, times, strformat
import asyncdispatch2

proc getFormattedTime*(): string =
  result = format(getTime().inZone(utc()), "ddd, dd MMM yyyy hh:mm:ss 'GMT'")

type
  IncomingCtx = ref object
    buf: string
    bufLen: int
    resp: string
    respLen: int

  ServerCtx = ref object
    ctxQueue: Deque[IncomingCtx]
    serverTime: string

proc newIncomingCtx(readSize: int, writeSize: int): IncomingCtx =
  result = IncomingCtx(
    buf: newString(readSize),
    bufLen: 0,
    resp: newString(writeSize),
    respLen: 0
  )

proc newServerCtx*(readSize, writeSize: int, cap: int): ServerCtx =
  new(result)
  result.ctxQueue = initDeque[IncomingCtx](cap)
  var ctxArray = newSeq[IncomingCtx](cap)
  for i in 0 ..< cap:
    ctxArray[i] = newIncomingCtx(readSize, writeSize)
    GC_ref(ctxArray[i])
    result.ctxQueue.addFirst(ctxArray[i])

proc getServerTime*(srv: ServerCtx): string =
  result = srv.serverTime

proc updateServerTime*(srv: ServerCtx) =
  srv.serverTime = getFormattedTime()

proc createCtx*(readSize, writeSize: int): IncomingCtx =
  result = newIncomingCtx(readSize, writeSize)
  GC_ref(result)

proc getIncomingCtx*(srv: ServerCtx, readSize, writeSize: int): IncomingCtx =
  if srv.ctxQueue.len > 0:
    return srv.ctxQueue.popFirst()
  else:
    return createCtx(readSize, writeSize)

proc freeCtx*(srv: ServerCtx, ctx: IncomingCtx) =
  srv.ctxQueue.addLast(ctx)

proc resetBuffer(ctx: IncomingCtx) =
  ctx.respLen = 0
  ctx.bufLen = 0

proc sendMessage(ctx: IncomingCtx, body: string) =
  let ol = ctx.respLen
  while unlikely ctx.respLen + body.len > ctx.resp.len:
    ctx.resp.setLen(ctx.resp.len + ctx.resp.len)
  copyMem(addr ctx.resp[ol], unsafeAddr body[0], body.len)
  ctx.respLen += body.len

proc readMessage*(ctx: IncomingCtx, st: StreamTransport): Future[int] {.async.} =
  let rcvLimit =
    block:
      if unlikely(ctx.buf.len - ctx.bufLen == 0):
        ctx.buf.setLen(ctx.buf.len + ctx.buf.len)
      ctx.buf.len - ctx.bufLen

  let rcv = await st.readOnce(addr ctx.buf[ctx.bufLen], rcvLimit)
  ctx.bufLen += rcv
  return rcv

proc makeResp(serverTime: string): string =
  result = fmt("HTTP/1.1 200 OK\r\L" &
               "Date: {serverTime}\r\l" &
               "Server: asyncdispatch2\r\L" &
               "Content-Type: text/plain\r\L" &
               "Content-Length: 13\r\L\r\L" &
               "Hello, World!")

proc handleIncoming(srv: ServerCtx, ctx: IncomingCtx, st: StreamTransport) {.async.} =
  try:
    while true:
      let rcv = await ctx.readMessage(st)
      if rcv == 0:
        st.close()
        srv.freeCtx(ctx)
        return

      var pos = 0
      while (ctx.bufLen - pos) > 3:
        if ctx.buf[pos] == '\r':
          if ctx.buf[pos+1] == '\L' and
            ctx.buf[pos+2] == '\r' and
            ctx.buf[pos+3] == '\L':
            ctx.sendMessage(makeResp(srv.serverTime))
        inc pos

      let wr = await st.write(ctx.resp[0].addr, ctx.respLen)
      assert wr == ctx.respLen
      ctx.resetBuffer()
  except:
    st.close()
    srv.freeCtx(ctx)

proc handleConnection(ss: StreamServer, st: StreamTransport) {.async.} =
  var srv = getUserData[ServerCtx](ss)
  var ctx = srv.getIncomingCtx(1024, 1024)
  ctx.resetBuffer()
  asyncCheck handleIncoming(srv, ctx, st)

proc handleBreak(udata: pointer) =
  var cdata = cast[ptr CompletionData](udata)
  var svr = cast[StreamServer](cdata.udata)
  echo "\nCTRL+C pressed, stopping server..."
  svr.stop()
  svr.close()

proc updateTime(arg: pointer = nil) {.gcsafe.} =
  var svr = cast[ServerCtx](arg)
  svr.updateServerTime()

proc serve(onAddress: string) =
  let
    ta = initTAddress(onAddress)
    ctx = newServerCtx(1024, 1024, 128)
    svr = createStreamServer(ta, handleConnection, {ReuseAddr}, backlog = 128, udata = cast[pointer](ctx))
  when not defined(windows):
    discard addSignal(SIGINT, handleBreak, udata = cast[pointer](svr))

  ctx.updateServerTime()
  addTimer(1000, updateTime, udata = cast[pointer](ctx))

  svr.start()
  echo "Server started at ", ta
  waitFor svr.join()

when isMainModule:
  serve("0.0.0.0:8080")

#              Asyncdispatch2 Test Suite
#                 (c) Copyright 2018
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

import asyncnet, asyncdispatch, nativesockets, net, strformat, times
import deques

when defined(windows):
  from winlean import TCP_NODELAY
else:
  from posix import TCP_NODELAY

type
  KeyboardInterruptError = object of Exception

proc handleCtrlC() {.noconv.} =
  raise newException(KeyboardInterruptError, "Keyboard Interrupt")

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
  while unlikely ctx.respLen + body.len > ctx.resp.len:
    ctx.resp.setLen(ctx.resp.len + ctx.resp.len)
  let ol = ctx.respLen
  copyMem(addr ctx.resp[ol], unsafeAddr body[0], body.len)
  ctx.respLen += body.len

const timeOut = 30 * 1000

proc readMessage*(ctx: IncomingCtx, client: AsyncSocket): Future[int] {.async.} =
#proc readMessage*(ctx: IncomingCtx, client: AsyncFD): Future[int] {.async.} =
  let rcvLimit =
    block:
      if unlikely(ctx.buf.len - ctx.bufLen == 0):
        ctx.buf.setLen(ctx.buf.len + ctx.buf.len)
      ctx.buf.len - ctx.bufLen

  #let fut = client.recvInto(addr ctx.buf[ctx.bufLen], rcvLimit)
  #let isSuccess = await withTimeout(fut, timeOut)
  #let rcv = if isSuccess: fut.read else: 0
  let rcv = await client.recvInto(addr ctx.buf[ctx.bufLen], rcvLimit)
  ctx.bufLen += rcv
  return rcv

proc makeResp(serverTime: string): string =
  result = fmt("HTTP/1.1 200 OK\r\L" &
               "Date: {serverTime}\r\l" &
               "Server: asyncnet\r\L" &
               "Content-Type: text/plain\r\L" &
               "Content-Length: 13\r\L\r\L" &
               "Hello, World!")

#proc handleIncoming(srv: ServerCtx, ctx: IncomingCtx, client: AsyncFD) {.async.} =
proc handleIncoming(srv: ServerCtx, ctx: IncomingCtx, client: AsyncSocket) {.async.} =
  while true:
    let rcv = await ctx.readMessage(client)
    if rcv == 0:
      #closeSocket(client)
      client.close()
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

    let fut = client.send(ctx.resp[0].addr, ctx.respLen)
    yield fut
    if fut.failed:
      #closeSocket(client)
      client.close()
      srv.freeCtx(ctx)
      return
    ctx.resetBuffer()

#proc handleConnection(srv: ServerCtx, client: AsyncFD) {.async.} =
proc handleConnection(srv: ServerCtx, client: AsyncSocket) {.async.} =
  var ctx = srv.getIncomingCtx(1024, 1024)
  ctx.resetBuffer()
  asyncCheck handleIncoming(srv, ctx, client)

#proc newServerSocket*(port: int): SocketHandle =
#  let server = newSocket()
#  server.setSockOpt(OptReuseAddr, true)
#  server.setSockOpt(OptReusePort, true)
#  server.getFd().setSockOptInt(cint(IPPROTO_TCP), TCP_NODELAY, 1)
#  server.getFd.setBlocking(false)
#  server.bindAddr(Port(port))
#  server.listen()
#  return server.getFd()

proc newServerSocket(port: int): AsyncSocket =
  var server = newAsyncSocket(buffered=false)
  server.setSockOpt(OptReuseAddr, true)
  server.setSockOpt(OptReusePort, true)
  server.getFd().setSockOptInt(cint(IPPROTO_TCP), TCP_NODELAY, 1)
  server.getFd.setBlocking(false)
  server.bindAddr(Port(port))
  server.listen()
  result = server

proc serve() {.async.} =
  let
    #server = newServerSocket(8080).AsyncFD
    server = newServerSocket(8080)
    ctx = newServerCtx(1024, 1024, 128)

  #register(server)
  proc updateTime(fd: AsyncFD): bool =
    ctx.updateServerTime()

  addTimer(1000, false, updateTime)

  var cantAccept = false
  while true:
    if unlikely cantaccept:
      await sleepAsync(1)
      cantAccept = true

    try:
      #let data = await acceptAddr(server)
      #asyncCheck handleConnection(ctx, data.client)
      let client = await server.accept()
      asyncCheck handleConnection(ctx, client)
    except:
      cantAccept = true

when isMainModule:
  setControlCHook(handleCtrlC)
  waitFor serve()

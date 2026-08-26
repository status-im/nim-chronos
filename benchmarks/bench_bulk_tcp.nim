# Simple benchmark that bulk-streams data from one thread to another using TCP

import std/strformat, chronos, chronos/threadsync

var buf: array[1024 * 1024, byte]

proc handleConn(transport: StreamTransport) {.async.} =
  var
    total = 0
    reads = 0
    last = Moment.now()

  while true:
    let n = await transport.readOnce(addr buf[0], buf.len)
    total += n
    reads += 1
    var x = Moment.now()
    if x - last >= 1.seconds:
      let
        tdiff = (x - last).nanoseconds().float / 1000000000.0
        mbps = total.float / tdiff / (1024 * 1024)
        rps = reads.float / tdiff
        bpr = total.float / reads.float

      echo &"{mbps:.3f} MB/s {rps:.3f} reads/s {bpr:.3f} bytes/read"
      last = x
      total = 0
      reads = 0

var
  serverAddress: TransportAddress
  started: ThreadSignalPtr

proc runServer() {.thread, nimcall.} =
  let server = createStreamServer(initTAddress("127.0.0.1:0"))

  serverAddress = server.localAddress()
  discard started.fireSync().expect("ok")

  let conn = waitFor server.accept()
  waitFor(handleConn(conn))

proc runClient() {.async.} =
  let
    client = await connect(serverAddress)
    start = Moment.now()

  while Moment.now() - start < 10.seconds:
    discard await client.write(addr buf[0], buf.len)

started = ThreadSignalPtr.new().expect("can create signal")
var server: Thread[void]
createThread(server, runServer)
discard started.waitSync().expect("ok")

waitFor runClient()

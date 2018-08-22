import strutils, posix

import asyncdispatch2

const DOUBLECRLF = @['\r'.byte, '\L'.byte, '\r'.byte, '\L'.byte]

proc handleConnection(ss: StreamServer, st: StreamTransport) {.async.} =
  var resp = "HTTP/1.1 200 OK\r\L" &
             "Content-Length: 15\r\L\r\L" &
             "Hello, World!\r\L"
  var readBuff: array[256, byte]
  while not st.atEof:
    try:
      let read = await st.readUntil(addr readBuff[0], len(readBuff), DOUBLECRLF)
    except:
      break
    let w = await st.write(addr resp[0], resp.len)
    assert w == resp.len
  st.close()

proc handleBreak(udata: pointer) =
  var cdata = cast[ptr CompletionData](udata)
  var svr = cast[StreamServer](cdata.udata)
  echo "\nCTRL+C pressed, stopping server..."
  svr.stop()
  svr.close()

proc serve(onAddress: string) =
  let
    ta = initTAddress(onAddress)
    svr = createStreamServer(ta, handleConnection, {ReuseAddr}, backlog = 128)
  when not defined(windows):
    discard addSignal(SIGINT, handleBreak, udata = cast[pointer](svr))
  svr.start()
  echo "Server started at ", ta
  try:
    waitFor svr.join()
  except:
    echo "Error happens: ", getCurrentExceptionMsg()
  finally:
    echo "bye!"

when isMainModule:
  serve("0.0.0.0:8080")

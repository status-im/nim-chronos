## Simple client for the TCP echo servers - to run, take note of the port that
## the server runs on and launch with (assuming the server is running on the
## same machine):
##
## ./tcpclient 127.0.0.1 port

import std/[os, strformat, strutils], chronos

proc handleConnection(transport: StreamTransport, id: int) {.async.} =
  try:
    for i in 0 ..< 4:
      if id == 2:
        # tcpserver2 shuts down on a lonely "q"!
        echo "Send the magic quit signal"
        discard await transport.write("q\r\n")
      else:
        echo "Client ", id, " sending ", i
        discard await transport.write(&"Hello {i} from {id}\r\n")

      # Read the response
      let response = await transport.readLine()
      if response == "":
        # `readLine` will return an empty line when the connection is closed!
        break
      echo "Got response: ", response

      await sleepAsync(500.milliseconds)
  except TransportError as exc:
    echo "Connection error: ", exc.msg
  finally:
    # Ensure the connection is closed properly
    await transport.closeWait()

proc main() {.async.} =
  if paramCount() < 2:
    echo "Usage: tcpclient <server> <port>"
    quit(1)

  let
    server = paramStr(1)
    port = parseInt(paramStr(2))

  var clients: seq[Future[void]]
  for i in 0 ..< 3:
    echo "Connecting to ", server, ":", port, ", ", i
    let client = await connect(initTAddress(server, port))
    clients.add handleConnection(client, i)
    await sleepAsync(300.milliseconds)

  # Wait for each handler to end
  for c in clients:
    await c

waitFor main()

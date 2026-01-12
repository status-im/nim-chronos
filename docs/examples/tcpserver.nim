## Minimal TCP/IP echo server that accepts both IPv4 and IPv6 connections.

import chronos

# `handleConn` is a worker task that handles the communication with a single
# client.
proc handleConn(transport: StreamTransport) {.async: (raises: []).} =
  try:
    echo "Incoming connection from ", transport.remoteAddress()

    while true:
      # Read and echo back lines until an empty line is entered
      let line = await transport.readLine()
      case line
      of "":
        break
      else:
        # Echo back the line assuming all bytes were written
        discard await transport.write(line & "\r\n")
        echo "Echoed: ", line
  except CatchableError as exc:
    # Since the task runs independently, it must perform its own error handling
    # and clean after the client disconnects to avoid leaks and crashes!
    echo "Connection problem! ", exc.msg
  finally:
    # Connections must always be closed to avoid resource leaks
    await transport.closeWait()

proc myApp(server: StreamServer) {.async: (raises: [CancelledError]).} =
  while true:
    # `accept` starts a task that waits for a client to connect to the server.
    # `await` will return when this task completes allowing other tasks to run
    # while waiting.
    let connection =
      try:
        await server.accept()
      except TransportError as exc:
        echo "Error accepting connection: ", exc.msg
        continue

    # Similar to `accept`, `handleConn` starts a task since it's marked with
    # `{.async.}`.
    # `asyncSpawn` marks the task as running in the background allowing
    # the loop to continue without waiting for `handleConn` to finish.
    asyncSpawn handleConn(connection)

# Create a server socket that listens for both IPv4 and IPv6 on a random port
let server = createStreamServer(AnyAddress6)

echo "Accepting connections on ", server.local

# `myApp` never finishes, so this will run forever!
waitFor myApp(server)

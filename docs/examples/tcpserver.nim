## Simple TCP/IP server that accepts both IPv4 and IPv6 connections
import chronos

# Because handleConn runs as an indepented task via `asyncSpawn`, it must
# handle all errors on its own (or the application will crash)
proc handleConn(transport: StreamTransport, done: Future[void]) {.
    async: (raises: []).} =
  # Handle a single remote connection
  try:
    echo "Incoming connection from ", transport.remoteAddress()

    while true:
      # Read and echo back lines until `q` or `0` is entered
      let data = await transport.readLine(sep="\n")
      if data.len > 0:
        if data[0] == 'q':
          if not done.finished():
            # Notify server that it's time to stop - some other client could
            # have done this already, so we check with `finished` first
            done.complete()
            break
        elif data[0] == '0':
          break # Stop reading and close the connection

      echo "Echoed ", await transport.write(data & "\n"), " bytes"
  except CancelledError:
    raiseAssert "No cancellations in this example"
  except TransportError as exc:
    echo "Connection problem! ", exc.msg
  finally:
    # Connections must always be closed to avoid resource leaks
    await transport.closeWait()

proc myApp(server: StreamServer) {.async.} =
  echo "Accepting connections on ", server.local
  let done = Future[void].init()
  try:
    while true:
      let
        accept = server.accept()

      # Wait either for a new connection or that an existing connection signals
      # that it's time to stop
      discard await race(accept, done)
      if done.finished(): break

      # asyncSpawn is used to spawn an independent async task that runs until
      # it's finished without blocking the current async function - the OS will
      # clean up these tasks on shutdown but a long-running server will want to
      # collect them and make sure their associated sockets are closed properly
      asyncSpawn handleConn(accept.read(), done)
  finally:
    await server.closeWait()

let
  # This server listens on both IPv4 and IPv6 and will pick a port number by
  # itself
  server = createStreamServer(AnyAddress6)

waitFor myApp(server)

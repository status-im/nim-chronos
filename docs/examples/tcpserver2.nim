## TCP/IP echo server that accepts both IPv4 and IPv6 connections.
##
## Unlike `tcpserver.nim`, this version performs a controlled shutdown by
## cancelling all client handlers before the server loop ends.
##
## This example also takes care not to allow exceptions to crash the application
## as is customary when writing server / library code.
import std/sequtils, chronos

{.push raises: [].} # Prevent spurious exceptions at compile time!

# A future without a value that can be used to wake up `async` tasks
type Sentinel = Future[void].Raising([CancelledError])

# `handleConn` is a worker task that handles the communication with a single
# client.
#
# The future it returns can be cancelled to end the task, closing the connection
# and reclaiming any resources before it ends.
proc handleConn(
    transport: StreamTransport, shutdown: Sentinel
) {.async: (raises: [CancelledError]).} =
  try:
    echo "Incoming connection from ", transport.remoteAddress()

    while true:
      # Read and echo back lines until `q` or an empty line is entered
      let line = await transport.readLine()
      case line
      of "":
        break
      of "q":
        # Notify server that it's time to stop - some other client could
        # have done this already, so we check with `finished` first
        echo "Got quit signal!"
        if not shutdown.finished():
          shutdown.complete()
        break
      else:
        # Echo back the line assuming all bytes were written
        discard await transport.write(line & "\r\n")
        echo "Echoed: ", line
  except TransportError as exc:
    echo "Connection problem! ", exc.msg
  except CancelledError:
    # The main loop is notifying us that it's time to shut down - cancellations
    # should not be interrupted, so we use `noCancel` and a timeout to ensure
    # that we end the read loop in a timely manner
    discard
      await noCancel transport.write("Shutting down\r\n\r\n").withTimeout(1.seconds)
  finally:
    # Connections must always be closed to avoid resource leaks
    await transport.closeWait()

proc myApp() {.async: (raises: [CancelledError]).} =
  # This server listens on both IPv4 and IPv6 and will pick a port number by
  # itself - this may fail, in which case an exception will be raised!
  let server =
    try:
      createStreamServer(AnyAddress6)
    except TransportError as exc:
      echo "Could not create server: ", exc.msg
      return

  echo "Accepting connections on ", server.local

  # A sentinel future allows clients to notify the server that we're shutting
  # down
  let shutdown = Sentinel.init()

  var clients: seq[Future[void].Raising([CancelledError])]
  try:
    while not shutdown.finished():
      # `accept` starts a task that waits for a client to connect to the server.
      # Because there is no `await` here, execution will continue even if there
      # is no client connecting right now.
      let accept = server.accept()

      # `race` starts a task that completes when at least one of the given
      # subtasks has finished, returning the one that finished first (which we
      # discard because we don't care about order)
      discard await race(accept, shutdown)

      # With `race`, one or both of `accept` and `shutdown` could have finished
      # so we'll always check `accept` to make sure we don't miss a connection
      # in the case that it's both!
      if accept.finished():
        let connection =
          try:
            # `await` can also be used to read the outcome of a finished task -
            # exceptions here could indicate that the client got disconnected
            # while it was queuing to be accepted.
            await accept
          except TransportError as exc:
            echo "Error accepting connection: ", exc.msg
            continue

        # Instead of using `asyncSpawn` to run tasks in the background, we'll
        # collect them in a list that later can be used to perform cleanup
        clients.add handleConn(connection, shutdown)

      # Occasionally clean up clients that already disconnected
      clients.keepItIf(not it.finished)
  finally:
    # Stop accepting new connections and release the server handle
    await server.closeWait()

    # Then stop all the client handlers by cancelling them - each client
    # handler will clean up after itself as part of its cancellation handler
    await cancelAndWait(clients)

waitFor myApp()

echo "Bye!"

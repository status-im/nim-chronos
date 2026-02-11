# Timeouts & Cancellation

**Goal:** Learn how to prevent the program from freezing on slow responses.

Our current program works fine with the well-behaving URIs we've tested so far: all these locations either respond quickly or quickly return an error.

However, not all requests will go smoothly when you face the real web. Poor connections, slow servers, anti-bot checks, and access restrictions result in responses that may take long to complete or even never complete. One "misbehaving" request can negatively affect the entire program.

For example, try adding an IP address the never responds to the list:

```nim
const uris =
  @[
    "https://duckduckgo.com/?q=chronos", "https://www.google.fr/search?q=chronos",
    "https://mock.codes/403", "http://123.456.78.90",
    "http://10.255.255.1",
  ]
```

Run the program and you'll see that it'll run for 10+ seconds, stuck on this last IP.

Let's add a timeout to our requests to cancel slow requests before they ruin our app: if a request takes longer than 5 seconds, we cancel it.

```nim
import chronos/apps/http/httpclient

const uris = @[
  "https://duckduckgo.com/?q=chronos", "https://www.google.fr/search?q=chronos",
  "https://mock.codes/403", "http://123.456.78.90", "http://10.255.255.1",
]

proc check(session: HttpSessionRef, uri: string) {.async.} =
  try:
    let responseFuture = session.fetch(parseUri(uri))

    if await responseFuture.withTimeout(5.seconds):
      let response = responseFuture.read()
      if response.status == 200:
        echo "[OK] " & uri
      else:
        echo "[NOK] " & uri & ": " & $response.status
    else:
      raise newException(AsyncTimeoutError, "Connection timed out")
  except CatchableError:
    echo "[ERR] " & uri & ": " & getCurrentExceptionMsg()

proc check(uris: seq[string]) {.async.} =
  let session = HttpSessionRef.new()
  var futures: seq[Future[void]]

  for uri in uris:
    futures.add(session.check(uri))

  await allFutures(futures)
  await noCancel(session.closeWait())

when isMainModule:
  waitFor check(uris)
```

Here's the part that changed:

```nim
proc check(session: HttpSessionRef, uri: string) {.async.} =
  try:
    let responseFuture = session.fetch(parseUri(uri))

    if await responseFuture.withTimeout(5.seconds):
      let response = responseFuture.read()
      if response.status == 200:
        echo "[OK] " & uri
      else:
        echo "[NOK] " & uri & ": " & $response.status
    else:
      raise newException(AsyncTimeoutError, "Connection timed out")
  except CatchableError:
    echo "[ERR] " & uri & ": " & getCurrentExceptionMsg()
```

1. We create a `Future` before awaiting on it.
2. Then we `await` it with the special `withTimeout` modifier. This modifier returns `true` if the `Future` passed to it completed before the timeout and `false` otherwise.
3. If the timeout exhausted before we got our response, we raise an exception that is caught downstream. 

Run the program again and you'll see it complete in roughly 5 seconds, i.e. our timeout.

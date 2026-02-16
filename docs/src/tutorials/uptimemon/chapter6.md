# Scaling & Finishing Touches

**Goal:** Learn how to use semaphores to control concurrency.

**Source code:** [chapter6.nim](https://github.com/status-im/nim-chronos/blob/master/docs/examples/uptimemon/chapter6.nim)

Our app is almost ready to run on production and do regular background URI checks.

However, there's one issue we need to address before we can feed it tens of URIs and wrap it in a `while true`: we need to limit the number of simultaneous checks. If we don't do that, our app can potentially run out of file descriptors or choke the DNS resolver with 20+ requests.

Instead of simultaneusly launching checks for all URIs in the list, we'll run them in batches of 5, i.e. no more than 5 checks will run at any given moment, keeping resource usage low and under control.

To achieve that, we'll use a _semaphore_—an special object that a function must acquire to run and must release after it's finished. A semaphore can be acquired by a fixed number of function at any moment, and this is how it regulates concurrency.

Here's the code with a semaphore and an infinite loop added:

```nim
import chronos/apps/http/httpclient

const
  maxConcurrency = 5
  ntfyTopic = "X3JIaLZSrFqBJXfJ"
  uris = @[
    "https://duckduckgo.com/?q=chronos", "https://mock.codes/403",
    "http://123.456.78.90", "http://10.255.255.1", "https://html.spec.whatwg.org",
    "https://mock.codes/200", "https://github.com", "https://archive.org",
    "https://nim-lang.org", "https://w3.org", "https://free.technology",
    "https://codeberg.org", "https://nimble.directory", "https://status.app",
    "https://keycard.tech", "https://stackoverflow.com", "https://nimbus.team",
    "https://logos.co", "https://forum.nim-lang.org", "https://acid.info",
    "https://vac.dev", "https://expired.badssl.com", "http://10.255.255.2",
    "http://10.255.255.3",
  ]

proc sendAlert(session: HttpSessionRef, message: string, priority = 3) {.async.} =
  let
    headers = {"Title": "Chronos Uptime Monitor", "Priority": $priority}
    body = message.stringToBytes()
    request = HttpClientRequestRef.new(
      session,
      "https://ntfy.sh/" & ntfyTopic,
      meth = MethodPost,
      headers = headers,
      body = body,
    )

  if request.isOk:
    try:
      let response = await request.get.send()
      await response.closeWait()
    except CatchableError:
      echo "[WRN] Failed to send alert: " & getCurrentExceptionMsg()

proc findMarker(response: HttpClientResponseRef): Future[bool] {.async.} =
  let bodyReader = response.getBodyReader()

  var
    buffer = newSeq[byte](1024)
    fetchedBytes: seq[byte]

  while not result and len(fetchedBytes) <= 10 * 1024:
    let bytesRead = await bodyReader.readOnce(addr(buffer[0]), len(buffer))

    if bytesRead == 0:
      break

    fetchedBytes &= buffer

    result = "<html" in bytesToString(fetchedBytes)

proc check(session: HttpSessionRef, uri: string, semaphore: AsyncSemaphore) {.async.} =
  await acquire(semaphore)

  defer:
    release (semaphore)

  try:
    let request = HttpClientRequestRef.new(session, uri)

    if request.isErr:
      raise newException(HttpRequestError, request.error)

    let responseFuture = request.get.send()

    if await responseFuture.withTimeout(5.seconds):
      let response = responseFuture.read()

      if response.status == 200:
        let markerFound = await findMarker(response)

        if markerFound:
          echo "[OK] " & uri
        else:
          let message = "[NOK] " & uri & ": Not valid HTML"
          echo message
          await session.sendAlert(message)
      else:
        let message = "[NOK] " & uri & ": " & $response.status
        echo message
        await session.sendAlert(message)
    else:
      raise newException(AsyncTimeoutError, "Connection timed out")
  except CatchableError:
    let message = "[ERR] " & uri & ": " & getCurrentExceptionMsg()
    echo message
    await session.sendAlert(message, 4)

proc check(uris: seq[string]) {.async.} =
  let
    session = HttpSessionRef.new()
    semaphore = newAsyncSemaphore(maxConcurrency)

  while true:
    echo "Checking " & $len(uris) & " URIs:"
    var futures: seq[Future[void]]

    for uri in uris:
      futures.add(session.check(uri, semaphore))

    await allFutures(futures)

    echo "Done. Next check in 10 seconds."
    await sleepAsync(10.seconds)

  await noCancel(session.closeWait())

when isMainModule:
  waitFor check(uris)
```

Let's see what changed.

```nim
const
  maxConcurrency = 5
```

We define a constant that would determine the capacity of our semaphore.

```nim
uris = @[
  "https://duckduckgo.com/?q=chronos", "https://mock.codes/403",
  "http://123.456.78.90", "http://10.255.255.1", "https://html.spec.whatwg.org",
  "https://mock.codes/200", "https://github.com", "https://archive.org",
  "https://nim-lang.org", "https://w3.org", "https://free.technology",
  "https://codeberg.org", "https://nimble.directory", "https://status.app",
  "https://keycard.tech", "https://stackoverflow.com", "https://nimbus.team",
  "https://logos.co", "https://forum.nim-lang.org", "https://acid.info",
  "https://vac.dev", "https://expired.badssl.com", "http://10.255.255.2",
  "http://10.255.255.3",
]
```

We've added more URIs to the list to make batching effect visible.

```nim
proc check(session: HttpSessionRef, uri: string, semaphore: AsyncSemaphore) {.async.} =
  await acquire(semaphore)

  defer:
    release (semaphore)
```

We've modified `check` function for a single URI so that it accepts a `semaphore` (of type[`AsyncSemaphore`](/api/chronos/asyncsync.html#AsyncSemaphore)), waits to [`acquire`](/api/chronos/asyncsync.html#acquire,AsyncSemaphore) it, and [`release`](/api/chronos/asyncsync.html#release,AsyncSemaphore)s it at the end (we use `defer` to postpone the release).

With this short addition, we prevent `check` from running if the semaphore is full.

```nim
proc check(uris: seq[string]) {.async.} =
  let
    session = HttpSessionRef.new()
    semaphore = newAsyncSemaphore(maxConcurrency)
```

In the `check` function for a URI sequence, we create a semaphore of the required capacity.

```nim
while true:
  echo "Checking " & $len(uris) & " URIs:"
```

Instead of a one off launch, we do the checks in an infinite loop.

We've added an `echo` to denote the start of each cycle.

```nim
for uri in uris:
  futures.add(session.check(uri, semaphore))
```

Then we pass the semaphore to `check` for each URI.

```nim
echo "Done. Next check in 10 seconds."
await sleepAsync(10.seconds)
```

Finally, print the message to mark the end of a cycle and wait 10 seconds before the next one.

Run the program and you'll see an even flow of statuses in your terminal.

```admonish important
To stop the program press Ctrl+C.
```

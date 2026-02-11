# Smarter Health Check

**Goal:** Learn how to use streaming to check web page content without fully downloading it.

Currently, we're using `fetch` to make a GET request and check its result. However, this function doesn't give us just the response status, it gives us the full response. That means that we're downloading the entire page just to check the response status. This is not optimal: if a page is large (or the server is serving some huge file), our program will consume unnecessary amount of memory to store that response and waste a lot of time downloading it.

## Getting Just the Status

Let's fix the redundant content fetching first. To do that, we'll replace the `fetch` call, which creates and sends a request, with manually creating and sending the request:

```nim
import chronos/apps/http/httpclient

const uris = @[
  "https://duckduckgo.com/?q=chronos", "https://www.google.fr/search?q=chronos",
  "https://mock.codes/403", "http://123.456.78.90", "http://10.255.255.1",
  "http://demo.borland.com/testsite/stadyn_largepagewithimages.html",
]

proc check(session: HttpSessionRef, uri: string) {.async.} =
  try:
    let request = HttpClientRequestRef.new(session, uri)

    if request.isErr:
      raise newException(HttpError, "Invalid URI")

    let responseFuture = request.get.send()

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

These are the lines that changed:

```nim
let request = HttpClientRequestRef.new(session, uri)
```

We explicitly create a GET request.

```nim
if request.isErr:
  raise newException(HttpError, "Invalid URI")
```

Request creation can fail if URI resolution was unsuccessful, so we need to check that before proceeding.

```admonition warning
You may wonder why not just let it fail as we have this whole section wrapped in a `try` block anyway.

The reason we do an explicit check is that if there had been an error during request creation and we called `get` on it, a `ResultDefect` would be raised. It is not a `CatchableError` and would therefore leak and crash the program.
```

```nim
let responseFuture = request.get.send()
```

Despite the fact that the rest of the code is the same, one very important thing changed: `response` is now a `HttpClientResponseRef` and not a `HttpResponseTuple`. The former doesn't contain the webpage content and therefore occupies much less memory.

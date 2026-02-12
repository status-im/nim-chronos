# Smarter Health Check

**Goal:** Learn how to use streaming to check web page content without fully downloading it.

Currently, we're using `fetch` to make a GET request and check its result. However, this function doesn't give us just the response status, it gives us the full page content as well.

While this is correct, it's not optimal: if a page is large, our program will consume unnecessary amount of memory to store that response and waste a lot of time downloading it.

For example, try adding this URI to the list and running the program: https://html.spec.whatwg.org. This is a proper page but it's so heavy fetching it entirely would time out:

```shell
[ERR] http://123.456.78.90: Could not resolve address of remote server
[NOK] https://mock.codes/403: 403
[OK] https://duckduckgo.com/?q=chronos
[ERR] http://10.255.255.1: Connection timed out
[ERR] https://html.spec.whatwg.org/: Connection timed out
```

Let's optimize our check to handle large page like this one.

## Getting Just the Status

First, let's not download the page and just check the response status.

To do that, instead of using `fetch`, we'll create the request manually:

```nim
import chronos/apps/http/httpclient

const uris = @[
  "https://duckduckgo.com/?q=chronos", "https://mock.codes/403", "http://123.456.78.90",
  "http://10.255.255.1", "https://html.spec.whatwg.org/",
]

proc check(session: HttpSessionRef, uri: string) {.async.} =
  try:
    let request = HttpClientRequestRef.new(session, uri)

    if request.isErr:
      raise newException(HttpRequestError, request.error)

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

Here are the new lines that replace `let responseFuture = session.fetch(parseUri(uri))`:

```nim
let request = HttpClientRequestRef.new(session, uri)
```

We explicitly create a GET request.

```nim
if request.isErr:
  raise newException(HttpRequestError, request.error)
```

Request creation can fail, so we need to check that before proceeding: if an error happened, raise a `HttpRequestError` to be caught downstream. We use `request.error` to get the message of the error.

```admonish note
You may wonder why we do an explicit check while the entire block is already wrapped in `try`.

That's because `request.get` raises `ResultDefect` if request creation failed which is not a `CatchableError` and would slip through our `except`.
```

```nim
let responseFuture = request.get.send()
```

We send the request and get a `Future`, which we can await on later just like before.

Run the program and you'll see the correct `[OK]` result for https://html.spec.whatwg.org:

```shell
[ERR] http://123.456.78.90: Could not resolve address of remote server
[NOK] https://mock.codes/403: 403
[OK] https://duckduckgo.com/?q=chronos
[OK] https://html.spec.whatwg.org/
[ERR] http://10.255.255.1: Connection timed out
```

## Streaming the Body

Checking just the status speeds up our program but by ignoring the body entirely, we can miss URIs that do not serve valid HTML content. We need a way to check the content but do that without downloading the whole page.

Chronos allows streaming response body, so let's use this feature to fetch content in chunks, check the collected data for a certain health marker (e.g. "<html" string), and stop immediatelly when we find it or download a certain amount of data:

```nim
import chronos/apps/http/httpclient

const uris = @[
  "https://duckduckgo.com/?q=chronos", "https://mock.codes/403", "http://123.456.78.90",
  "http://10.255.255.1", "https://html.spec.whatwg.org/", "https://mock.codes/200",
]

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

proc check(session: HttpSessionRef, uri: string) {.async.} =
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
          echo "[NOK] " & uri & ": Not valid HTML"
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

Let's go through the changes in this version line by line.

```nim
"http://10.255.255.1", "https://html.spec.whatwg.org/", "https://mock.codes/200",
```

We've added a new URI to our test: https://mock.codes/200. This is a valid URI that returns a 200 status response but it doesn't contain any meaningful data. With our old check, this would return `[OK]` and with the new one we expect it to be `[NOK]`.

```nim
proc findMarker(response: HttpClientResponseRef): Future[bool] {.async.} =
```

This is a new function that is responsible to finding the health marker in a given response. Because it is asynchrounous, it will not block the main thread when called.

Like any async function, it returns a `Future` that must be `await`ed to give the actual result.

```admonish note
If you see an async function without a return type, this async function simply returns a `Future[void]`.
```

```nim
let bodyReader = response.getBodyReader()
```

To stream the response body, we're using a `bodyReader`. To get one for the current response, we're calling `getBodyReader()`.

```nim
var
  buffer = newSeq[byte](1024)
  fetchedBytes: seq[byte]
```

We'll be reading raw bytes so to store them we create two byte sequences:

- `buffer` will hold the current chunk of maximum lengh 1024 (i.e. 1 KB)
- `fetchedBytes` is a sequence of bytes that have been collected so far

```nim
while not result and len(fetchedBytes) <= 10 * 1024:
```

Now we're fetching chunks of data in a loop. We stop if the marker has been spotted (`result` is `true`) or a total of 10 KB of data has been fetched (`len(fetchedBytes)` is over 10 * 1024).

```nim
let bytesRead = await bodyReader.readOnce(addr(buffer[0]), len(buffer))
```

`readOnce` reads `len(buffer)` bytes of data (1024 in our case) and stores them in `buffer`. Since `readOnce` expects a pointer to the container for the fetched bytes, we pass the address of the first item in `buffer`.

```nim
if bytesRead == 0:
  break
```

If no bytes were fetched, that means we're reached the end of the stream and must leave the loop.

```nim
fetchedBytes &= buffer
```

We accumulate the fetched bytes from `buffer`.

```nim
result = "<html" in bytesToString(fetchedBytes)
```

Finally, convert the collected bytes to a string and check if the marker ("<html") is present in it.

```admonish note
Notice that we can treat `result` as a regular `bool` despite the fact that the function returns a `Future[bool]`—really handy!
```

Now we can use this function in the URI health check:

```nim
      if response.status == 200:
        let markerFound = await findMarker(response)

        if markerFound:
          echo "[OK] " & uri
        else:
          echo "[NOK] " & uri & ": Not valid HTML"
      else:
        echo "[NOK] " & uri & ": " & $response.status
```

We just `await` on it and check the value.

Run the program and see the https://mock.codes/200 is no correctly marked as `[NOK]`:

```shell
[ERR] http://123.456.78.90: Could not resolve address of remote server
[NOK] https://mock.codes/200: Not valid HTML
[NOK] https://mock.codes/403: 403
[OK] https://duckduckgo.com/?q=chronos
[OK] https://html.spec.whatwg.org/
[ERR] http://10.255.255.1: Connection timed out
```

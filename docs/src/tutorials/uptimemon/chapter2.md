# Chapter 2. Making Many Requests Concurrently

**Goal:** Learn how to make arbitrarily many HTTP requests in an efficient way.

OK, we have a working app that can check one URI at a time, which is not that much impressive. Let's update our app to do what Chronos was made for—concurrency!

We'll take a somewhat unusual approach and **start with the wrong solution** before revealing the proper way of solving this problem. By highlighting the common mistakes, we'll help you avoid them in the future.

## Wrong Solution: Synchronous Loop

The most obvious to check multiple URIs instead of one would be to just call `check` in a loop:

```nim
import chronos/apps/http/httpclient

# Define a list of URIs to check
const uris =
  @[
    "https://duckduckgo.com/?q=chronos", "https://www.google.fr/search?q=chronos",
    "https://status.im", "http://123.456.78.90",
  ]

proc check(uri: string) {.async.} =
  let session = HttpSessionRef.new()

  try:
    let response = await session.fetch(parseUri(uri))

    if response.status == 200:
      echo "[OK] " & uri
    else:
      echo "[NOK] " & uri & ": " & $response.status
  except CatchableError:
    echo "[ERR] " & uri & ": " & getCurrentExceptionMsg()
  finally:
    await noCancel(session.closeWait())

when isMainModule:
  # Create one session to be used with all requests
  let session = HttpSessionRef.new()

  # Loop over the URIs
  for uri in uris:
    waitFor check(uri)
```

If you run this code, you'll see that it works and does in fact check your URIs.

So, why is it the wrong solution? Because we check URIs in a blocking, synchronous, and therefore slow loop.

With this kind of solution, your app checks URIs one by one and the total time is the sum of the time spent getting a response for every single URI. This is hardly usable if you have as few as 20 URIs to check.

## Correct Solution: Asynchronous Loop

We want Chronos to start all the requests at the same time and report on their results as soon as they are available.

```nim
import chronos/apps/http/httpclient

const uris =
  @[
    "https://duckduckgo.com/?q=chronos", "https://www.google.fr/search?q=chronos",
    "https://status.im", "http://123.456.78.90",
  ]

proc check(session: HttpSessionRef, uri: string) {.async.} =
  try:
    let response = await session.fetch(parseUri(uri))
    if response.status == 200:
      echo "[OK] " & uri
    else:
      echo "[NOK] " & uri & ": " & $response.status
  except CatchableError:
    echo "[ERR] " & uri & ": " & getCurrentExceptionMsg()

proc check(uris: seq[string]) {.async.} =
  let session = HttpSessionRef.new()
  var futs: seq[Future[void]]

  for uri in uris:
    futs.add(session.check(uri))

  await allFutures(futs)
  await noCancel(session.closeWait())

when isMainModule:
  waitFor check(uris)
```

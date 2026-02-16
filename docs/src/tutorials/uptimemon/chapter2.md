# Making Many Requests Concurrently

**Goal:** Learn how to make arbitrarily many HTTP requests asynchronously.

**Source code:** [chapter2.nim](https://github.com/status-im/nim-chronos/blob/master/docs/examples/uptimemon/chapter2.nim)

OK, we have a working app that can check one URI at a time, which is not that much impressive. Let's update our app to do what Chronos was made for—concurrency!

We'll take a somewhat unusual approach and **start with the wrong solution** before revealing the proper way of solving this problem. By highlighting the common mistakes, we'll help you avoid them in the future.

## Wrong Solution: Naive Loop

The most obvious to check multiple URIs instead of one would be to just call `check` in a loop:

```nim
import chronos/apps/http/httpclient

# Define a list of URIs to check
const uris = @[
  "https://duckduckgo.com/?q=chronos", "https://mock.codes/403", "http://123.456.78.90"
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
  # Loop over the URIs
  for uri in uris:
    waitFor check(uri)
```

If you run this code, you'll see that it works and does in fact check your URIs.

So, why is it the wrong solution? Because we check URIs in a blocking, synchronous, and therefore slow loop.

With this kind of solution, your app checks URIs one by one and the total time is the sum of the time spent getting a response for every single URI. This is hardly usable if you have as few as 20 URIs to check.

## Correct Solution: Asynchronous Bulk Requests

We want Chronos to start all the requests at the same time and each other's result as soon as it's available.

To achive that, we will:
1. Introduce a new async function that will schedule the checks. We can't do that outside if a function because async calls are allowed only in async functions.
2. Create one HTTP session for all requests instead of creting a new session for each request.
3. Store all `Future`s that correspond to pending HTTP requests and await them all at once with Chronos's [`allFutures`](/api/chronos/internal/asyncfutures.html#allFutures,varargs[Future[T]]) helper.

Here's the code:

```nim
import chronos/apps/http/httpclient

const uris = @[
  "https://duckduckgo.com/?q=chronos", "https://mock.codes/403", "http://123.456.78.90"
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
  var futures: seq[Future[void]]

  for uri in uris:
    futures.add(session.check(uri))

  await allFutures(futures)
  await noCancel(session.closeWait())

when isMainModule:
  waitFor check(uris)
```

Run this code with `nim r chapter2.nim`, you should see something like this (the order of messages may be different):

```shell
[ERR] http://123.456.78.90: Could not resolve address of remote server
[NOK] https://mock.codes/403: 403
[OK] https://duckduckgo.com/?q=chronos
```

Notice that:
1. The order of responses of different from the order of the URIs in the source code. That's because our requests are now asynchronous, as they should be.
2. The execution time has improved. Now, the program runs roughly as long as the its longest request, not as the sum of all requests.
You can measure the program's execution time to see the difference more clearly:

```shell
# Compile the program in release mode first:
$ nim c -d:release chapter2.nim
# bash, zsh:
$ time {./chapter2}
# PowerShell:
$ Measure-Command {./chapter2.exe | Out-Default}
```

Let's examine the changes since the previous version.

```nim
const uris = @[
  "https://duckduckgo.com/?q=chronos", "https://mock.codes/403", "http://123.456.78.90"
]
```

We define a list of URIs to check. We've put a diverse group to see different responses: DuckDuckGo should respond with `[OK]`, Mock returns a 403 status, i.e. `[NOK]`, and the last one is a non-existant location visiting which should return `[ERR]`.

```nim
proc check(session: HttpSessionRef, uri: string) {.async.} =
  try:
    let response = await session.fetch(parseUri(uri))
    if response.status == 200:
      echo "[OK] " & uri
    else:
      echo "[NOK] " & uri & ": " & $response.status
  except CatchableError:
    echo "[ERR] " & uri & ": " & getCurrentExceptionMsg()
```

We add a new argument to our `check` function and remove the session closing part—session creation and destruction now happen in the caller function.

```nim
proc check(uris: seq[string]) {.async.} =
  let session = HttpSessionRef.new()
  var futures: seq[Future[void]]

  for uri in uris:
    futures.add(session.check(uri))

  await allFutures(futures)
  await noCancel(session.closeWait())
```

We add another `check` function but this ones takes a list of URIs, not one URI. In this function, we create a session (and close it at the end), and populate a list of `Future`s by creating one for each URI.

Then, we use `allFutures` to await all those `Future`s as if they were a single `Future` (in fact, `allFutures` does exactly that—it wraps all `Future`s passed to it with one `Future`).

```nim
when isMainModule:
  waitFor check(uris)
```

Finally, we `waitFor` the `check` to complete for all URIs.

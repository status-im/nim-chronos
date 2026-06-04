# Making Many Requests Concurrently

**Goal:** Learn how to make arbitrarily many HTTP requests asynchronously.

**Source code:** [chapter2/src/uptimemon.nim](https://github.com/status-im/nim-chronos/blob/master/docs/examples/http_client/chapter2/src/uptimemon.nim)

OK, we have a working app that can check one URI at a time, which is not that much impressive. Let's update our project to do what Chronos was made for—concurrency!

We'll start with a simple serial solution before revealing how to make it concurrent. By comparing these approaches, we'll highlight some important concepts in asynchronous programming.

## Serial Requests

The most obvious way to check multiple URIs instead of one would be to just call `check` in a loop:

```nim
import chronos/apps/http/httpclient

# Define a list of URIs to check
const uris = @[
  "https://duckduckgo.com/?q=chronos", "https://mock.codes/403", "http://123.456.78.90"
]

proc check(uri: string) {.async: (raises: [CancelledError]).} =
  let session = HttpSessionRef.new()

  try:
    let response = await session.fetch(parseUri(uri))

    if response.status == 200:
      echo "[OK] " & uri
    else:
      echo "[NOK] " & uri & ": " & $response.status
  except HttpError:
    echo "[ERR] " & uri & ": " & getCurrentExceptionMsg()
  finally:
    await session.closeWait()

when isMainModule:
  # Loop over the URIs
  for uri in uris:
    waitFor check(uri)
```

If you run this code, you'll see that it works and does in fact check your URIs.

While this approach is straightforward, it can be suboptimal for two reasons:

1. **Session vs. request lifetime**: We are creating and closing a new session for every single request. This is inefficient because each session must establish its own connections. Reusing a single session for multiple requests allows Chronos to reuse underlying connections, reducing overhead.
2. **Sequential waiting**: Your app checks URIs one by one, waiting for each to finish before starting the next. The total execution time is the sum of all request times.

In many cases, serial execution is exactly what you want: for example, when you have limited resources or when requests depend on each other.

But for our case, we want to make the requests concurrently because we plan to check many URLs that could potentially be slow to respond.

## Concurrent Requests

We want Chronos to start all the requests at the same time and each other's result as soon as it's available.

To achieve that, we will:

1. Introduce a new async function that will schedule the checks. We can't do that outside if a function because async calls are allowed only in async functions.
2. Create one HTTP session for all requests instead of creting a new session for each request.
3. Store all `Future`s that correspond to pending HTTP requests and await them all at once with Chronos's [`allFutures`](/api/chronos/internal/asyncfutures.html#allFutures,varargs[Future[T]]) helper.

Here's the code:

```nim
{{#shiftinclude auto:../../../examples/http_client/chapter2/src/uptimemon.nim:all}}
```

Run this code with `nimble run`, you should see something like this (the order of messages may be different):

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
$ nimble build -d:release
# bash, zsh:
$ time {./uptimemon}
# PowerShell:
$ Measure-Command {./uptimemon.exe | Out-Default}
```

Let's examine the changes since the previous version.

```nim
{{#shiftinclude auto:../../../examples/http_client/chapter2/src/uptimemon.nim:uris}}
```

We define a list of URIs to check. We've put a diverse group to see different responses: DuckDuckGo should respond with `[OK]`, Mock returns a 403 status, i.e. `[NOK]`, and the last one is a non-existant location visiting which should return `[ERR]`.

```nim
{{#shiftinclude auto:../../../examples/http_client/chapter2/src/uptimemon.nim:check_uri}}
```

We add a new argument to our `check` function and remove the session closing part—session creation and destruction now happen in the caller function.

```nim
{{#shiftinclude auto:../../../examples/http_client/chapter2/src/uptimemon.nim:check_uris}}
```

We add another `check` function but this ones takes a list of URIs, not one URI. In this function, we create a session (and close it at the end), and populate a list of `Future`s by creating one for each URI.

Then, we use `allFutures` to await all those `Future`s as if they were a single `Future` (in fact, `allFutures` does exactly that—it wraps all `Future`s passed to it with one `Future`).

```nim
{{#shiftinclude auto:../../../examples/http_client/chapter2/src/uptimemon.nim:isMainModule}}
```

Finally, we `waitFor` the `check` to complete for all URIs.

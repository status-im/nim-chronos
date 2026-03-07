# Timeouts & Cancellation

**Goal:** Learn how to prevent the program from freezing on slow responses.

**Source code:** [chapter3.nim](https://github.com/status-im/nim-chronos/blob/master/docs/examples/uptimemon/chapter3.nim)

Our current program works fine with the well-behaving URIs we've tested so far: all these locations either respond quickly or quickly return an error.

However, not all requests will go smoothly when you face the real web. Poor connections, slow servers, anti-bot checks, and access restrictions result in responses that may take long to complete or even never complete. One "misbehaving" request can negatively affect the entire program.

For example, try adding an IP address the never responds to the list:

```nim
const uris = @[
  "https://duckduckgo.com/?q=chronos", "https://mock.codes/403", "http://123.456.78.90",
  "http://10.255.255.1",
]
```

Run the program and you'll see that it'll run for 10+ seconds, stuck on this last IP.

Let's add a timeout to our requests to cancel slow requests before they ruin our app: if a request takes longer than 5 seconds, we cancel it.

```nim
{{#shiftinclude auto:../../../examples/uptimemon/chapter3.nim:all}}
```

Here's the part that changed:

```nim
{{#shiftinclude auto:../../../examples/uptimemon/chapter3.nim:proc_uris}}
```

1. We create a `Future` before awaiting on it.
2. Then we `await` it with the special [`withTimeout`](/api/chronos/internal/asyncfutures.html#withTimeout,Future[T],Duration) modifier. This modifier returns `true` if the `Future` passed to it completed before the timeout and `false` otherwise.
3. If the timeout exhausted before we got our response, we raise an [`AsyncTimeoutError`](/api/chronos/internal/errors.html#AsyncTimeoutError) exception that is caught downstream.
4. [`responseFuture.read()`](</api/chronos/internal/asyncfutures.html#read,Future[T: not void]>) can raise [`FuturePendingError`](/api/chronos/internal/asyncfutures.html#FuturePendingError) so we have to handle this exception.
5. Since we explicitly raise an `AsyncTimeoutError`, we need to handle that exception as well.

Run the program again and you'll see it complete in roughly 5 seconds, i.e. our timeout.

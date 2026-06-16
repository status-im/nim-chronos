# Timeouts & Cancellation

**Goal:** Learn how to prevent the program from freezing on slow responses.

**Source code:** [chapter4/src/uptimemon.nim](https://github.com/status-im/nim-chronos/blob/master/docs/examples/http_client/chapter4/src/uptimemon.nim)

Our current program works fine with the well-behaving URIs we've tested so far: all these locations either respond quickly or quickly return an error.

However, not all requests will go smoothly when you face the real web. Poor connections, slow servers, anti-bot checks, and access restrictions result in responses that may take long to complete or even never complete. One "misbehaving" request can negatively affect the entire program.

For example, try adding an IP address that never responds to the list:

```nim
const uris = @[
  "https://duckduckgo.com/?q=chronos", "https://mock.codes/403", "http://10.255.255.1",
]
```

Run the program and you'll see that it'll run for 10+ seconds, stuck on this last IP.

Let's add a timeout to our requests to cancel slow requests before they ruin our app: if a request takes longer than 5 seconds, we cancel it.

```nim
{{#shiftinclude auto:../../../examples/http_client/chapter4/src/uptimemon.nim:all}}
```

Here's the part that changed:

```nim
{{#shiftinclude auto:../../../examples/http_client/chapter4/src/uptimemon.nim:check}}
```

1. We use the [`.wait(timeout)`](/api/chronos/internal/asyncfutures.html#wait,Future[T],Duration) modifier on our `fetch` future.
2. If the request takes longer than the provided duration, `.wait()` automatically cancels the underlying future and raises an [`AsyncTimeoutError`](/api/chronos/internal/errors.html#AsyncTimeoutError).
3. We catch this error alongside other expected exceptions in our `except` block.

Run the program again and you'll see it complete in roughly 5 seconds, i.e. our timeout.

```admonish warning
One important thing to notice here is that adding a timeout won't save us from slow DNS resolutions.

Before we can make an HTTP request, we need to *resolve the target hostname*, i.e. get the IP address that corresponds to the given hostname. This is called DNS resolution and it is a blocking operation in Chronos.

For valid URIs, DNS resolution happens quickly enough to not interfere with the main logic. However, for invalid URIs (e.g. `https://123.456.789.90`) the resolution can stall for several seconds.

The main takeaway here is **don't check invalid URIs**.
```

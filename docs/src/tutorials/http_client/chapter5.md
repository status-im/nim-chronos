# Handling Erroneous URIs

**Goal:** Learn how to prevent the entire program from stalling due to malformed or unreachable URIs.

**Source code:** [chapter5/src/uptimemon.nim](https://github.com/status-im/nim-chronos/blob/master/docs/examples/http_client/chapter5/src/uptimemon.nim)

Our current program handles slow responses with timeouts, but it still has a major flaw: certain kinds of erroneous URIs can cause the entire program to freeze.

For example, try adding this specific "bad" URI to the list: `http://123.456.78.90`. 

When you run the program, you'll notice that it doesn't just take 5 seconds (our timeout) to report an error for this URI. Instead, the entire program stops responding. Any other requests that were supposed to be running concurrently will also stall and likely time out.

## Why Some URIs Cause Stalls

The culprit is **DNS resolution**. Before Chronos can send an HTTP request, it needs to translate the hostname (like `duckduckgo.com`) or check the validity of an IP address. This translation is done using a system call called `getaddrinfo`.

The problem is that `getaddrinfo` is a **blocking** call provided by the operating system. There is no standard asynchronous version of it. When your program calls it, the entire thread stops and waits for the OS to return a result. 

On some systems, an invalid or malformed IP like `123.456.78.90` causes the OS resolver to search for a long time before giving up. Because this happens *inside* our async `check` function *before* we even get a `Future` to `await`, it blocks the Chronos event loop entirely. No other async tasks can run while the thread is stuck inside `getaddrinfo`.

## The Solution: Preemptive DNS Resolution

To fix this, we must separate the blocking address resolution from our concurrent async loop. We'll resolve all URIs into a list of `HttpAddress` objects **before** we start any async operations.

Here's the improved version:

```nim
{{#shiftinclude auto:../../../examples/http_client/chapter5/src/uptimemon.nim:all}}
```

Let's look at the implementation details.

```nim
{{#shiftinclude auto:../../../examples/http_client/chapter5/src/uptimemon.nim:resolve}}
```

We've added a `resolveUris` helper function. It uses [`session.getAddress(uri)`](/api/chronos/apps/http/httpclient.html#getAddress,HttpSessionRef,string) which performs the blocking DNS lookup. 

Because we call this function sequentially *before* we start our concurrent futures, we are essentially saying: "Validate all addresses first, then start the engine."

[`getAddress`](/api/chronos/apps/http/httpclient.html#getAddress,HttpSessionRef,string) returns an `HttpResult[HttpAddress]`. We use `valueOr` to handle cases where resolution fails by printing an error and skipping to the next URI.

## Updating the Check Function

Now that we have `HttpAddress` objects, we update our `check` function to accept them instead of raw strings:

```nim
proc check(session: HttpSessionRef, address: HttpAddress) {.async: (raises: [CancelledError]).} =
  try:
    let
      request = HttpClientRequestRef.new(session, address)
      response = await request.send().wait(5.seconds)
# ...
```

By using the [`HttpClientRequestRef.new`](/api/chronos/apps/http/httpclient.html#new,typedesc[HttpClientRequestRef],HttpSessionRef,HttpAddress,...) overload that takes an `HttpAddress`, we ensure that **no further blocking resolution** happens inside the async loop. The request object is created instantly, and `request.send()` returns a `Future` immediately without stalling.

Run the program now. You'll see that the bad IP fails quickly with a "Could not resolve" error, and more importantly, it no longer stalls the other concurrent requests!

In the next chapter, we'll learn how to handle large responses efficiently by streaming the body.

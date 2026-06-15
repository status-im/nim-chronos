# Handling Erroneous URIs

**Goal:** Learn how to prevent the entire program from stalling due to malformed or unreachable URIs.

**Source code:** [chapter5/src/uptimemon.nim](https://github.com/status-im/nim-chronos/blob/master/docs/examples/http_client/chapter5/src/uptimemon.nim)

Our current program handles slow responses with timeouts, but it still has a major flaw: certain kinds of erroneous URIs can cause the entire program to freeze. For example, if you add a malformed IP address that the OS takes a long time to resolve, the entire program will stop responding. Any other requests that were supposed to be running concurrently will also stall and likely time out.

## Why Some URIs Cause Stalls

The culprit is **DNS resolution**. Before Chronos can send an HTTP request, it needs to translate the hostname (like `duckduckgo.com`) into an IP address using a system call called `getaddrinfo`. This call is **blocking**—the entire thread stops and waits for the OS to return a result. 

Because this happens *inside* our async `check` function *before* we even get a `Future` to `await`, it blocks the Chronos event loop entirely. To fix this, we must separate the blocking address resolution from our concurrent async loop by resolving all URIs into a list of `HttpAddress` objects **before** we start any async operations.

Here's the improved version:

```nim
{{#shiftinclude auto:../../../examples/http_client/chapter5/src/uptimemon.nim:all}}
```

The key is the `resolveUris` helper function, which uses [`session.getAddress(uri)`](/api/chronos/apps/http/httpclient.html#getAddress,HttpSessionRef,string) to perform the blocking DNS lookup *sequentially* before starting the async loop.

By using the [`HttpClientRequestRef.new`](/api/chronos/apps/http/httpclient.html#new,typedesc[HttpClientRequestRef],HttpSessionRef,HttpAddress,...) overload that takes an `HttpAddress` rather than a raw URL, we ensure that **no further blocking resolution** happens inside the async loop. The request object is created instantly, and `request.send()` returns a `Future` immediately without stalling.

In the next chapter, we'll learn how to handle large responses efficiently by streaming the body.

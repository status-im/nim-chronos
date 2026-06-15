# Smarter Health Check with Streaming

**Goal:** Learn how to use streaming to check web page content without fully downloading it.

**Source code:**

- [chapter6_1/src/uptimemon.nim](https://github.com/status-im/nim-chronos/blob/master/docs/examples/http_client/chapter6_1/src/uptimemon.nim)
- [chapter6_2/src/uptimemon.nim](https://github.com/status-im/nim-chronos/blob/master/docs/examples/http_client/chapter6_2/src/uptimemon.nim)

Currently, we're using `fetch` to make a GET request and check its result. However, this function doesn't give us just the response status, it gives us the full page content as well.

While this is correct, it's not optimal: if a page is large, our program will consume unnecessary amount of memory to store that response and waste a lot of time downloading it.

For example, try adding this URI to the list and running the program: https://html.spec.whatwg.org. This is a proper page but it's so heavy fetching it entirely would time out:

```shell
[NOK] https://mock.codes/403: 403
[OK] https://duckduckgo.com/?q=chronos
[ERR] http://10.255.255.1: Connection timed out
[ERR] https://html.spec.whatwg.org/: Connection timed out
```

Let's optimize our check to handle large page like this one.

## Getting Just the Status

First, let's not download the page and just check the response status.

```admonish info
The HTTP protocol divides each request and response into a **header** and a **body**. The header contains metadata like the status code, while the body contains the actual content. This is true for both successful responses and error statuses.
```

To do that, instead of using `fetch`, we'll create the request manually:

```nim
{{#shiftinclude auto:../../../examples/http_client/chapter6_1/src/uptimemon.nim:all}}
```

Before creating the requests, we need to resolve each URI into an address. URL resolution involves DNS lookup which uses the blocking `getaddrinfo` system call — if we ran it inside the async loop, it would stall the whole event loop:

```nim
{{#shiftinclude auto:../../../examples/http_client/chapter6_1/src/uptimemon.nim:resolve}}
```

[`session.getAddress(uri)`](/api/chronos/apps/http/httpclient.html#getAddress,HttpSessionRef,string) turns a URL string into an `HttpAddress` — a value containing the parsed host, port, path, and the resolved IP addresses. Because DNS can fail (e.g. unreachable host), it returns an [`HttpResult`](/api/chronos/apps/http/httpclient.html#HttpResult) which is a [result type](https://github.com/arnetheduck/nim-results) that can contain either the address or an error message.

To handle this, we use `valueOr`: if the result is a success, the `address` variable gets the value; otherwise, the block after `valueOr` is executed. In our case, we print the error and skip to the next URI with `continue`.

```admonish note
You may wonder why we use `valueOr` instead of just relying on `try..except`.

That's because accessing the value of a failed `Result` directly (e.g. via `.get` or `.value`) raises `ResultDefect`, which is not a `CatchableError`. `valueOr` allows us to handle the failure explicitly and convert it into a catchable exception.
```

```admonish info
DNS resolution via `getaddrinfo` is a blocking system call on every operating system — there is no async version. As we saw in the previous chapter, address resolution blocks the calling thread, so it must be performed before entering the async loop to avoid stalling the event loop.
```

Once the addresses are resolved, we create the actual request objects:

```nim
{{#shiftinclude auto:../../../examples/http_client/chapter6_1/src/uptimemon.nim:request}}
```

We use the [`HttpClientRequestRef.new`](/api/chronos/apps/http/httpclient.html#new,typedesc[HttpClientRequestRef],HttpSessionRef,HttpAddress,HttpMethod,HttpVersion,set[HttpClientRequestFlag],int,openArray[HttpHeaderTuple],openArray[byte]) overload that takes an `HttpAddress` rather than a raw URL. This overload does **no** DNS resolution — it just packs the parameters into a request object.

```nim
{{#shiftinclude auto:../../../examples/http_client/chapter6_1/src/uptimemon.nim:response}}
```

We send the request with [`send`](/api/chronos/apps/http/httpclient.html#send,HttpClientRequestRef) and get a `Future`, which we can await on later just like before.

Run the program and you'll see the correct `[OK]` result for https://html.spec.whatwg.org:

```shell
[NOK] https://mock.codes/403: 403
[OK] https://duckduckgo.com/?q=chronos
[OK] https://html.spec.whatwg.org/
[ERR] http://10.255.255.1: Connection timed out
```

## Streaming the Body

Checking just the status speeds up our program but by ignoring the body entirely, we can miss URIs that do not serve valid HTML content. We need a way to check the content but do that without downloading the whole page.

Chronos allows streaming response body, so let's use this feature to fetch content in chunks, check the collected data for a certain health marker (e.g. "<html" string), and stop immediatelly when we find it or download a certain amount of data:

```nim
{{#shiftinclude auto:../../../examples/http_client/chapter6_2/src/uptimemon.nim:all}}
```

Let's go through the changes in this version line by line.

```nim
{{#shiftinclude auto:../../../examples/http_client/chapter6_2/src/uptimemon.nim:urls}}
```

We've added a new URI to our test: https://mock.codes/200. This is a valid URI that returns a 200 status response but it doesn't contain any meaningful data. With our old check, this would return `[OK]` and with the new one we expect it to be `[NOK]`.

```nim
{{#shiftinclude auto:../../../examples/http_client/chapter6_2/src/uptimemon.nim:findMarker}}
```

This is a new function that is responsible to finding the health marker in a given response. Because it is asynchrounous, it will not block the main thread when called.

Like any async function, it returns a `Future` that must be `await`ed to give the actual result.

```admonish note
If you see an async function without a return type, this async function simply returns a `Future[void]`.
```

```nim
{{#shiftinclude auto:../../../examples/http_client/chapter6_2/src/uptimemon.nim:bodyReader}}
```

To stream the response body, we're using a `bodyReader`. To get one for the current response, we're calling [`getBodyReader`](/api/chronos/apps/http/httpclient.html#getBodyReader,HttpClientResponseRef).

```nim
{{#shiftinclude auto:../../../examples/http_client/chapter6_2/src/uptimemon.nim:vars}}
```

- `chunkSize` is how many bytes we request per read
- `windowSize` is `chunkSize + len(marker) - 1`: a chunk plus enough overlap to catch a marker split across two reads — more on this below
- `window` is a fixed-size array of that size, zero-initialised
- `totalRead` tracks total bytes received, used for the 10 KB cap

```nim
{{#shiftinclude auto:../../../examples/http_client/chapter6_2/src/uptimemon.nim:while}}
```

We fetch chunks in a loop, stopping as soon as the marker is found or 10 KB has been read.

```nim
{{#shiftinclude auto:../../../examples/http_client/chapter6_2/src/uptimemon.nim:read_bytes}}
```

[`read`](/api/chronos/apps/http/httpclient.html#read,HttpBodyReader,int) reads up to `chunkSize` bytes and returns them as a `seq[byte]`.

```nim
{{#shiftinclude auto:../../../examples/http_client/chapter6_2/src/uptimemon.nim:bytes_check}}
```

An empty result means we've reached the end of the stream, so we leave the loop.

```nim
{{#shiftinclude auto:../../../examples/http_client/chapter6_2/src/uptimemon.nim:fetchedBytes}}
```

```nim
{{#shiftinclude auto:../../../examples/http_client/chapter6_2/src/uptimemon.nim:result}}
```

Searching only the latest `buffer` for the marker would miss the case where it is split across two reads — for example `<ht` arriving at the end of one chunk and `ml` at the start of the next. Accumulating all fetched bytes and searching the whole thing every iteration would work but wastes time re-scanning data we have already checked.

Instead, we maintain `window` as a sliding buffer. After each read, we shift its contents left by `len(buffer)` bytes and write the new chunk at the right end. The left side of the window then retains the last `len(marker) - 1` bytes of the previous chunk — exactly enough overlap to catch a split marker — while everything older is discarded. Searching the full `window` on every iteration is O(windowSize), a small constant regardless of how much data has been streamed.

```admonish note
Notice that we can treat `result` as a regular `bool` despite the fact that the function returns a `Future[bool]`—really handy!
```

Now we can use this function in the URI health check:

```nim
{{#shiftinclude auto:../../../examples/http_client/chapter6_2/src/uptimemon.nim:url_response}}
```

We just `await` on it and check the value.

```nim
{{#shiftinclude auto:../../../examples/http_client/chapter6_2/src/uptimemon.nim:except}}
```

Notice that since `findMarker` can raise an exception that we haven't been catching so far ([`AsyncStreamError`](/api/chronos/streams/asyncstream.html#AsyncStreamError)), we need to add it to the list as well.

Run the program and see the https://mock.codes/200 is now correctly marked as `[NOK]`:

```shell
[NOK] https://mock.codes/200: Not valid HTML
[NOK] https://mock.codes/403: 403
[OK] https://duckduckgo.com/?q=chronos
[OK] https://html.spec.whatwg.org/
[ERR] http://10.255.255.1: Connection timed out
```

In the next chapter, we'll see how to send alerts with POST requests!

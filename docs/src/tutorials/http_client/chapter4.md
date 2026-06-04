# Smarter Health Check with Streaming

**Goal:** Learn how to use streaming to check web page content without fully downloading it.

**Source code:**

- [chapter4_1/src/uptimemon.nim](https://github.com/status-im/nim-chronos/blob/master/docs/examples/http_client/chapter4_1/src/uptimemon.nim)
- [chapter4_2/src/uptimemon.nim](https://github.com/status-im/nim-chronos/blob/master/docs/examples/http_client/chapter4_2/src/uptimemon.nim)

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

```admonish info
The HTTP protocol divides each request and response into a **header** and a **body**. The header contains metadata like the status code, while the body contains the actual content. This is true for both successful responses and error statuses.
```

To do that, instead of using `fetch`, we'll create the request manually:

```nim
{{#shiftinclude auto:../../../examples/http_client/chapter4_1/src/uptimemon.nim:all}}
```

Here are the new lines that replace `let responseFuture = session.fetch(parseUri(uri))`:

```nim
{{#shiftinclude auto:../../../examples/http_client/chapter4_1/src/uptimemon.nim:request}}
```

We create the request with [`HttpClientRequestRef.new`](/api/chronos/apps/http/httpclient.html#new,typedesc[HttpClientRequestRef],HttpSessionRef,string,HttpMethod,HttpVersion,set[HttpClientRequestFlag],int,openArray[HttpHeaderTuple],openArray[byte]).

When we pass a string URL to `new`, it returns an [`HttpResult`](/api/chronos/apps/http/httpclient.html#HttpResult) which is a [result type](https://github.com/arnetheduck/nim-results) that can contain either the request or an error message (e.g. if the URL is malformed).

To handle this, we use `valueOr`: if the result is a success, the `request` variable gets the value; otherwise, the block after `valueOr` is executed. In our case, we raise a `HttpRequestError` with the provided `error` message.

```admonish note
You may wonder why we use `valueOr` instead of just relying on the `try..except` block.

That's because accessing the value of a failed `Result` directly (e.g. via `.get` or `.value`) raises `ResultDefect`, which is not a `CatchableError` and would skip through our `except HttpError` block. `valueOr` allows us to handle the failure explicitly and convert it into a catchable exception.
```

```nim
{{#shiftinclude auto:../../../examples/http_client/chapter4_1/src/uptimemon.nim:response}}
```

We send the request with [`send`](/api/chronos/apps/http/httpclient.html#send,HttpClientRequestRef) and get a `Future`, which we can await on later just like before.

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
{{#shiftinclude auto:../../../examples/http_client/chapter4_2/src/uptimemon.nim:all}}
```

Let's go through the changes in this version line by line.

```nim
{{#shiftinclude auto:../../../examples/http_client/chapter4_2/src/uptimemon.nim:urls}}
```

We've added a new URI to our test: https://mock.codes/200. This is a valid URI that returns a 200 status response but it doesn't contain any meaningful data. With our old check, this would return `[OK]` and with the new one we expect it to be `[NOK]`.

```nim
{{#shiftinclude auto:../../../examples/http_client/chapter4_2/src/uptimemon.nim:findMarker}}
```

This is a new function that is responsible to finding the health marker in a given response. Because it is asynchrounous, it will not block the main thread when called.

Like any async function, it returns a `Future` that must be `await`ed to give the actual result.

```admonish note
If you see an async function without a return type, this async function simply returns a `Future[void]`.
```

```nim
{{#shiftinclude auto:../../../examples/http_client/chapter4_2/src/uptimemon.nim:bodyReader}}
```

To stream the response body, we're using a `bodyReader`. To get one for the current response, we're calling [`getBodyReader`](/api/chronos/apps/http/httpclient.html#getBodyReader,HttpClientResponseRef).

```nim
{{#shiftinclude auto:../../../examples/http_client/chapter4_2/src/uptimemon.nim:vars}}
```

We'll be reading raw bytes so to store them we create two byte sequences:

- `buffer` will hold the current chunk of maximum lengh 1024 (i.e. 1 KB)
- `fetchedBytes` is a sequence of bytes that have been collected so far

```nim
{{#shiftinclude auto:../../../examples/http_client/chapter4_2/src/uptimemon.nim:while}}
```

Now we're fetching chunks of data in a loop. We stop if the marker has been spotted (`result` is `true`) or a total of 10 KB of data has been fetched (`len(fetchedBytes)` is over 10 * 1024).

```nim
{{#shiftinclude auto:../../../examples/http_client/chapter4_2/src/uptimemon.nim:read_bytes}}
```

[`readOnce`](/api/chronos/transports/stream.html#readOnce,StreamTransport,pointer,int) reads `len(buffer)` bytes of data (1024 in our case) and stores them in `buffer`. Since `readOnce` expects a pointer to the container for the fetched bytes, we pass the address of the first item in `buffer`.

```nim
{{#shiftinclude auto:../../../examples/http_client/chapter4_2/src/uptimemon.nim:bytes_check}}
```

If no bytes were fetched, that means we're reached the end of the stream and must leave the loop.

```nim
{{#shiftinclude auto:../../../examples/http_client/chapter4_2/src/uptimemon.nim:fetchedBytes}}
```

We accumulate the fetched bytes from `buffer`.

```nim
{{#shiftinclude auto:../../../examples/http_client/chapter4_2/src/uptimemon.nim:result}}
```

Finally, convert the collected bytes to a string and check if the marker ("<html") is present in it.

```admonish note
Notice that we can treat `result` as a regular `bool` despite the fact that the function returns a `Future[bool]`—really handy!
```

Now we can use this function in the URI health check:

```nim
{{#shiftinclude auto:../../../examples/http_client/chapter4_2/src/uptimemon.nim:url_response}}
```

We just `await` on it and check the value.

```nim
{{#shiftinclude auto:../../../examples/http_client/chapter4_2/src/uptimemon.nim:except}}
```

Notice that since `findMarker` can raise an exception that we haven't been catching so far ([`AsyncStreamError`](/api/chronos/streams/asyncstream.html#AsyncStreamError)), we need to add it to the list as well.

Run the program and see the https://mock.codes/200 is now correctly marked as `[NOK]`:

```shell
[ERR] http://123.456.78.90: Could not resolve address of remote server
[NOK] https://mock.codes/200: Not valid HTML
[NOK] https://mock.codes/403: 403
[OK] https://duckduckgo.com/?q=chronos
[OK] https://html.spec.whatwg.org/
[ERR] http://10.255.255.1: Connection timed out
```

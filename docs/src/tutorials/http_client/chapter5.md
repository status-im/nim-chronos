# Smarter Health Check with Streaming

**Goal:** Learn how to use streaming to check web page content without fully downloading it.

**Source code:**

- [chapter5/src/uptimemon.nim](https://github.com/status-im/nim-chronos/blob/master/examples/http_client/chapter5/src/uptimemon.nim)

Currently, we're just checking the response status to determine if the URI is healthy.

To make our check smarter, let's check the page content as well: we want it to look like valid HTML, i.e. we want to check that it at least contains a `<html` bit.

However, if we just download the content and look for the HTML marker, we'll have to download the page in its entirety whereas we really don't need the content. For large pages, this approach can lead to slow responses but in extreme cases this can ruin the whole program.

For example, try adding this URI to the list and running the program: https://html.spec.whatwg.org. This is a proper page but it's so heavy fetching it entirely would time out:

```shell
[NOK] https://mock.codes/403: 403
[OK] https://duckduckgo.com/?q=chronos
[ERR] http://10.255.255.1: Timeout exceeded!
[ERR] https://html.spec.whatwg.org: Could not read response headers, reason: Incomplete data sent or received
```

Let's optimize our check to handle large page like this one.

## Streaming the Body

Chronos allows streaming response body, so let's use this feature to fetch content in chunks, check the collected data for a certain health marker (e.g. "<html" string), and stop immediatelly when we find it or download a certain amount of data:

```admonish info
The HTTP protocol divides each request and response into a **header** and a **body**. The header contains metadata like the status code, while the body contains the actual content. This is true for both successful responses and error statuses.
```

```nim
{{#shiftinclude auto:../../../../examples/http_client/chapter5/src/uptimemon.nim:all}}
```

Let's go through the changes in this version line by line.

```nim
{{#shiftinclude auto:../../../../examples/http_client/chapter5/src/uptimemon.nim:urls}}
```

We've added a new URI to our test: https://mock.codes/200. This is a valid URI that returns a 200 status response but it doesn't contain any meaningful data. With our old check, this would return `[OK]` and with the new one we expect it to be `[NOK]`.

```nim
{{#shiftinclude auto:../../../../examples/http_client/chapter5/src/uptimemon.nim:findMarker}}
```

This is a new function that is responsible to finding the health marker in a HTTP body stream. Because it is asynchrounous, it will not block the main thread when called.

Like any async function, it returns a `Future` that must be `await`ed to give the actual result.

```nim
{{#shiftinclude auto:../../../../examples/http_client/chapter5/src/uptimemon.nim:vars}}
```

- `marker` is the string we're looking for.
- `readLimit` is the maximum number of bytes we're happy to fetch before we conclude that the response is not valid HTML (10 KB in our case).
- `totalRead` is the number of bytes fetched so far; if we fetched too much data, we stop reading.
- `sample` will contain the fetched data we're looking for the marker in.
- `found` is a flag that we set to `true` if you find the marker.

```admonish note
Because the marker can be split between two reads (i.e. we fetch `<ht` in one buffer and `ml` in the next one), our `sample` must be a little longer than the buffer. Precisely, it must be `len(marker) - 1` longer to contain the buffer _and_ the possible marker part from the previous read.
```

```nim
{{#shiftinclude auto:../../../../examples/http_client/chapter5/src/uptimemon.nim:findMarkerInSample}}
```

This a helper function that we'll use later in `readMessage` proc as its predicate (more about it later).

This function must conform to [`ReadMessagePredicate`](/api/chronos/transports/stream.html#ReadMessagePredicate) type, i.e. accept an open array of bytes from the stream and return a tuple of `(int, bool)` that represents the length of data read in the last read iteration and the exit flag.

On each iteration, we remove everything from the sample except for the trailing `len(marker) - 1` characters and append the new data, look up `marker` in the new `sample`, and update `found` is the match was found. We also check if `totalRead` is still no higher than `readLimit` and if it is, set the exit flag.

```nim
{{#shiftinclude auto:../../../../examples/http_client/chapter5/src/uptimemon.nim:readMessage}}
```

[`readMessage`](/api/chronos/streams/asyncstream.html#readMessage,AsyncStreamReader,ReadMessagePredicate) calls `findMarkerInSample` repeatedly until either there's no more data to read or the exit flag is `true`. The value `found` tells us if the marker was found in any of the samples checked by `readMessage` and we simply return it.

Now, we can use this function in the URI health check.

Because we won't `fetch` the response but will instead stream it, we will need to create the response object explicitly (so that we could run a stream reader with it). To do that, we first insantiate a `request` and then a `response`:

```nim
{{#shiftinclude auto:../../../../examples/http_client/chapter5/src/uptimemon.nim:let}}
```

Note that we close `request` after `response` is instantiated, either successfully or not. Cleaning up used resources is always encouraged.

```nim
{{#shiftinclude auto:../../../../examples/http_client/chapter5/src/uptimemon.nim:url_response}}
```

To stream the response body, we're using a `bodyReader`. To get one for the current response, we're calling [`getBodyReader`](/api/chronos/apps/http/httpclient.html#getBodyReader,HttpClientResponseRef).

Like any other resource, `HttpBodyReader` must be closed after use. We do that in the `finally` block. Notice that there's no `except` here, we're OK with `findMarker` raising—we'll catch its exceptions in the outer scope.

```nim
{{#shiftinclude auto:../../../../examples/http_client/chapter5/src/uptimemon.nim:except}}
```

Since `findMarker` can raise an exception that we haven't been catching so far ([`AsyncStreamError`](/api/chronos/streams/asyncstream.html#AsyncStreamError)), we need to add it to the list.

```nim
{{#shiftinclude auto:../../../../examples/http_client/chapter5/src/uptimemon.nim:finally}}
```

Like any other resource allocating object, `response` must be closed after usage.

Run the program and see the https://mock.codes/200 is now correctly marked as `[NOK]`:

```shell
[NOK] https://mock.codes/200: Not valid HTML
[NOK] https://mock.codes/403: 403
[OK] https://duckduckgo.com/?q=chronos
[OK] https://html.spec.whatwg.org/
[ERR] http://10.255.255.1: Timeout exceeded!
```

In the next chapter, we'll see how to send alerts with POST requests.

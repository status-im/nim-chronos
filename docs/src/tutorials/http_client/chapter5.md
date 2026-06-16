# Smarter Health Check with Streaming

**Goal:** Learn how to use streaming to check web page content without fully downloading it.

**Source code:**

- [chapter5/src/uptimemon.nim](https://github.com/status-im/nim-chronos/blob/master/docs/examples/http_client/chapter5/src/uptimemon.nim)

Currently, we're just checking the response status to determine if the URI is healthy.

To make our check smarter, let's check the page content as well: we want it to look like valid HTML, i.e. we want to check that it at least contains a `<html` bit.

However, if we just download the content and look for the HTML marker, we'll have to download the page in its entirety whereas we really don't need the content. For large pages, this approach can lead to slow responses but in extreme cases this can ruin the whole program.

For example, try adding this URI to the list and running the program: https://html.spec.whatwg.org. This is a proper page but it's so heavy fetching it entirely would time out:

```shell
[NOK] mock.codes/403: 403
[OK] duckduckgo.com/
[ERR] 10.255.255.1: Timeout exceeded!
[ERR] html.spec.whatwg.org: Could not read response headers, reason: Incomplete data sent or received
```

Let's optimize our check to handle large page like this one.

## Streaming the Body

Chronos allows streaming response body, so let's use this feature to fetch content in chunks, check the collected data for a certain health marker (e.g. "<html" string), and stop immediatelly when we find it or download a certain amount of data:

```admonish info
The HTTP protocol divides each request and response into a **header** and a **body**. The header contains metadata like the status code, while the body contains the actual content. This is true for both successful responses and error statuses.
```

```nim
{{#shiftinclude auto:../../../examples/http_client/chapter5/src/uptimemon.nim:all}}
```

Let's go through the changes in this version line by line.

```nim
{{#shiftinclude auto:../../../examples/http_client/chapter5/src/uptimemon.nim:urls}}
```

We've added a new URI to our test: https://mock.codes/200. This is a valid URI that returns a 200 status response but it doesn't contain any meaningful data. With our old check, this would return `[OK]` and with the new one we expect it to be `[NOK]`.

```nim
{{#shiftinclude auto:../../../examples/http_client/chapter5/src/uptimemon.nim:findMarker}}
```

This is a new function that is responsible to finding the health marker in a given response. Because it is asynchrounous, it will not block the main thread when called.

Like any async function, it returns a `Future` that must be `await`ed to give the actual result.

```nim
{{#shiftinclude auto:../../../examples/http_client/chapter5/src/uptimemon.nim:bodyReader}}
```

To stream the response body, we're using a `bodyReader`. To get one for the current response, we're calling [`getBodyReader`](/api/chronos/apps/http/httpclient.html#getBodyReader,HttpClientResponseRef).

The reader must be closed after usage no matter if we manage to read the full body or a part of it, so we `defer` the reader closing.

```nim
{{#shiftinclude auto:../../../examples/http_client/chapter5/src/uptimemon.nim:vars}}
```

- `marker` is the string we're looking for.
- `bufferSize` is how many bytes at most we want to fetch on one read.
- `totalRead` is the number of bytes fetched so far; if we fetched too much data, we stop reading.
- `buffer` is a string that we read in the last fetch.
- `sample` will contain the fetched data we're looking for the marker in.

```admonish note
Because the marker can be split between two reads (i.e. we fetch `<ht` in one buffer and `ml` in the next one), our `sample` must be a little longer than the buffer. Precisely, it must be `len(marker) - 1` longer to contain the buffer _and_ the possible marker part from the previous read.
```

```nim
{{#shiftinclude auto:../../../examples/http_client/chapter5/src/uptimemon.nim:while}}
```

We fetch chunks in a loop, stopping as soon as the marker is found or 10 KB has been read.

```nim
{{#shiftinclude auto:../../../examples/http_client/chapter5/src/uptimemon.nim:read_bytes}}
```

[`readOnce`](/api/chronos/apps/http/httpclient.html#readOnce,AsyncStreamReader,pointer,int) reads the next available chunk from the stream and writes it to `buffer`.

It is possible that we read less bytes than we asked for, so we adjust `buffer` for the actual data size.

```nim
{{#shiftinclude auto:../../../examples/http_client/chapter5/src/uptimemon.nim:bytes_check}}
```

An empty result means we've reached the end of the stream, so we close the reader, finalize the response, and leave the loop.

```nim
{{#shiftinclude auto:../../../examples/http_client/chapter5/src/uptimemon.nim:update_sample}}
```

We remove everything from the sample except for the trailing `len(marker) - 1` characters and append the new buffer value.

```nim
{{#shiftinclude auto:../../../examples/http_client/chapter5/src/uptimemon.nim:result}}
```

Finally, we check if the marker is in the sample.

```admonish note
Notice that we can treat `result` as a regular `bool` despite the fact that the function returns a `Future[bool]`—really handy!
```

Now, we can use this function in the URI health check.

Because we won't `fetch` the response but will instead stream it, we will need to create the response object explicitly (so that we could run a stream reader with it). To do that, we first insantiate a `request` and then a `response`:

```nim
{{#shiftinclude auto:../../../examples/http_client/chapter5/src/uptimemon.nim:let}}
```

Note that we close `request` after `response` is instantiated, either successfully or not. Cleaning up used resources is always encouraged.

Now we can use this function in the URI health check:

```nim
{{#shiftinclude auto:../../../examples/http_client/chapter5/src/uptimemon.nim:url_response}}
```

We just `await` on it and check the value.

```nim
{{#shiftinclude auto:../../../examples/http_client/chapter5/src/uptimemon.nim:except}}
```

Notice that since `findMarker` can raise an exception that we haven't been catching so far ([`AsyncStreamError`](/api/chronos/streams/asyncstream.html#AsyncStreamError)), we need to add it to the list as well.

```nim
{{#shiftinclude auto:../../../examples/http_client/chapter5/src/uptimemon.nim:finally}}
```

Like any other resource allocating object, `response` must be closed after usage.

Run the program and see the https://mock.codes/200 is now correctly marked as `[NOK]`:

```shell
[NOK] mock.codes/200: Not valid HTML
[NOK] mock.codes/403: 403
[OK] duckduckgo.com/?q=chronos
[OK] html.spec.whatwg.org/
[ERR] 10.255.255.1: Timeout exceeded!
```

In the next chapter, we'll see how to send alerts with POST requests!

# Handling POST Requests and Processing JSON

**Goal:** Learn how to handle POST requests and process incoming JSON data.

**Source code:** [chapter3/src/dashboard.nim](https://github.com/status-im/nim-chronos/blob/master/examples/http_server/chapter3/src/dashboard.nim)

In a real-life application, you often need to receive data from clients, not just serve static content. Our dashboard needs to receive status reports from other services.

Let's update our server to handle POST requests containing JSON data and store these reports in memory:

```nim
{{#shiftinclude auto:../../../../examples/http_server/chapter3/src/dashboard.nim:all}}
```

To test this version, run it with `nimble run` and use a tool like `curl` to send a POST request:

```shell
$ curl -X POST -H "Content-Type: application/json" -d '{"name": "google.com", "status": "UP"}' http://127.0.0.1:8080/report
```

Then, visit [127.0.0.1:8080](http://127.0.0.1:8080/status) in your browser to see the updated status.

## Handling POST Requests

```admonish info
The HTTP protocol divides each request and response into a **header** and a **body**. The header contains metadata like the request method and path, while the body contains the actual content — the JSON payload in our case. This is true for both requests and responses.
```

```nim
{{#shiftinclude auto:../../../../examples/http_server/chapter3/src/dashboard.nim:handler_closure}}
```

The first change you'll notice is that we wrapped our `handler` proc with another function that returns the actual handler (of type [`HttpProcessCallback2`](/api/chronos/apps/http/httpserver.html#HttpProcessCallback2)). This is done to enable passing an input param `reports` that we'll use to store the statuses.

In the handler, we added logic for the `/report` path:

```nim
{{#shiftinclude auto:../../../../examples/http_server/chapter3/src/dashboard.nim:report_post}}
```

1. We check if the request method is `MethodPost`.
2. We use [`request.getBody()`](/api/chronos/apps/http/httpserver.html#getBody,HttpRequestRef) to asynchronously read the entire request body.
3. `body` is an array of bytes, so we need to convert it to a string before we can parse it. To do that, we use [`bytesToString`](/api/chronos/apps/http/httpcommon.html#bytesToString,openArray[byte]) function from `chronos/apps/http/httpcommon`.
4. We use Nim's `std/json` library to parse the body as JSON. We wrap this in a `try-except` block to handle parsing errors. We want to catch all parsing errors at this point, so it's a rare case where catching generic `CatchableError` is fine.
5. We extract the relevant fields and store them in our table. We use a separate `try-except` block to catch `KeyError` if the fields are missing.

```admonish info
When dealing with JSON from clients, we must assume it can be malformed or missing fields. We handle these cases by catching parsing errors and `KeyError` exceptions, returning an appropriate HTTP 400 Bad Request status.
```

## Generating Response

Finally, for the `/status` path, we now generate a dynamic string based on the data in our table:

```nim
{{#shiftinclude auto:../../../../examples/http_server/chapter3/src/dashboard.nim:status_get}}
```

## Storing Data in Memory

We use an in-memory `TableRef` to store our status reports.

```nim
{{#shiftinclude auto:../../../../examples/http_server/chapter3/src/dashboard.nim:reports_table}}
```

We pass `reports` to the handler generating function to generate a handler that would store statuses to it.

```admonish info
In a real app you would store your persistent data in a database of key-value storage. In this tutorial, we use a `Table` for simplicity's sake.
```

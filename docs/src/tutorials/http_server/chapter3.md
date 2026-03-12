# Processing JSON Data and POST Requests

**Goal:** Learn how to handle POST requests and process incoming JSON data.

**Source code:** [chapter3.nim](https://github.com/status-im/nim-chronos/blob/master/docs/examples/http_server/chapter3.nim)

In a real-life application, you often need to receive data from clients, not just serve static content. Our dashboard needs to receive status reports from other services.

Let's update our server to handle POST requests containing JSON data and store these reports in memory:

```nim
{{#shiftinclude auto:../../../examples/http_server/chapter3.nim:all}}
```

To test this version, you can use a tool like `curl` to send a POST request:

```shell
$ curl -X POST -H "Content-Type: application/json" -d '{"name": "google.com", "status": "UP"}' http://127.0.0.1:8080/report
```

Then, visit `http://127.0.0.1:8080/status` in your browser to see the updated status.

## Storing Data in Memory

We use an in-memory `Table` to store our status reports.

```nim
{{#shiftinclude auto:../../../examples/http_server/chapter3.nim:data}}
```

Note that we use the `{.threadvar.}` pragma. In Nim, accessing global variables from an asynchronous callback requires them to be thread-local or the callback to be marked as not GC-safe. Since Chronos's HTTP server is designed to be highly performant and generally runs on a single thread per event loop, `threadvar` is a clean way to handle this.

We initialize the table in our `main` function before starting the server.

## Handling POST Requests

In the `mainHandler`, we added logic for the `/report` path:

```nim
{{#shiftinclude auto:../../../examples/http_server/chapter3.nim:report_post}}
```

1. We check if the request method is `MethodPost`.
2. We use `request.getBody()` to asynchronously read the entire request body.
3. We use Nim's `std/json` library to parse the body as JSON. We wrap this in a `try-except` block to handle malformed JSON and return a 400 Bad Request error if parsing fails.
4. We extract the relevant fields and store them in our table.

## Generating Dynamic Content

For the `/status` path, we now generate a dynamic string based on the data in our table:

```nim
{{#shiftinclude auto:../../../examples/http_server/chapter3.nim:status_get}}
```

## Error Handling

When dealing with JSON from clients, we must assume it can be malformed or missing fields. We handle these cases by catching `CatchableError` during parsing and `KeyError` when accessing JSON fields, returning an appropriate HTTP 400 Bad Request status.

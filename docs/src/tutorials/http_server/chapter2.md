# Handling Multiple Routes

**Goal:** Learn how to handle different request paths in your HTTP server.

**Source code:** [chapter2/src/dashboard.nim](https://github.com/status-im/nim-chronos/blob/master/docs/examples/http_server/chapter2/src/dashboard.nim)

Our first server version could only respond with one message regardless of the URL. Real-world applications usually need to handle multiple routes.

Let's update our server to handle different paths differently:

```nim
{{#shiftinclude auto:../../../examples/http_server/chapter2/src/dashboard.nim:all}}
```

To test the routes, run the project with `nimble run` and try visiting these URLs in your browser:

- [127.0.0.1:8080/](http://127.0.0.1:8080/)
- [127.0.0.1:8080/status](http://127.0.0.1:8080/status)
- [127.0.0.1:8080/any-other-path](http://127.0.0.1:8080/any-other-path)

## Routing Logic

The change is how we process the incoming request in the `handler`:

```nim
{{#shiftinclude auto:../../../examples/http_server/chapter2/src/dashboard.nim:routing}}
```

We use a `case` statement to check the `request.uri.path`.

- For the root path `/`, we return a welcome message.
- For the `/status` path, we return a simple operational message.
- For any other path, we use the `else` branch to return an HTTP 404 Not Found error.

By using [`request.respond`](/api/chronos/apps/http/httpserver.html#respond,HttpRequestRef,HttpCode,ByteChar), we can easily control both the HTTP status code and the response body.

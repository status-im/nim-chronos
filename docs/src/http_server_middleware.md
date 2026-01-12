## HTTP server middleware

Chronos provides a powerful mechanism for customizing HTTP request handlers via
middlewares.

A middleware is a coroutine that can modify, block or filter HTTP request.

Single HTTP server could support unlimited number of middlewares, but you need to consider that each request in worst case could go through all the middlewares, and therefore a huge number of middlewares can have a significant impact on HTTP server performance.

Order of middlewares is also important: right after HTTP server has received request, it will be sent to the first middleware in list, and each middleware will be responsible for passing control to other middlewares. Therefore, when building a list, it would be a good idea to place the request handlers at the end of the list, while keeping the middleware that could block or modify the request at the beginning of the list.

Middleware could also modify HTTP server request, and these changes will be visible to all handlers (either middlewares or the original request handler). This can be done using the following helpers:

```nim
  proc updateRequest*(request: HttpRequestRef, scheme: string, meth: HttpMethod,
                      version: HttpVersion, requestUri: string,
                      headers: HttpTable): HttpResultMessage[void]

  proc updateRequest*(request: HttpRequestRef, meth: HttpMethod,
                      requestUri: string,
                      headers: HttpTable): HttpResultMessage[void]

  proc updateRequest*(request: HttpRequestRef, requestUri: string,
                      headers: HttpTable): HttpResultMessage[void]

  proc updateRequest*(request: HttpRequestRef,
                      requestUri: string): HttpResultMessage[void]

  proc updateRequest*(request: HttpRequestRef,
                      headers: HttpTable): HttpResultMessage[void]
```

As you can see all the HTTP request parameters could be modified: request method, version, request path and request headers.

Middleware could also use helpers to obtain more information about remote and local addresses of request's connection (this could be helpful when you need to do some IP address filtering).

```nim
  proc remote*(request: HttpRequestRef): Opt[TransportAddress]
    ## Returns remote address of HTTP request's connection.
  proc local*(request: HttpRequestRef): Opt[TransportAddress] =
    ## Returns local address of HTTP request's connection.
```

Every middleware is the coroutine which looks like this:

```nim
  proc middlewareHandler(
      middleware: HttpServerMiddlewareRef,
      reqfence: RequestFence,
      nextHandler: HttpProcessCallback2
  ): Future[HttpResponseRef] {.async: (raises: [CancelledError]).} =
```

Where `middleware` argument is the object which could hold some specific values, `reqfence` is HTTP request which is enclosed with HTTP server error information and `nextHandler` is reference to next request handler, it could be either middleware handler or the original request processing callback handler.

```nim
  await nextHandler(reqfence)
```

You should perform await for the response from the `nextHandler(reqfence)`. Usually you should call next handler when you dont want to handle request or you dont know how to handle it, for example:

```nim
  proc middlewareHandler(
      middleware: HttpServerMiddlewareRef,
      reqfence: RequestFence,
      nextHandler: HttpProcessCallback2
  ): Future[HttpResponseRef] {.async: (raises: [CancelledError]).} =
  if reqfence.isErr():
    # We dont know or do not want to handle failed requests, so we call next handler.
    return await nextHandler(reqfence)
  let request = reqfence.get()
  if request.uri.path == "/path/we/able/to/respond":
    try:
      # Sending some response.
      await request.respond(Http200, "TEST")
    except HttpWriteError as exc:
      # We could also return default response for exception or other types of error.
      defaultResponse(exc)
  elif request.uri.path == "/path/for/rewrite":
    # We going to modify request object for this request, next handler will receive it with different request path.
    let res = request.updateRequest("/path/to/new/location")
    if res.isErr():
      return defaultResponse(res.error)
    await nextHandler(reqfence)
  elif request.uri.path == "/restricted/path":
    if request.remote().isNone():
      # We can't obtain remote address, so we force HTTP server to respond with `401 Unauthorized` status code.
      return codeResponse(Http401)
    if $(request.remote().get()).startsWith("127.0.0.1"):
      # Remote peer's address starts with "127.0.0.1", sending proper response.
      await request.respond(Http200, "AUTHORIZED")
    else:
      # Force HTTP server to respond with `403 Forbidden` status code.
      codeResponse(Http403)
  elif request.uri.path == "/blackhole":
    # Force HTTP server to drop connection with remote peer.
    dropResponse()
  else:
    # All other requests should be handled by somebody else.
    await nextHandler(reqfence)
```


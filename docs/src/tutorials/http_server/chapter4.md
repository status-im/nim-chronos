# Using Middleware

**Goal:** Learn how to extend your server's functionality with middleware.

**Source code:** [chapter4.nim](https://github.com/status-im/nim-chronos/blob/master/docs/examples/http_server/chapter4.nim)

Middleware is a way to wrap your request handler with additional logic. This is useful for cross-cutting concerns like logging, authentication, or modifying request/response headers.

Let's add a simple logging middleware that tracks how long each request takes to process:

```nim
{{#shiftinclude auto:../../../examples/http_server/chapter4.nim:all}}
```

## Defining a Middleware

A middleware handler is a function that takes the current middleware object, the `RequestFence`, and the `nextHandler` in the chain:

```nim
{{#shiftinclude auto:../../../examples/http_server/chapter4.nim:middleware}}
```

1. We record the current time before processing the request.
2. We call `await nextHandler(reqfence)` to pass the request to the next middleware or the main handler.
3. After the handler returns, we calculate the duration and print a log message.
4. We return the `response` received from the handler chain.

## Registering Middleware

To use middleware, you need to create an array of `HttpServerMiddlewareRef` and pass it to the server constructor:

```nim
{{#shiftinclude auto:../../../examples/http_server/chapter4.nim:setup_middleware}}
```

Then, include it in `HttpServerRef.new`:

```nim
{{#shiftinclude auto:../../../examples/http_server/chapter4.nim:main}}
```

Now, every time your server receives a request, you'll see a log message in your terminal with the method, path, and processing time.

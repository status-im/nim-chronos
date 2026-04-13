# Logging Requests with Middleware

**Goal:** Learn how to extend your server's functionality with middleware.

**Source code:** [chapter4/src/dashboard.nim](https://github.com/status-im/nim-chronos/blob/master/docs/examples/http_server/chapter4/src/dashboard.nim)

Middleware is a way to wrap your request handler with additional logic. This is useful for cross-cutting concerns like logging, authentication, modifying request and response headers, and for sharing a single HTTP server between multiple services (e.g. a metrics server and a REST API server).

Let's add a simple logging middleware that tracks how long each request takes to process:

```nim
{{#shiftinclude auto:../../../examples/http_server/chapter4/src/dashboard.nim:all}}
```

To test the middleware, run the project with `nimble run` and make some requests to your server (with `curl` and from your browser).

## Defining a Middleware

A middleware handler is a function that takes the current middleware object, the [`RequestFence`](/api/chronos/apps/http/httpserver.html#RequestFence), and the `nextHandler` (which is an [`HttpProcessCallback2`](/api/chronos/apps/http/httpserver.html#HttpProcessCallback2)) in the chain:

```nim
{{#shiftinclude auto:../../../examples/http_server/chapter4/src/dashboard.nim:middleware}}
```

1. We record the current time before processing the request using `getMonoTime` from `std/monotimes`.
2. We call `await nextHandler(reqfence)` to pass the request to the next middleware or the main handler.
3. After the handler returns, we calculate the duration and print a log message. To get the processing duration in milliseconds, we use `inMilliseconds` from `std/times`.
4. We return the `response` received from the handler chain.

```admonish info
You may wonder why `HttpProcessCallback2` has a `2` in its name and why don't we use [`HttpProcessCallback`](/api/chronos/apps/http/httpserver.html#HttpProcessCallback).

The difference is that `HttpProcessCallback2` is a newer and stricter version while `HttpProcessCallback` is kept for backward compatibility.

So, long story short: use `HttpProcessCallback2` unless you're sure you need `HttpProcessCallback`.
```

## Registering Middleware

To use middleware, you need to create an array of [`HttpServerMiddlewareRef`](/api/chronos/apps/http/httpserver.html#HttpServerMiddlewareRef) and pass it to the server constructor:

```nim
{{#shiftinclude auto:../../../examples/http_server/chapter4/src/dashboard.nim:setup_middleware}}
```

Then, include it in [`HttpServerRef.new`](/api/chronos/apps/http/httpserver.html#new,typedesc[HttpServerRef],TransportAddress,HttpProcessCallback2,set[HttpServerFlags],set[ServerFlags],string,int,int,int,int,int,openArray[HttpServerMiddlewareRef]):

```nim
{{#shiftinclude auto:../../../examples/http_server/chapter4/src/dashboard.nim:main}}
```

Now, every time your server receives a request, you'll see a log message in your terminal with the method, path, and processing time.

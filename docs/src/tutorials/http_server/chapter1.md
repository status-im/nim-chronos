# Setting Up a Basic HTTP Server

**Goal:** Learn how to create and start a simple HTTP server with Chronos.

**Source code:** [chapter1/src/dashboard.nim](https://github.com/status-im/nim-chronos/blob/master/docs/examples/http_server/chapter1/src/dashboard.nim)

First, let's initialize a new binary project with Nimble. Switch to your preferred project directory in your terminal and run:

```shell
$ nimble init dashboard
```

When prompted, choose `binary` for the package type.

Now, open the generated `dashboard.nimble` file and add `chronos` to the dependencies:

```nim
# Dependencies

requires "nim >= 2.0.0"
requires "chronos"
```

Finally, open `src/dashboard.nim` and replace the code in it with this (we'll go through each line in a moment):

```nim
{{#shiftinclude auto:../../../examples/http_server/chapter1/src/dashboard.nim:all}}
```

To execute the project, run this command from the `dashboard` directory:

```shell
$ nimble run
```

You should see the following message in your terminal:

```shell
HTTP server running on http://127.0.0.1:8080
```

Now, open your web browser and go to [127.0.0.1:8080](http://127.0.0.1:8080). You should see "Hello, Chronos!".

## Line-by-Line Explanation

```nim
{{#shiftinclude auto:../../../examples/http_server/chapter1/src/dashboard.nim:import}}
```

[`httpserver`](/api/chronos/apps/http/httpserver.html) module implements the HTTP server capabilities, i.e. listening for incoming connections and responding to HTTP requests.

```nim
{{#shiftinclude auto:../../../examples/http_server/chapter1/src/dashboard.nim:handler}}
```

We define a `handler` function that will be called for every incoming request.

Note that this function takes a [`RequestFence`](/api/chronos/apps/http/httpserver.html#RequestFence) as an argument. [`RequestFence`](/api/chronos/apps/http/httpserver.html#RequestFence) is a `Result` type that can contain either a valid [`HttpRequestRef`](/api/chronos/apps/http/httpserver.html#HttpRequestRef) or an error. This allows Chronos to notify us if something went wrong during request parsing.

```admonish info
`Result` comes from [results](https://github.com/arnetheduck/nim-results) library. It's somewhat similar to Nim's built-in `Options` type but more powerful. Chronos uses it all around the place whenever a function can return a result or an error.
```

The function is annotated with the [`async`](/api/chronos/asyncloop.html#async) pragma and `raises: [CancelledError]` ([`CancelledError`](/api/chronos/futures.html#CancelledError)) according to Chronos's [checked exceptions](../../error_handling.md#checked-exceptions).

Inside the handler, we first check if the request was received correctly. If not, we return a [`defaultResponse()`](/api/chronos/apps/http/httpserver.html#defaultResponse), which is simply an empty response.

If the request is valid, we use the [`respond`](/api/chronos/apps/http/httpserver.html#respond,HttpRequestRef,HttpCode,ByteChar) method to send a simple string back to the client with an HTTP 200 OK status.

We wrap the `respond` call in a `try-except` block to handle potential network errors ([`HttpWriteError`](/api/chronos/apps/http/httpcommon.html#HttpWriteError)). Note that we let [`CancelledError`](/api/chronos/futures.html#CancelledError) propagate to the caller instead of catching it.

```nim
{{#shiftinclude auto:../../../examples/http_server/chapter1/src/dashboard.nim:main}}
```

In the `main` function, we:

1. Define the address and port to listen on (`127.0.0.1:8080`).
2. Create an instance of the server using [`HttpServerRef.new`](/api/chronos/apps/http/httpserver.html#new,typedesc[HttpServerRef],TransportAddress,HttpProcessCallback2,set[HttpServerFlags],set[ServerFlags],string,int,int,int,int,int,openArray[HttpServerMiddlewareRef]).
3. Start the server with [`server.start()`](/api/chronos/apps/http/httpserver.html#start,HttpServerRef).
4. Use [`server.join()`](/api/chronos/apps/http/httpserver.html#join,HttpServerRef) to wait until the server is stopped (which, in this case, will be never, until we manually terminate the program with `Ctrl-C`).
5. In the `finally` block, we ensure the server is stopped and its resources are released correctly.

```nim
{{#shiftinclude auto:../../../examples/http_server/chapter1/src/dashboard.nim:run}}
```

Finally, we use [`waitFor`](/api/chronos/asyncloop.html#waitFor,Future[T]) to start our async `main` routine.

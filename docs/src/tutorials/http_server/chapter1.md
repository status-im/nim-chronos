# Setting Up a Basic HTTP Server

**Goal:** Learn how to create and start a simple HTTP server with Chronos.

**Source code:** [chapter1.nim](https://github.com/status-im/nim-chronos/blob/master/docs/examples/http_server/chapter1.nim)

Create a file called `server.nim` and open it in your favorite text editor.

Copy and paste this code into this new file (we'll go through each line in a moment):

```nim
{{#shiftinclude auto:../../../examples/http_server/chapter1.nim:all}}
```

To execute the file, switch to the directory with this file in your terminal and run this command:

```shell
$ nim r server.nim
```

You should see the following message in your terminal:

```shell
HTTP server running on http://127.0.0.1:8080
```

Now, open your web browser and go to `http://127.0.0.1:8080`. You should see "Hello, Chronos!".

## Line-by-Line Explanation

```nim
{{#shiftinclude auto:../../../examples/http_server/chapter1.nim:import}}
```

[`httpserver`](/api/chronos/apps/http/httpserver.html) module implements the HTTP server capabilities, i.e. listening for incoming connections and responding to HTTP requests.

```nim
{{#shiftinclude auto:../../../examples/http_server/chapter1.nim:handler}}
```

We define a `mainHandler` function that will be called for every incoming request.

Note that this function takes a `RequestFence` as an argument. `RequestFence` is a `Result` type that can contain either a valid `HttpRequestRef` or an error. This allows Chronos to notify us if something went wrong during request parsing.

The function is annotated with the `async` pragma and `raises: [CancelledError]` for consistency with Chronos's asynchronous execution and [checked exceptions](../../error_handling.md#checked-exceptions).

Inside the handler, we first check if the request was received correctly. If not, we return a `defaultResponse()`.

If the request is valid, we use the [`respond`](/api/chronos/apps/http/httpserver.html#respond,HttpRequestRef,HttpCode,ByteChar) method to send a simple string back to the client with an HTTP 200 OK status.

We wrap the `respond` call in a `try-except` block to handle potential network errors (`HttpWriteError`).

```nim
{{#shiftinclude auto:../../../examples/http_server/chapter1.nim:main}}
```

In the `main` function, we:

1. Define the address and port to listen on (`127.0.0.1:8080`).
2. Create an instance of the server using [`HttpServerRef.new`](/api/chronos/apps/http/httpserver.html#HttpServerRef,new).
3. Start the server with `server.start()`.
4. Use [`server.join()`](/api/chronos/asyncloop.html#join,StreamServer) to wait until the server is stopped (which, in this case, will be never, unless we manually terminate the program).
5. In the `finally` block, we ensure the server is stopped and its resources are released correctly.

```nim
{{#shiftinclude auto:../../../examples/http_server/chapter1.nim:run}}
```

Finally, we use `waitFor` to start our async `main` routine.

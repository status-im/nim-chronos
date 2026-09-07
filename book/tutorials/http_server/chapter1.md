.. title:: Setting Up a Basic HTTP Server
.. importdoc:: ../../error_handling
.. importdoc:: ../../api/chronos/apps/http/httpserver
.. importdoc:: ../../api/chronos/apps/http/httpcommon
.. importdoc:: ../../api/chronos/futures
.. importdoc:: ../../api/chronos/internal/asyncmacro
.. importdoc:: ../../api/chronos/internal/asyncfutures

**Goal:** Learn how to create and start a simple HTTP server with Chronos.

**Source code:** [chapter1/src/dashboard.nim](https://github.com/status-im/nim-chronos/blob/master/examples/http_server/chapter1/src/dashboard.nim)

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

.. include:: ../../../examples/http_server/chapter1/src/dashboard.nim
   :start-after: #ANCHOR: all
   :end-before: #ANCHOR_END: all
   :code:

To execute the project, run this command from the `dashboard` directory:

```shell
$ nimble run
```

You should see the following message in your terminal:

```shell
HTTP server running on http://127.0.0.1:8080
```

Now, open your web browser and go to [127.0.0.1:8080](http://127.0.0.1:8080). You should see "Hello, Chronos!".

# Line-by-Line Explanation

.. include:: ../../../examples/http_server/chapter1/src/dashboard.nim
   :start-after: #ANCHOR: import
   :end-before: #ANCHOR_END: import
   :code:

[httpserver](../../api/chronos/apps/http/httpserver.html) module implements the HTTP server capabilities, i.e. listening for incoming connections and responding to HTTP requests.

.. include:: ../../../examples/http_server/chapter1/src/dashboard.nim
   :start-after: #ANCHOR: handler
   :end-before: #ANCHOR_END: handler
   :code:

We define a `handler` function that will be called for every incoming request.

Note that this function takes a [RequestFence] as an argument. [RequestFence] is a `Result` type that can contain either a valid [HttpRequestRef] or an error. This allows Chronos to notify us if something went wrong during request parsing.

.. note::
   `Result` comes from [results](https://github.com/arnetheduck/nim-results) library. It's somewhat similar to Nim's built-in `Options` type but more powerful. Chronos uses it all around the place whenever a function can return a result or an error.

The function is annotated with the [async(untyped)] pragma and `raises: [CancelledError]` ([CancelledError]) according to Chronos's [Checked exceptions].

Inside the handler, we first check if the request was received correctly. If not, we return a [defaultResponse()], which is simply an empty response.

If the request is valid, we use the [respond(HttpRequestRef, HttpCode, ByteChar)] method to send a simple string back to the client with an HTTP 200 OK status.

We wrap the `respond` call in a `try-except` block to handle potential network errors ([HttpWriteError]). Note that we let [CancelledError] propagate to the caller instead of catching it.

.. include:: ../../../examples/http_server/chapter1/src/dashboard.nim
   :start-after: #ANCHOR: main
   :end-before: #ANCHOR_END: main
   :code:

In the `main` function, we:

1. Define the address and port to listen on (`127.0.0.1:8080`).
2. Create an instance of the server using [new(typedesc[HttpServerRef], TransportAddress, HttpProcessCallback2, set[HttpServerFlags], set[ServerFlags], string, int, int, int, int, int, openArray[HttpServerMiddlewareRef])].
3. Start the server with [start(HttpServerRef)].
4. Use [join(HttpServerRef)] to wait until the server is stopped (which, in this case, will be never, until we manually terminate the program with `Ctrl-C`).
5. In the `finally` block, we ensure the server is stopped and its resources are released correctly.

.. note::
   [`valueOr`](https://github.com/arnetheduck/nim-results/blob/master/results.nim#L1267) is a helper template from the [`results`](https://github.com/arnetheduck/nim-results) package that returns the value of a `Result` or executes a given code block if it is an error.

.. include:: ../../../examples/http_server/chapter1/src/dashboard.nim
   :start-after: #ANCHOR: run
   :end-before: #ANCHOR_END: run
   :code:

Finally, we use [waitFor(Future[void])] to start our async `main` routine.

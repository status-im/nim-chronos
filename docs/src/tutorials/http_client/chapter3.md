# Making Requests Concurrently

**Goal:** Learn how to make arbitrarily many HTTP requests asynchronously.

**Source code:** [chapter3/src/uptimemon.nim](https://github.com/status-im/nim-chronos/blob/master/examples/http_client/chapter3/src/uptimemon.nim)

In the previous chapter, we learned how to reuse a session to check multiple URIs serially. While efficient, checking URIs one by one is slow. Now, let's unlock the true power of Chronos—concurrency!

We want Chronos to start all the requests at the same time and handle each result as soon as it's available.

To achieve that, we will:

1. Use `mapIt` from `std/sequtils` to create a list of `Future`s for our requests.
2. Await all `Future`s at once with [`allFutures`](api/chronos/internal/asyncfutures.html#allFutures,varargs[Future[T]]).
3. Add cancellation logic to ensure that if the main check is cancelled, all individual requests are also cancelled and awaited.

Here's the code:

```nim
{{#shiftinclude auto:../../../../examples/http_client/chapter3/src/uptimemon.nim:all}}
```

Run this code with `nimble run`. You should see something like this (the order of messages may be different):

```shell
[NOK] https://mock.codes/403: 403
[OK] https://duckduckgo.com/?q=chronos
```

Notice that:

1. The order of responses is different from the order of the URIs in the source code. That's because our requests are now asynchronous and complete at different times.
2. The execution time has improved. Now, the program runs roughly as long as its longest request, not the sum of all requests.

Let's examine the changes since the previous version.

```nim
{{#shiftinclude auto:../../../../examples/http_client/chapter3/src/uptimemon.nim:check_uris}}
```

In our `check` function for multiple URIs, we've replaced the loop with concurrent execution:

1. We use `mapIt` to create a list of `Future`s, one for each URI. Each call to `session.check(it)` returns a `Future[void]` and starts the request in the background.
2. We use `allFutures` to await all those `Future`s at once.
3. We add a `try..except CancelledError` block around `allFutures`. This is important: if `check(uris)` itself is cancelled, we want to make sure all the pending requests we started are also cancelled and cleaned up properly. Using `cancelAndWait(futures)` ensures that all resources are freed immediately.

Note that since we handle the cancellation internally and don't re-raise the exception, the function signature is now `raises: []`. In async procedures, if you handle all potential exceptions, including `CancelledError`, the compiler sees it as not raising anything.

In the next chapter, we'll see how to prevent slow requests from freezing our application using timeouts!

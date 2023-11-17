# Concepts

Async/await is a programming model that relies on cooperative multitasking to
coordinate the concurrent execution of procedures, using event notifications
from the operating system or other treads to resume execution.

<!-- toc -->

## The dispatcher

The event handler loop is called a "dispatcher" and a single instance per
thread is created, as soon as one is needed.

Scheduling is done by calling [async procedures](./async_procs.md) that return
`Future` objects - each time a procedure is unable to make further
progress, for example because it's waiting for some data to arrive, it hands
control back to the dispatcher which ensures that the procedure is resumed when
ready.

A single thread, and thus a single dispatcher, is typically able to handle
thousands of concurrent in-progress requests.

## The `Future` type

`Future` objects encapsulate the outcome of executing an `async` procedure. The
`Future` may be `pending` meaning that the outcome is not yet known or
`finished` meaning that the return value is available, the operation failed
with an exception or was cancelled.

Inside an async procedure, you can `await` the outcome of another async
procedure - if the `Future` representing that operation is still `pending`, a
callback representing where to resume execution will be added to it and the
dispatcher will be given back control to deal with other tasks.

When a `Future` is `finished`, all its callbacks are scheduled to be run by
the dispatcher, thus continuing any operations that were waiting for an outcome.

## The `poll` call

To trigger the processing step of the dispatcher, we need to call `poll()` -
either directly or through a wrapper like `runForever()` or `waitFor()`.

Each call to poll handles any file descriptors, timers and callbacks that are
ready to be processed.

Using `waitFor`, the result of a single asynchronous operation can be obtained:

```nim
proc myApp() {.async.} =
  echo "Waiting for a second..."
  await sleepAsync(1.seconds)
  echo "done!"

waitFor myApp()
```

It is also possible to keep running the event loop forever using `runForever`:

```nim
proc myApp() {.async.} =
  while true:
    await sleepAsync(1.seconds)
    echo "A bit more than a second passed!"

let future = myApp()
runForever()
```

Such an application never terminates, thus it is rare that applications are
structured this way.

```admonish warning
Both `waitFor` and `runForever` call `poll` which offers fine-grained
control over the event loop steps.

Nested calls to `poll` - directly or indirectly via `waitFor` and `runForever`
are not allowed.
```

## Cancellation

Any pending `Future` can be cancelled. This can be used for timeouts, to start
multiple parallel operations and cancel the rest as soon as one finishes,
to initiate the orderely shutdown of an application etc.

```nim
{{#include ../examples/cancellation.nim}}
```

Even if cancellation is initiated, it is not guaranteed that the operation gets
cancelled - the future might still be completed or fail depending on the
order of events in the dispatcher and the specifics of the operation.

If the future indeed gets cancelled, `await` will raise a
`CancelledError` as is likely to happen in the following example:

```nim
proc c1 {.async.} =
  echo "Before sleep"
  try:
    await sleepAsync(10.minutes)
    echo "After sleep" # not reach due to cancellation
  except CancelledError as exc:
    echo "We got cancelled!"
    # `CancelledError` is typically re-raised to notify the caller that the
    # operation is being cancelled
    raise exc

proc c2 {.async.} =
  await c1()
  echo "Never reached, since the CancelledError got re-raised"

let work = c2()
waitFor(work.cancelAndWait())
```

The `CancelledError` will now travel up the stack like any other exception.
It can be caught for instance to free some resources and is then typically
re-raised for the whole chain operations to get cancelled.

Alternatively, the cancellation request can be translated to a regular outcome of the operation - for example, a `read` operation might return an empty result.

Cancelling an already-finished `Future` has no effect, as the following example
of downloading two web pages concurrently shows:

```nim
{{#include ../examples/twogets.nim}}
```

## Compile-time configuration

`chronos` contains several compile-time [configuration options](./chronos/config.nim) enabling stricter compile-time checks and debugging helpers whose runtime cost may be significant.

Strictness options generally will become default in future chronos releases and allow adapting existing code without changing the new version - see the [`config.nim`](./chronos/config.nim) module for more information.

# Concepts

Async/await is a programming model that relies on cooperative multitasking to
coordinate the concurrent execution of procedures, using event notifications
from the operating system or other treads to resume execution.

Code execution happens in a loop that alternates between making progress on
tasks and handling events.

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

Alternatively, the cancellation request can be translated to a regular outcome
of the operation - for example, a `read` operation might return an empty result.

Cancelling an already-finished `Future` has no effect, as the following example
of downloading two web pages concurrently shows:

```nim
{{#include ../examples/twogets.nim}}
```

### Ownership

When calling a procedure that returns a `Future`, ownership of that `Future` is
shared between the callee that created it and the caller that waits for it to be
finished.

The `Future` can be thought of as a single-item channel between a producer and a
consumer. The producer creates the `Future` and is responsible for completing or
failing it while the caller waits for completion and may `cancel` it.

Although it is technically possible, callers must not `complete` or `fail`
futures and callees or other intermediate observers must not `cancel` them as
this may lead to panics and shutdown (ie if the future is completed twice or a
cancalletion is not handled by the original caller).

### `noCancel`

Certain operations must not be cancelled for semantic reasons. Common scenarios
include `closeWait` that releases a resources irrevocably and composed
operations whose individual steps should be performed together or not at all.

In such cases, the `noCancel` modifier to `await` can be used to temporarily
disable cancellation propagation, allowing the operation to complete even if
the caller initiates a cancellation request:

```nim
proc deepSleep(dur: Duration) {.async.} =
  # `noCancel` prevents any cancellation request by the caller of `deepSleep`
  # from reaching `sleepAsync` - even if `deepSleep` is cancelled, its future
  # will not complete until the sleep finishes.
  await noCancel sleepAsync(dur)

let future = deepSleep(10.minutes)

# This will take ~10 minutes even if we try to cancel the call to `deepSleep`!
await cancelAndWait(future)
```

### `join`

The `join` modifier to `await` allows cancelling an `async` procedure without
propagating the cancellation to the awaited operation. This is useful when
`await`:ing a `Future` for monitoring purposes, ie when a procedure is not the
owner of the future that's being `await`:ed.

One situation where this happens is when implementing the "observer" pattern,
where a helper monitors an operation it did not initiate:

```nim
var tick: Future[void]
proc ticker() {.async.} =
  while true:
    tick = sleepAsync(1.second)
    await tick
    echo "tick!"

proc tocker() {.async.} =
  # This operation does not own or implement the operation behind `tick`,
  # so it should not cancel it when `tocker` is cancelled
  await join tick
  echo "tock!"

let
  fut = ticker() # `ticker` is now looping and most likely waiting for `tick`
  fut2 = tocker() # both `ticker` and `tocker` are waiting for `tick`

# We don't want `tocker` to cancel a future that was created in `ticker`
waitFor fut2.cancelAndWait()

waitFor fut # keeps printing `tick!` every second.
```

## Compile-time configuration

`chronos` contains several compile-time
[configuration options](./chronos/config.nim) enabling stricter compile-time
checks and debugging helpers whose runtime cost may be significant.

Strictness options generally will become default in future chronos releases and
allow adapting existing code without changing the new version - see the
[`config.nim`](./chronos/config.nim) module for more information.

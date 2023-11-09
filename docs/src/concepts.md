# Concepts

<!-- toc -->

## The dispatcher

Chronos implements the async/await paradigm in a self-contained library using
the macro and closure iterator transformation features provided by Nim.

Async/await programming relies on cooperative concurrency to make progress on
a series of tasks scheduled by the program. The tasks are run by an event loop
that is responsible for making progress on all tasks that are ready to be
executed then wait for OS events indicating that further progress is possible.

The event loop is called a "dispatcher" and a single instance per thread is
created, as soon as one is needed.

## The `Future` type

`Future` objects encapsulate the result of an `async` procedure upon successful
completion, and a list of callbacks to be scheduled after any type of
completion - be that success, failure or cancellation.

[Async procedures](./async_functions.md) return `Future` objects.

Inside an async procedure, you can `await` the future returned by another async
procedure. At this point, control will be handled to the event loop until that
future is completed.

A `Future` remains in the `pending` state until its associated task is
`finished`, either by being `completed`, `failed` or `cancelled`.

## The `poll` call

To trigger the processing step of the dispatcher, we need to call `poll()` -
either directly or through a wrapper like `runForever()` or `waitFor()`.

Each step handles any file descriptors, timers and callbacks that are ready to
be processed.

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

Nested calls to `poll`, `waitFor` and `runForever` are not supported.
```

## Cancellation

Any running `Future` can be cancelled. This can be used for timeouts,
to let a user cancel a running task, to start multiple futures in parallel
and cancel them as soon as one finishes, etc.

```nim
{{#inlcude examples/cancellation.nim}}
```

Even if cancellation is initiated, it is not guaranteed that
the operation gets cancelled - the future might still be completed
or fail depending on the ordering of events and the specifics of
the operation.

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
    raise exc

proc c2 {.async.} =
  await c1()
  echo "Never reached, since the CancelledError got re-raised"

let work = c2()
waitFor(work.cancelAndWait())
```

The `CancelledError` will now travel up the stack like any other exception.
It can be caught and handled (for instance, freeing some resources)

## Compile-time configuration

`chronos` contains several compile-time [configuration options](./chronos/config.nim) enabling stricter compile-time checks and debugging helpers whose runtime cost may be significant.

Strictness options generally will become default in future chronos releases and allow adapting existing code without changing the new version - see the [`config.nim`](./chronos/config.nim) module for more information.

## Platform independence

Several functions in `chronos` are backed by the operating system, such as
waiting for network events, creating files and sockets etc. The specific
exceptions that are raised by the OS is platform-dependent, thus such functions
are declared as raising `CatchableError` but will in general raise something
more specific. In particular, it's possible that some functions that are
annotated as raising `CatchableError` only raise on _some_ platforms - in order
to work on all platforms, calling code must assume that they will raise even
when they don't seem to do so on one platform.

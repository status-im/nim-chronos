# Async procedures

Async procedures are those that interact with `chronos` to cooperatively
suspend and resume their execution depending on the completion of other
async procedures, timers, tasks on other threads or asynchronous I/O scheduled
with the operating system.

Async procedures are marked with the `{.async.}` pragma and return a `Future`
indicating the state of the operation.

<!-- toc -->

## The `async` pragma

The `{.async.}` pragma will transform a procedure (or a method) returning a
`Future` into a closure iterator. If there is no return type specified,
`Future[void]` is returned.

```nim
proc p() {.async.} =
  await sleepAsync(100.milliseconds)

echo p().type # prints "Future[system.void]"
```

## `await` keyword

The `await` keyword operates on `Future` instances typically returned from an
`async` procedure.

Whenever `await` is encountered inside an async procedure, control is given
back to the dispatcher for as many steps as it's necessary for the awaited
future to complete, fail or be cancelled. `await` calls the
equivalent of `Future.read()` on the completed future to return the
encapsulated value when the operation finishes.

```nim
proc p1() {.async.} =
  await sleepAsync(1.seconds)

proc p2() {.async.} =
  await sleepAsync(1.seconds)

proc p3() {.async.} =
  let
    fut1 = p1()
    fut2 = p2()
  # Just by executing the async procs, both resulting futures entered the
  # dispatcher queue and their "clocks" started ticking.
  await fut1
  await fut2
  # Only one second passed while awaiting them both, not two.

waitFor p3()
```

```admonition warning
Because `async` procedures are executed concurrently, they are subject to many
of the same risks that typically accompany multithreaded programming.

In particular, if two `async` procedures have access to the same mutable state,
the value before and after `await` might not be the same as the order of execution is not guaranteed!
```

## Raw async procedures

Raw async procedures are those that interact with `chronos` via the `Future`
type but whose body does not go through the async transformation.

Such functions are created by adding `raw: true` to the `async` parameters:

```nim
proc rawAsync(): Future[void] {.async: (raw: true).} =
  let fut = newFuture[void]("rawAsync")
  fut.complete()
  fut
```

Raw functions must not raise exceptions directly - they are implicitly declared
as `raises: []` - instead they should store exceptions in the returned `Future`:

```nim
proc rawFailure(): Future[void] {.async: (raw: true).} =
  let fut = newFuture[void]("rawAsync")
  fut.fail((ref ValueError)(msg: "Oh no!"))
  fut
```

Raw procedures can also use checked exceptions:

```nim
proc rawAsyncRaises(): Future[void] {.async: (raw: true, raises: [IOError]).} =
  let fut = newFuture[void]()
  assert not (compiles do: fut.fail((ref ValueError)(msg: "uh-uh")))
  fut.fail((ref IOError)(msg: "IO"))
  fut
```

## Callbacks and closures

Callback/closure types are declared using the `async` annotation as usual:

```nim
type MyCallback = proc(): Future[void] {.async.}

proc runCallback(cb: MyCallback) {.async: (raises: []).} =
  try:
    await cb()
  except CatchableError:
    discard # handle errors as usual
```

When calling a callback, it is important to remember that it may raise exceptions that need to be handled.

Checked exceptions can be used to limit the exceptions that a callback can
raise:

```nim
type MyEasyCallback = proc(): Future[void] {.async: (raises: []).}

proc runCallback(cb: MyEasyCallback) {.async: (raises: [])} =
  await cb()
```

# Async functions

<!-- toc -->

## The `async` pragma

The `{.async.}` pragma will transform a procedure (or a method) returning a
specialised `Future` type into a closure iterator. If there is no return type
specified, a `Future[void]` is returned.

```nim
proc p() {.async.} =
  await sleepAsync(100.milliseconds)

echo p().type # prints "Future[system.void]"
```

## `await` keyword

Whenever `await` is encountered inside an async procedure, control is passed
back to the dispatcher for as many steps as it's necessary for the awaited
future to complete successfully, fail or be cancelled. `await` calls the
equivalent of `Future.read()` on the completed future and returns the
encapsulated value.

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
  # dispatcher's queue and their "clocks" started ticking.
  await fut1
  await fut2
  # Only one second passed while awaiting them both, not two.

waitFor p3()
```

Don't let `await`'s behaviour of giving back control to the dispatcher surprise
you. If an async procedure modifies global state, and you can't predict when it
will start executing, the only way to avoid that state changing underneath your
feet, in a certain section, is to not use `await` in it.

## Raw functions

Raw functions are those that interact with `chronos` via the `Future` type but
whose body does not go through the async transformation.

Such functions are created by adding `raw: true` to the `async` parameters:

```nim
proc rawAsync(): Future[void] {.async: (raw: true).} =
  let future = newFuture[void]("rawAsync")
  future.complete()
  return future
```

Raw functions must not raise exceptions directly - they are implicitly declared
as `raises: []` - instead they should store exceptions in the returned `Future`:

```nim
proc rawFailure(): Future[void] {.async: (raw: true).} =
  let future = newFuture[void]("rawAsync")
  future.fail((ref ValueError)(msg: "Oh no!"))
  return future
```

Raw functions can also use checked exceptions:

```nim
proc rawAsyncRaises(): Future[void] {.async: (raw: true, raises: [IOError]).} =
  let fut = newFuture[void]()
  assert not (compiles do: fut.fail((ref ValueError)(msg: "uh-uh")))
  fut.fail((ref IOError)(msg: "IO"))
  return fut
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

When calling a callback, it is important to remember that the given function
may raise and exceptions need to be handled.

Checked exceptions can be used to limit the exceptions that a callback can
raise:

```nim
type MyEasyCallback = proc: Future[void] {.async: (raises: []).}

proc runCallback(cb: MyEasyCallback) {.async: (raises: [])} =
  await cb()
```

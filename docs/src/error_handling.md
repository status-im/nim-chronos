# Errors and exceptions

<!-- toc -->

## Exceptions

Exceptions inheriting from [`CatchableError`](https://nim-lang.org/docs/system.html#CatchableError)
interrupt execution of an `async` procedure. The exception is placed in the
`Future.error` field while changing the status of the `Future` to `Failed`
and callbacks are scheduled.

When a future is read or awaited the exception is re-raised, traversing the
`async` execution chain until handled.

```nim
proc p1() {.async.} =
  await sleepAsync(1.seconds)
  raise newException(ValueError, "ValueError inherits from CatchableError")

proc p2() {.async.} =
  await sleepAsync(1.seconds)

proc p3() {.async.} =
  let
    fut1 = p1()
    fut2 = p2()
  await fut1
  echo "unreachable code here"
  await fut2

# `waitFor()` would call `Future.read()` unconditionally, which would raise the
# exception in `Future.error`.
let fut3 = p3()
while not(fut3.finished()):
  poll()

echo "fut3.state = ", fut3.state # "Failed"
if fut3.failed():
  echo "p3() failed: ", fut3.error.name, ": ", fut3.error.msg
  # prints "p3() failed: ValueError: ValueError inherits from CatchableError"
```

You can put the `await` in a `try` block, to deal with that exception sooner:

```nim
proc p3() {.async.} =
  let
    fut1 = p1()
    fut2 = p2()
  try:
    await fut1
  except CachableError:
    echo "p1() failed: ", fut1.error.name, ": ", fut1.error.msg
  echo "reachable code here"
  await fut2
```

Because `chronos` ensures that all exceptions are re-routed to the `Future`,
`poll` will not itself raise exceptions.

`poll` may still panic / raise `Defect` if such are raised in user code due to
undefined behavior.

## Checked exceptions

By specifying a `raises` list to an async procedure, you can check which
exceptions can be raised by it:

```nim
proc p1(): Future[void] {.async: (raises: [IOError]).} =
  assert not (compiles do: raise newException(ValueError, "uh-uh"))
  raise newException(IOError, "works") # Or any child of IOError

proc p2(): Future[void] {.async, (raises: [IOError]).} =
  await p1() # Works, because await knows that p1
             # can only raise IOError
```

Under the hood, the return type of `p1` will be rewritten to an internal type
which will convey raises informations to `await`.

```admonition note
Most `async` include `CancelledError` in the list of `raises`, indicating that
the operation they implement might get cancelled resulting in neither value nor
error!
```

When using checked exceptions, the `Future` type is modified to include
`raises` information - it can be constructed with the `Raising` helper:

```nim
# Create a variable of the type that will be returned by a an async function
# raising `[CancelledError]`:
var fut: Future[int].Raising([CancelledError])
```

```admonition note
`Raising` creates a specialization of `InternalRaisesFuture` type - as the name
suggests, this is an internal type whose implementation details are likely to
change in future `chronos` versions.
```

## The `Exception` type

Exceptions deriving from `Exception` are not caught by default as these may
include `Defect` and other forms undefined or uncatchable behavior.

Because exception effect tracking is turned on for `async` functions, this may
sometimes lead to compile errors around forward declarations, methods and
closures as Nim conservatively asssumes that any `Exception` might be raised
from those.

Make sure to excplicitly annotate these with `{.raises.}`:

```nim
# Forward declarations need to explicitly include a raises list:
proc myfunction() {.raises: [ValueError].}

# ... as do `proc` types
type MyClosure = proc() {.raises: [ValueError].}

proc myfunction() =
  raise (ref ValueError)(msg: "Implementation here")

let closure: MyClosure = myfunction
```

For compatibility, `async` functions can be instructed to handle `Exception` as
well, specifying `handleException: true`. `Exception` that is not a `Defect` and
not a `CatchableError` will then be caught and remapped to
`AsyncExceptionError`:

```nim
proc raiseException() {.async: (handleException: true, raises: [AsyncExceptionError]).} =
  raise (ref Exception)(msg: "Raising Exception is UB")

proc callRaiseException() {.async: (raises: []).} =
  try:
    raiseException()
  except AsyncExceptionError as exc:
    # The original Exception is available from the `parent` field
    echo exc.parent.msg
```

This mode can be enabled globally with `-d:chronosHandleException` as a help
when porting code to `chronos` but should generally be avoided as global
configuration settings may interfere with libraries that use `chronos` leading
to unexpected behavior.


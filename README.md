# Chronos - An efficient library for asynchronous programming

[![Github action](https://github.com/status-im/nim-chronos/workflows/nim-chronos%20CI/badge.svg)](https://github.com/status-im/nim-chronos/actions/workflows/ci.yml)
[![Windows build status (AppVeyor)](https://img.shields.io/appveyor/ci/nimbus/nim-asyncdispatch2/master.svg?label=Windows "Windows build status (Appveyor)")](https://ci.appveyor.com/project/nimbus/nim-asyncdispatch2)
[![License: Apache](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
![Stability: experimental](https://img.shields.io/badge/stability-experimental-orange.svg)

## Introduction

Chronos is an efficient [async/await](https://en.wikipedia.org/wiki/Async/await) framework for Nim. Features include:

* Efficient dispatch pipeline for asynchronous execution
* HTTP server with SSL/TLS support out of the box (no OpenSSL needed)
* Cancellation support
* Synchronization primitivies like queues, events and locks
* FIFO processing order of dispatch queue
* Minimal exception effect support (see [exception effects](#exception-effects))

## Installation

You can use Nim's official package manager Nimble to install Chronos:

```text
nimble install https://github.com/status-im/nim-chronos.git
```

or add a dependency to your `.nimble` file:

```text
requires "chronos"
```

## Projects using `chronos`

* [libp2p](https://github.com/status-im/nim-libp2p) - Peer-to-Peer networking stack implemented in many languages
* [Scorper](https://github.com/bung87/scorper) - Web framework
* [2DeFi](https://github.com/gogolxdong/2DeFi) - Decentralised file system

`chronos` is available in the [Nim Playground](https://play.nim-lang.org/#ix=2TpS)

Submit a PR to add yours!

## Documentation

### Concepts

Chronos implements the async/await paradigm in a self-contained library, using
macros, with no specific helpers from the compiler.

Our event loop is called a "dispatcher" and a single instance per thread is
created, as soon as one is needed.

To trigger a dispatcher's processing step, we need to call `poll()` - either
directly or through a wrapper like `runForever()` or `waitFor()`. This step
handles any file descriptors, timers and callbacks that are ready to be
processed.

`Future` objects encapsulate the result of an async procedure, upon successful
completion, and a list of callbacks to be scheduled after any type of
completion - be that success, failure or cancellation.

(These explicit callbacks are rarely used outside Chronos, being replaced by
implicit ones generated by async procedure execution and `await` chaining.)

Async procedures (those using the `{.async.}` pragma) return `Future` objects.

Inside an async procedure, you can `await` the future returned by another async
procedure. At this point, control will be handled to the event loop until that
future is completed.

Future completion is tested with `Future.finished()` and is defined as success,
failure or cancellation. This means that a future is either pending or completed.

To differentiate between completion states, we have `Future.failed()` and
`Future.cancelled()`.

### Dispatcher

You can run the "dispatcher" event loop forever, with `runForever()` which is defined as:

```nim
proc runForever*() =
  while true:
    poll()
```

You can also run it until a certain future is completed, with `waitFor()` which
will also call `Future.read()` on it:

```nim
proc p(): Future[int] {.async.} =
  await sleepAsync(100.milliseconds)
  return 1

echo waitFor p() # prints "1"
```

`waitFor()` is defined like this:

```nim
proc waitFor*[T](fut: Future[T]): T =
  while not(fut.finished()):
    poll()
  return fut.read()
```

### Async procedures and methods

The `{.async.}` pragma will transform a procedure (or a method) returning a
specialised `Future` type into a closure iterator. If there is no return type
specified, a `Future[void]` is returned.

```nim
proc p() {.async.} =
  await sleepAsync(100.milliseconds)

echo p().type # prints "Future[system.void]"
```

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

### Error handling

Exceptions inheriting from `Exception` (or `CatchableError` when
`-d:chronosStrictException` is enabled) are caught by hidden `try` blocks
and placed in the `Future.error` field, changing the future status to `Failed`.

When a future is awaited, that exception is re-raised, only to be caught again
by a hidden `try` block in the calling async procedure. That's how these
exceptions move up the async chain.

A failed future's callbacks will still be scheduled, but it's not possible to
resume execution from the point an exception was raised.

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

Chronos does not allow that future continuations and other callbacks raise
`CatchableError` - as such, calls to `poll` will never raise exceptions caused
originating from tasks on the dispatcher queue. It is however possible that
`Defect` that happen in tasks bubble up through `poll` as these are not caught
by the transformation.

#### Checked exceptions

By using `asyncraises` instead of `async`, you can check which
exceptions can be thrown by an async procedure.
```nim
proc p1(): Future[void] {.asyncraises: [IOError].} =
  assert not (compiles do: raise newException(ValueError, "uh-uh"))
  raise newException(IOError, "works") # Or any child of IOError
```

Under the hood, the return type of `p1` will be rewritten to another type,
which will convey raises informations to await.

```nim
proc p2(): Future[void] {.asyncraises: [IOError].} =
  await p1() # Works, because await knows that p1
             # can only raise IOError
```

The hidden type (`FuturEx`) is implicitely convertible into a Future.
However, it may causes issues when creating callback or methods
```nim
proc p3(): Future[void] {.asyncraises: [IOError].} =
  let fut: Future[void] = p1() # works
  assert not compiles(await fut) # await lost informations about raises,
                                 # so it can raise anything

  # Callbacks
  assert not(compiles do: let cb1: proc(): Future[void] = p1) # doesn't work
  let cb2: proc(): Future[void] {.asyncraises: [IOError].} = p1 # works
  assert not(compiles do:
    type c = proc(): Future[void] {.asyncraises: [IOError, ValueError].}
    let cb3: c = p1 # doesn't work, the raises must match _exactly_
  )
```

### Platform independence

Several functions in `chronos` are backed by the operating system, such as
waiting for network events, creating files and sockets etc. The specific
exceptions that are raised by the OS is platform-dependent, thus such functions
are declared as raising `CatchableError` but will in general raise something
more specific. In particular, it's possible that some functions that are
annotated as raising `CatchableError` only raise on _some_ platforms - in order
to work on all platforms, calling code must assume that they will raise even
when they don't seem to do so on one platform.

### Exception effects

`chronos` currently offers minimal support for exception effects and `raises`
annotations. In general, during the `async` transformation, a generic
`except CatchableError` handler is added around the entire function being
transformed, in order to catch any exceptions and transfer them to the `Future`.
Because of this, the effect system thinks no exceptions are "leaking" because in
fact, exception _handling_ is deferred to when the future is being read.

Effectively, this means that while code can be compiled with
`{.push raises: [Defect]}`, the intended effect propagation and checking is
**disabled** for `async` functions.

To enable checking exception effects in `async` code, enable strict mode with
`-d:chronosStrictException`.

In the strict mode, `async` functions are checked such that they only raise
`CatchableError` and thus must make sure to explicitly specify exception
effects on forward declarations, callbacks and methods using
`{.raises: [CatchableError].}` (or more strict) annotations.

### Multiple async backend support

Thanks to its powerful macro support, Nim allows `async`/`await` to be
implemented in libraries with only minimal support from the language - as such,
multiple `async` libraries exist, including `chronos` and `asyncdispatch`, and
more may come to be developed in the futures.

Libraries built on top of `async`/`await` may wish to support multiple async
backends - the best way to do so is to create separate modules for each backend
that may be imported side-by-side - see [nim-metrics](https://github.com/status-im/nim-metrics/blob/master/metrics/)
for an example.

An alternative way is to select backend using a global compile flag - this
method makes it diffucult to compose applications that use both backends as may
happen with transitive dependencies, but may be appropriate in some cases -
libraries choosing this path should call the flag `asyncBackend`, allowing
applications to choose the backend with `-d:asyncBackend=<backend_name>`.

Known `async` backends include:

* `chronos` - this library (`-d:asyncBackend=chronos`)
* `asyncdispatch` the standard library `asyncdispatch` [module](https://nim-lang.org/docs/asyncdispatch.html) (`-d:asyncBackend=asyncdispatch`)
* `none` - ``-d:asyncBackend=none`` - disable ``async`` support completely

``none`` can be used when a library supports both a synchronous and
asynchronous API, to disable the latter.

## TODO
  * Pipe/Subprocess Transports.
  * Multithreading Stream/Datagram servers

## Contributing

When submitting pull requests, please add test cases for any new features or fixes and make sure `nimble test` is still able to execute the entire test suite successfully.

`chronos` follows the [Status Nim Style Guide](https://status-im.github.io/nim-style-guide/).

## Other resources

* [Historical differences with asyncdispatch](https://github.com/status-im/nim-chronos/wiki/AsyncDispatch-comparison)

## License

Licensed and distributed under either of

* MIT license: [LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT

or

* Apache License, Version 2.0, ([LICENSE-APACHEv2](LICENSE-APACHEv2) or http://www.apache.org/licenses/LICENSE-2.0)

at your option. These files may not be copied, modified, or distributed except according to those terms.

# Porting code to `chronos` v4

<!-- toc -->

Thanks to its macro support, Nim allows `async`/`await` to be implemented in
libraries with only minimal support from the language - as such, multiple
`async` libraries exist, including `chronos` and `asyncdispatch`, and more may
come to be developed in the futures.

## Chronos v3

Chronos v4 introduces new features for IPv6, exception effects, a stand-alone
`Future` type as well as several other changes - when upgrading from chronos v3,
here are several things to consider:

* Exception handling is now strict by default - see the [error handling](./error_handling.md)
  chapter for how to deal with `raises` effects
* `AsyncEventBus` was removed - use `AsyncEventQueue` instead
* `Future.value` and `Future.error` panic when accessed in the wrong state
* `Future.read` and `Future.readError` raise `FutureError` instead of
  `ValueError` when accessed in the wrong state

## `asyncdispatch`

Code written for `asyncdispatch` and `chronos` looks similar but there are
several differences to be aware of:

* `chronos` has its own dispatch loop - you can typically not mix `chronos` and
  `asyncdispatch` in the same thread
* `import chronos` instead of `import asyncdispatch`
* cleanup is important - make sure to use `closeWait` to release any resources
  you're using or file descriptor and other leaks will ensue
* cancellation support means that `CancelledError` may be raised from most
  `{.async.}` functions
* Calling `yield` directly in tasks is not supported - instead, use `awaitne`.
* `asyncSpawn` is used instead of `asyncCheck` - note that exceptions raised
  in tasks that are `asyncSpawn`:ed cause panic

## Supporting multiple backends

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

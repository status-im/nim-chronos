# Introduction

Chronos implements the [async/await](https://en.wikipedia.org/wiki/Async/await)
paradigm in a self-contained library using macro and closure iterator
transformation features provided by Nim.

Features include:

* Asynchronous socket and process I/O
* HTTP client / server with SSL/TLS support out of the box (no OpenSSL needed)
* Synchronization primitivies like queues, events and locks
* [Cancellation](./concepts.md#cancellation)
* Efficient dispatch pipeline with excellent multi-platform support
* Exception [effect support](./guide.md#error-handling)

## Installation

Install `chronos` using `nimble`:

```text
nimble install chronos
```

or add a dependency to your `.nimble` file:

```text
requires "chronos"
```

and start using it:

```nim
{{#include ../examples/httpget.nim}}
```

There are more [examples](./examples.md) throughout the manual!

## Platform support

Several platforms are supported, with different backend [options](./concepts.md#compile-time-configuration):

* Windows: [`IOCP`](https://learn.microsoft.com/en-us/windows/win32/fileio/i-o-completion-ports)
* Linux: [`epoll`](https://en.wikipedia.org/wiki/Epoll) / `poll`
* OSX / BSD: [`kqueue`](https://en.wikipedia.org/wiki/Kqueue) / `poll`
* Android / Emscripten / posix: `poll`

## API documentation

This guide covers basic usage of chronos - for details, see the
[API reference](./api/chronos.html).

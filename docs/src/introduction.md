# Introduction

Chronos implements the [async/await](https://en.wikipedia.org/wiki/Async/await)
paradigm in a self-contained library using macro and closure iterator
transformation features provided by Nim.

Features include:

* Asynchronous socket and process I/O
* HTTP server with SSL/TLS support out of the box (no OpenSSL needed)
* Synchronization primitivies like queues, events and locks
* Cancellation
* Efficient dispatch pipeline with excellent multi-platform support
* Exception [effect support](./guide.md#error-handling)

## Examples

Examples are available in the [`docs/examples/`](https://github.com/status-im/nim-chronos/docs/examples) folder.

## API documentation

This guide covers basic usage of chronos - for details, see the
[API reference](./api/chronos.html).

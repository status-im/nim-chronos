.. title:: Introduction
.. importdoc:: concepts
.. importdoc:: error_handling
.. importdoc:: examples
.. importdoc:: api/chronos
.. importdoc:: api/chronos/threadsync
.. importdoc:: api/chronos/apps/http/httpagent
.. importdoc:: api/chronos/apps/http/httpbodyrw
.. importdoc:: api/chronos/apps/http/httpclient
.. importdoc:: api/chronos/apps/http/httpcommon
.. importdoc:: api/chronos/apps/http/httpdebug
.. importdoc:: api/chronos/apps/http/httpserver
.. importdoc:: api/chronos/apps/http/httptable
.. importdoc:: api/chronos/apps/http/multipart
.. importdoc:: api/chronos/apps/http/shttpserver

Chronos implements the [async/await](https://en.wikipedia.org/wiki/Async/await)
paradigm in a self-contained library using macro and closure iterator
transformation features provided by Nim.

Features include:

* Asynchronous socket and process I/O
* HTTP client / server with SSL/TLS support out of the box (no OpenSSL needed)
* Synchronization primitivies like queues, events and locks
* [Cancellation]
* Efficient dispatch pipeline with excellent multi-platform support
* [Errors and exceptions](./error_handling.html)

# Installation

Install `chronos` using `nimble`:

```text
nimble install chronos
```

or add a dependency to your `.nimble` file:

```text
requires "chronos"
```

and start using it:

.. include:: ../examples/httpget.nim
   :code:

There are more [examples](./examples.html) throughout the manual!

# Platform support

Several platforms are supported, with different backend [Compile-time configuration]:

* Windows: [`IOCP`](https://learn.microsoft.com/en-us/windows/win32/fileio/i-o-completion-ports)
* Linux: [`epoll`](https://en.wikipedia.org/wiki/Epoll) / `poll`
* OSX / BSD: [`kqueue`](https://en.wikipedia.org/wiki/Kqueue) / `poll`
* Android / Emscripten / posix: `poll`

# API documentation

This guide covers basic usage of chronos - for details, see the API reference:
- [chronos](./api/chronos.html)
- [threadsync](./api/chronos/threadsync.html)
- [httpagent](./api/chronos/apps/http/httpagent.html)
- [httpbodyrw](./api/chronos/apps/http/httpbodyrw.html)
- [httpclient](./api/chronos/apps/http/httpclient.html)
- [httpcommon](./api/chronos/apps/http/httpcommon.html)
- [httpdebug](./api/chronos/apps/http/httpdebug.html)
- [httpserver](./api/chronos/apps/http/httpserver.html)
- [httptable](./api/chronos/apps/http/httptable.html)
- [multipart](./api/chronos/apps/http/multipart.html)
- [shttpserver](./api/chronos/apps/http/shttpserver.html)

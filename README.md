# nim-asyncdispatch2
[![Build Status](https://travis-ci.org/status-im/nim-asyncdispatch2.svg?branch=master)](https://travis-ci.org/status-im/nim-asyncdispatch2) [![Build status](https://ci.appveyor.com/api/projects/status/ihrxhooltyrmo0mc?svg=true)](https://ci.appveyor.com/project/cheatfate/nim-asyncdispatch2)

Asyncdispatch hard fork.

## Core differences between asyncdispatch and asyncdispatch2.

1. Unified callback type `CallbackFunc`.
   Current version of asyncdispatch uses many types of callbacks.

   `proc ()` used in callSoon() callbacks and Future[T] completion callbacks.
   `proc (fut: Future[T])` used in Future[T] completion callbacks.
   `proc (fd: AsyncFD, bytesTransferred: Dword, errcode: OSErrorCode)` used in  Windows IO completion callbacks.
   `proc (fd: AsyncFD): bool` used in Unix IO events callbacks.

   Such a number of different types creates big problems in the storage, processing and interaction between callbacks. Lack of ability to pass custom user data to
   callback also creates difficulties and inefficiency, to pass custom user-defined data you need to use closures (one more allocation).

   To resolve this issue introduced unified callback type `CallbackFunc`, which is
   looks like `CallbackFunc* = proc (arg: pointer = nil) {.gcsafe.}`. Also one more type is introduced for callback storage is `AsyncCallback`.

   ```
   type
       AsyncCallback* = object
         function*: CallbackFunc
         udata*: pointer
   ```

2. Future[T] completion callbacks order.
   Current version of asyncdispatch processing Future[T] completion callbacks in reverse order, asyncdispatch2 schedule callbacks in forward order.
   - https://github.com/nim-lang/Nim/issues/7197

3. Changed behavior of OS decriptor events callbacks.
   For some unknown reason current version of asyncdispatch uses seq[T] to hold list of descriptor event listeners. Actually in asynchronous environment there no need to have list of event listeners.

   So in asyncdispatch2 there only one place for one READ listener and one place for one WRITE listener.

4. Removed default timeout value for poll() procedure, which allows incorrect
   usage asyncdispatch and produces 500ms timeouts in correct usage.

5. Changed behavior of scheduler in poll() procedure.
   Fixed issues:
   - https://github.com/nim-lang/Nim/issues/7758
   - https://github.com/nim-lang/Nim/issues/7197
   - https://github.com/nim-lang/Nim/issues/7193
   - https://github.com/nim-lang/Nim/issues/7192
   - https://github.com/nim-lang/Nim/issues/6846
   - https://github.com/nim-lang/Nim/issues/6929

5. Asyncdispatch2 no longer use `epochTime()`, it uses most fastest time primitives for specific OS `fastEpochTime()`. Also because MacOS supports only millisecond resolution in `kqueue` there no need on submillisecond resolution.

   https://github.com/nim-lang/Nim/issues/3909

6. Removed all IO primitives recv(), recvFrom(), connect(), accept(), send(), sendTo() from public API, and moved all it functionality into Transports.

7. Introduced addTimer/removeTimer callback interface.

8. Introduced removeReader() for addReader() and removeWriter() for addWriter().

9. Changed behavior of addReader()/addWriter()/addTimer() callbacks, now only explicit removal of callbacks must be supplied via (removeReader(), removeWriter(), removeTimer())

10. Support cross-platform `sendfile` operation.

11. Removed expensive `AsyncEvent`, also removed support of hardware timers and ``addProcess``. (``addProcess`` will be implement as SubprocessTransport, while hardware based `AsyncEvent` will be renamed to ``ThreadAsyncEvent``).

12. Added cheap synchronization primitives AsyncLock, AsyncEvent, AsyncQueue[T].

## Transport concept.

Transports are high level interface for interaction with OS IO system.
The main task that the Transport concept is designed to solve is reduce number of syscalls and number of memory allocations to perform single IO operation. Current version of asyncdispatch uses at least 4 syscalls for every single IO operation:

For Posix compliant systems current version of asyncdispatch performs such operations for every single IO operation:

- register for read/write event in system queue
- wait for event in system queue
- perform IO operation
- unregister read/write event from system queue

For Windows system current version of asyncdispatch performs  allocations of OVERLAPPED structure for every single IO operation.

In order to successfully cope with the task Transport also needs to incorporate some `asyncnet.nim` functionality (e.g. buffering) for stream transports. So asyncdispatch2 has buffering IO by default.

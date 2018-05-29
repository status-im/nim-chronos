**nim-asyncdispatch2**
[![Build Status](https://travis-ci.org/status-im/nim-asyncdispatch2.svg?branch=master)](https://travis-ci.org/status-im/nim-asyncdispatch2) [![Build status](https://ci.appveyor.com/api/projects/status/ihrxhooltyrmo0mc?svg=true)](https://ci.appveyor.com/project/cheatfate/nim-asyncdispatch2)

**Asyncdispatch hard fork**

# Core differences between asyncdispatch and asyncdispatch2

1. Unified callback type `CallbackFunc`:

   Current version of asyncdispatch uses many types of callbacks:

   * `proc ()` is used in callSoon() callbacks and Future[T] completion callbacks.
   * `proc (fut: Future[T])` is used in Future[T] completion callbacks.
   * `proc (fd: AsyncFD, bytesTransferred: Dword, errcode: OSErrorCode)` is used in  Windows IO completion callbacks.
   * `proc (fd: AsyncFD): bool` is used in Unix IO event callbacks.

   Such a large number of different types creates big problems in the storage and processing of callbacks and in interaction between callbacks. Lack of ability to pass custom user data to
   a callback also creates difficulties and inefficiency with passing custom, user-defined data needed for using closures (one more allocation).

   To resolve this issue, we have introduced a unified callback type, `CallbackFunc`:

   ```nim
   type
     CallbackFunc* = proc (arg: pointer = nil) {.gcsafe.}
   ```
   Also, one more type was introduced for the callback storage, `AsyncCallback`:

   ```nim
   type
       AsyncCallback* = object
         function*: CallbackFunc
         udata*: pointer
   ```

2. The order of Future[T] completion callbacks:

    Current version of asyncdispatch processes Future[T] completion callbacks in reverse order, but asyncdispatch2 schedules callbacks in forward order: https://github.com/nim-lang/Nim/issues/7197

3. Changed the behavior of OS descriptor event callbacks:

    For some unknown reason, the current version of asyncdispatch uses seq[T] to hold a list of descriptor event listeners. However, in the asynchronous environment, there is no need for a list of event listeners. In asyncdispatch2, there is only one place for one READ listener and one place for one WRITE listener.

4. Removed the default timeout value for the poll() procedure, which allows incorrect usage of asyncdispatch and produces 500-ms timeouts in correct usage.

5. Changed the behavior of the scheduler in the poll() procedure, and fixed the following issues:
   * https://github.com/nim-lang/Nim/issues/7758
   * https://github.com/nim-lang/Nim/issues/7197
   * https://github.com/nim-lang/Nim/issues/7193
   * https://github.com/nim-lang/Nim/issues/7192
   * https://github.com/nim-lang/Nim/issues/6846
   * https://github.com/nim-lang/Nim/issues/6929


6. Asyncdispatch2 no longer uses `epochTime()`; instead, it uses the fastest time primitives for a specific OS, `fastEpochTime()`. Also, because MacOS supports only a millisecond resolution in `kqueue`, sub-millisecond resolution is not needed. For details, see https://github.com/nim-lang/Nim/issues/3909.

7. Removed all IO primitives (`recv()`, `recvFrom()`, `connect()`, `accept()`, `send()`, and `sendTo()`) from the public API, and moved all their functionality into Transports.

8. Introduced an `addTimer()` / `removeTimer()` callback interface.

9. Introduced `removeReader()` for `addReader()` and `removeWriter()` for `addWriter()`.

10. Changed the behavior of the `addReader()`, `addWriter()`, and `addTimer()` callbacks. Now, only the explicit removal of the callbacks must be supplied via `removeReader()`, `removeWriter()`, and `removeTimer()`.

11. Added the support for the cross-platform `sendfile()` operation.

12. Removed the expensive `AsyncEvent` and the support for hardware timers and `addProcess`. `addProcess` will be implemented as SubprocessTransport, while hardware-based `AsyncEvent` will be renamed to `ThreadAsyncEvent`.

13. Added cheap synchronization primitives: `AsyncLock`, `AsyncEvent`, and `AsyncQueue[T]`.

# Transport Concept

Transports are high-level interfaces for interaction with the OS IO system. The main task that the Transport concept is designed to solve is to reduce the number of syscalls and of memory allocations for performing a single IO operation. Current version of asyncdispatch uses at least four (4) syscalls for every single IO operation.

For Posix-compliant systems, current version of asyncdispatch performs such operations for every single IO operation:

- Register for a read/write event in the system queue
- Wait for an event in the system queue
- Perform an IO operation
- Unregister a read/write event from the system queue

For Windows system, the current version of asyncdispatch performs  allocations of OVERLAPPED structure for every single IO operation.

To successfully cope with the task, Transport also needs to incorporate some `asyncnet.nim` functionality (e.g. buffering) for stream transports. For this reason, asyncdispatch2 has buffering IO by default.

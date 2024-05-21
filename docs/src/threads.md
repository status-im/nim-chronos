# Threads

While the cooperative [`async`](./concepts.md) model offers an efficient model
for dealing with many tasks that often are blocked on I/O, it is not suitable
for long-running computations that would prevent concurrent tasks from progressing.

Multithreading offers a way to offload heavy computations to be executed in
parallel with the async work, or, in cases where a single event loop gets
overloaded, to manage multiple event loops in parallel.

For interaction between threads, the `ThreadSignalPtr` type (found in the
(`chronos/threadsync`)(https://github.com/status-im/nim-chronos/blob/master/chronos/threadsync.nim)
module) is used - both to wait for notifications coming from other threads and
to notify other threads of progress from within an async procedure.

```nim
{{#include ../examples/signalling.nim}}
```

### Memory management in multithreading scenarios

Keep in mind that nim _does not clean up thread-variables_ when the thread exits.
This is problematic for thread variables that are ref-types or contain ref-types, as those will not be cleaned up and thus start causing memory leaks.

This means, that the dispatcher, which is a thread variable and a ref-type, needs to be cleaned up manually. The same is true for the thread-local variables `localInstance` and `utcInstance` of std/times, which will be used if you use any logging library such as chronicles.
Not just that, you will also need to invoke ORC's cycle-collector manually, as chronos' data-structures are at times cyclical and thus need to be collected as well.

You can do so by calling `=destroy` on it and forcing ORC to do a collect of cyclical data-structures like so:

```nim
`=destroy`(times.localInstance)
`=destroy`(times.utcInstance)
`=destroy`(getThreadDispatcher())
when defined(gcOrc):
  GC_fullCollect()
```

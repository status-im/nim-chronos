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

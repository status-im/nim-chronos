.. title:: Tips, tricks and best practices
.. importdoc:: error_handling

# Timeouts

To prevent a single task from taking too long, `withTimeout` can be used:

.. include:: ../examples/timeoutsimple.nim
   :code:

When several tasks should share a single timeout, a common timer can be created
with `sleepAsync`:

.. include:: ../examples/timeoutcomposed.nim
   :code:

# `discard`

When calling an asynchronous procedure without `await`, the operation is started
but its result is not processed until corresponding `Future` is `read`.

It is therefore important to never `discard` futures directly - instead, one
can discard the result of awaiting the future or use `asyncSpawn` to monitor
the outcome of the future as if it were running in a separate thread.

Similar to threads, tasks managed by `asyncSpawn` may causes the application to
crash if any exceptions leak out of it - use
[Checked exceptions] to avoid this
problem.

.. include:: ../examples/discards.nim
   :code:

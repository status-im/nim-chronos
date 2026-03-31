# Scaling & Finishing Touches

**Goal:** Learn how to use semaphores to control concurrency.

**Source code:** [chapter6/src/uptimemon.nim](https://github.com/status-im/nim-chronos/blob/master/docs/examples/http_client/chapter6/src/uptimemon.nim)

Our app is almost ready to run on production and do regular background URI checks.

However, there's one issue we need to address before we can feed it tens of URIs and wrap it in a `while true`: we need to limit the number of simultaneous checks. If we don't do that, our app can potentially run out of file descriptors or choke the DNS resolver with 20+ requests.

Instead of simultaneusly launching checks for all URIs in the list, we'll run them in batches of 5, i.e. no more than 5 checks will run at any given moment, keeping resource usage low and under control.

To achieve that, we'll use a _semaphore_—an special object that a function must acquire to run and must release after it's finished. A semaphore can be acquired by a fixed number of function at any moment, and this is how it regulates concurrency.

Here's the code with a semaphore and an infinite loop added:

```nim
{{#shiftinclude auto:../../../examples/http_client/chapter6/src/uptimemon.nim:all}}
```

Let's see what changed.

```nim
{{#shiftinclude auto:../../../examples/http_client/chapter6/src/uptimemon.nim:maxConcurrency}}
```

We define a constant that would determine the capacity of our semaphore.

```nim
{{#shiftinclude auto:../../../examples/http_client/chapter6/src/uptimemon.nim:uris}}
```

We've added more URIs to the list to make batching effect visible.

```nim
{{#shiftinclude auto:../../../examples/http_client/chapter6/src/uptimemon.nim:semaphore}}
```

We've modified `check` function for a single URI so that it accepts a `semaphore` (of type[`AsyncSemaphore`](/api/chronos/asyncsync.html#AsyncSemaphore)), waits to [`acquire`](/api/chronos/asyncsync.html#acquire,AsyncSemaphore) it, and [`release`](/api/chronos/asyncsync.html#release,AsyncSemaphore)s it at the end (we use `defer` to postpone the release).

With this short addition, we prevent `check` from running if the semaphore is full.

Because releasing a semaphore can raise a [`AsyncSemaphoreError`](/api/chronos/asyncsync.html#AsyncSemaphoreError) and it would happen outside of our managed `try` block, we need to add this exception to the `raises` list for `check`.

```nim
{{#shiftinclude auto:../../../examples/http_client/chapter6/src/uptimemon.nim:check}}
```

In the `check` function for a URI sequence, we create a semaphore of the required capacity.

```nim
{{#shiftinclude auto:../../../examples/http_client/chapter6/src/uptimemon.nim:while_true}}
```

Instead of a one off launch, we do the checks in an infinite loop.

We've added an `echo` to denote the start of each cycle.

```nim
{{#shiftinclude auto:../../../examples/http_client/chapter6/src/uptimemon.nim:pass_semaphore}}
```

Then we pass the semaphore to `check` for each URI.

```nim
{{#shiftinclude auto:../../../examples/http_client/chapter6/src/uptimemon.nim:sleep}}
```

Finally, print the message to mark the end of a cycle and wait 10 seconds before the next one.

Run the program and you'll see an even flow of statuses in your terminal.

```admonish important
To stop the program, press Ctrl+C.
```

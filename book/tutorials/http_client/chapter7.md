.. title:: Scaling & Finishing Touches
.. importdoc:: ../../api/chronos/asyncsync

**Goal:** Learn how to use semaphores to control concurrency.

**Source code:** [chapter7/src/uptimemon.nim](https://github.com/status-im/nim-chronos/blob/master/examples/http_client/chapter7/src/uptimemon.nim)

Our app is almost ready to run on production and do regular background URI checks.

However, there's one issue we need to address before we can feed it tens of URIs and wrap it in a `while true`: we need to limit the number of simultaneous checks. If we don't do that, our app can potentially run out of file descriptors or choke the DNS resolver with 20+ requests.

Instead of simultaneusly launching checks for all URIs in the list, we'll run them in batches of 5, i.e. no more than 5 checks will run at any given moment, keeping resource usage low and under control.

To achieve that, we'll use a *semaphore*—an special object that a function must acquire to run and must release after it's finished. A semaphore can be acquired by a fixed number of function at any moment, and this is how it regulates concurrency.

Here's the code with a semaphore and an infinite loop added:

.. include:: ../../../examples/http_client/chapter7/src/uptimemon.nim
   :start-after: #ANCHOR: all
   :end-before: #ANCHOR_END: all
   :code:

Let's see what changed.

.. include:: ../../../examples/http_client/chapter7/src/uptimemon.nim
   :start-after: #ANCHOR: maxConcurrency
   :end-before: #ANCHOR_END: maxConcurrency
   :code:

We define a constant that would determine the capacity of our semaphore.

.. include:: ../../../examples/http_client/chapter7/src/uptimemon.nim
   :start-after: #ANCHOR: uris
   :end-before: #ANCHOR_END: uris
   :code:

We've added more URIs to the list to make batching effect visible.

.. include:: ../../../examples/http_client/chapter7/src/uptimemon.nim
   :start-after: #ANCHOR: semaphore
   :end-before: #ANCHOR_END: semaphore
   :code:

We've modified `check` function for a single URI so that it accepts a `semaphore` (of type [AsyncSemaphore]), waits to [acquire(AsyncSemaphore)] it, and [release(AsyncSemaphore)]s it at the end (we use `defer` to postpone the release).

With this short addition, we prevent `check` from running if the semaphore is full.

Because releasing a semaphore can raise a [AsyncSemaphoreError] and it would happen outside of our managed `try` block, we wrap the `release` call in its own `try..except` block to handle it gracefully and prevent it from bubbling up.

.. include:: ../../../examples/http_client/chapter7/src/uptimemon.nim
   :start-after: #ANCHOR: check
   :end-before: #ANCHOR_END: check
   :code:

In the `check` function for a URI sequence, we create a semaphore of the required capacity.

.. include:: ../../../examples/http_client/chapter7/src/uptimemon.nim
   :start-after: #ANCHOR: while_true
   :end-before: #ANCHOR_END: while_true
   :code:

Instead of a one-off launch, we do the checks in an infinite loop. We wrap the entire loop in a `try..finally` block to ensure the session is always closed when the program stops.

.. include:: ../../../examples/http_client/chapter7/src/uptimemon.nim
   :start-after: #ANCHOR: pass_semaphore
   :end-before: #ANCHOR_END: pass_semaphore
   :code:

Then we pass the semaphore to `check` for each URI using `mapIt`. We also add a `try..except CancelledError` block around `allFutures` to ensure that if the program is stopped (e.g. by pressing Ctrl+C), all pending requests are cancelled and cleaned up properly. Note that in this case, we `break` the loop to finish the execution gracefully.

We've added an `echo` to denote the start of each cycle.

.. include:: ../../../examples/http_client/chapter7/src/uptimemon.nim
   :start-after: #ANCHOR: sleep
   :end-before: #ANCHOR_END: sleep
   :code:

Finally, print the message to mark the end of a cycle and wait 10 seconds before the next one.

.. note::
   Even though we set the program to wait for 10 seconds before the next check loop, in reality the waiting time will be longer because there is some delay for the system to wake up and resume execution.

   This is called **drift**. For an uptime monitor, this isn't critical but there are cases where you would need to compensate for it.

Run the program and you'll see an even flow of statuses in your terminal.

.. important::
   To stop the program, press Ctrl+C.

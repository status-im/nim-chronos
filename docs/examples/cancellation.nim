## Simple cancellation example

import chronos

proc someTask() {.async.} = await sleepAsync(10.minutes)

proc cancellationExample() {.async.} =
  # Start a task but don't wait for it to finish
  let future = someTask()
  future.cancelSoon()
  # `cancelSoon` schedules but does not wait for the future to get cancelled -
  # it might still be pending here

  let future2 = someTask() # Start another task concurrently
  await future2.cancelAndWait()
  # Using `cancelAndWait`, we can be sure that `future2` is either
  # complete, failed or cancelled at this point. `future` could still be
  # pending!
  assert future2.finished()

waitFor(cancellationExample())

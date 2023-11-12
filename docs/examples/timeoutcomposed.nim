## Single timeout for several operations
import chronos

proc shortTask {.async.} =
  try:
    await sleepAsync(1.seconds)
  except CancelledError as exc:
    echo "Short task was cancelled!"
    raise exc # Propagate cancellation to the next operation

proc composedTimeout()  {.async.} =
  let
    # Common timout for several sub-tasks
    timeout = sleepAsync(10.seconds)

  while not timeout.finished():
    let task = shortTask() # Start a task but don't `await` it
    if (await race(task, timeout)) == task:
      echo "Ran one more task"
    else:
      # This cancellation may or may not happen as task might have finished
      # right at the timeout!
      task.cancelSoon()

waitFor composedTimeout()

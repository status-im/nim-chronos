## Simple timeouts
import chronos

proc longTask() {.async.} =
  try:
    await sleepAsync(10.minutes)
  except CancelledError as exc:
    echo "Long task was cancelled!"
    raise exc # Propagate cancellation to the next operation

proc simpleTimeout() {.async.} =
  let task = longTask() # Start a task but don't `await` it

  if not await task.withTimeout(1.seconds):
    echo "Timeout reached - withTimeout should have cancelled the task"
  else:
    echo "Task completed"

waitFor simpleTimeout()

## The peculiarities of `discard` in `async` procedures
import chronos

proc failingOperation() {.async.} =
  echo "Raising!"
  raise (ref ValueError)(msg: "My error")

proc myApp() {.async.} =
  # This style of discard causes the `ValueError` to be discarded, hiding the
  # failure of the operation - avoid!
  discard failingOperation()

  proc runAsTask(fut: Future[void]): Future[void] {.async: (raises: []).} =
    # runAsTask uses `raises: []` to ensure at compile-time that no exceptions
    # escape it!
    try:
      await fut
    except CatchableError as exc:
      echo "The task failed! ", exc.msg

  # asyncSpawn ensures that errors don't leak unnoticed from tasks without
  # blocking:
  asyncSpawn runAsTask(failingOperation())

  # If we didn't catch the exception with `runAsTask`, the program will crash:
  asyncSpawn failingOperation()

waitFor myApp()

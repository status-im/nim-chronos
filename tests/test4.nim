import ../asyncdispatch2

proc task() {.async.} =
  if true:
    raise newException(ValueError, "Test Error")

proc waitTask() {.async.} =
  await task()

when isMainModule:
  waitFor waitTask()

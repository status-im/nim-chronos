import asyncdispatch2

proc task() {.async.} =
  await sleepAsync(1000)

proc waitTask() {.async.} =
  echo await withTimeout(task(), 100)

when isMainModule:
  waitFor waitTask()

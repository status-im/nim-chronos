import asyncdispatch2

proc task() {.async.} =
  await sleepAsync(10)

when isMainModule:
  var counter = 0
  var f = task()
  while not f.finished:
    inc(counter)
    poll()

echo counter

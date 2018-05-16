import asyncdispatch2

proc testProc() {.async.} =
  for i in 1..1_000:
    await sleepAsync(1000)
    echo "Timeout event " & $i

proc callbackProc(udata: pointer) {.gcsafe.} =
  echo "Callback event"
  callSoon(callbackProc)

when isMainModule:
  discard getGlobalDispatcher()
  asyncCheck testProc()
  callSoon(callbackProc)
  for i in 1..100:
    echo "Iteration " & $i
    poll()

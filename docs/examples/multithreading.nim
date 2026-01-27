import std/[os]
import chronos
import chronos/threadsync

proc cleanupThread*() {.gcsafe, raises: [].}=
  {.cast(gcsafe).}:
    try:
      `=destroy`(getThreadDispatcher())
      when defined(gcOrc):
        GC_fullCollect()
    except Exception as e:
      echo "Exception during cleanup: ", e[]

proc processAsync() {.async.} =
  await sleepAsync(1000) # Waiting on an HTTP Request or the like
  echo "Done with async work"

proc threadProc(threadSignal: ThreadSignalPtr) {.thread.} =
  block:
    asyncSpawn processAsync() # Start some async work
    
    waitFor threadSignal.wait() # Do async work and then go to sleep until main thread wakes you up
  
  cleanupThread() # Clean up thread local variables, e.g. dispatcher

var thread: Thread[ThreadSignalPtr]
let signal = new(ThreadSignalPtr)[]

createThread(thread, threadProc, signal)
sleep(10)
discard signal.fireSync()

joinThread(thread)
discard signal.close()
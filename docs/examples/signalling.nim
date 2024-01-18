import chronos, chronos/threadsync
import os

type
  Context = object
    # Context allocated by `createShared` should contain no garbage-collected
    # types!
    signal: ThreadSignalPtr
    value: int

proc myThread(ctx: ptr Context) {.thread.} =
  echo "Doing some work in a thread"
  sleep(3000)
  ctx.value = 42
  echo "Done, firing the signal"
  discard ctx.signal.fireSync().expect("correctly initialized signal should not fail")

proc main() {.async.} =
  let
    signal = ThreadSignalPtr.new().expect("free file descriptor for signal")
    context = createShared(Context)
  context.signal = signal

  var thread: Thread[ptr Context]

  echo "Starting thread"
  createThread(thread, myThread, context)

  await signal.wait()

  echo "Work done: ", context.value

  joinThread(thread)

  signal.close().expect("closing once works")
  deallocShared(context)

waitFor main()

#                Chronos Test Suite
#            (c) Copyright 2023-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)
import std/[cpuinfo, math]
import ../chronos/unittest2/asynctests
import ../chronos/threadsync

when hasThreadSupport:
  type
    ThreadResult = object
      value: int

    ThreadResultPtr = ptr ThreadResult

    ThreadArg = object
      signal: ThreadSignalPtr
      retval: ThreadResultPtr
      index: int

    ThreadArg2 = object
      signal1: ThreadSignalPtr
      signal2: ThreadSignalPtr
      retval: ThreadResultPtr

    WaitSendKind {.pure.} = enum
      Sync, Async

suite "Asynchronous multi-threading sync primitives test suite":
  proc setResult(thr: ThreadResultPtr, value: int) =
    thr[].value = value

  proc new(t: typedesc[ThreadResultPtr], value: int = 0): ThreadResultPtr =
    var res = cast[ThreadResultPtr](allocShared0(sizeof(ThreadResult)))
    res[].value = value
    res

  proc free(thr: ThreadResultPtr) =
    doAssert(not(isNil(thr)))
    deallocShared(thr)

  let numProcs = countProcessors() * 2

  template threadSignalTest(sendFlag, waitFlag: WaitSendKind) =
    proc testSyncThread(arg: ThreadArg) {.thread.} =
      let res = waitSync(arg.signal, 1500.milliseconds)
      if res.isErr():
        arg.retval.setResult(1)
      else:
        if res.get():
          arg.retval.setResult(2)
        else:
          arg.retval.setResult(3)

    proc testAsyncThread(arg: ThreadArg) {.thread.} =
      proc testAsyncCode(arg: ThreadArg) {.async.} =
        try:
          await wait(arg.signal).wait(1500.milliseconds)
          arg.retval.setResult(2)
        except AsyncTimeoutError:
          arg.retval.setResult(3)
        except CatchableError:
          arg.retval.setResult(1)

      waitFor testAsyncCode(arg)

    let signal = ThreadSignalPtr.new().tryGet()
    var args: seq[ThreadArg]
    var threads = newSeq[Thread[ThreadArg]](numProcs)
    for i in 0 ..< numProcs:
      let
        res = ThreadResultPtr.new()
        arg = ThreadArg(signal: signal, retval: res, index: i)
      args.add(arg)
      case waitFlag
      of WaitSendKind.Sync:
        createThread(threads[i], testSyncThread, arg)
      of WaitSendKind.Async:
        createThread(threads[i], testAsyncThread, arg)

    await sleepAsync(500.milliseconds)
    case sendFlag
    of WaitSendKind.Sync:
      check signal.fireSync().isOk()
    of WaitSendKind.Async:
      await signal.fire()

    joinThreads(threads)

    var ncheck: array[3, int]
    for item in args:
      if item.retval[].value == 1:
        inc(ncheck[0])
      elif item.retval[].value == 2:
        inc(ncheck[1])
      elif item.retval[].value == 3:
        inc(ncheck[2])
      free(item.retval)
    check:
      signal.close().isOk()
      ncheck[0] == 0
      ncheck[1] == 1
      ncheck[2] == numProcs - 1

  template threadSignalTest2(testsCount: int,
                             sendFlag, waitFlag: WaitSendKind) =
    proc testSyncThread(arg: ThreadArg2) {.thread.} =
      for i in 0 ..< testsCount:
        block:
          let res = waitSync(arg.signal1, 1500.milliseconds)
          # echo "thread awaited signal1 [", res, "]"
          if res.isErr():
            arg.retval.setResult(-1)
            return
          if not(res.get()):
            arg.retval.setResult(-2)
            return

        block:
          let res = arg.signal2.fireSync()
          # echo "thread signaled signal2 [", res, "]"
          if res.isErr():
            arg.retval.setResult(-3)
            return

        arg.retval.setResult(i + 1)

    proc testAsyncThread(arg: ThreadArg2) {.thread.} =
      proc testAsyncCode(arg: ThreadArg2) {.async.} =
        for i in 0 ..< testsCount:
          try:
            await wait(arg.signal1).wait(1500.milliseconds)
          except AsyncTimeoutError:
            arg.retval.setResult(-2)
            return
          except AsyncError:
            arg.retval.setResult(-1)
            return
          except CatchableError:
            arg.retval.setResult(-3)
            return

          try:
            await arg.signal2.fire()
          except AsyncError:
            arg.retval.setResult(-4)
            return
          except CatchableError:
            arg.retval.setResult(-5)
            return

          arg.retval.setResult(i + 1)

      waitFor testAsyncCode(arg)

    let
      signal1 = ThreadSignalPtr.new().tryGet()
      signal2 = ThreadSignalPtr.new().tryGet()
      retval = ThreadResultPtr.new()
      arg = ThreadArg2(signal1: signal1, signal2: signal2, retval: retval)
    var thread: Thread[ThreadArg2]

    case waitFlag
    of WaitSendKind.Sync:
      createThread(thread, testSyncThread, arg)
    of WaitSendKind.Async:
      createThread(thread, testAsyncThread, arg)

    let start = Moment.now()
    for i in 0 ..< testsCount:
      case sendFlag
      of WaitSendKind.Sync:
        block:
          let res = signal1.fireSync()
          check res.isOk()
        block:
          let res = waitSync(arg.signal2, 1500.milliseconds)
          check:
            res.isOk()
            res.get() == true
      of WaitSendKind.Async:
        await arg.signal1.fire()
        await wait(arg.signal2).wait(1500.milliseconds)
    joinThreads(thread)
    let finish = Moment.now()
    let perf = (float64(nanoseconds(1.seconds)) /
      float64(nanoseconds(finish - start))) * float64(testsCount)
    echo "Switches tested: ", testsCount, ", elapsed time: ", (finish - start),
         ", performance = ", int(round(perf)), " switches/second"

    check:
      arg.retval[].value == testsCount

  asyncTest "ThreadSignal: Multiple [" & $numProcs &
            "] threads waiting test [sync -> sync]":
    when not(hasThreadSupport):
      skip()
    else:
      threadSignalTest(WaitSendKind.Sync, WaitSendKind.Sync)

  asyncTest "ThreadSignal: Multiple [" & $numProcs &
            "] threads waiting test [async -> async]":
    when not(hasThreadSupport):
      skip()
    else:
      threadSignalTest(WaitSendKind.Async, WaitSendKind.Async)

  asyncTest "ThreadSignal: Multiple [" & $numProcs &
            "] threads waiting test [async -> sync]":
    when not(hasThreadSupport):
      skip()
    else:
      threadSignalTest(WaitSendKind.Async, WaitSendKind.Sync)

  asyncTest "ThreadSignal: Multiple [" & $numProcs &
            "] threads waiting test [sync -> async]":
    when not(hasThreadSupport):
      skip()
    else:
      threadSignalTest(WaitSendKind.Sync, WaitSendKind.Async)

  asyncTest "ThreadSignal: Multiple thread switches test [sync -> sync]":
    when not(hasThreadSupport):
      skip()
    else:
      threadSignalTest2(10000, WaitSendKind.Sync, WaitSendKind.Sync)

  asyncTest "ThreadSignal: Multiple thread switches test [async -> async]":
    when not(hasThreadSupport):
      skip()
    else:
      threadSignalTest2(10000, WaitSendKind.Async, WaitSendKind.Async)

  asyncTest "ThreadSignal: Multiple thread switches test [sync -> async]":
    when not(hasThreadSupport):
      skip()
    else:
      threadSignalTest2(10000, WaitSendKind.Sync, WaitSendKind.Async)

  asyncTest "ThreadSignal: Multiple thread switches test [async -> sync]":
    when not(hasThreadSupport):
      skip()
    else:
      threadSignalTest2(10000, WaitSendKind.Async, WaitSendKind.Sync)

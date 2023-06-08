#                Chronos Test Suite
#            (c) Copyright 2023-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)
import std/cpuinfo
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

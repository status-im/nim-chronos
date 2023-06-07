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
      event: ThreadEventPtr
      retval: ThreadResultPtr
      index: int


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

  asyncTest "Multiple threads waiting":
    when not(hasThreadSupport):
      skip()
    else:
      proc testSyncThread(arg: ThreadArg) {.thread.} =
        echo "testSyncThread(", arg.index, ") started"
        let res = waitSync(arg.event, 10.seconds)
        if res.isErr():
          arg.retval.setResult(-1)
          echo "testSyncThread(", arg.index, ") waiting completed with ERROR"
        else:
          echo "testSyncThread(", arg.index, ") waiting completed"

      let numProcs = countProcessors() * 2
      let event = ThreadEventPtr.new().tryGet()
      var args: seq[ThreadArg]
      var threads = newSeq[Thread[ThreadArg]](numProcs)
      for i in 0 ..< numProcs:
        let
          res = ThreadResultPtr.new()
          arg = ThreadArg(event: event, retval: res, index: i)
        args.add(arg)
        createThread(threads[i], testSyncThread, arg)

      await sleepAsync(2.seconds)
      check event.fireSync().isOk()
      joinThreads(threads)

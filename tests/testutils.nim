#                Chronos Test Suite
#            (c) Copyright 2020-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)
import unittest2
import ../chronos, ../chronos/config
import std/[tables, os] 

{.used.}

when chronosFuturesInstrumentation:
  import std/[tables, macros]
  import ../chronos/timer

suite "Asynchronous utilities test suite":
  when chronosFutureTracking:
    proc getCount(): uint =
      # This procedure counts number of Future[T] in double-linked list via list
      # iteration.
      var res = 0'u
      for item in pendingFutures():
        inc(res)
      res

  test "Future clean and leaks test":
    when chronosFutureTracking:
      if pendingFuturesCount(WithoutCompleted) == 0'u:
        if pendingFuturesCount(OnlyCompleted) > 0'u:
          poll()
        check pendingFuturesCount() == 0'u
      else:
        echo dumpPendingFutures()
        check false
    else:
      skip()

  test "FutureList basics test":
    when chronosFutureTracking:
      var fut1 = newFuture[void]()
      check:
        getCount() == 1'u
        pendingFuturesCount() == 1'u
      var fut2 = newFuture[void]()
      check:
        getCount() == 2'u
        pendingFuturesCount() == 2'u
      var fut3 = newFuture[void]()
      check:
        getCount() == 3'u
        pendingFuturesCount() == 3'u
      fut1.complete()
      poll()
      check:
        getCount() == 2'u
        pendingFuturesCount() == 2'u
      fut2.fail(newException(ValueError, ""))
      poll()
      check:
        getCount() == 1'u
        pendingFuturesCount() == 1'u
      fut3.cancel()
      poll()
      check:
        getCount() == 0'u
        pendingFuturesCount() == 0'u
    else:
      skip()

  test "FutureList async procedure test":
    when chronosFutureTracking:
      proc simpleProc() {.async.} =
        await sleepAsync(10.milliseconds)

      var fut = simpleProc()
      check:
        getCount() == 2'u
        pendingFuturesCount() == 2'u

      waitFor fut
      check:
        getCount() == 1'u
        pendingFuturesCount() == 1'u

      poll()
      check:
        getCount() == 0'u
        pendingFuturesCount() == 0'u
    else:
      skip()


  test "Example of using Future hooks to gather metrics":

    when chronosFuturesInstrumentation:

      type
        CallbackDurationMetric = object
          ## Holds average timing information for a given closure
          closureLoc*: ptr SrcLoc
          totalDuration*: Duration
          minSingleTime*: Duration
          maxSingleTime*: Duration
          count*: int64

      var callbackDurations: Table[ptr SrcLoc, CallbackDurationMetric]

      # if not callbackDurations.hasKey(fut.location[Create])

      proc setFutureDuration(fut: FutureBase, internalDuration: Duration) {.raises: [].} =
        ## used for setting the duration
        let loc = fut.internalLocation[Create]
        discard callbackDurations.hasKeyOrPut(loc, CallbackDurationMetric(minSingleTime: InfiniteDuration))
        callbackDurations.withValue(loc, metric):
          metric.totalDuration += internalDuration
          metric.count.inc
          metric.minSingleTime = min(metric.minSingleTime, internalDuration)
          metric.maxSingleTime = max(metric.maxSingleTime, internalDuration)
          # handle overflow
          if metric.count == metric.count.typeof.high:
            metric.totalDuration = ZeroDuration
            metric.count = 0

      template instrumentAsync() =
        var start = Moment.now()
        var internalDuration: Duration

        echo "chronosInternalRetFuture: ", chronosInternalRetFuture.id()
        chronosInternalRetFuture.onFutureRunning =
          proc (f: FutureBase) =
            echo "start future"
            start = Moment.now()
        chronosInternalRetFuture.onFuturePause =
          proc (f, child: FutureBase) =
            echo "pause future"
            # echo "future child: ", repr child
            internalDuration += Moment.now() - start
        chronosInternalRetFuture.onFutureStop =
          proc (f: FutureBase) =
            echo "end future"
            internalDuration += Moment.now() - start
            f.setFutureDuration(internalDuration)

      macro instrument(prc: untyped) =
        echo "intrument: ", prc.treeRepr
        let callSetup = nnkCall.newTree(ident "instrumentAsync")
        prc.body.insert(0, callSetup)
        return prc

      proc simpleAsync1() {.instrument, async.} =
        for i in 0..1:
          await sleepAsync(10.milliseconds)
          os.sleep(50)
        
      waitFor(simpleAsync1())

      let metrics = callbackDurations
      echo "metrics:"
      for (k,v) in metrics.pairs():
        let count = v.count
        let totalDuration = v.totalDuration
        if count > 0:
          echo ""
          echo "metric: ", $k
          echo "count: ", count
          echo "total: ", totalDuration
          echo "avg: ", totalDuration div count
        if k.procedure == "simpleAsync1":
          check v.totalDuration <= 120.milliseconds()
          check v.totalDuration >= 100.milliseconds()
      echo ""

    else:
      skip()

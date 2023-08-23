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
  import std/[tables, macros, options]
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
          created*: Moment
          start*: Option[Moment]
          duration*: Duration
          totalExecTime*: Duration
          totalWallTime*: Duration
          minSingleTime*: Duration
          maxSingleTime*: Duration
          count*: int64

      var
        callbackDurations: Table[ptr SrcLoc, CallbackDurationMetric]

      proc setFutureCreate(fut: FutureBase) {.raises: [].} =
        ## used for setting the duration
        let loc = fut.internalLocation[Create]
        discard callbackDurations.hasKeyOrPut(loc, CallbackDurationMetric(minSingleTime: InfiniteDuration))
        callbackDurations.withValue(loc, metric):
          metric.created = Moment.now()
          echo loc, " future create "

      proc setFutureStart(fut: FutureBase) {.raises: [].} =
        ## used for setting the duration
        let loc = fut.internalLocation[Create]
        discard callbackDurations.hasKeyOrPut(loc, CallbackDurationMetric(minSingleTime: InfiniteDuration))
        callbackDurations.withValue(loc, metric):
          metric.start = some Moment.now()
          echo loc, " future start "

      proc setFuturePause(fut: FutureBase) {.raises: [].} =
        ## used for setting the duration
        let loc = fut.internalLocation[Create]
        assert callbackDurations.hasKey(loc)
        callbackDurations.withValue(loc, metric):
          if metric.start.isSome:
            metric.duration += Moment.now() - metric.start.get()
            metric.start = none Moment
          echo loc, " future pause "

      proc setFutureDuration(fut: FutureBase) {.raises: [].} =
        ## used for setting the duration
        let loc = fut.internalLocation[Create]
        # assert  "set duration: " & $loc
        callbackDurations.withValue(loc, metric):
          echo loc, " set duration: ", callbackDurations.hasKey(loc)
          metric.totalExecTime += metric.duration
          metric.totalWallTime += Moment.now() - metric.created
          metric.count.inc
          metric.minSingleTime = min(metric.minSingleTime, metric.duration)
          metric.maxSingleTime = max(metric.maxSingleTime, metric.duration)
          # handle overflow
          if metric.count == metric.count.typeof.high:
            metric.totalExecTime = ZeroDuration
            metric.count = 0

      onFutureCreate =
        proc (f: FutureBase) =
          f.setFutureCreate()
      onFutureRunning =
        proc (f: FutureBase) =
          f.setFutureStart()
      onFuturePause =
        proc (f, child: FutureBase) =
          f.setFuturePause()
      onFutureStop =
        proc (f: FutureBase) =
          f.setFuturePause()
          f.setFutureDuration()

      proc simpleAsync1() {.async.} =
        for i in 0..1:
          await sleepAsync(40.milliseconds)
          echo "sleep..."
          os.sleep(50)
        
      waitFor(simpleAsync1())

      let metrics = callbackDurations
      echo "\n=== metrics ==="
      for (k,v) in metrics.pairs():
        let count = v.count
        let totalDuration = v.totalExecTime
        if count > 0:
          echo ""
          echo "metric: ", $k
          echo "count: ", count
          echo "totalExec: ", totalDuration, " avg: ", totalDuration div count
          echo "wallTime: ", v.totalWallTime, " avg: ", v.totalWallTime div count
        if k.procedure == "simpleAsync1":
          check v.totalExecTime <= 120.milliseconds()
          check v.totalExecTime >= 100.milliseconds()
          # check v.totalWallTime <= 120.milliseconds()
          # check v.totalWallTime >= 100.milliseconds()
      echo ""

    else:
      skip()

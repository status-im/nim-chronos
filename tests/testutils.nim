#                Chronos Test Suite
#            (c) Copyright 2020-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)
import unittest2
import ../chronos

when defined(nimHasUsed): {.used.}

suite "Asynchronous utilities test suite":
  when defined(chronosFutureTracking):
    proc getCount(): int =
      # This procedure counts number of Future[T] in double-linked list via list
      # iteration.
      result = 0
      for item in pendingFutures():
        inc(result)

  test "Future clean and leaks test":
    when defined(chronosFutureTracking):
      if pendingFuturesCount(WithoutFinished) == 0:
        if pendingFuturesCount(OnlyFinished) > 0:
          poll()
        check pendingFuturesCount() == 0
      else:
        echo dumpPendingFutures()
        check false
    else:
      skip()

  test "FutureList basics test":
    when defined(chronosFutureTracking):
      var fut1 = newFuture[void]()
      check:
        getCount() == 1
        pendingFuturesCount() == 1
      var fut2 = newFuture[void]()
      check:
        getCount() == 2
        pendingFuturesCount() == 2
      var fut3 = newFuture[void]()
      check:
        getCount() == 3
        pendingFuturesCount() == 3
      fut1.complete()
      poll()
      check:
        getCount() == 2
        pendingFuturesCount() == 2
      fut2.fail(newException(ValueError, ""))
      poll()
      check:
        getCount() == 1
        pendingFuturesCount() == 1
      fut3.cancel()
      poll()
      check:
        getCount() == 0
        pendingFuturesCount() == 0
    else:
      skip()

  test "FutureList async procedure test":
    when defined(chronosFutureTracking):
      proc simpleProc() {.async.} =
        await sleepAsync(10.milliseconds)

      var fut = simpleProc()
      check:
        getCount() == 2
        pendingFuturesCount() == 2

      waitFor fut
      check:
        getCount() == 1
        pendingFuturesCount() == 1

      poll()
      check:
        getCount() == 0
        pendingFuturesCount() == 0
    else:
      skip()

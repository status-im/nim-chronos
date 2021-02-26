#                Chronos Test Suite
#            (c) Copyright 2018-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)
import unittest
import ../chronos

when defined(nimHasUsed): {.used.}

suite "Future[T] behavior test suite":
  proc testFuture1(): Future[int] {.async.} =
    await sleepAsync(0.milliseconds)

  proc testFuture2(): Future[int] {.async.} =
    return 1

  proc testFuture3(): Future[int] {.async.} =
    result = await testFuture2()

  proc testFuture100(): Future[int] {.async.} =
    await sleepAsync(100.milliseconds)

  proc testFuture4(): Future[int] {.async.} =
    ## Test for not immediately completed future and timeout = -1
    result = 0
    try:
      discard await wait(testFuture1(), InfiniteDuration)
      result = 1
    except:
      result = 0

    if result == 0:
      return -1

    ## Test for immediately completed future and timeout = -1
    result = 0
    try:
      discard await wait(testFuture2(), InfiniteDuration)
      result = 2
    except:
      result = 0

    if result == 0:
      return -2

    ## Test for not immediately completed future and timeout = 0
    result = 0
    try:
      discard await wait(testFuture1(), 0.milliseconds)
    except AsyncTimeoutError:
      result = 3

    if result == 0:
      return -3

    ## Test for immediately completed future and timeout = 0
    result = 0
    try:
      discard await wait(testFuture2(), 0.milliseconds)
      result = 4
    except:
      result = 0

    if result == 0:
      return -4

    ## Test for future which cannot be completed in timeout period
    result = 0
    try:
      discard await wait(testFuture100(), 50.milliseconds)
    except AsyncTimeoutError:
      result = 5

    if result == 0:
      return -5

    ## Test for future which will be completed before timeout exceeded.
    try:
      discard await wait(testFuture100(), 500.milliseconds)
      result = 6
    except:
      result = -6

  proc test1(): bool =
    var fut = testFuture1()
    poll()
    poll()
    if not fut.finished:
      poll()
    result = fut.finished

  proc test2(): bool =
    var fut = testFuture3()
    result = fut.finished

  proc test3(): string =
    var testResult = ""
    var fut = testFuture1()
    fut.addCallback proc(udata: pointer) =
      testResult &= "1"
    fut.addCallback proc(udata: pointer) =
      testResult &= "2"
    fut.addCallback proc(udata: pointer) =
      testResult &= "3"
    fut.addCallback proc(udata: pointer) =
      testResult &= "4"
    fut.addCallback proc(udata: pointer) =
      testResult &= "5"
    discard waitFor(fut)
    poll()
    if fut.finished:
      result = testResult

  proc test4(): string =
    var testResult = ""
    var fut = testFuture1()
    proc cb1(udata: pointer) =
      testResult &= "1"
    proc cb2(udata: pointer) =
      testResult &= "2"
    proc cb3(udata: pointer) =
      testResult &= "3"
    proc cb4(udata: pointer) =
      testResult &= "4"
    proc cb5(udata: pointer) =
      testResult &= "5"
    fut.addCallback cb1
    fut.addCallback cb2
    fut.addCallback cb3
    fut.addCallback cb4
    fut.addCallback cb5
    fut.removeCallback cb3
    discard waitFor(fut)
    poll()
    if fut.finished:
      result = testResult

  proc test5(): int =
    result = waitFor(testFuture4())

  proc testAsyncDiscard(): int =
    var completedFutures = 0

    proc client1() {.async.} =
      await sleepAsync(100.milliseconds)
      inc(completedFutures)

    proc client2() {.async.} =
      await sleepAsync(200.milliseconds)
      inc(completedFutures)

    proc client3() {.async.} =
      await sleepAsync(300.milliseconds)
      inc(completedFutures)

    proc client4() {.async.} =
      await sleepAsync(400.milliseconds)
      inc(completedFutures)

    proc client5() {.async.} =
      await sleepAsync(500.milliseconds)
      inc(completedFutures)

    proc client1f() {.async.} =
      await sleepAsync(100.milliseconds)
      inc(completedFutures)
      if true:
        raise newException(ValueError, "")

    proc client2f() {.async.} =
      await sleepAsync(200.milliseconds)
      inc(completedFutures)
      if true:
        raise newException(ValueError, "")

    proc client3f() {.async.} =
      await sleepAsync(300.milliseconds)
      inc(completedFutures)
      if true:
        raise newException(ValueError, "")

    proc client4f() {.async.} =
      await sleepAsync(400.milliseconds)
      inc(completedFutures)
      if true:
        raise newException(ValueError, "")

    proc client5f() {.async.} =
      await sleepAsync(500.milliseconds)
      inc(completedFutures)
      if true:
        raise newException(ValueError, "")

    discard client1()
    discard client1f()
    discard client2()
    discard client2f()
    discard client3()
    discard client3f()
    discard client4()
    discard client4f()
    discard client5()
    discard client5f()

    waitFor(sleepAsync(2000.milliseconds))
    result = completedFutures

  proc testAllFuturesZero(): bool =
    var tseq = newSeq[Future[int]]()
    var fut = allFutures(tseq)
    result = fut.finished

  proc testAllFuturesVarargs(): int =
    var completedFutures = 0

    proc vlient1() {.async.} =
      await sleepAsync(100.milliseconds)
      inc(completedFutures)

    proc vlient2() {.async.} =
      await sleepAsync(200.milliseconds)
      inc(completedFutures)

    proc vlient3() {.async.} =
      await sleepAsync(300.milliseconds)
      inc(completedFutures)

    proc vlient4() {.async.} =
      await sleepAsync(400.milliseconds)
      inc(completedFutures)

    proc vlient5() {.async.} =
      await sleepAsync(500.milliseconds)
      inc(completedFutures)

    proc vlient1f() {.async.} =
      await sleepAsync(100.milliseconds)
      inc(completedFutures)
      if true:
        raise newException(ValueError, "")

    proc vlient2f() {.async.} =
      await sleepAsync(100.milliseconds)
      inc(completedFutures)
      if true:
        raise newException(ValueError, "")

    proc vlient3f() {.async.} =
      await sleepAsync(100.milliseconds)
      inc(completedFutures)
      if true:
        raise newException(ValueError, "")

    proc vlient4f() {.async.} =
      await sleepAsync(100.milliseconds)
      inc(completedFutures)
      if true:
        raise newException(ValueError, "")

    proc vlient5f() {.async.} =
      await sleepAsync(100.milliseconds)
      inc(completedFutures)
      if true:
        raise newException(ValueError, "")

    proc client1(): Future[int] {.async.} =
      await sleepAsync(100.milliseconds)
      inc(completedFutures)
      result = 1

    proc client2(): Future[int] {.async.} =
      await sleepAsync(200.milliseconds)
      inc(completedFutures)
      result = 1

    proc client3(): Future[int] {.async.} =
      await sleepAsync(300.milliseconds)
      inc(completedFutures)
      result = 1

    proc client4(): Future[int] {.async.} =
      await sleepAsync(400.milliseconds)
      inc(completedFutures)
      result = 1

    proc client5(): Future[int] {.async.} =
      await sleepAsync(500.milliseconds)
      inc(completedFutures)
      result = 1

    proc client1f(): Future[int] {.async.} =
      await sleepAsync(100.milliseconds)
      inc(completedFutures)
      if true:
        raise newException(ValueError, "")

    proc client2f(): Future[int] {.async.} =
      await sleepAsync(200.milliseconds)
      inc(completedFutures)
      if true:
        raise newException(ValueError, "")

    proc client3f(): Future[int] {.async.} =
      await sleepAsync(300.milliseconds)
      inc(completedFutures)
      if true:
        raise newException(ValueError, "")

    proc client4f(): Future[int] {.async.} =
      await sleepAsync(400.milliseconds)
      inc(completedFutures)
      if true:
        raise newException(ValueError, "")

    proc client5f(): Future[int] {.async.} =
      await sleepAsync(500.milliseconds)
      inc(completedFutures)
      if true:
        raise newException(ValueError, "")

    waitFor(allFutures(vlient1(), vlient2(), vlient3(), vlient4(), vlient5()))
    # 5 completed futures = 5
    result += completedFutures

    completedFutures = 0
    waitFor(allFutures(vlient1(), vlient1f(),
                       vlient2(), vlient2f(),
                       vlient3(), vlient3f(),
                       vlient4(), vlient4f(),
                       vlient5(), vlient5f()))
    # 10 completed futures = 10
    result += completedFutures

    completedFutures = 0
    waitFor(allFutures(client1(), client2(), client3(), client4(), client5()))
    # 5 completed futures
    result += completedFutures

    completedFutures = 0
    waitFor(allFutures(client1(), client1f(),
                       client2(), client2f(),
                       client3(), client3f(),
                       client4(), client4f(),
                       client5(), client5f()))
    # 10 completed futures = 10
    result += completedFutures

  proc testAllFuturesSeq(): int =
    var completedFutures = 0
    var vfutures = newSeq[Future[void]]()
    var nfutures = newSeq[Future[int]]()

    proc vlient1() {.async.} =
      await sleepAsync(100.milliseconds)
      inc(completedFutures)

    proc vlient2() {.async.} =
      await sleepAsync(200.milliseconds)
      inc(completedFutures)

    proc vlient3() {.async.} =
      await sleepAsync(300.milliseconds)
      inc(completedFutures)

    proc vlient4() {.async.} =
      await sleepAsync(400.milliseconds)
      inc(completedFutures)

    proc vlient5() {.async.} =
      await sleepAsync(500.milliseconds)
      inc(completedFutures)

    proc vlient1f() {.async.} =
      await sleepAsync(100.milliseconds)
      inc(completedFutures)
      if true:
        raise newException(ValueError, "")

    proc vlient2f() {.async.} =
      await sleepAsync(100.milliseconds)
      inc(completedFutures)
      if true:
        raise newException(ValueError, "")

    proc vlient3f() {.async.} =
      await sleepAsync(100.milliseconds)
      inc(completedFutures)
      if true:
        raise newException(ValueError, "")

    proc vlient4f() {.async.} =
      await sleepAsync(100.milliseconds)
      inc(completedFutures)
      if true:
        raise newException(ValueError, "")

    proc vlient5f() {.async.} =
      await sleepAsync(100.milliseconds)
      inc(completedFutures)
      if true:
        raise newException(ValueError, "")

    proc client1(): Future[int] {.async.} =
      await sleepAsync(100.milliseconds)
      inc(completedFutures)
      result = 1

    proc client2(): Future[int] {.async.} =
      await sleepAsync(200.milliseconds)
      inc(completedFutures)
      result = 1

    proc client3(): Future[int] {.async.} =
      await sleepAsync(300.milliseconds)
      inc(completedFutures)
      result = 1

    proc client4(): Future[int] {.async.} =
      await sleepAsync(400.milliseconds)
      inc(completedFutures)
      result = 1

    proc client5(): Future[int] {.async.} =
      await sleepAsync(500.milliseconds)
      inc(completedFutures)
      result = 1

    proc client1f(): Future[int] {.async.} =
      await sleepAsync(100.milliseconds)
      inc(completedFutures)
      if true:
        raise newException(ValueError, "")

    proc client2f(): Future[int] {.async.} =
      await sleepAsync(200.milliseconds)
      inc(completedFutures)
      if true:
        raise newException(ValueError, "")

    proc client3f(): Future[int] {.async.} =
      await sleepAsync(300.milliseconds)
      inc(completedFutures)
      if true:
        raise newException(ValueError, "")

    proc client4f(): Future[int] {.async.} =
      await sleepAsync(400.milliseconds)
      inc(completedFutures)
      if true:
        raise newException(ValueError, "")

    proc client5f(): Future[int] {.async.} =
      await sleepAsync(500.milliseconds)
      inc(completedFutures)
      if true:
        raise newException(ValueError, "")

    vfutures.setLen(0)
    for i in 0..<10:
      vfutures.add(vlient1())
      vfutures.add(vlient2())
      vfutures.add(vlient3())
      vfutures.add(vlient4())
      vfutures.add(vlient5())

    waitFor(allFutures(vfutures))
    # 5 * 10 completed futures = 50
    result += completedFutures

    completedFutures = 0
    vfutures.setLen(0)
    for i in 0..<10:
      vfutures.add(vlient1())
      vfutures.add(vlient1f())
      vfutures.add(vlient2())
      vfutures.add(vlient2f())
      vfutures.add(vlient3())
      vfutures.add(vlient3f())
      vfutures.add(vlient4())
      vfutures.add(vlient4f())
      vfutures.add(vlient5())
      vfutures.add(vlient5f())

    waitFor(allFutures(vfutures))
    # 10 * 10 completed futures = 100
    result += completedFutures

    completedFutures = 0
    nfutures.setLen(0)
    for i in 0..<10:
      nfutures.add(client1())
      nfutures.add(client2())
      nfutures.add(client3())
      nfutures.add(client4())
      nfutures.add(client5())

    waitFor(allFutures(nfutures))
    # 5 * 10 completed futures = 50
    result += completedFutures

    completedFutures = 0
    nfutures.setLen(0)
    for i in 0..<10:
      nfutures.add(client1())
      nfutures.add(client1f())
      nfutures.add(client2())
      nfutures.add(client2f())
      nfutures.add(client3())
      nfutures.add(client3f())
      nfutures.add(client4())
      nfutures.add(client4f())
      nfutures.add(client5())
      nfutures.add(client5f())

    waitFor(allFutures(nfutures))

    # 10 * 10 completed futures = 100
    result += completedFutures

  proc testAllCompleted(operation: int): bool =
    proc client1(): Future[int] {.async.} =
      result = 1

    proc client2(): Future[int] {.async.} =
      if true:
        raise newException(ValueError, "")

    if operation == 1:
      var fut = allFutures(client1(), client2())
      result = fut.finished() and not(fut.failed())
    elif operation == 2:
      var fut = allFinished(client1(), client2())
      result = fut.finished() and not(fut.failed()) and (len(fut.read()) == 2)

  proc testOneZero(): bool =
    var tseq = newSeq[Future[int]]()
    var fut = one(tseq)
    result = fut.finished and fut.failed

  proc testOneVarargs(): bool =
    proc vlient1() {.async.} =
      await sleepAsync(100.milliseconds)

    proc vlient2() {.async.} =
      await sleepAsync(200.milliseconds)

    proc vlient3() {.async.} =
      await sleepAsync(300.milliseconds)

    proc client1(): Future[int] {.async.} =
      await sleepAsync(100.milliseconds)
      result = 10

    proc client2(): Future[int] {.async.} =
      await sleepAsync(200.milliseconds)
      result = 20

    proc client3(): Future[int] {.async.} =
      await sleepAsync(300.milliseconds)
      result = 30

    var fut11 = vlient1()
    var fut12 = vlient2()
    var fut13 = vlient3()
    var res1 = waitFor(one(fut11, fut12, fut13))

    var fut21 = vlient2()
    var fut22 = vlient1()
    var fut23 = vlient3()
    var res2 = waitFor(one(fut21, fut22, fut23))

    var fut31 = vlient3()
    var fut32 = vlient2()
    var fut33 = vlient1()
    var res3 = waitFor(one(fut31, fut32, fut33))

    if fut11 != res1 or fut22 != res2 or fut33 != res3:
      return false

    var cut11 = client1()
    var cut12 = client2()
    var cut13 = client3()
    var res4 = waitFor(one(cut11, cut12, cut13))

    var cut21 = client2()
    var cut22 = client1()
    var cut23 = client3()
    var res5 = waitFor(one(cut21, cut22, cut23))

    var cut31 = client3()
    var cut32 = client2()
    var cut33 = client1()
    var res6 = waitFor(one(cut31, cut32, cut33))

    if cut11 != res4 or cut22 != res5 or cut33 != res6:
      return false

    result = true

  proc testOneSeq(): bool =
    proc vlient1() {.async.} =
      await sleepAsync(100.milliseconds)

    proc vlient2() {.async.} =
      await sleepAsync(200.milliseconds)

    proc vlient3() {.async.} =
      await sleepAsync(300.milliseconds)

    proc client1(): Future[int] {.async.} =
      await sleepAsync(100.milliseconds)
      result = 10

    proc client2(): Future[int] {.async.} =
      await sleepAsync(200.milliseconds)
      result = 20

    proc client3(): Future[int] {.async.} =
      await sleepAsync(300.milliseconds)
      result = 30

    var v10 = vlient1()
    var v11 = vlient2()
    var v12 = vlient3()
    var res1 = waitFor(one(@[v10, v11, v12]))

    var v20 = vlient2()
    var v21 = vlient1()
    var v22 = vlient3()
    var res2 = waitFor(one(@[v20, v21, v22]))

    var v30 = vlient3()
    var v31 = vlient2()
    var v32 = vlient1()
    var res3 = waitFor(one(@[v30, v31, v32]))

    if res1 != v10 or res2 != v21 or res3 != v32:
      return false

    var c10 = client1()
    var c11 = client2()
    var c12 = client3()
    var res4 = waitFor(one(@[c10, c11, c12]))

    var c20 = client2()
    var c21 = client1()
    var c22 = client3()
    var res5 = waitFor(one(@[c20, c21, c22]))

    var c30 = client3()
    var c31 = client2()
    var c32 = client1()
    var res6 = waitFor(one(@[c30, c31, c32]))

    if res4 != c10 or res5 != c21 or res6 != c32:
      return false

    result = true

  proc testOneCompleted(): bool =
    proc client1(): Future[int] {.async.} =
      result = 1

    proc client2(): Future[int] {.async.} =
      if true:
        raise newException(ValueError, "")

    proc client3(): Future[int] {.async.} =
      await sleepAsync(100.milliseconds)
      result = 3

    var f10 = client1()
    var f20 = client2()
    var f30 = client3()
    var fut1 = one(f30, f10, f20)
    var f11 = client1()
    var f21 = client2()
    var f31 = client3()
    var fut2 = one(f31, f21, f11)

    result = fut1.finished() and not(fut1.failed()) and fut1.read() == f10 and
             fut2.finished() and not(fut2.failed()) and fut2.read() == f21

  proc waitForNeLocal[T](fut: Future[T]): Future[T] =
    ## **Blocks** the current thread until the specified future completes.
    while not(fut.finished()):
      poll()
    result = fut

  proc testOr(): bool =

    proc client1() {.async.} =
      await sleepAsync(200.milliseconds)

    proc client2() {.async.} =
      await sleepAsync(300.milliseconds)

    proc client3() {.async.} =
      await sleepAsync(100.milliseconds)
      if true:
        raise newException(ValueError, "")

    proc client4() {.async.} =
      await sleepAsync(400.milliseconds)
      if true:
        raise newException(KeyError, "")

    var f1 = waitForNeLocal(client1() or client2())
    var f2 = waitForNeLocal(client2() or client1())
    var f3 = waitForNeLocal(client1() or client4())
    var f4 = waitForNeLocal(client2() or client4())
    var f5 = waitForNeLocal(client1() or client3())
    var f6 = waitForNeLocal(client3() or client1())
    var f7 = waitForNeLocal(client2() or client4())
    var f8 = waitForNeLocal(client4() or client2())
    var f9 = waitForNeLocal(client3() or client4())
    var f10 = waitForNeLocal(client4() or client3())

    result = (f1.finished() and not(f1.failed())) and
             (f2.finished() and not(f2.failed())) and
             (f3.finished() and not(f3.failed())) and
             (f4.finished() and not(f4.failed())) and
             (f5.finished() and f5.failed()) and
             (f6.finished() and f6.failed()) and
             (f7.finished() and not(f7.failed())) and
             (f8.finished() and not(f8.failed())) and
             (f9.finished() and f9.failed()) and
             (f10.finished() and f10.failed())

  proc testOrCompleted(): bool =
    proc client1(): Future[int] {.async.} =
      result = 1
    proc client2(): Future[int] {.async.} =
      if true:
        raise newException(ValueError, "")
    proc client3(): Future[int] {.async.} =
      await sleepAsync(100.milliseconds)
      result = 3

    var f1 = client1() or client2()
    var f2 = client1() or client3()
    var f3 = client2() or client3()
    var f4 = client2() or client1()
    var f5 = client3() or client1()
    var f6 = client3() or client2()

    result = (f1.finished() and not(f1.failed())) and
             (f2.finished() and not(f2.failed())) and
             (f3.finished() and f3.failed()) and
             (f4.finished() and f4.failed()) and
             (f5.finished() and not(f5.failed())) and
             (f6.finished() and f6.failed())

  proc testCancelIter(): bool =
    var completed = 0

    proc client1() {.async.} =
      await sleepAsync(1.seconds)
      inc(completed)

    proc client2() {.async.} =
      await client1()
      inc(completed)

    proc client3() {.async.} =
      await client2()
      inc(completed)

    proc client4() {.async.} =
      await client3()
      inc(completed)

    var fut = client4()
    fut.cancel()

    # Future must not be cancelled immediately, because it has many nested
    # futures.
    if fut.cancelled():
      return false

    try:
      waitFor fut
      result = false
    except CancelledError:
      if completed == 0:
        result = true
      else:
        result = false

  proc testCancelAndWait(): bool =
    var completed = 0

    proc client1() {.async.} =
      await sleepAsync(1.seconds)
      inc(completed)

    proc client2() {.async.} =
      await client1()
      inc(completed)

    proc client3() {.async.} =
      await client2()
      inc(completed)

    proc client4() {.async.} =
      await client3()
      inc(completed)

    var fut = client4()
    waitFor cancelAndWait(fut)
    if not(fut.cancelled()):
      return false
    return true

  proc testBreakCancellation(): bool =
    var completed = 0

    proc client1() {.async.} =
      await sleepAsync(1.seconds)
      inc(completed)

    proc client2() {.async.} =
      try:
        await client1()
      except CancelledError:
        discard
      inc(completed)

    var fut1 = client2()
    var fut2 = client2()
    fut1.cancel()
    waitFor fut1
    waitFor cancelAndWait(fut2)

    if fut1.cancelled():
      return false
    if fut2.cancelled():
      return false

    if completed != 2:
      return false

    return true

  proc testCancelCallback(): bool =
    var completed = 0
    var cancelled = 0

    proc client1(duration: Duration): Future[void] =
      ## Suspends the execution of the current async procedure for the next
      ## ``duration`` time.
      var retFuture = newFuture[void]()
      let moment = Moment.fromNow(duration)

      proc completion(data: pointer) {.gcsafe.} =
        inc(completed)
        if not(retFuture.finished()):
          retFuture.complete()

      proc cancel(udata: pointer) {.gcsafe.} =
        inc(cancelled)
        if not(retFuture.finished()):
          removeTimer(moment, completion, cast[pointer](retFuture))

      retFuture.cancelCallback = cancel
      discard setTimer(moment, completion, cast[pointer](retFuture))
      return retFuture

    var fut = client1(100.milliseconds)
    fut.cancel()
    waitFor(sleepAsync(500.milliseconds))

    if not(fut.cancelled()):
      return false
    if (completed != 0) and (cancelled != 1):
      return false
    return true

  proc testWaitAsync(): Future[bool] {.async.} =
    var neverFlag1, neverFlag2, neverFlag3: bool
    var waitProc1, waitProc2: bool
    proc neverEndingProc(): Future[void] =
      var res = newFuture[void]()
      proc continuation(udata: pointer) {.gcsafe.} =
        neverFlag2 = true
      proc cancellation(udata: pointer) {.gcsafe.} =
        neverFlag3 = true
      res.addCallback(continuation)
      res.cancelCallback = cancellation
      result = res
      neverFlag1 = true

    proc waitProc() {.async.} =
      try:
        await wait(neverEndingProc(), 100.milliseconds)
      except CancelledError:
        waitProc1 = true
      finally:
        waitProc2 = true

    var fut = waitProc()
    await cancelAndWait(fut)
    result = (fut.state == FutureState.Finished) and
             neverFlag1 and neverFlag2 and neverFlag3 and
             waitProc1 and waitProc2

  proc testWithTimeoutAsync(): Future[bool] {.async.} =
    var neverFlag1, neverFlag2, neverFlag3: bool
    var waitProc1, waitProc2: bool
    proc neverEndingProc(): Future[void] =
      var res = newFuture[void]()
      proc continuation(udata: pointer) {.gcsafe.} =
        neverFlag2 = true
      proc cancellation(udata: pointer) {.gcsafe.} =
        neverFlag3 = true
      res.addCallback(continuation)
      res.cancelCallback = cancellation
      result = res
      neverFlag1 = true

    proc withTimeoutProc() {.async.} =
      try:
        discard await withTimeout(neverEndingProc(), 100.milliseconds)
        doAssert(false)
      except CancelledError:
        waitProc1 = true
      finally:
        waitProc2 = true

    var fut = withTimeoutProc()
    await cancelAndWait(fut)
    result = (fut.state == FutureState.Finished) and
             neverFlag1 and neverFlag2 and neverFlag3 and
             waitProc1 and waitProc2

  proc testCancellationRaceAsync(): Future[bool] {.async.} =
    var someFut = newFuture[void]()

    proc raceProc(): Future[void] {.async.} =
      await someFut

    var raceFut1 = raceProc()
    someFut.complete()
    await cancelAndWait(raceFut1)

    someFut = newFuture[void]()
    var raceFut2 = raceProc()
    someFut.fail(newException(ValueError, ""))
    await cancelAndWait(raceFut2)

    someFut = newFuture[void]()
    var raceFut3 = raceProc()
    someFut.cancel()
    await cancelAndWait(raceFut3)

    result = (raceFut1.state == FutureState.Cancelled) and
             (raceFut2.state == FutureState.Cancelled) and
             (raceFut3.state == FutureState.Cancelled)

  proc testWait(): bool =
    waitFor(testWaitAsync())

  proc testWithTimeout(): bool =
    waitFor(testWithTimeoutAsync())

  proc testCancellationRace(): bool =
    waitFor(testCancellationRaceAsync())


  proc testAsyncSpawnAsync(): Future[bool] {.async.} =

    proc completeTask1() {.async.} =
      discard

    proc completeTask2() {.async.} =
      await sleepAsync(100.milliseconds)

    proc errorTask() {.async.} =
      if true:
        raise newException(ValueError, "")

    proc cancelTask() {.async.} =
      await sleepAsync(10.seconds)

    try:
      var fut1 = completeTask1()
      var fut2 = completeTask2()
      asyncSpawn fut1
      asyncSpawn fut2
      await sleepAsync(200.milliseconds)
      if not(fut1.finished()) or not(fut2.finished()):
        return false
      if fut1.failed() or fut1.cancelled() or fut2.failed() or fut2.cancelled():
        return false
    except:
      return false

    try:
      asyncSpawn errorTask()
      return false
    except FutureDefect:
      discard
    except:
      return false

    try:
      var fut = cancelTask()
      await cancelAndWait(fut)
      asyncSpawn fut
      return false
    except FutureDefect:
      discard
    except:
      return false

    return true

  proc testAsyncSpawn(): bool =
    waitFor(testAsyncSpawnAsync())

  proc testSrcLocation(): bool =
    # WARNING: This test is very sensitive to line numbers and module name.

    proc macroFuture() {.async.} =
      let someVar {.used.} = 5
      let someOtherVar {.used.} = 4
      if true:
        let otherVar {.used.} = 3

    template templateFuture(): untyped =
      newFuture[void]("template")

    proc procFuture(): Future[void] =
      newFuture[void]("procedure")

    var fut1 = macroFuture()
    var fut2 = templateFuture()
    var fut3 = procFuture()

    fut2.complete()
    fut3.complete()

    let loc10 = fut1.location[0]
    let loc11 = fut1.location[1]
    let loc20 = fut2.location[0]
    let loc21 = fut2.location[1]
    let loc30 = fut3.location[0]
    let loc31 = fut3.location[1]

    proc chk(loc: ptr SrcLoc, file: string, line: int,
             procedure: string): bool =
      if len(procedure) == 0:
        (loc.line == line) and ($loc.file  == file)
      else:
        (loc.line == line) and ($loc.file  == file) and
        (loc.procedure == procedure)

    let r10 = chk(loc10, "testfut.nim", 1027, "macroFuture")
    let r11 = chk(loc11, "testfut.nim", 1028, "")
    let r20 = chk(loc20, "testfut.nim", 1040, "template")
    let r21 = chk(loc21, "testfut.nim", 1043, "")
    let r30 = chk(loc30, "testfut.nim", 1037, "procedure")
    let r31 = chk(loc31, "testfut.nim", 1044, "")

    r10 and r11 and r20 and r21 and r30 and r31

  proc testWithTimeoutCancelAndWait(): bool =
    proc futureNeverEnds(): Future[void] =
      newFuture[void]("neverending.future")

    proc futureOneLevelMore() {.async.} =
      await futureNeverEnds()

    proc testWithTimeout(): Future[bool] {.async.} =
      var fut = futureOneLevelMore()
      try:
        let res = await withTimeout(fut, 100.milliseconds)
        # Because `fut` is never-ending Future[T], `withTimeout` should return
        # `false` but it also has to wait until `fut` is cancelled.
        if not(res) and fut.cancelled():
          return true
        else:
          return false
      except CatchableError:
        return false

    waitFor testWithTimeout()

  proc testWaitCancelAndWait(): bool =
    proc futureNeverEnds(): Future[void] =
      newFuture[void]("neverending.future")

    proc futureOneLevelMore() {.async.} =
      await futureNeverEnds()

    proc testWait(): Future[bool] {.async.} =
      var fut = futureOneLevelMore()
      try:
        await wait(fut, 100.milliseconds)
        return false
      except AsyncTimeoutError:
        # Because `fut` is never-ending Future[T], `wait` should raise
        # `AsyncTimeoutError`, but only after `fut` is cancelled.
        if fut.cancelled():
          return true
        else:
          return false
      except CatchableError:
        return false

    waitFor testWait()

  proc testRaceZero(): bool =
    var tseq = newSeq[FutureBase]()
    var fut1 = race(tseq)
    var fut2 = race()
    var fut3 = race([])
    fut1.failed() and fut2.failed() and fut3.failed()

  proc testRaceVarargs(): bool =
    proc vlient1() {.async.} =
      await sleepAsync(100.milliseconds)

    proc vlient2() {.async.} =
      await sleepAsync(200.milliseconds)

    proc vlient3() {.async.} =
      await sleepAsync(300.milliseconds)

    proc ilient1(): Future[int] {.async.} =
      await sleepAsync(100.milliseconds)
      result = 10

    proc ilient2(): Future[int] {.async.} =
      await sleepAsync(200.milliseconds)
      result = 20

    proc ilient3(): Future[int] {.async.} =
      await sleepAsync(300.milliseconds)
      result = 30

    proc slient1(): Future[string] {.async.} =
      await sleepAsync(100.milliseconds)
      result = "sclient1"

    proc slient2(): Future[string] {.async.} =
      await sleepAsync(200.milliseconds)
      result = "sclient2"

    proc slient3(): Future[string] {.async.} =
      await sleepAsync(300.milliseconds)
      result = "sclient3"

    var fut11 = vlient1()
    var fut12 = ilient2()
    var fut13 = slient3()
    var res1 = waitFor(race(fut11, fut12, fut13))

    var fut21 = vlient2()
    var fut22 = ilient1()
    var fut23 = slient3()
    var res2 = waitFor(race(fut21, fut22, fut23))

    var fut31 = vlient3()
    var fut32 = ilient2()
    var fut33 = slient1()
    var res3 = waitFor(race(fut31, fut32, fut33))

    var fut41 = vlient1()
    var fut42 = slient2()
    var fut43 = ilient3()
    var res4 = waitFor(race(fut41, fut42, fut43))

    if (FutureBase(fut11) != res1) or
       (FutureBase(fut22) != res2) or
       (FutureBase(fut33) != res3) or
       (FutureBase(fut41) != res4):
      return false

    result = true

  proc testRaceSeq(): bool =
    proc vlient1() {.async.} =
      await sleepAsync(100.milliseconds)

    proc vlient2() {.async.} =
      await sleepAsync(200.milliseconds)

    proc vlient3() {.async.} =
      await sleepAsync(300.milliseconds)

    proc ilient1(): Future[int] {.async.} =
      await sleepAsync(100.milliseconds)
      result = 10

    proc ilient2(): Future[int] {.async.} =
      await sleepAsync(200.milliseconds)
      result = 20

    proc ilient3(): Future[int] {.async.} =
      await sleepAsync(300.milliseconds)
      result = 30

    proc slient1(): Future[string] {.async.} =
      await sleepAsync(100.milliseconds)
      result = "slient1"

    proc slient2(): Future[string] {.async.} =
      await sleepAsync(200.milliseconds)
      result = "slient2"

    proc slient3(): Future[string] {.async.} =
      await sleepAsync(300.milliseconds)
      result = "slient3"

    var v10 = vlient1()
    var v11 = ilient2()
    var v12 = slient3()
    var res1 = waitFor(race(@[FutureBase(v10), FutureBase(v11),
                              FutureBase(v12)]))

    var v20 = vlient2()
    var v21 = ilient1()
    var v22 = slient3()
    var res2 = waitFor(race(@[FutureBase(v20), FutureBase(v21),
                              FutureBase(v22)]))

    var v30 = vlient3()
    var v31 = ilient2()
    var v32 = slient1()
    var res3 = waitFor(race(@[FutureBase(v30), FutureBase(v31),
                              FutureBase(v32)]))

    var v40 = vlient1()
    var v41 = slient2()
    var v42 = ilient3()
    var res4 = waitFor(race(@[FutureBase(v40), FutureBase(v41),
                              FutureBase(v42)]))

    if res1 != FutureBase(v10) or
       res2 != FutureBase(v21) or
       res3 != FutureBase(v32) or
       res4 != FutureBase(v40):
      return false

    result = true

  proc testRaceCompleted(): bool =
    proc client1(): Future[int] {.async.} =
      result = 1

    proc client2() {.async.} =
      if true:
        raise newException(ValueError, "")

    proc client3(): Future[string] {.async.} =
      await sleepAsync(100.milliseconds)
      result = "client3"

    var f10 = client1()
    var f20 = client2()
    var f30 = client3()
    var fut1 = race(f30, f10, f20)
    var f11 = client1()
    var f21 = client2()
    var f31 = client3()
    var fut2 = race(f31, f21, f11)

    result = (fut1.done() and fut1.read() == FutureBase(f10)) and
             (fut2.done() and fut2.read() == FutureBase(f21))

  proc testRaceCancelled(): bool =
    proc client1() {.async.} =
      await sleepAsync(100.milliseconds)

    proc client2(): Future[int] {.async.} =
      await sleepAsync(200.milliseconds)
      return 10

    proc client3(): Future[string] {.async.} =
      await sleepAsync(300.milliseconds)
      return "client3"

    var f1 = client1()
    var f2 = client2()
    var f3 = client3()
    var fut = race(f1, f2, f3)
    waitFor(cancelAndWait(fut))

    if f1.finished() or f2.finished() or f3.finished():
      return false

    waitFor(sleepAsync(400.milliseconds))
    if not(f1.finished()) or not(f2.finished()) or not(f3.finished()):
      return false

    return true

  test "Async undefined behavior (#7758) test":
    check test1() == true
  test "Immediately completed asynchronous procedure test":
    check test2() == true
  test "Future[T] callbacks are invoked in reverse order (#7197) test":
    check test3() == "12345"
  test "Future[T] callbacks not changing order after removeCallback()":
    check test4() == "1245"
  test "wait[T]() test":
    check test5() == 6

  test "discard result Future[T] test":
    check testAsyncDiscard() == 10

  test "allFutures(zero) test":
    check testAllFuturesZero() == true
  test "allFutures(varargs) test":
    check testAllFuturesVarargs() == 30
  test "allFutures(varargs) test":
    check testAllFuturesSeq() == 300
  test "allFutures() already completed test":
    check testAllCompleted(1) == true
  test "allFinished() already completed test":
    check testAllCompleted(2) == true

  test "one(zero) test":
    check testOneZero() == true
  test "one(varargs) test":
    check testOneVarargs() == true
  test "one(seq) test":
    check testOneSeq() == true
  test "one() already completed test":
    check testOneCompleted() == true

  test "or() test":
    check testOr() == true
  test "or() already completed test":
    check testOrCompleted() == true

  test "race(zero) test":
    check testRaceZero() == true
  test "race(varargs) test":
    check testRaceVarargs() == true
  test "race(seq) test":
    check testRaceSeq() == true
  test "race() already completed test":
    check testRaceCompleted() == true
  test "race() cancellation test":
    check testRaceCancelled() == true

  test "cancel() async procedure test":
    check testCancelIter() == true
  test "cancelAndWait() test":
    check testCancelAndWait() == true
  test "Break cancellation propagation test":
    check testBreakCancellation() == true
  test "Cancellation callback test":
    check testCancelCallback() == true
  test "Cancellation wait() test":
    check testWait() == true
  test "Cancellation withTimeout() test":
    check testWithTimeout() == true
  test "Cancellation race test":
    check testCancellationRace() == true

  test "asyncSpawn() test":
    check testAsyncSpawn() == true

  test "location test":
    check testSrcLocation() == true

  test "withTimeout(fut) should wait cancellation test":
    check testWithTimeoutCancelAndWait()

  test "wait(fut) should wait cancellation test":
    check testWaitCancelAndWait()

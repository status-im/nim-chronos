#                Chronos Test Suite
#            (c) Copyright 2018-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)
import unittest
import ../chronos

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
      var res = await wait(testFuture1(), InfiniteDuration)
      result = 1
    except:
      result = 0

    if result == 0:
      return -1

    ## Test for immediately completed future and timeout = -1
    result = 0
    try:
      var res = await wait(testFuture2(), InfiniteDuration)
      result = 2
    except:
      result = 0

    if result == 0:
      return -2

    ## Test for not immediately completed future and timeout = 0
    result = 0
    try:
      var res = await wait(testFuture1(), 0.milliseconds)
    except AsyncTimeoutError:
      result = 3

    if result == 0:
      return -3

    ## Test for immediately completed future and timeout = 0
    result = 0
    try:
      var res = await wait(testFuture2(), 0.milliseconds)
      result = 4
    except:
      result = 0

    if result == 0:
      return -4

    ## Test for future which cannot be completed in timeout period
    result = 0
    try:
      var res = await wait(testFuture100(), 50.milliseconds)
    except AsyncTimeoutError:
      result = 5

    if result == 0:
      return -5

    ## Test for future which will be completed before timeout exceeded.
    try:
      var res = await wait(testFuture100(), 500.milliseconds)
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

  proc testAllVarargs(): int =
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

    waitFor(all(vlient1(), vlient2(), vlient3(), vlient4(), vlient5()))
    # 5 completed futures = 5
    result += completedFutures
    completedFutures = 0
    try:
      waitFor(all(vlient1(), vlient1f(),
                  vlient2(), vlient2f(),
                  vlient3(), vlient3f(),
                  vlient4(), vlient4f(),
                  vlient5(), vlient5f()))
      result -= 10000
    except:
      discard
    # 10 completed futures = 10
    result += completedFutures

    completedFutures = 0
    var res = waitFor(all(client1(), client2(), client3(), client4(), client5()))
    for item in res:
      result += item
    # 5 completed futures + 5 values = 10
    result += completedFutures

    completedFutures = 0
    try:
      var res = waitFor(all(client1(), client1f(),
                            client2(), client2f(),
                            client3(), client3f(),
                            client4(), client4f(),
                            client5(), client5f()))
      result -= 10000
    except:
      discard
    # 10 completed futures = 10
    result += completedFutures

  proc testAllSeq(): int =
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

    waitFor(all(vfutures))
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

    try:
      waitFor(all(vfutures))
      result -= 10000
    except:
      discard
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

    var res = waitFor(all(nfutures))
    for i in 0..<len(nfutures):
      result += res[i]
    # 5 * 10 completed futures + 5 * 10 results = 100
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

    try:
      var results = waitFor(all(nfutures))
      result -= 10000
    except:
      discard

    # 10 * 10 completed futures + 0 * 10 results = 100
    result += completedFutures

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

    asyncDiscard client1()
    asyncDiscard client1f()
    asyncDiscard client2()
    asyncDiscard client2f()
    asyncDiscard client3()
    asyncDiscard client3f()
    asyncDiscard client4()
    asyncDiscard client4f()
    asyncDiscard client5()
    asyncDiscard client5f()

    waitFor(sleepAsync(2000.milliseconds))
    result = completedFutures

  proc testAllZero(): bool =
    var tseq = newSeq[Future[int]]()
    var fut = all(tseq)
    result = fut.finished

  proc testOneIndexZero(): bool =
    var tseq = newSeq[Future[int]]()
    var fut = oneIndex(tseq)
    result = fut.finished and fut.failed

  proc testOneValueZero(): bool =
    var tseq = newSeq[Future[int]]()
    var fut = oneValue(tseq)
    result = fut.finished and fut.failed

  proc testOneIndexVarargs(): bool =
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

    var res10 = waitFor(oneIndex(vlient1(), vlient2(), vlient3()))
    var res11 = waitFor(oneIndex(vlient2(), vlient1(), vlient3()))
    var res12 = waitFor(oneIndex(vlient3(), vlient2(), vlient1()))
    if res10 != 0 or res11 != 1 or res12 != 2:
      return

    var res20 = waitFor(oneIndex(client1(), client2(), client3()))
    var res21 = waitFor(oneIndex(client2(), client1(), client3()))
    var res22 = waitFor(oneIndex(client3(), client2(), client1()))
    if res20 != 0 or res21 != 1 or res22 != 2:
      return

    result = true

  proc testOneValueVarargs(): bool =
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
    var v20 = vlient2()
    var v21 = vlient1()
    var v22 = vlient3()
    var v30 = vlient3()
    var v31 = vlient2()
    var v32 = vlient1()

    waitFor(oneValue(v10, v11, v12))
    waitFor(oneValue(v20, v21, v22))
    waitFor(oneValue(v30, v31, v32))

    if (not v10.finished) or (not v21.finished) or (not v32.finished):
      return

    var res30 = waitFor(oneValue(client1(), client2(), client3()))
    var res31 = waitFor(oneValue(client2(), client1(), client3()))
    var res32 = waitFor(oneValue(client3(), client2(), client1()))
    if res30 != 10 or res31 != 10 or res32 != 10:
      return

    result = true

  proc testOneIndexSeq(): bool =
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

    var res10 = waitFor(oneIndex(@[vlient1(), vlient2(), vlient3()]))
    var res11 = waitFor(oneIndex(@[vlient2(), vlient1(), vlient3()]))
    var res12 = waitFor(oneIndex(@[vlient3(), vlient2(), vlient1()]))
    if res10 != 0 or res11 != 1 or res12 != 2:
      return

    var res20 = waitFor(oneIndex(@[client1(), client2(), client3()]))
    var res21 = waitFor(oneIndex(@[client2(), client1(), client3()]))
    var res22 = waitFor(oneIndex(@[client3(), client2(), client1()]))
    if res20 != 0 or res21 != 1 or res22 != 2:
      return

    result = true

  proc testOneValueSeq(): bool =
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
    var v20 = vlient2()
    var v21 = vlient1()
    var v22 = vlient3()
    var v30 = vlient3()
    var v31 = vlient2()
    var v32 = vlient1()

    waitFor(oneValue(@[v10, v11, v12]))
    waitFor(oneValue(@[v20, v21, v22]))
    waitFor(oneValue(@[v30, v31, v32]))

    if (not v10.finished) or (not v21.finished) or (not v32.finished):
      return

    var res30 = waitFor(oneValue(@[client1(), client2(), client3()]))
    var res31 = waitFor(oneValue(@[client2(), client1(), client3()]))
    var res32 = waitFor(oneValue(@[client3(), client2(), client1()]))
    if res30 != 10 or res31 != 10 or res32 != 10:
      return

    result = true

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
      addTimer(moment, completion, cast[pointer](retFuture))
      return retFuture

    var fut = client1(100.milliseconds)
    fut.cancel()
    waitFor(sleepAsync(500.milliseconds))

    if not(fut.cancelled()):
      return false
    if (completed != 0) and (cancelled != 1):
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
  test "all[T](varargs) test":
    check testAllVarargs() == 35
  test "all[T](seq) test":
    check testAllSeq() == 350
  test "all[T](zero) test":
    check testAllZero() == true
  test "asyncDiscard() test":
    check testAsyncDiscard() == 10
  test "oneIndex[T](zero) test":
    check testOneIndexZero() == true
  test "oneValue[T](zero) test":
    check testOneValueZero() == true
  test "oneIndex[T](varargs) test":
    check testOneIndexVarargs() == true
  test "oneValue[T](varargs) test":
    check testOneValueVarargs() == true
  test "oneIndex[T](seq) test":
    check testOneIndexSeq() == true
  test "oneValue[T](seq) test":
    check testOneValueSeq() == true

  test "cancel() async procedure test":
    check testCancelIter() == true
  test "cancelAndWait() test":
    check testCancelAndWait() == true
  test "Break cancellation propagation test":
    check testBreakCancellation() == true
  test "Cancellation callback test":
    check testCancelCallback() == true

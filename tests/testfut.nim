#                Chronos Test Suite
#            (c) Copyright 2018-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)
import unittest2
import results
import ../chronos, ../chronos/unittest2/asynctests

{.used.}

type
  TestFooConnection* = ref object
    id*: int

suite "Future[T] behavior test suite":
  proc testFuture1(): Future[int] {.async.} =
    await sleepAsync(0.milliseconds)

  proc testFuture2(): Future[int] {.async.} =
    return 1

  proc testFuture3(): Future[int] {.async.} =
    result = await testFuture2()

  proc testFuture100(): Future[int] {.async.} =
    await sleepAsync(100.milliseconds)

  test "Async undefined behavior (#7758) test":
    var fut = testFuture1()
    poll()
    poll()
    if not fut.finished:
      poll()
    check: fut.finished

  test "Immediately completed asynchronous procedure test":
    var fut = testFuture3()
    check: fut.finished

  test "Future[T] callbacks are invoked in reverse order (#7197) test":
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

    check:
      fut.finished
      testResult == "12345"

  test "Future[T] callbacks not changing order after removeCallback()":
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
    check:
      fut.finished
      testResult == "1245"

  asyncTest "wait(duration) test":
    block:
      ## Test for not immediately completed future and timeout = -1
      let res =
        try:
          discard await wait(testFuture1(), InfiniteDuration)
          true
        except CatchableError:
          false
      check res
    block:
      ## Test for immediately completed future and timeout = -1
      let res =
        try:
          discard await wait(testFuture2(), InfiniteDuration)
          true
        except CatchableError:
          false
      check res
    block:
      ## Test for not immediately completed future and timeout = 0
      let res =
        try:
          discard await wait(testFuture1(), 0.milliseconds)
          false
        except AsyncTimeoutError:
          true
        except CatchableError:
          false
      check res

    block:
      ## Test for immediately completed future and timeout = 0
      let res =
        try:
          discard await wait(testFuture2(), 0.milliseconds)
          true
        except CatchableError:
          false
      check res

    block:
      ## Test for future which cannot be completed in timeout period
      let res =
        try:
          discard await wait(testFuture100(), 50.milliseconds)
          false
        except AsyncTimeoutError:
          true
        except CatchableError:
          false
      check res

    block:
      ## Test for future which will be completed before timeout exceeded.
      let res =
        try:
          discard await wait(testFuture100(), 500.milliseconds)
          true
        except CatchableError:
          false
      check res

  asyncTest "wait(future) test":
    block:
      ## Test for not immediately completed future and deadline which is not
      ## going to be finished
      let
        deadline = newFuture[void]()
        future1 = testFuture1()
      let res =
        try:
          discard await wait(future1, deadline)
          true
        except CatchableError:
          false
      check:
        deadline.finished() == false
        future1.finished() == true
        res == true

      await deadline.cancelAndWait()

      check deadline.finished() == true
    block:
      ## Test for immediately completed future and timeout = -1
      let
        deadline = newFuture[void]()
        future2 = testFuture2()
      let res =
        try:
          discard await wait(future2, deadline)
          true
        except CatchableError:
          false
      check:
        deadline.finished() == false
        future2.finished() == true
        res

      await deadline.cancelAndWait()

      check deadline.finished() == true
    block:
      ## Test for not immediately completed future and timeout = 0
      let
        deadline = newFuture[void]()
        future1 = testFuture1()
      deadline.complete()
      let res =
        try:
          discard await wait(future1, deadline)
          false
        except AsyncTimeoutError:
          true
        except CatchableError:
          false
      check:
        future1.finished() == false
        deadline.finished() == true
        res

    block:
      ## Test for immediately completed future and timeout = 0
      let
        deadline = newFuture[void]()
        future2 = testFuture2()
      deadline.complete()
      let (res1, res2) =
        try:
          let res = await wait(future2, deadline)
          (true, res)
        except CatchableError:
          (false, -1)
      check:
        future2.finished() == true
        deadline.finished() == true
        res1 == true
        res2 == 1

    block:
      ## Test for future which cannot be completed in timeout period
      let
        deadline = sleepAsync(50.milliseconds)
        future100 = testFuture100()
      let res =
        try:
          discard await wait(future100, deadline)
          false
        except AsyncTimeoutError:
          true
        except CatchableError:
          false
      check:
        deadline.finished() == true
        res
      await future100.cancelAndWait()
      check:
        future100.finished() == true

    block:
      ## Test for future which will be completed before timeout exceeded.
      let
        deadline = sleepAsync(500.milliseconds)
        future100 = testFuture100()
      let (res1, res2) =
        try:
          let res = await wait(future100, deadline)
          (true, res)
        except CatchableError:
          (false, -1)
      check:
        future100.finished() == true
        deadline.finished() == false
        res1 == true
        res2 == 0
      await deadline.cancelAndWait()
      check:
        deadline.finished() == true

  asyncTest "wait(future) cancellation behavior test":
    proc deepTest3(future: Future[void]) {.async.} =
      await future

    proc deepTest2(future: Future[void]) {.async.} =
      await deepTest3(future)

    proc deepTest1(future: Future[void]) {.async.} =
      await deepTest2(future)

    let

      deadlineFuture = newFuture[void]()

    block:
      # Cancellation should affect `testFuture` because it is in pending state.
      let monitorFuture = newFuture[void]()
      var testFuture = deepTest1(monitorFuture)
      let waitFut = wait(testFuture, deadlineFuture)
      await cancelAndWait(waitFut)
      check:
        monitorFuture.cancelled() == true
        testFuture.cancelled() == true
        waitFut.cancelled() == true
        deadlineFuture.finished() == false

    block:
      # Cancellation should not affect `testFuture` because it is completed.
      let monitorFuture = newFuture[void]()
      var testFuture = deepTest1(monitorFuture)
      let waitFut = wait(testFuture, deadlineFuture)
      monitorFuture.complete()
      await cancelAndWait(waitFut)
      check:
        monitorFuture.completed() == true
        monitorFuture.cancelled() == false
        testFuture.completed() == true
        waitFut.completed() == true
        deadlineFuture.finished() == false

    block:
      # Cancellation should not affect `testFuture` because it is failed.
      let monitorFuture = newFuture[void]()
      var testFuture = deepTest1(monitorFuture)
      let waitFut = wait(testFuture, deadlineFuture)
      monitorFuture.fail(newException(ValueError, "TEST"))
      await cancelAndWait(waitFut)
      check:
        monitorFuture.failed() == true
        monitorFuture.cancelled() == false
        testFuture.failed() == true
        testFuture.cancelled() == false
        waitFut.failed() == true
        testFuture.cancelled() == false
        deadlineFuture.finished() == false

    await cancelAndWait(deadlineFuture)

    check deadlineFuture.finished() == true

  asyncTest "Discarded result Future[T] test":
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

    await sleepAsync(1.seconds)
    check completedFutures == 10

  test "allFutures(zero) test":
    var tseq = newSeq[Future[int]]()
    var fut = allFutures(tseq)
    check:
      fut.finished

  asyncTest "allFutures(varargs) test":
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

    await allFutures(vlient1(), vlient2(), vlient3(), vlient4(), vlient5())
    check completedFutures == 5

    completedFutures = 0

    await allFutures(vlient1(), vlient1f(), vlient2(), vlient2f(), vlient3(),
                     vlient3f(), vlient4(), vlient4f(), vlient5(), vlient5f())
    check completedFutures == 10

    completedFutures = 0

    await allFutures(client1(), client2(), client3(), client4(), client5())
    check completedFutures == 5

    completedFutures = 0

    await allFutures(client1(), client1f(), client2(), client2f(), client3(),
                     client3f(), client4(), client4f(), client5(), client5f())
    check completedFutures == 10

  asyncTest "allFutures(varargs) test":
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

    await allFutures(vfutures)
    # 5 * 10 completed futures = 50
    check completedFutures == 50

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

    await allFutures(vfutures)
    # 10 * 10 completed futures = 100
    check completedFutures == 100

    completedFutures = 0
    nfutures.setLen(0)
    for i in 0..<10:
      nfutures.add(client1())
      nfutures.add(client2())
      nfutures.add(client3())
      nfutures.add(client4())
      nfutures.add(client5())

    await allFutures(nfutures)
    # 5 * 10 completed futures = 50
    check completedFutures == 50

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

    await allFutures(nfutures)

    # 10 * 10 completed futures = 100
    check completedFutures == 100

  test "allFutures() already completed test":
    proc client1(): Future[int] {.async.} =
      result = 1

    proc client2(): Future[int] {.async.} =
      if true:
        raise newException(ValueError, "")

    var fut = allFutures(client1(), client2())
    check:
      fut.finished()
      not(fut.failed())

  test "allFinished() already completed test":
    proc client1(): Future[int] {.async.} =
      result = 1

    proc client2(): Future[int] {.async.} =
      if true:
        raise newException(ValueError, "")

    var fut = allFinished(client1(), client2())
    check:
      fut.finished()
      not(fut.failed())
      len(fut.read()) == 2

  test "one(zero) test":
    var tseq = newSeq[Future[int]]()
    var fut = one(tseq)
    check: fut.finished and fut.failed

  asyncTest "one(varargs) test":
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
    var res1 = await one(fut11, fut12, fut13)

    var fut21 = vlient2()
    var fut22 = vlient1()
    var fut23 = vlient3()
    var res2 = await one(fut21, fut22, fut23)

    var fut31 = vlient3()
    var fut32 = vlient2()
    var fut33 = vlient1()
    var res3 = await one(fut31, fut32, fut33)

    check:
      fut11 == res1
      fut22 == res2
      fut33 == res3

    var cut11 = client1()
    var cut12 = client2()
    var cut13 = client3()
    var res4 = await one(cut11, cut12, cut13)

    var cut21 = client2()
    var cut22 = client1()
    var cut23 = client3()
    var res5 = await one(cut21, cut22, cut23)

    var cut31 = client3()
    var cut32 = client2()
    var cut33 = client1()
    var res6 = await one(cut31, cut32, cut33)

    check:
      cut11 == res4
      cut22 == res5
      cut33 == res6

  asyncTest "one(seq) test":
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
    var res1 = await one(@[v10, v11, v12])

    var v20 = vlient2()
    var v21 = vlient1()
    var v22 = vlient3()
    var res2 = await one(@[v20, v21, v22])

    var v30 = vlient3()
    var v31 = vlient2()
    var v32 = vlient1()
    var res3 = await one(@[v30, v31, v32])

    check:
      res1 == v10
      res2 == v21
      res3 == v32

    var c10 = client1()
    var c11 = client2()
    var c12 = client3()
    var res4 = await one(@[c10, c11, c12])

    var c20 = client2()
    var c21 = client1()
    var c22 = client3()
    var res5 = await one(@[c20, c21, c22])

    var c30 = client3()
    var c31 = client2()
    var c32 = client1()
    var res6 = await one(@[c30, c31, c32])

    check:
      res4 == c10
      res5 == c21
      res6 == c32

  test "one(completed) test":
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

    check:
      fut1.finished()
      not(fut1.failed())
      fut1.read() == f10
      fut2.finished()
      not(fut2.failed())
      fut2.read() == f21

  asyncTest "one() exception effect":
    proc checkraises() {.async: (raises: [CancelledError]).} =
      let f = Future[void].Raising([CancelledError]).init()
      f.complete()
      one(f).cancelSoon()

    await checkraises()

  asyncTest "or() test":
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
        raise newException(IOError, "")

    proc client5() {.async.} =
      discard

    proc client6() {.async.} =
      if true:
        raise newException(ValueError, "")

    proc client7() {.async.} =
      if true:
        raise newException(IOError, "")

    block:
      let res =
        try:
          await client1() or client2()
          true
        except CatchableError:
          false
      check res

    block:
      let res =
        try:
          await client2() or client1()
          true
        except CatchableError:
          false
      check res

    block:
      let res =
        try:
          await client1() or client4()
          true
        except IOError:
          false
        except CatchableError:
          false
      check res

    block:
      let res =
        try:
          await client2() or client4()
          true
        except IOError:
          false
        except CatchableError:
          false
      check res

    block:
      let res =
        try:
          await client4() or client2()
          true
        except IOError:
          false
        except CatchableError:
          false
      check res

    block:
      let res =
        try:
          await client1() or client3()
          false
        except ValueError:
          true
        except CatchableError:
          false
      check res

    block:
      let res =
        try:
          await client3() or client1()
          false
        except ValueError:
          true
        except CatchableError:
          false
      check res

    block:
      let res =
        try:
          await client3() or client4()
          false
        except ValueError:
          true
        except CatchableError:
          false
      check res

    block:
      let res =
        try:
          await client4() or client3()
          false
        except ValueError:
          true
        except CatchableError:
          false
      check res

    block:
      let res =
        try:
          await client5() or client6()
          true
        except ValueError:
          false
        except CatchableError:
          false
      check res

    block:
      let res =
        try:
          await client6() or client5()
          false
        except ValueError:
          true
        except CatchableError:
          false
      check res

    block:
      let res =
        try:
          await client6() or client7()
          false
        except ValueError:
          true
        except IOError:
          false
        except CatchableError:
          false
      check res

    block:
      let res =
        try:
          await client7() or client6()
          false
        except ValueError:
          false
        except IOError:
          true
        except CatchableError:
          false
      check res

  asyncTest "or() already completed test":
    proc client1(): Future[int] {.async.} =
      result = 1
    proc client2(): Future[int] {.async.} =
      if true:
        raise newException(ValueError, "")
    proc client3(): Future[int] {.async.} =
      await sleepAsync(100.milliseconds)
      result = 3

    block:
      let res =
        try:
          await client1() or client2()
          true
        except ValueError:
          false
        except CatchableError:
          false
      check res

    block:
      var fut1 = client1()
      var fut2 = client3()
      let res =
        try:
          await fut1 or fut2
          true
        except ValueError:
          false
        except CatchableError:
          false
      let discarded {.used.} = await fut2
      check res

    block:
      var fut1 = client2()
      var fut2 = client3()
      let res =
        try:
          await fut1 or fut2
          false
        except ValueError:
          true
        except CatchableError:
          false
      let discarded {.used.} = await fut2
      check res

    block:
      let res =
        try:
          await client2() or client1()
          false
        except ValueError:
          true
        except CatchableError:
          false
      check res

    block:
      var fut1 = client3()
      var fut2 = client1()
      let res =
        try:
          await fut1 or fut2
          true
        except ValueError:
          false
        except CatchableError:
          false
      let discarded {.used.} = await fut1
      check res

    block:
      var fut1 = client3()
      var fut2 = client2()
      let res =
        try:
          await fut1 or fut2
          false
        except ValueError:
          true
        except CatchableError:
          false
      let discarded {.used.} = await fut1
      check res

  asyncTest "tryCancel() async procedure test":
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
    discard fut.tryCancel()

    # Future must not be cancelled immediately, because it has many nested
    # futures.
    check:
      not fut.cancelled()

    expect(CancelledError):
      await fut

    check completed == 0

  asyncTest "cancelAndWait() test":
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
    await cancelAndWait(fut)
    check fut.cancelled()

  asyncTest "Break cancellation propagation test":
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
    discard fut1.tryCancel()
    await fut1
    await cancelAndWait(fut2)
    check:
      not fut1.cancelled()
      not fut2.cancelled()
      completed == 2

  asyncTest "Cancellation callback test":
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

      proc cancellation(udata: pointer) {.gcsafe.} =
        inc(cancelled)
        if not(retFuture.finished()):
          removeTimer(moment, completion, cast[pointer](retFuture))

      retFuture.cancelCallback = cancellation
      discard setTimer(moment, completion, cast[pointer](retFuture))
      return retFuture

    var fut = client1(100.milliseconds)
    discard fut.tryCancel()
    await sleepAsync(500.milliseconds)
    check:
      fut.cancelled()
      completed == 0
      cancelled == 1

  asyncTest "Cancellation wait(duration) test":
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
      except CatchableError:
        doAssert(false)
      finally:
        waitProc2 = true

    var fut = waitProc()
    await cancelAndWait(fut)
    check:
      fut.state == FutureState.Completed
      neverFlag1 and neverFlag2 and neverFlag3 and waitProc1 and waitProc2

  asyncTest "Cancellation withTimeout() test":
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
      neverFlag1 = true
      res

    proc withTimeoutProc() {.async.} =
      try:
        discard await withTimeout(neverEndingProc(), 100.milliseconds)
        doAssert(false)
      except CancelledError:
        waitProc1 = true
      except CatchableError:
        doAssert(false)
      finally:
        waitProc2 = true

    var fut = withTimeoutProc()
    await cancelAndWait(fut)
    check:
      fut.state == FutureState.Completed
      neverFlag1 and neverFlag2 and neverFlag3 and waitProc1 and waitProc2

  asyncTest "Cancellation wait(future) test":
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
      let deadline = sleepAsync(100.milliseconds)
      try:
        await wait(neverEndingProc(), deadline)
      except CancelledError:
        waitProc1 = true
      except CatchableError:
        doAssert(false)
      finally:
        await cancelAndWait(deadline)
        waitProc2 = true

    var fut = waitProc()
    await cancelAndWait(fut)
    check:
      fut.state == FutureState.Completed
      neverFlag1 and neverFlag2 and neverFlag3 and waitProc1 and waitProc2

  asyncTest "Cancellation race() test":
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
    discard someFut.tryCancel()
    await cancelAndWait(raceFut3)

    check:
      raceFut1.state == FutureState.Completed
      raceFut2.state == FutureState.Failed
      raceFut3.state == FutureState.Cancelled

  asyncTest "asyncSpawn() test":
    proc completeTask1() {.async.} =
      discard

    proc completeTask2() {.async.} =
      await sleepAsync(100.milliseconds)

    proc errorTask() {.async.} =
      if true:
        raise newException(ValueError, "")

    proc cancelTask() {.async.} =
      await sleepAsync(10.seconds)

    block:
      let res =
        try:
          var fut1 = completeTask1()
          var fut2 = completeTask2()
          asyncSpawn fut1
          asyncSpawn fut2
          await sleepAsync(200.milliseconds)
          if not(fut1.finished()) or not(fut2.finished()):
            false
          else:
            if fut1.failed() or fut1.cancelled() or fut2.failed() or
               fut2.cancelled():
              false
            else:
              true
        except CatchableError:
          false
      check res

    block:
      let res =
        try:
          asyncSpawn errorTask()
          false
        except FutureDefect:
          true
        except CatchableError:
          false
      check res

    block:
      let res =
        try:
          var fut = cancelTask()
          await cancelAndWait(fut)
          asyncSpawn fut
          false
        except FutureDefect:
          true
        except CatchableError:
          false
      check res

  test "location test":
    # WARNING: This test is very sensitive to line numbers and module name.
    template start(): int =
      instantiationInfo().line

    const first = start()
    proc macroFuture() {.async.} =
      let someVar {.used.} = 5           # LINE POSITION 1
      let someOtherVar {.used.} = 4
      if true:
        let otherVar {.used.} = 3        # LINE POSITION 2

    template templateFuture(): untyped =
      newFuture[void]("template")

    proc procFuture(): Future[void] =
      newFuture[void]("procedure")       # LINE POSITION 5

    var fut1 = macroFuture()
    var fut2 = templateFuture()          # LINE POSITION 3
    var fut3 = procFuture()

    fut2.complete()                      # LINE POSITION 4
    fut3.complete()                      # LINE POSITION 6

    {.push warning[Deprecated]: off.} # testing backwards compatibility interface
    let loc10 = fut1.location[0]
    let loc11 = fut1.location[1]
    let loc20 = fut2.location[0]
    let loc21 = fut2.location[1]
    let loc30 = fut3.location[0]
    let loc31 = fut3.location[1]
    {.pop.}

    proc chk(loc: ptr SrcLoc, file: string, line: int,
             procedure: string): bool =
      if len(procedure) == 0:
        (loc.line == line) and ($loc.file  == file)
      else:
        (loc.line == line) and ($loc.file  == file) and
        (loc.procedure == procedure)

    check:
      chk(loc10, "testfut.nim", first + 2, "macroFuture")
      chk(loc11, "testfut.nim", first + 5, "")
      chk(loc20, "testfut.nim", first + 14, "template")
      chk(loc21, "testfut.nim", first + 17, "")
      chk(loc30, "testfut.nim", first + 11, "procedure")
      chk(loc31, "testfut.nim", first + 18, "")

  asyncTest "withTimeout(fut) should wait cancellation test":
    proc futureNeverEnds(): Future[void] =
      newFuture[void]("neverending.future")

    proc futureOneLevelMore() {.async.} =
      await futureNeverEnds()

    let res =
      block:
        var fut = futureOneLevelMore()
        try:
          let res = await withTimeout(fut, 100.milliseconds)
          # Because `fut` is never-ending Future[T], `withTimeout` should return
          # `false` but it also has to wait until `fut` is cancelled.
          if not(res) and fut.cancelled():
            true
          else:
            false
        except CatchableError:
          false
    check res

  asyncTest "wait(future) should wait cancellation test":
    proc futureNeverEnds(): Future[void] =
      newFuture[void]("neverending.future")

    proc futureOneLevelMore() {.async.} =
      await futureNeverEnds()

    var fut = futureOneLevelMore()
    let res =
      try:
        await wait(fut, 100.milliseconds)
        false
      except AsyncTimeoutError:
        # Because `fut` is never-ending Future[T], `wait` should raise
        # `AsyncTimeoutError`, but only after `fut` is cancelled.
        if fut.cancelled():
          true
        else:
          false
      except CatchableError:
        false

    check res

  asyncTest "wait(future) should wait cancellation test":
    proc futureNeverEnds(): Future[void] =
      newFuture[void]("neverending.future")

    proc futureOneLevelMore() {.async.} =
      await futureNeverEnds()

    var fut = futureOneLevelMore()
    let res =
      try:
        await wait(fut, sleepAsync(100.milliseconds))
        false
      except AsyncTimeoutError:
        # Because `fut` is never-ending Future[T], `wait` should raise
        # `AsyncTimeoutError`, but only after `fut` is cancelled.
        if fut.cancelled():
          true
        else:
          false
      except CatchableError:
        false
    check res

  test "race(zero) test":
    var tseq = newSeq[FutureBase]()
    var fut1 = race(tseq)
    check:
      # https://github.com/nim-lang/Nim/issues/22964
      not compiles(block:
        var fut2 = race())
      not compiles(block:
        var fut3 = race([]))

    check:
      fut1.failed()
      # fut2.failed()
      # fut3.failed()

  asyncTest "race(varargs) test":
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
    var res1 = await race(fut11, fut12, fut13)
    check FutureBase(fut11) == res1
    await allFutures(fut12, fut13)

    var fut21 = vlient2()
    var fut22 = ilient1()
    var fut23 = slient3()
    var res2 = await race(fut21, fut22, fut23)
    check FutureBase(fut22) == res2
    await allFutures(fut21, fut23)

    var fut31 = vlient3()
    var fut32 = ilient2()
    var fut33 = slient1()
    var res3 = await race(fut31, fut32, fut33)
    check FutureBase(fut33) == res3
    await allFutures(fut31, fut32)

    var fut41 = vlient1()
    var fut42 = slient2()
    var fut43 = ilient3()
    var res4 = await race(fut41, fut42, fut43)
    check FutureBase(fut41) == res4
    await allFutures(fut42, fut43)

  asyncTest "race(seq) test":
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
    var res1 = await race(@[FutureBase(v10), FutureBase(v11), FutureBase(v12)])
    check res1 == FutureBase(v10)
    await allFutures(v11, v12)

    var v20 = vlient2()
    var v21 = ilient1()
    var v22 = slient3()
    var res2 = await race(@[FutureBase(v20), FutureBase(v21), FutureBase(v22)])
    check res2 == FutureBase(v21)
    await allFutures(v20, v22)

    var v30 = vlient3()
    var v31 = ilient2()
    var v32 = slient1()
    var res3 = await race(@[FutureBase(v30), FutureBase(v31), FutureBase(v32)])
    check res3 == FutureBase(v32)
    await allFutures(v30, v31)

    var v40 = vlient1()
    var v41 = slient2()
    var v42 = ilient3()
    var res4 = await race(@[FutureBase(v40), FutureBase(v41), FutureBase(v42)])
    check res4 == FutureBase(v40)
    await allFutures(v41, v42)

  asyncTest "race() already completed test":
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

    check:
      fut1.completed() and fut1.read() == FutureBase(f10)
      fut2.completed() and fut2.read() == FutureBase(f21)

    await allFutures(f20, f30, f11, f31)

  asyncTest "race() cancellation test":
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
    await cancelAndWait(fut)

    check:
      not(f1.finished())
      not(f2.finished())
      not(f3.finished())

    await sleepAsync(500.milliseconds)

    check:
      f1.finished()
      f2.finished()
      f3.finished()

  asyncTest "race() exception effect":
    proc checkraises() {.async: (raises: [CancelledError]).} =
      let f = Future[void].Raising([CancelledError]).init()
      f.complete()
      race(f).cancelSoon()

    await checkraises()

  test "Unsigned integer overflow test":
    check:
      0xFFFF_FFFF_FFFF_FFFF'u64 + 1'u64 == 0'u64
      0xFFFF_FFFF'u32 + 1'u32 == 0'u32

    when sizeof(uint) == 8:
      check 0xFFFF_FFFF_FFFF_FFFF'u + 1'u == 0'u
    else:
      check 0xFFFF_FFFF'u + 1'u == 0'u

    var v1_64 = 0xFFFF_FFFF_FFFF_FFFF'u64
    var v2_64 = 0xFFFF_FFFF_FFFF_FFFF'u64
    var v1_32 = 0xFFFF_FFFF'u32
    var v2_32 = 0xFFFF_FFFF'u32
    inc(v1_64)
    inc(v1_32)
    check:
      v1_64 == 0'u64
      v2_64 + 1'u64 == 0'u64
      v1_32 == 0'u32
      v2_32 + 1'u32 == 0'u32

    when sizeof(uint) == 8:
      var v1_u = 0xFFFF_FFFF_FFFF_FFFF'u
      var v2_u = 0xFFFF_FFFF_FFFF_FFFF'u
      inc(v1_u)
      check:
        v1_u == 0'u
        v2_u + 1'u == 0'u
    else:
      var v1_u = 0xFFFF_FFFF'u
      var v2_u = 0xFFFF_FFFF'u
      inc(v1_u)
      check:
        v1_u == 0'u
        v2_u + 1'u == 0'u

  asyncTest "wait(duration) cancellation undefined behavior test #1":
    proc testInnerFoo(fooFut: Future[void]): Future[TestFooConnection] {.
         async.} =
      await fooFut
      return TestFooConnection()

    proc testFoo(fooFut: Future[void]) {.async.} =
      let connection =
        try:
          let res = await testInnerFoo(fooFut).wait(10.seconds)
          Result[TestFooConnection, int].ok(res)
        except CancelledError:
          Result[TestFooConnection, int].err(0)
        except CatchableError:
          Result[TestFooConnection, int].err(1)
      check connection.isOk()

    var future = newFuture[void]("last.child.future")
    var someFut = testFoo(future)
    future.complete()
    discard someFut.tryCancel()
    await someFut

  asyncTest "wait(duration) cancellation undefined behavior test #2":
    proc testInnerFoo(fooFut: Future[void]): Future[TestFooConnection] {.
         async.} =
      await fooFut
      return TestFooConnection()

    proc testMiddleFoo(fooFut: Future[void]): Future[TestFooConnection] {.
         async.} =
      await testInnerFoo(fooFut)

    proc testFoo(fooFut: Future[void]) {.async.} =
      let connection =
        try:
          let res = await testMiddleFoo(fooFut).wait(10.seconds)
          Result[TestFooConnection, int].ok(res)
        except CancelledError:
          Result[TestFooConnection, int].err(0)
        except CatchableError:
          Result[TestFooConnection, int].err(1)
      check connection.isOk()

    var future = newFuture[void]("last.child.future")
    var someFut = testFoo(future)
    future.complete()
    discard someFut.tryCancel()
    await someFut

  asyncTest "wait(duration) should allow cancellation test (depends on race())":
    proc testFoo(): Future[bool] {.async.} =
      let
        resFut = sleepAsync(2.seconds).wait(3.seconds)
        timeFut = sleepAsync(1.seconds)
        cancelFut = cancelAndWait(resFut)
      discard await race(cancelFut, timeFut)
      if cancelFut.finished():
        return (resFut.cancelled() and cancelFut.completed())
      false

    check (await testFoo()) == true

  asyncTest "withTimeout() cancellation undefined behavior test #1":
    proc testInnerFoo(fooFut: Future[void]): Future[TestFooConnection] {.
         async.} =
      await fooFut
      return TestFooConnection()

    proc testFoo(fooFut: Future[void]) {.async.} =
      let connection =
        try:
          let
            checkFut = testInnerFoo(fooFut)
            res = await withTimeout(checkFut, 10.seconds)
          if res:
            Result[TestFooConnection, int].ok(checkFut.value)
          else:
            Result[TestFooConnection, int].err(0)
        except CancelledError:
          Result[TestFooConnection, int].err(1)
        except CatchableError:
          Result[TestFooConnection, int].err(2)
      check connection.isOk()

    var future = newFuture[void]("last.child.future")
    var someFut = testFoo(future)
    future.complete()
    discard someFut.tryCancel()
    await someFut

  asyncTest "withTimeout() cancellation undefined behavior test #2":
    proc testInnerFoo(fooFut: Future[void]): Future[TestFooConnection] {.
         async.} =
      await fooFut
      return TestFooConnection()

    proc testMiddleFoo(fooFut: Future[void]): Future[TestFooConnection] {.
         async.} =
      await testInnerFoo(fooFut)

    proc testFoo(fooFut: Future[void]) {.async.} =
      let connection =
        try:
          let
            checkFut = testMiddleFoo(fooFut)
            res = await withTimeout(checkFut, 10.seconds)
          if res:
            Result[TestFooConnection, int].ok(checkFut.value)
          else:
            Result[TestFooConnection, int].err(0)
        except CancelledError:
          Result[TestFooConnection, int].err(1)
        except CatchableError:
          Result[TestFooConnection, int].err(2)
      check connection.isOk()

    var future = newFuture[void]("last.child.future")
    var someFut = testFoo(future)
    future.complete()
    discard someFut.tryCancel()
    await someFut

  asyncTest "withTimeout() should allow cancellation test (depends on race())":
    proc testFoo(): Future[bool] {.async.} =
      let
        resFut = sleepAsync(2.seconds).withTimeout(3.seconds)
        timeFut = sleepAsync(1.seconds)
        cancelFut = cancelAndWait(resFut)
      discard await race(cancelFut, timeFut)
      if cancelFut.finished():
        return (resFut.cancelled() and cancelFut.completed())
      false

    check (await testFoo()) == true

  asyncTest "wait(future) cancellation undefined behavior test #1":
    proc testInnerFoo(fooFut: Future[void]): Future[TestFooConnection] {.
         async.} =
      await fooFut
      return TestFooConnection()

    proc testFoo(fooFut: Future[void]) {.async.} =
      let deadline = sleepAsync(10.seconds)
      let connection =
        try:
          let res = await testInnerFoo(fooFut).wait(deadline)
          Result[TestFooConnection, int].ok(res)
        except CancelledError:
          Result[TestFooConnection, int].err(0)
        except CatchableError:
          Result[TestFooConnection, int].err(1)
        finally:
          await deadline.cancelAndWait()

      check connection.isOk()

    var future = newFuture[void]("last.child.future")
    var someFut = testFoo(future)
    future.complete()
    discard someFut.tryCancel()
    await someFut

  asyncTest "wait(future) cancellation undefined behavior test #2":
    proc testInnerFoo(fooFut: Future[void]): Future[TestFooConnection] {.
         async.} =
      await fooFut
      return TestFooConnection()

    proc testMiddleFoo(fooFut: Future[void]): Future[TestFooConnection] {.
         async.} =
      await testInnerFoo(fooFut)

    proc testFoo(fooFut: Future[void]) {.async.} =
      let deadline = sleepAsync(10.seconds)
      let connection =
        try:
          let res = await testMiddleFoo(fooFut).wait(deadline)
          Result[TestFooConnection, int].ok(res)
        except CancelledError:
          Result[TestFooConnection, int].err(0)
        except CatchableError:
          Result[TestFooConnection, int].err(1)
        finally:
          await deadline.cancelAndWait()
      check connection.isOk()

    var future = newFuture[void]("last.child.future")
    var someFut = testFoo(future)
    future.complete()
    discard someFut.tryCancel()
    await someFut

  asyncTest "wait(future) should allow cancellation test (depends on race())":
    proc testFoo(): Future[bool] {.async.} =
      let
        deadline = sleepAsync(3.seconds)
        resFut = sleepAsync(2.seconds).wait(deadline)
        timeFut = sleepAsync(1.seconds)
        cancelFut = cancelAndWait(resFut)
      discard await race(cancelFut, timeFut)
      await deadline.cancelAndWait()
      if cancelFut.finished():
        return (resFut.cancelled() and cancelFut.completed())
      false

    check (await testFoo()) == true

  asyncTest "Cancellation behavior test":
    proc testInnerFoo(fooFut: Future[void]) {.async.} =
      await fooFut

    proc testMiddleFoo(fooFut: Future[void]) {.async.} =
      await testInnerFoo(fooFut)

    proc testOuterFoo(fooFut: Future[void]) {.async.} =
      await testMiddleFoo(fooFut)

    block:
      # Cancellation of pending Future
      let future = newFuture[void]("last.child.pending.future")
      await cancelAndWait(future)
      check:
        future.cancelled() == true

    block:
      # Cancellation of completed Future
      let future = newFuture[void]("last.child.completed.future")
      future.complete()
      await cancelAndWait(future)
      check:
        future.cancelled() == false
        future.completed() == true

    block:
      # Cancellation of failed Future
      let future = newFuture[void]("last.child.failed.future")
      future.fail(newException(ValueError, "ABCD"))
      await cancelAndWait(future)
      check:
        future.cancelled() == false
        future.failed() == true

    block:
      # Cancellation of already cancelled Future
      let future = newFuture[void]("last.child.cancelled.future")
      future.cancelAndSchedule()
      await cancelAndWait(future)
      check:
        future.cancelled() == true

    block:
      # Cancellation of Pending->Pending->Pending->Pending sequence
      let future = newFuture[void]("last.child.pending.future")
      let testFut = testOuterFoo(future)
      await cancelAndWait(testFut)
      check:
        testFut.cancelled() == true

    block:
      # Cancellation of Pending->Pending->Pending->Completed sequence
      let future = newFuture[void]("last.child.completed.future")
      let testFut = testOuterFoo(future)
      future.complete()
      await cancelAndWait(testFut)
      check:
        testFut.cancelled() == false
        testFut.completed() == true

    block:
      # Cancellation of Pending->Pending->Pending->Failed sequence
      let future = newFuture[void]("last.child.failed.future")
      let testFut = testOuterFoo(future)
      future.fail(newException(ValueError, "ABCD"))
      await cancelAndWait(testFut)
      check:
        testFut.cancelled() == false
        testFut.failed() == true

    block:
      # Cancellation of Pending->Pending->Pending->Cancelled sequence
      let future = newFuture[void]("last.child.cancelled.future")
      let testFut = testOuterFoo(future)
      future.cancelAndSchedule()
      await cancelAndWait(testFut)
      check:
        testFut.cancelled() == true

    block:
      # Cancellation of pending Future, when automatic scheduling disabled
      let future = newFuture[void]("last.child.pending.future",
                                   {FutureFlag.OwnCancelSchedule})
      proc cancellation(udata: pointer) {.gcsafe.} =
        discard
      future.cancelCallback = cancellation
      # Note, future will never be finished in such case, until we manually not
      # finish it
      let cancelFut = cancelAndWait(future)
      await sleepAsync(100.milliseconds)
      check:
        cancelFut.finished() == false
        future.cancelled() == false
      # Now we manually changing Future's state, so `cancelAndWait` could
      # finish
      future.complete()
      await cancelFut
      check:
        cancelFut.finished() == true
        future.cancelled() == false
        future.finished() == true

    block:
      # Cancellation of pending Future, which will fail Future on cancellation,
      # when automatic scheduling disabled
      let future = newFuture[void]("last.child.completed.future",
                                   {FutureFlag.OwnCancelSchedule})
      proc cancellation(udata: pointer) {.gcsafe.} =
        future.complete()
      future.cancelCallback = cancellation
      # Note, future will never be finished in such case, until we manually not
      # finish it
      await cancelAndWait(future)
      check:
        future.cancelled() == false
        future.completed() == true

    block:
      # Cancellation of pending Future, which will fail Future on cancellation,
      # when automatic scheduling disabled
      let future = newFuture[void]("last.child.failed.future",
                                   {FutureFlag.OwnCancelSchedule})
      proc cancellation(udata: pointer) {.gcsafe.} =
        future.fail(newException(ValueError, "ABCD"))
      future.cancelCallback = cancellation
      # Note, future will never be finished in such case, until we manually not
      # finish it
      await cancelAndWait(future)
      check:
        future.cancelled() == false
        future.failed() == true

    block:
      # Cancellation of pending Future, which will fail Future on cancellation,
      # when automatic scheduling disabled
      let future = newFuture[void]("last.child.cancelled.future",
                                   {FutureFlag.OwnCancelSchedule})
      proc cancellation(udata: pointer) {.gcsafe.} =
        future.cancelAndSchedule()
      future.cancelCallback = cancellation
      # Note, future will never be finished in such case, until we manually not
      # finish it
      await cancelAndWait(future)
      check:
        future.cancelled() == true

    block:
      # Cancellation of pending Pending->Pending->Pending->Pending, when
      # automatic scheduling disabled and Future do nothing in cancellation
      # callback
      let future = newFuture[void]("last.child.pending.future",
                                   {FutureFlag.OwnCancelSchedule})
      proc cancellation(udata: pointer) {.gcsafe.} =
        discard
      future.cancelCallback = cancellation
      # Note, future will never be finished in such case, until we manually not
      # finish it
      let testFut = testOuterFoo(future)
      let cancelFut = cancelAndWait(testFut)
      await sleepAsync(100.milliseconds)
      check:
        cancelFut.finished() == false
        testFut.cancelled() == false
        future.cancelled() == false
      # Now we manually changing Future's state, so `cancelAndWait` could
      # finish
      future.complete()
      await cancelFut
      check:
        cancelFut.finished() == true
        future.cancelled() == false
        future.finished() == true
        testFut.cancelled() == false
        testFut.finished() == true

    block:
      # Cancellation of pending Pending->Pending->Pending->Pending, when
      # automatic scheduling disabled and Future completes in cancellation
      # callback
      let future = newFuture[void]("last.child.pending.future",
                                   {FutureFlag.OwnCancelSchedule})
      proc cancellation(udata: pointer) {.gcsafe.} =
        future.complete()
      future.cancelCallback = cancellation
      # Note, future will never be finished in such case, until we manually not
      # finish it
      let testFut = testOuterFoo(future)
      await cancelAndWait(testFut)
      await sleepAsync(100.milliseconds)
      check:
        testFut.cancelled() == false
        testFut.finished() == true
        future.cancelled() == false
        future.finished() == true

    block:
      # Cancellation of pending Pending->Pending->Pending->Pending, when
      # automatic scheduling disabled and Future fails in cancellation callback
      let future = newFuture[void]("last.child.pending.future",
                                   {FutureFlag.OwnCancelSchedule})
      proc cancellation(udata: pointer) {.gcsafe.} =
        future.fail(newException(ValueError, "ABCD"))
      future.cancelCallback = cancellation
      # Note, future will never be finished in such case, until we manually not
      # finish it
      let testFut = testOuterFoo(future)
      await cancelAndWait(testFut)
      await sleepAsync(100.milliseconds)
      check:
        testFut.cancelled() == false
        testFut.failed() == true
        future.cancelled() == false
        future.failed() == true

    block:
      # Cancellation of pending Pending->Pending->Pending->Pending, when
      # automatic scheduling disabled and Future fails in cancellation callback
      let future = newFuture[void]("last.child.pending.future",
                                   {FutureFlag.OwnCancelSchedule})
      proc cancellation(udata: pointer) {.gcsafe.} =
        future.cancelAndSchedule()
      future.cancelCallback = cancellation
      # Note, future will never be finished in such case, until we manually not
      # finish it
      let testFut = testOuterFoo(future)
      await cancelAndWait(testFut)
      await sleepAsync(100.milliseconds)
      check:
        testFut.cancelled() == true
        future.cancelled() == true

  test "Issue #334 test":
    proc test(): bool =
      var testres = ""

      proc a() {.async.} =
        try:
          await sleepAsync(seconds(1))
        except CatchableError as exc:
          testres.add("A")
          raise exc

      proc b() {.async.} =
        try:
          await a()
        except CatchableError as exc:
          testres.add("B")
          raise exc

      proc c() {.async.} =
        try:
          echo $(await b().withTimeout(seconds(2)))
        except CatchableError as exc:
          testres.add("C")
          raise exc

      let x = c()
      x.cancelSoon()

      try:
        waitFor x
      except CatchableError:
        testres.add("D")

      testres.add("E")

      waitFor sleepAsync(milliseconds(100))

      testres == "ABCDE"

    check test() == true

  asyncTest "cancelAndWait() should be able to cancel test":
    proc test1() {.async.} =
      await noCancel sleepAsync(100.milliseconds)
      await noCancel sleepAsync(100.milliseconds)
      await sleepAsync(100.milliseconds)

    proc test2() {.async.} =
      await noCancel sleepAsync(100.milliseconds)
      await sleepAsync(100.milliseconds)
      await noCancel sleepAsync(100.milliseconds)

    proc test3() {.async.} =
      await sleepAsync(100.milliseconds)
      await noCancel sleepAsync(100.milliseconds)
      await noCancel sleepAsync(100.milliseconds)

    proc test4() {.async.} =
      while true:
        await noCancel sleepAsync(50.milliseconds)
        await sleepAsync(0.milliseconds)

    proc test5() {.async.} =
      while true:
        await sleepAsync(0.milliseconds)
        await noCancel sleepAsync(50.milliseconds)

    block:
      let future1 = test1()
      await cancelAndWait(future1)
      let future2 = test1()
      await sleepAsync(10.milliseconds)
      await cancelAndWait(future2)
      check:
        future1.cancelled() == true
        future2.cancelled() == true

    block:
      let future1 = test2()
      await cancelAndWait(future1)
      let future2 = test2()
      await sleepAsync(10.milliseconds)
      await cancelAndWait(future2)
      check:
        future1.cancelled() == true
        future2.cancelled() == true

    block:
      let future1 = test3()
      await cancelAndWait(future1)
      let future2 = test3()
      await sleepAsync(10.milliseconds)
      await cancelAndWait(future2)
      check:
        future1.cancelled() == true
        future2.cancelled() == true

    block:
      let future1 = test4()
      await cancelAndWait(future1)
      let future2 = test4()
      await sleepAsync(333.milliseconds)
      await cancelAndWait(future2)
      check:
        future1.cancelled() == true
        future2.cancelled() == true

    block:
      let future1 = test5()
      await cancelAndWait(future1)
      let future2 = test5()
      await sleepAsync(333.milliseconds)
      await cancelAndWait(future2)
      check:
        future1.cancelled() == true
        future2.cancelled() == true

  asyncTest "cancelAndWait(varargs) should be able to cancel test":
    proc test01() {.async.} =
      await noCancel sleepAsync(100.milliseconds)
      await noCancel sleepAsync(100.milliseconds)
      await sleepAsync(100.milliseconds)

    proc test02() {.async.} =
      await noCancel sleepAsync(100.milliseconds)
      await sleepAsync(100.milliseconds)
      await noCancel sleepAsync(100.milliseconds)

    proc test03() {.async.} =
      await sleepAsync(100.milliseconds)
      await noCancel sleepAsync(100.milliseconds)
      await noCancel sleepAsync(100.milliseconds)

    proc test04() {.async.} =
      while true:
        await noCancel sleepAsync(50.milliseconds)
        await sleepAsync(0.milliseconds)

    proc test05() {.async.} =
      while true:
        await sleepAsync(0.milliseconds)
        await noCancel sleepAsync(50.milliseconds)

    proc test11() {.async: (raises: [CancelledError]).} =
      await noCancel sleepAsync(100.milliseconds)
      await noCancel sleepAsync(100.milliseconds)
      await sleepAsync(100.milliseconds)

    proc test12() {.async: (raises: [CancelledError]).} =
      await noCancel sleepAsync(100.milliseconds)
      await sleepAsync(100.milliseconds)
      await noCancel sleepAsync(100.milliseconds)

    proc test13() {.async: (raises: [CancelledError]).} =
      await sleepAsync(100.milliseconds)
      await noCancel sleepAsync(100.milliseconds)
      await noCancel sleepAsync(100.milliseconds)

    proc test14() {.async: (raises: [CancelledError]).} =
      while true:
        await noCancel sleepAsync(50.milliseconds)
        await sleepAsync(0.milliseconds)

    proc test15() {.async: (raises: [CancelledError]).} =
      while true:
        await sleepAsync(0.milliseconds)
        await noCancel sleepAsync(50.milliseconds)

    template runTest(N1, N2, N3: untyped) =
      let
        future01 = `test N2 N1`()
        future02 = `test N2 N1`()
        future03 = `test N2 N1`()
        future04 = `test N2 N1`()
        future05 = `test N2 N1`()
        future06 = `test N2 N1`()
        future07 = `test N2 N1`()
        future08 = `test N2 N1`()
        future09 = `test N2 N1`()
        future10 = `test N2 N1`()
        future11 = `test N2 N1`()
        future12 = `test N2 N1`()

      await allFutures(
        cancelAndWait(future01, future02),
        cancelAndWait(FutureBase(future03), FutureBase(future04)),
        cancelAndWait([future05, future06]),
        cancelAndWait([FutureBase(future07), FutureBase(future08)]),
        cancelAndWait(@[future09, future10]),
        cancelAndWait(@[FutureBase(future11), FutureBase(future12)])
      )

      let
        future21 = `test N2 N1`()
        future22 = `test N2 N1`()
        future23 = `test N2 N1`()
        future24 = `test N2 N1`()
        future25 = `test N2 N1`()
        future26 = `test N2 N1`()
        future27 = `test N2 N1`()
        future28 = `test N2 N1`()
        future29 = `test N2 N1`()
        future30 = `test N2 N1`()
        future31 = `test N2 N1`()
        future32 = `test N2 N1`()

      await sleepAsync(`N3`)

      await allFutures(
        cancelAndWait(future21, future22),
        cancelAndWait(FutureBase(future23), FutureBase(future24)),
        cancelAndWait([future25, future26]),
        cancelAndWait([FutureBase(future27), FutureBase(future28)]),
        cancelAndWait(@[future29, future30]),
        cancelAndWait(@[FutureBase(future31), FutureBase(future32)])
      )

      check:
        future01.state == FutureState.Cancelled
        future02.state == FutureState.Cancelled
        future03.state == FutureState.Cancelled
        future04.state == FutureState.Cancelled
        future05.state == FutureState.Cancelled
        future06.state == FutureState.Cancelled
        future07.state == FutureState.Cancelled
        future08.state == FutureState.Cancelled
        future09.state == FutureState.Cancelled
        future10.state == FutureState.Cancelled
        future11.state == FutureState.Cancelled
        future12.state == FutureState.Cancelled
        future21.state == FutureState.Cancelled
        future22.state == FutureState.Cancelled
        future23.state == FutureState.Cancelled
        future24.state == FutureState.Cancelled
        future25.state == FutureState.Cancelled
        future26.state == FutureState.Cancelled
        future27.state == FutureState.Cancelled
        future28.state == FutureState.Cancelled
        future29.state == FutureState.Cancelled
        future30.state == FutureState.Cancelled
        future31.state == FutureState.Cancelled
        future32.state == FutureState.Cancelled

    runTest(1, 0, 10.milliseconds)
    runTest(1, 1, 10.milliseconds)
    runTest(2, 0, 10.milliseconds)
    runTest(2, 1, 10.milliseconds)
    runTest(3, 0, 10.milliseconds)
    runTest(3, 1, 10.milliseconds)
    runTest(4, 0, 333.milliseconds)
    runTest(4, 1, 333.milliseconds)
    runTest(5, 0, 333.milliseconds)
    runTest(5, 1, 333.milliseconds)

  asyncTest "cancelAndWait([]) on empty set returns completed Future test":
    var
      a0: array[0, Future[void]]
      a1: array[0, Future[void].Raising([CancelledError])]
      a2: seq[Future[void].Raising([CancelledError])]
      a3: seq[Future[void]]

    let
      future1 = cancelAndWait()
      future2 = cancelAndWait(a0)
      future3 = cancelAndWait(a1)
      future4 = cancelAndWait(a2)
      future5 = cancelAndWait(a3)

    check:
      future1.finished() == true
      future2.finished() == true
      future3.finished() == true
      future4.finished() == true
      future5.finished() == true

  asyncTest "cancelAndWait([]) should ignore finished futures test":
    let
      future0 =
        Future[void].Raising([]).init("future0", {OwnCancelSchedule})
      future1 =
        Future[void].Raising([CancelledError]).init("future1")
      future2 =
        Future[void].Raising([CancelledError, ValueError]).init("future2")
      future3 =
        Future[string].Raising([]).init("future3", {OwnCancelSchedule})
      future4 =
        Future[string].Raising([CancelledError]).init("future4")
      future5 =
        Future[string].Raising([CancelledError, ValueError]).init("future5")
      future6 =
        newFuture[void]("future6")
      future7 =
        newFuture[void]("future7")
      future8 =
        newFuture[void]("future8")
      future9 =
        newFuture[string]("future9")
      future10 =
        newFuture[string]("future10")
      future11 =
        newFuture[string]("future11")

    future0.complete()
    check future1.tryCancel() == true
    future2.fail(newException(ValueError, "Test Error"))
    future3.complete("test")
    check future4.tryCancel() == true
    future5.fail(newException(ValueError, "Test Error"))
    future6.complete()
    check future7.tryCancel() == true
    future8.fail(newException(ValueError, "Test Error"))
    future9.complete("test")
    check future10.tryCancel() == true
    future11.fail(newException(ValueError, "Test Error"))

    check:
      cancelAndWait(future0, future1, future2).finished() == true
      cancelAndWait(future3, future4, future5).finished() == true
      cancelAndWait(future6, future7, future8).finished() == true
      cancelAndWait(future9, future10, future11).finished() == true
      cancelAndWait(future0, future1, future2,
                    future3, future4, future5,
                    future5, future7, future8,
                    future9, future10, future11).finished() == true

      cancelAndWait([future0, future1, future2]).finished() == true
      cancelAndWait([future3, future4]).finished() == true
      cancelAndWait([future5]).finished() == true
      cancelAndWait([future6, future7, future8]).finished() == true
      cancelAndWait([future9, future10, future11]).finished() == true

      cancelAndWait(@[future0, future1, future2]).finished() == true
      cancelAndWait(@[future3, future4]).finished() == true
      cancelAndWait(@[future5]).finished() == true
      cancelAndWait(@[future6, future7, future8]).finished() == true
      cancelAndWait(@[future9, future10, future11]).finished() == true

  asyncTest "join() test":
    proc joinFoo0(future: FutureBase) {.async.} =
      await join(future)

    proc joinFoo1(future: Future[void]) {.async.} =
      await join(future)

    proc joinFoo2(future: Future[void]) {.
         async: (raises: [CancelledError]).} =
      await join(future)

    let
      future0 = newFuture[void]()
      future1 = newFuture[void]()
      future2 = Future[void].Raising([CancelledError]).init()

    let
      resfut0 = joinFoo0(future0)
      resfut1 = joinFoo1(future1)
      resfut2 = joinFoo2(future2)

    check:
      resfut0.finished() == false
      resfut1.finished() == false
      resfut2.finished() == false

    future0.complete()
    future1.complete()
    future2.complete()

    let res =
      try:
        await noCancel allFutures(resfut0, resfut1, resfut2).wait(1.seconds)
        true
      except AsyncTimeoutError:
        false

    check:
      res == true
      resfut0.finished() == true
      resfut1.finished() == true
      resfut2.finished() == true
      future0.finished() == true
      future1.finished() == true
      future2.finished() == true

  asyncTest "join() cancellation test":
    proc joinFoo0(future: FutureBase) {.async.} =
      await join(future)

    proc joinFoo1(future: Future[void]) {.async.} =
      await join(future)

    proc joinFoo2(future: Future[void]) {.
         async: (raises: [CancelledError]).} =
      await join(future)

    let
      future0 = newFuture[void]()
      future1 = newFuture[void]()
      future2 = Future[void].Raising([CancelledError]).init()

    let
      resfut0 = joinFoo0(future0)
      resfut1 = joinFoo1(future1)
      resfut2 = joinFoo2(future2)

    check:
      resfut0.finished() == false
      resfut1.finished() == false
      resfut2.finished() == false

    let
      cancelfut0 = cancelAndWait(resfut0)
      cancelfut1 = cancelAndWait(resfut1)
      cancelfut2 = cancelAndWait(resfut2)

    let res =
      try:
        await noCancel allFutures(cancelfut0, cancelfut1,
                                  cancelfut2).wait(1.seconds)
        true
      except AsyncTimeoutError:
        false

    check:
      res == true
      cancelfut0.finished() == true
      cancelfut1.finished() == true
      cancelfut2.finished() == true
      resfut0.cancelled() == true
      resfut1.cancelled() == true
      resfut2.cancelled() == true
      future0.finished() == false
      future1.finished() == false
      future2.finished() == false

    future0.complete()
    future1.complete()
    future2.complete()

    check:
      future0.finished() == true
      future1.finished() == true
      future2.finished() == true

  test "Sink with literals":
    # https://github.com/nim-lang/Nim/issues/22175
    let fut = newFuture[string]()
    fut.complete("test")
    check:
      fut.value() == "test"

  test "Raising type matching":
    type X[E] = Future[void].Raising(E)

    proc f(x: X) = discard

    var v: Future[void].Raising([ValueError])
    f(v)

    type Object = object
      # TODO cannot use X[[ValueError]] here..
      field: Future[void].Raising([ValueError])
    discard Object(field: v)

    check:
      not compiles(Future[void].Raising([42]))
      not compiles(Future[void].Raising(42))

  asyncTest "Timeout/cancellation race wait(duration) test":
    proc raceTest(T: typedesc, itype: int) {.async.} =
      let monitorFuture = newFuture[T]("monitor",
                                       {FutureFlag.OwnCancelSchedule})

      proc raceProc0(future: Future[T]): Future[T] {.async.} =
        await future
      proc raceProc1(future: Future[T]): Future[T] {.async.} =
        await raceProc0(future)
      proc raceProc2(future: Future[T]): Future[T] {.async.} =
        await raceProc1(future)

      proc activation(udata: pointer) {.gcsafe.} =
        if itype == 0:
          when T is void:
            monitorFuture.complete()
          elif T is int:
            monitorFuture.complete(100)
        elif itype == 1:
          monitorFuture.fail(newException(ValueError, "test"))
        else:
          monitorFuture.cancelAndSchedule()

      monitorFuture.cancelCallback = activation
      let
        testFut = raceProc2(monitorFuture)
        waitFut = wait(testFut, 10.milliseconds)

      when T is void:
        let waitRes =
          try:
            await waitFut
            if itype == 0:
              true
            else:
              false
          except CancelledError:
            false
          except CatchableError:
            if itype != 0:
              true
            else:
              false
        check waitRes == true
      elif T is int:
        let waitRes =
          try:
            let res = await waitFut
            if itype == 0:
              (true, res)
            else:
              (false, -1)
          except CancelledError:
            (false, -1)
          except CatchableError:
            if itype != 0:
              (true, 0)
            else:
              (false, -1)
        if itype == 0:
          check:
            waitRes[0] == true
            waitRes[1] == 100
        else:
          check:
            waitRes[0] == true

    await raceTest(void, 0)
    await raceTest(void, 1)
    await raceTest(void, 2)
    await raceTest(int, 0)
    await raceTest(int, 1)
    await raceTest(int, 2)

  asyncTest "Timeout/cancellation race wait(future) test":
    proc raceTest(T: typedesc, itype: int) {.async.} =
      let monitorFuture = newFuture[T]()

      proc raceProc0(future: Future[T]): Future[T] {.async.} =
        await future
      proc raceProc1(future: Future[T]): Future[T] {.async.} =
        await raceProc0(future)
      proc raceProc2(future: Future[T]): Future[T] {.async.} =
        await raceProc1(future)

      proc continuation(udata: pointer) {.gcsafe.} =
        if itype == 0:
          when T is void:
            monitorFuture.complete()
          elif T is int:
            monitorFuture.complete(100)
        elif itype == 1:
          monitorFuture.fail(newException(ValueError, "test"))
        else:
          monitorFuture.cancelAndSchedule()

      let deadlineFuture = newFuture[void]()
      deadlineFuture.addCallback continuation

      let
        testFut = raceProc2(monitorFuture)
        waitFut = wait(testFut, deadlineFuture)

      deadlineFuture.complete()

      when T is void:
        let waitRes =
          try:
            await waitFut
            if itype == 0:
              true
            else:
              false
          except CancelledError:
            false
          except CatchableError:
            if itype != 0:
              true
            else:
              false
        check waitRes == true
      elif T is int:
        let waitRes =
          try:
            let res = await waitFut
            if itype == 0:
              (true, res)
            else:
              (false, -1)
          except CancelledError:
            (false, -1)
          except CatchableError:
            if itype != 0:
              (true, 0)
            else:
              (false, -1)
        if itype == 0:
          check:
            waitRes[0] == true
            waitRes[1] == 100
        else:
          check:
            waitRes[0] == true

    await raceTest(void, 0)
    await raceTest(void, 1)
    await raceTest(void, 2)
    await raceTest(int, 0)
    await raceTest(int, 1)
    await raceTest(int, 2)

  asyncTest "Timeout/cancellation race withTimeout() test":
    proc raceTest(T: typedesc, itype: int) {.async.} =
      let monitorFuture = newFuture[T]("monitor",
                                       {FutureFlag.OwnCancelSchedule})

      proc raceProc0(future: Future[T]): Future[T] {.async.} =
        await future
      proc raceProc1(future: Future[T]): Future[T] {.async.} =
        await raceProc0(future)
      proc raceProc2(future: Future[T]): Future[T] {.async.} =
        await raceProc1(future)

      proc activation(udata: pointer) {.gcsafe.} =
        if itype == 0:
          when T is void:
            monitorFuture.complete()
          elif T is int:
            monitorFuture.complete(100)
        elif itype == 1:
          monitorFuture.fail(newException(ValueError, "test"))
        else:
          monitorFuture.cancelAndSchedule()

      monitorFuture.cancelCallback = activation
      let
        testFut = raceProc2(monitorFuture)
        waitFut = withTimeout(testFut, 10.milliseconds)

      when T is void:
        let waitRes =
          try:
            await waitFut
          except CancelledError:
            false
          except CatchableError:
            false
        if itype == 0:
          check waitRes == true
        elif itype == 1:
          check waitRes == true
        else:
          check waitRes == false
      elif T is int:
        let waitRes =
          try:
            await waitFut
          except CancelledError:
            false
          except CatchableError:
            false
        if itype == 0:
          check waitRes == true
        elif itype == 1:
          check waitRes == true
        else:
          check waitRes == false

    await raceTest(void, 0)
    await raceTest(void, 1)
    await raceTest(void, 2)
    await raceTest(int, 0)
    await raceTest(int, 1)
    await raceTest(int, 2)

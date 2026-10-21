#                Chronos Test Suite
#            (c) Copyright 2018-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)
import std/[macros, strutils]
import unittest2
import ../chronos
import ../chronos/config
import ../chronos/unittest2/asynctests

{.used.}

proc asyncRetValue(n: int): Future[int] {.async.} =
  await sleepAsync(n.milliseconds)
  result = n * 10

proc asyncRetVoid(n: int) {.async.} =
  await sleepAsync(n.milliseconds)

proc asyncRetExceptionValue(n: int): Future[int] {.async.} =
  await sleepAsync(n.milliseconds)
  result = n * 10
  if true:
    raise newException(ValueError, "Test exception")

proc asyncRetExceptionVoid(n: int) {.async.} =
  await sleepAsync(n.milliseconds)
  if true:
    raise newException(ValueError, "Test exception")

template returner =
  # can't use `return 5`
  result = 5
  return

suite "Macro transformations test suite":
  asyncTest "`await` command test":
    type
      RetValueType = proc(n: int): Future[int] {.async.}
      RetImplicitVoidType = proc(n: int) {.async.}
      RetVoidType = proc(n: int): Future[void] {.async.}

    await asyncRetVoid(100)
    check (await asyncRetValue(100)) == 1000
    check (await asyncRetValue(100)) == 1000
    expect ValueError:
      await asyncRetExceptionVoid(100)
    expect ValueError:
      discard await asyncRetExceptionValue(100)

    block:
      let fn: RetVoidType = asyncRetVoid
      await fn(100)
    block:
      let fn: RetImplicitVoidType = asyncRetVoid
      await fn(100)
    block:
      let fn: RetValueType = asyncRetValue
      check (await fn(100)) == 1000

  asyncTest "`awaitne` command test":
    var res1: Future[void]
    var res2: Future[int]

    res1 = awaitne asyncRetVoid(100)
    res2 = awaitne asyncRetValue(100)
    check not res1.failed()
    check res2.read() == 1000

    res1 = awaitne asyncRetExceptionVoid(100)
    check res1.failed()

    res2 = awaitne asyncRetExceptionValue(100)
    expect ValueError:
      discard res2.read()

  test "template async macro transformation":
    template templatedAsync(name, restype: untyped): untyped =
      proc name(): Future[restype] {.async.} = return @[4]

    templatedAsync(testTemplate, seq[int])
    check waitFor(testTemplate()) == @[4]

    macro macroAsync(name, restype, innerrestype: untyped): untyped =
      quote do:
        proc `name`(): Future[`restype`[`innerrestype`]] {.async.} = return

    type OpenObject = object
    macroAsync(testMacro, seq, OpenObject)
    check waitFor(testMacro()).len == 0

    macro macroAsync2(name, restype, inner1, inner2, inner3, inner4: untyped): untyped =
      quote do:
        proc `name`(): Future[`restype`[`inner1`[`inner2`[`inner3`, `inner4`]]]] {.async.} = return

    macroAsync2(testMacro2, seq, Opt, Result, OpenObject, cstring)
    check waitFor(testMacro2()).len == 0

  test "Future with generics":
    proc gen(T: typedesc): Future[T] {.async.} =
      proc testproc(): Future[T] {.async.} =
        when T is void:
          return
        else:
          return default(T)
      await testproc()

    waitFor gen(void)
    check:
      waitFor(gen(int)) == default(int)

  test "Nested return":
    proc nr: Future[int] {.async.} =
      return
        if 1 == 1:
          return 42
        else:
          33

    check waitFor(nr()) == 42

# There are a few unreacheable statements to ensure that we don't regress in
# generated code
{.push warning[UnreachableCode]: off.}

suite "Macro transformations - completions":
  asyncTest "Run closure to completion on return": # issue #415
    var x = 0
    proc test415 {.async.} =
      try:
        return
      finally:
        await sleepAsync(1.milliseconds)
        x = 5
    await test415()
    check: x == 5

  asyncTest "Run closure to completion on defer":
    var x = 0
    proc testDefer {.async.} =
      defer:
        await sleepAsync(1.milliseconds)
        x = 5
      return
    await testDefer()
    check: x == 5

  asyncTest "Run closure to completion with exceptions":
    var x = 0
    proc testExceptionHandling {.async.} =
      try:
        return
      finally:
        try:
          await sleepAsync(1.milliseconds)
          raise newException(ValueError, "")
        except ValueError:
          await sleepAsync(1.milliseconds)
        await sleepAsync(1.milliseconds)
        x = 5
    await testExceptionHandling()
    check: x == 5

  test "Correct return value when updating result after return":
    proc testWeirdCase: int =
      try: return 33
      finally: result = 55
    proc testWeirdCaseAsync: Future[int] {.async.} =
      try:
        await sleepAsync(1.milliseconds)
        return 33
      finally: result = 55

    check:
        testWeirdCase() == waitFor(testWeirdCaseAsync())
        testWeirdCase() == 55

  test "Correct return value with result assignment in defer":
    proc testWeirdCase: int =
      defer:
        result = 55
      result = 33
    proc testWeirdCaseAsync: Future[int] {.async.} =
      defer:
        result = 55
      await sleepAsync(1.milliseconds)
      return 33

    check:
        testWeirdCase() == waitFor(testWeirdCaseAsync())
        testWeirdCase() == 55

  asyncTest "Generic & finally calling async":
    proc testGeneric(T: type): Future[T] {.async.} =
      try:
        try:
          await sleepAsync(1.milliseconds)
          return
        finally:
          await sleepAsync(1.milliseconds)
          await sleepAsync(1.milliseconds)
          result = 11
      finally:
        await sleepAsync(1.milliseconds)
        await sleepAsync(1.milliseconds)
        result = 12
    check (await testGeneric(int)) == 12

    proc testFinallyCallsAsync(T: type): Future[T] {.async.} =
      try:
        await sleepAsync(1.milliseconds)
        return
      finally:
        result = await testGeneric(T)
    check (await testFinallyCallsAsync(int)) == 12

  asyncTest "templates returning":
    proc testReturner: Future[int] {.async.} =
      returner
      doAssert false
    check (await testReturner()) == 5

    proc testReturner2: Future[int] {.async.} =
      template returner2 =
        return 6
      returner2
      doAssert false
    check (await testReturner2()) == 6

  test "raising defects":
    proc raiser {.async.} =
      # sleeping to make sure our caller is the poll loop
      await sleepAsync(0.milliseconds)
      raise newException(Defect, "uh-oh")

    let fut = raiser()
    expect(Defect): waitFor(fut)
    check not fut.completed()
    fut.complete()

  asyncTest "return result":
    proc returnResult: Future[int] {.async.} =
      var result: int
      result = 12
      return result
    check (await returnResult()) == 12

  asyncTest "async in async":
    proc asyncInAsync: Future[int] {.async.} =
      proc a2: Future[int] {.async.} =
        result = 12
      result = await a2()
    check (await asyncInAsync()) == 12
{.pop.}

suite "Macro transformations - implicit returns":
  asyncTest "Implicit return":
    proc implicit(): Future[int] {.async.} =
      42

    proc implicit2(): Future[int] {.async.} =
      block:
        42

    proc implicit3(): Future[int] {.async.} =
      try:
        parseInt("error")
      except ValueError:
        42

    proc implicit4(v: bool): Future[int] {.async.} =
      case v
      of false: 5
      of true: 42

    proc implicit5(v: bool): Future[int] {.async.} =
      if v: 42
      else: 5

    proc implicit6(v: ref int): Future[int] {.async.} =
      try:
        parseInt("error")
      except ValueError:
        42
      finally:
        v[] = 42

    proc implicit7(v: bool): Future[int] {.async.} =
      case v
      of false: return 33
      of true: 42

    proc implicit8(v: bool): Future[int] {.async.} =
      case v
      of false: await implicit7(v)
      of true: 42

    proc implicit9(): Future[int] {.async.} =
      result = 42
      result

    let fin = new int
    check:
      (await implicit()) == 42
      (await implicit2()) == 42
      (await implicit3()) == 42
      (await implicit4(true)) == 42
      (await implicit5(true)) == 42
      (await implicit5(false)) == 5
      (await implicit6(fin)) == 42
      fin[] == 42
      (await implicit7(true)) == 42
      (await implicit7(false)) == 33

      (await implicit8(true)) == 42
      (await implicit8(false)) == 33

      (await implicit9()) == 42

suite "Exception/effect tracking":
  asyncTest "Nested defer/finally not called on return":
    # issue #288
    # fixed by https://github.com/nim-lang/Nim/pull/19933
    var answer = 0
    proc a {.async.} =
      try:
        try:
          await sleepAsync(0.milliseconds)
          return
        finally:
          answer = 32
      finally:
        answer.inc(10)
    await a()
    check answer == 42

  asyncTest "raise-only":
    # https://github.com/status-im/nim-chronos/issues/56
    proc trySync() {.async.} =
      return

    proc x() {.async.} =
      try:
        await trySync()
        return
      except ValueError:
        discard

      raiseAssert "shouldn't reach"

    await x()

  template checkNotCompiles(body: untyped) =
    check (not compiles(body))

  asyncTest "Can raise valid exception":
    proc test1 {.async.} = raise newException(ValueError, "hey")
    proc test2 {.async: (raises: [ValueError]).} = raise newException(ValueError, "hey")
    proc test3 {.async: (raises: [IOError, ValueError]).} =
      if 1 == 2:
        raise newException(ValueError, "hey")
      else:
        raise newException(IOError, "hey")

    proc test4 {.async: (raises: []), used.} = raise newException(Defect, "hey")
    proc test5 {.async: (raises: []).} = discard
    proc test6 {.async: (raises: []).} = await test5()

    expect(ValueError): await test1()
    expect(ValueError): await test2()
    expect(IOError): await test3()
    await test6()

  test "Cannot raise invalid exception":
    checkNotCompiles:
      proc test3 {.async: (raises: [IOError]).} = raise newException(ValueError, "hey")

  asyncTest "Explicit return in non-raising proc":
    proc test(): Future[int] {.async: (raises: []).} = return 12
    check:
      (await test()) == 12

  test "Non-raising compatibility":
    proc test1 {.async: (raises: [ValueError]).} = raise newException(ValueError, "hey")
    let testVar: Future[void] = test1()

    proc test2 {.async.} = raise newException(ValueError, "hey")
    let testVar2: proc: Future[void] = test2

    # Doesn't work unfortunately
    #let testVar3: proc: Future[void] = test1

  test "Cannot store invalid future types":
    proc test1 {.async: (raises: [ValueError]).} = raise newException(ValueError, "hey")
    proc test2 {.async: (raises: [IOError]).} = raise newException(IOError, "hey")

    var a = test1()
    checkNotCompiles:
      a = test2()

  test "Await raises the correct types":
    proc test1 {.async: (raises: [ValueError]).} = raise newException(ValueError, "hey")
    proc test2 {.async: (raises: [ValueError, CancelledError]).} = await test1()
    checkNotCompiles:
      proc test3 {.async: (raises: [CancelledError]).} = await test1()

  test "Can create callbacks":
    proc test1 {.async: (raises: [ValueError]).} = raise newException(ValueError, "hey")
    let callback: proc() {.async: (raises: [ValueError]).} = test1

  test "Can return values":
    proc test1: Future[int] {.async: (raises: [ValueError]).} =
      if 1 == 0: raise newException(ValueError, "hey")
      return 12
    proc test2: Future[int] {.async: (raises: [ValueError, IOError, CancelledError]).} =
      return await test1()

    checkNotCompiles:
      proc test3: Future[int] {.async: (raises: [CancelledError]).} = await test1()

    check waitFor(test2()) == 12

  test "Manual tracking":
    proc test1: Future[int] {.async: (raw: true, raises: [ValueError]).} =
      result = newFuture[int]()
      result.complete(12)
    check waitFor(test1()) == 12

    proc test2: Future[int] {.async: (raw: true, raises: [IOError, OSError]).} =
      checkNotCompiles:
        result.fail(newException(ValueError, "fail"))

      result = newFuture[int]()
      result.fail(newException(IOError, "fail"))

    proc test3: Future[void] {.async: (raw: true, raises: []).} =
      result = newFuture[void]()
      checkNotCompiles:
        result.fail(newException(ValueError, "fail"))
      result.complete()
    # Inheritance
    proc test4: Future[void] {.async: (raw: true, raises: [CatchableError]).} =
      result = newFuture[void]()
      result.fail(newException(IOError, "fail"))

    check:
      waitFor(test1()) == 12
    expect(IOError):
      discard waitFor(test2())

    waitFor(test3())
    expect(IOError):
      waitFor(test4())

  test "or errors":
    proc testit {.async: (raises: [ValueError]).} =
      raise (ref ValueError)()

    proc testit2 {.async: (raises: [IOError]).} =
      raise (ref IOError)()

    proc test {.async: (raises: [CancelledError, ValueError, IOError]).} =
      await testit() or testit2()

    proc noraises() {.raises: [].} =
      expect(ValueError):
        try:
          let f = test()
          waitFor(f)
        except IOError:
          doAssert false

    noraises()

  test "Wait errors":
    proc testit {.async: (raises: [ValueError]).} =
      raise newException(ValueError, "hey")

    proc test {.async: (raises: [ValueError, AsyncTimeoutError, CancelledError]).} =
      await wait(testit(), 1000.milliseconds)

    proc noraises() {.raises: [].} =
      try:
        expect(ValueError): waitFor(test())
      except CancelledError: doAssert false
      except AsyncTimeoutError: doAssert false

    noraises()

  test "Nocancel errors with raises":
    proc testit {.async: (raises: [ValueError, CancelledError]).} =
      await sleepAsync(5.milliseconds)
      raise (ref ValueError)()

    proc test {.async: (raises: [ValueError]).} =
      await noCancel testit()

    proc noraises() {.raises: [].} =
      expect(ValueError):
        let f = test()
        waitFor(f.cancelAndWait())
        waitFor(f)

    noraises()

  test "Nocancel with no errors":
    proc testit {.async: (raises: [CancelledError]).} =
      await sleepAsync(5.milliseconds)

    proc test {.async: (raises: []).} =
      await noCancel testit()

    proc noraises() {.raises: [].} =
      let f = test()
      waitFor(f.cancelAndWait())
      waitFor(f)

    noraises()

  test "Nocancel errors without raises":
    proc testit {.async.} =
      await sleepAsync(5.milliseconds)
      raise (ref ValueError)()

    proc test {.async.} =
      await noCancel testit()

    proc noraises() =
      expect(ValueError):
        let f = test()
        waitFor(f.cancelAndWait())
        waitFor(f)

    noraises()

  test "Defect on wrong exception type at runtime":
    {.push warning[User]: off}
    let f = InternalRaisesFuture[void, (ValueError,)]()
    expect(Defect): f.fail((ref CatchableError)())
    {.pop.}
    check: not f.finished()

    expect(Defect): f.fail((ref CatchableError)(), warn = false)
    check: not f.finished()

  asyncTest "handleException behavior":
    proc raiseException() {.
        async: (handleException: true, raises: [AsyncExceptionError]).} =
      raise (ref Exception)(msg: "Raising Exception is UB and support for it may change in the future")

    proc callCatchAll() {.async: (raises: []).} =
      expect(AsyncExceptionError):
        await raiseException()

    await callCatchAll()

  test "Global handleException does not override local annotations":
    when chronosHandleException:
      proc unnanotated() {.async.} = raise (ref CatchableError)()

      checkNotCompiles:
        proc annotated() {.async: (raises: [ValueError]).} =
          raise (ref CatchableError)()

      checkNotCompiles:
        proc noHandleException() {.async: (handleException: false).} =
          raise (ref Exception)()
    else:
      skip()

  asyncTest "Results compatibility":
    proc returnOk(): Future[Result[int, string]] {.async: (raises: []).} =
      ok(42)

    proc returnErr(): Future[Result[int, string]] {.async: (raises: []).} =
      err("failed")

    proc testit(): Future[Result[void, string]] {.async: (raises: []).} =
      let
        v = await returnOk()

      check:
        v.isOk() and v.value() == 42

      let
        vok = ?v
      check:
        vok == 42

      discard ?await returnErr()

    check:
      (await testit()).error() == "failed"

  test "await with defer":
    when (NimMajor, NimMinor, NimPatch) >= (2, 2, 6):
      # https://github.com/status-im/nim-chronos/issues/576
      var aaa: int
      var bbb: int
      var ccc: int

      proc doStuff() {.async.} =
        defer:
          for i in 0 ..< 3:
            try:
              await sleepAsync(10.milliseconds)
            except:
              discard

            bbb += 1

        for i in 0 ..< 3:
          try:
            await sleepAsync(10.milliseconds)
          except:
            discard
          aaa += 1

        raise newException(CatchableError, "")

      proc main() {.async.} =
        try:
          await doStuff()
        except:
          ccc += 1

      waitFor main()

      check:
        aaa == 3
        bbb == 3
        ccc == 1
    else:
      skip()

  asyncTest "async do":
    var called = false
    proc callProc[T](f: proc (): T {.raises: [], gcsafe.}): T =
      f()

    proc foo() {.async.} =
      await callProc do {.async.}:
        called = true
    await foo()
    check:
      called

  test "detect poll reentrancy at compile-time in macro":
    when (NimMajor, NimMinor) >= (2, 2):
      check:
        not(compiles do:
          proc callPoll() {.async.} =
            poll())
        not(compiles do:
          proc callWaitFor() {.async.} =
            waitFor(sleepAsync(1.millis)))
    else:
      skip()

  test "detect poll reentrance at runtime for other cases":
    when chronosStrictReentrancy:
      callSoon(proc(_: pointer) =
        poll())

      expect(Defect):
        poll()
    else:
      skip()

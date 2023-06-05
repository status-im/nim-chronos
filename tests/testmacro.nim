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

{.used.}

type
  RetValueType = proc(n: int): Future[int] {.async.}
  RetImplicitVoidType = proc(n: int) {.async.}
  RetVoidType = proc(n: int): Future[void] {.async.}

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

proc testAwait(): Future[bool] {.async.} =
  var res: int

  await asyncRetVoid(100)
  res = await asyncRetValue(100)
  if res != 1000:
    return false
  if (await asyncRetValue(100)) != 1000:
    return false
  try:
    await asyncRetExceptionVoid(100)
    return false
  except ValueError:
    discard
  res = 0
  try:
    discard await asyncRetExceptionValue(100)
    return false
  except ValueError:
    discard
  if res != 0:
    return false

  block:
    let fn: RetVoidType = asyncRetVoid
    await fn(100)
  block:
    let fn: RetImplicitVoidType = asyncRetVoid
    await fn(100)
  block:
    let fn: RetValueType = asyncRetValue
    if (await fn(100)) != 1000:
      return false

  return true

proc testAwaitne(): Future[bool] {.async.} =
  var res1: Future[void]
  var res2: Future[int]

  res1 = awaitne asyncRetVoid(100)
  res2 = awaitne asyncRetValue(100)
  if res1.failed():
    return false
  if res2.read() != 1000:
    return false

  res1 = awaitne asyncRetExceptionVoid(100)
  if not(res1.failed()):
    return false

  res2 = awaitne asyncRetExceptionValue(100)
  try:
    discard res2.read()
    return false
  except ValueError:
    discard

  return true

suite "Macro transformations test suite":
  test "`await` command test":
    check waitFor(testAwait()) == true
  test "`awaitne` command test":
    check waitFor(testAwaitne()) == true


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

  test "Implicit return":
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

    let fin = new int
    check:
      waitFor(implicit()) == 42
      waitFor(implicit2()) == 42
      waitFor(implicit3()) == 42
      waitFor(implicit4(true)) == 42
      waitFor(implicit5(true)) == 42
      waitFor(implicit5(false)) == 5
      waitFor(implicit6(fin)) == 42
      fin[] == 42
      waitFor(implicit7(true)) == 42
      waitFor(implicit7(false)) == 33

      waitFor(implicit8(true)) == 42
      waitFor(implicit8(false)) == 33

suite "Closure iterator's exception transformation issues":
  test "Nested defer/finally not called on return":
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
    waitFor(a())
    check answer == 42

  test "raise-only":
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

    waitFor(x())


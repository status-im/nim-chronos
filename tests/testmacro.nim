#                Chronos Test Suite
#            (c) Copyright 2018-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)
import unittest2
import ../chronos

when defined(nimHasUsed): {.used.}

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

suite "Exceptions tracking":
  test "Can raise valid exception":
    proc test1 {.async.} = raise newException(ValueError, "hey")
    proc test2 {.asyncraises: [ValueError].} = raise newException(ValueError, "hey")
    proc test3 {.asyncraises: [IOError, ValueError].} =
      if 1 == 2:
        raise newException(ValueError, "hey")
      else:
        raise newException(IOError, "hey")

    proc test4 {.asyncraises: [].} = raise newException(Defect, "hey")
    proc test5 {.asyncraises: [].} = await test5()

  test "Cannot raise invalid exception":
    check not (compiles do:
      proc test3 {.asyncraises: [IOError].} = raise newException(ValueError, "hey")
    )

  test "Non-raising compatibility":
    proc test1 {.asyncraises: [ValueError].} = raise newException(ValueError, "hey")
    let testVar: Future[void] = test1()

    proc test2 {.async.} = raise newException(ValueError, "hey")
    let testVar2: proc: Future[void] = test2

    # Doesn't work unfortunately
    #let testVar3: proc: Future[void] = test1

  test "Cannot store invalid future types":
    proc test1 {.asyncraises: [ValueError].} = raise newException(ValueError, "hey")
    proc test2 {.asyncraises: [IOError].} = raise newException(IOError, "hey")

    var a = test1()
    check not compiles(a = test2())

  test "Await raises the correct types":
    proc test1 {.asyncraises: [ValueError].} = raise newException(ValueError, "hey")
    proc test2 {.asyncraises: [ValueError].} = await test1()
    check not (compiles do:
      proc test3 {.asyncraises: [].} = await test1()
    )

  test "Can create callbacks":
    proc test1 {.asyncraises: [ValueError].} = raise newException(ValueError, "hey")
    let callback: proc {.asyncraises: [ValueError].} = test1

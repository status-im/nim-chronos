#                Chronos Test Suite
#            (c) Copyright 2018-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

import unittest
import ../chronos

proc testFuture1(): Future[int] {.async.} =
  await sleepAsync(100)

proc testFuture2(): Future[int] {.async.} =
  return 1

proc testFuture3(): Future[int] {.async.} =
  result = await testFuture2()

proc testFuture4(): Future[int] {.async.} =
  ## Test for not immediately completed future and timeout = -1
  result = 0
  try:
    var res = await wait(testFuture1(), -1)
    result = 1
  except:
    result = 0

  if result == 0:
    return -1

  ## Test for immediately completed future and timeout = -1
  result = 0
  try:
    var res = await wait(testFuture2(), -1)
    result = 2
  except:
    result = 0

  if result == 0:
    return -2

  ## Test for not immediately completed future and timeout = 0
  result = 0
  try:
    var res = await wait(testFuture1(), 0)
  except AsyncTimeoutError:
    result = 3

  if result == 0:
    return -3

  ## Test for immediately completed future and timeout = 0
  result = 0
  try:
    var res = await wait(testFuture2(), 0)
    result = 4
  except:
    result = 0

  if result == 0:
    return -4

  ## Test for future which cannot be completed in timeout period
  result = 0
  try:
    var res = await wait(testFuture1(), 50)
  except AsyncTimeoutError:
    result = 5

  if result == 0:
    return -5

  ## Test for future which will be completed before timeout exceeded.
  try:
    var res = await wait(testFuture1(), 300)
    result = 6
  except:
    result = -6

proc test1(): bool =
  var fut = testFuture1()
  poll()
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

when isMainModule:
  suite "Future[T] behavior test suite":
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

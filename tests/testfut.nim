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

proc testAllVarargs(): int =
  var completedFutures = 0

  proc client1() {.async.} =
    await sleepAsync(100)
    inc(completedFutures)

  proc client2() {.async.} =
    await sleepAsync(200)
    inc(completedFutures)

  proc client3() {.async.} =
    await sleepAsync(300)
    inc(completedFutures)

  proc client4() {.async.} =
    await sleepAsync(400)
    inc(completedFutures)

  proc client5() {.async.} =
    await sleepAsync(500)
    inc(completedFutures)

  proc client1f() {.async.} =
    await sleepAsync(100)
    inc(completedFutures)
    if true:
      raise newException(ValueError, "")

  proc client2f() {.async.} =
    await sleepAsync(200)
    inc(completedFutures)
    if true:
      raise newException(ValueError, "")

  proc client3f() {.async.} =
    await sleepAsync(300)
    inc(completedFutures)
    if true:
      raise newException(ValueError, "")

  proc client4f() {.async.} =
    await sleepAsync(400)
    inc(completedFutures)
    if true:
      raise newException(ValueError, "")

  proc client5f() {.async.} =
    await sleepAsync(500)
    inc(completedFutures)
    if true:
      raise newException(ValueError, "")

  waitFor(all(client1(), client1f(),
              client2(), client2f(),
              client3(), client3f(),
              client4(), client4f(),
              client5(), client5f()))
  result = completedFutures

proc testAllSeq(): int =
  var completedFutures = 0

  proc client1() {.async.} =
    await sleepAsync(100)
    inc(completedFutures)

  proc client2() {.async.} =
    await sleepAsync(200)
    inc(completedFutures)

  proc client3() {.async.} =
    await sleepAsync(300)
    inc(completedFutures)

  proc client4() {.async.} =
    await sleepAsync(400)
    inc(completedFutures)

  proc client5() {.async.} =
    await sleepAsync(500)
    inc(completedFutures)

  proc client1f() {.async.} =
    await sleepAsync(100)
    inc(completedFutures)
    if true:
      raise newException(ValueError, "")

  proc client2f() {.async.} =
    await sleepAsync(200)
    inc(completedFutures)
    if true:
      raise newException(ValueError, "")

  proc client3f() {.async.} =
    await sleepAsync(300)
    inc(completedFutures)
    if true:
      raise newException(ValueError, "")

  proc client4f() {.async.} =
    await sleepAsync(400)
    inc(completedFutures)
    if true:
      raise newException(ValueError, "")

  proc client5f() {.async.} =
    await sleepAsync(500)
    inc(completedFutures)
    if true:
      raise newException(ValueError, "")

  var futures = newSeq[Future[void]]()
  for i in 0..<100:
    futures.add(client1())
    futures.add(client1f())
    futures.add(client2())
    futures.add(client2f())
    futures.add(client3())
    futures.add(client3f())
    futures.add(client4())
    futures.add(client4f())
    futures.add(client5())
    futures.add(client5f())
  waitFor(all(futures))
  result = completedFutures

proc testAsyncIgnore(): int =
  var completedFutures = 0

  proc client1() {.async.} =
    await sleepAsync(100)
    inc(completedFutures)

  proc client2() {.async.} =
    await sleepAsync(200)
    inc(completedFutures)

  proc client3() {.async.} =
    await sleepAsync(300)
    inc(completedFutures)

  proc client4() {.async.} =
    await sleepAsync(400)
    inc(completedFutures)

  proc client5() {.async.} =
    await sleepAsync(500)
    inc(completedFutures)

  proc client1f() {.async.} =
    await sleepAsync(100)
    inc(completedFutures)
    if true:
      raise newException(ValueError, "")

  proc client2f() {.async.} =
    await sleepAsync(200)
    inc(completedFutures)
    if true:
      raise newException(ValueError, "")

  proc client3f() {.async.} =
    await sleepAsync(300)
    inc(completedFutures)
    if true:
      raise newException(ValueError, "")

  proc client4f() {.async.} =
    await sleepAsync(400)
    inc(completedFutures)
    if true:
      raise newException(ValueError, "")

  proc client5f() {.async.} =
    await sleepAsync(500)
    inc(completedFutures)
    if true:
      raise newException(ValueError, "")

  for i in 0..<1000:
    asyncIgnore client1()
    asyncIgnore client1f()
    asyncIgnore client2()
    asyncIgnore client2f()
    asyncIgnore client3()
    asyncIgnore client3f()
    asyncIgnore client4()
    asyncIgnore client4f()
    asyncIgnore client5()
    asyncIgnore client5f()

  waitFor(sleepAsync(2000))
  result = completedFutures

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
    test "all[T](varargs) test":
      check testAllVarargs() == 10
    test "all[T](seq) test":
      check testAllSeq() == 1000
    test "asyncIgnore() test":
      check testAsyncIgnore() == 10000

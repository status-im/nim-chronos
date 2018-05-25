#              Asyncdispatch2 Test Suite
#                 (c) Copyright 2018
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

import unittest
import ../asyncdispatch2

when defined(vcc):
  {.passC: "/Zi /FS".}

proc testFuture1(): Future[int] {.async.} =
  await sleepAsync(100)

proc testFuture2(): Future[int] {.async.} =
  return 1

proc testFuture3(): Future[int] {.async.} = 
  result = await testFuture2()

proc test1(): bool =
  var fut = testFuture1()
  poll()
  poll()
  result = fut.finished

proc test2(): bool =
  var fut = testFuture3()
  result = fut.finished

when isMainModule:
  suite "Future[T] behavior test suite":
    test "`Async undefined behavior (#7758)` test":
      check test1() == true
    test "Immediately completed asynchronous procedure test":
      check test2() == true

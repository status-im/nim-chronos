import unittest2

import ../chronos

proc completeOnReturn(fut: FutureVar[string], x: bool) {.async.} =
  if x:
    fut.mget() = ""
    fut.mget.add("foobar")
    return

proc completeOnImplicitReturn(fut: FutureVar[string], x: bool) {.async.} =
  if x:
    fut.mget() = ""
    fut.mget.add("foobar")

proc failureTest(fut: FutureVar[string], x: bool) {.async.} =
  if x:
    raise newException(Exception, "Test")

proc manualComplete(fut: FutureVar[string], x: bool) {.async.} =
  if x:
    fut.complete("Hello world")
    return

suite "FutureVar test suite":
  test "Nim test suite":
    proc main() {.async.} =
      var fut: FutureVar[string]

      fut = newFutureVar[string]()
      await completeOnReturn(fut, true)
      check fut.read() == "foobar"

      fut = newFutureVar[string]()
      await completeOnImplicitReturn(fut, true)
      check fut.read() == "foobar"

      fut = newFutureVar[string]()
      let retFut = failureTest(fut, true)
      yield retFut
      check fut.read().len == 0
      check fut.finished

      fut = newFutureVar[string]()
      await manualComplete(fut, true)
      check fut.read() == "Hello World"
    waitFor(main())

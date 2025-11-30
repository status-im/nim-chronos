#                Chronos Test Suite
#            (c) Copyright 2018-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

{.used.}

import std/[strscans, strutils]
import ../chronos

proc stripped(content: string): string =
  proc keepLastPart(s: var string, c: char) =
    if c in {'/', '\\'}:
      s.setLen 0
    elif c in "1234567890":
      discard
    else:
      s.add c

  result = ""
  var idx = 0
  while true:
    var entry = ""
    if scanp(content, idx, +((~{'\n', '\0'}) -> entry.keepLastPart($_)), '\n'):
      result.add entry
      result.add '\n'
    else:
      break

proc err() =
  raise newException(ValueError, "the_error_msg")

template test(name: string, body: untyped): untyped =
  block:
    echo "[", name, ": OK]"
    body

const hasStackTrace = compileOption("stacktrace")

test "recursion":
  proc recursion(i: int) {.async.} =
    if i == 5:
      err()
    await sleepAsync(100.milliseconds)
    await recursion(i + 1)

  proc main() {.async.} =
    await recursion(0)

  try:
    waitFor main()
    doAssert false
  except ValueError as err:
    let expected =
      when hasStackTrace:
        """
        testasyncstacktrace.nim() testasyncstacktrace
        testasyncstacktrace.nim() main
        testasyncstacktrace.nim() recursion
        testasyncstacktrace.nim() recursion
        testasyncstacktrace.nim() err
        """.dedent
      else:
        """
        testasyncstacktrace.nim() err
        testasyncstacktrace.nim() recursion
        testasyncstacktrace.nim() main
        """.dedent
    doAssert err.getAsyncStackTrace().stripped == expected,
      err.getAsyncStackTrace().stripped

test "simple":
  proc baz() =
    err()

  proc bar() =
    baz()

  proc foo() {.async.} =
    await sleepAsync(100.milliseconds)
    bar()

  proc main() {.async.} =
    await foo()

  try:
    waitFor main()
    doAssert false
  except ValueError as err:
    let expected =
      when hasStackTrace:
        """
        testasyncstacktrace.nim() testasyncstacktrace
        testasyncstacktrace.nim() main
        testasyncstacktrace.nim() foo
        testasyncstacktrace.nim() bar
        testasyncstacktrace.nim() baz
        testasyncstacktrace.nim() err
        """.dedent
      else:
        """
        testasyncstacktrace.nim() err
        testasyncstacktrace.nim() main
        """.dedent
    doAssert err.getAsyncStackTrace().stripped == expected,
      err.getAsyncStackTrace().stripped

test "async work":
  proc baz() {.async.} =
    await sleepAsync(100.milliseconds)
    raise newException(ValueError, "the_error_msg")

  proc bar() {.async.} =
    await sleepAsync(100.milliseconds)
    await baz()

  proc foo() {.async.} =
    await sleepAsync(100.milliseconds)
    await bar()

  proc main() {.async.} =
    await foo()

  try:
    waitFor main()
    doAssert false
  except ValueError as err:
    let expected =
      when hasStackTrace:
        """
        testasyncstacktrace.nim() testasyncstacktrace
        testasyncstacktrace.nim() main
        testasyncstacktrace.nim() foo
        testasyncstacktrace.nim() bar
        testasyncstacktrace.nim() baz
        """.dedent
      else:
        """
        testasyncstacktrace.nim() baz
        testasyncstacktrace.nim() bar
        testasyncstacktrace.nim() foo
        testasyncstacktrace.nim() main
        """.dedent
    doAssert err.getAsyncStackTrace().stripped == expected,
      err.getAsyncStackTrace().stripped

test "interleaved async work":
  proc baz() {.async.} =
    await sleepAsync(100.milliseconds)
    raise newException(ValueError, "the_error_msg")

  proc bar() {.async.} =
    #await sleepAsync(100.milliseconds)
    await baz()

  proc foo() {.async.} =
    await sleepAsync(100.milliseconds)
    await bar()

  proc main() {.async.} =
    await foo()

  try:
    waitFor main()
    doAssert false
  except ValueError as err:
    let expected =
      when hasStackTrace:
        """
        testasyncstacktrace.nim() testasyncstacktrace
        testasyncstacktrace.nim() main
        testasyncstacktrace.nim() foo
        testasyncstacktrace.nim() bar
        testasyncstacktrace.nim() baz
        """.dedent
      else:
        """
        testasyncstacktrace.nim() baz
        testasyncstacktrace.nim() bar
        testasyncstacktrace.nim() foo
        testasyncstacktrace.nim() main
        """.dedent
    doAssert err.getAsyncStackTrace().stripped == expected,
      err.getAsyncStackTrace().stripped

test "no async work":
  proc baz() {.async.} =
    raise newException(ValueError, "the_error_msg")

  proc bar() {.async.} =
    await baz()

  proc foo() {.async.} =
    await bar()

  proc main() {.async.} =
    await foo()

  try:
    waitFor main()
    doAssert false
  except ValueError as err:
    poll()
    let expected =
      when hasStackTrace:
        """
        testasyncstacktrace.nim() testasyncstacktrace
        testasyncstacktrace.nim() main
        testasyncstacktrace.nim() foo
        testasyncstacktrace.nim() bar
        testasyncstacktrace.nim() baz
        """.dedent
      else:
        """
        testasyncstacktrace.nim() baz
        testasyncstacktrace.nim() bar
        testasyncstacktrace.nim() foo
        testasyncstacktrace.nim() main
        """.dedent
    doAssert err.getAsyncStackTrace().stripped == expected,
      err.getAsyncStackTrace().stripped

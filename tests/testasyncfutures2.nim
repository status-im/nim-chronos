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

suite "Async Future test suite":
  test "finishWith should complete the future with value":
    let f1 = newFuture[string]()
    let f2 = newFuture[string]()

    f1.finishWith(f2)

    f2.complete("value")
    check (waitFor f1) == "value"

  test "finishWith should fail the future with error":
    let f1 = newFuture[string]()
    let f2 = newFuture[string]()

    f1.finishWith(f2)
    f2.fail(newException(CatchableError, "error"))

    expect CatchableError:
      discard waitFor f1


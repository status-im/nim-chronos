#                Chronos Test Suite
#            (c) Copyright 2022-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)
import unittest2
import ../chronos

when defined(nimHasUsed): {.used.}

suite "Dispatcher closing":
  test "Can close the current dispatcher":
    waitFor(sleepAsync(1.milliseconds))
    check isNil(getThreadDispatcher()) == false
    let beforeClose = getThreadDispatcher()
    closeThreadDispatcher()
    waitFor(sleepAsync(1.milliseconds))
    check:
      isNil(getThreadDispatcher()) == false
      getThreadDispatcher() != beforeClose

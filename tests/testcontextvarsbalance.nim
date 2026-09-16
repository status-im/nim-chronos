#                Chronos Test Suite
#            (c) Copyright 2018-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

## Suite-final contextvars binder-balance check, split out of
## testutils.nim so it runs on every engine — testutils.nim itself is
## only imported when `chronosEventEngine` is epoll/kqueue/windows
## (see testall.nim), which skips the `poll` engine entirely. Imported
## unconditionally, last, in testall.nim.

import unittest2
import ../chronos/contextvars

{.used.}

suite "contextvars: suite-final binder balance":

  test "contextvars binder balance (no leaked bindings)":
    when defined(chronosDebug):
      # `withValue` increments `chainBalance` at push, decrements at
      # pop. A nonzero count at suite end means some `withValue` pushed
      # a chain node without popping.
      check chainBalance == 0
      # Chain must also be empty at top-level (no test left a leaked
      # binding in `currentAsyncContext`).
      check chainLen() == 0
    else:
      skip()

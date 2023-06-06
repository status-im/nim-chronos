#                Chronos Test Suite
#            (c) Copyright 2018-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

{.used.}

import unittest2
import ../chronos/futures

suite "Futures":
  test "Future constructors":
    let
      completed = Future.completed(42)
      failed = Future[int].failed((ref ValueError)(msg: "msg"))
      cancelled = Future[int].cancelled()

    check:
      completed.value == 42
      completed.state == FutureState.Completed

    check:
      failed.error of ValueError
      failed.state == FutureState.Failed

    check:
      cancelled.error of CancelledError
      cancelled.state == FutureState.Cancelled

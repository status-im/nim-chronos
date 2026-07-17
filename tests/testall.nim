#                Chronos Test Suite
#            (c) Copyright 2018-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

import ../chronos/config

import
  ./[
    testmacro, testsync, testsoon, testtime, testfut, testaddress,
    testdatagram, teststream, testserver, testbugs, testnet, testasyncstream,
    testhttpserver, testshttpserver, testhttpclient, testratelimit,
    testfutures, testthreadsync, testasyncsemaphore,
  ]

when (chronosEventEngine in ["epoll", "kqueue"]) or defined(windows):
  # `poll` engine does not support signals and processes.
  import testsignal

  # Mobile test binaries cannot execute the host-side helper scripts used by
  # the process tests.
  when not (defined(android) or defined(ios)):
    import testproc

  # Must be imported last to check for Pending futures
  import testutils

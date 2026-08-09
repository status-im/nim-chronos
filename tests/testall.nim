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
    testmacro, testsync, testsoon, testtime, testfut, testaddress, testdatagram,
    teststream, testserver, testbugs, testnet, testasyncstream, testhttpserver,
    testshttpserver, testhttpclient, testratelimit, testfutures, testthreadsync,
    testasyncsemaphore, testmpsc, testcallbackqueue,
  ]

import
  ./[testcontextvarsasync, testcontextvarsguardrails,
     testcontextvarssurface, testcontextvarsexport, testcontextvars]
  # Import order among these five is not load-bearing: the one-way
  # chronosDebug construction lock lives in its own file
  # (tests/testcontextvarslock.nim, its own step in chronos.nimble's
  # test task), never imported here.

when (chronosEventEngine in ["epoll", "kqueue"]) or defined(windows):
  # `poll` engine do not support signals and processes
  import ./[testsignal, testproc]

  # Must be imported last to check for Pending futures
  import testutils

# Unconditional (unlike testutils above, which the `poll` engine never
# imports): the contextvars binder-balance check must run on every
# engine, so it lives in its own file, imported last.
import testcontextvarsbalance

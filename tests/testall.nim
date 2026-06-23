#                Chronos Test Suite
#            (c) Copyright 2018-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)
import ".."/chronos/config

when chronosEventEngine != "" or defined(windows):
  import testmacro, testsync, testsoon, testunwind, testtime, testfut,
         testaddress, testdatagram, teststream, testserver, testbugs, testnet,
         testasyncstream, testhttpserver, testshttpserver, testhttpclient,
         testratelimit, testfutures, testthreadsync, testasyncsemaphore

  when chronosEventEngine != "poll" or defined(windows):
    # `poll` engine do not support signals and processes
    import testsignal, testproc

# Must be imported last to check for Pending futures
import testutils

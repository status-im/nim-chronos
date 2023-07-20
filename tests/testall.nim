#                Chronos Test Suite
#            (c) Copyright 2018-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)
const
  asyncEventEngine {.strdefine.} =
    when defined(linux):
      "epoll"
    elif defined(macosx) or defined(macos) or defined(ios) or
         defined(freebsd) or defined(netbsd) or defined(openbsd) or
         defined(dragonfly):
      "kqueue"
    elif defined(posix):
      "poll"
    else:
      ""

when (asyncEventEngine in ["epoll", "kqueue"]) or defined(windows):
  import testmacro, testsync, testsoon, testtime, testfut, testsignal,
         testaddress, testdatagram, teststream, testserver, testbugs, testnet,
         testasyncstream, testhttpserver, testshttpserver, testhttpclient,
         testproc, testratelimit, testfutures, testthreadsync

  # Must be imported last to check for Pending futures
  import testutils
elif asyncEventEngine == "poll":
  # `poll` engine do not support signals and processes
  import testmacro, testsync, testsoon, testtime, testfut, testaddress,
         testdatagram, teststream, testserver, testbugs, testnet,
         testasyncstream, testhttpserver, testshttpserver, testhttpclient,
         testratelimit, testfutures, testthreadsync

  # Must be imported last to check for Pending futures
  import testutils

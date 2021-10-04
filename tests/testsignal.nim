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

when not defined(windows):
  import posix

suite "Signal handling test suite":
  when not defined(windows):
    var signalCounter = 0

    proc signalProc(udata: pointer) =
      var cdata = cast[ptr CompletionData](udata)
      signalCounter = cast[int](cdata.udata)
      try:
        removeSignal(int(cdata.fd))
      except Exception as exc:
        raiseAssert exc.msg

    proc asyncProc() {.async.} =
      await sleepAsync(500.milliseconds)

    proc test(signal, value: int): bool =
      try:
        discard addSignal(signal, signalProc, cast[pointer](value))
      except Exception as exc:
        raiseAssert exc.msg
      var fut = asyncProc()
      discard posix.kill(posix.getpid(), cint(signal))
      waitFor(fut)
      signalCounter == value
  else:
    const
      SIGINT = 0
      SIGTERM = 0
    proc test(signal, value: int): bool = true

  test "SIGINT test":
    check test(SIGINT, 31337) == true
  test "SIGTERM test":
    check test(SIGTERM, 65537) == true

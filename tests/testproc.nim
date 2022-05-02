#                Chronos Test Suite
#            (c) Copyright 2022-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)
import unittest2, stew/base10
import ".."/chronos
import testhelpers

when defined(nimHasUsed): {.used.}

suite "Asynchronous process management test suite":
  asyncTest "Exit code tests":
    const ExitCodes = [5, 13, 64, 100, 126, 127, 128, 130, 255]

    for item in ExitCodes:
      let command = "exit " & Base10.toString(uint64(item))
      let res = await execCommand(command)
      check res == item

  asyncTest "Spawn sleeping processes test":
    discard
  asyncTest "Process termination test":
    discard

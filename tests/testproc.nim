#                Chronos Test Suite
#            (c) Copyright 2022-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)
import unittest2, stew/[base10, byteutils]
import ".."/chronos
import testhelpers

when defined(nimHasUsed): {.used.}

suite "Asynchronous process management test suite":
  const OutputTests =
    when defined(windows):
      [
        ("ECHO TESTOUT", "TESTOUT\r\n", ""),
        ("ECHO TESTERR 1>&2", "", "TESTERR \r\n"),
        ("ECHO TESTBOTH && ECHO TESTBOTH 1>&2", "TESTBOTH \r\n",
         "TESTBOTH \r\n")
      ]
    else:
      [
        ("echo TESTOUT", "TESTOUT\n", ""),
        ("echo TESTERR 1>&2", "", "TESTERR"),
        ("echo TESTBOTH && echo TESTBOTH 1>&2", "TESTBOTH", "TESTBOTH")
      ]

  const ExitCodes = [5, 13, 64, 100, 126, 127, 128, 130, 255]

  proc createBigMessage(size: int): seq[byte] =
    var message = "MESSAGE"
    result = newSeq[byte](size)
    for i in 0 ..< len(result):
      result[i] = byte(message[i mod len(message)])

  asyncTest "execCommand() exit codes test":
    for item in ExitCodes:
      let command = "exit " & Base10.toString(uint64(item))
      let res = await execCommand(command)
      check res == item

  asyncTest "waitForExit() & peekExitCode() exit codes test":
    let options = {AsyncProcessOption.EvalCommand}
    for item in ExitCodes:
      let command = "exit " & Base10.toString(uint64(item))
      let process = await startProcess(command, options = options)
      try:
        let res = await process.waitForExit(InfiniteDuration)
        check:
          res == item
          process.peekExitCode().tryGet() == item
          process.running().tryGet() == false
      finally:
        await process.closeWait()

  asyncTest "STDIN stream test":
    let
      command =
        when defined(windows):
          "tests\\testproc.bat STDIN"
        else:
          "tests/testproc.sh"
      options = {AsyncProcessOption.EvalCommand}
      shellHeader = "STDIN DATA: ".toBytes()
      smallTest =
        when defined(windows):
          "SMALL AMOUNT\r\n".toBytes()
        else:
          "SMALL AMOUNT\n".toBytes()

    var bigTest =
      when defined(windows):
        var res = createBigMessage(256)
        res.add(byte(0x0D))
        res.add(byte(0x0A))
        res
      else:
        var res = createBigMessage(256)
        res.add(byte(0x0A))
        res

    for item in [smallTest, bigTest]:
      let process = await startProcess(command, options = options)
      try:
        await process.stdinStream.write(item)
        let stdoutData = await process.stdoutStream.read()
        check stdoutData == shellHeader & item
      finally:
        await process.closeWait()

  asyncTest "STDOUT and STDERR streams test":
    let options = {AsyncProcessOption.EvalCommand}

    for test in OutputTests:
      let process = await startProcess(test[0], options = options)
      try:
        let outBytes = await process.stdoutStream.read()
        let errBytes = await process.stderrStream.read()
        check:
          string.fromBytes(outBytes) == test[1]
          string.fromBytes(errBytes) == test[2]
      finally:
        await process.closeWait()

  asyncTest "Long-waiting waitForExit() test":
    let command =
      when defined(windows):
        ("tests\\testproc.bat", "timeout2")
      else:
        ("tests/testproc.sh", "timeout2")
    let process = await startProcess(command[0], arguments = @[command[1]])
    try:
      let res = await process.waitForExit(InfiniteDuration)
      check res == 2
    finally:
      await process.closeWait()

  asyncTest "waitForExit(duration) test":
    let command =
      when defined(windows):
        ("tests\\testproc.bat", "stdin")
      else:
        ("tests/testproc.sh", "stdin")
    let process = await startProcess(command[0], arguments = @[command[1]])
    try:
      let res = await process.waitForExit(1.seconds)
      check res == 0
    finally:
      await process.closeWait()

  asyncTest "terminate() test":
    let command =
      when defined(windows):
        ("tests\\testproc.bat", "timeout10")
      else:
        ("tests/testproc.sh", "timeout10")
    let process = await startProcess(command[0], arguments = @[command[1]])
    try:
      check process.terminate().isOk()
      let res = await process.waitForExit(InfiniteDuration)
      check res == 0
    finally:
      await process.closeWait()

  asyncTest "kill() test":
    let command =
      when defined(windows):
        ("tests\\testproc.bat", "timeout10")
      else:
        ("tests/testproc.sh", "timeout10")
    let process = await startProcess(command[0], arguments = @[command[1]])
    try:
      check process.kill().isOk()
      let res = await process.waitForExit(InfiniteDuration)
      check res == 0
    finally:
      await process.closeWait()

  asyncTest "execCommandEx() exit codes and outputs test":
    for test in OutputTests:
      let response = await execCommandEx(test[0])
      check:
        response.stdOutput == test[1]
        response.stdError == test[2]
        response.status == 0

  test "getProcessEnvironment() test":
    let env = getProcessEnvironment()
    when defined(windows):
      check len(env["SYSTEMROOT"]) > 0
    else:
      discard

  test "Leaks test":
    proc getTrackerLeaks(tracker: string): bool =
      let tracker = getTracker(tracker)
      if isNil(tracker): false else: tracker.isLeaked()

    check:
      getTrackerLeaks("async.process") == false
      getTrackerLeaks("async.stream.reader") == false
      getTrackerLeaks("async.stream.writer") == false
      getTrackerLeaks("stream.transport") == false

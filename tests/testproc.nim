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

when defined(posix):
  from ".."/chronos/osdefs import SIGTERM

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
        ("echo TESTERR 1>&2", "", "TESTERR\n"),
        ("echo TESTBOTH && echo TESTBOTH 1>&2", "TESTBOTH\n", "TESTBOTH\n")
      ]

  const ExitCodes = [5, 13, 64, 100, 126, 127, 128, 130, 255]

  proc createBigMessage(size: int): seq[byte] =
    var message = "MESSAGE"
    result = newSeq[byte](size)
    for i in 0 ..< len(result):
      result[i] = byte(message[i mod len(message)])

  when not(defined(windows)):
    proc getCurrentFD(): int =
      let local = initTAddress("127.0.0.1:34334")
      let sock = createAsyncSocket(local.getDomain(), SockType.SOCK_DGRAM,
                                   Protocol.IPPROTO_UDP)
      closeSocket(sock)
      return int(sock)
    var markFD = getCurrentFD()

  asyncTest "execCommand() exit codes test":
    for item in ExitCodes:
      let command = "exit " & Base10.toString(uint64(item))
      let res = await execCommand(command)
      check res == item

  asyncTest "execCommandEx() exit codes and outputs test":
    for test in OutputTests:
      let response = await execCommandEx(test[0])
      check:
        response.stdOutput == test[1]
        response.stdError == test[2]
        response.status == 0

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
          "tests\\testproc.bat stdin"
        else:
          "tests/testproc.sh stdin"
      options = {AsyncProcessOption.EvalCommand}
      shellHeader = "STDIN DATA: ".toBytes()
      smallTest =
        when defined(windows):
          "SMALL AMOUNT\r\n".toBytes()
        else:
          "SMALL AMOUNT\n".toBytes()

    let bigTest =
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
      let process = await startProcess(command, options = options,
                                       stdinHandle = AsyncProcess.Pipe,
                                       stdoutHandle = AsyncProcess.Pipe)
      try:
        await process.stdinStream.write(item)
        let stdoutDataFut = process.stdoutStream.read()
        let res = await process.waitForExit(InfiniteDuration)
        await allFutures(stdoutDataFut)
        check:
          res == 0
          stdoutDataFut.read() == shellHeader & item
      finally:
        await process.closeWait()

  asyncTest "STDOUT and STDERR streams test":
    let options = {AsyncProcessOption.EvalCommand}

    for test in OutputTests:
      let process = await startProcess(test[0], options = options,
                                       stdoutHandle = AsyncProcess.Pipe,
                                       stderrHandle = AsyncProcess.Pipe)
      try:
        let outBytesFut = process.stdoutStream.read()
        let errBytesFut = process.stderrStream.read()
        let res = await process.waitForExit(InfiniteDuration)
        await allFutures(outBytesFut, errBytesFut)
        check:
          string.fromBytes(outBytesFut.read()) == test[1]
          string.fromBytes(errBytesFut.read()) == test[2]
          res == 0
      finally:
        await process.closeWait()

  asyncTest "STDERR to STDOUT streams test":
    let options = {AsyncProcessOption.EvalCommand,
                   AsyncProcessOption.StdErrToStdOut}
    let command =
      when defined(windows):
        "ECHO TESTSTDOUT && ECHO TESTSTDERR 1>&2"
      else:
        "echo TESTSTDOUT && echo TESTSTDERR 1>&2"
    let expect =
      when defined(windows):
        "TESTSTDOUT \r\nTESTSTDERR \r\n"
      else:
        "TESTSTDOUT\nTESTSTDERR\n"
    let process = await startProcess(command, options = options,
                                     stdoutHandle = AsyncProcess.Pipe)
    try:
      let outBytesFut = process.stdoutStream.read()
      let res = await process.waitForExit(InfiniteDuration)
      await allFutures(outBytesFut)
      check:
        string.fromBytes(outBytesFut.read()) == expect
        res == 0
    finally:
      await process.closeWait()

  asyncTest "CAPTURE BIG DATA STDOUT stream test":
    let options = {AsyncProcessOption.EvalCommand}
    let command =
      when defined(windows):
        "tests\\testproc.bat bigdata"
      else:
        "tests/testproc.sh bigdata"
    let expect =
      when defined(windows):
        400_000 * (64 + 2)
      else:
        400_000 * (64 + 1)
    let process = await startProcess(command, options = options,
                                     stdoutHandle = AsyncProcess.Pipe,
                                     stderrHandle = AsyncProcess.Pipe)
    try:
      let outBytesFut = process.stdoutStream.read()
      let errBytesFut = process.stderrStream.read()
      let res = await process.waitForExit(InfiniteDuration)
      await allFutures(outBytesFut, errBytesFut)
      check:
        res == 0
        len(outBytesFut.read()) == expect
        len(errBytesFut.read()) == 0
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
    let expect =
      when defined(windows):
        0
      else:
        128 + int(SIGTERM)
    let process = await startProcess(command[0], arguments = @[command[1]])
    try:
      let res = await process.waitForExit(1.seconds)
      check res == expect
    finally:
      await process.closeWait()

  asyncTest "terminate() test":
    let command =
      when defined(windows):
        ("tests\\testproc.bat", "timeout10", 0)
      else:
        ("tests/testproc.sh", "timeout10", 143) # 128 + SIGTERM
    let process = await startProcess(command[0], arguments = @[command[1]])
    try:
      check process.terminate().isOk()
      let res = await process.waitForExit(InfiniteDuration)
      check res == command[2]
    finally:
      await process.closeWait()

  asyncTest "kill() test":
    let command =
      when defined(windows):
        ("tests\\testproc.bat", "timeout10", 0)
      else:
        ("tests/testproc.sh", "timeout10", 137) # 128 + SIGKILL
    let process = await startProcess(command[0], arguments = @[command[1]])
    try:
      check process.kill().isOk()
      let res = await process.waitForExit(InfiniteDuration)
      check res == command[2]
    finally:
      await process.closeWait()

  test "getProcessEnvironment() test":
    let env = getProcessEnvironment()
    when defined(windows):
      check len(env["SYSTEMROOT"]) > 0
    else:
      check len(env["SHELL"]) > 0

  test "File descriptors leaks test":
    when defined(windows):
      skip()
    else:
      check getCurrentFD() == markFD

  test "Leaks test":
    proc getTrackerLeaks(tracker: string): bool =
      let tracker = getTracker(tracker)
      if isNil(tracker): false else: tracker.isLeaked()

    check:
      getTrackerLeaks("async.process") == false
      getTrackerLeaks("async.stream.reader") == false
      getTrackerLeaks("async.stream.writer") == false
      getTrackerLeaks("stream.transport") == false

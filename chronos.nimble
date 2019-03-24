packageName   = "chronos"
version       = "2.2.2"
author        = "Status Research & Development GmbH"
description   = "Chronos"
license       = "Apache License 2.0 or MIT"
skipDirs      = @["tests"]

### Dependencies

requires "nim > 0.18.0"

import ospaths

task test, "Run all tests":

  var testFiles = @[
    "testsync",
    "testsoon",
    "testtime",
    "testfut",
    "testsignal",
    "testaddress",
    "testdatagram",
    "teststream",
    "testserver",
    "testbugs",
  ]

  var testCommands = @[
    "nim c -r -d:useSysAssert -d:useGcAssert",
    "nim c -r",
    "nim c -r -d:release"
  ]

  var timerCommands = @[
    " -d:asyncTimer=system",
    " -d:asyncTimer=mono"
  ]

  for tfile in testFiles:
    if tfile == "testtime":
      for cmd in testCommands:
        for def in timerCommands:
          var commandLine = (cmd & def & " tests") / tfile
          echo "\n" & commandLine
          exec commandLine
          rmFile("tests" / tfile.toExe())
    else:
      for cmd in testCommands:
        var commandLine = (cmd & " tests") / tfile
        echo "\n" & commandLine
        exec commandLine
        rmFile("tests" / tfile.toExe())

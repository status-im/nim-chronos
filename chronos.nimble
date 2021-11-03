packageName   = "chronos"
version       = "3.0.6"
author        = "Status Research & Development GmbH"
description   = "Chronos"
license       = "Apache License 2.0 or MIT"
skipDirs      = @["tests"]

### Dependencies

requires "nim > 1.2.0",
         "stew",
         "bearssl",
         "httputils",
         "https://github.com/status-im/nim-unittest2.git#head"

var commandStart = "nim c -r --hints:off --verbosity:0 --skipParentCfg:on --warning[ObservableStores]:off"

task test, "Run all tests":
  var commands = @[
      commandStart & " -d:useSysAssert -d:useGcAssert tests/",
      commandStart & " -d:chronosStackTrace -d:chronosStrictException tests/",
      commandStart & " -d:release tests/",
      commandStart & " -d:release -d:chronosFutureTracking tests/",
      commandStart & " -d:release --debugger:native -d:chronosStackTrace -d:nimStackTraceOverride --import:libbacktrace tests/",
    ]
  when (NimMajor, NimMinor) >= (1, 5):
    commands.add commandStart & " --gc:orc -d:chronosFutureTracking -d:release -d:chronosStackTrace tests/"

  for testname in ["testall"]:
    for cmd in commands:
      let curcmd = cmd & testname
      echo "\n" & curcmd
      exec curcmd
      rmFile "tests/" & testname

task test_libbacktrace, "test with libbacktrace":
  var commands = @[
      commandStart & " -d:release --debugger:native -d:chronosStackTrace -d:nimStackTraceOverride --import:libbacktrace tests/",
    ]

  for testname in ["testall"]:
    for cmd in commands:
      let curcmd = cmd & testname
      echo "\n" & curcmd
      exec curcmd
      rmFile "tests/" & testname

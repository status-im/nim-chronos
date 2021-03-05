packageName   = "chronos"
version       = "2.6.1"
author        = "Status Research & Development GmbH"
description   = "Chronos"
license       = "Apache License 2.0 or MIT"
skipDirs      = @["tests"]

### Dependencies

requires "nim > 1.2.0",
         "stew",
         "bearssl",
         "httputils"

task test, "Run all tests":
  var commands = @[
    "nim c -r -d:useSysAssert -d:useGcAssert tests/",
    "nim c -r -d:chronosStackTrace tests/",
    "nim c -r -d:release tests/",
    "nim c -r -d:release -d:chronosFutureTracking tests/"
  ]
  when (NimMajor, NimMinor) >= (1, 5):
    commands.add "nim c -r --gc:orc -d:chronosFutureTracking -d:release -d:chronosStackTrace tests/"

  for testname in ["testall"]:
    for cmd in commands:
      let curcmd = cmd & testname
      echo "\n" & curcmd
      exec curcmd

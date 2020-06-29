packageName   = "chronos"
version       = "2.4.1"
author        = "Status Research & Development GmbH"
description   = "Chronos"
license       = "Apache License 2.0 or MIT"
skipDirs      = @["tests"]

### Dependencies

requires "nim > 0.19.4",
         "bearssl"

task test, "Run all tests":
  var commands = [
    "nim c -r -d:useSysAssert -d:useGcAssert tests/",
    "nim c -r tests/",
    "nim c -r -d:release tests/"
  ]
  for testname in ["testall", "testutils"]:
    for cmd in commands:
      let curcmd = cmd & testname
      echo "\n" & curcmd
      exec curcmd

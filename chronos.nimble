packageName   = "chronos"
version       = "2.3.3"
author        = "Status Research & Development GmbH"
description   = "Chronos"
license       = "Apache License 2.0 or MIT"
skipDirs      = @["tests"]

### Dependencies

requires "nim > 0.19.4",
         "bearssl"

task test, "Run all tests":
  var commands = [
    "nim c -r -d:useSysAssert -d:useGcAssert tests/testall",
    "nim c -r tests/testall",
    "nim c -r -d:release tests/testall"
  ]
  echo "\n" & commands[0]
  exec commands[0]
  echo "\n" & commands[1]
  exec commands[1]
  echo "\n" & commands[2]
  exec commands[2]

packageName   = "asyncdispatch2"
version       = "0.1.0"
author        = "Status Research & Development GmbH"
description   = "Asyncdispatch2"
license       = "Apache License 2.0 or MIT"
skipDirs      = @["tests", "Nim", "nim"]

### Dependencies

requires "nim > 0.18.0"

task test, "Run all tests":
  exec "nim c -r tests/testdatagram"
  exec "nim c -r tests/teststream"

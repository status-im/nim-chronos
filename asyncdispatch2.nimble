packageName   = "asyncdispatch2"
version       = "2.0.1"
author        = "Status Research & Development GmbH"
description   = "Asyncdispatch2"
license       = "Apache License 2.0 or MIT"
skipDirs      = @["tests", "Nim", "nim"]

### Dependencies

requires "nim > 0.18.0"

task test, "Run all tests":
  exec "nim c -r -d:useSysAssert -d:useGcAssert tests/testsync"
  exec "nim c -r tests/testsync"
  exec "nim c -r -d:release tests/testsync"

  exec "nim c -r -d:useSysAssert -d:useGcAssert tests/testsoon"
  exec "nim c -r tests/testsoon"
  exec "nim c -r -d:release tests/testsoon"

  exec "nim c -r -d:useSysAssert -d:useGcAssert tests/testtime"
  exec "nim c -r tests/testtime"
  exec "nim c -r -d:release tests/testtime"

  exec "nim c -r -d:useSysAssert -d:useGcAssert tests/testdatagram"
  exec "nim c -r tests/testdatagram"
  exec "nim c -r -d:release tests/testdatagram"

  exec "nim c -r -d:useSysAssert -d:useGcAssert tests/teststream"
  exec "nim c -r tests/teststream"
  exec "nim c -r -d:release tests/teststream"

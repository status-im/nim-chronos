packageName   = "asyncdispatch2"
version       = "2.1.1"
author        = "Status Research & Development GmbH"
description   = "Asyncdispatch2"
license       = "Apache License 2.0 or MIT"
skipDirs      = @["tests", "Nim", "nim", "benchmarks"]

### Dependencies

requires "nim > 0.18.0"

task test, "Run all tests":
  exec "nim c -r -d:useSysAssert -d:useGcAssert tests/testsync"
  exec "nim c -r tests/testsync"
  exec "nim c -r --gc:markAndSweep tests/testsync"
  exec "nim c -r -d:release tests/testsync"


  exec "nim c -r -d:useSysAssert -d:useGcAssert tests/testsoon"
  exec "nim c -r tests/testsoon"
  exec "nim c -r --gc:markAndSweep tests/testsoon"
  exec "nim c -r -d:release tests/testsoon"

  exec "nim c -r -d:useSysAssert -d:useGcAssert tests/testtime"
  exec "nim c -r tests/testtime"
  exec "nim c -r --gc:markAndSweep tests/testtime"
  exec "nim c -r -d:release tests/testtime"

  exec "nim c -r -d:useSysAssert -d:useGcAssert tests/testfut"
  exec "nim c -r tests/testfut"
  exec "nim c -r --gc:markAndSweep tests/testfut"
  exec "nim c -r -d:release tests/testfut"

  exec "nim c -r -d:useSysAssert -d:useGcAssert tests/testsignal"
  exec "nim c -r tests/testsignal"
  exec "nim c -r --gc:markAndSweep tests/testsignal"
  exec "nim c -r -d:release tests/testsignal"

  exec "nim c -r -d:useSysAssert -d:useGcAssert tests/testaddress"
  exec "nim c -r tests/testaddress"
  exec "nim c -r --gc:markAndSweep tests/testaddress"
  exec "nim c -r -d:release tests/testaddress"

  exec "nim c -r -d:useSysAssert -d:useGcAssert tests/testdatagram"
  exec "nim c -r tests/testdatagram"
  exec "nim c -r --gc:markAndSweep tests/testdatagram"
  exec "nim c -r -d:release tests/testdatagram"

  exec "nim c -r -d:useSysAssert -d:useGcAssert tests/teststream"
  exec "nim c -r tests/teststream"
  exec "nim c -r --gc:markAndSweep tests/teststream"
  exec "nim c -r -d:release tests/teststream"

  exec "nim c -r -d:useSysAssert -d:useGcAssert tests/testserver"
  exec "nim c -r tests/testserver"
  exec "nim c -r --gc:markAndSweep tests/testserver"
  exec "nim c -r -d:release tests/testserver"

  exec "nim c -r -d:useSysAssert -d:useGcAssert tests/testbugs"
  exec "nim c -r tests/testbugs"
  exec "nim c -r --gc:markAndSweep tests/testbugs"
  exec "nim c -r -d:release tests/testbugs"

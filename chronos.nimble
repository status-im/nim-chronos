mode = ScriptMode.Verbose

packageName   = "chronos"
version       = "3.2.0"
author        = "Status Research & Development GmbH"
description   = "Networking framework with async/await support"
license       = "MIT or Apache License 2.0"
skipDirs      = @["tests"]

requires "nim >= 1.6.0",
         "stew",
         "bearssl",
         "httputils",
         "unittest2"

let nimc = getEnv("NIMC", "nim") # Which nim compiler to use
let lang = getEnv("NIMLANG", "c") # Which backend (c/cpp/js)
let flags = getEnv("NIMFLAGS", "") # Extra flags for the compiler
let verbose = getEnv("V", "") notin ["", "0"]
let testArguments =
  when defined(windows):
    [
      "-d:debug -d:chronosDebug -d:useSysAssert -d:useGcAssert",
      "-d:debug -d:chronosPreviewV4",
      "-d:release",
      "-d:release -d:chronosPreviewV4"
    ]
  else:
    [
      "-d:debug -d:chronosDebug -d:useSysAssert -d:useGcAssert",
      "-d:debug -d:chronosPreviewV4",
      "-d:debug -d:chronosDebug -d:chronosEventEngine=poll -d:useSysAssert -d:useGcAssert",
      "-d:release",
      "-d:release -d:chronosPreviewV4"
    ]

let styleCheckStyle = if (NimMajor, NimMinor) < (1, 6): "hint" else: "error"
let cfg =
  " --styleCheck:usages --styleCheck:" & styleCheckStyle &
  (if verbose: "" else: " --verbosity:0 --hints:off") &
  " --skipParentCfg --skipUserCfg --outdir:build --nimcache:build/nimcache -f"

proc build(args, path: string) =
  exec nimc & " " & lang & " " & cfg & " " & flags & " " & args & " " & path

proc run(args, path: string) =
  build args & " -r", path

task test, "Run all tests":
  for args in testArguments:
    run args, "tests/testall"
    if (NimMajor, NimMinor) > (1, 6):
      run args & " --mm:refc", "tests/testall"

task test_libbacktrace, "test with libbacktrace":
  var allArgs = @[
      "-d:release --debugger:native -d:chronosStackTrace -d:nimStackTraceOverride --import:libbacktrace",
    ]

  for args in allArgs:
    run args, "tests/testall"

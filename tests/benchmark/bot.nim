import osproc, json, streams, strutils, os

type
  Option = enum
    optNoDocker
    optNoThreads

  Options = set[Option]

const
  participants = ["fasthttp", "mofuw", "asyncnet", "asyncdispatch2", "libreactor", "actix-raw"]

proc execAndGetJson(command: string): JsonNode =
  const
    options = {poStdErrToStdOut, poUsePath, poEvalCommand}
  var p = startProcess(command, args=[], env=nil, options=options)
  var outp = outputStream(p)
  result = newJArray()
  var line = newStringOfCap(120)
  while true:
    # FIXME: converts CR-LF to LF.
    if outp.readLine(line):
      if line[0] == '{':
        let node = parseJson(line)
        result.add node
    elif not running(p): break
  close(p)

proc execSilent(command: string): int =
  const
    options = {poStdErrToStdOut, poUsePath, poEvalCommand}
  var p = startProcess(command, args=[], env=nil, options=options)
  var outp = outputStream(p)
  var line = newStringOfCap(120)
  while true:
    if outp.readLine(line): discard
    elif not running(p): break
  result = peekExitCode(p)
  close(p)

proc buildImage(name: string) =
  let cmd = "docker image build -t \"bench-$1:latest\" -f $1/plaintext.dockerfile $1/" % [name]
  let ret = execCmd(cmd)
  if ret != 0:
    raise newException(Exception, "cannot build image: " & name)

proc buildImages() =
  for c in participants:
    buildImage(c)

proc killContainer(id: string) =
  var ret = execSilent("docker kill " & id)
  if ret != 0:
    raise newException(Exception, "cannot kill container: " & id)

proc removeContainer(id: string) =
  var ret = execSilent("docker rm " & id)
  if ret != 0:
    raise newException(Exception, "cannot remove container: " & id)

proc killContainers() =
  let m = execAndGetJson("docker ps --format '{{json .}}'")
  for x in m:
    let ID = x["ID"]
    killContainer(ID.getStr())

proc removeContainers() =
  let m = execAndGetJson("docker ps -a --format '{{json .}}'")
  for x in m:
    let ID = x["ID"]
    removeContainer(ID.getStr())

proc buildExe(name: string) =
  let parentDir = getAppDir()
  let curDir = parentDir & DirSep & name
  setCurrentDir(curDir)
  if execCmd("sh build.sh") != 0:
    raise newException(Exception, "cannot build executable: " & name)
  setCurrentDir(parentDir)

proc buildExes() =
  for c in participants:
    buildExe(c)

proc runServer(id: string): Process =
  const options = {poParentStreams}
  let parentDir = getAppDir()
  let name = parentDir & DirSep & id & DirSep & "server"
  result = startProcess(name, args=[], env=nil, options=options)
  if not result.running():
    raise newException(Exception, "cannot run server: " & id)

proc stopServer(p: Process) =
  p.terminate()
  p.kill()
  discard p.waitForExit(1000)
  p.close()

const
  levels = [128, 256, 480]
  maxConcurrency = levels[^1]
  primer_duration = 5
  warmup_duration = 10
  concurrency_duration = 15
  pipeline_duration = 15
  sleep_duration = 1000
  serverHost = "bench-bot"
  url = "http://127.0.0.1:8080/plaintext"
  pipeline = 16
  accept = "text/plain,text/html;q=0.9,application/xhtml+xml;q=0.9,application/xml;q=0.8,*/*;q=0.7"

proc runTest(name: string, options: Options): JsonNode =
  let maxThreads = countProcessors()
  var cmd: string
  var ret: int
  var server: Process

  echo "** ", name, " **"

  if optNoDocker in options:
    server = runServer(name)
  else:
    let useTheadsFlag = if optNoThreads in options: ""
                        else: "-e USE_THREADS=1"
    cmd = "docker run -d -p 8080:8080 $1 bench-$2" % [useTheadsFlag, name]
    ret = execSilent(cmd)
    if ret != 0:
      raise newException(Exception, "cannot run image: " & name & " " & $ret)

  cmd = "./wrk -H \"Host: $1\" -H \"Accept: $2\" -H \"Connection: keep-alive\" --latency -d $3 -c 8 --timeout 8 -t 8 $4" %
    [serverHost, accept, $primer_duration, url]
  echo "  Running Primer"

  ret = execSilent(cmd)
  if ret != 0:
    raise newException(Exception, "cannot run primer: " & name)
  sleep(sleep_duration)

  cmd = "./wrk -H \"Host: $1\" -H \"Accept: $2\" -H \"Connection: keep-alive\" --latency -d $3 -c $4 --timeout 8 -t $5 $6" %
    [serverHost, accept, $warmup_duration, $(256), $maxThreads, url]
  echo "  Running Warmup"
  ret = execSilent(cmd)
  if ret != 0:
    raise newException(Exception, "cannot run warmup: " & name)
  sleep(sleep_duration)

  var jar = newJArray()
  for c in levels:
    echo "  Running Concurrency $1" % [$c]
    let t = max(c, maxThreads)
    let cmd = "./wrk -H \"Host: $1\" -H \"Accept: $2\" -H \"Connection: keep-alive\" --latency -d $3 -c $4 --timeout 8 -t $5 $6 -s jsonfmt.lua" %
      [serverHost, accept, $concurrency_duration, $c, $t, url]
    let res = execAndGetJson(cmd)
    if res.len == 1:
      var json = res[0]
      json.add("level", newJInt(c))
      json.add("success", newJBool(true))
      json.add("pipeline", newJInt(0))
      jar.add json
    else:
      var json = newJObject()
      json.add("level", newJInt(c))
      json.add("success", newJBool(false))
      json.add("pipeline", newJInt(0))
      jar.add json

  sleep(sleep_duration)
  for c in levels:
    echo "  Running Concurrency $1 with pipeline $2" % [$c, $pipeline]
    let t = max(c, maxThreads)
    let cmd = "./wrk -H \"Host: $1\" -H \"Accept: $2\" -H \"Connection: keep-alive\" --latency -d $3 -c $4 --timeout 8 -t $5 $6 -s pipeline.lua -- $7" %
      [serverHost, accept, $pipeline_duration, $c, $t, url, $pipeline]
    let res = execAndGetJson(cmd)
    if res.len == 1:
      var json = res[0]
      json.add("level", newJInt(c))
      json.add("success", newJBool(true))
      json.add("pipeline", newJInt(pipeline))
      jar.add json
    else:
      var json = newJObject()
      json.add("level", newJInt(c))
      json.add("success", newJBool(false))
      json.add("pipeline", newJInt(pipeline))
      jar.add json

  if optNoDocker in options:
    stopServer(server)
  else:
    sleep(sleep_duration)
    killContainers()
    removeContainers()

  result = newJObject()
  result.add("result", jar)
  result.add("name", newJString(name))

proc renderResult(json: JsonNode, s: Stream) =
  s.writeLine(json["name"].getStr())
  let bench = json["result"]
  for c in bench:
    if c["success"].getBool():
      let concurrency = c["level"].getInt()
      let duration = c["duration"].getInt()
      let requests = c["requests"].getInt()
      let bytes  = c["bytes"].getInt()
      let pipeline  = c["pipeline"].getInt()

      let sec = duration.float / 1_000_000.0
      let rps = formatFloat(requests.float / sec, ffDecimal, 2)
      let size = bytes.float / sec
      let tps = formatSize(size.int)

      if pipeline == 0:
        s.writeLine("  concurrency: $1, request/sec: $2, transfer/sec: $3" % [$concurrency, rps, tps])
      else:
        s.writeLine("  concurrency: $1, request/sec: $2, transfer/sec: $3, pipeline: $4" % [$concurrency, rps, tps, $pipeline])

    else:
      let concurrency = c["level"].getInt()
      s.writeLine("  concurrency: $1, failed" % [$concurrency])

proc runAllTest(options: Options) =
  if optNoDocker in options:
    buildExes()
  else:
    buildImages()

  var resList = newSeq[JsonNode]()
  for p in participants:
    try:
      let res = runTest(p, options)
      resList.add res
    except Exception as e:
      echo e.msg

  var s = newFileStream("benchmark_result.txt", fmWrite)
  for res in resList:
    res.renderResult(s)
  s.close()

  var ss = newStringStream()
  for res in resList:
    res.renderResult(ss)
  echo ss.data

proc runSingleTest(name: string, options: Options) =
  if optNoDocker in options:
    buildExe(name)
  else:
    buildImage(name)

  let res = runTest(name, options)
  var s = newStringStream()
  res.renderResult(s)
  echo s.data

proc removeImage(id: string) =
  var ret = execSilent("docker rmi " & id)
  if ret != 0:
    raise newException(Exception, "cannot remove image: " & id)

proc removeDanglingImages() =
  let m = execAndGetJson("docker images -f \"dangling=true\" -q --format '{{json .}}'")
  for x in m:
    let ID = x["ID"]
    removeImage(ID.getStr())

proc installWrk(forceInstall: bool = false): bool =
  result = true
  let parentDir = getAppDir()
  if fileExists(parentDir & DirSep & "wrk") and not forceInstall:
    return true
  let curDir = parentDir & DirSep & "wrksrc"
  discard existsOrCreateDir(curDir)
  setCurrentDir(curDir)
  echo "build wrk..."
  if not fileExists(curDir & DirSep & "4.1.0.tar.gz") or forceInstall:
    result = execCmd("wget -q https://github.com/wg/wrk/archive/4.1.0.tar.gz") == 0
  if result or forceInstall:
    result = execCmd("tar xzf 4.1.0.tar.gz --strip-components=1 --skip-old-files") == 0
  if result or forceInstall:
    result = execCmd("make > /dev/null") == 0
  if result or forceInstall:
    copyFileWithPermissions(curDir & DirSep & "wrk", parentDir & DirSep & "wrk")
  setCurrentDir(parentDir)

proc printHelp() =
  echo "clean        clean all containers and unused images"
  echo "installwrk   force install wrk tool"
  echo "help         print this help"
  echo "all          run test for all frameworks"
  echo "run `bot xxx` with xxx=`framework name` to run test on single framework"
  echo ""
  echo "available frameworks:"
  for c in participants:
    echo "  ", c

proc runCommand(cmd: string, options: Options) =
  case cmd
  of "clean":
    killContainers()
    removeContainers()
    removeDanglingImages()
  of "installwrk":
    discard installWrk(true)
  of "all":
    discard installWrk()
    runAllTest(options)
  of "help":
    printHelp()
  else:
    if cmd notin participants:
      echo cmd & " is not a registered participant"
      return
    discard installWrk()
    runSingleTest(cmd, options)

proc main() =
  if paramCount() > 0:
    let cmd = paramStr(1)
    var options: Options = {}

    for i in 2 .. paramCount():
      case paramStr(i)
      of "nodocker":
        options.incl optNoDocker
      of "nothreads":
        options.incl optNoThreads
      else:
        echo "Invalid option: ", paramStr(i)
        quit 1

    runCommand(cmd, options)
  else:
    printHelp()

main()

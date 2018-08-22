import osproc, json, streams, strutils, os

const
  participants = ["mofuw", "asyncnet", "asyncdispatch2"]

proc execDocker(command: string): JsonNode =
  const
    options = {poStdErrToStdOut, poUsePath, poEvalCommand}
  var p = startProcess(command, args=[], env=nil, options=options)
  var outp = outputStream(p)
  result = newJArray()
  var line = newStringOfCap(120)
  while true:
    # FIXME: converts CR-LF to LF.
    if outp.readLine(line):
      let node = parseJson(line)
      result.add node
    elif not running(p): break
  close(p)

proc buildImages() =
  for c in participants:
    let cmd = "docker image build -q -t \"bench-$1:latest\" -f $1/plaintext.dockerfile $1/" % [c]
    let ret = execCmd(cmd)
    if ret != 0:
      raise newException(Exception, "cannot build image: " & c)

proc killAndRemove(id: string) =
  var ret = execCmd("docker kill " & id)
  if ret != 0:
    raise newException(Exception, "cannot kill container: " & id)
  ret = execCmd("docker rm " & id)
  if ret != 0:
    raise newException(Exception, "cannot remove container: " & id)

const
  levels = [256, 1024, 4096, 16384]
  maxConcurrency = levels[^1]
  duration = 15
  serverHost = "bench-bot"
  url = "http://127.0.0.1:8080/"
  pipeline = 16
  accept = "text/plain,text/html;q=0.9,application/xhtml+xml;q=0.9,application/xml;q=0.8,*/*;q=0.7"

proc runTest(name: string): seq[string] =
  let maxThreads = countProcessors()

  var cmd = "docker run -d -p 8080:8080 bench-$1" % [name]
  var ret = execCmd(cmd)
  if ret != 0:
    raise newException(Exception, "cannot run image: " & name)

  cmd = "wrk -H \"Host: $1\" -H \"Accept: $2\" -H \"Connection: keep-alive\" --latency -d 5 -c 8 --timeout 8 -t 8 $3" %
    [serverHost, accept, url]
  echo "Running Primer " & name
  echo cmd
  ret = execCmd(cmd)
  if ret != 0:
    raise newException(Exception, "cannot run primer: " & name)
  sleep(5000)

  cmd = "wrk -H \"Host: $1\" -H \"Accept: $2\" -H \"Connection: keep-alive\" --latency -d $3 -c $4 --timeout 8 -t $5 $6" %
    [serverHost, accept, $duration, $maxConcurrency, $maxThreads, url]
  echo "Running Warmup " & name
  echo cmd
  ret = execCmd(cmd)
  if ret != 0:
    raise newException(Exception, "cannot run warmup: " & name)
  sleep(5000)

  let m = execDocker("docker ps -a --format '{{json .}}'")
  for x in m:
    let ID = x["ID"]
    killAndRemove(ID.getStr())

  result = newSeqOfCap[string](levels.len)
  for c in levels:
    echo "Running Concurrency $1 for $2" % [$c, name]
    let t = max(c, maxThreads)
    cmd = "wrk -H \"Host: $1\" -H \"Accept: $2\" -H \"Connection: keep-alive\" --latency -d $3 -c $4 --timeout 8 -t $5 $6 -s pipeline.lua -- $7" %
      [serverHost, accept, $duration, $c, $t, url, $pipeline]
    result.add execProcess(cmd)

proc main() =
  buildImages()
  
  for p in participants:
    let res = runTest(p)
    
  #let cmd = "docker image ls --format '{{json .}}'"
  #let res = execDocker(cmd)
  #for x in res:
  #  echo x["Repository"], "/", x["Tag"]

  # docker kill $(docker ps -q) # kill all running containers
  # docker rm $(docker ps -a -q) # remove all stopped containers
  #var k = execProcess("./wrk -c 8 -t 3 -s pipeline.lua http://127.0.0.1:8080/ -- 16")
  #echo k

main()

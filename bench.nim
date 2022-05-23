import std/[os, osproc, math, strutils]
import stew/[base10, endians2]
import chronos

type
  BenchData = object
    writesCount: uint64
    writeDuration: Duration
    writeSessionDuration: Duration
    writeSize: uint64
    readsCount: uint64
    readDuration: Duration
    readSessionDuration: Duration
    readSize: uint64

  TestKind* = enum
    Test1, Test2, Test3

  BenchConfig* = object
    test: TestKind
    testsCount: int
    chunkSize: int
    timeout: Duration

const
  TestsCount = 2_000_000
  TestTimeSeconds = 600
  ChunkSize = 4096

proc createBigMessage(size: int): seq[byte] =
  var message = "MESSAGE"
  result = newSeq[byte](size)
  for i in 0 ..< len(result):
    result[i] = byte(message[i mod len(message)])

proc runSequentialLoop(address: TransportAddress,
                       config: BenchConfig) {.async.} =
  var
    buffer: array[4, byte]
    size = 0'u64
    transp: StreamTransport = nil
    message = createBigMessage(config.chunkSize)

  try:
    transp = await connect(address)
    let start = Moment.now()
    for i in 0 ..< config.testsCount:
      let bytesWrote = await transp.write(message)
      if bytesWrote != len(message):
        raise newException(ValueError, "Incomplete message has been sent")
      size = size + uint64(len(message))
    let elapsed1 = Moment.now() - start
    await transp.readExactly(addr buffer[0], 4)
    let elapsed2 = Moment.now() - start
    let countArr = uint64(config.testsCount).toBytesLE()
    let elapsed1Arr = toBytesLE(uint64(elapsed1.nanoseconds()))
    let elapsed2Arr = toBytesLE(uint64(elapsed2.nanoseconds()))
    let sizeArr = toBytesLE(size)
    let r1 = await transp.write(unsafeAddr countArr[0], len(countArr))
    let r2 = await transp.write(unsafeAddr elapsed1Arr[0], len(elapsed1Arr))
    let r3 = await transp.write(unsafeAddr elapsed2Arr[0], len(elapsed1Arr))
    let r4 = await transp.write(unsafeAddr sizeArr[0], len(sizeArr))
    if r1 + r2 + r3 + r4 != 32:
      raise newException(ValueError, "Incomplete bench data has been sent")
  finally:
    if not(isNil(transp)):
      await closeWait(transp)

proc runConcurrentLoop(address: TransportAddress,
                       config: BenchConfig) {.async.} =
  var
    buffer: array[4, byte]
    size = 0'u64
    transp: StreamTransport = nil
    message = createBigMessage(config.chunkSize)
    futures = newSeq[Future[int]](config.testsCount)

  try:
    transp = await connect(address)
    let start = Moment.now()
    case config.test
    of TestKind.Test1:
      raiseAssert "Incorrect test call"
    of TestKind.Test2:
      for i in 0 ..< config.testsCount:
        futures[i] = transp.write(message)
        size = size + uint64(len(message))
      await allFutures(futures)
      for i in 0 ..< config.testsCount:
        if futures[i].failed() or futures[i].cancelled():
          raise futures[i].readError()
        else:
          let bytesWrote = futures[i].read()
          if bytesWrote != len(message):
            raise newException(ValueError, "Incomplete message has been sent")
    of TestKind.Test3:
      for i in 0 ..< (config.testsCount - 1):
        discard transp.write(message)
        size = size + uint64(len(message))

      let bytesWrote = await transp.write(message)
      if bytesWrote != len(message):
        raise newException(ValueError, "Incomplete message has been sent")
      size = size + uint64(len(message))

    let elapsed1 = Moment.now() - start
    await transp.readExactly(addr buffer[0], 4)
    let elapsed2 = Moment.now() - start
    let countArr = uint64(config.testsCount).toBytesLE()
    let elapsed1Arr = toBytesLE(uint64(elapsed1.nanoseconds()))
    let elapsed2Arr = toBytesLE(uint64(elapsed2.nanoseconds()))
    let sizeArr = toBytesLE(size)
    let r1 = await transp.write(unsafeAddr countArr[0], len(countArr))
    let r2 = await transp.write(unsafeAddr elapsed1Arr[0], len(elapsed1Arr))
    let r3 = await transp.write(unsafeAddr elapsed2Arr[0], len(elapsed1Arr))
    let r4 = await transp.write(unsafeAddr sizeArr[0], len(sizeArr))
    if r1 + r2 + r3 + r4 != 32:
      raise newException(ValueError, "Incomplete bench data has been sent")
  finally:
    if not(isNil(transp)):
      await closeWait(transp)

proc runClient(address: TransportAddress,
               config: BenchConfig): Future[int] {.async.} =
  var fut =
    case config.test
    of TestKind.Test1:
      runSequentialLoop(address, config)
    of TestKind.Test2, TestKind.Test3:
      runConcurrentLoop(address, config)
  let res = await fut.withTimeout(config.timeout)
  if not(res):
    echo "CLIENT: Timeout exceeded while performing test"
    return 1
  if fut.failed():
    let exc = fut.readError()
    echo "CLIENT: Test failed with an exception [", $exc.name, ": ",
         $exc.msg, "]"
    return 1
  echo "CLIENT: Succesfully finished"
  return 0

proc runServerLoop(server: StreamServer,
                   config: BenchConfig): Future[BenchData] {.async.} =
  var
    transp: StreamTransport = nil
    buffer = newSeq[byte](config.chunkSize)
    size = 0'u64
  try:
    transp = await server.accept()
    let start = Moment.now()
    for i in 0 ..< config.testsCount:
      await transp.readExactly(addr buffer[0], len(buffer))
      size = size + uint64(len(buffer))
    let elapsed1 = Moment.now() - start
    let finres = await transp.write("#FIN")
    if finres != 4:
      raise newException(ValueError, "Incomplete fin mark sent")
    let data = await transp.read()
    let elapsed2 = Moment.now() - start
    if len(data) != 32:
      raise newException(ValueError, "Benchmark data is incorrect")
    let res =
      block:
        let writesCount = uint64.fromBytesLE(data.toOpenArray(0, 7))
        let writeDur = uint64.fromBytesLE(data.toOpenArray(8, 15))
        let sessionDur = uint64.fromBytesLE(data.toOpenArray(16, 23))
        let writeSize = uint64.fromBytesLE(data.toOpenArray(24, 31))
        BenchData(
          writesCount: writesCount,
          writeDuration: int64(writeDur).nanoseconds(),
          writeSessionDuration: int64(sessionDur).nanoseconds(),
          writeSize: writeSize,
          readsCount: uint64(config.testsCount),
          readDuration: elapsed1,
          readSessionDuration: elapsed2,
          readSize: size)
    return res
  finally:
    if not(isNil(transp)):
      await transp.closeWait()

proc itemsPerSecond(count: uint64, duration: Duration): int64 =
  int64(
    trunc(float(count) * float(1_000_000_000) / float(duration.nanoseconds())))

proc `$`(kind: TestKind): string =
  case kind
  of TestKind.Test1:
    "test1"
  of TestKind.Test2:
    "test2"
  of TestKind.Test3:
    "test3"

proc describe(kind: TestKind): string =
  case kind
  of TestKind.Test1:
    "sequential"
  of TestKind.Test2:
    "concurrent-slow"
  of TestKind.Test3:
    "concurrent-fast"

proc runServer(config: BenchConfig): Future[int] {.async.} =
  let address = initTAddress("127.0.0.1:0")
  let server = createStreamServer(address)
  let host = server.localAddress()

  let fut = runServerLoop(server, config)

  let params = [
    "client",
    $host,
    $config.test,
    Base10.toString(uint64(config.testsCount)),
    Base10.toString(uint64(config.chunkSize)),
    Base10.toString(uint64(config.timeout.seconds()))
  ]
  let process = startProcess(getAppFilename(), "", params, nil,
                             {poParentStreams, poStdErrToStdOut})

  let res = await fut.withTimeout(config.timeout)
  server.stop()
  await server.closeWait()

  if not(res):
    echo "SERVER: Timeout exceeded while performing test"
    return 1

  if fut.failed():
    let exc = fut.readError()
    echo "SERVER: Test failed with an exception [", $exc.name, ": ",
         $exc.msg, "]"
    return 1

  echo "SERVER: Client process finished with ", process.waitForExit(),
       " exit code"
  echo "SERVER: Succesfully finished"
  let data = fut.read()

  let writeThroughput =
    formatSize(itemsPerSecond(data.writeSize, data.writeDuration),
               includeSpace = true) & "/second"
  let readThroughput =
    formatSize(itemsPerSecond(data.readSize, data.readDuration),
               includeSpace = true) & "/second"

  echo "=== Benchmark setup ================================"
  echo "Test type   : ", config.test.describe()
  echo "Tests count : ", config.testsCount
  echo "Chunk size  : ", config.chunkSize, " bytes"
  echo "Timeout     : ", $config.timeout
  echo "=== Benchmark results =============================="
  echo "write(): ", itemsPerSecond(data.writesCount, data.writeDuration),
       " requests/second"
  echo "write(): ", writeThroughput
  echo "read(): ", itemsPerSecond(data.readsCount, data.readDuration),
       " requests/second"
  echo "read(): ", readThroughput
  echo "=== Benchmark statistics ==========================="
  echo "Number of write() calls       : ", data.writesCount
  echo "Number of bytes written       : ", formatSize(int64(data.writeSize),
                                                      includeSpace = true)
  echo "Duration of all write() calls : ", data.writeDuration
  echo "Duration of the write session : ", data.writeSessionDuration
  echo "Number of read() calls        : ", data.readsCount
  echo "Number of bytes read          : ", formatSize(int64(data.readSize),
                                                      includeSpace = true)
  echo "Duration of all read() calls  : ", data.readDuration
  echo "Duration of the read session  : ", data.readSessionDuration
  echo "===================================================="
  return 0

proc printUsage() =
  let usage = """
chronos benchmark suite, Version 0.7,

Usage: bench TEST <TESTS COUNT> <CHUNK SIZE> <TIMEOUT SECONDS>
  """
  echo usage

proc getIntegerValue(argName: string, argNum: int, default: int): int =
  let argsCount = paramCount()
  if argsCount > argNum - 1:
    let res = Base10.decode(uint64, paramStr(argNum))
    if res.isErr():
      echo "SYNTAX ERROR: Incorrect <" & argName & "> value!"
      quit(1)
    let vres = res.get()
    if vres > uint64(high(int)):
      echo "SYNTAX ERROR: <" & argName & "> value is too big!"
      quit(1)
    int(vres)
  else:
    default

proc getTestKindValue(argName: string, argNum: int): TestKind =
  let argsCount = paramCount()
  if argsCount > argNum - 1:
    case paramStr(argNum)
    of "test1":
      TestKind.Test1
    of "test2":
      TestKind.Test2
    of "test3":
      TestKind.Test3
    else:
      echo "SYNTAX ERROR: Unrecognized TEST name value!"
      quit(1)
  else:
    echo "SYNTAX ERROR: Missing TEST name value!"
    quit(1)

when isMainModule:
  let argsCount = paramCount()
  if paramCount() == 0:
    printUsage()
    quit(0)
  elif argsCount < 5:
    let
      test = getTestKindValue("TEST", 1)
      testsCount = getIntegerValue("TESTS COUNT", 2, TestsCount)
      chunkSize = getIntegerValue("CHUNK SIZE", 3, ChunkSize)
      timeoutValue = seconds(
        getIntegerValue("TIMEOUT SECONDS", 4, TestTimeSeconds))
      config = BenchConfig(
        test: test, testsCount: testsCount, chunkSize: chunkSize,
        timeout: timeoutValue
      )

    let res = waitFor(runServer(config))
    quit(res)

  elif paramCount() == 6:
    if paramStr(1) != "client":
      echo "SYNTAX ERROR: Incorrect client spawn argument"
      quit(1)

    let
      address =
        try:
          initTAddress(paramStr(2))
        except TransportAddressError:
          echo "SYNTAX ERROR: Incorrect server address argument"
          quit(1)
      test = getTestKindValue("TEST", 3)
      testsCount = getIntegerValue("TESTS COUNT", 4, TestsCount)
      chunkSize = getIntegerValue("CHUNK SIZE", 5, ChunkSize)
      timeoutValue = seconds(
        getIntegerValue("TIMEOUT SECONDS", 6, TestTimeSeconds))

      config = BenchConfig(
        test: test, testsCount: testsCount, chunkSize: chunkSize,
        timeout: timeoutValue
      )

    let res = waitFor(runClient(address, config))
    quit(res)
  else:
    echo "SYNTAX ERROR: Unrecognized number of arguments"
    quit(1)

#                Chronos Test Suite
#            (c) Copyright 2021-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)
import
  std/[strformat, times],

  ../chronos,
  ../chronos/threadsync,
  ../chronos/apps/http/[httpserver, httpclient, httpcommon]

{.used.}

# Benchmark configuration
const
  SmallRequestSize = 32
  MediumRequestSize = 1024 * 1024 # 1MB
  MediumResponseSize = 1024 * 1024 # 1MB
  NumClients = 10 # Number of concurrent clients
  NumRequestsPerClient = 100 # Number of requests per client

type BenchmarkResult = object
  testName: string
  totalTime: times.Duration
  totalBytesSent: int64
  totalBytesReceived: int64
  numRequests: int

# Create a message of specified size
proc createMessage(size: int): seq[byte] =
  let message = "Hello, World! This is a benchmark message. "
  result = newSeq[byte](size)
  for i in 0 ..< size:
    result[i] = byte(message[i mod len(message)])


const
  smallRequest = createMessage(SmallRequestSize)
  mediumMessage = createMessage(MediumRequestSize)

proc inSecondsFloat(d: times.Duration): float =
  d.inNanoseconds() / 1000000000

# Create a simple HTTP server for benchmarking
proc createBenchmarkServer(address: TransportAddress): HttpServerRef =
  proc process(
      r: RequestFence
  ): Future[HttpResponseRef] {.async: (raises: [CancelledError]).} =
    if r.isOk():
      let request = r.get()
      try:
        case request.uri.path
        of "/small":
          # Small request, small response
          let data = await request.getBody()
          await request.respond(Http200, "Received " & $len(data) & " bytes")
        of "/medium":
          # Small request, medium response
          discard await request.getBody()
          await request.respond(Http200, mediumMessage)
        else:
          await request.respond(Http404, "Not found")
      except HttpError as exc:
        defaultResponse(exc)
    else:
      defaultResponse()

  let socketFlags = {ServerFlags.TcpNoDelay, ServerFlags.ReuseAddr}
  let res = HttpServerRef.new(address, process, socketFlags = socketFlags)
  res.get()

var
  serverAddress: TransportAddress
  tsp: ThreadSignalPtr

proc runServer() {.thread, nimcall.} =
  let server = createBenchmarkServer(initTAddress("127.0.0.1:0"))
  server.start()
  serverAddress = server.instance.localAddress()
  discard tsp.fireSync().expect("ok")
  runForever()

# Create an HTTP client session
proc createBenchmarkClient(): HttpSessionRef =
  HttpSessionRef.new({HttpClientFlag.Http11Pipeline})

# Client worker that sends requests and measures performance
proc clientWorker(
    session: HttpSessionRef,
    address: TransportAddress,
    testPath: string,
    requestData: seq[byte],
    results: ref BenchmarkResult,
) {.async.} =
  let ha = getAddress(address, HttpClientScheme.NonSecure, testPath)

  for i in 0 ..< NumRequestsPerClient:
    var req = HttpClientRequestRef.new(session, ha, MethodPost, body = requestData)

    let response = await fetch(req)
    assert response.status == 200, "No failing requests in this benchmark"

    inc(results.numRequests)
    results.totalBytesReceived += int64(len(response.data))

    await req.closeWait()

# Run a benchmark test
proc runBenchmark(
    testName: string, testPath: string, requestData: seq[byte]
): Future[BenchmarkResult] {.async.} =
  var session = createBenchmarkClient()
  var futures = newSeq[Future[void]](NumClients)
  var results = (ref BenchmarkResult)(
    testName: testName,
    totalBytesSent: int64(len(requestData)) * int64(NumClients * NumRequestsPerClient),
    numRequests: 0,
  )

  let startTime = getTime()

  # Start client workers
  for i in 0 ..< NumClients:
    futures[i] = clientWorker(session, serverAddress, testPath, requestData, results)

  # Wait for all workers to complete
  await allFutures(futures)

  await session.closeWait()
  let endTime = getTime()

  results.totalTime = endTime - startTime

  results[]

# Print benchmark results as a table
proc print(results: BenchmarkResult) =
  let v = (
    name: results.testName,
    totalTime: results.totalTime.inSecondsFloat,
    numRequests: results.numRequests,
    reqsps: ((results.numRequests.float / results.totalTime.inSecondsFloat)),
    sent: results.totalBytesSent / (1024 * 1024),
    received: results.totalBytesReceived / (1024 * 1024),
    sendSpeed:
      (results.totalBytesSent.float / results.totalTime.inSecondsFloat / (1024 * 1024)),
    recvSpeed: (
      results.totalBytesReceived.float / results.totalTime.inSecondsFloat / (
        1024 * 1024
      )
    ),
  )

  echo &"| {v.name:14} | {v.totalTime:8.3f}s | {v.numRequests:6} | {v.reqsps:8.3f} | {v.sent:8.3f} MB | {v.received:8.3f} MB | {v.sendSpeed:8.3f} MB/s | {v.recvSpeed:8.3f} MB/s |"

# Main benchmark function
proc runBenchmarks() {.async.} =
  echo "  Clients: " & $NumClients
  echo "  Requests per client: " & $NumRequestsPerClient
  echo "  Total requests: " & $(NumClients * NumRequestsPerClient)
  echo ""
  echo "| Benchmark      | Time (s)  | Reqs   | Req/s    | Bytes Sent  | Bytes Recv  | Send Speed    | Recv Speed    |"
  echo "|----------------|-----------|--------|----------|-------------|-------------|---------------|---------------|"

  print(await runBenchmark("Small/small", "/small", smallRequest))
  print(await runBenchmark("Medium/small", "/small", mediumMessage))
  print(await runBenchmark("Small/Medium", "/medium", smallRequest))
  print(await runBenchmark("Medium/Medium", "/medium", mediumMessage))

when isMainModule:
  tsp = ThreadSignalPtr.new()[]
  var server: Thread[void]
  createThread(server, runServer)
  discard tsp.waitSync().expect("ok")

  waitFor runBenchmarks()

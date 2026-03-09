# ANCHOR: all
import chronos/apps/http/httpclient

# ANCHOR: urls
const uris = @[
  "https://duckduckgo.com/?q=chronos", "https://mock.codes/403", "http://123.456.78.90",
  "http://10.255.255.1", "https://html.spec.whatwg.org/", "https://mock.codes/200",
]
# ANCHOR_END: urls

# ANCHOR: findMarker
proc findMarker(
    response: HttpClientResponseRef
): Future[bool] {.
    async: (raises: [HttpUseClosedError, AsyncStreamError, CancelledError])
.} =
# ANCHOR_END: findMarker
# ANCHOR: bodyReader
  let bodyReader = response.getBodyReader()
# ANCHOR_END: bodyReader

# ANCHOR: vars
  var
    buffer = newSeq[byte](1024)
    fetchedBytes: seq[byte]
# ANCHOR_END: vars

# ANCHOR: while
  while not result and len(fetchedBytes) <= 10 * 1024:
# ANCHOR_END: while
# ANCHOR: read_bytes
    let bytesRead = await bodyReader.readOnce(addr(buffer[0]), len(buffer))
# ANCHOR_END: read_bytes

# ANCHOR: bytes_check
    if bytesRead == 0:
      break
# ANCHOR_END: bytes_check

# ANCHOR: fetchedBytes
    fetchedBytes &= buffer
# ANCHOR_END: fetchedBytes

# ANCHOR: result
    result = "<html" in bytesToString(fetchedBytes)
# ANCHOR_END: result

proc check(session: HttpSessionRef, uri: string) {.async.} =
  try:
    let request = HttpClientRequestRef.new(session, uri)

    if request.isErr:
      raise newException(HttpRequestError, request.error)

    let responseFuture = request.value.send()

    if await responseFuture.withTimeout(5.seconds):
      let response = responseFuture.read()

# ANCHOR: url_response
      if response.status == 200:
        let markerFound = await findMarker(response)

        if markerFound:
          echo "[OK] " & uri
        else:
          echo "[NOK] " & uri & ": Not valid HTML"
      else:
        echo "[NOK] " & uri & ": " & $response.status
# ANCHOR_END: url_response
    else:
      raise newException(AsyncTimeoutError, "Connection timed out")
  except CatchableError:
    echo "[ERR] " & uri & ": " & getCurrentExceptionMsg()

proc check(uris: seq[string]) {.async.} =
  let session = HttpSessionRef.new()
  var futures: seq[Future[void]]

  for uri in uris:
    futures.add(session.check(uri))

  await allFutures(futures)
  await noCancel(session.closeWait())

when isMainModule:
  waitFor check(uris)
# ANCHOR_END: all

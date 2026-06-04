# ANCHOR: all
import std/sequtils
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

proc check(session: HttpSessionRef, address: HttpAddress) {.async: (raises: [CancelledError]).} =
  try:
    let
      request = HttpClientRequestRef.new(session, address)
      responseFuture = request.send()

    if await responseFuture.withTimeout(5.seconds):
      let response = responseFuture.read()

# ANCHOR: url_response
      if response.status == 200:
        let markerFound = await findMarker(response)

        if markerFound:
          echo "[OK] " & address.hostname
        else:
          echo "[NOK] " & address.hostname & ": Not valid HTML"
      else:
        echo "[NOK] " & address.hostname & ": " & $response.status
# ANCHOR_END: url_response
    else:
      raise newException(AsyncTimeoutError, "Connection timed out")
# ANCHOR: except
  except HttpError, FuturePendingError, AsyncTimeoutError, AsyncStreamError:
# ANCHOR_END: except
    echo "[ERR] " & address.hostname & ": " & getCurrentExceptionMsg()

proc resolveUris(session: HttpSessionRef, uris: seq[string]): seq[HttpAddress] =
  for uri in uris:
    let address = session.getAddress(uri).valueOr:
      echo "[ERR] " & uri & ": " & error
      continue
    result.add(address)

proc check(uris: seq[string]) {.async: (raises: []).} =
  let
    session = HttpSessionRef.new()
    addresses = session.resolveUris(uris)
    futures = addresses.mapIt(session.check(it))

  try:
    await allFutures(futures)
  except CancelledError:
    await cancelAndWait(futures)
  finally:
    await session.closeWait()

when isMainModule:
  waitFor check(uris)
# ANCHOR_END: all

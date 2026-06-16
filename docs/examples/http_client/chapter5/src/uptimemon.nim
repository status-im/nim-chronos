# ANCHOR: all
import std/sequtils
import chronos/apps/http/httpclient

# ANCHOR: urls
const uris = @[
  "https://duckduckgo.com/?q=chronos", "https://mock.codes/403",
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

  defer:
    await bodyReader.closeWait()
# ANCHOR_END: bodyReader

# ANCHOR: vars
  const
    marker = "<html"
    bufferSize = 1024
  var
    totalRead = 0
    buffer = newString(bufferSize)
    sample = newString(len(marker) - 1)
# ANCHOR_END: vars

# ANCHOR: while
  while not result and totalRead <= 10 * 1024:
# ANCHOR_END: while
# ANCHOR: read_bytes
    let bytesRead = await bodyReader.readOnce(addr buffer[0], len(buffer))
    buffer.setLen(bytesRead)
# ANCHOR_END: read_bytes

# ANCHOR: bytes_check
    if len(buffer) == 0:
      await bodyReader.closeWait()
      await response.finish()
      break
# ANCHOR_END: bytes_check

# ANCHOR: update_sample
    totalRead += len(buffer)
    sample = sample[^(len(marker) - 1)..high(sample)]
    sample &= buffer
# ANCHOR_END: update_sample

# ANCHOR: result
    result = marker in sample
# ANCHOR_END: result

proc check(session: HttpSessionRef, uri: string) {.async: (raises: [CancelledError]).} =
# ANCHOR: let
  let
    request = HttpClientRequestRef.new(session, uri).valueOr:
      echo "[ERR] " & uri & ": " & error
      return
    response =
      try:
        await request.send().wait(5.seconds)
      except:
        echo "[ERR] " & uri & ": " & getCurrentExceptionMsg()
        return
      finally:
        await request.closeWait()
# ANCHOR_END: let

# ANCHOR: url_response
  try:
    if response.status == 200:
      let markerFound = await findMarker(response)

      if markerFound:
        echo "[OK] " & uri
      else:
        echo "[NOK] " & uri & ": Not valid HTML"
    else:
      echo "[NOK] " & uri & ": " & $response.status
# ANCHOR_END: url_response

# ANCHOR: except
  except HttpError, AsyncStreamError:
    echo "[ERR] " & uri & ": " & getCurrentExceptionMsg()
# ANCHOR_END: except

# ANCHOR: finally
  finally:
    await response.closeWait()
# ANCHOR_END: finally

proc check(uris: seq[string]) {.async: (raises: []).} =
  let
    session = HttpSessionRef.new()
    futures = uris.mapIt(session.check(it))

  try:
    await allFutures(futures)
  except CancelledError:
    await cancelAndWait(futures)
  finally:
    await session.closeWait()

when isMainModule:
  waitFor check(uris)
# ANCHOR_END: all

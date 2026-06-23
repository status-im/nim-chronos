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
    bodyReader: HttpBodyReader
): Future[bool] {.async: (raises: [AsyncStreamError, CancelledError]).} =
# ANCHOR_END: findMarker

# ANCHOR: vars
  const
    marker = "<html"
    readLimit = 10 * 1024

  var
    totalRead = 0
    sample = newString(len(marker) - 1)
    found = false
# ANCHOR_END: vars

# ANCHOR: findMarkerInSample
  proc findMarkerInSample(data: openArray[byte]): (int, bool) =
    if len(data) == 0:
      (0, false)
    else:
      sample = sample[^(len(marker) - 1) .. high(sample)]
      sample &= bytesToString(data)
      found = marker in sample
      totalRead += len(data)
      (len(data), found and totalRead <= readLimit)
# ANCHOR_END: findMarkerInSample

# ANCHOR: readMessage
  await bodyReader.readMessage(findMarkerInSample)
  found
# ANCHOR_END: readMessage
 
proc check(session: HttpSessionRef, uri: string) {.async: (raises: [CancelledError]).} =
# ANCHOR: let
  let
    request = HttpClientRequestRef.new(session, uri).valueOr:
      echo "[ERR] " & uri & ": " & error
      return
    response =
      try:
        await request.send().wait(5.seconds)
      except HttpError, AsyncTimeoutError:
        echo "[ERR] " & uri & ": " & getCurrentExceptionMsg()
        return
      finally:
        await request.closeWait()
# ANCHOR_END: let

# ANCHOR: url_response
  try:
    if response.status == 200:
      let
        bodyReader = response.getBodyReader()
        markerFound =
          try:
            await bodyReader.findMarker()
          finally:
            await bodyReader.closeWait()

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

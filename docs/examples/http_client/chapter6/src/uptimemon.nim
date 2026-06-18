# ANCHOR: all
import std/sequtils
import chronos/apps/http/httpclient

# ANCHOR: ntfy_topic
const
  ntfyTopic = "<YOUR_NTFY_TOPIC_NAME>"
# ANCHOR_END: ntfy_topic
  uris = @[
    "https://duckduckgo.com/?q=chronos", "https://mock.codes/403",
    "http://10.255.255.1", "https://html.spec.whatwg.org/",
    "https://mock.codes/200",
  ]

# ANCHOR: sendAlert
proc sendAlert(
    session: HttpSessionRef, message: string, priority = 3
) {.async: (raises: [CancelledError]).} =
  let
# ANCHOR_END: sendAlert
# ANCHOR: headers
    headers = {"Title": "Chronos Uptime Monitor", "Priority": $priority}
# ANCHOR_END: headers
# ANCHOR: body
    body = message.stringToBytes()
# ANCHOR_END: body
# ANCHOR: request
    request = HttpClientRequestRef.new(
      session,
      "https://ntfy.sh/" & ntfyTopic,
      meth = MethodPost,
      headers = headers,
      body = body,
    ).valueOr:
      echo "[WRN] Failed to send alert: " & error
      return
# ANCHOR_END: request

# ANCHOR: response
  try:
    let response = await request.send().wait(5.seconds)
    await response.closeWait()
  except HttpError, FuturePendingError, AsyncTimeoutError:
    echo "[WRN] Failed to send alert: " & getCurrentExceptionMsg()
  finally:
    await request.closeWait()
# ANCHOR_END: response

proc findMarker(
    bodyReader: HttpBodyReader
): Future[bool] {.async: (raises: [AsyncStreamError, CancelledError]).} =
  const
    marker = "<html"
    readLimit = 10 * 1024

  var
    totalRead = 0
    sample = newString(len(marker) - 1)
    found = false

  proc findMarkerInSample(data: openArray[byte]): (int, bool) =
    if len(data) == 0:
      (0, false)
    else:
      sample = sample[^(len(marker) - 1) .. high(sample)]
      sample &= bytesToString(data)
      found = marker in sample
      totalRead += len(data)
      (len(data), found and totalRead <= readLimit)

  await bodyReader.readMessage(findMarkerInSample)
  found

# ANCHOR: check
proc check(session: HttpSessionRef, uri: string) {.async: (raises: [CancelledError]).} =
  let
    request = HttpClientRequestRef.new(session, uri).valueOr:
      echo "[ERR] " & uri & ": " & error
      return
    response =
      try:
        await request.send().wait(5.seconds)
      except HttpError:
        echo "[ERR] " & uri & ": " & getCurrentExceptionMsg()
        return
      except AsyncTimeoutError:
        echo "[ERR] " & uri & ": " & getCurrentExceptionMsg()
        return
      finally:
        await request.closeWait()

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
        let message = "[NOK] " & uri & ": Not valid HTML"
        echo message
        await session.sendAlert(message)
    else:
      let message = "[NOK] " & uri & ": " & $response.status
      echo message
      await session.sendAlert(message)
  except HttpError, AsyncStreamError:
    let message = "[ERR] " & uri & ": " & getCurrentExceptionMsg()
    echo message
    await session.sendAlert(message, 4)
  finally:
    await response.closeWait()
# ANCHOR_END: check

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

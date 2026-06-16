# ANCHOR: all
import std/sequtils
import chronos/apps/http/httpclient

# ANCHOR: ntfy_topic
const
  ntfyTopic = "<YOUR_NTFY_TOPIC_NAME>"
# ANCHOR_END: ntfy_topic
  uris = @[
    "https://duckduckgo.com/?q=chronos", "https://mock.codes/403",
    "http://123.456.78.90", "http://10.255.255.1", "https://html.spec.whatwg.org/",
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
    response: HttpClientResponseRef
): Future[bool] {.
    async: (raises: [HttpUseClosedError, AsyncStreamError, CancelledError])
.} =
  let bodyReader = response.getBodyReader()

  const
    marker = "<html"
    bufferSize = 1024

  var
    totalRead = 0
    buffer = newString(bufferSize)
    sample = newString(len(marker) - 1)

  while not result and totalRead <= 10 * 1024:
    let bytesRead = await bodyReader.readOnce(buffer)
    buffer.setLen(bytesRead)

    if len(buffer) == 0:
      await bodyReader.closeWait()
      break

    totalRead += len(buffer)
    sample = sample[^(len(marker) - 1)..high(sample)]
    sample &= buffer

    result = marker in sample

# ANCHOR: check
proc check(session: HttpSessionRef, address: HttpAddress) {.async: (raises: [CancelledError]).} =
  let request = HttpClientRequestRef.new(session, address)

  try:
    let response = await request.send().wait(5.seconds)

    if response.status == 200:
      let markerFound = await findMarker(response)

      if markerFound:
        echo "[OK] " & address.hostname & address.path
      else:
        let message = "[NOK] " & address.hostname & address.path & ": Not valid HTML"
        echo message
        await session.sendAlert(message)
    else:
      let message = "[NOK] " & address.hostname & address.path & ": " & $response.status
      echo message
      await session.sendAlert(message)
  except HttpError, FuturePendingError, AsyncTimeoutError, AsyncStreamError:
    let message = "[ERR] " & address.hostname & address.path & ": " & getCurrentExceptionMsg()
    echo message
    await session.sendAlert(message, 4)
  finally:
    await request.closeWait()
# ANCHOR_END: check

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

# ANCHOR: all
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
    )
# ANCHOR_END: request

# ANCHOR: response
  if request.isOk:
    try:
      let response = await request.get.send()
      await response.closeWait()
    except HttpError:
      echo "[WRN] Failed to send alert: " & getCurrentExceptionMsg()
# ANCHOR_END: response

proc findMarker(
    response: HttpClientResponseRef
): Future[bool] {.
    async: (raises: [HttpUseClosedError, AsyncStreamError, CancelledError])
.} =
  let bodyReader = response.getBodyReader()

  var
    buffer = newSeq[byte](1024)
    fetchedBytes: seq[byte]

  while not result and len(fetchedBytes) <= 10 * 1024:
    let bytesRead = await bodyReader.readOnce(addr(buffer[0]), len(buffer))

    if bytesRead == 0:
      break

    fetchedBytes &= buffer

    result = "<html" in bytesToString(fetchedBytes)

HttpError ANCHOR: check
proc check(session: HttpSessionRef, uri: string) {.async: (raises: [CancelledError]).} =
  try:
    let request = HttpClientRequestRef.new(session, uri)

    if request.isErr:
      raise newException(HttpRequestError, request.error)

    let responseFuture = request.get.send()

    if await responseFuture.withTimeout(5.seconds):
      let response = responseFuture.read()

      if response.status == 200:
        let markerFound = await findMarker(response)

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
    else:
      raise newException(AsyncTimeoutError, "Connection timed out")
  except HttpError, FuturePendingError, AsyncTimeoutError, AsyncStreamError:
    let message = "[ERR] " & uri & ": " & getCurrentExceptionMsg()
    echo message
    await session.sendAlert(message, 4)
# ANCHOR_END: check

proc check(uris: seq[string]) {.async: (raises: [CancelledError]).} =
  let session = HttpSessionRef.new()
  var futures: seq[Future[void]]

  for uri in uris:
    futures.add(session.check(uri))

  await allFutures(futures)
  await noCancel(session.closeWait())

when isMainModule:
  waitFor check(uris)
# ANCHOR_END: all

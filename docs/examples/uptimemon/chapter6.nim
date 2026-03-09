# ANCHOR: all
import chronos/apps/http/httpclient

# ANCHOR: maxConcurrency
const
  maxConcurrency = 5
# ANCHOR_END: maxConcurrency
  ntfyTopic = "X3JIaLZSrFqBJXfJ"
# ANCHOR: uris
  uris = @[
    "https://duckduckgo.com/?q=chronos", "https://mock.codes/403",
    "http://123.456.78.90", "http://10.255.255.1", "https://html.spec.whatwg.org",
    "https://mock.codes/200", "https://github.com", "https://archive.org",
    "https://nim-lang.org", "https://w3.org", "https://free.technology",
    "https://codeberg.org", "https://nimble.directory", "https://status.app",
    "https://keycard.tech", "https://stackoverflow.com", "https://nimbus.team",
    "https://logos.co", "https://forum.nim-lang.org", "https://acid.info",
    "https://vac.dev", "https://expired.badssl.com", "http://10.255.255.2",
    "http://10.255.255.3",
  ]
# ANCHOR_END: uris

proc sendAlert(
    session: HttpSessionRef, message: string, priority = 3
) {.async: (raises: [CancelledError]).} =
  let
    headers = {"Title": "Chronos Uptime Monitor", "Priority": $priority}
    body = message.stringToBytes()
    request = HttpClientRequestRef.new(
      session,
      "https://ntfy.sh/" & ntfyTopic,
      meth = MethodPost,
      headers = headers,
      body = body,
    )

  if request.isOk:
    try:
      let response = await request.get.send()
      await response.closeWait()
    except HttpError:
      echo "[WRN] Failed to send alert: " & getCurrentExceptionMsg()

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

# ANCHOR: semaphore
proc check(
    session: HttpSessionRef, uri: string, semaphore: AsyncSemaphore
) {.async: (raises: [CancelledError, AsyncSemaphoreError]).} =
  await acquire(semaphore)

  defer:
    release(semaphore)
# ANCHOR_END: semaphore

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

# ANCHOR: check
proc check(uris: seq[string]) {.async: (raises: [CancelledError]).} =
  let
    session = HttpSessionRef.new()
    semaphore = newAsyncSemaphore(maxConcurrency)
# ANCHOR_END: check

# ANCHOR: while_true
  while true:
# ANCHOR_END: while_true
    echo "Checking " & $len(uris) & " URIs:"
    var futures: seq[Future[void]]

# ANCHOR: pass_semaphore
    for uri in uris:
      futures.add(session.check(uri, semaphore))
# ANCHOR_END: pass_semaphore

    await allFutures(futures)
    
# ANCHOR: sleep
    echo "Done. Next check in 10 seconds."
    await sleepAsync(10.seconds)
# ANCHOR_END: sleep

  await noCancel(session.closeWait())

when isMainModule:
  waitFor check(uris)
# ANCHOR_END: all

# ANCHOR: all
import std/sequtils
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
    ).valueOr:
      echo "[WRN] Failed to send alert: " & error
      return

  try:
    let response = await request.send()
    await response.closeWait()
  except HttpError:
    echo "[WRN] Failed to send alert: " & getCurrentExceptionMsg()
  finally:
    await request.closeWait()

proc findMarker(
    response: HttpClientResponseRef
): Future[bool] {.
    async: (raises: [HttpUseClosedError, AsyncStreamError, CancelledError])
.} =
  let bodyReader = response.getBodyReader()

  const
    marker = "<html"
    chunkSize = 1024
    windowSize = chunkSize + len(marker) - 1
  var
    totalRead = 0
    window: array[windowSize, byte]

  while not result and totalRead <= 10 * 1024:
    let buffer = await bodyReader.read(chunkSize)

    if len(buffer) == 0:
      break

    totalRead += len(buffer)
    window[0 ..< windowSize - len(buffer)] = window[len(buffer) ..< windowSize]
    window[windowSize - len(buffer) ..< windowSize] = buffer

    result = marker in bytesToString(window)

# ANCHOR: semaphore
proc check(
    session: HttpSessionRef, address: HttpAddress, semaphore: AsyncSemaphore
) {.async: (raises: [CancelledError]).} =
  await acquire(semaphore)

  defer:
    try:
      release(semaphore)
    except AsyncSemaphoreError:
      echo "Could not release a lock: " & getCurrentExceptionMsg()
# ANCHOR_END: semaphore

  try:
    let
      request = HttpClientRequestRef.new(session, address)
      responseFuture = request.send()

    if await responseFuture.withTimeout(5.seconds):
      let response = responseFuture.read()

      if response.status == 200:
        let markerFound = await findMarker(response)

        if markerFound:
          echo "[OK] " & address.hostname
        else:
          let message = "[NOK] " & address.hostname & ": Not valid HTML"
          echo message
          await session.sendAlert(message)
      else:
        let message = "[NOK] " & address.hostname & ": " & $response.status
        echo message
        await session.sendAlert(message)
    else:
      raise newException(AsyncTimeoutError, "Connection timed out")
  except HttpError, FuturePendingError, AsyncTimeoutError, AsyncStreamError:
    let message = "[ERR] " & address.hostname & ": " & getCurrentExceptionMsg()
    echo message
    await session.sendAlert(message, 4)

proc resolveUris(session: HttpSessionRef, uris: seq[string]): seq[HttpAddress] =
  for uri in uris:
    let address = session.getAddress(uri).valueOr:
      echo "[ERR] " & uri & ": " & error
      continue
    result.add(address)

# ANCHOR: check
proc check(uris: seq[string]) {.async: (raises: []).} =
  let
    session = HttpSessionRef.new()
    semaphore = newAsyncSemaphore(maxConcurrency)
# ANCHOR_END: check

# ANCHOR: while_true
  try:
    while true:
# ANCHOR_END: while_true
      echo "Checking " & $len(uris) & " URIs:"
      let
        addresses = session.resolveUris(uris)
        futures = addresses.mapIt(session.check(it, semaphore))

# ANCHOR: pass_semaphore
# ANCHOR_END: pass_semaphore

      try:
        await allFutures(futures)
      except CancelledError:
        await cancelAndWait(futures)
        break

# ANCHOR: sleep
      echo "Done. Next check in 10 seconds."
      try:
        await sleepAsync(10.seconds)
      except CancelledError:
        break
# ANCHOR_END: sleep
  except CancelledError:
    discard
  finally:
    await session.closeWait()

when isMainModule:
  waitFor check(uris)
# ANCHOR_END: all

# ANCHOR: all
import std/sequtils
import chronos/apps/http/httpclient

# ANCHOR: maxConcurrency
const
  maxConcurrency = 5
# ANCHOR_END: maxConcurrency
  ntfyTopic = "<YOUR_NTFY_TOPIC_NAME>"
# ANCHOR: uris
  uris = @[
    "https://duckduckgo.com/?q=chronos", "https://mock.codes/403",
    "http://10.255.255.1", "https://html.spec.whatwg.org",
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
    let response = await request.send().wait(5.seconds)
    await response.closeWait()
  except HttpError, FuturePendingError, AsyncTimeoutError:
    echo "[WRN] Failed to send alert: " & getCurrentExceptionMsg()
  finally:
    await request.closeWait()

proc findMarker(
    response: HttpClientResponseRef
): Future[bool] {.
    async: (raises: [HttpUseClosedError, AsyncStreamError, CancelledError])
.} =
  let bodyReader = response.getBodyReader()

  defer:
    await bodyReader.closeWait()

  const
    marker = "<html"
    bufferSize = 1024

  var
    totalRead = 0
    buffer = newString(bufferSize)
    sample = newString(len(marker) - 1)

  while not result and totalRead <= 10 * 1024:
    let bytesRead = await bodyReader.readOnce(addr buffer[0], len(buffer))
    buffer.setLen(bytesRead)

    if len(buffer) == 0:
      await bodyReader.closeWait()
      await response.finish()
      break

    totalRead += len(buffer)
    sample = sample[^(len(marker) - 1)..high(sample)]
    sample &= buffer

    result = marker in sample
  
# ANCHOR: semaphore
proc check(
    session: HttpSessionRef, uri: string, semaphore: AsyncSemaphore
) {.async: (raises: [CancelledError]).} =
  await acquire(semaphore)

  defer:
    try:
      release(semaphore)
    except AsyncSemaphoreError:
      echo "Could not release a lock: " & getCurrentExceptionMsg()
# ANCHOR_END: semaphore

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
  except HttpError, AsyncStreamError:
    let message = "[ERR] " & uri & ": " & getCurrentExceptionMsg()
    echo message
    await session.sendAlert(message, 4)
  finally:
    await response.closeWait()

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
# ANCHOR: pass_semaphore
      echo "Checking " & $len(uris) & " URIs:"
      let
        futures = uris.mapIt(session.check(it, semaphore))

      try:
        await allFutures(futures)
      except CancelledError:
        await cancelAndWait(futures)
        break
# ANCHOR_END: pass_semaphore

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

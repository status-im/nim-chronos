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
  except HttpError as e: 
    echo "[WRN] Failed to send alert: " & e.msg
  except FuturePendingError as e: 
    echo "[WRN] Failed to send alert: " & e.msg
  except AsyncTimeoutError as e: 
    echo "[WRN] Failed to send alert: " & e.msg
  finally:
    await request.closeWait()

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

# ANCHOR: semaphore
proc check(
    session: HttpSessionRef, uri: string, semaphore: AsyncSemaphore
) {.async: (raises: [CancelledError]).} =
  await acquire(semaphore)

  defer:
    try:
      release(semaphore)
    except AsyncSemaphoreError as e:
      echo "Could not release a lock: " & e.msg
# ANCHOR_END: semaphore

  let
    request = HttpClientRequestRef.new(session, uri).valueOr:
      echo "[ERR] " & uri & ": " & error
      return
    response =
      try:
        await request.send().wait(5.seconds)
      except HttpError as e:
        echo "[ERR] " & uri & ": " & e.msg
        return
      except AsyncTimeoutError as e:
        echo "[ERR] " & uri & ": " & e.msg
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
  except HttpError as e:
    let message = "[ERR] " & uri & ": " & e.msg
    echo message
    await session.sendAlert(message, 4)
  except AsyncStreamError as e:
    let message = "[ERR] " & uri & ": " & e.msg
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

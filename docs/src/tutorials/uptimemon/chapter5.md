# Sending Alerts

```nim
import chronos/apps/http/httpclient

const uris = @[
  "https://duckduckgo.com/?q=chronos", "https://mock.codes/403", "http://123.456.78.90",
  "http://10.255.255.1", "https://html.spec.whatwg.org/", "https://mock.codes/200",
]

proc sendAlert(
    session: HttpSessionRef, message: string, priority = "default"
) {.async.} =
  let
    headers = {"Title": "Chronos Uptime Monitor", "Priority": priority}
    body = message.stringToBytes()
    request = HttpClientRequestRef.new(
      session,
      "https://ntfy.sh/zZ50WuKxpX2Ujy5H",
      meth = MethodPost,
      headers = headers,
      body = body,
    )

  if request.isOk:
    try:
      let response = await request.get.send()
      await response.closeWait()
      echo "[INF] Alert sent"
    except CatchableError:
      echo "[WRN] Failed to send alert: " & getCurrentExceptionMsg()

proc findMarker(response: HttpClientResponseRef): Future[bool] {.async.} =
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

proc check(session: HttpSessionRef, uri: string) {.async.} =
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
  except CatchableError:
    let message = "[ERR] " & uri & ": " & getCurrentExceptionMsg()
    echo message
    await session.sendAlert(message, "high")

proc check(uris: seq[string]) {.async.} =
  let session = HttpSessionRef.new()
  var futures: seq[Future[void]]

  for uri in uris:
    futures.add(session.check(uri))

  await allFutures(futures)
  await noCancel(session.closeWait())

when isMainModule:
  waitFor check(uris)
```

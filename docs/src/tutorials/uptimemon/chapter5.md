# Sending Alerts with POST Requests

**Goal:** Learn how to send POST HTTP requests and set request headers.

**Source code:** [chapter5.nim](https://github.com/status-im/nim-chronos/blob/master/docs/examples/uptimemon/chapter5.nim)

How cool would it be to get notified about a service being down to your phone? This way, you can launch the program and just go on with your business and not constantly monitor the terminal window.

[ntfy](https://ntfy.sh) is a service that allows to send push notifications with [POST requests](https://docs.ntfy.sh/publish/). Let's use it to send notifications when our program detects a `[NOK]` or `[ERR]`.

## Set Up ntfy

1. Go to [https://ntfy.sh/app](https://ntfySub.sh/app).
2. Click on **Subscribe to topic** in the sidebar, click **GENERATE NAME** in the popup, copy the generated name, and **SUBSCRIBE**. We'll use this unique topic name to send the notifications to.
3. Click on **GRANT NOW** to allow push notifications from your browser.
4. Keep the browser open.

## Add Alerts

Here's the version of the program with alerting capabilities:

```nim
import chronos/apps/http/httpclient

const
  ntfyTopic = "YOUR_NTFY_TOPIC_NAME"
  uris = @[
    "https://duckduckgo.com/?q=chronos", "https://mock.codes/403",
    "http://123.456.78.90", "http://10.255.255.1", "https://html.spec.whatwg.org/",
    "https://mock.codes/200",
  ]

proc sendAlert(
    session: HttpSessionRef, message: string, priority = 3
) {.async.} =
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
    await session.sendAlert(message, 4)

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

As usual, let's examine the changes part by part.

```nim
const
  ntfyTopic = "YOUR_NTFY_TOPIC_NAME"
```

Define a new constant for the ntfy topic name you copied [earlier](#set-up-ntfy). Replace `YOUR_NTFY_TOPIC_NAME` with the actual value you copied from ntfy.

```nim
proc sendAlert(
    session: HttpSessionRef, message: string, priority = 3
) {.async.} =
```

Define a new async function that will do the request sending to ntfy. We'll send those requests in the same session so we pass it to the function as `session`.

`message` is the text we want to send in the notification.

`priority` is a number that defines the style of the notification in ntfy. ntfy recognizes five priority levels from 1 to 5: the higher the number, the "scarier" the message.

```nim
let
  headers = {"Title": "Chronos Uptime Monitor", "Priority": $priority}
```

ntfy uses headers to customize notifications, e.g. [`Title`](https://docs.ntfy.sh/publish/#message-title) and [`Priority`](https://docs.ntfy.sh/publish/#message-priority).

Here we set the headers as an arrays of tuples using Nim's shortcut syntax.

```nim
body = message.stringToBytes()
```

Requests body must be a sequence of bytes so we convert our text message using [`stringToBytes`](/api/chronos/apps/http/httpcommon.html#stringToBytes,openArray[char]).

```nim
request = HttpClientRequestRef.new(
  session,
  "https://ntfy.sh/" & ntfyTopic,
  meth = MethodPost,
  headers = headers,
  body = body,
)
```

Create the request with the necessary properties. `meth` is the request's HTTP method.

```nim
if request.isOk:
  try:
    let response = await request.get.send()
    await response.closeWait()
  except CatchableError:
    echo "[WRN] Failed to send alert: " & getCurrentExceptionMsg()
```

If the request was successfully created (`request.isOk`), we try to send it with `send()` and discard it (with `closeWait`).

If the request couldn't be sent (e.g. ntfy is unavailable), we print a warning.

```nim
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
    await session.sendAlert(message, 4)
```

Finally, we add calls to `sendAlert` in the `check` branches for `[NOK]` and `[ERR]`.
Run the code and observe alerts appearing in your browser accompanied by push notifications:

![ntfy alerts in browser](./ntfy_alerts_in_browser.png)

Install ntfy mobile app and subscribe to the same topic to receive the notifications on your phone.

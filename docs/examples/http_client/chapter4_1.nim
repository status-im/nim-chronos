# ANCHOR: all
import chronos/apps/http/httpclient

const uris = @[
  "https://duckduckgo.com/?q=chronos", "https://mock.codes/403", "http://123.456.78.90",
  "http://10.255.255.1", "https://html.spec.whatwg.org/",
]

proc check(session: HttpSessionRef, uri: string) {.async: (raises: [CancelledError]).} =
  try:
    let
# ANCHOR: request
      request = HttpClientRequestRef.new(session, uri)
# ANCHOR_END: request

# ANCHOR: error_check
    if request.isErr:
      raise newException(HttpRequestError, request.error)

    let
# ANCHOR_END: error_check

# ANCHOR: response
      responseFuture = request.value.send()
# ANCHOR_END: response
    if await responseFuture.withTimeout(5.seconds):
      let response = responseFuture.read()

      if response.status == 200:
        echo "[OK] " & uri
      else:
        echo "[NOK] " & uri & ": " & $response.status
    else:
      raise newException(AsyncTimeoutError, "Connection timed out")
  except HttpError, FuturePendingError, AsyncTimeoutError:
    echo "[ERR] " & uri & ": " & getCurrentExceptionMsg()

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

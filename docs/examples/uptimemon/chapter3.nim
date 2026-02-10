import chronos/apps/http/httpclient

const uris = @[
  "https://duckduckgo.com/?q=chronos", "https://www.google.fr/search?q=chronos",
  "https://mock.codes/403", "http://123.456.78.90", "http://10.255.255.1",
]

proc check(session: HttpSessionRef, uri: string) {.async.} =
  try:
    let responseFuture = session.fetch(parseUri(uri))

    if await responseFuture.withTimeout(5.seconds):
      let response = responseFuture.read()
      if response.status == 200:
        echo "[OK] " & uri
      else:
        echo "[NOK] " & uri & ": " & $response.status
    else:
      raise newException(AsyncTimeoutError, "Connection timed out")
  except CatchableError:
    echo "[ERR] " & uri & ": " & getCurrentExceptionMsg()

proc check(uris: seq[string]) {.async.} =
  let session = HttpSessionRef.new()
  var futures: seq[Future[void]]

  for uri in uris:
    futures.add(session.check(uri))

  await allFutures(futures)
  await noCancel(session.closeWait())

when isMainModule:
  waitFor check(uris)

import chronos/apps/http/httpclient

const uris =
  @[
    "https://duckduckgo.com/?q=chronos", "https://www.google.fr/search?q=chronos",
    "https://status.im", "http://123.456.78.90",
  ]

proc check(session: HttpSessionRef, uri: string) {.async.} =
  try:
    let response = await session.fetch(parseUri(uri))
    if response.status == 200:
      echo "[OK] " & uri
    else:
      echo "[NOK] " & uri & ": " & $response.status
  except CatchableError:
    echo "[ERR] " & uri & ": " & getCurrentExceptionMsg()

proc check(uris: seq[string]) {.async.} =
  let session = HttpSessionRef.new()
  var futs: seq[Future[void]]

  for uri in uris:
    futs.add(session.check(uri))

  await allFutures(futs)
  await noCancel(session.closeWait())

when isMainModule:
  waitFor check(uris)

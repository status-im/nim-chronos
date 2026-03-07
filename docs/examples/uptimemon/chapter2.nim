# ANCHOR: all
import chronos/apps/http/httpclient

# ANCHOR: uris
const uris = @[
  "https://duckduckgo.com/?q=chronos", "https://mock.codes/403", "http://123.456.78.90"
]
# ANCHOR_END: uris

# ANCHOR: proc_uris
proc check(session: HttpSessionRef, uri: string) {.async: (raises: [CancelledError]).} =
  try:
    let response = await session.fetch(parseUri(uri))

    if response.status == 200:
      echo "[OK] " & uri
    else:
      echo "[NOK] " & uri & ": " & $response.status
  except HttpError:
    echo "[ERR] " & uri & ": " & getCurrentExceptionMsg()
# ANCHOR_END: proc_uris

# ANCHOR: proc_uri
proc check(uris: seq[string]) {.async: (raises: [CancelledError]).} =
  let session = HttpSessionRef.new()
  var futures: seq[Future[void]]

  for uri in uris:
    futures.add(session.check(uri))

  await allFutures(futures)
  await noCancel(session.closeWait())
# ANCHOR_END: proc_uri

# ANCHOR: isMainModule
when isMainModule:
  waitFor check(uris)
# ANCHOR_END: isMainModule
# ANCHOR_END: all

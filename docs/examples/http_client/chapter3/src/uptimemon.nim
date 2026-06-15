# ANCHOR: all
import std/sequtils
import chronos/apps/http/httpclient

# ANCHOR: uris
const uris = @[
  "https://duckduckgo.com/?q=chronos", "https://mock.codes/403"
]
# ANCHOR_END: uris

# ANCHOR: check_uri
proc check(session: HttpSessionRef, uri: string) {.async: (raises: [CancelledError]).} =
  try:
    let response = await session.fetch(parseUri(uri))

    if response.status == 200:
      echo "[OK] " & uri
    else:
      echo "[NOK] " & uri & ": " & $response.status
  except HttpError:
    echo "[ERR] " & uri & ": " & getCurrentExceptionMsg()
# ANCHOR_END: check_uri

# ANCHOR: check_uris
proc check(uris: seq[string]) {.async: (raises: []).} =
  let
    session = HttpSessionRef.new()
    futures = uris.mapIt(session.check(it))

  try:
    await allFutures(futures)
  except CancelledError:
    await cancelAndWait(futures)
  finally:
    await session.closeWait()
# ANCHOR_END: check_uris

# ANCHOR: isMainModule
when isMainModule:
  waitFor check(uris)
# ANCHOR_END: isMainModule
# ANCHOR_END: all

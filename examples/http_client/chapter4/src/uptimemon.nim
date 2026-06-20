# ANCHOR: all
import std/sequtils
import chronos/apps/http/httpclient

const uris = @[
  "https://duckduckgo.com/?q=chronos", "https://mock.codes/403", "http://10.255.255.1",
]

# ANCHOR: check
proc check(session: HttpSessionRef, uri: string) {.async: (raises: [CancelledError]).} =
  try:
    let response = await session.fetch(parseUri(uri)).wait(5.seconds)

    if response.status == 200:
      echo "[OK] " & uri
    else:
      echo "[NOK] " & uri & ": " & $response.status
  except HttpError as e:
    echo "[ERR] " & uri & ": " & e.msg
  except FuturePendingError as e:
    echo "[ERR] " & uri & ": " & e.msg
  except AsyncTimeoutError as e:
    echo "[ERR] " & uri & ": " & e.msg
# ANCHOR_END: check

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

when isMainModule:
  waitFor check(uris)
# ANCHOR_END: all

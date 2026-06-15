# ANCHOR: all
import std/sequtils
import chronos/apps/http/httpclient

const uris = @[
  "https://duckduckgo.com/?q=chronos", "https://mock.codes/403", "http://123.456.78.90",
  "http://10.255.255.1", "https://html.spec.whatwg.org/",
]

proc check(session: HttpSessionRef, address: HttpAddress) {.async: (raises: [CancelledError]).} =
  try:
    let
      request = HttpClientRequestRef.new(session, address)
      response = await request.send().wait(5.seconds)

    if response.status == 200:
      echo "[OK] " & address.hostname & address.path
    else:
      echo "[NOK] " & address.hostname & address.path & ": " & $response.status
  except HttpError, FuturePendingError, AsyncTimeoutError:
    echo "[ERR] " & address.hostname & address.path & ": " & getCurrentExceptionMsg()

# ANCHOR: resolve
proc resolveUris(session: HttpSessionRef, uris: seq[string]): seq[HttpAddress] =
  for uri in uris:
    let address = session.getAddress(uri).valueOr:
      echo "[ERR] " & uri & ": " & error
      continue
    result.add(address)
# ANCHOR_END: resolve

proc check(uris: seq[string]) {.async: (raises: []).} =
  let
    session = HttpSessionRef.new()
    addresses = session.resolveUris(uris)
    futures = addresses.mapIt(session.check(it))

  try:
    await allFutures(futures)
  except CancelledError:
    await cancelAndWait(futures)
  finally:
    await session.closeWait()

when isMainModule:
  waitFor check(uris)
# ANCHOR_END: all

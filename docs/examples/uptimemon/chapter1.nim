import std/strformat

import chronos, chronos/apps/http/httpclient

proc checkUrl(url: string) {.async.} =
  let session = HttpSessionRef.new()

  try:
    let response = await session.fetch(parseUri(url))

    if response.status == 200:
      echo fmt"[OK] {url}"
    else:
      echo fmt"[NOK] {url} returned status: {response.status}"
  except CatchableError:
    echo fmt"[ERR] Connection to {url} failed: {getCurrentExceptionMsg()}"
  finally:
    await noCancel(session.closeWait())

when isMainModule:
  waitFor checkUrl("https://google.com")

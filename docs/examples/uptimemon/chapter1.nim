import chronos/apps/http/httpclient

proc check(uri: string) {.async.} =
  let session = HttpSessionRef.new()

  try:
    let response = await session.fetch(parseUri(uri))

    if response.status == 200:
      echo "[OK] " & uri
    else:
      echo "[NOK] " & uri & ": " & $response.status
  except CatchableError:
    echo "[ERR] " & uri & ": " & getCurrentExceptionMsg()
  finally:
    await noCancel(session.closeWait())

when isMainModule:
  waitFor check("https://google.com")

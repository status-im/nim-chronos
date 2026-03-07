# ANCHOR: all
# ANCHOR: import
import chronos/apps/http/httpclient
# ANCHOR_END: import

# ANCHOR: proc
proc check(uri: string) {.async: (raises: [CancelledError]).} =
# ANCHOR_END: proc
# ANCHOR: session
  let session = HttpSessionRef.new()
# ANCHOR_END: session

# ANCHOR: response
  try:
    let response = await session.fetch(parseUri(uri))
# ANCHOR_END: response

# ANCHOR: status
    if response.status == 200:
      echo "[OK] " & uri
    else:
      echo "[NOK] " & uri & ": " & $response.status
# ANCHOR_END: status
# ANCHOR: except
  except HttpError:
    echo "[ERR] " & uri & ": " & getCurrentExceptionMsg()
# ANCHOR_END: except
# ANCHOR: finally
  finally:
    await noCancel(session.closeWait())
# ANCHOR_END: finally

# ANCHOR: isMainModule
when isMainModule:
  waitFor check("https://google.com")
# ANCHOR_END: isMainModule
# ANCHOR_END: all

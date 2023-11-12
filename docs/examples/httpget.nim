import chronos/apps/http/httpclient

proc retrievePage*(uri: string): Future[string] {.async.} =
  # Create a new HTTP session
  let httpSession = HttpSessionRef.new()
  try:
    # Fetch page contents
    let resp = await httpSession.fetch(parseUri(uri))
    # Convert response to a string, assuming its encoding matches the terminal!
    bytesToString(resp.data)
  finally: # Close the session
    await noCancel(httpSession.closeWait())

echo waitFor retrievePage(
  "https://raw.githubusercontent.com/status-im/nim-chronos/master/README.md")

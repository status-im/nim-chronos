import chronos/apps/http/httpclient

proc cancellationExample() {.async.} =
  # Simple cancellation
  let future = sleepAsync(10.minutes)
  future.cancelSoon()
  # `cancelSoon` will not wait for the cancellation
  # to be finished, so the Future could still be
  # pending at this point.

  # Wait for cancellation
  let future2 = sleepAsync(10.minutes)
  await future2.cancelAndWait()
  # Using `cancelAndWait`, we know that future2 isn't
  # pending anymore. However, it could have completed
  # before cancellation happened (in which case, it
  # will hold a value)

  # Race between futures
  proc retrievePage(uri: string): Future[string] {.async.} =
    let httpSession = HttpSessionRef.new()
    try:
      let resp = await httpSession.fetch(parseUri(uri))
      return bytesToString(resp.data)
    finally:
      # be sure to always close the session
      # `finally` will run also during cancellation -
      # `noCancel` ensures that `closeWait` doesn't get cancelled
      await noCancel(httpSession.closeWait())

  let
    futs =
      @[
        retrievePage("https://duckduckgo.com/?q=chronos"),
        retrievePage("https://www.google.fr/search?q=chronos")
      ]

  let finishedFut = await one(futs)
  for fut in futs:
    if not fut.finished:
      fut.cancelSoon()
  echo "Result: ", await finishedFut

waitFor(cancellationExample())

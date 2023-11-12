## Make two http requests concurrently and output the one that wins

import chronos
import ./httpget

proc twoGets() {.async.} =
  let
    futs = @[
      # Both pages will start downloading concurrently...
      httpget.retrievePage("https://duckduckgo.com/?q=chronos"),
      httpget.retrievePage("https://www.google.fr/search?q=chronos")
    ]

  # Wait for at least one request to finish..
  let winner = await one(futs)
  # ..and cancel the others since we won't need them
  for fut in futs:
    # Trying to cancel an already-finished future is harmless
    fut.cancelSoon()

  # An exception could be raised here if the winning request failed!
  echo "Result: ", winner.read()

waitFor(twoGets())

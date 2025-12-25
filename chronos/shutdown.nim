## Manages nim-chronos graceful shutdown procedures.
## 
## Phases:
##   1. Block new work requests.
##   2. Signal all current work to start ending.
##   3. Wait until all tasks are completed.
##   4. Close resources.
## 

import ./oserrno

## Flag aimed to control whether shutdown is in progress.
## When set to true, new work requests should be rejected.
var shutdownInProgress{.threadvar.}: bool

proc initShutdownInProgressToFalse*() =
  shutdownInProgress = false

proc setShutdownInProgress*() =
  shutdownInProgress = true

proc isShutdownInProgress*(): bool =
  return shutdownInProgress

template checkShutdownInProgress*(): untyped =
  if isShutdownInProgress():
    when defined(windows):
      return err(WSAESHUTDOWN)
    else:
      return err(ESHUTDOWN)


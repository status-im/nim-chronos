#
#             Chronos Debugging Utilities
#
#  (c) Copyright 2020-Present Status Research & Development GmbH
#
#                Licensed under either of
#    Apache License, version 2.0, (LICENSE-APACHEv2)
#                MIT license (LICENSE-MIT)

{.push raises: [Defect].}

import ./asyncloop
export asyncloop

when defined(chronosFutureTracking):
  import stew/base10

const
  AllFutureStates* = {FutureState.Pending, FutureState.Cancelled,
                      FutureState.Finished, FutureState.Failed}
  WithoutFinished* = {FutureState.Pending, FutureState.Cancelled,
                      FutureState.Failed}
  OnlyPending* = {FutureState.Pending}
  OnlyFinished* = {FutureState.Finished}

proc dumpPendingFutures*(filter = AllFutureStates): string =
  ## Dump all `pending` Future[T] objects.
  ##
  ## This list will contain:
  ## 1. Future[T] objects with ``FutureState.Pending`` state (this Futures are
  ##    not yet finished).
  ## 2. Future[T] objects with ``FutureState.Finished/Cancelled/Failed`` state
  ##    which callbacks are scheduled, but not yet fully processed.
  var count = 0'u
  var res = ""
  when defined(chronosFutureTracking):
    for item in pendingFutures():
      if item.state in filter:
        inc(count)
        let loc = item.location[LocCreateIndex][]
        let procedure = $loc.procedure
        let filename = $loc.file
        let procname = if len(procedure) == 0:
          "\"unspecified\""
        else:
          "\"" & procedure & "\""
        let item = "Future[" & Base10.toString(item.id) & "] with name " &
                   $procname & " created at " & "<" & filename & ":" &
                   Base10.toString(uint(loc.line)) & ">" &
                   " and state = " & $item.state & "\n"
        res.add(item)
    Base10.toString(count) & " pending Future[T] objects found:\n" & $res
  else:
    "0 pending Future[T] objects found\n"

proc pendingFuturesCount*(filter: set[FutureState]): uint =
  ## Returns number of `pending` Future[T] objects which satisfy the ``filter``
  ## condition.
  ##
  ## If ``filter`` is equal to ``AllFutureStates`` Operation's complexity is
  ## O(1), otherwise operation's complexity is O(n).
  when defined(chronosFutureTracking):
    if filter == AllFutureStates:
      pendingFuturesCount()
    else:
      var res = 0'u
      for item in pendingFutures():
        if item.state in filter:
          inc(res)
      res
  else:
    0'u

#
#                 Asyncdispatch2 Timer
#
#           (c) Coprygith 2017 Eugene Kabanov
#  (c) Copyright 2018 Status Research & Development GmbH
#
#                Licensed under either of
#    Apache License, version 2.0, (LICENSE-APACHEv2)
#                MIT license (LICENSE-MIT)


## This module implements cross-platform system timer with
## milliseconds resolution.

when defined(windows):

  from winlean import DWORD, getSystemTimeAsFileTime, FILETIME

  proc fastEpochTime*(): uint64 {.inline.} =
    var t: FILETIME
    getSystemTimeAsFileTime(t)
    result = ((uint64(t.dwHighDateTime) shl 32) or
              uint64(t.dwLowDateTime)) div 10_000

elif defined(macosx):

  from posix import Timeval

  proc posix_gettimeofday(tp: var Timeval, unused: pointer = nil) {.
    importc: "gettimeofday", header: "<sys/time.h>".}

  proc fastEpochTime*(): uint64 {.inline.} =
    var t: Timeval
    posix_gettimeofday(t)
    result = (uint64(t.tv_sec) * 1_000 + uint64(t.tv_usec) div 1_000)

elif defined(posix):

  from posix import clock_gettime, Timespec, CLOCK_REALTIME

  proc fastEpochTime*(): uint64 {.inline.} =
    var t: Timespec
    discard clock_gettime(CLOCK_REALTIME, t)
    result = (uint64(t.tv_sec) * 1_000 + uint64(t.tv_nsec) div 1_000_000)

elif defined(nimdoc):

  proc fastEpochTime*(): uint64
    ## Returns system's timer in milliseconds.

else:
  error("Sorry, your operation system is not yet supported!")

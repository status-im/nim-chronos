#
#
#                     nAIO
#        (c) Copyright 2017 Eugene Kabanov
#
#    See the file "LICENSE", included in this
#    distribution, for details about the copyright.
#

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
    result = (a.tv_sec * 1_000 + a.tv_usec div 1_000)

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

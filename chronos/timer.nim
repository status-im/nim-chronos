#
#                 Chronos Timer
#
#           (c) Copyright 2017 Eugene Kabanov
#  (c) Copyright 2018-Present Status Research & Development GmbH
#
#                Licensed under either of
#    Apache License, version 2.0, (LICENSE-APACHEv2)
#                MIT license (LICENSE-MIT)

## This module implements cross-platform system timer with
## milliseconds resolution.
##
## Timer supports two types of clocks:
## ``system`` uses the most fast OS primitive to obtain wall clock time.
## ``mono`` uses monotonic clock time (default).
##
## ``system`` clock is affected by discontinuous jumps in the system time. This
## clock is significantly faster then ``mono`` clock in most of the cases.
##
## ``mono`` clock is not affected by discontinuous jumps in the system time.
## This clock is slower then ``system`` clock.
##
## You can specify which timer you want to use ``-d:asyncTimer=<system/mono>``.
const asyncTimer* {.strdefine.} = "mono"

when defined(windows):
  when asyncTimer == "system":
    from winlean import DWORD, getSystemTimeAsFileTime, FILETIME

    proc fastEpochTime*(): uint64 {.inline.} =
      ## Timer resolution is millisecond.
      var t: FILETIME
      getSystemTimeAsFileTime(t)
      result = ((cast[uint64](t.dwHighDateTime) shl 32) or
                 cast[uint64](t.dwLowDateTime)) div 10_000

    proc fastEpochTimeNano*(): uint64 {.inline.} =
      ## Timer resolution is nanosecond.
      var t: FILETIME
      getSystemTimeAsFileTime(t)
      result = ((cast[uint64](t.dwHighDateTime) shl 32) or
                 cast[uint64](t.dwLowDateTime)) * 100

  else:
    proc QueryPerformanceCounter(res: var uint64) {.
      importc: "QueryPerformanceCounter", stdcall, dynlib: "kernel32".}
    proc QueryPerformanceFrequency(res: var uint64) {.
      importc: "QueryPerformanceFrequency", stdcall, dynlib: "kernel32".}

    var queryFrequencyM: uint64
    var queryFrequencyN: uint64

    proc fastEpochTimeNano*(): uint64 {.inline.} =
      ## Procedure's resolution is nanosecond.
      var res: uint64
      QueryPerformanceCounter(res)
      result = res * queryFrequencyN

    proc fastEpochTime*(): uint64 {.inline.} =
      ## Procedure's resolution is millisecond.
      var res: uint64
      QueryPerformanceCounter(res)
      when sizeof(int) == 4:
        result = (res div queryFrequencyN) * 1_000
      else:
        result = (res * 1_000) div queryFrequencyM

    proc setupQueryFrequence() =
      var freq: uint64
      QueryPerformanceFrequency(freq)
      queryFrequencyM = freq
      queryFrequencyN = 1_000_000_000'u64 div freq

    setupQueryFrequence()

elif defined(macosx):

  when asyncTimer == "system":
    from posix import Timeval

    proc posix_gettimeofday(tp: var Timeval, unused: pointer = nil) {.
      importc: "gettimeofday", header: "<sys/time.h>".}

    proc fastEpochTime*(): uint64 {.inline.} =
      ## Procedure's resolution is millisecond.
      var t: Timeval
      posix_gettimeofday(t)
      result = (cast[uint64](t.tv_sec) * 1_000 +
                cast[uint64](t.tv_usec) div 1_000)

    proc fastEpochTimeNano*(): uint64 {.inline.} =
      ## Procedure's resolution is nanosecond.
      var t: Timeval
      posix_gettimeofday(t)
      result = (cast[uint64](t.tv_sec) * 1_000_000_000 +
                cast[uint64](t.tv_usec) * 1_000)
  else:
    from posix import clock_gettime, Timespec, CLOCK_MONOTONIC

    proc fastEpochTime*(): uint64 {.inline.} =
      ## Procedure's resolution is millisecond.
      var t: Timespec
      discard clock_gettime(CLOCK_MONOTONIC, t)
      result = ((cast[uint64](t.tv_sec) * 1_000) +
                (cast[uint64](t.tv_nsec) div 1_000_000))

    proc fastEpochTimeNano*(): uint64 {.inline.} =
      ## Procedure's resolution is nanosecond.
      var t: Timespec
      discard clock_gettime(CLOCK_MONOTONIC, t)
      result = (cast[uint64](t.tv_sec) * 1_000_000_000 +
                cast[uint64](t.tv_nsec))

elif defined(posix):
  from posix import clock_gettime, Timespec, CLOCK_REALTIME, CLOCK_MONOTONIC

  when asyncTimer == "system":
    proc fastEpochTime*(): uint64 {.inline.} =
      ## Procedure's resolution is millisecond.
      var t: Timespec
      discard clock_gettime(CLOCK_REALTIME, t)
      result = (cast[uint64](t.tv_sec) * 1_000 +
                (cast[uint64](t.tv_nsec) div 1_000_000))

    proc fastEpochTimeNano*(): uint64 {.inline.} =
      ## Procedure's resolution is nanosecond.
      var t: Timespec
      discard clock_gettime(CLOCK_REALTIME, t)
      result = (cast[uint64](t.tv_sec) * 1_000_000_000 +
                (cast[uint64](t.tv_nsec) div 1_000_000))

  else:
    proc fastEpochTime*(): uint64 {.inline.} =
      ## Procedure's resolution is millisecond.
      var t: Timespec
      discard clock_gettime(CLOCK_MONOTONIC, t)
      result = (cast[uint64](t.tv_sec) * 1_000 +
                (cast[uint64](t.tv_nsec) div 1_000_000))

    proc fastEpochTimeNano*(): uint64 {.inline.} =
      ## Procedure's resolution is nanosecond.
      var t: Timespec
      discard clock_gettime(CLOCK_MONOTONIC, t)
      result = (cast[uint64](t.tv_sec) * 1_000_000_000 +
                (cast[uint64](t.tv_nsec) div 1_000_000))

elif defined(nimdoc):

  proc fastEpochTime*(): uint64
    ## Returns system's timer in milliseconds.

  proc fastEpochTimeNano*(): uint64
    ## Returns system's timer in nanoseconds.

else:
  error("Sorry, your operation system is not yet supported!")

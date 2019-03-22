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

    proc fastEpochTime*(): uint64 {.
         inline, deprecated: "Use Moment.now()".} =
      ## Timer resolution is millisecond.
      var t: FILETIME
      getSystemTimeAsFileTime(t)
      result = ((cast[uint64](t.dwHighDateTime) shl 32) or
                 cast[uint64](t.dwLowDateTime)) div 10_000

    proc fastEpochTimeNano(): uint64 {.inline.} =
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

    proc fastEpochTimeNano(): uint64 {.inline.} =
      ## Procedure's resolution is nanosecond.
      var res: uint64
      QueryPerformanceCounter(res)
      result = res * queryFrequencyN

    proc fastEpochTime*(): uint64 {.
         inline, deprecated: "Use Moment.now()".} =
      ## Procedure's resolution is millisecond.
      var res: uint64
      QueryPerformanceCounter(res)
      result = res div queryFrequencyM

    proc setupQueryFrequence() =
      var freq: uint64
      QueryPerformanceFrequency(freq)
      if freq < 1000:
        queryFrequencyM = freq
      else:
        queryFrequencyM = freq div 1_000
      queryFrequencyN = 1_000_000_000'u64 div freq

    setupQueryFrequence()

elif defined(macosx):

  when asyncTimer == "system":
    from posix import Timeval

    proc posix_gettimeofday(tp: var Timeval, unused: pointer = nil) {.
      importc: "gettimeofday", header: "<sys/time.h>".}

    proc fastEpochTime*(): uint64 {.
         inline, deprecated: "Use Moment.now()".} =
      ## Procedure's resolution is millisecond.
      var t: Timeval
      posix_gettimeofday(t)
      result = (cast[uint64](t.tv_sec) * 1_000 +
                cast[uint64](t.tv_usec) div 1_000)

    proc fastEpochTimeNano(): uint64 {.inline.} =
      ## Procedure's resolution is nanosecond.
      var t: Timeval
      posix_gettimeofday(t)
      result = (cast[uint64](t.tv_sec) * 1_000_000_000 +
                cast[uint64](t.tv_usec) * 1_000)
  else:
    from posix import clock_gettime, Timespec, CLOCK_MONOTONIC

    proc fastEpochTime*(): uint64 {.
         inline, deprecated: "Use Moment.now()".} =
      ## Procedure's resolution is millisecond.
      var t: Timespec
      discard clock_gettime(CLOCK_MONOTONIC, t)
      result = ((cast[uint64](t.tv_sec) * 1_000) +
                (cast[uint64](t.tv_nsec) div 1_000_000))

    proc fastEpochTimeNano(): uint64 {.inline.} =
      ## Procedure's resolution is nanosecond.
      var t: Timespec
      discard clock_gettime(CLOCK_MONOTONIC, t)
      result = cast[uint64](t.tv_sec) * 1_000_000_000'u64 +
               cast[uint64](t.tv_nsec)

elif defined(posix):
  from posix import clock_gettime, Timespec, CLOCK_REALTIME, CLOCK_MONOTONIC

  when asyncTimer == "system":
    proc fastEpochTime*(): uint64 {.
         inline, deprecated: "Use Moment.now()".} =
      ## Procedure's resolution is millisecond.
      var t: Timespec
      discard clock_gettime(CLOCK_REALTIME, t)
      result = (cast[uint64](t.tv_sec) * 1_000 +
                (cast[uint64](t.tv_nsec) div 1_000_000))

    proc fastEpochTimeNano(): uint64 {.inline.} =
      ## Procedure's resolution is nanosecond.
      var t: Timespec
      discard clock_gettime(CLOCK_REALTIME, t)
      result = cast[uint64](t.tv_sec) * 1_000_000_000'u64 +
               cast[uint64](t.tv_nsec)

  else:
    proc fastEpochTime*(): uint64 {.
         inline, deprecated: "Use Moment.now()".} =
      ## Procedure's resolution is millisecond.
      var t: Timespec
      discard clock_gettime(CLOCK_MONOTONIC, t)
      result = (cast[uint64](t.tv_sec) * 1_000 +
                (cast[uint64](t.tv_nsec) div 1_000_000))

    proc fastEpochTimeNano(): uint64 {.inline.} =
      ## Procedure's resolution is nanosecond.
      var t: Timespec
      discard clock_gettime(CLOCK_MONOTONIC, t)
      result = cast[uint64](t.tv_sec) * 1_000_000_000'u64 +
               cast[uint64](t.tv_nsec)

elif defined(nimdoc):

  proc fastEpochTime*(): uint64 {.deprecated: "Use Moment.now()".}
    ## Returns system's timer in milliseconds.

else:
  error("Sorry, your operation system is not yet supported!")

type
  Moment* = object
    value: int64

  Duration* = object
    value: int64

  DurationOrMoment* = Duration | Moment

func `+`*(a: Duration, b: Duration): Duration {.inline.} =
  ## Duration + Duration = Duration
  result.value = a.value + b.value

func `+`*(a: Duration, b: Moment): Moment {.inline.} =
  ## Duration + Moment = Moment
  result.value = a.value + b.value

func `+`*(a: Moment, b: Duration): Moment {.inline.} =
  ## Moment + Duration = Moment
  result.value = a.value + b.value

func `+=`*(a: var Moment, b: Duration) {.inline.} =
  ## Moment += Duration
  a.value += b.value

func `+=`*(a: var Duration, b: Duration) {.inline.} =
  ## Duration += Duration
  a.value += b.value

func `-`*(a, b: Moment): Duration {.inline.} =
  ## Moment - Moment = Duration
  ##
  ## Note: Duration can't be negative.
  result.value = if a.value >= b.value: a.value - b.value else: 0'i64

func `-`*(a: Moment, b: Duration): Moment {.inline.} =
  ## Moment - Duration = Moment
  ##
  ## Note: Moment can be negative
  result.value = a.value - b.value

func `-`*(a: Duration, b: Duration): Duration {.inline.} =
  ## Duration - Duration = Duration
  ##
  ## Note: Duration can't be negative.
  result.value = if a.value >= b.value: a.value - b.value else: 0'i64

func `-=`*(a: var Duration, b: Duration): Duration {.inline.} =
  ## Duration -= Duration
  a.value = if a.value >= b.value: a.value - b.value else: 0'i64

func `-=`*(a: var Moment, b: Duration): Moment {.inline.} =
  ## Moment -= Duration
  a.value -= b.value

func `==`*(a, b: Duration): bool {.inline.} =
  ## Returns ``true`` if ``a`` equal to ``b``.
  result = (a.value == b.value)

func `==`*(a, b: Moment): bool {.inline.} =
  ## Returns ``true`` if ``a`` equal to ``b``.
  result = (a.value == b.value)

func `<`*(a, b: Duration): bool {.inline.} =
  ## Returns ``true`` if ``a`` less then ``b``.
  result = (a.value < b.value)

func `<`*(a, b: Moment): bool {.inline.} =
  ## Returns ``true`` if ``a`` less then ``b``.
  result = (a.value < b.value)

func `<=`*(a, b: Duration): bool {.inline.} =
  ## Returns ``true`` if ``a`` less or equal ``b``.
  result = (a.value <= b.value)

func `<=`*(a, b: Moment): bool {.inline.} =
  ## Returns ``true`` if ``a`` less or equal ``b``.
  result = (a.value <= b.value)

func `>`*(a, b: Duration): bool {.inline.} =
  ## Returns ``true`` if ``a`` bigger then ``b``.
  result = (a.value > b.value)

func `>`*(a, b: Moment): bool {.inline.} =
  ## Returns ``true`` if ``a`` bigger then ``b``.
  result = (a.value > b.value)

func `>=`*(a, b: Duration): bool {.inline.} =
  ## Returns ``true`` if ``a`` bigger or equal ``b``.
  result = (a.value >= b.value)

func `>=`*(a, b: Moment): bool {.inline.} =
  ## Returns ``true`` if ``a`` bigger or equal ``b``.
  result = (a.value >= b.value)

func `*`*(a, b: Duration): Duration {.inline.} =
  result.value = a.value * b.value

func `div`*(a, b: Duration): Duration {.inline.} =
  result.value = a.value div b.value

const
  Nanosecond* = Duration(value: 1'i64)
  Microsecond* = Duration(value: 1_000'i64) * Nanosecond
  Millisecond* = Duration(value: 1_000'i64) * Microsecond
  Second* = Duration(value: 1_000'i64) * Millisecond
  Minute* = Duration(value: 60'i64) * Second
  Hour* = Duration(value: 60'i64) * Minute
  Day* = Duration(value: 24'i64) * Hour
  Week* = Duration(value: 7'i64) * Day

  ZeroDuration* = Duration(value: 0'i64)
  InfiniteDuration* = Duration(value: -1'i64)

func nanoseconds*(v: SomeInteger): Duration {.inline.} =
  ## Initialize Duration with nanoseconds value ``v``.
  result.value = cast[int64](v)

func microseconds*(v: SomeInteger): Duration {.inline.} =
  ## Initialize Duration with microseconds value ``v``.
  result.value = cast[int64](v) * Microsecond.value

func milliseconds*(v: SomeInteger): Duration {.inline.} =
  ## Initialize Duration with milliseconds value ``v``.
  result.value = cast[int64](v) * Millisecond.value

func seconds*(v: SomeInteger): Duration {.inline.} =
  ## Initialize Duration with seconds value ``v``.
  result.value = cast[int64](v) * Second.value

func minutes*(v: SomeInteger): Duration {.inline.} =
  ## Initialize Duration with minutes value ``v``.
  result.value = cast[int64](v) * Minute.value

func hours*(v: SomeInteger): Duration {.inline.} =
  ## Initialize Duration with hours value ``v``.
  result.value = cast[int64](v) * Hour.value

func days*(v: SomeInteger): Duration {.inline.} =
  ## Initialize Duration with days value ``v``.
  result.value = cast[int64](v) * Day.value

func weeks*(v: SomeInteger): Duration {.inline.} =
  ## Initialize Duration with weeks value ``v``.
  result.value = cast[int64](v) * Week.value

func nanoseconds*(v: Duration): Duration {.inline.} =
  ## Round Duration ``v`` to nanoseconds.
  result = v

func microseconds*(v: Duration): Duration {.inline.} =
  ## Round Duration ``v`` to microseconds.
  result = (v div Microsecond) * Microsecond

func milliseconds*(v: Duration): Duration {.inline.} =
  ## Round Duration ``v`` to milliseconds.
  result = (v div Millisecond) * Millisecond

func seconds*(v: Duration): Duration {.inline.} =
  ## Round Duration ``v`` to seconds.
  result = (v div Second) * Second

func minutes*(v: Duration): Duration {.inline.} =
  ## Round Duration ``v`` to minutes.
  result = (v div Minute) * Minute

func hours*(v: Duration): Duration {.inline.} =
  ## Round Duration ``v`` to hours.
  result = (v div Hour) * Hour

func days*(v: Duration): Duration {.inline.} =
  ## Round Duration ``v`` to days.
  result = (v div Day) * Day

func weeks*(v: Duration): Duration {.inline.} =
  ## Round Duration ``v`` to weeks.
  result = (v div Week) * Week

func nanos*[T: SomeInteger|Duration](v: T): Duration {.inline.} =
  nanoseconds(v)

func micros*[T: SomeInteger|Duration](v: T): Duration {.inline.} =
  microseconds(v)

func millis*[T: SomeInteger|Duration](v: T): Duration {.inline.} =
  milliseconds(v)

func secs*[T: SomeInteger|Duration](v: T): Duration {.inline.} =
  seconds(v)

func toInt*(a: Duration, unit: Duration): int64 {.inline.} =
  ## Round Duration ``a`` to specific Duration ``unit`` and returns value
  ## as integer.
  result = (a div unit).value

func `$`*(a: Duration): string {.inline.} =
  ## Returns string representation of Duration ``a`` as nanoseconds value.
  result = $(a.value)

func `$`*(a: Moment): string {.inline.} =
  ## Returns string representation of Moment ``a`` as nanoseconds value.
  result = $(a.value)

func isOver*(a: Duration): bool {.inline.} =
  ## Returns ``true`` if Duration ``a`` is ``0``.
  result = (a.value == 0)

func isInfinite*(a: Duration): bool {.inline.} =
  ## Returns ``true`` if Duration ``a`` is infinite.
  result = (a.value == -1)

proc now*(t: typedesc[Moment]): Moment {.inline.} =
  ## Returns current moment in time as Moment.
  result.value = cast[int64](fastEpochTimeNano())

proc init*(t: typedesc[Moment], value: int64, precision: Duration): Moment =
  ## Initialize Moment with absolute time value ``value`` with precision
  ## ``precision``.
  result.value = value * precision.value

proc fromNow*(t: typedesc[Duration], a: Duration): Moment {.inline.} =
  result = Moment.now() + a

func getTimestamp*(a: Duration): int {.inline.} =
  ## Return rounded up value of duration with milliseconds resolution.
  result = cast[int](a.value div 1_000_000'i64)
  let mid = a.value mod 1_000_000'i64
  if mid > 0'i64:
    result += 1

when defined(posix):
  from posix import Time, Suseconds, Timeval, Timespec

  func toTimeval*(a: Duration): Timeval =
    ## Convert Duration ``a`` to ``Timeval`` object.
    let m = a.value mod Second.value
    result.tv_sec = cast[Time](a.value div Second.value)
    result.tv_usec = cast[Suseconds](m div Microsecond.value)

  func toTimespec*(a: Duration): Timespec =
    ## Convert Duration ``a`` to ``Timespec`` object.
    result.tv_sec = cast[Time](a.value div Second.value)
    result.tv_nsec = cast[int](a.value mod Second.value)

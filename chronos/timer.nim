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

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

when defined(windows):
  when asyncTimer == "system":
    from winlean import getSystemTimeAsFileTime, FILETIME

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
    proc QueryPerformanceCounter*(res: var uint64) {.
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
    type
      MachTimebaseInfo {.importc: "struct mach_timebase_info",
                          header: "<mach/mach_time.h>", pure, final.} = object
        numer: uint32
        denom: uint32

    proc mach_timebase_info(info: var MachTimebaseInfo) {.importc,
         header: "<mach/mach_time.h>".}
    proc mach_absolute_time(): uint64 {.importc, header: "<mach/mach_time.h>".}

    var queryFrequencyN: uint64
    var queryFrequencyD: uint64

    proc setupQueryFrequence() =
      var info: MachTimebaseInfo
      mach_timebase_info(info)
      queryFrequencyN = info.numer
      queryFrequencyD = info.denom

    proc fastEpochTime*(): uint64 {.
         inline, deprecated: "Use Moment.now()".} =
      ## Procedure's resolution is millisecond.
      result = (mach_absolute_time() * queryFrequencyN) div queryFrequencyD
      result = result div 1_000_000

    proc fastEpochTimeNano(): uint64 {.inline.} =
      ## Procedure's resolution is nanosecond.
      result = (mach_absolute_time() * queryFrequencyN) div queryFrequencyD

    setupQueryFrequence()

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
    ## A Moment in time. Its value has no direct meaning, but can be compared
    ## with other Moments. Moments are captured using a monotonically
    ## non-decreasing clock (by default).
    value: int64

  Duration* = object
    ## A Duration is the interval between to points in time.
    value: int64

when sizeof(int) == 4:
  type SomeIntegerI64* = SomeSignedInt|uint|uint8|uint16|uint32
else:
  type SomeIntegerI64* = SomeSignedInt|uint8|uint16|uint32

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

func `*`*(a: Duration, b: SomeIntegerI64): Duration {.inline.} =
  ## Returns Duration multiplied by scalar integer.
  result.value = a.value * int64(b)

func `*`*(a: SomeIntegerI64, b: Duration): Duration {.inline.} =
  ## Returns Duration multiplied by scalar integer.
  result.value = int64(a) * b.value

func `div`*(a: Duration, b: SomeIntegerI64): Duration {.inline.} =
  ## Returns Duration which is result of dividing a Duration by scalar integer.
  result.value = a.value div int64(b)

const
  Nanosecond* = Duration(value: 1'i64)
  Microsecond* = Nanosecond * 1_000'i64
  Millisecond* = Microsecond * 1_000'i64
  Second* = Millisecond * 1_000'i64
  Minute* = Second * 60'i64
  Hour* = Minute * 60'i64
  Day* = Hour * 24'i64
  Week* = Day * 7'i64

  ZeroDuration* = Duration(value: 0'i64)
  InfiniteDuration* = Duration(value: high(int64))

template high*(T: typedesc[Moment]): Moment =
  Moment(value: high(int64))

template low*(T: typedesc[Moment]): Moment =
  Moment(value: 0)

template high*(T: typedesc[Duration]): Duration =
  Duration(value: high(int64))

template low*(T: typedesc[Duration]): Duration =
  Duration(value: 0)

func nanoseconds*(v: SomeIntegerI64): Duration {.inline.} =
  ## Initialize Duration with nanoseconds value ``v``.
  result.value = int64(v)

func microseconds*(v: SomeIntegerI64): Duration {.inline.} =
  ## Initialize Duration with microseconds value ``v``.
  result.value = int64(v) * Microsecond.value

func milliseconds*(v: SomeIntegerI64): Duration {.inline.} =
  ## Initialize Duration with milliseconds value ``v``.
  result.value = int64(v) * Millisecond.value

func seconds*(v: SomeIntegerI64): Duration {.inline.} =
  ## Initialize Duration with seconds value ``v``.
  result.value = int64(v) * Second.value

func minutes*(v: SomeIntegerI64): Duration {.inline.} =
  ## Initialize Duration with minutes value ``v``.
  result.value = int64(v) * Minute.value

func hours*(v: SomeIntegerI64): Duration {.inline.} =
  ## Initialize Duration with hours value ``v``.
  result.value = int64(v) * Hour.value

func days*(v: SomeIntegerI64): Duration {.inline.} =
  ## Initialize Duration with days value ``v``.
  result.value = int64(v) * Day.value

func weeks*(v: SomeIntegerI64): Duration {.inline.} =
  ## Initialize Duration with weeks value ``v``.
  result.value = int64(v) * Week.value

func nanoseconds*(v: Duration): int64 {.inline.} =
  ## Round Duration ``v`` to nanoseconds.
  result = v.value

func microseconds*(v: Duration): int64 {.inline.} =
  ## Round Duration ``v`` to microseconds.
  result = v.value div Microsecond.value

func milliseconds*(v: Duration): int64 {.inline.} =
  ## Round Duration ``v`` to milliseconds.
  result = v.value div Millisecond.value

func seconds*(v: Duration): int64 {.inline.} =
  ## Round Duration ``v`` to seconds.
  result = v.value div Second.value

func minutes*(v: Duration): int64 {.inline.} =
  ## Round Duration ``v`` to minutes.
  result = v.value div Minute.value

func hours*(v: Duration): int64 {.inline.} =
  ## Round Duration ``v`` to hours.
  result = v.value div Hour.value

func days*(v: Duration): int64 {.inline.} =
  ## Round Duration ``v`` to days.
  result = v.value div Day.value

func weeks*(v: Duration): int64 {.inline.} =
  ## Round Duration ``v`` to weeks.
  result = v.value div Week.value

func nanos*(v: SomeIntegerI64): Duration {.inline.} =
  result = nanoseconds(v)

func micros*(v: SomeIntegerI64): Duration {.inline.} =
  result = microseconds(v)

func millis*(v: SomeIntegerI64): Duration {.inline.} =
  result = milliseconds(v)

func secs*(v: SomeIntegerI64): Duration {.inline.} =
  result = seconds(v)

func nanos*(v: Duration): int64 {.inline.} =
  result = nanoseconds(v)

func micros*(v: Duration): int64 {.inline.} =
  result = microseconds(v)

func millis*(v: Duration): int64 {.inline.} =
  result = milliseconds(v)

func secs*(v: Duration): int64 {.inline.} =
  result = seconds(v)

func `$`*(a: Duration): string {.inline.} =
  ## Returns string representation of Duration ``a`` as nanoseconds value.
  var v = a.value
  if v >= Week.value:
    result = $(v div Week.value) & "w"
    v = v mod Week.value
  if v >= Day.value:
    result &= $(v div Day.value) & "d"
    v = v mod Day.value
  if v >= Hour.value:
    result &= $(v div Hour.value) & "h"
    v = v mod Hour.value
  if v >= Minute.value:
    result &= $(v div Minute.value) & "m"
    v = v mod Minute.value
  if v >= Second.value:
    result &= $(v div Second.value) & "s"
    v = v mod Second.value
  if v >= Millisecond.value:
    result &= $(v div Millisecond.value) & "ms"
    v = v mod Millisecond.value
  if v >= Microsecond.value:
    result &= $(v div Microsecond.value) & "us"
    v = v mod Microsecond.value
  result &= $(v div Nanosecond.value) & "ns"

func `$`*(a: Moment): string {.inline.} =
  ## Returns string representation of Moment ``a`` as nanoseconds value.
  result = $(a.value)
  result.add("ns")

func isZero*(a: Duration): bool {.inline.} =
  ## Returns ``true`` if Duration ``a`` is ``0``.
  result = (a.value == 0)

func isInfinite*(a: Duration): bool {.inline.} =
  ## Returns ``true`` if Duration ``a`` is infinite.
  result = (a.value == InfiniteDuration.value)

proc now*(t: typedesc[Moment]): Moment {.inline.} =
  ## Returns current moment in time as Moment.
  result.value = int64(fastEpochTimeNano())

func init*(t: typedesc[Moment], value: int64, precision: Duration): Moment =
  ## Initialize Moment with absolute time value ``value`` with precision
  ## ``precision``.
  result.value = value * precision.value

func epochSeconds*(moment: Moment): int64 =
  moment.value div Second.value

func epochNanoSeconds*(moment: Moment): int64 =
  moment.value

proc fromNow*(t: typedesc[Moment], a: Duration): Moment {.inline.} =
  ## Returns moment in time which is equal to current moment + Duration.
  result = Moment.now() + a

when defined(posix):
  from posix import Time, Suseconds, Timeval, Timespec

  func toTimeval*(a: Duration): Timeval =
    ## Convert Duration ``a`` to ``Timeval`` object.
    let m = a.value mod Second.value
    result.tv_sec = Time(a.value div Second.value)
    result.tv_usec = Suseconds(m div Microsecond.value)

  func toTimespec*(a: Duration): Timespec =
    ## Convert Duration ``a`` to ``Timespec`` object.
    result.tv_sec = Time(a.value div Second.value)
    result.tv_nsec = int(a.value mod Second.value)

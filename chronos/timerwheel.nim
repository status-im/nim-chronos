import std/lists
import ./timer

const useBuiltins = not defined(noIntrinsicsBitOpts)

when (defined(gcc) or defined(llvm_gcc) or defined(clang)) and useBuiltins:
  # Returns the number of leading 0-bits in ``x``, starting at the most
  # significant bit position. If ``x`` is 0, the result is undefined.
  func builtin_clz(x: cuint): cint {.
       importc: "__builtin_clz", nodecl.}
  func builtin_clzll(x: culonglong): cint {.
       importc: "__builtin_clzll", nodecl.}
  # Returns the number of trailing 0-bits in ``x``, starting at the least
  # significant bit position. If ``x`` is 0, the result is undefined.
  func builtin_ctz(x: cuint): cint {.
       importc: "__builtin_ctz", nodecl.}
  func builtin_ctzll(x: culonglong): cint {.
       importc: "__builtin_ctzll", nodecl.}

  proc ctz32*(value: uint32): int {.noinit, inline.} =
    doAssert(value != 0'u32)
    int(builtin_ctz(cuint(value)))

  proc clz32*(value: uint32): int {.noinit, inline.} =
    doAssert(value != 0'u32)
    int(builtin_clz(cuint(value)))

  proc ctz64*(value: uint64): int {.noinit, inline.} =
    doAssert(value != 0'u64)
    int(builtin_ctzll(culonglong(value)))

  proc clz64*(value: uint64): int {.noinit, inline.} =
    doAssert(value != 0'u64)
    int(builtin_clzll(culonglong(value)))

elif defined(vcc) and useBuiltins:
  # Search the ``mask`` data from most significant bit (MSB) to least
  # significant bit (LSB) for a set bit (1). This function returns non-zero
  # if ``index`` was set, or ``0`` if no set bits were found.
  func bitScanReverse(index: ptr uint32, mask: uint32): cuchar {.
       importc: "_BitScanReverse", header: "<intrin.h>".}
  # Search the ``mask`` data from least significant bit (LSB) to the most
  # significant bit (MSB) for a set bit (1). This function returns non-zero
  # if ``index`` was set, or ``0`` if no set bits were found.
  func bitScanForward(index: ptr uint32, mask: uint32): cuchar {.
       importc: "_BitScanForward", header: "<intrin.h>".}

  when sizeof(int) == 8:
    func bitScanReverse64(index: ptr uint32, mask: uint64): cuchar {.
         importc: "_BitScanReverse64", header: "<intrin.h>".}
    func bitScanForward64(index: ptr uint32, mask: uint64): cuchar {.
         importc: "_BitScanForward64", header: "<intrin.h>".}

  proc ctz32*(value: uint32): int {.noinit, inline.} =
    doAssert(value != 0'u32)
    var zeros = 0'u32
    discard bitScanForward(addr zeros, value)
    int(zeros)

  proc clz32*(value: uint32): int {.noinit, inline.} =
    doAssert(value != 0'u32)
    var zeros = 0'u32
    discard bitScanReverse(addr zeros, value)
    31 - int(zeros)

  when sizeof(int) == 8:
    proc ctz64*(value: uint64): int {.noinit, inline.} =
      doAssert(value != 0'u64)
      var zeros = 0'u32
      discard bitScanForward64(addr zeros, value)
      int(zeros)

    proc clz64*(value: uint64): int {.noinit, inline.} =
      doAssert(value != 0'u64)
      var zeros = 0'u32
      discard bitScanReverse64(addr zeros, value)
      63 - int(zeros)
  else:
    proc ctz64*(value: uint64): int {.noinit, inline.} =
      var
        lo: uint32 = uint32(value and 0xFFFF_FFFF'u32)
        hi: uint32 = uint32(value shr 32)
      if lo != 0'u32: ctz32(lo) else: 32 + ctz32(hi)

    proc clz64*(value: uint64): int {.noinit, inline.} =
      var
        lo: uint32 = uint32(value and 0xFFFF_FFFF'u32)
        hi: uint32 = uint32(value shr 32)
      if hi != 0'u32: clz32(hi) else: 32 + clz32(lo)

elif defined(icc) and useBuiltins:
  # Sets ``p`` to the bit index of the least significant set bit of ``b``
  # or leaves it unchanged if ``b`` is zero. The function returns a non-zero
  # result when ``b`` is non-zero and returns zero when ``b`` is zero.
  func bitScanForward(p: ptr uint32, b: uint32): cuchar {.
       importc: "_BitScanForward", header: "<immintrin.h>".}
  # Sets ``p`` to the bit index of the most significant set bit of ``b``
  # or leaves it unchanged if ``b`` is zero. The function returns a non-zero
  # result when ``b`` is non-zero and returns zero when ``b`` is zero.
  func bitScanReverse(p: ptr uint32, b: uint32): cuchar {.
       importc: "_BitScanReverse", header: "<immintrin.h>".}

  when sizeof(int) == 8:
    func bitScanForward64(p: ptr uint32, b: uint64): cuchar {.
         importc: "_BitScanForward64", header: "<immintrin.h>".}
    func bitScanReverse64(p: ptr uint32, b: uint64): cuchar {.
         importc: "_BitScanReverse64", header: "<immintrin.h>".}

  proc ctz32*(value: uint32): int {.noinit, inline.} =
    doAssert(value != 0'u32)
    var zeros = 0'u32
    discard bitScanForward(addr zeros, value)
    int(zeros)

  proc clz32*(value: uint32): int {.noinit, inline.} =
    doAssert(value != 0'u32)
    var zeros = 0'u32
    discard bitScanReverse(addr zeros, value)
    31 - int(zeros)

  when sizeof(int) == 8:
    proc ctz64*(value: uint64): int {.noinit, inline.} =
      doAssert(value != 0'u64)
      var zeros = 0'u32
      discard bitScanForward64(addr zeros, value)
      int(zeros)

    proc clz64*(value: uint64): int {.noinit, inline.} =
      doAssert(value != 0'u64)
      var zeros = 0'u32
      discard bitScanReverse64(addr zeros, value)
      63 - int(zeros)
  else:
    proc ctz64*(value: uint64): int {.noinit, inline.} =
      var
        lo: uint32 = uint32(value and 0xFFFF_FFFF'u32)
        hi: uint32 = uint32(value shr 32)
      if lo != 0'u32: ctz32(lo) else: 32 + ctz32(hi)

    proc clz64*(value: uint64): int {.noinit, inline.} =
      var
        lo: uint32 = uint32(value and 0xFFFF_FFFF'u32)
        hi: uint32 = uint32(value shr 32)
      if hi != 0'u32: clz32(hi) else: 32 + clz32(lo)

else:
  proc ctz32*(value: uint32): int {.noinit.} =
    ## Returns the 1-based index of the least significant set bit of ``x``.
    ## https://en.wikipedia.org/wiki/De_Bruijn_sequence
    doAssert(value != 0'u32)
    const lookup = [
      0'u8, 1, 28, 2, 29, 14, 24, 3, 30, 22, 20, 15, 25, 17, 4, 8,
      31, 27, 13, 23, 21, 19, 16, 7, 26, 12, 18,  6, 11, 5, 10, 9]

    template keepLowestBit(n: uint32): uint32 =
      let k = not(n) + 1
      n and k

    cast[int](lookup[(keepLowestBit(value) * 0x077CB531'u32) shr 27])

  proc clz32*(value: uint32): int {.noinit.} =
    doAssert(value != 0'u32)
    const lookup = [
      0'u8, 1, 16, 2, 29, 17, 3, 22, 30, 20, 18, 11, 13, 4, 7, 23,
      31, 15, 28, 21, 19, 10, 12, 6, 14, 27, 9, 5, 26,  8, 25, 24]

    template keepHighestBit(v: uint32): uint32 =
      var n = v or (v shr 1)
      n = n or (n shr 2)
      n = n or (n shr 4)
      n = n or (n shr 8)
      n = n or (n shr 16)
      n - (n shr 1)

    31 - cast[int](lookup[(keepHighestBit(value) * 0x06EB14F9'u32) shr 27])

  proc ctz64*(value: uint64): int {.noinit, inline.} =
      var
        lo: uint32 = uint32(value and 0xFFFF_FFFF'u32)
        hi: uint32 = uint32(value shr 32)
      if lo != 0'u32: ctz32(lo) else: 32 + ctz32(hi)

  proc clz64*(value: uint64): int {.noinit, inline.} =
    var
      lo: uint32 = uint32(value and 0xFFFF_FFFF'u32)
      hi: uint32 = uint32(value shr 32)
    if hi != 0'u32: clz32(hi) else: 32 + clz32(lo)

const
  WHEEL_BIT = 6
  WHEEL_NUM = 4
  WHEEL_LEN = (1'u64 shl WHEEL_BIT)
  WHEEL_MAX = (WHEEL_LEN - 1)
  WHEEL_MASK = (WHEEL_LEN - 1)
  TIMEOUT_MAX = ((1'u64 shl (WHEEL_BIT * WHEEL_NUM)) - 1)

when WHEEL_BIT == 6:
  template clz(n) = clz64(n)
  template ctz(n) = ctz64(n)
  template fls(n) = 64 - clz64(n)
else:
  template clz(n) = clz32(n)
  template ctz(n) = ctz32(n)
  template fls(n) = 32 - clz32(n)

when WHEEL_BIT == 6:
  type Wheel = uint64
elif WHEEL_BIT == 5:
  type Wheel = uint32
elif WHEEL_BIT == 4:
  type Wheel = uint16
elif WHEEL_BIT == 3:
  type Wheel = uint8
else:
  {.fatal: "Sorry, WHEEL_BIT value less than 3 are not supported!".}

proc rotl(v: Wheel, c: int): Wheel {.inline, noinit.} =
  if (c and (sizeof(v) * 8 - 1)) == 0:
    return v
  Wheel((v shl c) or (v shr (sizeof(v) * 8 - c)))

proc rotr(v: Wheel, c: int): Wheel {.inline, noinit.} =
  if (c and (sizeof(v) * 8 - 1)) == 0:
    return v
  Wheel((v shr c) or (v shl (sizeof(v) * 8 - c)))

type
  WTimeout = object
  TimeoutList = DoublyLinkedList[WTimeout]
  TimoutsWheelImpl = object
    wheel: array[WHEEL_NUM, array[WHEEL_LEN, TimeoutList]]
    expired: TimeoutList
    pending: array[WHEEL_NUM, Wheel]
    curtime: Moment
  TimeoutWheelRef* = ref TimoutsWheelImpl

proc init*(t: typedesc[TimeoutWheelRef]): TimeoutWheelRef =
  var res = TimeoutWheelRef()

when isMainModule:

  proc naiveClz(bits: int, value: uint64): int =
    var
      r = 0
      bit = 1'u64 shl (bits - 1)
    while (bit != 0) and ((value and bit) == 0):
      inc(r)
      bit = bit shr 1
    r

  proc naiveCtz(bits: int, value: uint64): int =
    var
      r = 0
      bit = 1'u64
    while (bit != 0'u64) and ((value and bit) == 0):
      inc(r)
      bit = bit shl 1
      if r == bits:
        break
    r

  proc check(v64: uint64): bool =
    let v32 = uint32(v64 and 0xFFFF_FFFF'u32)
    if v64 == 0'u64:
      return true
    if v32 == 0'u32:
      return true
    if naiveClz(64, v64) != clz64(v64):
      return false
    if naiveCtz(64, v64) != ctz64(v64):
      return false
    if naiveClz(32, uint64(v32)) != clz32(v32):
      return false
    if naiveCtz(32, uint64(v32)) != ctz32(v32):
      return false
    true

  for i in 0 ..< 64:
    var x = 1'u64 shl i
    echo x
    doAssert(check(x))
    dec(x)
    doAssert(check(x))

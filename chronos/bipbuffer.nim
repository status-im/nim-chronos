#
#                     Chronos
#
#  (c) Copyright 2018-Present Status Research & Development GmbH
#
#                Licensed under either of
#    Apache License, version 2.0, (LICENSE-APACHEv2)
#                MIT license (LICENSE-MIT)

## This module implements Bip Buffer (bi-partite circular buffer) by Simone
## Cooke.
##
## The Bip-Buffer is like a circular buffer, but slightly different. Instead of
## keeping one head and tail pointer to the data in the buffer, it maintains two
## revolving regions, allowing for fast data access without having to worry
## about wrapping at the end of the buffer. Buffer allocations are always
## maintained as contiguous blocks, allowing the buffer to be used in a highly
## efficient manner with API calls, and also reducing the amount of copying
## which needs to be performed to put data into the buffer. Finally, a two-phase
## allocation system allows the user to pessimistically reserve an area of
## buffer space, and then trim back the buffer to commit to only the space which
## was used.
##
## https://www.codeproject.com/Articles/3479/The-Bip-Buffer-The-Circular-Buffer-with-a-Twist

{.push raises: [].}

import results

type
  BipPos = object
    start: Natural
    finish: Natural

  BipBuffer* = object
    a, b, r: BipPos
    data: seq[byte]

proc init*(t: typedesc[BipBuffer], size: int): BipBuffer =
  ## Creates new Bip Buffer with size `size`.
  BipBuffer(data: newSeq[byte](size))

template len(pos: BipPos): Natural =
  pos.finish - pos.start

template zero(pos: var BipPos) =
  pos = BipPos()

func init(t: typedesc[BipPos], start, finish: Natural): BipPos =
  BipPos(start: start, finish: finish)

func calcReserve(bp: BipBuffer): tuple[space: Natural, start: Natural] =
  if len(bp.b) > 0:
    (Natural(bp.a.start - bp.b.finish), bp.b.finish)
  else:
    let spaceAfterA = Natural(len(bp.data) - bp.a.finish)
    if spaceAfterA >= bp.a.start:
      (spaceAfterA, bp.a.finish)
    else:
      (bp.a.start, Natural(0))

func freeSpace*(bp: BipBuffer): Natural =
  ## Returns amount of free space in buffer `bp`.
  var sum: Natural
  if len(bp.b) > 0:
    sum += (bp.a.start - bp.b.finish)
  else:
    sum += bp.a.start
  sum += Natural(len(bp.data)) - bp.a.finish
  sum

func availSpace*(bp: BipBuffer): Natural =
  ## Returns amount of space available for reserve in buffer `bp`.
  let (res, _) = bp.calcReserve()
  res

func usedSpace*(bp: BipBuffer): Natural =
  ## Returns amount of used space in buffer `bp`.
  len(bp.b) + len(bp.a)

proc reserve*(bp: var BipBuffer, size: Natural): Result[Natural, cstring] =
  ## Reserve `size` bytes in buffer. Returns number of bytes reserved.
  doAssert(size <= len(bp.data))
  let (availableSpace, reserveStart) = bp.calcReserve()
  if availableSpace == 0:
    return err("Not enough space available")
  let reserveLength = min(availableSpace, size)
  bp.r = BipPos.init(reserveStart, Natural(reserveStart + reserveLength))
  ok(availableSpace)

proc reserve*(bp: var BipBuffer): Natural =
  ## Reserve all available free space in buffer. Returns number of bytes
  ## reserved.
  ##
  ## Note, this procedure will raise Defect if there is no free space available.
  let (availableSpace, reserveStart) = bp.calcReserve()
  doAssert(availableSpace > 0, "Not enough space available")
  bp.r = BipPos.init(reserveStart, Natural(reserveStart + availableSpace))
  availableSpace

proc reserve*(bp: var BipBuffer,
              pt, st: typedesc): tuple[data: pt, size: st] =
  ## Reserve all available free space in buffer. Returns current reserved range
  ## as pointer of type `pt` and size of type `st`.
  ##
  ## Note, this procedure will raise Defect if there is no free space available.
  let (availableSpace, reserveStart) = bp.calcReserve()
  doAssert(availableSpace > 0, "Not enough space available")
  bp.r = BipPos.init(reserveStart, Natural(reserveStart + availableSpace))
  (cast[pt](addr bp.data[bp.r.start]), cast[st](len(bp.r)))

func getReserve*(bp: var BipBuffer,
                 pt: typedesc, st: typedesc): tuple[data: pointer, size: cint] =
  ## Returns current reserved range as pointer + size tuple.
  (cast[pt](addr bp.data[bp.r.start]), st(len(bp.r)))

proc commit*(bp: var BipBuffer, size: Natural) =
  ## Updates structure's pointers when new data inserted into buffer.
  doAssert(len(bp.r) >= size,
    "Committed size could not be larger than the previously reserved one")
  if size == 0:
    bp.r.zero()
    return

  let toCommit = min(size, len(bp.r))
  if len(bp.a) == 0 and len(bp.b) == 0:
    bp.a.start = bp.r.start
    bp.a.finish = bp.r.start + toCommit
  elif bp.r.start == bp.a.finish:
    bp.a.finish += toCommit
  else:
    bp.b.finish += toCommit
  bp.r.zero()

proc consume*(bp: var BipBuffer, size: Natural): Natural =
  ## The procedure removes/frees `size` bytes from the buffer.
  ## Returns number of bytes actually removed.
  var currentSize = size
  if currentSize >= len(bp.a):
    currentSize -= len(bp.a)
    bp.a = bp.b
    bp.b.zero()
    if currentSize >= len(bp.a):
      currentSize -= len(bp.a)
      bp.a.zero()
      size - currentSize
    else:
      bp.a.start += currentSize
      size
  else:
    bp.a.start += currentSize
    size

iterator bytes*(bp: BipBuffer): byte =
  ## Iterates over all the bytes in the buffer.
  for index in bp.a.start ..< bp.a.finish:
    yield bp.data[index]
  for index in bp.b.start ..< bp.b.finish:
    yield bp.data[index]

iterator regions*(bp: var BipBuffer,
                  pt, st: typedesc): tuple[data: pt, size: st] =
  ## Iterates over all the regions (`a` and `b`) in the buffer.
  if len(bp.a) > 0:
    yield (cast[pt](addr bp.data[bp.a.start]), cast[st](len(bp.a)))
  if len(bp.b) > 0:
    yield (cast[pt](addr bp.data[bp.b.start]), cast[st](len(bp.b)))

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

template reset(pos: var BipPos) =
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

func availSpace*(bp: BipBuffer): Natural =
  ## Returns amount of space available for reserve in buffer `bp`.
  let (res, _) = bp.calcReserve()
  res

func len*(bp: BipBuffer): Natural =
  ## Returns amount of used space in buffer `bp`.
  len(bp.b) + len(bp.a)

proc reserve*(
    bp: var BipBuffer, size: Natural = 0
): tuple[data: ptr byte, size: Natural] =
  ## Reserve `size` bytes in buffer.
  ##
  ## If `size == 0` (default) reserve all available space from buffer.
  ##
  ## If there is not enough space in buffer for resevation - error will be
  ## returned.
  ##
  ## Returns current reserved range as pointer of type `pt` and size of
  ## type `st`.
  const ErrorMessage = "Not enough space available"
  doAssert(size <= len(bp.data))
  let (availableSpace, reserveStart) = bp.calcReserve()
  if availableSpace == 0:
    raiseAssert ErrorMessage
  let reserveLength =
    if size == 0:
      availableSpace
    else:
      if size < availableSpace:
        raiseAssert ErrorMessage
      size
  bp.r = BipPos.init(reserveStart, Natural(reserveStart + reserveLength))
  (addr bp.data[bp.r.start], len(bp.r))

proc commit*(bp: var BipBuffer, size: Natural) =
  ## Updates structure's pointers when new data inserted into buffer.
  doAssert(
    len(bp.r) >= size,
    "Committed size could not be larger than the previously reserved one",
  )
  if size == 0:
    bp.r.reset()
    return

  let toCommit = min(size, len(bp.r))
  if len(bp.a) == 0 and len(bp.b) == 0:
    bp.a.start = bp.r.start
    bp.a.finish = bp.r.start + toCommit
  elif bp.r.start == bp.a.finish:
    bp.a.finish += toCommit
  else:
    bp.b.finish += toCommit
  bp.r.reset()

proc consume*(bp: var BipBuffer, size: Natural) =
  ## The procedure removes/frees `size` bytes from the buffer ``bp``.
  var currentSize = size
  if currentSize >= len(bp.a):
    currentSize -= len(bp.a)
    bp.a = bp.b
    bp.b.reset()
    if currentSize >= len(bp.a):
      currentSize -= len(bp.a)
      bp.a.reset()
    else:
      bp.a.start += currentSize
  else:
    bp.a.start += currentSize

iterator items*(bp: BipBuffer): byte =
  ## Iterates over all the bytes in the buffer.
  for index in bp.a.start ..< bp.a.finish:
    yield bp.data[index]
  for index in bp.b.start ..< bp.b.finish:
    yield bp.data[index]

iterator regions*(bp: var BipBuffer): tuple[data: ptr byte, size: Natural] =
  ## Iterates over all the regions (`a` and `b`) in the buffer.
  if len(bp.a) > 0:
    yield (addr bp.data[bp.a.start], len(bp.a))
  if len(bp.b) > 0:
    yield (addr bp.data[bp.b.start], len(bp.b))

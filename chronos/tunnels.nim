#
#          Chronos multi-threading tunnels
#             (c) Copyright 2018-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)
import selectors, strutils
import asyncloop, handles, transport

const hasThreadSupport* = compileOption("threads")

when hasThreadSupport:
  import locks

when defined(windows):
  import winlean

  proc createEvent(lpEventAttributes: ptr SECURITY_ATTRIBUTES,
                   bManualReset: DWORD, bInitialState: DWORD,
                   lpName: ptr Utf16Char): Handle
       {.stdcall, dynlib: "kernel32", importc: "CreateEventW".}

type
  RawTunnelImpl {.pure, final.} = object
    rd, wr, count, mask: int
    maxItems: int
    refCount: int
    data: ptr UncheckedArray[byte]
    when hasThreadSupport:
      lock: Lock
    when defined(windows):
      event: Handle
    else:
      event: SelectEvent

  RawTunnel = ptr RawTunnelImpl
  Tunnel*[Msg] = RawTunnel
  TunnelError* = object of CatchableError

proc initLocks(rtun: RawTunnel) {.inline.} =
  ## Initialize and create OS locks.
  when hasThreadSupport:
    initLock(rtun.lock)
  else:
    discard

  when defined(windows):
    rtun.event = createEvent(nil, DWORD(0), DWORD(0), nil)
  else:
    rtun.event = newSelectEvent()

proc deinitLocks(rtun: RawTunnel) {.inline.} =
  ## Deinitialize and close OS locks.
  when hasThreadSupport:
    deinitLock(rtun.lock)
  else:
    discard

  when defined(windows):
    discard winlean.closeHandle(rtun.event)
  else:
    selectors.close(rtun.event)

proc acquireLock(rtun: RawTunnel) {.inline.} =
  ## Acquire lock in multi-threaded mode and do nothing in
  ## single-threaded mode.
  when hasThreadSupport:
    acquire(rtun.lock)
  else:
    discard

proc releaseLock(rtun: RawTunnel) {.inline.} =
  ## Release lock in multi-threaded mode and do nothing in
  ## single-threaded mode.
  when hasThreadSupport:
    release(rtun.lock)
  else:
    discard

proc fireEvent(rtun: RawTunnel) {.inline.} =
  ## Trigger OS event for Windows and SelectEvent for *nix.
  when defined(windows):
    discard setEvent(rtun.event)
  else:
    trigger(rtun.event)

proc waitForEvent(rtun: RawTunnel): Future[bool] =
  ## Wait asynchronously for OS event.
  when defined(windows):
    result = awaitForSingleObject(rtun.event, InfiniteDuration)
  else:
    result = awaitForSelectEvent(rtun.event, InfiniteDuration)

proc newTunnel*[Msg](maxItems: int = -1): Tunnel[Msg] =
  ## Create new Tunnel[Msg] with queue size ``maxItems``.
  ##
  ## If ``maxItems`` equal to ``-1`` (default value), then queue size is
  ## unlimited.
  let loop = getGlobalDispatcher()
  result = cast[Tunnel[Msg]](allocShared(sizeof(RawTunnelImpl)))
  result.initLocks()
  result.mask = -1
  result.maxItems = maxItems
  result.count = 0
  result.wr = 0
  result.rd = 0
  result.refCount = 0
  result.data = cast[ptr UncheckedArray[byte]](0)

proc open*[Msg](tun: Tunnel[Msg]) =
  ## Open tunnel ``tun``.
  let loop = getGlobalDispatcher()
  tun.acquireLock()
  inc(tun.refCount)
  tun.releaseLock()

proc close*[Msg](tun: Tunnel[Msg]) =
  ## Close tunnel ``tun``.
  tun.acquireLock()
  if tun.refCount == 0:
    if not(isNil(tun.data)):
      deallocShared(cast[pointer](tun.data))
    tun.deinitLocks()
    deallocShared(cast[pointer](tun))
  else:
    dec(tun.refCount)
    tun.releaseLock()

proc `$`*[Msg](tun: Tunnel[Msg]): string =
  ## Dump tunnel ``tun`` debugging information as string.
  tun.acquireLock()
  result = "Tunnel 0x" & toHex(cast[uint](tun)) & " ("
  result.add("event = 0x" & toHex(cast[uint](tun.event)))
  result.add(", rd = " & $tun.rd)
  result.add(", wr = " & $tun.wr)
  result.add(", count = " & $tun.count)
  result.add(", mask = 0x" & toHex(tun.mask))
  result.add(", data = 0x" & toHex(cast[uint](tun.data)))
  result.add(", maxItems = " & $tun.maxItems)
  result.add(", refCount = " & $tun.refCount)
  result.add(")")
  tun.releaseLock()

proc rawSend(rtun: RawTunnel, pbytes: pointer, nbytes: int) =
  var cap = rtun.mask + 1
  if rtun.count >= cap:
    if cap == 0: cap = 1
    var n = cast[ptr UncheckedArray[byte]](allocShared0(cap * 2 * nbytes))
    var z = 0
    var i = rtun.rd
    var c = rtun.count

    while c > 0:
      dec(c)
      copyMem(addr(n[z * nbytes]), addr(rtun.data[i * nbytes]), nbytes)
      i = (i + 1) and rtun.mask
      inc(z)

    if not isNil(rtun.data):
      deallocShared(rtun.data)

    rtun.data = n
    rtun.mask = (cap shl 1) - 1
    rtun.wr = rtun.count
    rtun.rd = 0

  copyMem(addr(rtun.data[rtun.wr * nbytes]), pbytes, nbytes)
  inc(rtun.count)
  rtun.wr = (rtun.wr + 1) and rtun.mask

proc send*[Msg](tun: Tunnel[Msg], msg: Msg) {.async.} =
  ## Send message ``msg`` over tunnel ``tun``.
  tun.acquireLock()
  if tun.refCount == 0:
    raise newException(TunnelError, "Tunnel closed or not opened")
  if tun.maxItems > 0:
    # Wait until count is less then `maxItems`.
    while tun.count >= tun.maxItems:
      tun.releaseLock()
      let res = await tun.waitForEvent()
      tun.acquireLock()

  rawSend(tun, unsafeAddr msg, sizeof(Msg))
  tun.fireEvent()
  tun.releaseLock()

proc rawRecv(rtun: RawTunnel, pbytes: pointer, nbytes: int) {.inline.} =
  doAssert(rtun.count > 0)
  dec(rtun.count)
  copyMem(pbytes, addr rtun.data[rtun.rd * nbytes], nbytes)
  rtun.rd = (rtun.rd + 1) and rtun.mask

proc recv*[Msg](tun: Tunnel[Msg]): Future[Msg] {.async.} =
  ## Wait for message ``Msg`` in tunnel ``tun`` asynchronously and receive
  ## it when it become available.
  var rmsg: Msg
  tun.acquireLock()
  while tun.count <= 0:
    tun.releaseLock()
    let res = await tun.waitForEvent()
    tun.acquireLock()

  rawRecv(tun, addr rmsg, sizeof(Msg))
  result = rmsg

  if tun.maxItems > 0 and (tun.count == (tun.maxItems - 1)):
    tun.fireEvent()
  tun.releaseLock()

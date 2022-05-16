#
#                  Chronos' OS helpers
#
#  (c) Copyright 2022-Present Status Research & Development GmbH
#
#                Licensed under either of
#    Apache License, version 2.0, (LICENSE-APACHEv2)
#                MIT license (LICENSE-MIT)
import stew/results
export results
import osdefs

{.push raises: [Defect].}

when defined(windows):
  type
    WINDESCRIPTOR* = SocketHandle|HANDLE
  template handleEintr*(body: untyped): untyped =
    discard

  proc setDescriptorInheritance*(s: WINDESCRIPTOR,
                                 value: bool): Result[void, OSErrorCode] =
    var flags = 0'u32
    let fd = when s is SocketHandle: HANDLE(s) else: s
    if getHandleInformation(fd, flags) == FALSE:
      return err(osLastError())
    if value != ((flags and HANDLE_FLAG_INHERIT) == HANDLE_FLAG_INHERIT):
      let mode = if value: HANDLE_FLAG_INHERIT else: 0'u32
      if setHandleInformation(fd, HANDLE_FLAG_INHERIT, mode) == FALSE:
        return err(osLastError())
    ok()

  proc getDescriptorInheritance*(s: WINDESCRIPTOR
                                ): Result[bool, OSErrorCode] =
    var flags = 0'u32
    let fd = when s is SocketHandle: HANDLE(s) else: s
    if getHandleInformation(fd, flags) == FALSE:
      return err(osLastError())
    ok((flags and HANDLE_FLAG_INHERIT) == HANDLE_FLAG_INHERIT)

  proc setDescriptorBlocking*(s: SocketHandle,
                              value: bool): Result[void, OSErrorCode] =
    var mode = clong(ord(not value))
    if ioctlsocket(s, osdefs.FIONBIO, addr(mode)) == -1:
      return err(osLastError())
    ok()

  proc setDescriptorFlags*(s: WINDESCRIPTOR, nonblock,
                           cloexec: bool): Result[void, OSErrorCode] =
    ? setDescriptorBlocking(s, not(nonblock))
    ? setDescriptorInheritance(s, not(cloexec))
    ok()

  proc closeFd*(s: SocketHandle): int =
    int(osdefs.closesocket(s))

  proc closeFd*(s: HANDLE): int =
    if osdefs.closeHandle(s) == TRUE: 0 else: -1

else:
  template handleEintr*(body: untyped): untyped =
    var res = 0
    while true:
      res = body
      if not((res == -1) and (osLastError() == EINTR)):
        break
    res

  proc setDescriptorBlocking*(s: cint,
                              value: bool): Result[void, OSErrorCode] =
    let flags = handleEintr(osdefs.fcntl(s, osdefs.F_GETFL))
    if flags == -1:
      return err(osLastError())
    if value != not((flags and osdefs.O_NONBLOCK) == osdefs.O_NONBLOCK):
      let mode =
        if value:
          flags and not(osdefs.O_NONBLOCK)
        else:
          flags or osdefs.O_NONBLOCK
      if handleEintr(osdefs.fcntl(s, osdefs.F_SETFL, mode)) == -1:
        return err(osLastError())
    ok()

  proc setDescriptorInheritance*(s: cint,
                                 value: bool): Result[void, OSErrorCode] =
    let flags = handleEintr(osdefs.fcntl(s, osdefs.F_GETFD))
    if flags == -1:
      return err(osLastError())
    if value != not((flags and osdefs.FD_CLOEXEC) == osdefs.FD_CLOEXEC):
      let mode =
        if value:
          flags and not(osdefs.FD_CLOEXEC)
        else:
          flags or osdefs.FD_CLOEXEC
      if handleEintr(osdefs.fcntl(s, osdefs.F_SETFD, mode)) == -1:
        return err(osLastError())
    ok()

  proc getDescriptorInheritance*(s: cint): Result[bool, OSErrorCode] =
    let flags = handleEintr(osdefs.fcntl(s, osdefs.F_GETFD))
    if flags == -1:
      return err(osLastError())
    ok((flags and osdefs.FD_CLOEXEC) == osdefs.FD_CLOEXEC)

  proc setDescriptorFlags*(s: cint, nonblock,
                           cloexec: bool): Result[void, OSErrorCode] =
    ? setDescriptorBlocking(s, not(nonblock))
    ? setDescriptorInheritance(s, not(cloexec))
    ok()

  proc closeFd*(s: cint): int =
    handleEintr(osdefs.close(s))

  proc closeFd*(s: SocketHandle): int =
    handleEintr(osdefs.close(cint(s)))

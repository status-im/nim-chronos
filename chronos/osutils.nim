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
  template handleEintr*(body: untyped): untyped =
    discard

  proc setDescriptorInheritance*(s: SocketHandle|HANDLE,
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

  proc getDescriptorInheritance*(s: SocketHandle|HANDLE
                                ): Result[bool, OSErrorCode] =
    var flags = 0'u32
    let fd = when s is SocketHandle: HANDLE(s) else: s
    if getHandleInformation(fd, flags) == FALSE:
      return err(osLastError())
    ok((flags and HANDLE_FLAG_INHERIT) == HANDLE_FLAG_INHERIT)

  proc setDescriptorBlocking*(s: SocketHandle | HANDLE,
                              value: bool): Result[void, OSErrorCode] =
    # TODO: Here should be present code which will obtain handle type and check
    # for FILE_FLAG_OVERLAPPED (pipes) or WSA_FLAG_OVERLAPPED (socket).
    ok()

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
    let flags = handleEintr(osdefs.fcntl(cint(fd), osdefs.F_GETFD))
    if flags == -1:
      return err(osLastError())
    ok((flags and osdefs.FD_CLOEXEC) == osdefs.FD_CLOEXEC)

proc setDescriptorFlags*(s: SocketHandle|HANDLE|cint, nonblock,
                         cloexec: bool): Result[void, OSErrorCode] =
  ? setDescriptorBlocking(s, not(nonblock))
  ? setDescriptorInheritance(s, not(cloexec))
  ok()

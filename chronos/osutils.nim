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

when defined(windows) or defined(nimdoc):
  import stew/base10
  const PipeHeaderName* = r"\\.\pipe\LOCAL\chronos\"

type
  DescriptorFlag* {.pure.} = enum
    CloseOnExec, NonBlock

const
  AsyncDescriptorDefault* = {
    DescriptorFlag.CloseOnExec, DescriptorFlag.NonBlock}

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

  proc toWideString*(s: string): Result[LPWSTR, OSErrorCode] =
    if len(s) == 0:
      ok(cast[LPWSTR](alloc0(sizeof(WCHAR))))
    else:
      let charsNeeded = multiByteToWideChar(CP_UTF8, 0'u32,
                                            cast[ptr char](unsafeAddr s[0]),
                                            cint(len(s)), nil, cint(0))
      if charsNeeded <= cint(0):
        return err(osLastError())
      var buffer = cast[LPWSTR](alloc0((charsNeeded + 1) * sizeof(WCHAR)))
      let res = multiByteToWideChar(CP_UTF8, 0'u32,
                                    cast[ptr char](unsafeAddr s[0]),
                                    cint(len(s)), buffer, charsNeeded)
      if res != charsNeeded:
        err(osLastError())
      else:
        ok(buffer)

  proc toString*(w: LPWSTR): Result[string, OSErrorCode] =
    if isNil(w):
      ok("")
    else:
      let bytesNeeded = wideCharToMultiByte(CP_UTF8, 0'u32, w, cint(-1), nil,
                                            cint(0), nil, nil)
      if bytesNeeded <= cint(0):
        return err(osLastError())

      var buffer = newString(bytesNeeded)
      let res = wideCharToMultiByte(CP_UTF8, 0'u32, w, cint(-1),
                                    addr buffer[0], cint(len(buffer)), nil, nil)
      if res != bytesNeeded:
        err(osLastError())
      else:
        # We need to strip trailing `\x00`.
        for i in countdown(len(buffer) - 1, 0):
          if buffer[i] != '\x00':
            buffer.setLen(i + 1)
            break
        ok(buffer)

  proc free*(w: LPWSTR) =
    if not(isNil(w)):
      dealloc(cast[pointer](w))

  proc createOsPipe*(readset, writeset: set[DescriptorFlag]
                    ): Result[tuple[read: HANDLE, write: HANDLE], OSErrorCode] =
    var
      pipeIn, pipeOut: HANDLE
      widePipeName: LPWSTR
      uniq = 0'u64
      rsa = getSecurityAttributes(DescriptorFlag.CloseOnExec notin readset)
      wsa = getSecurityAttributes(DescriptorFlag.CloseOnExec notin writeset)

    while true:
      queryPerformanceCounter(uniq)
      let pipeName = PipeHeaderName & Base10.toString(uniq)

      let openMode =
        if DescriptorFlag.NonBlock in readset:
          osdefs.FILE_FLAG_FIRST_PIPE_INSTANCE or osdefs.FILE_FLAG_OVERLAPPED or
          osdefs.PIPE_ACCESS_INBOUND
        else:
          osdefs.FILE_FLAG_FIRST_PIPE_INSTANCE or osdefs.PIPE_ACCESS_INBOUND

      let pipeMode = osdefs.PIPE_TYPE_BYTE or osdefs.PIPE_READMODE_BYTE or
                     osdefs.PIPE_WAIT
      widePipeName =
        block:
          let res = pipeName.toWideString()
          if res.isErr():
            return err(res.error())
          res.get()
      pipeIn = createNamedPipe(widePipeName, openMode, pipeMode,
                               1'u32, osdefs.DEFAULT_PIPE_SIZE,
                               osdefs.DEFAULT_PIPE_SIZE, 0'u32, addr rsa)
      if pipeIn == osdefs.INVALID_HANDLE_VALUE:
        let errorCode = osLastError()
        free(widePipeName)
        # If error in {ERROR_ACCESS_DENIED, ERROR_PIPE_BUSY}, then named pipe
        # with such name already exists.
        if (errorCode == osdefs.ERROR_ACCESS_DENIED) or
           (errorCode == osdefs.ERROR_PIPE_BUSY):
          continue
        return err(errorCode)
      else:
        break

    let openMode = osdefs.GENERIC_WRITE or osdefs.FILE_WRITE_DATA or
                   osdefs.SYNCHRONIZE
    let openFlags =
      if DescriptorFlag.NonBlock in writeset:
        osdefs.FILE_FLAG_OVERLAPPED
      else:
        DWORD(0)

    pipeOut = createFile(widePipeName, openMode, 0, addr wsa,
                         osdefs.OPEN_EXISTING, openFlags, HANDLE(0))
    if pipeOut == osdefs.INVALID_HANDLE_VALUE:
      let errorCode = osLastError()
      free(widePipeName)
      discard closeFd(pipeIn)
      return err(errorCode)

    var ovl = osdefs.OVERLAPPED()
    let res =
      if DescriptorFlag.NonBlock in writeset:
        connectNamedPipe(pipeIn, addr ovl)
      else:
        connectNamedPipe(pipeIn, nil)
    if res == 0:
      let cleanupFlag =
        block:
          let errorCode = osLastError()
          case int(errorCode)
          of osdefs.ERROR_PIPE_CONNECTED:
            false
          of osdefs.ERROR_IO_PENDING:
            if DescriptorFlag.NonBlock in writeset:
              var bytesRead = 0.DWORD
              if getOverlappedResult(pipeIn, addr ovl, bytesRead, 1) == FALSE:
                true
              else:
                false
            else:
              true
          else:
            true
      if cleanupFlag:
        let errorCode = osLastError()
        free(widePipeName)
        discard closeFd(pipeIn)
        discard closeFd(pipeOut)
        return err(errorCode)
    ok((read: pipeIn, write: pipeOut))

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

  proc acceptConn*(a1: cint, a2: ptr SockAddr, a3: ptr SockLen,
                   a4: set[DescriptorFlag]): Result[cint, OSErrorCode] =
    when declared(accept4):
      let flags =
        block:
          var res: cint = 0
          if DescriptorFlag.CloseOnExec in a4:
            res = res or osdefs.SOCK_CLOEXEC
          if DescriptorFlag.NonBlock in a4:
            res = res or osdefs.SOCK_NONBLOCK
          res
      let res = cint(handleEintr(accept4(a1, a2, a3, flags)))
      if res == -1:
        return err(osLastError())
      ok(res)
    else:
      let sock = cint(handleEintr(cint(accept(SocketHandle(a1), a2, a3))))
      if sock == -1:
        return err(osLastError())
      let
        cloexec = DescriptorFlag.CloseOnExec in a4
        nonblock = DescriptorFlag.NonBlock in a4
      let res = setDescriptorFlags(sock, nonblock, cloexec)
      if res.isErr():
        discard closeFd(sock)
        return err(res.error())
      ok(sock)

  proc createOsPipe*(readset, writeset: set[DescriptorFlag]
                    ): Result[tuple[read: cint, write: cint], OSErrorCode] =
    when declared(pipe2):
      var fds: array[2, cint]
      let readFlags =
        block:
          var res = cint(0)
          if DescriptorFlag.CloseOnExec in readset:
            res = res or osdefs.O_CLOEXEC
          if DescriptorFlag.NonBlock in readset:
            res = res or osdefs.O_NONBLOCK
          res
      if osdefs.pipe2(fds, readFlags) == -1:
        return err(osLastError())
      if readset != writeset:
        let res = setDescriptorFlags(fds[1],
                                     DescriptorFlag.NonBlock in writeset,
                                     DescriptorFlag.CloseOnExec in writeset)
        if res.isErr():
          discard closeFd(fds[0])
          discard closeFd(fds[1])
          return err(res.error())
      ok((read: fds[0], write: fds[1]))
    else:
      var fds: array[2, cint]
      if osdefs.pipe(fds) == -1:
        return err(osLastError())
      block:
        let res = setDescriptorFlags(fds[0],
                                     DescriptorFlag.NonBlock in readset,
                                     DescriptorFlag.CloseOnExec in readset)
        if res.isErr():
          discard closeFd(fds[0])
          discard closeFd(fds[1])
          return err(res.error())
      block:
        let res = setDescriptorFlags(fds[1],
                                     DescriptorFlag.NonBlock in writeset,
                                     DescriptorFlag.CloseOnExec in writeset)
        if res.isErr():
          discard closeFd(fds[0])
          discard closeFd(fds[1])
          return err(res.error())
      ok((read: fds[0], write: fds[1]))

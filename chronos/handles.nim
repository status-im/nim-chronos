#
#                  Chronos Handles
#              (c) Copyright 2018-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import "."/[asyncloop, osdefs]
from nativesockets import Domain, Protocol, SockType, toInt
export Domain, Protocol, SockType


when defined(windows) or defined(nimdoc):
  import stew/base10
  const
    asyncInvalidSocket* = AsyncFD(-1)
    PipeHeaderName = r"\\.\pipe\LOCAL\chronos\"
else:
  const
    asyncInvalidSocket* = AsyncFD(osdefs.INVALID_SOCKET)

const
  asyncInvalidPipe* = asyncInvalidSocket

proc setSocketBlocking*(s: SocketHandle, blocking: bool): bool =
  ## Sets blocking mode on socket.
  when defined(windows) or defined(nimdoc):
    var mode = clong(ord(not blocking))
    if osdefs.ioctlsocket(s, osdefs.FIONBIO, addr(mode)) == -1:
      false
    else:
      true
  else:
    let x: int = osdefs.fcntl(s, osdefs.F_GETFL, 0)
    if x == -1:
      false
    else:
      let mode =
        if blocking: x and not(osdefs.O_NONBLOCK) else: x or osdefs.O_NONBLOCK
      if osdefs.fcntl(s, osdefs.F_SETFL, mode) == -1:
        false
      else:
        true

proc setSockOpt*(socket: AsyncFD, level, optname, optval: int): bool =
  ## `setsockopt()` for integer options.
  ## Returns ``true`` on success, ``false`` on error.
  var value = cint(optval)
  osdefs.setsockopt(SocketHandle(socket), cint(level), cint(optname),
                    addr(value), SockLen(sizeof(value))) >= cint(0)

proc setSockOpt*(socket: AsyncFD, level, optname: int, value: pointer,
                 valuelen: int): bool =
  ## `setsockopt()` for custom options (pointer and length).
  ## Returns ``true`` on success, ``false`` on error.
  osdefs.setsockopt(SocketHandle(socket), cint(level), cint(optname), value,
                    SockLen(valuelen)) >= cint(0)

proc getSockOpt*(socket: AsyncFD, level, optname: int, value: var int): bool =
  ## `getsockopt()` for integer options.
  ## Returns ``true`` on success, ``false`` on error.
  var res: cint
  var size = SockLen(sizeof(res))
  if osdefs.getsockopt(SocketHandle(socket), cint(level), cint(optname),
                       addr(res), addr(size)) >= cint(0):
    value = int(res)
    true
  else:
    false

proc getSockOpt*(socket: AsyncFD, level, optname: int, value: pointer,
                 valuelen: var int): bool =
  ## `getsockopt()` for custom options (pointer and length).
  ## Returns ``true`` on success, ``false`` on error.
  osdefs.getsockopt(SocketHandle(socket), cint(level), cint(optname),
                    value, cast[ptr SockLen](addr valuelen)) >= cint(0)

proc getSocketError*(socket: AsyncFD, err: var int): bool =
  ## Recover error code associated with socket handle ``socket``.
  getSockOpt(socket, cint(osdefs.SOL_SOCKET), cint(osdefs.SO_ERROR), err)

proc createAsyncSocket*(domain: Domain, sockType: SockType,
                        protocol: Protocol, inherit = true): AsyncFD {.
     raises: [Defect].} =
  ## Creates new asynchronous socket.
  ## Returns ``asyncInvalidSocket`` on error.
  when defined(windows):
    let flags =
      if inherit:
        osdefs.WSA_FLAG_OVERLAPPED
      else:
        osdefs.WSA_FLAG_OVERLAPPED or osdefs.WSA_FLAG_NO_HANDLE_INHERIT
    let fd = wsaSocket(toInt(domain), toInt(sockType), toInt(protocol),
                       nil, GROUP(0), flags)
    if fd == osdefs.INVALID_SOCKET:
      return asyncInvalidSocket
    if not(setSocketBlocking(fd, false)):
      discard osdefs.closeSocket(fd)
      return asyncInvalidSocket
    try:
      register(AsyncFD(fd))
    except OSError:
      discard osdefs.closeSocket(fd)
      return asyncInvalidSocket
    AsyncFD(fd)
  else:
    when declared(SOCK_NONBLOCK) and declared(SOCK_CLOEXEC):
      let socketType =
        if inherit:
          toInt(sockType) or osdefs.SOCK_NONBLOCK
        else:
          toInt(sockType) or osdefs.SOCK_NONBLOCK or osdefs.SOCK_CLOEXEC
      let fd = osdefs.socket(toInt(domain), socketType, toInt(protocol))
      if fd == -1:
        return asyncInvalidSocket
      try:
        register(AsyncFD(fd))
      except CatchableError:
        discard osdefs.close(fd)
        return asyncInvalidSocket
      AsyncFD(fd)
    else:
      let fd = osdefs.socket(toInt(domain), toInt(sockType), toInt(protocol))
      if fd == -1:
        return asyncInvalidSocket
      if not(inherit):
        if osdefs.fcntl(fd, osdefs.F_SETFD, osdefs.FD_CLOEXEC) == -1:
          discard osdefs.close(fd)
          return asyncInvalidSocket
      if not(setSocketBlocking(fd, false)):
        discard osdefs.close(fd)
        return asyncInvalidSocket
      try:
        register(AsyncFD(fd))
      except CatchableError:
        discard osdefs.close(fd)
        return asyncInvalidSocket
      AsyncFD(fd)

proc wrapAsyncSocket*(sock: SocketHandle): AsyncFD {.
     raises: [Defect].} =
  ## Wraps socket to asynchronous socket handle.
  ## Return ``asyncInvalidSocket`` on error.
  if not(setSocketBlocking(sock, false)):
    when defined(windows):
      discard osdefs.closeSocket(sock)
    else:
      discard osdefs.close(sock)
    return asyncInvalidSocket
  try:
    register(AsyncFD(sock))
  except CatchableError:
    when defined(windows):
      discard osdefs.closeSocket(sock)
    else:
      discard osdefs.close(sock)
    return asyncInvalidSocket
  AsyncFD(sock)

proc getMaxOpenFiles*(): int {.raises: [Defect, OSError].} =
  ## Returns maximum file descriptor number that can be opened by this process.
  ##
  ## Note: On Windows its impossible to obtain such number, so getMaxOpenFiles()
  ## will return constant value of 16384. You can get more information on this
  ## link https://docs.microsoft.com/en-us/archive/blogs/markrussinovich/pushing-the-limits-of-windows-handles
  when defined(windows) or defined(nimdoc):
    16384
  else:
    var limits: RLimit
    if osdefs.getrlimit(osdefs.RLIMIT_NOFILE, limits) != 0:
      raiseOSError(osLastError())
    int(limits.rlim_cur)

proc setMaxOpenFiles*(count: int) {.raises: [Defect, OSError].} =
  ## Set maximum file descriptor number that can be opened by this process.
  ##
  ## Note: On Windows its impossible to set this value, so it just a nop call.
  when defined(windows) or defined(nimdoc):
    discard
  else:
    var limits: RLimit
    if osdefs.getrlimit(osdefs.RLIMIT_NOFILE, limits) != 0:
      raiseOSError(osLastError())
    limits.rlim_cur = count
    if osdefs.setrlimit(osdefs.RLIMIT_NOFILE, limits) != 0:
      raiseOSError(osLastError())

proc createAsyncPipe*(inherit = true): tuple[read: AsyncFD, write: AsyncFD] {.
     raises: [Defect].}=
  ## Create new asynchronouse pipe.
  ## Returns tuple of read pipe handle and write pipe handle``asyncInvalidPipe``
  ## on error.
  when defined(windows):
    var pipeIn, pipeOut: HANDLE
    var pipeName: string
    var uniq = 0'u64
    var sa = getSecurityAttributes(inherit)
    while true:
      QueryPerformanceCounter(uniq)
      pipeName = PipeHeaderName & Base10.toString(uniq)

      var openMode = osdefs.FILE_FLAG_FIRST_PIPE_INSTANCE or
                     osdefs.FILE_FLAG_OVERLAPPED or osdefs.PIPE_ACCESS_INBOUND
      var pipeMode = osdefs.PIPE_TYPE_BYTE or osdefs.PIPE_READMODE_BYTE or
                     osdefs.PIPE_WAIT
      pipeIn = createNamedPipe(newWideCString(pipeName), openMode, pipeMode,
                               1'u32, osdefs.DEFAULT_PIPE_SIZE,
                               osdefs.DEFAULT_PIPE_SIZE, 0'u32, addr sa)
      if pipeIn == osdefs.INVALID_HANDLE_VALUE:
        let err = osLastError()
        # If error in {ERROR_ACCESS_DENIED, ERROR_PIPE_BUSY}, then named pipe
        # with such name already exists.
        if err != osdefs.ERROR_ACCESS_DENIED and err != osdefs.ERROR_PIPE_BUSY:
          return (read: asyncInvalidPipe, write: asyncInvalidPipe)
        continue
      else:
        break

    var openMode = osdefs.GENERIC_WRITE or osdefs.FILE_WRITE_DATA or
                   osdefs.SYNCHRONIZE
    pipeOut = createFile(newWideCString(pipeName), openMode, 0, addr(sa),
                         osdefs.OPEN_EXISTING, osdefs.FILE_FLAG_OVERLAPPED,
                         HANDLE(0))
    if pipeOut == osdefs.INVALID_HANDLE_VALUE:
      discard closeHandle(pipeIn)
      return (read: asyncInvalidPipe, write: asyncInvalidPipe)

    var ovl = osdefs.OVERLAPPED()
    let res = connectNamedPipe(pipeIn, cast[pointer](addr ovl))
    if res == 0:
      let err = osLastError()
      case int(err)
      of osdefs.ERROR_PIPE_CONNECTED:
        discard
      of osdefs.ERROR_IO_PENDING:
        var bytesRead = 0.DWORD
        if getOverlappedResult(pipeIn, addr ovl, bytesRead, 1) == 0:
          discard closeHandle(pipeIn)
          discard closeHandle(pipeOut)
          return (read: asyncInvalidPipe, write: asyncInvalidPipe)
      else:
        discard closeHandle(pipeIn)
        discard closeHandle(pipeOut)
        return (read: asyncInvalidPipe, write: asyncInvalidPipe)

    (read: AsyncFD(pipeIn), write: AsyncFD(pipeOut))
  else:
    when declared(pipe2):
      var fds: array[2, cint]
      let flags =
        if inherit:
          osdefs.O_NONBLOCK
        else:
          osdefs.O_NONBLOCK or osdefs.O_CLOEXEC

      if osdefs.pipe2(fds, cint(flags)) == -1:
        return (read: asyncInvalidPipe, write: asyncInvalidPipe)

      (read: AsyncFD(fds[0]), write: AsyncFD(fds[1]))

    else:
      var fds: array[2, cint]
      if osdefs.pipe(fds) == -1:
        return (read: asyncInvalidPipe, write: asyncInvalidPipe)

      if not(inherit):
        if fcntl(fds[0], osdefs.F_SETFD, osdefs.FD_CLOEXEC) == -1 or
           fcntl(fds[1], osdefs.F_SETFD, osdefs.FD_CLOEXEC) == -1:
          discard osdefs.close(fds[0])
          discard osdefs.close(fds[1])
          return (read: asyncInvalidPipe, write: asyncInvalidPipe)

      if not(setSocketBlocking(SocketHandle(fds[0]), false)) or
         not(setSocketBlocking(SocketHandle(fds[1]), false)):
        discard osdefs.close(fds[0])
        discard osdefs.close(fds[1])
        return (read: asyncInvalidPipe, write: asyncInvalidPipe)

      (read: AsyncFD(fds[0]), write: AsyncFD(fds[1]))

#
#                  Chronos Handles
#              (c) Copyright 2018-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

{.push raises: [Defect].}

import std/[net, nativesockets]
import stew/base10
import ./asyncloop

when defined(windows) or defined(nimdoc):
  import os, winlean
  const
    asyncInvalidSocket* = AsyncFD(-1)
    TCP_NODELAY* = 1
    IPPROTO_TCP* = 6
    PIPE_TYPE_BYTE = 0x00000000'i32
    PIPE_READMODE_BYTE = 0x00000000'i32
    PIPE_WAIT = 0x00000000'i32
    DEFAULT_PIPE_SIZE = 65536'i32
    ERROR_PIPE_CONNECTED = 535
    ERROR_PIPE_BUSY = 231
    pipeHeaderName = r"\\.\pipe\LOCAL\chronos\"

  proc connectNamedPipe(hNamedPipe: Handle, lpOverlapped: pointer): WINBOOL
       {.importc: "ConnectNamedPipe", stdcall, dynlib: "kernel32".}
else:
  import os, posix
  const
    asyncInvalidSocket* = AsyncFD(posix.INVALID_SOCKET)
    TCP_NODELAY* = 1
    IPPROTO_TCP* = 6

const
  asyncInvalidPipe* = asyncInvalidSocket

proc setSocketBlocking*(s: SocketHandle, blocking: bool): bool =
  ## Sets blocking mode on socket.
  when defined(windows) or defined(nimdoc):
    var mode = clong(ord(not blocking))
    if ioctlsocket(s, FIONBIO, addr(mode)) == -1:
      false
    else:
      true
  else:
    let x: int = fcntl(s, F_GETFL, 0)
    if x == -1:
      false
    else:
      let mode = if blocking: x and not O_NONBLOCK else: x or O_NONBLOCK
      if fcntl(s, F_SETFL, mode) == -1:
        false
      else:
        true

proc setSockOpt*(socket: AsyncFD, level, optname, optval: int): bool =
  ## `setsockopt()` for integer options.
  ## Returns ``true`` on success, ``false`` on error.
  var value = cint(optval)
  setsockopt(SocketHandle(socket), cint(level), cint(optname),
             addr(value), SockLen(sizeof(value))) >= cint(0)

proc setSockOpt*(socket: AsyncFD, level, optname: int, value: pointer,
                 valuelen: int): bool =
  ## `setsockopt()` for custom options (pointer and length).
  ## Returns ``true`` on success, ``false`` on error.
  setsockopt(SocketHandle(socket), cint(level), cint(optname), value,
             SockLen(valuelen)) >= cint(0)

proc getSockOpt*(socket: AsyncFD, level, optname: int, value: var int): bool =
  ## `getsockopt()` for integer options.
  ## Returns ``true`` on success, ``false`` on error.
  var res: cint
  var size = SockLen(sizeof(res))
  if getsockopt(SocketHandle(socket), cint(level), cint(optname),
                addr(res), addr(size)) >= cint(0):
    value = int(res)
    true
  else:
    false

proc getSockOpt*(socket: AsyncFD, level, optname: int, value: pointer,
                 valuelen: var int): bool =
  ## `getsockopt()` for custom options (pointer and length).
  ## Returns ``true`` on success, ``false`` on error.
  getsockopt(SocketHandle(socket), cint(level), cint(optname),
             value, cast[ptr SockLen](addr valuelen)) >= cint(0)

proc getSocketError*(socket: AsyncFD, err: var int): bool =
  ## Recover error code associated with socket handle ``socket``.
  getSockOpt(socket, cint(SOL_SOCKET), cint(SO_ERROR), err)

proc createAsyncSocket*(domain: Domain, sockType: SockType,
                        protocol: Protocol): AsyncFD {.
    raises: [Defect, CatchableError].} =
  ## Creates new asynchronous socket.
  ## Returns ``asyncInvalidSocket`` on error.
  let handle = createNativeSocket(domain, sockType, protocol)
  if handle == osInvalidSocket:
    return asyncInvalidSocket
  if not setSocketBlocking(handle, false):
    close(handle)
    return asyncInvalidSocket
  register(AsyncFD(handle))
  AsyncFD(handle)

proc wrapAsyncSocket*(sock: SocketHandle): AsyncFD {.
    raises: [Defect, CatchableError].} =
  ## Wraps socket to asynchronous socket handle.
  ## Return ``asyncInvalidSocket`` on error.
  if not setSocketBlocking(sock, false):
    close(sock)
    return asyncInvalidSocket
  register(AsyncFD(sock))
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
    if getrlimit(posix.RLIMIT_NOFILE, limits) != 0:
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
    if getrlimit(posix.RLIMIT_NOFILE, limits) != 0:
      raiseOSError(osLastError())
    limits.rlim_cur = count
    if setrlimit(posix.RLIMIT_NOFILE, limits) != 0:
      raiseOSError(osLastError())

proc createAsyncPipe*(): tuple[read: AsyncFD, write: AsyncFD] =
  ## Create new asynchronouse pipe.
  ## Returns tuple of read pipe handle and write pipe handle``asyncInvalidPipe``
  ## on error.
  when defined(windows):
    var pipeIn, pipeOut: Handle
    var pipeName: string
    var uniq = 0'u64
    var sa = SECURITY_ATTRIBUTES(nLength: sizeof(SECURITY_ATTRIBUTES).cint,
                                 lpSecurityDescriptor: nil, bInheritHandle: 0)
    while true:
      QueryPerformanceCounter(uniq)
      pipeName = pipeHeaderName & Base10.toString(uniq)

      var openMode = FILE_FLAG_FIRST_PIPE_INSTANCE or FILE_FLAG_OVERLAPPED or
                     PIPE_ACCESS_INBOUND
      var pipeMode = PIPE_TYPE_BYTE or PIPE_READMODE_BYTE or PIPE_WAIT
      pipeIn = createNamedPipe(newWideCString(pipeName), openMode, pipeMode,
                               1'i32, DEFAULT_PIPE_SIZE, DEFAULT_PIPE_SIZE,
                               0'i32, addr sa)
      if pipeIn == INVALID_HANDLE_VALUE:
        let err = osLastError()
        # If error in {ERROR_ACCESS_DENIED, ERROR_PIPE_BUSY}, then named pipe
        # with such name already exists.
        if int32(err) != ERROR_ACCESS_DENIED and int32(err) != ERROR_PIPE_BUSY:
          return (read: asyncInvalidPipe, write: asyncInvalidPipe)
        continue
      else:
        break

    var openMode = (GENERIC_WRITE or FILE_WRITE_DATA or SYNCHRONIZE)
    pipeOut = createFileW(newWideCString(pipeName), openMode, 0, addr(sa),
                          OPEN_EXISTING, FILE_FLAG_OVERLAPPED, 0)
    if pipeOut == INVALID_HANDLE_VALUE:
      discard closeHandle(pipeIn)
      return (read: asyncInvalidPipe, write: asyncInvalidPipe)

    var ovl = OVERLAPPED()
    let res = connectNamedPipe(pipeIn, cast[pointer](addr ovl))
    if res == 0:
      let err = osLastError()
      case int32(err)
      of ERROR_PIPE_CONNECTED:
        discard
      of ERROR_IO_PENDING:
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
  elif defined(nimdoc): discard
  else:
    var fds: array[2, cint]

    if posix.pipe(fds) == -1:
      return (read: asyncInvalidPipe, write: asyncInvalidPipe)

    if not(setSocketBlocking(SocketHandle(fds[0]), false)) or
       not(setSocketBlocking(SocketHandle(fds[1]), false)):
      return (read: asyncInvalidPipe, write: asyncInvalidPipe)

    (read: AsyncFD(fds[0]), write: AsyncFD(fds[1]))

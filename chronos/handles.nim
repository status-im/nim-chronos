#
#                  Chronos Handles
#              (c) Copyright 2018-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

import net, nativesockets, os, asyncloop, osapi

when defined(windows):
  import winlean
  const
    asyncInvalidSocket* = AsyncFD(-1)
    pipeHeaderName = r"\\.\pipe\chronos\"
else:
  import posix
  const asyncInvalidSocket* = AsyncFD(posix.INVALID_SOCKET)

const
  asyncInvalidPipe* = asyncInvalidSocket

proc setSocketBlocking*(s: SocketHandle, blocking: bool): bool =
  ## Sets blocking mode on socket.
  when defined(windows):
    result = true
    var mode = clong(ord(not blocking))
    if ioctlsocket(s, FIONBIO, addr(mode)) == -1:
      result = false
  else:
    result = true
    var x: int = fcntl(s, F_GETFL, 0)
    if x == -1:
      result = false
    else:
      var mode = if blocking: x and not O_NONBLOCK else: x or O_NONBLOCK
      if fcntl(s, F_SETFL, mode) == -1:
        result = false

proc setSockOpt*(socket: AsyncFD, level, optname, optval: int): bool =
  ## `setsockopt()` for integer options.
  ## Returns ``true`` on success, ``false`` on error.
  var value = cint(optval)
  result = setsockopt(SocketHandle(socket), cint(level), cint(optname),
                      addr(value), SockLen(sizeof(value))) >= cint(0)

proc setSockOpt*(socket: AsyncFD, level, optname: int, value: pointer,
                 valuelen: int): bool =
  ## `setsockopt()` for custom options (pointer and length).
  ## Returns ``true`` on success, ``false`` on error.
  result = setsockopt(SocketHandle(socket), cint(level), cint(optname), value,
                      SockLen(valuelen)) >= cint(0)

proc getSockOpt*(socket: AsyncFD, level, optname: int, value: var int): bool =
  ## `getsockopt()` for integer options.
  ## Returns ``true`` on success, ``false`` on error.
  var res: cint
  var size = SockLen(sizeof(res))
  if getsockopt(SocketHandle(socket), cint(level), cint(optname),
                addr(res), addr(size)) >= cint(0):
    value = int(res)
    result = true

proc getSockOpt*(socket: AsyncFD, level, optname: int, value: pointer,
                 valuelen: var int): bool =
  ## `getsockopt()` for custom options (pointer and length).
  ## Returns ``true`` on success, ``false`` on error.
  result = getsockopt(SocketHandle(socket), cint(level), cint(optname),
                      value, cast[ptr Socklen](addr valuelen)) >= cint(0)

proc getSocketError*(socket: AsyncFD, err: var int): bool =
  ## Recover error code associated with socket handle ``socket``.
  result = getSockOpt(socket, cint(SOL_SOCKET), cint(SO_ERROR), err)

proc createAsyncSocket*(domain: Domain, sockType: SockType,
                        protocol: Protocol): AsyncFD =
  ## Creates new asynchronous socket.
  ## Returns ``asyncInvalidSocket`` on error.
  let handle = createNativeSocket(domain, sockType, protocol)
  if handle == osInvalidSocket:
    return asyncInvalidSocket
  if not setSocketBlocking(handle, false):
    close(handle)
    return asyncInvalidSocket
  when defined(macosx) and not defined(nimdoc):
    if not setSockOpt(AsyncFD(handle), SOL_SOCKET, SO_NOSIGPIPE, 1):
      close(handle)
      return asyncInvalidSocket
  result = AsyncFD(handle)
  register(result)

proc wrapAsyncSocket*(sock: SocketHandle): AsyncFD =
  ## Wraps socket to asynchronous socket handle.
  ## Return ``asyncInvalidSocket`` on error.
  if not setSocketBlocking(sock, false):
    close(sock)
    return asyncInvalidSocket
  when defined(macosx) and not defined(nimdoc):
    if not setSockOpt(AsyncFD(sock), SOL_SOCKET, SO_NOSIGPIPE, 1):
      close(sock)
      return asyncInvalidSocket
  result = AsyncFD(sock)
  register(result)

proc createAsyncPipe*(): tuple[read: AsyncFD, write: AsyncFD] =
  ## Create new asynchronouse pipe.
  ## Returns tuple of read pipe handle and write pipe handle``asyncInvalidPipe`` on error.
  when defined(windows):
    var pipeIn, pipeOut: Handle
    var pipeName: WideCString
    var uniq = 0'u64
    var sa = SECURITY_ATTRIBUTES(nLength: sizeof(SECURITY_ATTRIBUTES).cint,
                                 lpSecurityDescriptor: nil, bInheritHandle: 0)
    while true:
      QueryPerformanceCounter(uniq)
      pipeName = newWideCString(pipeHeaderName & $uniq)
      var openMode = FILE_FLAG_FIRST_PIPE_INSTANCE or FILE_FLAG_OVERLAPPED or
                     PIPE_ACCESS_INBOUND
      var pipeMode = PIPE_TYPE_BYTE or PIPE_READMODE_BYTE or PIPE_WAIT
      pipeIn = createNamedPipe(pipeName, openMode, pipeMode, 1'i32,
                               DEFAULT_PIPE_SIZE, DEFAULT_PIPE_SIZE,
                               0'i32, addr sa)
      if pipeIn == INVALID_HANDLE_VALUE:
        let err = osLastError()
        # If error in {ERROR_ACCESS_DENIED, ERROR_PIPE_BUSY}, then named pipe
        # with such name already exists.
        if int32(err) != ERROR_ACCESS_DENIED and int32(err) != ERROR_PIPE_BUSY:
          result = (read: asyncInvalidPipe, write: asyncInvalidPipe)
          return
        continue
      else:
        break

    var openMode = (GENERIC_WRITE or FILE_WRITE_DATA or SYNCHRONIZE)
    pipeOut = createFileW(pipeName, openMode, 0, addr(sa), OPEN_EXISTING,
                          FILE_FLAG_OVERLAPPED, 0)
    if pipeOut == INVALID_HANDLE_VALUE:
      discard closeHandle(pipeIn)
      result = (read: asyncInvalidPipe, write: asyncInvalidPipe)
      return

    var ovl = OVERLAPPED()
    let res = connectNamedPipe(pipeIn, cast[pointer](addr ovl))
    if res == 0:
      let err = osLastError()
      if int32(err) == ERROR_PIPE_CONNECTED:
        discard
      elif int32(err) == ERROR_IO_PENDING:
        var bytesRead = 0.Dword
        if getOverlappedResult(pipeIn, addr ovl, bytesRead, 1) == 0:
          discard closeHandle(pipeIn)
          discard closeHandle(pipeOut)
          result = (read: asyncInvalidPipe, write: asyncInvalidPipe)
          return
      else:
        discard closeHandle(pipeIn)
        discard closeHandle(pipeOut)
        result = (read: asyncInvalidPipe, write: asyncInvalidPipe)
        return

    result = (read: AsyncFD(pipeIn), write: AsyncFD(pipeOut))
  else:
    var fds: array[2, cint]

    if posix.pipe(fds) == -1:
      result = (read: asyncInvalidPipe, write: asyncInvalidPipe)
      return

    if not(setSocketBlocking(SocketHandle(fds[0]), false)) or
       not(setSocketBlocking(SocketHandle(fds[1]), false)):
      result = (read: asyncInvalidPipe, write: asyncInvalidPipe)
      return

    result = (read: AsyncFD(fds[0]), write: AsyncFD(fds[1]))

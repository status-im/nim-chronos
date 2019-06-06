#
#                  Chronos Handles
#              (c) Copyright 2018-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

import net, nativesockets, asyncloop

when defined(windows):
  import winlean
  const
    asyncInvalidSocket* = AsyncFD(-1)
    TCP_NODELAY* = 1
    IPPROTO_TCP* = 6
else:
  import posix
  const
    asyncInvalidSocket* = AsyncFD(posix.INVALID_SOCKET)
    TCP_NODELAY* = 1
    IPPROTO_TCP* = 6

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

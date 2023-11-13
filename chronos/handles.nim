#
#                  Chronos Handles
#              (c) Copyright 2018-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

{.push raises: [].}

import "."/[asyncloop, osdefs, osutils]
import results
from nativesockets import Domain, Protocol, SockType, toInt
export Domain, Protocol, SockType, results

when defined(windows):
  export raiseSignal, raiseConsoleCtrlSignal

const
  asyncInvalidSocket* = AsyncFD(osdefs.INVALID_SOCKET)
  asyncInvalidPipe* = asyncInvalidSocket

proc setSocketBlocking*(s: SocketHandle, blocking: bool): bool {.
     deprecated: "Please use setDescriptorBlocking() instead".} =
  ## Sets blocking mode on socket.
  setDescriptorBlocking(s, blocking).isOkOr:
    return false
  true

proc setSockOpt2*(socket: AsyncFD,
                  level, optname, optval: int): Result[void, OSErrorCode] =
  var value = cint(optval)
  let res = osdefs.setsockopt(SocketHandle(socket), cint(level), cint(optname),
                              addr(value), SockLen(sizeof(value)))
  if res == -1:
    return err(osLastError())
  ok()

proc setSockOpt2*(socket: AsyncFD, level, optname: int, value: pointer,
                  valuelen: int): Result[void, OSErrorCode] =
  ## `setsockopt()` for custom options (pointer and length).
  ## Returns ``true`` on success, ``false`` on error.
  let res = osdefs.setsockopt(SocketHandle(socket), cint(level), cint(optname),
                              value, SockLen(valuelen))
  if res == -1:
    return err(osLastError())
  ok()

proc setSockOpt*(socket: AsyncFD, level, optname, optval: int): bool {.
     deprecated: "Please use setSockOpt2() instead".} =
  ## `setsockopt()` for integer options.
  ## Returns ``true`` on success, ``false`` on error.
  setSockOpt2(socket, level, optname, optval).isOk

proc setSockOpt*(socket: AsyncFD, level, optname: int, value: pointer,
                 valuelen: int): bool {.
     deprecated: "Please use setSockOpt2() instead".} =
  ## `setsockopt()` for custom options (pointer and length).
  ## Returns ``true`` on success, ``false`` on error.
  setSockOpt2(socket, level, optname, value, valuelen).isOk

proc getSockOpt2*(socket: AsyncFD,
                  level, optname: int): Result[cint, OSErrorCode] =
  var
    value: cint
    size = SockLen(sizeof(value))
  let res = osdefs.getsockopt(SocketHandle(socket), cint(level), cint(optname),
                              addr(value), addr(size))
  if res == -1:
    return err(osLastError())
  ok(value)

proc getSockOpt2*(socket: AsyncFD, level, optname: int,
                  T: type): Result[T, OSErrorCode] =
  var
    value = default(T)
    size = SockLen(sizeof(value))
  let res = osdefs.getsockopt(SocketHandle(socket), cint(level), cint(optname),
                              cast[ptr byte](addr(value)), addr(size))
  if res == -1:
    return err(osLastError())
  ok(value)

proc getSockOpt*(socket: AsyncFD, level, optname: int, value: var int): bool {.
     deprecated: "Please use getSockOpt2() instead".} =
  ## `getsockopt()` for integer options.
  ## Returns ``true`` on success, ``false`` on error.
  value = getSockOpt2(socket, level, optname).valueOr:
    return false
  true

proc getSockOpt*(socket: AsyncFD, level, optname: int, value: var pointer,
                 valuelen: var int): bool  {.
     deprecated: "Please use getSockOpt2() instead".} =
  ## `getsockopt()` for custom options (pointer and length).
  ## Returns ``true`` on success, ``false`` on error.
  osdefs.getsockopt(SocketHandle(socket), cint(level), cint(optname),
                    value, cast[ptr SockLen](addr valuelen)) >= cint(0)

proc getSocketError*(socket: AsyncFD, err: var int): bool  {.
     deprecated: "Please use getSocketError() instead".} =
  ## Recover error code associated with socket handle ``socket``.
  err = getSockOpt2(socket, cint(osdefs.SOL_SOCKET),
                    cint(osdefs.SO_ERROR)).valueOr:
    return false
  true

proc getSocketError2*(socket: AsyncFD): Result[cint, OSErrorCode] =
  getSockOpt2(socket, cint(osdefs.SOL_SOCKET), cint(osdefs.SO_ERROR))

proc isAvailable*(domain: Domain): bool =
  when defined(windows):
    let fd = wsaSocket(toInt(domain), toInt(SockType.SOCK_STREAM),
                       toInt(Protocol.IPPROTO_TCP), nil, GROUP(0), 0'u32)
    if fd == osdefs.INVALID_SOCKET:
      return if osLastError() == osdefs.WSAEAFNOSUPPORT: false else: true
    discard closeFd(fd)
    true
  else:
    let fd = osdefs.socket(toInt(domain), toInt(SockType.SOCK_STREAM),
                           toInt(Protocol.IPPROTO_TCP))
    if fd == -1:
      return if osLastError() == osdefs.EAFNOSUPPORT: false else: true
    discard closeFd(fd)
    true

proc createAsyncSocket2*(domain: Domain, sockType: SockType,
                         protocol: Protocol,
                         inherit = true): Result[AsyncFD, OSErrorCode] =
  ## Creates new asynchronous socket.
  when defined(windows):
    let flags =
      if inherit:
        osdefs.WSA_FLAG_OVERLAPPED
      else:
        osdefs.WSA_FLAG_OVERLAPPED or osdefs.WSA_FLAG_NO_HANDLE_INHERIT
    let fd = wsaSocket(toInt(domain), toInt(sockType), toInt(protocol),
                       nil, GROUP(0), flags)
    if fd == osdefs.INVALID_SOCKET:
      return err(osLastError())

    setDescriptorBlocking(fd, false).isOkOr:
      discard closeFd(fd)
      return err(error)
    register2(AsyncFD(fd)).isOkOr:
      discard closeFd(fd)
      return err(error)

    ok(AsyncFD(fd))
  else:
    when declared(SOCK_NONBLOCK) and declared(SOCK_CLOEXEC):
      let socketType =
        if inherit:
          toInt(sockType) or osdefs.SOCK_NONBLOCK
        else:
          toInt(sockType) or osdefs.SOCK_NONBLOCK or osdefs.SOCK_CLOEXEC
      let fd = osdefs.socket(toInt(domain), socketType, toInt(protocol))
      if fd == -1:
        return err(osLastError())
      register2(AsyncFD(fd)).isOkOr:
        discard closeFd(fd)
        return err(error)
      ok(AsyncFD(fd))
    else:
      let fd = osdefs.socket(toInt(domain), toInt(sockType), toInt(protocol))
      if fd == -1:
        return err(osLastError())
      setDescriptorFlags(cint(fd), true, true).isOkOr:
        discard closeFd(fd)
        return err(error)
      register2(AsyncFD(fd)).isOkOr:
        discard closeFd(fd)
        return err(error)
      ok(AsyncFD(fd))

proc wrapAsyncSocket2*(sock: cint|SocketHandle): Result[AsyncFD, OSErrorCode] =
  ## Wraps socket to asynchronous socket handle.
  let fd =
    when defined(windows):
      sock
    else:
      when sock is cint: sock else: cint(sock)
  ? setDescriptorFlags(fd, true, true)
  ? register2(AsyncFD(fd))
  ok(AsyncFD(fd))

proc createAsyncSocket*(domain: Domain, sockType: SockType,
                        protocol: Protocol,
                        inherit = true): AsyncFD =
  ## Creates new asynchronous socket.
  ## Returns ``asyncInvalidSocket`` on error.
  createAsyncSocket2(domain, sockType, protocol, inherit).valueOr:
    return asyncInvalidSocket

proc wrapAsyncSocket*(sock: cint|SocketHandle): AsyncFD {.
    raises: [CatchableError].} =
  ## Wraps socket to asynchronous socket handle.
  ## Return ``asyncInvalidSocket`` on error.
  wrapAsyncSocket2(sock).valueOr:
    return asyncInvalidSocket

proc getMaxOpenFiles2*(): Result[int, OSErrorCode] =
  ## Returns maximum file descriptor number that can be opened by this process.
  ##
  ## Note: On Windows its impossible to obtain such number, so getMaxOpenFiles()
  ## will return constant value of 16384. You can get more information on this
  ## link https://docs.microsoft.com/en-us/archive/blogs/markrussinovich/pushing-the-limits-of-windows-handles
  when defined(windows) or defined(nimdoc):
    ok(16384)
  else:
    var limits: RLimit
    if osdefs.getrlimit(osdefs.RLIMIT_NOFILE, limits) != 0:
      return err(osLastError())
    ok(int(limits.rlim_cur))

proc setMaxOpenFiles2*(count: int): Result[void, OSErrorCode] =
  ## Set maximum file descriptor number that can be opened by this process.
  ##
  ## Note: On Windows its impossible to set this value, so it just a nop call.
  when defined(windows) or defined(nimdoc):
    ok()
  else:
    var limits: RLimit
    if getrlimit(osdefs.RLIMIT_NOFILE, limits) != 0:
      return err(osLastError())
    limits.rlim_cur = count
    if setrlimit(osdefs.RLIMIT_NOFILE, limits) != 0:
      return err(osLastError())
    ok()

proc getMaxOpenFiles*(): int {.raises: [OSError].} =
  ## Returns maximum file descriptor number that can be opened by this process.
  ##
  ## Note: On Windows its impossible to obtain such number, so getMaxOpenFiles()
  ## will return constant value of 16384. You can get more information on this
  ## link https://docs.microsoft.com/en-us/archive/blogs/markrussinovich/pushing-the-limits-of-windows-handles
  let res = getMaxOpenFiles2()
  if res.isErr():
    raiseOSError(res.error())
  res.get()

proc setMaxOpenFiles*(count: int) {.raises: [OSError].} =
  ## Set maximum file descriptor number that can be opened by this process.
  ##
  ## Note: On Windows its impossible to set this value, so it just a nop call.
  let res = setMaxOpenFiles2(count)
  if res.isErr():
    raiseOSError(res.error())

proc getInheritable*(fd: AsyncFD): Result[bool, OSErrorCode] =
  ## Returns ``true`` if ``fd`` is inheritable handle.
  when defined(windows):
    var flags = 0'u32
    if getHandleInformation(HANDLE(fd), flags) == FALSE:
      return err(osLastError())
    ok((flags and HANDLE_FLAG_INHERIT) == HANDLE_FLAG_INHERIT)
  else:
    let flags = osdefs.fcntl(cint(fd), osdefs.F_GETFD)
    if flags == -1:
      return err(osLastError())
    ok((flags and osdefs.FD_CLOEXEC) == osdefs.FD_CLOEXEC)

proc createAsyncPipe*(): tuple[read: AsyncFD, write: AsyncFD] =
  ## Create new asynchronouse pipe.
  ## Returns tuple of read pipe handle and write pipe handle``asyncInvalidPipe``
  ## on error.
  let res = createOsPipe(AsyncDescriptorDefault, AsyncDescriptorDefault)
  if res.isErr():
    (read: asyncInvalidPipe, write: asyncInvalidPipe)
  else:
    let pipes = res.get()
    (read: AsyncFD(pipes.read), write: AsyncFD(pipes.write))

proc getDualstack*(fd: AsyncFD): Result[bool, OSErrorCode] =
  ## Returns `true` if `IPV6_V6ONLY` socket option set to `false`.
  var
    flag = cint(0)
    size = SockLen(sizeof(flag))
  let res = osdefs.getsockopt(SocketHandle(fd), cint(osdefs.IPPROTO_IPV6),
                              cint(osdefs.IPV6_V6ONLY), addr(flag), addr(size))
  if res == -1:
    return err(osLastError())
  ok(flag == cint(0))

proc setDualstack*(fd: AsyncFD, value: bool): Result[void, OSErrorCode] =
  ## Sets `IPV6_V6ONLY` socket option value to `false` if `value == true` and
  ## to `true` if `value == false`.
  var
    flag = cint(if value: 0 else: 1)
    size = SockLen(sizeof(flag))
  let res = osdefs.setsockopt(SocketHandle(fd), cint(osdefs.IPPROTO_IPV6),
                              cint(osdefs.IPV6_V6ONLY), addr(flag), size)
  if res == -1:
    return err(osLastError())
  ok()

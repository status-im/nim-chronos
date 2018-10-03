#
#        Asyncdispatch2 Transport Common Types
#                 (c) Copyright 2018
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

import os, net, strutils
from nativesockets import toInt
import ../asyncloop
export net

when defined(windows):
  import winlean
else:
  import posix

const
  DefaultStreamBufferSize* = 4096    ## Default buffer size for stream
                                     ## transports
  DefaultDatagramBufferSize* = 65536 ## Default buffer size for datagram
                                     ## transports
type
  ServerFlags* = enum
    ## Server's flags
    ReuseAddr, ReusePort, TcpNoDelay, NoAutoRead, GCUserData

  TransportAddress* = object
    ## Transport network address
    address*: IpAddress           # IP Address
    port*: Port                   # IP port

  ServerCommand* = enum
    ## Server's commands
    Start,                        # Start server
    Pause,                        # Pause server
    Stop                          # Stop server

  ServerStatus* = enum
    ## Server's statuses
    Starting,                     # Server created
    Stopped,                      # Server stopped
    Running,                      # Server running
    Closed                        # Server closed

  FutureGCString*[T] = ref object of Future[T]
    ## Future to hold GC strings
    gcholder*: string

  FutureGCSeq*[A, B] = ref object of Future[A]
    ## Future to hold GC seqs
    gcholder*: seq[B]

when defined(windows):
  type
    SocketServer* = ref object of RootRef
      ## Socket server object
      sock*: AsyncFD                # Socket
      local*: TransportAddress      # Address
      status*: ServerStatus         # Current server status
      udata*: pointer               # User-defined pointer
      flags*: set[ServerFlags]      # Flags
      bufferSize*: int              # Size of internal transports' buffer
      loopFuture*: Future[void]     # Server's main Future
      domain*: Domain               # Current server domain (IPv4 or IPv6)
      apending*: bool
      asock*: AsyncFD               # Current AcceptEx() socket
      abuffer*: array[128, byte]    # Windows AcceptEx() buffer
      aovl*: CustomOverlapped       # AcceptEx OVERLAPPED structure
else:
  type
    SocketServer* = ref object of RootRef
      ## Socket server object
      sock*: AsyncFD                # Socket
      local*: TransportAddress      # Address
      status*: ServerStatus         # Current server status
      udata*: pointer               # User-defined pointer
      flags*: set[ServerFlags]      # Flags
      bufferSize*: int              # Size of internal transports' buffer
      loopFuture*: Future[void]     # Server's main Future

type
  TransportError* = object of AsyncError
    ## Transport's specific exception
  TransportOsError* = object of TransportError
    ## Transport's OS specific exception
    code*: OSErrorCode
  TransportIncompleteError* = object of TransportError
    ## Transport's `incomplete data received` exception
  TransportLimitError* = object of TransportError
    ## Transport's `data limit reached` exception
  TransportAddressError* = object of TransportError
    ## Transport's address specific exception
    code*: OSErrorCode

  TransportState* = enum
    ## Transport's state
    ReadPending,                  # Read operation pending (Windows)
    ReadPaused,                   # Read operations paused
    ReadClosed,                   # Read operations closed
    ReadEof,                      # Read at EOF
    ReadError,                    # Read error
    WritePending,                 # Writer operation pending (Windows)
    WritePaused,                  # Writer operations paused
    WriteClosed,                  # Writer operations closed
    WriteError                    # Write error

var
  AnyAddress* = TransportAddress(
    address: IpAddress(family: IpAddressFamily.IPv4), port: Port(0)
  ) ## Default INADDR_ANY address for IPv4
  AnyAddress6* = TransportAddress(
    address: IpAddress(family: IpAddressFamily.IPv6), port: Port(0)
  ) ## Default INADDR_ANY address for IPv6

proc getDomain*(address: IpAddress): Domain =
  ## Returns OS specific Domain from IP Address.
  case address.family
  of IpAddressFamily.IPv4:
    result = Domain.AF_INET
  of IpAddressFamily.IPv6:
    result = Domain.AF_INET6

proc getDomain*(address: TransportAddress): Domain =
  ## Returns OS specific Domain from TransportAddress.
  result = address.address.getDomain()

proc `$`*(address: TransportAddress): string =
  ## Returns string representation of ``address``.
  case address.address.family
  of IpAddressFamily.IPv4:
    result = $address.address
    result.add(":")
  of IpAddressFamily.IPv6:
    result = "[" & $address.address & "]"
    result.add(":")
  result.add($int(address.port))

proc initTAddress*(address: string): TransportAddress =
  ## Parses string representation of ``address``.
  ##
  ## IPv4 transport address format is ``a.b.c.d:port``.
  ## IPv6 transport address format is ``[::]:port``.
  var parts = address.rsplit(":", maxsplit = 1)
  if len(parts) != 2:
    raise newException(TransportAddressError, "Format is <address>:<port>!")

  try:
    let port = parseInt(parts[1])
    doAssert(port > 0 and port < 65536)
    result.port = Port(port)
  except:
    raise newException(TransportAddressError, "Illegal port number!")

  try:
    if parts[0][0] == '[' and parts[0][^1] == ']':
      result.address = parseIpAddress(parts[0][1..^2])
    else:
      result.address = parseIpAddress(parts[0])
  except:
    raise newException(TransportAddressError, getCurrentException().msg)

proc initTAddress*(address: string, port: Port): TransportAddress =
  ## Initialize ``TransportAddress`` with IP address ``address`` and
  ## port number ``port``.
  try:
    result.address = parseIpAddress(address)
    result.port = port
  except:
    raise newException(TransportAddressError, getCurrentException().msg)

proc initTAddress*(address: string, port: int): TransportAddress =
  ## Initialize ``TransportAddress`` with IP address ``address`` and
  ## port number ``port``.
  if port < 0 or port >= 65536:
    raise newException(TransportAddressError, "Illegal port number!")
  try:
    result.address = parseIpAddress(address)
    result.port = Port(port)
  except:
    raise newException(TransportAddressError, getCurrentException().msg)

proc initTAddress*(address: IpAddress, port: Port): TransportAddress =
  ## Initialize ``TransportAddress`` with net.nim ``IpAddress`` and
  ## port number ``port``.
  result.address = address
  result.port = port

proc getAddrInfo(address: string, port: Port, domain: Domain,
                 sockType: SockType = SockType.SOCK_STREAM,
                 protocol: Protocol = Protocol.IPPROTO_TCP): ptr AddrInfo =
  ## We have this one copy of ``getAddrInfo()`` because of AI_V4MAPPED in
  ## ``net.nim:getAddrInfo()``, which is not cross-platform.
  var hints: AddrInfo
  result = nil
  hints.ai_family = toInt(domain)
  hints.ai_socktype = toInt(sockType)
  hints.ai_protocol = toInt(protocol)
  var gaiResult = getaddrinfo(address, $port, addr(hints), result)
  if gaiResult != 0'i32:
    when defined(windows):
      raise newException(TransportAddressError, osErrorMsg(osLastError()))
    else:
      raise newException(TransportAddressError, $gai_strerror(gaiResult))

proc resolveTAddress*(address: string,
                      family = IpAddressFamily.IPv4): seq[TransportAddress] =
  ## Resolve string representation of ``address``.
  ##
  ## Supported formats are:
  ## IPv4 numeric address ``a.b.c.d:port``
  ## IPv6 numeric address ``[::]:port``
  ## Hostname address ``hostname:port``
  ##
  ## If hostname address is detected, then network address translation via DNS
  ## will be performed.
  var
    hostname: string
    port: int

  result = newSeq[TransportAddress]()
  var parts = address.rsplit(":", maxsplit = 1)
  if len(parts) != 2:
    raise newException(TransportAddressError, "Format is <address>:<port>!")

  try:
    port = parseInt(parts[1])
    doAssert(port > 0 and port < 65536)
  except:
    raise newException(TransportAddressError, "Illegal port number!")

  if parts[0][0] == '[' and parts[0][^1] == ']':
    # IPv6 numeric addresses must be enclosed with `[]`.
    hostname = parts[0][1..^2]
  else:
    hostname = parts[0]

  var domain = if family == IpAddressFamily.IPv4: Domain.AF_INET else:
                 Domain.AF_INET6
  var aiList = getAddrInfo(hostname, Port(port), domain)
  var it = aiList
  while it != nil:
    var ta: TransportAddress
    fromSockAddr(cast[ptr Sockaddr_storage](it.ai_addr)[],
                 SockLen(it.ai_addrlen), ta.address, ta.port)
    # For some reason getAddrInfo() sometimes returns duplicate addresses,
    # for example getAddrInfo(`localhost`) returns `127.0.0.1` twice.
    if ta notin result:
      result.add(ta)
    it = it.ai_next
  freeAddrInfo(aiList)

proc resolveTAddress*(address: string, port: Port,
                      family = IpAddressFamily.IPv4): seq[TransportAddress] =
  ## Resolve string representation of ``address``.
  ##
  ## ``address`` could be dot IPv4/IPv6 address or hostname.
  ##
  ## If hostname address is detected, then network address translation via DNS
  ## will be performed.
  result = newSeq[TransportAddress]()
  var domain = if family == IpAddressFamily.IPv4: Domain.AF_INET else:
                 Domain.AF_INET6
  var aiList = getAddrInfo(address, port, domain)
  var it = aiList
  while it != nil:
    var ta: TransportAddress
    fromSockAddr(cast[ptr Sockaddr_storage](it.ai_addr)[],
                 SockLen(it.ai_addrlen), ta.address, ta.port)
    # For some reason getAddrInfo() sometimes returns duplicate addresses,
    # for example getAddrInfo(`localhost`) returns `127.0.0.1` twice.
    if ta notin result:
      result.add(ta)
    it = it.ai_next
  freeAddrInfo(aiList)

template checkClosed*(t: untyped) =
  if (ReadClosed in (t).state) or (WriteClosed in (t).state):
    raise newException(TransportError, "Transport is already closed!")

template checkClosed*(t: untyped, future: untyped) =
  if (ReadClosed in (t).state) or (WriteClosed in (t).state):
    future.fail(newException(TransportError, "Transport is already closed!"))
    return future

template getError*(t: untyped): ref Exception =
  var err = (t).error
  (t).error = nil
  err

proc raiseTransportOsError*(err: OSErrorCode) =
  ## Raises transport specific OS error.
  var msg = "(" & $int(err) & ") " & osErrorMsg(err)
  var tre = newException(TransportOsError, msg)
  tre.code = err
  raise tre

template getTransportOsError*(err: OSErrorCode): ref TransportOsError =
  var msg = "(" & $int(err) & ") " & osErrorMsg(err)
  var tre = newException(TransportOsError, msg)
  tre.code = err
  tre

template getTransportOsError*(err: cint): ref TransportOsError =
  getTransportOsError(OSErrorCode(err))

type
  SeqHeader = object
    length, reserved: int

proc isLiteral*(s: string): bool {.inline.} =
  (cast[ptr SeqHeader](s).reserved and (1 shl (sizeof(int) * 8 - 2))) != 0

proc isLiteral*[T](s: seq[T]): bool {.inline.} =
  (cast[ptr SeqHeader](s).reserved and (1 shl (sizeof(int) * 8 - 2))) != 0

when defined(windows):
  import winlean

  const
    ERROR_OPERATION_ABORTED* = 995
    ERROR_SUCCESS* = 0
    ERROR_CONNECTION_REFUSED* = 1225

  proc cancelIo*(hFile: HANDLE): WINBOOL
       {.stdcall, dynlib: "kernel32", importc: "CancelIo".}

#
#             Chronos Datagram Transport
#             (c) Copyright 2018-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

{.push raises: [].}

import std/deques
import results
when not (defined(windows)):
  import ".."/selectors2
import ".."/[asyncloop, osdefs, oserrno, osutils, handles]
import "."/[common, ipnet]
import stew/ptrops

export results

type
  VectorKind = enum
    WithoutAddress
    WithAddress

  GramVector = object
    kind: VectorKind # Vector kind (with address/without address)
    address: TransportAddress # Destination address
    buf: pointer # Writer buffer pointer
    buflen: int # Writer buffer size
    writer: Future[void] # Writer vector completion Future

  DatagramCallback* = proc(
    transp: DatagramTransport, remote: TransportAddress
  ): Future[void] {.async: (raises: []).}

  UnsafeDatagramCallback* =
    proc(transp: DatagramTransport, remote: TransportAddress): Future[void] {.async.}

  DatagramTransport* = ref object of RootRef
    fd*: AsyncFD # File descriptor
    state: set[TransportState] # Current Transport state
    flags: set[ServerFlags] # Flags
    buffer: seq[byte] # Reading buffer
    buflen: int # Reading buffer effective size
    error: ref TransportError # Current error
    queue: Deque[GramVector] # Writer queue
    local: TransportAddress # Local address
    remote: TransportAddress # Remote address
    udata*: pointer # User-driven pointer
    function: DatagramCallback # Receive data callback
    future: Future[void].Raising([]) # Transport's life future
    raddr: Sockaddr_storage # Reader address storage
    ralen: SockLen # Reader address length
    waddr: Sockaddr_storage # Writer address storage
    walen: SockLen # Writer address length
    when defined(windows):
      rovl: CustomOverlapped # Reader OVERLAPPED structure
      wovl: CustomOverlapped # Writer OVERLAPPED structure
      rflag: uint32 # Reader flags storage
      rwsabuf: WSABUF # Reader WSABUF structure
      wwsabuf: WSABUF # Writer WSABUF structure

const DgramTransportTrackerName* = "datagram.transport"

proc getRemoteAddress(
    transp: DatagramTransport, address: Sockaddr_storage, length: SockLen
): TransportAddress =
  var raddr: TransportAddress
  fromSAddr(unsafeAddr address, length, raddr)
  if ServerFlags.V4Mapped in transp.flags:
    if raddr.isV4Mapped():
      raddr.toIPv4()
    else:
      raddr
  else:
    raddr

proc getRemoteAddress(transp: DatagramTransport): TransportAddress =
  transp.getRemoteAddress(transp.raddr, transp.ralen)

proc setRemoteAddress(
    transp: DatagramTransport, address: TransportAddress
): TransportAddress =
  let
    fixedAddress =
      when defined(windows):
        windowsAnyAddressFix(address)
      else:
        address
    remoteAddress =
      if ServerFlags.V4Mapped in transp.flags:
        if address.family == AddressFamily.IPv4:
          fixedAddress.toIPv6()
        else:
          fixedAddress
      else:
        fixedAddress
  toSAddr(remoteAddress, transp.waddr, transp.walen)
  remoteAddress

proc remoteAddress2*(transp: DatagramTransport): Result[TransportAddress, OSErrorCode] =
  ## Returns ``transp`` remote socket address.
  if transp.remote.family == AddressFamily.None:
    var
      saddr: Sockaddr_storage
      slen = SockLen(sizeof(saddr))
    if getpeername(SocketHandle(transp.fd), cast[ptr SockAddr](addr saddr), addr slen) !=
        0:
      return err(osLastError())
    transp.remote = transp.getRemoteAddress(saddr, slen)
  ok(transp.remote)

proc localAddress2*(transp: DatagramTransport): Result[TransportAddress, OSErrorCode] =
  ## Returns ``transp`` local socket address.
  if transp.local.family == AddressFamily.None:
    var
      saddr: Sockaddr_storage
      slen = SockLen(sizeof(saddr))
    if getsockname(SocketHandle(transp.fd), cast[ptr SockAddr](addr saddr), addr slen) !=
        0:
      return err(osLastError())
    fromSAddr(addr saddr, slen, transp.local)
  ok(transp.local)

func toException(v: OSErrorCode): ref TransportOsError =
  getTransportOsError(v)

proc remoteAddress*(
    transp: DatagramTransport
): TransportAddress {.raises: [TransportOsError].} =
  ## Returns ``transp`` remote socket address.
  remoteAddress2(transp).tryGet()

proc localAddress*(
    transp: DatagramTransport
): TransportAddress {.raises: [TransportOsError].} =
  ## Returns ``transp`` remote socket address.
  localAddress2(transp).tryGet()

template setReadError(t, e: untyped) =
  (t).state.incl(ReadError)
  (t).error = getTransportOsError(e)

when defined(windows):
  template setWriterWSABuffer(t, v: untyped) =
    (t).wwsabuf.buf = cast[cstring](v.buf)
    (t).wwsabuf.len = cast[ULONG](v.buflen)

  proc writeDatagramLoop(udata: pointer) =
    var bytesCount: uint32
    var ovl = cast[PtrCustomOverlapped](udata)
    var transp = cast[DatagramTransport](ovl.data.udata)
    while len(transp.queue) > 0:
      if WritePending in transp.state:
        ## Continuation
        transp.state.excl(WritePending)
        let err = transp.wovl.data.errCode
        let vector = transp.queue.popFirst()
        case err
        of OSErrorCode(-1):
          if not (vector.writer.finished()):
            vector.writer.complete()
        of ERROR_OPERATION_ABORTED:
          # CancelIO() interrupt
          transp.state.incl(WritePaused)
          if not (vector.writer.finished()):
            vector.writer.complete()
        else:
          transp.state.incl({WritePaused, WriteError})
          if not (vector.writer.finished()):
            vector.writer.fail(getTransportOsError(err))
      else:
        ## Initiation
        transp.state.incl(WritePending)
        let fd = SocketHandle(transp.fd)
        let vector = transp.queue.popFirst()
        transp.setWriterWSABuffer(vector)
        let ret =
          if vector.kind == WithAddress:
            # We only need `Sockaddr_storage` data here, so result discarded.
            discard transp.setRemoteAddress(vector.address)
            wsaSendTo(
              fd,
              addr transp.wwsabuf,
              DWORD(1),
              addr bytesCount,
              DWORD(0),
              cast[ptr SockAddr](addr transp.waddr),
              cint(transp.walen),
              cast[POVERLAPPED](addr transp.wovl),
              nil,
            )
          else:
            wsaSend(
              fd,
              addr transp.wwsabuf,
              DWORD(1),
              addr bytesCount,
              DWORD(0),
              cast[POVERLAPPED](addr transp.wovl),
              nil,
            )
        if ret != 0:
          let err = osLastError()
          case err
          of ERROR_OPERATION_ABORTED:
            # CancelIO() interrupt
            transp.state.excl(WritePending)
            transp.state.incl(WritePaused)
            if not (vector.writer.finished()):
              vector.writer.complete()
          of ERROR_IO_PENDING:
            transp.queue.addFirst(vector)
          else:
            transp.state.excl(WritePending)
            transp.state.incl({WritePaused, WriteError})
            if not (vector.writer.finished()):
              vector.writer.fail(getTransportOsError(err))
        else:
          transp.queue.addFirst(vector)
        break

    if len(transp.queue) == 0:
      transp.state.incl(WritePaused)

  proc readDatagramLoop(udata: pointer) =
    var
      bytesCount: uint32
      ovl = cast[PtrCustomOverlapped](udata)

    let transp = cast[DatagramTransport](ovl.data.udata)

    while true:
      if ReadPending in transp.state:
        ## Continuation
        transp.state.excl(ReadPending)
        let
          err = transp.rovl.data.errCode
          remoteAddress = transp.getRemoteAddress()
        case err
        of OSErrorCode(-1):
          let bytesCount = transp.rovl.data.bytesCount
          if bytesCount == 0:
            transp.state.incl({ReadEof, ReadPaused})
          transp.buflen = int(bytesCount)
          asyncSpawn transp.function(transp, remoteAddress)
        of ERROR_OPERATION_ABORTED:
          # CancelIO() interrupt or closeSocket() call.
          transp.state.incl(ReadPaused)
          if ReadClosed in transp.state and not (transp.future.finished()):
            # Stop tracking transport
            untrackCounter(DgramTransportTrackerName)
            # If `ReadClosed` present, then close(transport) was called.
            transp.future.complete()
            GC_unref(transp)
          break
        else:
          transp.setReadError(err)
          transp.state.incl(ReadPaused)
          transp.buflen = 0
          asyncSpawn transp.function(transp, remoteAddress)
      else:
        ## Initiation
        if transp.state * {ReadEof, ReadClosed, ReadError} == {}:
          transp.state.incl(ReadPending)
          let fd = SocketHandle(transp.fd)
          transp.rflag = 0
          transp.ralen = SockLen(sizeof(Sockaddr_storage))
          let ret = wsaRecvFrom(
            fd,
            addr transp.rwsabuf,
            DWORD(1),
            addr bytesCount,
            addr transp.rflag,
            cast[ptr SockAddr](addr transp.raddr),
            cast[ptr cint](addr transp.ralen),
            cast[POVERLAPPED](addr transp.rovl),
            nil,
          )
          if ret != 0:
            let err = osLastError()
            case err
            of ERROR_OPERATION_ABORTED:
              # CancelIO() interrupt
              transp.state.excl(ReadPending)
              transp.state.incl(ReadPaused)
            of WSAECONNRESET:
              transp.state.excl(ReadPending)
              transp.state.incl({ReadPaused, ReadEof})
              break
            of ERROR_IO_PENDING:
              discard
            else:
              transp.state.excl(ReadPending)
              transp.state.incl(ReadPaused)
              transp.setReadError(err)
              transp.buflen = 0
              asyncSpawn transp.function(transp, transp.getRemoteAddress())
        else:
          # Transport closure happens in callback, and we not started new
          # WSARecvFrom session.
          if ReadClosed in transp.state and not (transp.future.finished()):
            # Stop tracking transport
            untrackCounter(DgramTransportTrackerName)
            transp.future.complete()
            GC_unref(transp)
        break

  proc resumeRead(transp: DatagramTransport): Result[void, OSErrorCode] =
    if ReadPaused in transp.state:
      transp.state.excl(ReadPaused)
      readDatagramLoop(cast[pointer](addr transp.rovl))
    ok()

  proc resumeWrite(transp: DatagramTransport): Result[void, OSErrorCode] =
    if WritePaused in transp.state:
      transp.state.excl(WritePaused)
      writeDatagramLoop(cast[pointer](addr transp.wovl))
    ok()

  proc newDatagramTransportCommon(
      cbproc: DatagramCallback,
      remote: TransportAddress,
      local: TransportAddress,
      sock: AsyncFD,
      flags: set[ServerFlags],
      udata: pointer,
      child: DatagramTransport,
      bufferSize: int,
      ttl: int,
      dualstack = DualStackType.Auto,
  ): DatagramTransport {.raises: [TransportOsError].} =
    doAssert(not isNil(cbproc))
    var res =
      if isNil(child):
        DatagramTransport()
      else:
        child

    let localSock =
      if sock == asyncInvalidSocket:
        let proto =
          if local.family == AddressFamily.Unix:
            Protocol.IPPROTO_IP
          else:
            Protocol.IPPROTO_UDP
        let res = createAsyncSocket2(local.getDomain(), SockType.SOCK_DGRAM, proto)
        if res.isErr():
          raiseTransportOsError(res.error)
        res.get()
      else:
        setDescriptorBlocking(SocketHandle(sock), false).isOkOr:
          raiseTransportOsError(error)
        register2(sock).isOkOr:
          raiseTransportOsError(error)
        sock

    ## Apply ServerFlags here
    if ServerFlags.ReuseAddr in flags:
      setSockOpt2(localSock, SOL_SOCKET, SO_REUSEADDR, 1).isOkOr:
        if sock == asyncInvalidSocket:
          closeSocket(localSock)
        raiseTransportOsError(error)

    if ServerFlags.ReusePort in flags:
      setSockOpt2(localSock, SOL_SOCKET, SO_REUSEPORT, 1).isOkOr:
        if sock == asyncInvalidSocket:
          closeSocket(localSock)
        raiseTransportOsError(error)

    if ServerFlags.Broadcast in flags:
      setSockOpt2(localSock, SOL_SOCKET, SO_BROADCAST, 1).isOkOr:
        if sock == asyncInvalidSocket:
          closeSocket(localSock)
        raiseTransportOsError(error)

      if ttl > 0:
        setSockOpt2(localSock, osdefs.IPPROTO_IP, osdefs.IP_TTL, ttl).isOkOr:
          if sock == asyncInvalidSocket:
            closeSocket(localSock)
          raiseTransportOsError(error)

    ## IPV6_V6ONLY
    if sock == asyncInvalidSocket:
      setDualstack(localSock, local.family, dualstack).isOkOr:
        closeSocket(localSock)
        raiseTransportOsError(error)
    else:
      setDualstack(localSock, dualstack).isOkOr:
        raiseTransportOsError(error)

    ## Fix for Q263823.
    var bytesRet: DWORD
    var bval = WINBOOL(0)
    if wsaIoctl(
      SocketHandle(localSock),
      osdefs.SIO_UDP_CONNRESET,
      addr bval,
      sizeof(WINBOOL).DWORD,
      nil,
      DWORD(0),
      addr bytesRet,
      nil,
      nil,
    ) != 0:
      raiseTransportOsError(osLastError())

    if local.family != AddressFamily.None:
      var saddr: Sockaddr_storage
      var slen: SockLen
      toSAddr(local, saddr, slen)

      if bindSocket(SocketHandle(localSock), cast[ptr SockAddr](addr saddr), slen) != 0:
        let err = osLastError()
        if sock == asyncInvalidSocket:
          closeSocket(localSock)
        raiseTransportOsError(err)
    else:
      var saddr: Sockaddr_storage
      var slen: SockLen
      saddr.ss_family = type(saddr.ss_family)(local.getDomain())
      if bindSocket(SocketHandle(localSock), cast[ptr SockAddr](addr saddr), slen) != 0:
        let err = osLastError()
        if sock == asyncInvalidSocket:
          closeSocket(localSock)
        raiseTransportOsError(err)

    res.flags = block:
      # Add `V4Mapped` flag when `::` address is used and dualstack is
      # set to enabled or auto.
      var res = flags
      if (local.family == AddressFamily.IPv6) and local.isAnyLocal():
        if dualstack in {DualStackType.Enabled, DualStackType.Auto}:
          res.incl(ServerFlags.V4Mapped)
      res

    if remote.port != Port(0):
      let remoteAddress = res.setRemoteAddress(remote)
      if connect(SocketHandle(localSock), cast[ptr SockAddr](addr res.waddr), res.walen) !=
          0:
        let err = osLastError()
        if sock == asyncInvalidSocket:
          closeSocket(localSock)
        raiseTransportOsError(err)
      res.remote = remoteAddress

    res.fd = localSock
    res.function = cbproc
    res.buffer = newSeq[byte](bufferSize)
    res.queue = initDeque[GramVector]()
    res.udata = udata
    res.state = {ReadPaused, WritePaused}
    res.future = Future[void].Raising([]).init(
        "datagram.transport", {FutureFlag.OwnCancelSchedule}
      )
    res.rovl.data = CompletionData(cb: readDatagramLoop, udata: cast[pointer](res))
    res.wovl.data = CompletionData(cb: writeDatagramLoop, udata: cast[pointer](res))
    res.rwsabuf =
      WSABUF(buf: cast[cstring](baseAddr res.buffer), len: ULONG(len(res.buffer)))
    GC_ref(res)
    # Start tracking transport
    trackCounter(DgramTransportTrackerName)
    if NoAutoRead notin flags:
      let rres = res.resumeRead()
      if rres.isErr():
        raiseTransportOsError(rres.error())
    res

else:
  # Linux/BSD/MacOS part

  proc readDatagramLoop(udata: pointer) {.raises: [].} =
    doAssert(not isNil(udata))
    let
      transp = cast[DatagramTransport](udata)
      fd = SocketHandle(transp.fd)
    if int(fd) == 0:
      ## This situation can be happen, when there events present
      ## after transport was closed.
      return
    if ReadClosed in transp.state:
      transp.state.incl({ReadPaused})
    else:
      while true:
        transp.ralen = SockLen(sizeof(Sockaddr_storage))
        var res = osdefs.recvfrom(
          fd,
          baseAddr transp.buffer,
          cint(len(transp.buffer)),
          cint(0),
          cast[ptr SockAddr](addr transp.raddr),
          addr transp.ralen,
        )
        if res >= 0:
          transp.buflen = res
          asyncSpawn transp.function(transp, transp.getRemoteAddress())
        else:
          let err = osLastError()
          case err
          of oserrno.EINTR:
            continue
          else:
            transp.buflen = 0
            transp.setReadError(err)
            asyncSpawn transp.function(transp, transp.getRemoteAddress())
        break

  proc writeDatagramLoop(udata: pointer) =
    var res: int
    doAssert(not isNil(udata))
    let
      transp = cast[DatagramTransport](udata)
      fd = SocketHandle(transp.fd)
    if int(fd) == 0:
      ## This situation can be happen, when there events present
      ## after transport was closed.
      return
    if WriteClosed in transp.state:
      transp.state.incl({WritePaused})
    else:
      if len(transp.queue) > 0:
        let vector = transp.queue.popFirst()
        while true:
          if vector.kind == WithAddress:
            # We only need `Sockaddr_storage` data here, so result discarded.
            discard transp.setRemoteAddress(vector.address)
            res = osdefs.sendto(
              fd,
              vector.buf,
              vector.buflen,
              MSG_NOSIGNAL,
              cast[ptr SockAddr](addr transp.waddr),
              transp.walen,
            )
          elif vector.kind == WithoutAddress:
            res = osdefs.send(fd, vector.buf, vector.buflen, MSG_NOSIGNAL)
          if res >= 0:
            if not (vector.writer.finished()):
              vector.writer.complete()
          else:
            let err = osLastError()
            case err
            of oserrno.EINTR:
              continue
            else:
              if not (vector.writer.finished()):
                vector.writer.fail(getTransportOsError(err))
          break
      else:
        transp.state.incl({WritePaused})
        discard removeWriter2(transp.fd)

  proc resumeWrite(transp: DatagramTransport): Result[void, OSErrorCode] =
    if WritePaused in transp.state:
      ?addWriter2(transp.fd, writeDatagramLoop, cast[pointer](transp))
      transp.state.excl(WritePaused)
    ok()

  proc resumeRead(transp: DatagramTransport): Result[void, OSErrorCode] =
    if ReadPaused in transp.state:
      ?addReader2(transp.fd, readDatagramLoop, cast[pointer](transp))
      transp.state.excl(ReadPaused)
    ok()

  proc newDatagramTransportCommon(
      cbproc: DatagramCallback,
      remote: TransportAddress,
      local: TransportAddress,
      sock: AsyncFD,
      flags: set[ServerFlags],
      udata: pointer,
      child: DatagramTransport,
      bufferSize: int,
      ttl: int,
      dualstack = DualStackType.Auto,
  ): DatagramTransport {.raises: [TransportOsError].} =
    doAssert(not isNil(cbproc))
    var res =
      if isNil(child):
        DatagramTransport()
      else:
        child

    let localSock =
      if sock == asyncInvalidSocket:
        let proto =
          if local.family == AddressFamily.Unix:
            Protocol.IPPROTO_IP
          else:
            Protocol.IPPROTO_UDP
        let res = createAsyncSocket2(local.getDomain(), SockType.SOCK_DGRAM, proto)
        if res.isErr():
          raiseTransportOsError(res.error)
        res.get()
      else:
        setDescriptorBlocking(SocketHandle(sock), false).isOkOr:
          raiseTransportOsError(error)
        register2(sock).isOkOr:
          raiseTransportOsError(error)
        sock

    ## Apply ServerFlags here
    if ServerFlags.ReuseAddr in flags:
      setSockOpt2(localSock, SOL_SOCKET, SO_REUSEADDR, 1).isOkOr:
        if sock == asyncInvalidSocket:
          closeSocket(localSock)
        raiseTransportOsError(error)

    if ServerFlags.ReusePort in flags:
      setSockOpt2(localSock, SOL_SOCKET, SO_REUSEPORT, 1).isOkOr:
        if sock == asyncInvalidSocket:
          closeSocket(localSock)
        raiseTransportOsError(error)

    if ServerFlags.Broadcast in flags:
      setSockOpt2(localSock, SOL_SOCKET, SO_BROADCAST, 1).isOkOr:
        if sock == asyncInvalidSocket:
          closeSocket(localSock)
        raiseTransportOsError(error)

      if ttl > 0:
        if local.family == AddressFamily.IPv4:
          setSockOpt2(localSock, osdefs.IPPROTO_IP, osdefs.IP_MULTICAST_TTL, cint(ttl)).isOkOr:
            if sock == asyncInvalidSocket:
              closeSocket(localSock)
            raiseTransportOsError(error)
        elif local.family == AddressFamily.IPv6:
          setSockOpt2(
            localSock, osdefs.IPPROTO_IP, osdefs.IPV6_MULTICAST_HOPS, cint(ttl)
          ).isOkOr:
            if sock == asyncInvalidSocket:
              closeSocket(localSock)
            raiseTransportOsError(error)
        else:
          raiseAssert "Unsupported address bound to local socket"

    ## IPV6_V6ONLY
    if sock == asyncInvalidSocket:
      setDualstack(localSock, local.family, dualstack).isOkOr:
        closeSocket(localSock)
        raiseTransportOsError(error)
    else:
      setDualstack(localSock, dualstack).isOkOr:
        raiseTransportOsError(error)

    if local.family != AddressFamily.None:
      var saddr: Sockaddr_storage
      var slen: SockLen
      toSAddr(local, saddr, slen)
      if bindSocket(SocketHandle(localSock), cast[ptr SockAddr](addr saddr), slen) != 0:
        let err = osLastError()
        if sock == asyncInvalidSocket:
          closeSocket(localSock)
        raiseTransportOsError(err)

    res.flags = block:
      # Add `V4Mapped` flag when `::` address is used and dualstack is
      # set to enabled or auto.
      var res = flags
      if (local.family == AddressFamily.IPv6) and local.isAnyLocal():
        if dualstack != DualStackType.Disabled:
          res.incl(ServerFlags.V4Mapped)
      res

    if remote.port != Port(0):
      let remoteAddress = res.setRemoteAddress(remote)
      if connect(SocketHandle(localSock), cast[ptr SockAddr](addr res.waddr), res.walen) !=
          0:
        let err = osLastError()
        if sock == asyncInvalidSocket:
          closeSocket(localSock)
        raiseTransportOsError(err)
      res.remote = remoteAddress

    res.fd = localSock
    res.function = cbproc
    res.buffer = newSeq[byte](bufferSize)
    res.queue = initDeque[GramVector]()
    res.udata = udata
    res.state = {ReadPaused, WritePaused}
    res.future = Future[void].Raising([]).init(
        "datagram.transport", {FutureFlag.OwnCancelSchedule}
      )
    GC_ref(res)
    # Start tracking transport
    trackCounter(DgramTransportTrackerName)
    if NoAutoRead notin flags:
      let rres = res.resumeRead()
      if rres.isErr():
        raiseTransportOsError(rres.error())
    res

proc close*(transp: DatagramTransport) =
  ## Closes and frees resources of transport ``transp``.
  proc continuation(udata: pointer) {.raises: [].} =
    if not (transp.future.finished()):
      # Stop tracking transport
      untrackCounter(DgramTransportTrackerName)
      transp.future.complete()
      GC_unref(transp)

  when defined(windows):
    if {ReadClosed, WriteClosed} * transp.state == {}:
      transp.state.incl({WriteClosed, ReadClosed})
      if ReadPaused in transp.state:
        # If readDatagramLoop() is not running we need to finish in
        # continuation step.
        closeSocket(transp.fd, continuation)
      else:
        # If readDatagramLoop() is running, it will be properly finished inside
        # of readDatagramLoop().
        closeSocket(transp.fd)
  else:
    if {ReadClosed, WriteClosed} * transp.state == {}:
      transp.state.incl({WriteClosed, ReadClosed})
      closeSocket(transp.fd, continuation)

proc getTransportAddresses(
    local, remote: Opt[IpAddress], localPort, remotePort: Port
): tuple[local: TransportAddress, remote: TransportAddress] =
  let
    (localAuto, remoteAuto) = getAutoAddresses(localPort, remotePort)
    lres =
      if local.isSome():
        initTAddress(local.get(), localPort)
      else:
        localAuto
    rres =
      if remote.isSome():
        initTAddress(remote.get(), remotePort)
      else:
        remoteAuto
  (lres, rres)

proc newDatagramTransportCommon(
    cbproc: UnsafeDatagramCallback,
    remote: TransportAddress,
    local: TransportAddress,
    sock: AsyncFD,
    flags: set[ServerFlags],
    udata: pointer,
    child: DatagramTransport,
    bufferSize: int,
    ttl: int,
    dualstack = DualStackType.Auto,
): DatagramTransport {.raises: [TransportOsError].} =
  ## Create new UDP datagram transport (IPv4).
  ##
  ## ``cbproc`` - callback which will be called, when new datagram received.
  ## ``remote`` - bind transport to remote address (optional).
  ## ``local`` - bind transport to local address (to serving incoming
  ## datagrams, optional)
  ## ``sock`` - application-driven socket to use.
  ## ``flags`` - flags that will be applied to socket.
  ## ``udata`` - custom argument which will be passed to ``cbproc``.
  ## ``bufSize`` - size of internal buffer.
  ## ``ttl`` - TTL for UDP datagram packet (only usable when flags has
  ## ``Broadcast`` option).

  proc wrap(
      transp: DatagramTransport, remote: TransportAddress
  ) {.async: (raises: []).} =
    try:
      await cbproc(transp, remote)
    except CatchableError as exc:
      raiseAssert "Unexpected exception from stream server cbproc: " & exc.msg

  newDatagramTransportCommon(
    wrap, remote, local, sock, flags, udata, child, bufferSize, ttl, dualstack
  )

proc newDatagramTransport*(
    cbproc: DatagramCallback,
    remote: TransportAddress = AnyAddress,
    local: TransportAddress = AnyAddress,
    sock: AsyncFD = asyncInvalidSocket,
    flags: set[ServerFlags] = {},
    udata: pointer = nil,
    child: DatagramTransport = nil,
    bufSize: int = DefaultDatagramBufferSize,
    ttl: int = 0,
    dualstack = DualStackType.Auto,
): DatagramTransport {.raises: [TransportOsError].} =
  ## Create new UDP datagram transport (IPv4).
  ##
  ## ``cbproc`` - callback which will be called, when new datagram received.
  ## ``remote`` - bind transport to remote address (optional).
  ## ``local`` - bind transport to local address (to serving incoming
  ## datagrams, optional)
  ## ``sock`` - application-driven socket to use.
  ## ``flags`` - flags that will be applied to socket.
  ## ``udata`` - custom argument which will be passed to ``cbproc``.
  ## ``bufSize`` - size of internal buffer.
  ## ``ttl`` - TTL for UDP datagram packet (only usable when flags has
  ## ``Broadcast`` option).
  newDatagramTransportCommon(
    cbproc, remote, local, sock, flags, udata, child, bufSize, ttl, dualstack
  )

proc newDatagramTransport*[T](
    cbproc: DatagramCallback,
    udata: ref T,
    remote: TransportAddress = AnyAddress,
    local: TransportAddress = AnyAddress,
    sock: AsyncFD = asyncInvalidSocket,
    flags: set[ServerFlags] = {},
    child: DatagramTransport = nil,
    bufSize: int = DefaultDatagramBufferSize,
    ttl: int = 0,
    dualstack = DualStackType.Auto,
): DatagramTransport {.raises: [TransportOsError].} =
  var fflags = flags + {GCUserData}
  GC_ref(udata)
  newDatagramTransportCommon(
    cbproc,
    remote,
    local,
    sock,
    fflags,
    cast[pointer](udata),
    child,
    bufSize,
    ttl,
    dualstack,
  )

proc newDatagramTransport6*(
    cbproc: DatagramCallback,
    remote: TransportAddress = AnyAddress6,
    local: TransportAddress = AnyAddress6,
    sock: AsyncFD = asyncInvalidSocket,
    flags: set[ServerFlags] = {},
    udata: pointer = nil,
    child: DatagramTransport = nil,
    bufSize: int = DefaultDatagramBufferSize,
    ttl: int = 0,
    dualstack = DualStackType.Auto,
): DatagramTransport {.raises: [TransportOsError].} =
  ## Create new UDP datagram transport (IPv6).
  ##
  ## ``cbproc`` - callback which will be called, when new datagram received.
  ## ``remote`` - bind transport to remote address (optional).
  ## ``local`` - bind transport to local address (to serving incoming
  ## datagrams, optional)
  ## ``sock`` - application-driven socket to use.
  ## ``flags`` - flags that will be applied to socket.
  ## ``udata`` - custom argument which will be passed to ``cbproc``.
  ## ``bufSize`` - size of internal buffer.
  ## ``ttl`` - TTL for UDP datagram packet (only usable when flags has
  ## ``Broadcast`` option).
  newDatagramTransportCommon(
    cbproc, remote, local, sock, flags, udata, child, bufSize, ttl, dualstack
  )

proc newDatagramTransport6*[T](
    cbproc: DatagramCallback,
    udata: ref T,
    remote: TransportAddress = AnyAddress6,
    local: TransportAddress = AnyAddress6,
    sock: AsyncFD = asyncInvalidSocket,
    flags: set[ServerFlags] = {},
    child: DatagramTransport = nil,
    bufSize: int = DefaultDatagramBufferSize,
    ttl: int = 0,
    dualstack = DualStackType.Auto,
): DatagramTransport {.raises: [TransportOsError].} =
  var fflags = flags + {GCUserData}
  GC_ref(udata)
  newDatagramTransportCommon(
    cbproc,
    remote,
    local,
    sock,
    fflags,
    cast[pointer](udata),
    child,
    bufSize,
    ttl,
    dualstack,
  )

proc newDatagramTransport*(
    cbproc: UnsafeDatagramCallback,
    remote: TransportAddress = AnyAddress,
    local: TransportAddress = AnyAddress,
    sock: AsyncFD = asyncInvalidSocket,
    flags: set[ServerFlags] = {},
    udata: pointer = nil,
    child: DatagramTransport = nil,
    bufSize: int = DefaultDatagramBufferSize,
    ttl: int = 0,
    dualstack = DualStackType.Auto,
): DatagramTransport {.
    raises: [TransportOsError],
    deprecated:
      "Callback must not raise exceptions, annotate with {.async: (raises: []).}"
.} =
  ## Create new UDP datagram transport (IPv4).
  ##
  ## ``cbproc`` - callback which will be called, when new datagram received.
  ## ``remote`` - bind transport to remote address (optional).
  ## ``local`` - bind transport to local address (to serving incoming
  ## datagrams, optional)
  ## ``sock`` - application-driven socket to use.
  ## ``flags`` - flags that will be applied to socket.
  ## ``udata`` - custom argument which will be passed to ``cbproc``.
  ## ``bufSize`` - size of internal buffer.
  ## ``ttl`` - TTL for UDP datagram packet (only usable when flags has
  ## ``Broadcast`` option).
  newDatagramTransportCommon(
    cbproc, remote, local, sock, flags, udata, child, bufSize, ttl, dualstack
  )

proc newDatagramTransport*[T](
    cbproc: UnsafeDatagramCallback,
    udata: ref T,
    remote: TransportAddress = AnyAddress,
    local: TransportAddress = AnyAddress,
    sock: AsyncFD = asyncInvalidSocket,
    flags: set[ServerFlags] = {},
    child: DatagramTransport = nil,
    bufSize: int = DefaultDatagramBufferSize,
    ttl: int = 0,
    dualstack = DualStackType.Auto,
): DatagramTransport {.
    raises: [TransportOsError],
    deprecated:
      "Callback must not raise exceptions, annotate with {.async: (raises: []).}"
.} =
  var fflags = flags + {GCUserData}
  GC_ref(udata)
  newDatagramTransportCommon(
    cbproc,
    remote,
    local,
    sock,
    fflags,
    cast[pointer](udata),
    child,
    bufSize,
    ttl,
    dualstack,
  )

proc newDatagramTransport6*(
    cbproc: UnsafeDatagramCallback,
    remote: TransportAddress = AnyAddress6,
    local: TransportAddress = AnyAddress6,
    sock: AsyncFD = asyncInvalidSocket,
    flags: set[ServerFlags] = {},
    udata: pointer = nil,
    child: DatagramTransport = nil,
    bufSize: int = DefaultDatagramBufferSize,
    ttl: int = 0,
    dualstack = DualStackType.Auto,
): DatagramTransport {.
    raises: [TransportOsError],
    deprecated:
      "Callback must not raise exceptions, annotate with {.async: (raises: []).}"
.} =
  ## Create new UDP datagram transport (IPv6).
  ##
  ## ``cbproc`` - callback which will be called, when new datagram received.
  ## ``remote`` - bind transport to remote address (optional).
  ## ``local`` - bind transport to local address (to serving incoming
  ## datagrams, optional)
  ## ``sock`` - application-driven socket to use.
  ## ``flags`` - flags that will be applied to socket.
  ## ``udata`` - custom argument which will be passed to ``cbproc``.
  ## ``bufSize`` - size of internal buffer.
  ## ``ttl`` - TTL for UDP datagram packet (only usable when flags has
  ## ``Broadcast`` option).
  newDatagramTransportCommon(
    cbproc, remote, local, sock, flags, udata, child, bufSize, ttl, dualstack
  )

proc newDatagramTransport6*[T](
    cbproc: UnsafeDatagramCallback,
    udata: ref T,
    remote: TransportAddress = AnyAddress6,
    local: TransportAddress = AnyAddress6,
    sock: AsyncFD = asyncInvalidSocket,
    flags: set[ServerFlags] = {},
    child: DatagramTransport = nil,
    bufSize: int = DefaultDatagramBufferSize,
    ttl: int = 0,
    dualstack = DualStackType.Auto,
): DatagramTransport {.
    raises: [TransportOsError],
    deprecated:
      "Callback must not raise exceptions, annotate with {.async: (raises: []).}"
.} =
  var fflags = flags + {GCUserData}
  GC_ref(udata)
  newDatagramTransportCommon(
    cbproc,
    remote,
    local,
    sock,
    fflags,
    cast[pointer](udata),
    child,
    bufSize,
    ttl,
    dualstack,
  )

proc newDatagramTransport*(
    cbproc: DatagramCallback,
    localPort: Port,
    remotePort: Port,
    local: Opt[IpAddress] = Opt.none(IpAddress),
    remote: Opt[IpAddress] = Opt.none(IpAddress),
    flags: set[ServerFlags] = {},
    udata: pointer = nil,
    child: DatagramTransport = nil,
    bufSize: int = DefaultDatagramBufferSize,
    ttl: int = 0,
    dualstack = DualStackType.Auto,
): DatagramTransport {.raises: [TransportOsError].} =
  ## Create new UDP datagram transport (IPv6) and bind it to ANY_ADDRESS.
  ## Depending on OS settings procedure perform an attempt to create transport
  ## using IPv6 ANY_ADDRESS, if its not available it will try to bind transport
  ## to IPv4 ANY_ADDRESS.
  ##
  ## ``cbproc`` - callback which will be called, when new datagram received.
  ## ``localPort`` - local peer's port number.
  ## ``remotePort`` - remote peer's port number.
  ## ``local`` - optional local peer's IPv4/IPv6 address.
  ## ``remote`` - optional remote peer's IPv4/IPv6 address.
  ## ``sock`` - application-driven socket to use.
  ## ``flags`` - flags that will be applied to socket.
  ## ``udata`` - custom argument which will be passed to ``cbproc``.
  ## ``bufSize`` - size of internal buffer.
  ## ``ttl`` - TTL for UDP datagram packet (only usable when flags has
  ## ``Broadcast`` option).
  let (localHost, remoteHost) =
    getTransportAddresses(local, remote, localPort, remotePort)
  newDatagramTransportCommon(
    cbproc,
    remoteHost,
    localHost,
    asyncInvalidSocket,
    flags,
    cast[pointer](udata),
    child,
    bufSize,
    ttl,
    dualstack,
  )

proc newDatagramTransport*(
    cbproc: DatagramCallback,
    localPort: Port,
    local: Opt[IpAddress] = Opt.none(IpAddress),
    flags: set[ServerFlags] = {},
    udata: pointer = nil,
    child: DatagramTransport = nil,
    bufSize: int = DefaultDatagramBufferSize,
    ttl: int = 0,
    dualstack = DualStackType.Auto,
): DatagramTransport {.raises: [TransportOsError].} =
  newDatagramTransport(
    cbproc,
    localPort,
    Port(0),
    local,
    Opt.none(IpAddress),
    flags,
    udata,
    child,
    bufSize,
    ttl,
    dualstack,
  )

proc newDatagramTransport*[T](
    cbproc: DatagramCallback,
    localPort: Port,
    remotePort: Port,
    local: Opt[IpAddress] = Opt.none(IpAddress),
    remote: Opt[IpAddress] = Opt.none(IpAddress),
    flags: set[ServerFlags] = {},
    udata: ref T,
    child: DatagramTransport = nil,
    bufSize: int = DefaultDatagramBufferSize,
    ttl: int = 0,
    dualstack = DualStackType.Auto,
): DatagramTransport {.raises: [TransportOsError].} =
  let
    (localHost, remoteHost) =
      getTransportAddresses(local, remote, localPort, remotePort)
    fflags = flags + {GCUserData}
  GC_ref(udata)
  newDatagramTransportCommon(
    cbproc,
    remoteHost,
    localHost,
    asyncInvalidSocket,
    fflags,
    cast[pointer](udata),
    child,
    bufSize,
    ttl,
    dualstack,
  )

proc newDatagramTransport*[T](
    cbproc: DatagramCallback,
    localPort: Port,
    local: Opt[IpAddress] = Opt.none(IpAddress),
    flags: set[ServerFlags] = {},
    udata: ref T,
    child: DatagramTransport = nil,
    bufSize: int = DefaultDatagramBufferSize,
    ttl: int = 0,
    dualstack = DualStackType.Auto,
): DatagramTransport {.raises: [TransportOsError].} =
  newDatagramTransport(
    cbproc,
    localPort,
    Port(0),
    local,
    Opt.none(IpAddress),
    flags,
    udata,
    child,
    bufSize,
    ttl,
    dualstack,
  )

proc join*(
    transp: DatagramTransport
): Future[void] {.async: (raw: true, raises: [CancelledError]).} =
  ## Wait until the transport ``transp`` will be closed.
  transp.future.join()

proc closed*(transp: DatagramTransport): bool {.inline.} =
  ## Returns ``true`` if transport in closed state.
  {ReadClosed, WriteClosed} * transp.state != {}

proc closeWait*(transp: DatagramTransport): Future[void] {.async: (raises: []).} =
  ## Close transport ``transp`` and release all resources.
  if not transp.closed():
    transp.close()
    await noCancel(transp.join())

proc send*(
    transp: DatagramTransport, pbytes: pointer, nbytes: int
): Future[void] {.async: (raw: true, raises: [TransportError, CancelledError]).} =
  ## Send buffer with pointer ``pbytes`` and size ``nbytes`` using transport
  ## ``transp`` to remote destination address which was bounded on transport.
  let retFuture = newFuture[void]("datagram.transport.send(pointer)")
  transp.checkClosed(retFuture)
  if transp.remote.port == Port(0):
    retFuture.fail(newException(TransportError, "Remote peer not set!"))
    return retFuture
  let vector =
    GramVector(kind: WithoutAddress, buf: pbytes, buflen: nbytes, writer: retFuture)
  transp.queue.addLast(vector)
  if WritePaused in transp.state:
    let wres = transp.resumeWrite()
    if wres.isErr():
      retFuture.fail(getTransportOsError(wres.error()))
  return retFuture

proc send*(
    transp: DatagramTransport, msg: string, msglen = -1
): Future[void] {.async: (raw: true, raises: [TransportError, CancelledError]).} =
  ## Send string ``msg`` using transport ``transp`` to remote destination
  ## address which was bounded on transport.
  let retFuture = newFuture[void]("datagram.transport.send(string)")
  transp.checkClosed(retFuture)

  let length =
    if msglen <= 0:
      len(msg)
    else:
      msglen
  var localCopy = msg
  retFuture.addCallback(
    proc(_: pointer) =
      reset(localCopy)
  )

  let vector = GramVector(
    kind: WithoutAddress, buf: baseAddr localCopy, buflen: length, writer: retFuture
  )

  transp.queue.addLast(vector)
  if WritePaused in transp.state:
    let wres = transp.resumeWrite()
    if wres.isErr():
      retFuture.fail(getTransportOsError(wres.error()))
  return retFuture

proc send*[T](
    transp: DatagramTransport, msg: seq[T], msglen = -1
): Future[void] {.async: (raw: true, raises: [TransportError, CancelledError]).} =
  ## Send string ``msg`` using transport ``transp`` to remote destination
  ## address which was bounded on transport.
  let retFuture = newFuture[void]("datagram.transport.send(seq)")
  transp.checkClosed(retFuture)

  let length =
    if msglen <= 0:
      (len(msg) * sizeof(T))
    else:
      (msglen * sizeof(T))
  var localCopy = msg
  retFuture.addCallback(
    proc(_: pointer) =
      reset(localCopy)
  )

  let vector = GramVector(
    kind: WithoutAddress, buf: baseAddr localCopy, buflen: length, writer: retFuture
  )
  transp.queue.addLast(vector)
  if WritePaused in transp.state:
    let wres = transp.resumeWrite()
    if wres.isErr():
      retFuture.fail(getTransportOsError(wres.error()))
  return retFuture

proc sendTo*(
    transp: DatagramTransport, remote: TransportAddress, pbytes: pointer, nbytes: int
): Future[void] {.async: (raw: true, raises: [TransportError, CancelledError]).} =
  ## Send buffer with pointer ``pbytes`` and size ``nbytes`` using transport
  ## ``transp`` to remote destination address ``remote``.
  let retFuture = newFuture[void]("datagram.transport.sendTo(pointer)")
  transp.checkClosed(retFuture)
  let vector = GramVector(
    kind: WithAddress, buf: pbytes, buflen: nbytes, writer: retFuture, address: remote
  )
  transp.queue.addLast(vector)
  if WritePaused in transp.state:
    let wres = transp.resumeWrite()
    if wres.isErr():
      retFuture.fail(getTransportOsError(wres.error()))
  return retFuture

proc sendTo*(
    transp: DatagramTransport, remote: TransportAddress, msg: string, msglen = -1
): Future[void] {.async: (raw: true, raises: [TransportError, CancelledError]).} =
  ## Send string ``msg`` using transport ``transp`` to remote destination
  ## address ``remote``.
  let retFuture = newFuture[void]("datagram.transport.sendTo(string)")
  transp.checkClosed(retFuture)

  let length =
    if msglen <= 0:
      len(msg)
    else:
      msglen
  var localCopy = msg
  retFuture.addCallback(
    proc(_: pointer) =
      reset(localCopy)
  )

  let vector = GramVector(
    kind: WithAddress,
    buf: baseAddr localCopy,
    buflen: length,
    writer: retFuture,
    address: remote,
  )
  transp.queue.addLast(vector)
  if WritePaused in transp.state:
    let wres = transp.resumeWrite()
    if wres.isErr():
      retFuture.fail(getTransportOsError(wres.error()))
  return retFuture

proc sendTo*[T](
    transp: DatagramTransport, remote: TransportAddress, msg: seq[T], msglen = -1
): Future[void] {.async: (raw: true, raises: [TransportError, CancelledError]).} =
  ## Send sequence ``msg`` using transport ``transp`` to remote destination
  ## address ``remote``.
  let retFuture = newFuture[void]("datagram.transport.sendTo(seq)")
  transp.checkClosed(retFuture)
  let length =
    if msglen <= 0:
      (len(msg) * sizeof(T))
    else:
      (msglen * sizeof(T))
  var localCopy = msg
  retFuture.addCallback(
    proc(_: pointer) =
      reset(localCopy)
  )

  let vector = GramVector(
    kind: WithAddress,
    buf: baseAddr localCopy,
    buflen: length,
    writer: retFuture,
    address: remote,
  )
  transp.queue.addLast(vector)
  if WritePaused in transp.state:
    let wres = transp.resumeWrite()
    if wres.isErr():
      retFuture.fail(getTransportOsError(wres.error()))
  return retFuture

proc peekMessage*(
    transp: DatagramTransport, msg: var seq[byte], msglen: var int
) {.raises: [TransportError].} =
  ## Get access to internal message buffer and length of incoming datagram.
  if ReadError in transp.state:
    transp.state.excl(ReadError)
    raise transp.getError()
  when declared(shallowCopy):
    shallowCopy(msg, transp.buffer)
  else:
    msg = transp.buffer
  msglen = transp.buflen

proc getMessage*(transp: DatagramTransport): seq[byte] {.raises: [TransportError].} =
  ## Copy data from internal message buffer and return result.
  if ReadError in transp.state:
    transp.state.excl(ReadError)
    raise transp.getError()
  if transp.buflen > 0:
    var res = newSeq[byte](transp.buflen)
    copyMem(addr res[0], addr transp.buffer[0], transp.buflen)
    res
  else:
    default(seq[byte])

proc getUserData*[T](transp: DatagramTransport): T {.inline.} =
  ## Obtain user data stored in ``transp`` object.
  cast[T](transp.udata)

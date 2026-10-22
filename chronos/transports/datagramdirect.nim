# Copyright (c) Status Research & Development GmbH
# Licensed under either of Apache License, version 2.0, or MIT license.
# Included by datagram.nim so direct and queued sends share transport state.

type
  DatagramBuffer* = object
    ## Borrowed payload fragment. Both the descriptor and payload must remain
    ## valid until the send call returns. Layout matches POSIX iovec.
    base*: pointer
    len*: csize_t

  DatagramOut* = object
    remote*: TransportAddress
    buffers*: ptr UncheckedArray[DatagramBuffer]
    bufferCount*: int

  DatagramNativeOut* = object
    ## Borrowed IPv4/IPv6 socket address and payload descriptors. remote must
    ## point to readable storage of remoteLen bytes until trySendNativeBatch
    ## returns. remoteLen must match the address family exactly. Nothing is
    ## retained; native IPv6 scope/flow fields are preserved unless normalized.
    remote*: ptr Sockaddr_storage
    remoteLen*: SockLen
    buffers*: ptr UncheckedArray[DatagramBuffer]
    bufferCount*: int

  DatagramSendResult* = object
    ## sent counts complete datagrams accepted by the OS, not delivered peers.
    ## error is zero on success or a short batch with no known failure reason.
    ## A nonzero error applies to the first unsent datagram. No buffers are kept.
    sent*: int
    error*: OSErrorCode

proc prepareAddress(transp: DatagramTransport, packet: DatagramOut,
                    storage: var Sockaddr_storage,
                    length: var SockLen): OSErrorCode =
  discard transp.setRemoteAddress(packet.remote)
  storage = transp.waddr
  length = transp.walen

proc prepareAddress(transp: DatagramTransport, packet: DatagramNativeOut,
                    storage: var Sockaddr_storage,
                    length: var SockLen): OSErrorCode =
  const InvalidAddress =
    when defined(windows): OSErrorCode(WSAEINVAL)
    else: OSErrorCode(oserrno.EINVAL)
  if packet.remote == nil or
      int(packet.remoteLen) notin [sizeof(Sockaddr_in), sizeof(Sockaddr_in6)]:
    return InvalidAddress
  let family = int(packet.remote.ss_family)
  if not ((family == toInt(Domain.AF_INET) and
           int(packet.remoteLen) == sizeof(Sockaddr_in)) or
          (family == toInt(Domain.AF_INET6) and
           int(packet.remoteLen) == sizeof(Sockaddr_in6))):
    return InvalidAddress
  if family == toInt(Domain.AF_INET) and ServerFlags.V4Mapped in transp.flags:
    var remote: TransportAddress
    fromSAddr(packet.remote, packet.remoteLen, remote)
    discard transp.setRemoteAddress(remote)
    storage = transp.waddr
    length = transp.walen
    return
  when defined(windows) or defined(macos) or defined(macosx):
    var remote: TransportAddress
    fromSAddr(packet.remote, packet.remoteLen, remote)
    if anyAddressFix(remote) != remote:
      discard transp.setRemoteAddress(remote)
      storage = transp.waddr
      length = transp.walen
      return
  length = packet.remoteLen
  copyMem(addr storage, packet.remote, int(length))

when defined(linux):
  {.passc: "-D_GNU_SOURCE".}
  type DatagramMMsg {.importc: "struct mmsghdr", header: "<sys/socket.h>",
                      bycopy.} = object
    msg_hdr: native.Tmsghdr
    msg_len: cuint
  proc sendmmsg(fd: native.SocketHandle, msgs: ptr DatagramMMsg,
               count: cuint, flags: cint): cint {.
    importc, header: "<sys/socket.h>".}

when not defined(windows):
  static:
    doAssert offsetOf(DatagramBuffer, base) == offsetOf(native.IOVec, iov_base)
    doAssert offsetOf(DatagramBuffer, len) == offsetOf(native.IOVec, iov_len)

  proc prepareMessage[T: DatagramOut | DatagramNativeOut](
      packet: T, storage: var Sockaddr_storage,
      addressLen: SockLen): native.Tmsghdr =
    result.msg_name = addr storage
    result.msg_namelen = native.SockLen(addressLen)
    result.msg_iov = cast[ptr native.IOVec](packet.buffers)
    result.msg_iovlen = typeof(result.msg_iovlen)(packet.bufferCount)

proc trySendBatchImpl[T: DatagramOut | DatagramNativeOut](
    transp: DatagramTransport, packets: openArray[T]): DatagramSendResult =
  if packets.len == 0:
    return
  if transp.closed():
    when defined(windows):
      result.error = OSErrorCode(WSAENOTSOCK)
    else:
      result.error = OSErrorCode(oserrno.EBADF)
    return
  if transp.queue.len > 0:
    when defined(windows):
      result.error = OSErrorCode(WSAEWOULDBLOCK)
    else:
      result.error = OSErrorCode(oserrno.EAGAIN)
    return

  when defined(linux):
    const BatchSize = 64
    var
      addresses: array[BatchSize, Sockaddr_storage]
      messages: array[BatchSize, DatagramMMsg]
    while result.sent < packets.len:
      var
        count = 0
        addressError: OSErrorCode
      for i in 0 ..< min(BatchSize, packets.len - result.sent):
        let packet = packets[result.sent + i]
        doAssert packet.bufferCount >= 0
        var addressLen: SockLen
        addressError = prepareAddress(transp, packet, addresses[i], addressLen)
        if addressError != OSErrorCode(0):
          break
        messages[i].msg_hdr = prepareMessage(packet, addresses[i], addressLen)
        inc count
      if count == 0:
        result.error = addressError
        return
      let sent = sendmmsg(native.SocketHandle(transp.fd), addr messages[0],
                          cuint(count), MSG_NOSIGNAL)
      if sent < 0:
        let error = osLastError()
        if error == OSErrorCode(oserrno.EINTR):
          continue
        result.error = error
        return
      result.sent += int(sent)
      if int(sent) < count:
        return
      if addressError != OSErrorCode(0):
        result.error = addressError
        return
  else:
    when defined(windows):
      var
        stackBuffers: array[64, WSABUF]
        overflow: seq[WSABUF]
    while result.sent < packets.len:
      let packet = packets[result.sent]
      doAssert packet.bufferCount >= 0
      result.error = prepareAddress(transp, packet, transp.waddr, transp.walen)
      if result.error != OSErrorCode(0):
        return
      when defined(windows):
        let buffers =
          if packet.bufferCount <= stackBuffers.len:
            cast[ptr UncheckedArray[WSABUF]](addr stackBuffers[0])
          else:
            overflow.setLen(packet.bufferCount)
            cast[ptr UncheckedArray[WSABUF]](addr overflow[0])
        for i in 0 ..< packet.bufferCount:
          buffers[i] = WSABUF(buf: cast[cstring](packet.buffers[i].base),
                              len: ULONG(packet.buffers[i].len))
        if packet.bufferCount == 0:
          buffers[0] = WSABUF(buf: nil, len: 0)
        var bytes: DWORD
        let sent = wsaSendTo(SocketHandle(transp.fd), addr buffers[0],
          DWORD(max(1, packet.bufferCount)), addr bytes, DWORD(0),
          cast[ptr SockAddr](addr transp.waddr), cint(transp.walen), nil, nil)
      else:
        var
          msg = prepareMessage(packet, transp.waddr, transp.walen)
          empty: native.IOVec
        # BSD sendmsg rejects a zero-iovec message even for an empty datagram.
        if packet.bufferCount == 0:
          msg.msg_iov = addr empty
          msg.msg_iovlen = 1
        let sent = native.sendmsg(native.SocketHandle(transp.fd), addr msg,
                                  MSG_NOSIGNAL)
      if sent < 0:
        let error = osLastError()
        when defined(windows):
          if error == OSErrorCode(WSAEINTR):
            continue
        else:
          if error == OSErrorCode(oserrno.EINTR):
            continue
        result.error = error
        return
      inc result.sent

proc trySendBatch*(transp: DatagramTransport,
                   packets: openArray[DatagramOut]): DatagramSendResult =
  ## Attempt immediate nonblocking sends, without Futures, payload copies or
  ## queuing. Retry only packets[sent .. ^1]. A short batch with error == 0 has
  ## an unknown stop reason; it must not be interpreted as a permanent failure.
  ## EAGAIN/EWOULDBLOCK (WSAEWOULDBLOCK on Windows) means retry later, including
  ## when queued sends are pending: direct sends never overtake that queue.
  ## Payload fragments form one atomic datagram, not independent messages.
  trySendBatchImpl(transp, packets)

proc trySendNativeBatch*(transp: DatagramTransport,
                         packets: openArray[DatagramNativeOut]): DatagramSendResult =
  ## Same immediate-send, queue ordering and accepted-prefix contract as
  ## trySendBatch, with borrowed native IPv4/IPv6 destination addresses.
  ## A nil address, unsupported family or mismatched length reports EINVAL
  ## (WSAEINVAL on Windows) for the first unsent datagram. IPv4 destinations
  ## are mapped for dual-stack sockets; wildcard destinations follow the
  ## same platform normalization as trySendBatch. Addresses are never modified.
  trySendBatchImpl(transp, packets)

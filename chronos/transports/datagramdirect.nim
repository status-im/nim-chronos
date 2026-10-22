# Copyright (c) Status Research & Development GmbH
# Licensed under either of Apache License, version 2.0, or MIT license.
# Included by datagram.nim so direct and queued sends share transport state.

type
  DatagramBuffer* = object
    ## Borrowed payload fragment. Both the descriptor and payload must remain
    ## valid until trySendBatch returns. Layout matches POSIX iovec.
    base*: pointer
    len*: csize_t

  DatagramOut* = object
    remote*: TransportAddress
    buffers*: ptr UncheckedArray[DatagramBuffer]
    bufferCount*: int

  DatagramSendResult* = object
    ## sent counts complete datagrams accepted by the OS, not delivered peers.
    ## error is zero on success or a short batch with no known failure reason.
    ## A nonzero error applies to the first unsent datagram. No buffers are kept.
    sent*: int
    error*: OSErrorCode

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

  proc prepareMessage(packet: DatagramOut, storage: var Sockaddr_storage,
                      addressLen: SockLen): native.Tmsghdr =
    result.msg_name = addr storage
    result.msg_namelen = native.SockLen(addressLen)
    result.msg_iov = cast[ptr native.IOVec](packet.buffers)
    result.msg_iovlen = typeof(result.msg_iovlen)(packet.bufferCount)

proc trySendBatch*(transp: DatagramTransport,
                   packets: openArray[DatagramOut]): DatagramSendResult =
  ## Attempt immediate nonblocking sends, without Futures, payload copies or
  ## queuing. Retry only packets[sent .. ^1]. A short batch with error == 0 has
  ## an unknown stop reason; it must not be interpreted as a permanent failure.
  ## EAGAIN/EWOULDBLOCK (WSAEWOULDBLOCK on Windows) means retry later, including
  ## when queued sends are pending: direct sends never overtake that queue.
  ## Payload fragments form one atomic datagram, not independent messages.
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
      let count = min(BatchSize, packets.len - result.sent)
      for i in 0 ..< count:
        let packet = packets[result.sent + i]
        doAssert packet.bufferCount >= 0
        discard transp.setRemoteAddress(packet.remote)
        addresses[i] = transp.waddr
        messages[i].msg_hdr = prepareMessage(packet, addresses[i], transp.walen)
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
  else:
    when defined(windows):
      var
        stackBuffers: array[64, WSABUF]
        overflow: seq[WSABUF]
    while result.sent < packets.len:
      let packet = packets[result.sent]
      doAssert packet.bufferCount >= 0
      discard transp.setRemoteAddress(packet.remote)
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
        var bytes: DWORD
        let sent = wsaSendTo(SocketHandle(transp.fd), addr buffers[0],
          DWORD(packet.bufferCount), addr bytes, DWORD(0),
          cast[ptr SockAddr](addr transp.waddr), cint(transp.walen), nil, nil)
      else:
        var msg = prepareMessage(packet, transp.waddr, transp.walen)
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

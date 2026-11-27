# Copyright (c) Status Research & Development GmbH
# Licensed under either of Apache License, version 2.0, or MIT license.
import ../chronos
import stew/byteutils
import ../chronos/osdefs
import ../chronos/unittest2/asynctests

{.used.}

proc ignorePacket(t: DatagramTransport, data: openArray[byte],
                  remote: TransportAddress, error: OSErrorCode) {.gcsafe.} =
  discard

proc packet(data: var string, remote: TransportAddress,
            buffer: var DatagramBuffer): DatagramOut =
  buffer = DatagramBuffer(base: (if data.len == 0: nil else: addr data[0]),
                          len: csize_t(data.len))
  DatagramOut(remote: remote,
    buffers: cast[ptr UncheckedArray[DatagramBuffer]](addr buffer), bufferCount: 1)

suite "Direct datagram transport":
  setup:
    let counters = getTrackerCounters()
  teardown:
    checkLeaks(counters)

  asyncTest "bounded draining preserves payloads and empty datagrams":
    var
      received: seq[seq[byte]]
      turns: seq[int]
      last = 0
    let done = newFuture[void]()
    proc receive(t: DatagramTransport, data: openArray[byte],
                 remote: TransportAddress, error: OSErrorCode) {.gcsafe.} =
      doAssert error == OSErrorCode(0)
      received.add(@data)
    proc drained(t: DatagramTransport) {.gcsafe.} =
      turns.add(received.len - last)
      last = received.len
      if received.len == 5:
        done.complete()
    let
      receiver = newDatagramTransportSync(receive,
        local = initTAddress("127.0.0.1:0"), onDrain = drained, maxDatagrams = 2)
      sender = newDatagramTransportSync(ignorePacket,
        local = initTAddress("127.0.0.1:0"))
    var
      contents = ["one", "", "three", "four", "five"]
      buffers: array[5, DatagramBuffer]
      packets: array[5, DatagramOut]
    for i in 0 ..< packets.len:
      packets[i] = packet(contents[i], receiver.localAddress(), buffers[i])
    check sender.trySendBatch(packets).sent == 5
    await done.wait(2.seconds)
    check received == @["one".toBytes(), @[], "three".toBytes(), "four".toBytes(), "five".toBytes()]
    # Packet arrival can split a turn before the receive budget is exhausted.
    for count in turns:
      check count <= 2
    await sender.closeWait()
    await receiver.closeWait()

  asyncTest "close inside receive stops draining and suppresses onDrain":
    var received, drained: int
    proc receive(t: DatagramTransport, data: openArray[byte],
                 remote: TransportAddress, error: OSErrorCode) {.gcsafe.} =
      inc received
      t.close()
    proc onDrain(t: DatagramTransport) {.gcsafe.} =
      inc drained
    let
      receiver = newDatagramTransportSync(receive,
        local = initTAddress("127.0.0.1:0"), onDrain = onDrain)
      sender = newDatagramTransportSync(ignorePacket,
        local = initTAddress("127.0.0.1:0"))
    var
      data = "packet"
      buffer: DatagramBuffer
      message = packet(data, receiver.localAddress(), buffer)
    check sender.trySendBatch([message, message]).sent == 2
    await receiver.join().wait(2.seconds)
    check received == 1
    check drained == 0
    await sender.closeWait()

  asyncTest "scatter gather and batches spanning syscall limits":
    var received = 0
    let done = newFuture[void]()
    proc receive(t: DatagramTransport, data: openArray[byte],
                 remote: TransportAddress, error: OSErrorCode) {.gcsafe.} =
      doAssert error == OSErrorCode(0)
      doAssert @data == "abc".toBytes()
      inc received
      if received == 65:
        done.complete()
    let
      receiver = newDatagramTransportSync(receive,
        local = initTAddress("127.0.0.1:0"))
      sender = newDatagramTransportSync(ignorePacket,
        local = initTAddress("127.0.0.1:0"))
    var
      first = "a"
      second = "bc"
      buffers = [DatagramBuffer(base: addr first[0], len: 1),
                 DatagramBuffer(base: addr second[0], len: 2)]
      packets: array[65, DatagramOut]
    for message in packets.mitems():
      message = DatagramOut(remote: receiver.localAddress(),
        buffers: cast[ptr UncheckedArray[DatagramBuffer]](addr buffers[0]),
        bufferCount: 2)
    let sent = sender.trySendBatch(packets)
    check sent.sent == 65
    check sent.error == OSErrorCode(0)
    await done.wait(2.seconds)
    await sender.closeWait()
    await receiver.closeWait()

  asyncTest "partial sends retain the successful prefix":
    let sender = newDatagramTransportSync(ignorePacket,
      local = initTAddress("127.0.0.1:0"))
    var
      data = "hello"
      oversized = newString(65536)
      buffer, oversizedBuffer: DatagramBuffer
      valid = packet(data, initTAddress("127.0.0.1:9"), buffer)
      invalid = packet(oversized, valid.remote, oversizedBuffer)
    # Address-family mismatches are accepted on some platforms. A payload
    # larger than the UDP length field must fail on every backend.
    let partial = sender.trySendBatch([valid, invalid])
    check partial.sent == 1
    # Linux sendmmsg cannot report the error following a successful prefix.
    let expectedError =
      when defined(windows): WSAEMSGSIZE
      else: EMSGSIZE
    when not defined(linux):
      check partial.error == expectedError
    let failed = sender.trySendBatch([invalid])
    check failed.sent == 0
    check failed.error == expectedError
    await sender.closeWait()
    check sender.trySendBatch([valid]).error != OSErrorCode(0)
    check sender.trySendBatch([]).sent == 0

  asyncTest "truncation preserves the sender and reception continues":
    for local in [initTAddress("127.0.0.1:0"), initTAddress("[::1]:0")]:
      let done = newFuture[void]()
      var
        expectedRemote: TransportAddress
        received = 0
      proc receive(t: DatagramTransport, data: openArray[byte],
                   remote: TransportAddress, error: OSErrorCode) {.gcsafe.} =
        doAssert remote == expectedRemote
        doAssert received < 4
        if received mod 2 == 0:
          when defined(windows):
            doAssert error == WSAEMSGSIZE, $int(error)
          else:
            doAssert error == EMSGSIZE
          doAssert data.len == 0
        else:
          doAssert error == OSErrorCode(0)
          doAssert @data == "ok".toBytes()
        inc received
        if received == 4:
          done.complete()
      let
        receiver = newDatagramTransportSync(receive, local = local, bufSize = 2)
        sender = newDatagramTransportSync(ignorePacket, local = local)
      expectedRemote = sender.localAddress()
      var
        oversized = "too large"
        valid = "ok"
        oversizedBuffer, validBuffer: DatagramBuffer
        messages = [
          packet(oversized, receiver.localAddress(), oversizedBuffer),
          packet(valid, receiver.localAddress(), validBuffer)]
      # Exercise both the pending receive and truncation during draining.
      check sender.trySendBatch(
        [messages[0], messages[1], messages[0], messages[1]]).sent == 4
      await done.wait(2.seconds)
      check received == 4
      await sender.closeWait()
      await receiver.closeWait()

  asyncTest "dual stack normalizes IPv4 peers and sends replies":
    let done = newFuture[void]()
    proc receive(t: DatagramTransport, data: openArray[byte],
                 remote: TransportAddress, error: OSErrorCode) {.gcsafe.} =
      doAssert error == OSErrorCode(0)
      doAssert remote.family == AddressFamily.IPv4
      var
        buffer = DatagramBuffer(base: unsafeAddr data[0], len: csize_t(data.len))
        message = DatagramOut(remote: remote,
          buffers: cast[ptr UncheckedArray[DatagramBuffer]](addr buffer), bufferCount: 1)
      doAssert t.trySendBatch([message]).sent == 1
    proc reply(t: DatagramTransport, data: openArray[byte],
               remote: TransportAddress, error: OSErrorCode) {.gcsafe.} =
      doAssert error == OSErrorCode(0)
      doAssert @data == "hello".toBytes()
      done.complete()
    let
      receiver = newDatagramTransportSync(receive,
        local = initTAddress("[::]:0"), dualstack = DualStackType.Enabled)
      sender = newDatagramTransportSync(reply,
        local = initTAddress("127.0.0.1:0"))
    var
      data = "hello"
      buffer: DatagramBuffer
      dest = initTAddress("127.0.0.1:0")
    dest.port = receiver.localAddress().port
    let message = packet(data, dest, buffer)
    check sender.trySendBatch([message]).sent == 1
    await done.wait(2.seconds)
    await sender.closeWait()
    await receiver.closeWait()

  asyncTest "direct sends do not overtake queued sends":
    var received: seq[seq[byte]]
    let done = newFuture[void]()
    proc receive(t: DatagramTransport, data: openArray[byte],
                 remote: TransportAddress, error: OSErrorCode) {.gcsafe.} =
      doAssert error == OSErrorCode(0)
      received.add(@data)
      if received.len == 2:
        done.complete()
    let
      receiver = newDatagramTransportSync(receive,
        local = initTAddress("127.0.0.1:0"))
      sender = newDatagramTransportSync(ignorePacket,
        local = initTAddress("127.0.0.1:0"))
      queued = sender.sendTo(receiver.localAddress(), "queued")
    var
      data = "direct"
      buffer: DatagramBuffer
      message = packet(data, receiver.localAddress(), buffer)
    let blocked = sender.trySendBatch([message])
    check blocked.sent == 0
    check blocked.error != OSErrorCode(0)
    await queued
    message = packet(data, receiver.localAddress(), buffer)
    check sender.trySendBatch([message]).sent == 1
    await done.wait(2.seconds)
    check received == @["queued".toBytes(), "direct".toBytes()]
    await sender.closeWait()
    await receiver.closeWait()

proc nativePacket(data: var string, remote: TransportAddress,
                  storage: var Sockaddr_storage,
                  buffer: var DatagramBuffer): DatagramNativeOut =
  remote.toSAddr(storage, result.remoteLen)
  result.remote = addr storage
  buffer = DatagramBuffer(base: (if data.len == 0: nil else: addr data[0]),
                          len: csize_t(data.len))
  result.buffers = cast[ptr UncheckedArray[DatagramBuffer]](addr buffer)
  result.bufferCount = 1

suite "Native direct datagram transport":
  setup:
    let counters = getTrackerCounters()
  teardown:
    checkLeaks(counters)

  asyncTest "borrowed scatter gather batches preserve IPv4 and IPv6 payloads":
    for local in [initTAddress("127.0.0.1:0"), initTAddress("[::1]:0")]:
      var received = 0
      let done = newFuture[void]()
      proc receive(t: DatagramTransport, data: openArray[byte],
                   remote: TransportAddress, error: OSErrorCode) {.gcsafe.} =
        doAssert error == OSErrorCode(0)
        doAssert @data == (if received == 65: @[] else: "abc".toBytes())
        inc received
        if received == 66:
          done.complete()
      let receiver = newDatagramTransportSync(receive, local = local)
      let sender = newDatagramTransportSync(ignorePacket, local = local)
      var
        first = "a"
        second = "bc"
        storage: Sockaddr_storage
        length: SockLen
        buffers = [DatagramBuffer(base: addr first[0], len: 1),
                   DatagramBuffer(base: addr second[0], len: 2)]
        messages: array[66, DatagramNativeOut]
      receiver.localAddress().toSAddr(storage, length)
      for message in messages.mitems():
        message = DatagramNativeOut(remote: addr storage, remoteLen: length,
          buffers: cast[ptr UncheckedArray[DatagramBuffer]](addr buffers[0]),
          bufferCount: 2)
      messages[65].bufferCount = 0
      let sent = sender.trySendNativeBatch(messages)
      check sent.sent == 66
      check sent.error == OSErrorCode(0)
      # The call borrows these values only until it returns.
      first[0] = 'x'
      second[0] = 'x'
      zeroMem(addr storage, sizeof(storage))
      await done.wait(2.seconds)
      await sender.closeWait()
      await receiver.closeWait()

  asyncTest "invalid native addresses preserve the accepted prefix":
    let sender = newDatagramTransportSync(ignorePacket,
      local = initTAddress("127.0.0.1:0"))
    var
      data = "ok"
      buffer: DatagramBuffer
      storage, unsupported: Sockaddr_storage
      valid = nativePacket(data, initTAddress("127.0.0.1:9"), storage, buffer)
    let expected =
      when defined(windows): WSAEINVAL
      else: EINVAL
    for kind in 0 .. 4:
      var invalid = valid
      case kind
      of 0: invalid.remote = nil
      of 1: invalid.remoteLen = SockLen(0)
      of 2: invalid.remoteLen = SockLen(sizeof(Sockaddr_storage) + 1)
      of 3: invalid.remoteLen = SockLen(sizeof(Sockaddr_in6))
      else: invalid.remote = addr unsupported
      let partial = sender.trySendNativeBatch([valid, invalid, valid])
      check partial.sent == 1
      check partial.error == expected
      let failed = sender.trySendNativeBatch([invalid])
      check failed.sent == 0
      check failed.error == expected
    await sender.closeWait()
    check sender.trySendNativeBatch([valid]).error != OSErrorCode(0)
    check sender.trySendNativeBatch([]).sent == 0

  asyncTest "native oversized sends retain the successful prefix":
    let sender = newDatagramTransportSync(ignorePacket,
      local = initTAddress("127.0.0.1:0"))
    var
      data = "ok"
      oversized = newString(65536)
      buffer, largeBuffer: DatagramBuffer
      storage, largeStorage: Sockaddr_storage
      valid = nativePacket(data, initTAddress("127.0.0.1:9"), storage, buffer)
      invalid = nativePacket(oversized, initTAddress("127.0.0.1:9"),
                             largeStorage, largeBuffer)
    check sender.trySendNativeBatch([valid, invalid]).sent == 1
    let expected =
      when defined(windows): WSAEMSGSIZE
      else: EMSGSIZE
    let failed = sender.trySendNativeBatch([invalid])
    check failed.sent == 0
    check failed.error == expected
    await sender.closeWait()

  asyncTest "native sends wait for the async queue":
    var received: seq[seq[byte]]
    let done = newFuture[void]()
    proc receive(t: DatagramTransport, data: openArray[byte],
                 remote: TransportAddress, error: OSErrorCode) {.gcsafe.} =
      doAssert error == OSErrorCode(0)
      received.add(@data)
      if received.len == 2:
        done.complete()
    let receiver = newDatagramTransportSync(receive,
      local = initTAddress("127.0.0.1:0"))
    let sender = newDatagramTransportSync(ignorePacket,
      local = initTAddress("127.0.0.1:0"))
    let queued = sender.sendTo(receiver.localAddress(), "queued")
    var
      data = "native"
      buffer: DatagramBuffer
      storage: Sockaddr_storage
      message = nativePacket(data, receiver.localAddress(), storage, buffer)
    let blocked = sender.trySendNativeBatch([message])
    check blocked.sent == 0
    check blocked.error != OSErrorCode(0)
    await queued
    message = nativePacket(data, receiver.localAddress(), storage, buffer)
    check sender.trySendNativeBatch([message]).sent == 1
    await done.wait(2.seconds)
    check received == @["queued".toBytes(), "native".toBytes()]
    await sender.closeWait()
    await receiver.closeWait()

  asyncTest "native IPv4 replies are mapped on dual stack sockets":
    let done = newFuture[void]()
    proc receive(t: DatagramTransport, data: openArray[byte],
                 remote: TransportAddress, error: OSErrorCode) {.gcsafe.} =
      doAssert error == OSErrorCode(0)
      doAssert remote.family == AddressFamily.IPv4
      var
        payload = "reply"
        storage: Sockaddr_storage
        buffer: DatagramBuffer
        message = nativePacket(payload, remote, storage, buffer)
      let original = storage
      doAssert t.trySendNativeBatch([message]).sent == 1
      doAssert equalMem(addr storage, unsafeAddr original, sizeof(storage))
    proc reply(t: DatagramTransport, data: openArray[byte],
               remote: TransportAddress, error: OSErrorCode) {.gcsafe.} =
      doAssert error == OSErrorCode(0)
      doAssert @data == "reply".toBytes()
      done.complete()
    let receiver = newDatagramTransportSync(receive,
      local = initTAddress("[::]:0"), dualstack = DualStackType.Enabled)
    let sender = newDatagramTransportSync(reply, local = initTAddress("127.0.0.1:0"))
    var
      data = "hello"
      storage: Sockaddr_storage
      buffer: DatagramBuffer
      dest = initTAddress("127.0.0.1:0")
    dest.port = receiver.localAddress().port
    var message = nativePacket(data, dest, storage, buffer)
    check sender.trySendNativeBatch([message]).sent == 1
    await done.wait(2.seconds)
    await sender.closeWait()
    await receiver.closeWait()

  asyncTest "native wildcard destinations use platform normalization":
    for local in [initTAddress("127.0.0.1:0"), initTAddress("[::1]:0")]:
      let done = newFuture[void]()
      proc receive(t: DatagramTransport, data: openArray[byte],
                   remote: TransportAddress, error: OSErrorCode) {.gcsafe.} =
        doAssert error == OSErrorCode(0)
        doAssert @data == "ok".toBytes()
        done.complete()
      let receiver = newDatagramTransportSync(receive, local = local)
      let sender = newDatagramTransportSync(ignorePacket, local = local)
      var
        dest = if local.family == AddressFamily.IPv4: AnyAddress else: AnyAddress6
        storage: Sockaddr_storage
        buffer: DatagramBuffer
        data = "ok"
      dest.port = receiver.localAddress().port
      var message = nativePacket(data, dest, storage, buffer)
      check sender.trySendNativeBatch([message]).sent == 1
      await done.wait(2.seconds)
      await sender.closeWait()
      await receiver.closeWait()

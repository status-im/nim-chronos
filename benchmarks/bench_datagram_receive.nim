# Copyright (c) Status Research & Development GmbH
# Licensed under either of Apache License, version 2.0, or MIT license.
# Compare receive delivery with identical direct sends and bounded bursts.
import ../chronos
import ../chronos/osdefs

const
  BurstSize = 64
  Rounds = 2000

proc run(sync: bool) {.async.} =
  var received, callbacks: int
  let ready = newAsyncEvent()
  proc receive(t: DatagramTransport, data: openArray[byte],
               remote: TransportAddress, error: OSErrorCode) {.gcsafe.} =
    doAssert error == OSErrorCode(0)
    doAssert data.len == 1200
    inc received
    if received mod BurstSize == 0:
      ready.fire()
  proc drained(t: DatagramTransport) {.gcsafe.} =
    inc callbacks
  proc receiveAsync(t: DatagramTransport,
                    remote: TransportAddress) {.async: (raises: []).} =
    try:
      let data = t.getMessage()
      inc callbacks
      receive(t, data, remote, OSErrorCode(0))
    except TransportError as exc:
      raiseAssert exc.msg
  proc ignore(t: DatagramTransport, data: openArray[byte],
              remote: TransportAddress, error: OSErrorCode) {.gcsafe.} =
    discard
  let
    receiver =
      if sync:
        newDatagramTransportSync(receive, local = initTAddress("127.0.0.1:0"),
                                  onDrain = drained)
      else:
        newDatagramTransport(receiveAsync, local = initTAddress("127.0.0.1:0"))
    sender = newDatagramTransportSync(ignore, local = initTAddress("127.0.0.1:0"))
    remote = receiver.localAddress()
    start = Moment.now()
  for round in 0 ..< Rounds:
    # Rebuild borrowed descriptors after each await; never retain stack addresses.
    var
      payload: array[1200, byte]
      buffer = DatagramBuffer(base: addr payload[0], len: payload.len.csize_t)
      packets: array[BurstSize, DatagramOut]
    for packet in packets.mitems():
      packet = DatagramOut(remote: remote,
        buffers: cast[ptr UncheckedArray[DatagramBuffer]](addr buffer), bufferCount: 1)
    doAssert sender.trySendBatch(packets).sent == BurstSize
    await ready.wait().wait(5.seconds)
    ready.clear()
  let elapsed = Moment.now() - start
  echo (if sync: "sync" else: "async"), ": ", received, " packets in ",
       elapsed, "; receive turns: ", callbacks
  await sender.closeWait()
  await receiver.closeWait()

waitFor run(false)
waitFor run(true)

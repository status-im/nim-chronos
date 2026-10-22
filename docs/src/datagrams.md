# Direct datagram I/O

`newDatagramTransportSync` is intended for consumers such as QUIC engines that
process incoming packets immediately and already own their outgoing queues. The
existing `newDatagramTransport` asynchronous callback API remains available.

The synchronous receive callback gets a borrowed `openArray[byte]`, the remote
address, and an `OSErrorCode`. Data is valid only until the callback returns;
copy it before retaining it or starting asynchronous work. A zero error denotes
a packet, including a valid zero-length UDP packet. A nonzero error carries no
payload. Truncated packets are discarded and reported as `EMSGSIZE`
(`WSAEMSGSIZE` on Windows).

Chronos makes at most `maxDatagrams` receive attempts per turn (64 by default),
then calls the optional `onDrain` callback. This lets an engine process a group
of packets before producing output. Closing the transport during packet delivery
stops draining and suppresses `onDrain`. Callbacks must not block. Windows drains
only between completion of an overlapped receive and posting the next one.

`trySendBatch` takes borrowed `DatagramOut` descriptors. Each descriptor specifies
one destination and a pointer/count pair of `DatagramBuffer` payload fragments.
All descriptors and payloads must remain valid until the call returns. No payload
is copied into a queue and no Future is created. A fragment of length zero can be
used to send an empty datagram.

The result's `sent` field counts whole packets accepted by the OS, not delivered
to peers. Only the unsent suffix may be retried. `error` describes a known failure
at the first unsent packet. Linux `sendmmsg` can return a successful prefix without
revealing the reason it stopped; in this case `error` is zero. A short result is
therefore not necessarily would-block. A subsequent attempt can expose the error.

Would-block is reported as `EAGAIN`/`EWOULDBLOCK` (`WSAEWOULDBLOCK` on Windows).
Direct sends also return would-block while asynchronous sends are queued, so they
cannot overtake that queue. The caller retains unsent packets and schedules its
own retry; this API does not install a writable callback. Linux uses `sendmmsg`,
other POSIX platforms use `sendmsg`, and Windows uses non-overlapped `WSASendTo`.

This API does not yet expose packet-info, destination-interface or ECN metadata.
`localAddress` remains the socket's bound address, which may be a wildcard.

Run `nim c -d:release -r benchmarks/bench_datagram_receive.nim` to compare the two
receive paths using identical direct sends and bursts of 64 packets. The benchmark
includes loopback socket and sender costs; it is not a QUIC throughput benchmark.

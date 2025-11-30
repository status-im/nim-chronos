#
#          Chronos Asynchronous TLS Stream
#             (c) Copyright 2019-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

## This module implements Transport Layer Security (TLS) stream. This module
## uses sources of BearSSL <https://www.bearssl.org> by Thomas Pornin.
##
## The stream implementation is safe only for self-terminating protocols (like
## HTTP), ie those that don't require `close_notifiy` error detection.
##
## See https://www.rfc-editor.org/rfc/rfc5246.html#section-7.2.1
##
## TODO implement full duplex close or upgrade to TLS 1.3 that supports half-
## duplex close.

{.push raises: [].}

import stew/ptrops
import
  bearssl/[brssl, ec, errors, pem, rsa, ssl, x509],
  bearssl/certs/cacert
import ../[asyncloop, asyncsync, config]
import ./asyncstream, ../transports/[stream, common]

export asyncloop, asyncsync, asyncstream

const
  TLSSessionCacheBufferSize* = chronosTLSSessionCacheBufferSize

type
  TLSStreamKind {.pure.} = enum
    Client, Server

  TLSVersion* {.pure.} = enum
    TLS10 = 0x0301, TLS11 = 0x0302, TLS12 = 0x0303

  TLSFlags* {.pure.} = enum
    NoVerifyHost,         # Client: Skip remote certificate check
    NoVerifyServerName,   # Client: Skip Server Name Indication (SNI) check
    EnforceServerPref,    # Server: Enforce server preferences
    NoRenegotiation,      # Server: Reject renegotiations requests
    TolerateNoClientAuth, # Server: Disable strict client authentication
    FailOnAlpnMismatch    # Server: Fail on application protocol mismatch

  TLSKeyType {.pure.} = enum
    RSA, EC

  TLSPrivateKey* = ref object
    case kind: TLSKeyType
    of RSA:
      rsakey: RsaPrivateKey
    of EC:
      eckey: EcPrivateKey
    storage: seq[byte]

  TLSCertificate* = ref object
    certs: seq[X509Certificate]
    storage: seq[byte]

  TLSSessionCache* = ref object
    storage: seq[byte]
    context: SslSessionCacheLru

  PEMElement* = object
    name*: string
    data*: seq[byte]

  PEMContext = ref object
    data: seq[byte]

  TrustAnchorStore* = ref object
    anchors: seq[X509TrustAnchor]

  TLSStreamWriter* = ref object of AsyncStreamWriter
    stream*: TLSAsyncStream
    lock: AsyncLock
      # Lock needed to order writes as they are sent to the next layer

  TLSStreamReader* = ref object of AsyncStreamReader
    case kind: TLSStreamKind
    of TLSStreamKind.Client:
      ccontext: ptr SslClientContext
    of TLSStreamKind.Server:
      scontext: ptr SslServerContext
    stream*: TLSAsyncStream

  TLSAsyncStream* = ref object of RootRef
    xwc*: X509NoanchorContext

    case kind*: TLSStreamKind
    of TLSStreamKind.Client:
      ccontext*: SslClientContext
    of TLSStreamKind.Server:
      scontext*: SslServerContext

    sbuffer*: seq[byte]
    x509*: X509MinimalContext
    reader*: TLSStreamReader
    writer*: TLSStreamWriter
    lock: AsyncLock
    handshaked*: bool
    eof: bool
    trustAnchors: TrustAnchorStore
    clientCertificate: TLSCertificate
    clientPrivateKey: TLSPrivateKey

    readFut*: Future[int].Raising([CancelledError, AsyncStreamError])

  SomeTLSStreamType* = TLSStreamReader|TLSStreamWriter|TLSAsyncStream
  SomeTrustAnchorType* = TrustAnchorStore | openArray[X509TrustAnchor]

  TLSStreamError* = object of AsyncStreamError
  TLSStreamHandshakeError* = object of TLSStreamError
  TLSStreamInitError* = object of TLSStreamError
  TLSStreamReadError* = object of TLSStreamError
  TLSStreamWriteError* = object of TLSStreamError
  TLSStreamProtocolError* = object of TLSStreamError
    errCode*: int

template rsource(s: TLSAsyncStream): AsyncStreamReader =
  s.reader.rsource

template wsource(s: TLSAsyncStream): AsyncStreamWriter =
  s.writer.wsource

template engine(s: TLSAsyncStream): ptr SslEngineContext =
  case s.kind
  of TLSStreamKind.Server:
    addr s.scontext.eng
  of TLSStreamKind.Client:
    addr s.ccontext.eng

template engine(s: TLSStreamReader|TLSStreamWriter): ptr SslEngineContext =
  s.stream.engine()

proc newTLSStreamWriteError(p: ref AsyncStreamError): ref TLSStreamWriteError {.
     noinline.} =
  var w = newException(TLSStreamWriteError, "Write stream failed")
  w.msg = w.msg & ", originated from [" & $p.name & "] " & p.msg
  w.parent = p
  w

template newTLSStreamProtocolImpl[T](message: T): ref TLSStreamProtocolError =
  var msg = ""
  var code = 0
  when T is string:
    msg.add(message)
  elif T is cint:
    msg.add(sslErrorMsg(message) & " (code: " & $int(message) & ")")
    code = int(message)
  elif T is int:
    msg.add(sslErrorMsg(message) & " (code: " & $message & ")")
    code = message
  else:
    msg.add("Internal Error")
  var err = newException(TLSStreamProtocolError, msg)
  err.errCode = code
  err

template newTLSUnexpectedProtocolError(): ref TLSStreamProtocolError =
  newException(TLSStreamProtocolError, "Unexpected internal error")

proc newTLSStreamProtocolError[T](message: T): ref TLSStreamProtocolError =
  newTLSStreamProtocolImpl(message)

proc raiseTLSStreamProtocolError[T](message: T) {.
     noreturn, noinline, raises: [TLSStreamProtocolError].} =
  raise newTLSStreamProtocolImpl(message)

proc new*(T: typedesc[TrustAnchorStore],
          anchors: openArray[X509TrustAnchor]): TrustAnchorStore =
  var res: seq[X509TrustAnchor]
  for anchor in anchors:
    res.add(anchor)
    doAssert(unsafeAddr(anchor) != unsafeAddr(res[^1]),
             "Anchors should be copied")
  TrustAnchorStore(anchors: res)

proc dumpState*(state: cuint): string =
  var res = ""
  if (state and SSL_CLOSED) == SSL_CLOSED:
    if len(res) > 0: res.add(", ")
    res.add("SSL_CLOSED")
  if (state and SSL_SENDREC) == SSL_SENDREC:
    if len(res) > 0: res.add(", ")
    res.add("SSL_SENDREC")
  if (state and SSL_SENDAPP) == SSL_SENDAPP:
    if len(res) > 0: res.add(", ")
    res.add("SSL_SENDAPP")
  if (state and SSL_RECVREC) == SSL_RECVREC:
    if len(res) > 0: res.add(", ")
    res.add("SSL_RECVREC")
  if (state and SSL_RECVAPP) == SSL_RECVAPP:
    if len(res) > 0: res.add(", ")
    res.add("SSL_RECVAPP")
  "{" & res & "}"

proc runUntil(rws: TLSAsyncStream, target: cuint): Future[void] {.
     async: (raises: [CancelledError, AsyncStreamError]).} =
  var offset = 0
  let engine = rws.engine()
  while true:
    let err = sslEngineLastError(engine[])
    if err != 0:
      raise newTLSStreamProtocolError(err)

    let state = sslEngineCurrentState(engine[])
    if (state and SSL_CLOSED) == SSL_CLOSED:
      break

    if ((state and target) == target):
      if (state and SSL_SENDAPP) == SSL_SENDAPP:
        rws.handshaked = true
      break

    # Prevent concurrent reads and writes from interfering with each other
    await rws.lock.acquire()
    try:
      # If the engine is ready for reading, start a read operation - although
      # we start reading here, it's important to exhaust SSL_SENDREC before
      # blocking on reads or the protocol will deadlock during handshakes
      if (state and SSL_RECVREC) == SSL_RECVREC and rws.readFut.isNil:
        if rws.eof: # We've already read EOF from the underlying stream
          break

        var length = 0'u
        var buf = sslEngineRecvrecBuf(engine[], length)
        rws.readFut = rws.rsource.readOnce(buf, int(length))

      if (state and SSL_SENDREC) == SSL_SENDREC:
        var length = 0'u
        var buf = sslEngineSendrecBuf(engine[], length)
        doAssert(length != 0 and not isNil(buf))
        # TODO we could process readFut concurrently here - keep it simple for
        #      now
        await rws.wsource.write(buf, int(length))
        sslEngineSendrecAck(engine[], length)

      elif (state and SSL_RECVREC) == SSL_RECVREC:
        let res = await rws.readFut
        rws.readFut = nil
        if res == 0:
          rws.eof = true
        else:
          sslEngineRecvrecAck(engine[], uint(res))
    except CancelledError as exc:
      # Typically this will happen during close but can also occur if user
      # cancels a read/write in which case the stream is broken (ie we don't
      # attempt recovery / resumption)
      if rws.reader.state == AsyncStreamState.Running:
        rws.reader.state = AsyncStreamState.Stopped
      if rws.writer.state == AsyncStreamState.Running:
        rws.writer.state = AsyncStreamState.Stopped

      if not rws.readFut.isNil:
        let readFut = move(rws.readFut)
        await readFut.cancelAndWait()
      raise exc
    except AsyncStreamError as exc:
      rws.reader.state = AsyncStreamState.Error
      rws.reader.error = exc
      rws.writer.state = AsyncStreamState.Error
      rws.writer.error = exc
      if not rws.readFut.isNil:
        let readFut = move(rws.readFut)
        await readFut.cancelAndWait()
      raise exc
    finally:
      try:
        rws.lock.release()
      except AsyncLockError:
        raiseAssert "just checked"

proc handshake*(rws: TLSAsyncStream): Future[void] {.
     async: (raises: [CancelledError, AsyncStreamError]).} =
  ## Wait until initial TLS handshake has been successfully performed - if this
  ## function is not called, errors will be reported on the first read or write.
  if rws.handshaked:
    return

  await rws.runUntil(SSL_SENDAPP)

  if rws.eof:
    raiseAsyncStreamWriteEOFError()

proc readOnce*(
    rstream: TLSStreamReader, pbytes: pointer, nbytes: int
): Future[int] {.async: (raises: [CancelledError, AsyncStreamError]).} =
  let engine = rstream.engine()

  while true:
    let state = sslEngineCurrentState(engine[])

    if (state and SSL_RECVAPP) == SSL_RECVAPP:
      # Unencrypted data is available from the engine - copy as much as possible
      # to the user buffer
      var length = 0'u
      var buf = sslEngineRecvappBuf(engine[], length)
      let n = min(nbytes.uint, length)
      copyMem(pbytes, buf, n)
      sslEngineRecvappAck(engine[], n)
      return n.int

    if rstream.stream.eof:
      if rstream.state == AsyncStreamState.Running:
        rstream.state = AsyncStreamState.Finished
      return 0

    # Wait for data to arrive on the network - this might involve both sending
    # and receiving
    await rstream.stream.runUntil(SSL_RECVAPP)

proc close(s: TLSStreamReader) {.async: (raises: []).} =
  # Cancel reads only if both directions are being closed
  if not s.stream.readFut.isNil and s.stream.writer.closed():
    let readFut = move(s.stream.readFut)
    await readFut.cancelAndWait()

proc write*(
    wstream: TLSStreamWriter, pbytes: pointer, nbytes: int
) {.async: (raises: [CancelledError, AsyncStreamError]).} =
  let engine = wstream.engine()

  # Prevent concurrent writes from being interleaved on the wire
  await wstream.lock.acquire()
  defer:
    try:
      wstream.lock.release()
    except AsyncLockError:
      raiseAssert ""

  var offset = 0
  while offset < nbytes:
    if wstream.stream.eof:
      if wstream.state == AsyncStreamState.Running:
        wstream.state = AsyncStreamState.Finished
      raiseAsyncStreamWriteEOFError()

    let state = sslEngineCurrentState(engine[])

    if (state and SSL_SENDAPP) == SSL_SENDAPP:
      # Application data can be queued for encryption
      var length = 0'u
      var buf = sslEngineSendappBuf(engine[], length)
      let toWrite = min(int(length), nbytes - offset)
      copyMem(buf, pbytes.offset(offset), toWrite)
      offset += toWrite
      sslEngineSendappAck(engine[], uint(toWrite))

      if offset == nbytes:
        # Flushing is necessary for writes that only partially fill an SSL
        # record
        sslEngineFlush(engine[], 0)

    # Write encrypted data to underlying stream
    await wstream.stream.runUntil(SSL_SENDAPP)

proc close(s: TLSStreamWriter) {.async: (raises: []).} =
  # Cancel reads only if both directions are being closed
  if not s.stream.readFut.isNil and s.stream.reader.closed():
    let readFut = move(s.stream.readFut)
    await readFut.cancelAndWait()

proc getSignerAlgo(xc: X509Certificate): int =
  ## Get certificate's signing algorithm.
  var dc: X509DecoderContext
  x509DecoderInit(dc, nil, nil)
  x509DecoderPush(dc, xc.data, xc.dataLen)
  let err = x509DecoderLastError(dc)
  if err != 0:
    -1
  else:
    int(x509DecoderGetSignerKeyType(dc))

proc initReaderVtbl(bufferSize: int): AsyncStreamReaderVtbl =
  proc readOnceImpl(
      rstream: AsyncStreamReader, pbytes: pointer, nbytes: int
  ): Future[int] {.async: (raises: [CancelledError, AsyncStreamError], raw: true).} =
    TLSStreamReader(rstream).readOnce(pbytes, nbytes)

  proc closeImpl(rstream: AsyncStreamReader) {.async: (raises: [], raw: true).} =
    TLSStreamReader(rstream).close()

  var res = AsyncStreamReaderVtbl.initSimpleVtbl(readOnceImpl, bufferSize)
  res.close = closeImpl
  res

proc initWriterVtbl(): AsyncStreamWriterVtbl =
  proc writeImpl(
      wstream: AsyncStreamWriter, pbytes: pointer, nbytes: int
  ) {.async: (raises: [CancelledError, AsyncStreamError], raw: true).} =
    TLSStreamWriter(wstream).write(pbytes, nbytes)

  proc closeImpl(wstream: AsyncStreamWriter) {.async: (raises: [], raw: true).} =
    TLSStreamWriter(wstream).close()

  var res = AsyncStreamWriterVtbl.initSimpleVtbl(writeImpl)
  res.close = closeImpl
  res

proc newTLSClientAsyncStream*(
       rsource: AsyncStreamReader,
       wsource: AsyncStreamWriter,
       serverName: string,
       bufferSize = SSL_BUFSIZE_BIDI,
       minVersion = TLSVersion.TLS12,
       maxVersion = TLSVersion.TLS12,
       flags: set[TLSFlags] = {},
       trustAnchors: SomeTrustAnchorType = MozillaTrustAnchors,
       certificate: TLSCertificate = nil,
       privateKey: TLSPrivateKey = nil
     ): TLSAsyncStream {.raises: [TLSStreamInitError].} =
  ## Create new TLS asynchronous stream for outbound (client) connections
  ## using reading stream ``rsource`` and writing stream ``wsource``.
  ##
  ## You can specify remote server name using ``serverName``, if while
  ## handshake server reports different name you will get an error. If
  ## ``serverName`` is empty string, remote server name checking will be
  ## disabled.
  ##
  ## ``bufferSize`` - is SSL/TLS buffer which is used for encoding/decoding
  ## incoming data.
  ##
  ## ``minVersion`` and ``maxVersion`` are TLS versions which will be used
  ## for handshake with remote server. If server's version will be lower then
  ## ``minVersion`` of bigger then ``maxVersion`` you will get an error.
  ##
  ## ``flags`` - custom TLS connection flags.
  ##
  ## ``trustAnchors`` - use this if you want to use certificate trust
  ## anchors other than the default Mozilla trust anchors. If you pass
  ## a ``TrustAnchorStore`` you should reuse the same instance for
  ## every call to avoid making a copy of the trust anchors per call.
  ##
  ## ``certificate`` and ``privateKey`` - if both are provided, the client
  ## will use them for client certificate authentication when the server
  ## requests it.
  when trustAnchors is TrustAnchorStore:
    doAssert(len(trustAnchors.anchors) > 0,
             "Empty trust anchor list is invalid")
  else:
    doAssert(len(trustAnchors) > 0, "Empty trust anchor list is invalid")
  var res = TLSAsyncStream(kind: TLSStreamKind.Client, lock: newAsyncLock())
  var reader = TLSStreamReader(
    stream: res,
    rsource: rsource,
    tsource: rsource.tsource,
  )
  var writer = TLSStreamWriter(
    stream: res,
    lock: newAsyncLock(),
    wsource: wsource,
    tsource: wsource.tsource,
  )
  res.reader = reader
  res.writer = writer

  if TLSFlags.NoVerifyHost in flags:
    sslClientInitFull(res.ccontext, addr res.x509, nil, 0)
    x509NoanchorInit(res.xwc,
                     X509ClassPointerConst(addr res.x509.vtable))
    sslEngineSetX509(res.ccontext.eng,
                     X509ClassPointerConst(addr res.xwc.vtable))
  else:
    when trustAnchors is TrustAnchorStore:
      res.trustAnchors = trustAnchors
      sslClientInitFull(res.ccontext, addr res.x509,
                        unsafeAddr trustAnchors.anchors[0],
                        uint(len(trustAnchors.anchors)))
    else:
      sslClientInitFull(res.ccontext, addr res.x509,
                        unsafeAddr trustAnchors[0],
                        uint(len(trustAnchors)))

  let size = max(SSL_BUFSIZE_BIDI, bufferSize)
  res.sbuffer = newSeq[byte](size)
  sslEngineSetBuffer(res.ccontext.eng, addr res.sbuffer[0],
                     uint(len(res.sbuffer)), 1)
  sslEngineSetVersions(res.ccontext.eng, uint16(minVersion),
                       uint16(maxVersion))

  if not isNil(certificate) xor not isNil(privateKey):
    raise newException(TLSStreamInitError,
      "Both certificate and privateKey must be provided for client " &
      "certificate authentication")

  if not isNil(certificate) and not isNil(privateKey):
    if len(certificate.certs) == 0:
      raise newException(TLSStreamInitError, "Incorrect client certificate")
    res.clientCertificate = certificate
    res.clientPrivateKey = privateKey
    let algo = getSignerAlgo(res.clientCertificate.certs[0])
    if algo == -1:
      raise newException(TLSStreamInitError,
                         "Could not decode client certificate")
    case privateKey.kind
    of TLSKeyType.RSA:
      sslClientSetSingleRsa(res.ccontext,
                            addr res.clientCertificate.certs[0],
                            len(res.clientCertificate.certs),
                            addr res.clientPrivateKey.rsakey,
                            rsaPkcs1SignGetDefault())
    of TLSKeyType.EC:
      sslClientSetSingleEc(res.ccontext,
                           addr res.clientCertificate.certs[0],
                           len(res.clientCertificate.certs),
                           addr res.clientPrivateKey.eckey,
                           cuint(KEYTYPE_SIGN or KEYTYPE_KEYX),
                           cuint(algo), ecGetDefault(),
                           ecdsaSignAsn1GetDefault())

  if TLSFlags.NoVerifyServerName in flags:
    let err = sslClientReset(res.ccontext, nil, 0)
    if err == 0:
      raise newException(TLSStreamInitError, "Could not initialize TLS layer")
  else:
    if len(serverName) == 0:
      raise newException(TLSStreamInitError,
                         "serverName must not be empty string")

    let err = sslClientReset(res.ccontext, serverName, 0)
    if err == 0:
      raise newException(TLSStreamInitError, "Could not initialize TLS layer")

  block:
    let vtbl = initWriterVtbl()
    init(AsyncStreamWriter(res.writer), vtbl)
  block:
    let vtbl = initReaderVtbl(bufferSize)
    init(AsyncStreamReader(res.reader),vtbl)
  res

proc newTLSServerAsyncStream*(rsource: AsyncStreamReader,
                              wsource: AsyncStreamWriter,
                              privateKey: TLSPrivateKey,
                              certificate: TLSCertificate,
                              bufferSize = SSL_BUFSIZE_BIDI,
                              minVersion = TLSVersion.TLS11,
                              maxVersion = TLSVersion.TLS12,
                              cache: TLSSessionCache = nil,
                              flags: set[TLSFlags] = {}): TLSAsyncStream {.
     raises: [TLSStreamInitError, TLSStreamProtocolError].} =
  ## Create new TLS asynchronous stream for inbound (server) connections
  ## using reading stream ``rsource`` and writing stream ``wsource``.
  ##
  ## You need to specify local private key ``privateKey`` and certificate
  ## ``certificate``.
  ##
  ## ``bufferSize`` - is SSL/TLS buffer which is used for encoding/decoding
  ## incoming data.
  ##
  ## ``minVersion`` and ``maxVersion`` are TLS versions which will be used
  ## for handshake with remote server. If server's version will be lower then
  ## ``minVersion`` of bigger then ``maxVersion`` you will get an error.
  ##
  ## ``flags`` - custom TLS connection flags.
  if isNil(privateKey) or privateKey.kind notin {TLSKeyType.RSA, TLSKeyType.EC}:
    raiseTLSStreamProtocolError("Incorrect private key")
  if isNil(certificate) or len(certificate.certs) == 0:
    raiseTLSStreamProtocolError("Incorrect certificate")

  var res = TLSAsyncStream(kind: TLSStreamKind.Server, lock: newAsyncLock())
  var reader = TLSStreamReader(
    stream: res,
    rsource: rsource,
    tsource: rsource.tsource,
  )
  var writer = TLSStreamWriter(
    stream: res,
    lock: newAsyncLock(),
    wsource: wsource,
    tsource: wsource.tsource,
  )
  res.reader = reader
  res.writer = writer

  if privateKey.kind == TLSKeyType.EC:
    let algo = getSignerAlgo(certificate.certs[0])
    if algo == -1:
      raiseTLSStreamProtocolError("Could not decode certificate")
    sslServerInitFullEc(res.scontext, addr certificate.certs[0],
                        uint(len(certificate.certs)), cuint(algo),
                        addr privateKey.eckey)
  elif privateKey.kind == TLSKeyType.RSA:
    sslServerInitFullRsa(res.scontext, addr certificate.certs[0],
                         uint(len(certificate.certs)), addr privateKey.rsakey)

  let size = max(SSL_BUFSIZE_BIDI, bufferSize)
  res.sbuffer = newSeq[byte](size)
  sslEngineSetBuffer(res.scontext.eng, addr res.sbuffer[0],
                     uint(len(res.sbuffer)), 1)
  sslEngineSetVersions(res.scontext.eng, uint16(minVersion),
                       uint16(maxVersion))

  if not isNil(cache):
    sslServerSetCache(
      res.scontext, SslSessionCacheClassPointerConst(addr cache.context.vtable))

  if TLSFlags.EnforceServerPref in flags:
    sslEngineAddFlags(res.scontext.eng, OPT_ENFORCE_SERVER_PREFERENCES)
  if TLSFlags.NoRenegotiation in flags:
    sslEngineAddFlags(res.scontext.eng, OPT_NO_RENEGOTIATION)
  if TLSFlags.TolerateNoClientAuth in flags:
    sslEngineAddFlags(res.scontext.eng, OPT_TOLERATE_NO_CLIENT_AUTH)
  if TLSFlags.FailOnAlpnMismatch in flags:
    sslEngineAddFlags(res.scontext.eng, OPT_FAIL_ON_ALPN_MISMATCH)

  let err = sslServerReset(res.scontext)
  if err == 0:
    raise newException(TLSStreamInitError, "Could not initialize TLS layer")

  block:
    let vtbl = initWriterVtbl()
    init(AsyncStreamWriter(res.writer), vtbl)

  block:
    let vtbl = initReaderVtbl(bufferSize)
    init(AsyncStreamReader(res.reader), vtbl)

  res

proc copyKey(src: RsaPrivateKey): TLSPrivateKey =
  ## Creates copy of RsaPrivateKey ``src``.
  var offset = 0'u
  let keySize = src.plen + src.qlen + src.dplen + src.dqlen + src.iqlen
  var res = TLSPrivateKey(kind: TLSKeyType.RSA, storage: newSeq[byte](keySize))
  copyMem(addr res.storage[offset], src.p, src.plen)
  res.rsakey.p = addr res.storage[offset]
  res.rsakey.plen = src.plen
  offset = offset + src.plen
  copyMem(addr res.storage[offset], src.q, src.qlen)
  res.rsakey.q = addr res.storage[offset]
  res.rsakey.qlen = src.qlen
  offset = offset + src.qlen
  copyMem(addr res.storage[offset], src.dp, src.dplen)
  res.rsakey.dp = addr res.storage[offset]
  res.rsakey.dplen = src.dplen
  offset = offset + src.dplen
  copyMem(addr res.storage[offset], src.dq, src.dqlen)
  res.rsakey.dq = addr res.storage[offset]
  res.rsakey.dqlen = src.dqlen
  offset = offset + src.dqlen
  copyMem(addr res.storage[offset], src.iq, src.iqlen)
  res.rsakey.iq = addr res.storage[offset]
  res.rsakey.iqlen = src.iqlen
  res.rsakey.nBitlen = src.nBitlen
  res

proc copyKey(src: EcPrivateKey): TLSPrivateKey =
  ## Creates copy of EcPrivateKey ``src``.
  var offset = 0
  let keySize = src.xlen
  var res = TLSPrivateKey(kind: TLSKeyType.EC, storage: newSeq[byte](keySize))
  copyMem(addr res.storage[offset], src.x, src.xlen)
  res.eckey.x = addr res.storage[offset]
  res.eckey.xlen = src.xlen
  res.eckey.curve = src.curve
  res

proc init*(tt: typedesc[TLSPrivateKey], data: openArray[byte]): TLSPrivateKey {.
     raises: [TLSStreamProtocolError].} =
  ## Initialize TLS private key from array of bytes ``data``.
  ##
  ## This procedure initializes private key using raw, DER-encoded format,
  ## or wrapped in an unencrypted PKCS#8 archive (again DER-encoded).
  var ctx: SkeyDecoderContext
  if len(data) == 0:
    raiseTLSStreamProtocolError("Incorrect private key")
  skeyDecoderInit(ctx)
  skeyDecoderPush(ctx, cast[pointer](unsafeAddr data[0]), uint(len(data)))
  let err = skeyDecoderLastError(ctx)
  if err != 0:
    raiseTLSStreamProtocolError(err)
  let keyType = skeyDecoderKeyType(ctx)
  let res =
    if keyType == KEYTYPE_RSA:
      copyKey(ctx.key.rsa)
    elif keyType == KEYTYPE_EC:
      copyKey(ctx.key.ec)
    else:
      raiseTLSStreamProtocolError("Unknown key type (" & $keyType & ")")
  res

proc pemDecode*(data: openArray[char]): seq[PEMElement] {.
     raises: [TLSStreamProtocolError].} =
  ## Decode PEM encoded string and get array of binary blobs.
  if len(data) == 0:
    raiseTLSStreamProtocolError("Empty PEM message")
  var pctx = new PEMContext
  var res = newSeq[PEMElement]()

  proc itemAppend(ctx: pointer, pbytes: pointer, nbytes: csize_t) {.cdecl.} =
    var p = cast[PEMContext](ctx)
    var o = uint(len(p.data))
    p.data.setLen(o + nbytes)
    copyMem(addr p.data[o], pbytes, nbytes)

  var offset = 0
  var inobj = false
  var elem: PEMElement

  var ctx: PemDecoderContext
  ctx.init()
  ctx.setdest(itemAppend, cast[pointer](pctx))

  while offset < data.len:
    let tlen = ctx.push(data.toOpenArray(offset, data.high))
    offset = offset + tlen

    let event = ctx.lastEvent()
    if event == PEM_BEGIN_OBJ:
      inobj = true
      elem.name = ctx.banner()
      pctx.data.setLen(0)
    elif event == PEM_END_OBJ:
      if inobj:
        elem.data = pctx.data
        res.add(elem)
        inobj = false
      else:
        break
    else:
      raiseTLSStreamProtocolError("Invalid PEM encoding")
  res

proc init*(tt: typedesc[TLSPrivateKey], data: openArray[char]): TLSPrivateKey {.
     raises: [TLSStreamProtocolError].} =
  ## Initialize TLS private key from string ``data``.
  ##
  ## This procedure initializes private key using unencrypted PKCS#8 PEM
  ## encoded string.
  ##
  ## Note that PKCS#1 PEM encoded objects are not supported.
  var res: TLSPrivateKey
  var items = pemDecode(data)
  for item in items:
    if item.name == "PRIVATE KEY":
      res = TLSPrivateKey.init(item.data)
      break
  if isNil(res):
    raiseTLSStreamProtocolError("Could not find private key")
  res

proc init*(tt: typedesc[TLSCertificate],
           data: openArray[char]): TLSCertificate {.
     raises: [TLSStreamProtocolError].} =
  ## Initialize TLS certificates from string ``data``.
  ##
  ## This procedure initializes array of certificates from PEM encoded string.
  var items = pemDecode(data)
  # storage needs to be big enough for input data
  var res = TLSCertificate(storage: newSeqOfCap[byte](data.len))
  for item in items:
    if item.name == "CERTIFICATE" and len(item.data) > 0:
      let offset = len(res.storage)
      res.storage.add(item.data)
      let cert = X509Certificate(
        data: addr res.storage[offset],
        dataLen: uint(len(item.data))
      )
      let ares = getSignerAlgo(cert)
      if ares == -1:
        raiseTLSStreamProtocolError("Could not decode certificate")
      elif ares != KEYTYPE_RSA and ares != KEYTYPE_EC:
        raiseTLSStreamProtocolError(
          "Unsupported signing key type in certificate")
      res.certs.add(cert)
  if len(res.storage) == 0:
    raiseTLSStreamProtocolError("Could not find any certificates")
  res

proc init*(tt: typedesc[TLSSessionCache],
           size: int = TLSSessionCacheBufferSize): TLSSessionCache =
  ## Create new TLS session cache with size ``size``.
  ##
  ## One cached item is near 100 bytes size.
  let rsize = min(size, 4096)
  var res = TLSSessionCache(storage: newSeq[byte](rsize))
  sslSessionCacheLruInit(addr res.context, addr res.storage[0], rsize)
  res

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
import bearssl, bearssl/cacert
import ../asyncloop, ../timer, ../asyncsync
import asyncstream, ../transports/stream, ../transports/common

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

  TLSStreamWriter* = ref object of AsyncStreamWriter
    case kind: TLSStreamKind
    of TLSStreamKind.Client:
      ccontext: ptr SslClientContext
    of TLSStreamKind.Server:
      scontext: ptr SslServerContext
    stream*: TLSAsyncStream
    switchToReader*: AsyncEvent
    switchToWriter*: AsyncEvent
    handshaked*: bool
    handshakeFut*: Future[void]

  TLSStreamReader* = ref object of AsyncStreamReader
    case kind: TLSStreamKind
    of TLSStreamKind.Client:
      ccontext: ptr SslClientContext
    of TLSStreamKind.Server:
      scontext: ptr SslServerContext
    stream*: TLSAsyncStream
    switchToReader*: AsyncEvent
    switchToWriter*: AsyncEvent
    handshaked*: bool
    handshakeFut*: Future[void]

  TLSAsyncStream* = ref object of RootRef
    xwc*: X509NoAnchorContext
    ccontext*: SslClientContext
    scontext*: SslServerContext
    sbuffer*: seq[byte]
    x509*: X509MinimalContext
    reader*: TLSStreamReader
    writer*: TLSStreamWriter

  SomeTLSStreamType* = TLSStreamReader|TLSStreamWriter|TLSAsyncStream

  TLSStreamError* = object of CatchableError
  TLSStreamProtocolError* = object of TLSStreamError
    errCode*: int

template newTLSStreamProtocolError[T](message: T): ref Exception =
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

proc raiseTLSStreamProtoError*[T](message: T) =
  raise newTLSStreamProtocolError(message)

proc tlsWriteLoop(stream: AsyncStreamWriter) {.async.} =
  var wstream = cast[TLSStreamWriter](stream)
  var engine: ptr SslEngineContext
  var error: ref Exception

  if wstream.kind == TLSStreamKind.Server:
    engine = addr wstream.scontext.eng
  else:
    engine = addr wstream.ccontext.eng

  wstream.state = AsyncStreamState.Running

  try:
    var length: uint
    while true:
      var state = engine.sslEngineCurrentState()

      if (state and SSL_CLOSED) == SSL_CLOSED:
        wstream.state = AsyncStreamState.Finished
        break

      if (state and (SSL_RECVREC or SSL_RECVAPP)) != 0:
        if not(wstream.switchToReader.isSet()):
          wstream.switchToReader.fire()

      if (state and (SSL_SENDREC or SSL_SENDAPP)) == 0:
        await wstream.switchToWriter.wait()
        wstream.switchToWriter.clear()
        # We need to refresh `state` because we just returned from readerLoop.
        continue

      if (state and SSL_SENDREC) == SSL_SENDREC:
        # TLS record needs to be sent over stream.
        length = 0'u
        var buf = sslEngineSendrecBuf(engine, length)
        doAssert(length != 0 and not isNil(buf))
        var fut = awaitne wstream.wsource.write(buf, int(length))
        if fut.cancelled():
          raise fut.error
        elif fut.failed():
          error = fut.error
          break
        sslEngineSendrecAck(engine, length)
        continue

      if (state and SSL_SENDAPP) == SSL_SENDAPP:
        # Application data can be sent over stream.
        if not(wstream.handshaked):
          wstream.stream.reader.handshaked = true
          wstream.handshaked = true
          if not(isNil(wstream.handshakeFut)):
            wstream.handshakeFut.complete()

        var item = await wstream.queue.get()
        if item.size > 0:
          length = 0'u
          var buf = sslEngineSendappBuf(engine, length)
          let toWrite = min(int(length), item.size)
          copyOut(buf, item, toWrite)
          if int(length) >= item.size:
            # BearSSL is ready to accept whole item size.
            sslEngineSendappAck(engine, uint(item.size))
            sslEngineFlush(engine, 0)
            item.future.complete()
          else:
            # BearSSL is not ready to accept whole item, so we will send only
            # part of item and adjust offset.
            item.offset = item.offset + int(length)
            item.size = item.size - int(length)
            wstream.queue.addFirstNoWait(item)
            sslEngineSendappAck(engine, length)
          continue
        else:
          # Zero length item means finish
          wstream.state = AsyncStreamState.Finished
          break

  except CancelledError:
    wstream.state = AsyncStreamState.Stopped

  finally:
    if wstream.state == AsyncStreamState.Stopped:
      while len(wstream.queue) > 0:
        let item = wstream.queue.popFirstNoWait()
        if not(item.future.finished()):
          item.future.complete()
    elif wstream.state == AsyncStreamState.Error:
      while len(wstream.queue) > 0:
        let item = wstream.queue.popFirstNoWait()
        if not(item.future.finished()):
          item.future.fail(error)
    wstream.stream = nil

proc tlsReadLoop(stream: AsyncStreamReader) {.async.} =
  var rstream = cast[TLSStreamReader](stream)
  var engine: ptr SslEngineContext

  if rstream.kind == TLSStreamKind.Server:
    engine = addr rstream.scontext.eng
  else:
    engine = addr rstream.ccontext.eng

  rstream.state = AsyncStreamState.Running

  try:
    var length: uint
    while true:
      var state = engine.sslEngineCurrentState()
      if (state and SSL_CLOSED) == SSL_CLOSED:
        let err = engine.sslEngineLastError()
        if err != 0:
          raise newTLSStreamProtocolError(err)
        rstream.state = AsyncStreamState.Stopped
        break

      if (state and (SSL_SENDREC or SSL_SENDAPP)) != 0:
        if not(rstream.switchToWriter.isSet()):
          rstream.switchToWriter.fire()

      if (state and (SSL_RECVREC or SSL_RECVAPP)) == 0:
        await rstream.switchToReader.wait()
        rstream.switchToReader.clear()
        # We need to refresh `state` because we just returned from writerLoop.
        continue

      if (state and SSL_RECVREC) == SSL_RECVREC:
        # TLS records required for further processing
        length = 0'u
        var buf = sslEngineRecvrecBuf(engine, length)
        let res = await rstream.rsource.readOnce(buf, int(length))
        if res > 0:
          sslEngineRecvrecAck(engine, uint(res))
          continue
        else:
          rstream.state = AsyncStreamState.Finished
          break

      if (state and SSL_RECVAPP) == SSL_RECVAPP:
        # Application data can be recovered.
        length = 0'u
        var buf = sslEngineRecvappBuf(engine, length)
        await upload(addr rstream.buffer, buf, int(length))
        sslEngineRecvappAck(engine, length)
        continue

  except CancelledError:
    rstream.state = AsyncStreamState.Stopped
  except TLSStreamProtocolError as exc:
    rstream.error = exc
    rstream.state = AsyncStreamState.Error
    if not(rstream.handshaked):
      rstream.handshaked = true
      rstream.stream.writer.handshaked = true
      if not(isNil(rstream.handshakeFut)):
        rstream.handshakeFut.fail(rstream.error)
      rstream.switchToWriter.fire()
  except AsyncStreamReadError as exc:
    rstream.error = exc
    rstream.state = AsyncStreamState.Error
    if not(rstream.handshaked):
      rstream.handshaked = true
      rstream.stream.writer.handshaked = true
      if not(isNil(rstream.handshakeFut)):
        rstream.handshakeFut.fail(rstream.error)
      rstream.switchToWriter.fire()
  finally:
    # Perform TLS cleanup procedure
    sslEngineClose(engine)
    rstream.buffer.forget()
    rstream.stream = nil

proc getSignerAlgo(xc: X509Certificate): int =
  ## Get certificate's signing algorithm.
  var dc: X509DecoderContext
  x509DecoderInit(addr dc, nil, nil)
  x509DecoderPush(addr dc, xc.data, xc.dataLen)
  let err = x509DecoderLastError(addr dc)
  if err != 0:
    result = -1
  else:
    result = int(x509DecoderGetSignerKeyType(addr dc))

proc newTLSClientAsyncStream*(rsource: AsyncStreamReader,
                              wsource: AsyncStreamWriter,
                              serverName: string,
                              bufferSize = SSL_BUFSIZE_BIDI,
                              minVersion = TLSVersion.TLS11,
                              maxVersion = TLSVersion.TLS12,
                              flags: set[TLSFlags] = {}): TLSAsyncStream =
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
  result = new TLSAsyncStream
  var reader = TLSStreamReader(kind: TLSStreamKind.Client)
  var writer = TLSStreamWriter(kind: TLSStreamKind.Client)
  var switchToWriter = newAsyncEvent()
  var switchToReader = newAsyncEvent()
  reader.stream = result
  writer.stream = result
  reader.switchToReader = switchToReader
  reader.switchToWriter = switchToWriter
  writer.switchToReader = switchToReader
  writer.switchToWriter = switchToWriter
  result.reader = reader
  result.writer = writer
  reader.ccontext = addr result.ccontext
  writer.ccontext = addr result.ccontext

  if TLSFlags.NoVerifyHost in flags:
    sslClientInitFull(addr result.ccontext, addr result.x509, nil, 0)
    initNoAnchor(addr result.xwc, addr result.x509.vtable)
    sslEngineSetX509(addr result.ccontext.eng, addr result.xwc.vtable)
  else:
    sslClientInitFull(addr result.ccontext, addr result.x509,
                      unsafeAddr MozillaTrustAnchors[0],
                      len(MozillaTrustAnchors))

  let size = max(SSL_BUFSIZE_BIDI, bufferSize)
  result.sbuffer = newSeq[byte](size)
  sslEngineSetBuffer(addr result.ccontext.eng, addr result.sbuffer[0],
                     uint(len(result.sbuffer)), 1)
  sslEngineSetVersions(addr result.ccontext.eng, uint16(minVersion),
                       uint16(maxVersion))

  if TLSFlags.NoVerifyServerName in flags:
    let err = sslClientReset(addr result.ccontext, "", 0)
    if err == 0:
      raise newException(TLSStreamError, "Could not initialize TLS layer")
  else:
    if len(serverName) == 0:
      raise newException(TLSStreamError, "serverName must not be empty string")

    let err = sslClientReset(addr result.ccontext, serverName, 0)
    if err == 0:
      raise newException(TLSStreamError, "Could not initialize TLS layer")

  init(cast[AsyncStreamWriter](result.writer), wsource, tlsWriteLoop,
       bufferSize)
  init(cast[AsyncStreamReader](result.reader), rsource, tlsReadLoop,
       bufferSize)

proc newTLSServerAsyncStream*(rsource: AsyncStreamReader,
                              wsource: AsyncStreamWriter,
                              privateKey: TLSPrivateKey,
                              certificate: TLSCertificate,
                              bufferSize = SSL_BUFSIZE_BIDI,
                              minVersion = TLSVersion.TLS11,
                              maxVersion = TLSVersion.TLS12,
                              cache: TLSSessionCache = nil,
                              flags: set[TLSFlags] = {}): TLSAsyncStream =
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
    raiseTLSStreamProtoError("Incorrect private key")
  if isNil(certificate) or len(certificate.certs) == 0:
    raiseTLSStreamProtoError("Incorrect certificate")

  result = new TLSAsyncStream
  var reader = TLSStreamReader(kind: TLSStreamKind.Server)
  var writer = TLSStreamWriter(kind: TLSStreamKind.Server)
  var switchToWriter = newAsyncEvent()
  var switchToReader = newAsyncEvent()
  reader.stream = result
  writer.stream = result
  reader.switchToReader = switchToReader
  reader.switchToWriter = switchToWriter
  writer.switchToReader = switchToReader
  writer.switchToWriter = switchToWriter
  result.reader = reader
  result.writer = writer
  reader.scontext = addr result.scontext
  writer.scontext = addr result.scontext

  if privateKey.kind == TLSKeyType.EC:
    let algo = getSignerAlgo(certificate.certs[0])
    if algo == -1:
      raiseTLSStreamProtoError("Could not decode certificate")
    sslServerInitFullEc(addr result.scontext, addr certificate.certs[0],
                        len(certificate.certs), cuint(algo),
                        addr privateKey.eckey)
  elif privateKey.kind == TLSKeyType.RSA:
    sslServerInitFullRsa(addr result.scontext, addr certificate.certs[0],
                         len(certificate.certs), addr privateKey.rsakey)

  let size = max(SSL_BUFSIZE_BIDI, bufferSize)
  result.sbuffer = newSeq[byte](size)
  sslEngineSetBuffer(addr result.scontext.eng, addr result.sbuffer[0],
                     uint(len(result.sbuffer)), 1)
  sslEngineSetVersions(addr result.scontext.eng, uint16(minVersion),
                       uint16(maxVersion))

  if not isNil(cache):
    sslServerSetCache(addr result.scontext, addr cache.context.vtable)

  if TLSFlags.EnforceServerPref in flags:
    sslEngineAddFlags(addr result.scontext.eng, OPT_ENFORCE_SERVER_PREFERENCES)
  if TLSFlags.NoRenegotiation in flags:
    sslEngineAddFlags(addr result.scontext.eng, OPT_NO_RENEGOTIATION)
  if TLSFlags.TolerateNoClientAuth in flags:
    sslEngineAddFlags(addr result.scontext.eng, OPT_TOLERATE_NO_CLIENT_AUTH)
  if TLSFlags.FailOnAlpnMismatch in flags:
    sslEngineAddFlags(addr result.scontext.eng, OPT_FAIL_ON_ALPN_MISMATCH)

  let err = sslServerReset(addr result.scontext)
  if err == 0:
    raise newException(TLSStreamError, "Could not initialize TLS layer")

  init(cast[AsyncStreamWriter](result.writer), wsource, tlsWriteLoop,
       bufferSize)
  init(cast[AsyncStreamReader](result.reader), rsource, tlsReadLoop,
       bufferSize)

proc copyKey(src: RsaPrivateKey): TLSPrivateKey =
  ## Creates copy of RsaPrivateKey ``src``.
  var offset = 0
  let keySize = src.plen + src.qlen + src.dplen + src.dqlen + src.iqlen
  result = TLSPrivateKey(kind: TLSKeyType.RSA)
  result.storage = newSeq[byte](keySize)
  copyMem(addr result.storage[offset], src.p, src.plen)
  result.rsakey.p = cast[ptr cuchar](addr result.storage[offset])
  result.rsakey.plen = src.plen
  offset = offset + src.plen
  copyMem(addr result.storage[offset], src.q, src.qlen)
  result.rsakey.q = cast[ptr cuchar](addr result.storage[offset])
  result.rsakey.qlen = src.qlen
  offset = offset + src.qlen
  copyMem(addr result.storage[offset], src.dp, src.dplen)
  result.rsakey.dp = cast[ptr cuchar](addr result.storage[offset])
  result.rsakey.dplen = src.dplen
  offset = offset + src.dplen
  copyMem(addr result.storage[offset], src.dq, src.dqlen)
  result.rsakey.dq = cast[ptr cuchar](addr result.storage[offset])
  result.rsakey.dqlen = src.dqlen
  offset = offset + src.dqlen
  copyMem(addr result.storage[offset], src.iq, src.iqlen)
  result.rsakey.iq = cast[ptr cuchar](addr result.storage[offset])
  result.rsakey.iqlen = src.iqlen
  result.rsakey.nBitlen = src.nBitlen

proc copyKey(src: EcPrivateKey): TLSPrivateKey =
  ## Creates copy of EcPrivateKey ``src``.
  var offset = 0
  let keySize = src.xlen
  result = TLSPrivateKey(kind: TLSKeyType.EC)
  result.storage = newSeq[byte](keySize)
  copyMem(addr result.storage[offset], src.x, src.xlen)
  result.eckey.x = cast[ptr cuchar](addr result.storage[offset])
  result.eckey.xlen = src.xlen
  result.eckey.curve = src.curve

proc init*(tt: typedesc[TLSPrivateKey], data: openarray[byte]): TLSPrivateKey =
  ## Initialize TLS private key from array of bytes ``data``.
  ##
  ## This procedure initializes private key using raw, DER-encoded format,
  ## or wrapped in an unencrypted PKCS#8 archive (again DER-encoded).
  var ctx: SkeyDecoderContext
  if len(data) == 0:
    raiseTLSStreamProtoError("Incorrect private key")
  skeyDecoderInit(addr ctx)
  skeyDecoderPush(addr ctx, cast[pointer](unsafeAddr data[0]), len(data))
  let err = skeyDecoderLastError(addr ctx)
  if err != 0:
    raiseTLSStreamProtoError(err)
  let keyType = skeyDecoderKeyType(addr ctx)
  if keyType == KEYTYPE_RSA:
    result = copyKey(ctx.key.rsa)
  elif keyType == KEYTYPE_EC:
    result = copyKey(ctx.key.ec)
  else:
    raiseTLSStreamProtoError("Unknown key type (" & $keyType & ")")

proc pemDecode*(data: openarray[char]): seq[PEMElement] =
  ## Decode PEM encoded string and get array of binary blobs.
  if len(data) == 0:
    raiseTLSStreamProtoError("Empty PEM message")
  var ctx: PemDecoderContext
  var pctx = new PEMContext
  result = newSeq[PEMElement]()
  pemDecoderInit(addr ctx)

  proc itemAppend(ctx: pointer, pbytes: pointer, nbytes: int) {.cdecl.} =
    var p = cast[PEMContext](ctx)
    var o = len(p.data)
    p.data.setLen(o + nbytes)
    copyMem(addr p.data[o], pbytes, nbytes)

  var length = len(data)
  var offset = 0
  var inobj = false
  var elem: PEMElement

  while length > 0:
    var tlen = pemDecoderPush(addr ctx,
                              cast[pointer](unsafeAddr data[offset]), length)
    offset = offset + tlen
    length = length - tlen

    let event = pemDecoderEvent(addr ctx)
    if event == PEM_BEGIN_OBJ:
      inobj = true
      elem.name = $pemDecoderName(addr ctx)
      pctx.data = newSeq[byte]()
      pemDecoderSetdest(addr ctx, itemAppend, cast[pointer](pctx))
    elif event == PEM_END_OBJ:
      if inobj:
        elem.data = pctx.data
        result.add(elem)
        inobj = false
      else:
        break
    else:
      raiseTLSStreamProtoError("Invalid PEM encoding")

proc init*(tt: typedesc[TLSPrivateKey], data: openarray[char]): TLSPrivateKey =
  ## Initialize TLS private key from string ``data``.
  ##
  ## This procedure initializes private key using unencrypted PKCS#8 PEM
  ## encoded string.
  ##
  ## Note that PKCS#1 PEM encoded objects are not supported.
  var items = pemDecode(data)
  for item in items:
    if item.name == "PRIVATE KEY":
      result = TLSPrivateKey.init(item.data)
      break
  if isNil(result):
    raiseTLSStreamProtoError("Could not find private key")

proc init*(tt: typedesc[TLSCertificate],
           data: openarray[char]): TLSCertificate =
  ## Initialize TLS certificates from string ``data``.
  ##
  ## This procedure initializes array of certificates from PEM encoded string.
  var items = pemDecode(data)
  result = new TLSCertificate
  for item in items:
    if item.name == "CERTIFICATE" and len(item.data) > 0:
      let offset = len(result.storage)
      result.storage.add(item.data)
      let cert = X509Certificate(
        data: cast[ptr cuchar](addr result.storage[offset]),
        dataLen: len(item.data)
      )
      let res = getSignerAlgo(cert)
      if res == -1:
        raiseTLSStreamProtoError("Could not decode certificate")
      elif res != KEYTYPE_RSA and res != KEYTYPE_EC:
        raiseTLSStreamProtoError("Unsupported signing key type in certificate")
      result.certs.add(cert)
  if len(result.storage) == 0:
    raiseTLSStreamProtoError("Could not find any certificates")

proc init*(tt: typedesc[TLSSessionCache], size: int = 4096): TLSSessionCache =
  ## Create new TLS session cache with size ``size``.
  ##
  ## One cached item is near 100 bytes size.
  result = new TLSSessionCache
  var rsize = min(size, 4096)
  result.storage = newSeq[byte](rsize)
  sslSessionCacheLruInit(addr result.context, addr result.storage[0], rsize)

proc handshake*(rws: SomeTLSStreamType): Future[void] =
  ## Wait until initial TLS handshake will be successfully performed.
  var retFuture = newFuture[void]("tlsstream.handshake")
  when rws is TLSStreamReader:
    if rws.handshaked:
      retFuture.complete()
    else:
      rws.handshakeFut = retFuture
      rws.stream.writer.handshakeFut = retFuture
  elif rws is TLSStreamWriter:
    if rws.handshaked:
      retFuture.complete()
    else:
      rws.handshakeFut = retFuture
      rws.stream.reader.handshakeFut = retFuture
  elif rws is TLSAsyncStream:
    if rws.reader.handshaked:
      retFuture.complete()
    else:
      rws.reader.handshakeFut = retFuture
      rws.writer.handshakeFut = retFuture
  return retFuture

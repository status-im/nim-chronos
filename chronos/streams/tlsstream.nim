#
#          Chronos Asynchronous TLS Stream
#             (c) Copyright 2019-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

## This module implements TLS stream reading and writing.
import bearssl, bearssl/cacert
import ../asyncloop, ../timer, ../asyncsync
import asyncstream, ../transports/stream, ../transports/common
import strutils

type
  TLSStreamKind {.pure.} = enum
    Client, Server

  TLSVersion* {.pure.} = enum
    TLS10 = 0x0301, TLS11 = 0x0302, TLS12 = 0x0303

  TLSFlags* {.pure.} = enum
    NoVerifyHost,       # Client: Skip remote certificate check
    NoVerifySN,         # Client: Skip Server Name Indication (SNI) check
    NoRenegotiation,    # Server: Reject renegotiations requests
    NoClientAuth,       # Server: Disable strict client authentication
    FailOnAlpnMismatch  # Server: Fail on application protocol mismatch

type
  TlsStreamWriter* = ref object of AsyncStreamWriter
    case kind: TlsStreamKind
    of TlsStreamKind.Client:
      ccontext: ptr SslClientContext
    of TlsStreamKind.Server:
      scontext: ptr SslServerContext
    stream*: TlsAsyncStream
    switchToReader*: AsyncEvent
    switchToWriter*: AsyncEvent

  TlsStreamReader* = ref object of AsyncStreamReader
    case kind: TlsStreamKind
    of TlsStreamKind.Client:
      ccontext: ptr SslClientContext
    of TlsStreamKind.Server:
      scontext: ptr SslServerContext
    stream*: TlsAsyncStream
    switchToReader*: AsyncEvent
    switchToWriter*: AsyncEvent

  TlsAsyncStream* = ref object of RootRef
    xwc*: X509NoAnchorContext
    context*: SslClientContext
    sbuffer*: seq[byte]
    x509*: X509MinimalContext
    reader*: TlsStreamReader
    writer*: TlsStreamWriter

  TlsStreamError* = object of CatchableError
  TlsStreamProtocolError* = object of TlsStreamError
    errCode*: int

template newTlsStreamProtocolError[T](message: T): ref Exception =
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
  var err = newException(TlsStreamProtocolError, msg)
  err.errCode = code
  err

# proc raiseTlsStreamProtoError*[T](message: T) =
#   raise newTlsStreamProtocolError(message)

proc getStringState*(state: cuint): string =
  var n = newSeq[string]()
  if (state and SSL_CLOSED) == SSL_CLOSED:
    n.add("Closed")
  if (state and SSL_SENDREC) == SSL_SENDREC:
    n.add("SendRec")
  if (state and SSL_RECVREC) == SSL_RECVREC:
    n.add("RecvRec")
  if (state and SSL_SENDAPP) == SSL_SENDAPP:
    n.add("SendApp")
  if (state and SSL_RECVAPP) == SSL_RECVAPP:
    n.add("RecvApp")
  result = "{" & n.join(", ") & "} number (" & $state & ")"

proc tlsWriteLoop(stream: AsyncStreamWriter) {.async.} =
  var wstream = cast[TlsStreamWriter](stream)
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
        if fut.failed():
          error = fut.error
          break
        sslEngineSendrecAck(engine, length)
        continue

      if (state and SSL_SENDAPP) == SSL_SENDAPP:
        # Application data can be sent over stream.
        var item = await wstream.queue.get()
        if item.size > 0:
          length = 0'u
          var buf = sslEngineSendappBuf(engine, length)
          let toWrite = min(int(length), item.size)

          if int(length) >= item.size:
            if item.kind == Pointer:
              let p = cast[pointer](cast[uint](item.data1) + uint(item.offset))
              copyMem(buf, p, item.size)
            elif item.kind == Sequence:
              copyMem(buf, addr item.data2[item.offset], item.size)
            elif item.kind == String:
              copyMem(buf, addr item.data3[item.offset], item.size)
            sslEngineSendappAck(engine, uint(item.size))
            sslEngineFlush(engine, 0)
            item.future.complete()
          else:
            if item.kind == Pointer:
              let p = cast[pointer](cast[uint](item.data1) + uint(item.offset))
              copyMem(buf, p, length)
            elif item.kind == Sequence:
              copyMem(buf, addr item.data2[item.offset], length)
            elif item.kind == String:
              copyMem(buf, addr item.data3[item.offset], length)
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
  var rstream = cast[TlsStreamReader](stream)
  var engine: ptr SslEngineContext

  if rstream.kind == TlsStreamKind.Server:
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
          rstream.error = newTlsStreamProtocolError(err)
          rstream.state = AsyncStreamState.Error
          break
        else:
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
        var resFut = awaitne rstream.rsource.readOnce(buf, int(length))
        if resFut.failed():
          rstream.error = resFut.error
          rstream.state = AsyncStreamState.Error
          break
        let res = resFut.read()
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

  finally:
    # Perform TLS cleanup procedure
    sslEngineClose(engine)
    # Becase tlsWriteLoop() is ephemeral, but we still need to keep stream state
    # consistent.
    rstream.buffer.forget()
    rstream.stream = nil

proc newTlsClientAsyncStream*(rsource: AsyncStreamReader,
                              wsource: AsyncStreamWriter,
                              serverName: string = "",
                              bufferSize = SSL_BUFSIZE_BIDI,
                              minVersion = TLSVersion.TLS11,
                              maxVersion = TLSVersion.TLS12,
                              flags: set[TlsFlags] = {}): TlsAsyncStream =
  ## Create new TLS asynchronous stream using reading stream ``rsource``,
  ## writing stream ``wsource``.
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
  result = new TlsAsyncStream
  var reader = new TlsStreamReader
  reader.kind = TlsStreamKind.Client
  var writer = new TlsStreamWriter
  writer.kind = TlsStreamKind.Client
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
  reader.ccontext = addr result.context
  writer.ccontext = addr result.context

  if TLSFlags.NoVerifyHost in flags:
    sslClientInitFull(addr result.context, addr result.x509, nil, 0)
    initNoAnchor(addr result.xwc, addr result.x509.vtable)
    sslEngineSetX509(addr result.context.eng, addr result.xwc.vtable)
  else:
    sslClientInitFull(addr result.context, addr result.x509,
                      unsafeAddr MozillaTrustAnchors[0],
                      len(MozillaTrustAnchors))

  let size = max(SSL_BUFSIZE_BIDI, bufferSize)
  result.sbuffer = newSeq[byte](size)
  sslEngineSetBuffer(addr result.context.eng, addr result.sbuffer[0],
                     uint(len(result.sbuffer)), 1)
  sslEngineSetVersions(addr result.context.eng, uint16(minVersion),
                       uint16(maxVersion))

  if TLSFlags.NoVerifySN in flags:
    let err = sslClientReset(addr result.context, "", 0)
    if err == 0:
      raise newException(TlsStreamError, "Could not initialize TLS layer")
  else:
    let err = sslClientReset(addr result.context, serverName, 0)
    if err == 0:
      raise newException(TlsStreamError, "Could not initialize TLS layer")

  init(cast[AsyncStreamWriter](result.writer), wsource, tlsWriteLoop,
       bufferSize)
  init(cast[AsyncStreamReader](result.reader), rsource, tlsReadLoop,
       bufferSize)

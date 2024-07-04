#
#        Chronos HTTP/S server implementation
#             (c) Copyright 2021-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

{.push raises: [].}

import std/tables
import results
import ../../timer
import httpserver, shttpserver
from httpclient import HttpClientScheme
from httpcommon import HttpState
from ../../osdefs import SocketHandle
from ../../transports/common import TransportAddress, ServerFlags
export HttpClientScheme, SocketHandle, TransportAddress, ServerFlags, HttpState

type
  ConnectionType* {.pure.} = enum
    NonSecure, Secure

  ConnectionState* {.pure.} = enum
    Accepted, Alive, Closing, Closed

  ServerConnectionInfo* = object
    handle*: SocketHandle
    connectionType*: ConnectionType
    connectionState*: ConnectionState
    query*: Opt[string]
    remoteAddress*: Opt[TransportAddress]
    localAddress*: Opt[TransportAddress]
    acceptMoment*: Moment
    createMoment*: Opt[Moment]

  ServerInfo* = object
    connectionType*: ConnectionType
    address*: TransportAddress
    state*: HttpServerState
    maxConnections*: int
    backlogSize*: int
    baseUri*: Uri
    serverIdent*: string
    flags*: set[HttpServerFlags]
    socketFlags*: set[ServerFlags]
    headersTimeout*: Duration
    bufferSize*: int
    maxHeadersSize*: int
    maxRequestBodySize*: int

proc getConnectionType*(
       server: HttpServerRef | SecureHttpServerRef): ConnectionType =
  when server is SecureHttpServerRef:
    ConnectionType.Secure
  else:
    if HttpServerFlags.Secure in server.flags:
      ConnectionType.Secure
    else:
      ConnectionType.NonSecure

proc getServerInfo*(server: HttpServerRef|SecureHttpServerRef): ServerInfo =
  ServerInfo(
    connectionType: server.getConnectionType(),
    address: server.address,
    state: server.state(),
    maxConnections: server.maxConnections,
    backlogSize: server.backlogSize,
    baseUri: server.baseUri,
    serverIdent: server.serverIdent,
    flags: server.flags,
    socketFlags: server.socketFlags,
    headersTimeout: server.headersTimeout,
    bufferSize: server.bufferSize,
    maxHeadersSize: server.maxHeadersSize,
    maxRequestBodySize: server.maxRequestBodySize
  )

proc getConnectionState*(holder: HttpConnectionHolderRef): ConnectionState =
  if not(isNil(holder.connection)):
    case holder.connection.state
    of HttpState.Alive: ConnectionState.Alive
    of HttpState.Closing: ConnectionState.Closing
    of HttpState.Closed: ConnectionState.Closed
  else:
    ConnectionState.Accepted

proc getQueryString*(holder: HttpConnectionHolderRef): Opt[string] =
  if not(isNil(holder.connection)):
    holder.connection.currentRawQuery
  else:
    Opt.none(string)

proc init*(t: typedesc[ServerConnectionInfo],
           holder: HttpConnectionHolderRef): ServerConnectionInfo =
  let
    localAddress =
      try:
        Opt.some(holder.transp.localAddress())
      except CatchableError:
        Opt.none(TransportAddress)
    remoteAddress =
      try:
        Opt.some(holder.transp.remoteAddress())
      except CatchableError:
        Opt.none(TransportAddress)
    queryString = holder.getQueryString()

  ServerConnectionInfo(
    handle: SocketHandle(holder.transp.fd),
    connectionType: holder.server.getConnectionType(),
    connectionState: holder.getConnectionState(),
    remoteAddress: remoteAddress,
    localAddress: localAddress,
    acceptMoment: holder.acceptMoment,
    query: queryString,
    createMoment:
      if not(isNil(holder.connection)):
        Opt.some(holder.connection.createMoment)
      else:
        Opt.none(Moment)
  )

proc getConnections*(server: HttpServerRef): seq[ServerConnectionInfo] =
  var res: seq[ServerConnectionInfo]
  for holder in server.connections.values():
    res.add(ServerConnectionInfo.init(holder))
  res

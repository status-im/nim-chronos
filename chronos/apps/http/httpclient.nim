import std/uri
import stew/[results, base10], httputils
import ../../asyncloop, ../../asyncsync
import ../../streams/[asyncstream, tlsstream]
import httptable, httpcommon, multipart
export httptable, httpcommon, multipart

const
  HttpMaxHeadersSize* = 8192        # maximum size of HTTP headers in octets
  HttpConnectTimeout* = 12.seconds  # timeout for connecting to host (12 sec)
  HttpHeadersTimeout* = 120.seconds # timeout for receiving headers (120 sec)
  HttpMaxRedirections* = 10         # maximum number of Location redirections.

type
  HttpClientState* {.pure.} = enum
    Closed                    # Connection closed
    Resolving,                # Resolving remote hostname
    Connecting,               # Connecting to remote server
    Ready,                    # Connected to remote server
    RequestHeadersSending,    # Sending request headers
    RequestHeadersSent,       # Request headers has been sent
    RequestBodySending,       # Sending request body
    RequestBodySent,          # Request body has been sent
    ResponseHeadersReceiving, # Receiving response headers
    ResponseHeadersReceived,  # Response headers has been received
    ResponseBodyReceiving,    # Receiving response body
    ResponseBodyReceived,     # Response body has been received
    Error                     # Error happens

  HttpClientConnectionType* {.pure.} = enum
    NonSecure, Secure

  HttpClientBodyFlag* {.pure.} = enum
    Sized,                    # `Content-Length` present
    Chunked,                  # `Transfer-Encoding: chunked` present
    Custom                    # None of the above

  HttpClientRequestFlag* {.pure.} = enum
    CloseConnection           # Send `Connection: close` in request

  HttpHeaderTuple* = tuple
    key: string
    value: string

  HttpClientConnection* = object of RootObj
    case kind*: HttpClientConnectionType
    of HttpClientConnectionType.NonSecure:
      discard
    of HttpClientConnectionType.Secure:
      treader*: AsyncStreamReader
      twriter*: AsyncStreamWriter
      tls*: TLSAsyncStream
    transp*: StreamTransport
    reader*: AsyncStreamReader
    writer*: AsyncStreamWriter
    state*: HttpClientState
    error*: ref HttpError
    remoteHostname*: string

  HttpClientConnectionRef* = ref HttpClientConnection

  HttpSessionRef* = ref object
    connections*: seq[HttpClientConnectionRef]
    maxRedirections*: int
    connectTimeout*: Duration
    headersTimeout*: Duration
    connectionBufferSize*: int
    flags*: HttpClientFlags

  HttpClientScheme* {.pure.} = enum
    Nonsecure, Secure

  HttpAddress* = object
    id*: string
    scheme*: HttpClientConnectionType
    hostname*: string
    port*: uint16
    path*: string
    query*: string
    anchor*: string
    username*: string
    password*: string
    addresses*: seq[TransportAddress]

  HttpClientRequest* = object
    meth: HttpMethod
    url: tuple[path: string, query: string, anchor: string]
    version: HttpVersion
    headers: HttpTable
    bodyFlag: HttpClientBodyFlag
    flags: set[HttpClientRequestFlag]


  HttpClientFlag* {.pure.} = enum
    NoVerifyHost,       ## Skip remote server certificate verification
    NoVerifyServerName, ## Skip remote server name CN verification
    NoInet4Resolution,  ## Do not resolve server hostname to IPv4 addresses
    NoInet6Resolution   ## Do not resolve server hostname to IPv6 addresses

  HttpClientFlags* = set[HttpClientFlag]

proc new*(t: typedesc[HttpSessionRef],
          flags: HttpClientFlags = {},
          maxRedirections = HttpMaxRedirections,
          connectTimeout = HttpConnectTimeout,
          headersTimeout = HttpHeadersTimeout,
          connectionBufferSize = DefaultStreamBufferSize): HttpSessionRef {.
     raises: [Defect] .} =
  ## Create new HTTP session object.
  ##
  ## ``maxRedirections`` - maximum number of HTTP 3xx redirections
  ## ``connectTimeout`` - timeout for ongoing HTTP connection
  ## ``headersTimeout`` - timeout for receiving HTTP response headers
  HttpSessionRef(
    flags: flags,
    maxRedirections: maxRedirections,
    connectTimeout: connectTimeout,
    headersTimeout: headersTimeout,
    connectionBufferSize: connectionBufferSize
  )

proc getTLSFlags(flags: HttpClientFlags): set[TLSFlags] {.raises: [Defect] .} =
  var res: set[TLSFlags]
  if HttpClientFlag.NoVerifyHost in flags:
    res.incl(TLSFlags.NoVerifyHost)
  if HttpClientFlag.NoVerifyServerName in flags:
    res.incl(TLSFlags.NoVerifyServerName)
  res

proc getAddress(session: HttpSessionRef,
                url: Uri): HttpResult[HttpAddress] {.
     raises: [Defect] .} =
  let scheme =
    if len(url.scheme) == 0:
      HttpClientConnectionType.NonSecure
    else:
      case toLowerAscii(url.scheme)
      of "http":
        HttpClientConnectionType.NonSecure
      of "https":
        HttpClientConnectionType.Secure
      else:
        return err("URL scheme not supported")

  let port =
    if len(url.port) == 0:
      case scheme
      of HttpClientConnectionType.NonSecure:
        80'u16
      of HttpClientConnectionType.Secure:
        443'u16
    else:
      let res = Base10.decode(uint16, url.port)
      if res.isErr():
        return err("Invalid URL port number")
      res.get()

  let hostname =
    block:
      if len(url.hostname) == 0:
        return err("URL hostname is missing")
      url.hostname

  let id = hostname & ":" & Base10.toString(port)

  let addresses =
    try:
      if (HttpClientFlag.NoInet4Resolution in session.flags) and
         (HttpClientFlag.NoInet6Resolution in session.flags):
        # DNS resolution is disabled.
        @[initTAddress(hostname, Port(port))]
      else:
        if (HttpClientFlag.NoInet4Resolution notin session.flags) and
           (HttpClientFlag.NoInet6Resolution notin session.flags):
          # DNS resolution for both IPv4 and IPv6 addresses.
          resolveTAddress(hostname, Port(port))
        else:
          if HttpClientFlag.NoInet6Resolution in session.flags:
            # DNS resolution only for IPv4 addresses.
            resolveTAddress(hostname, Port(port), AddressFamily.IPv4)
          else:
            # DNS resolution only for IPv6 addresses
            resolveTAddress(hostname, Port(port), AddressFamily.IPv6)
    except TransportAddressError:
      return err("Could not resolve address of remote server")

  if len(addresses) == 0:
    return err("Could not resolve address of remote server")

  ok(HttpAddress(id: id, scheme: scheme, hostname: hostname, port: port,
                 path: url.path, query: url.query, anchor: url.anchor,
                 username: url.username, password: url.password,
                 addresses: addresses))

proc new(t: typedesc[HttpClientConnectionRef], session: HttpSessionRef,
         ha: HttpAddress, transp: StreamTransport): HttpClientConnectionRef =
  case ha.scheme
  of HttpClientConnectionType.NonSecure:
    HttpClientConnectionRef(
      kind: HttpClientConnectionType.NonSecure,
      transp: transp,
      reader: newAsyncStreamReader(transp),
      writer: newAsyncStreamWriter(transp),
      state: HttpClientState.Ready,
      remoteHostname: ha.id
    )
  of HttpClientConnectionType.Secure:
    let treader = newAsyncStreamReader(transp)
    let twriter = newAsyncStreamWriter(transp)
    let tls = newTLSClientAsyncStream(treader, twriter, ha.hostname,
                                      flags = session.flags.getTLSFlags())
    HttpClientConnectionRef(
      kind: HttpClientConnectionType.Secure,
      transp: transp,
      treader: treader,
      twriter: twriter,
      reader: tls.reader,
      writer: tls.writer,
      tls: tls,
      state: HttpClientState.Connecting,
      remoteHostname: ha.id
    )

proc closeWait*(conn: HttpClientConnectionRef) {.async.} =
  ## Close HttpClientConnectionRef instance ``conn`` and free all the resources.
  await allFutures(conn.reader.closeWait(), conn.writer.closeWait())
  case conn.kind
  of HttpClientConnectionType.Secure:
    await allFutures(conn.treader.closeWait(), conn.twriter.closeWait())
  of HttpClientConnectionType.NonSecure:
    discard
  await conn.transp.closeWait()

proc connect(session: HttpSessionRef,
             ha: HttpAddress): Future[HttpClientConnectionRef] {.async.} =
  ## Establish connection with remote server using ``url`` and ``flags``.
  ## On success returns ``HttpClientConnectionRef`` object.

  # Here we trying to connect to every possible remote host address we got after
  # DNS resolution.
  for address in ha.addresses:
    let transp =
      try:
        await connect(address, bufferSize = session.connectionBufferSize)
      except CancelledError as exc:
        raise exc
      except CatchableError:
        nil
    if not(isNil(transp)):
      let conn =
        block:
          let res = HttpClientConnectionRef.new(session, ha, transp)
          if res.kind == HttpClientConnectionType.Secure:
            try:
              await res.tls.handshake()
              res.state = HttpClientState.Ready
            except CancelledError as exc:
              await res.closeWait()
              raise exc
            except AsyncStreamError:
              discard
          res
      if not(isNil(conn)):
        return conn

  # If all attempts to connect to the remote host have failed.
  raiseHttpConnectionError()

proc init*(t: typedesc[HttpClientRequest], meth: HttpMethod = MethodGet,
           version: HttpVersion = HttpVersion11, ha: HttpAddress,
           flags: set[HttpClientRequestFlag],
           headers: openarray[HttpHeaderTuple]): HttpClientRequest {.
     raises: [Defect] .} =
  var headersTable: HttpTable
  for item in headers:
    headersTable.add(item.key, item.value)

  if "user-agent" notin headersTable:
    discard
  if "host" notin headersTable:
    discard headersTable.hasKeyOrPut("host", ha.hostname)
  if "connection" notin headersTable:
    if HttpClientRequestFlag.CloseConnection in flags:
      discard headersTable.hasKeyOrPut("connection", "close")
    else:
      discard headersTable.hasKeyOrPut("connection", "keep-alive")




proc sendHeaders(conn: HttpClientConnectionRef, headers: HttpTable) {.async.} =
  doAssert(conn.state == HttpClientState.Ready)

proc testClient*(address: string) {.async.} =
  var session = HttpSessionRef.new()
  let ha = session.getAddress(parseUri(address)).tryGet()
  echo ha
  var conn = await session.connect(ha)
  echo conn.state

when isMainModule:
  waitFor testClient("https://www.google.com")

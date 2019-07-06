#                Chronos Test Suite
#            (c) Copyright 2018-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)
import strutils, unittest, os
import httputils
import ../chronos

proc simpleTest(version: HttpVersion): Future[bool] {.async.} =
  var req = HttpRequest.init(MethodGet, "http://www.google.com",
                             version = version)
  var session = HttpSession.init(10)
  var resp = await session.request(req)
  if resp.code == 200:
    var data = await resp.getBody()
    if len(data) > 0:
      result = true

proc testRedirection1(address: TransportAddress,
                      absolute: bool,
                      maxreconnections: int,
                      reconnections: int): Future[bool] {.async.} =
  var baseurl = "http://" & $address & "/1"
  var count = 0
  proc client(server: StreamServer, transp: StreamTransport) {.async.} =
    var url: Uri
    var buffer = newSeq[byte](HttpMaxHeadersSize)
    var length = await transp.readUntil(addr buffer[0], HttpMaxHeadersSize,
                                        HttpHeadersMark)
    var header = buffer.parseRequest()
    if header.success():
      var uri = parseUri(header.uri())
      if absolute:
        var base = parseUri(baseurl)
        url = combine(base, uri)
      else:
        url = uri
      var reqn = parseInt(url.path[1..^1])
      url.path = "/" & $(reqn + 1)

      var answer: string
      if count < reconnections:
        answer = "HTTP/1.0 301 OK\r\nLocation: " & $url &
                 "\r\nContent-Length: 0\r\n\r\n"
        inc(count)
      else:
        answer = "HTTP/1.0 200 OK\r\nContent-Length: 5\r\n\r\nHELLO"

      var res = await transp.write(answer)
      doAssert(res == len(answer))
      await transp.closeWait()

  var server = createStreamServer(address, client, {ReuseAddr})
  server.start()

  var req = HttpRequest.init(MethodGet, baseurl, version = HttpVersion10)
  var session = HttpSession.init(maxreconnections)
  try:
    var resp = await session.request(req)
    if resp.code == 200:
      var data = await resp.getBody()
      if len(data) == 5:
        result = true
  finally:
    server.stop()
    await server.closeWait()

proc testRedirectionOvermax1(address: TransportAddress,
                             absolute: bool,
                             maxreconnections: int): Future[bool] {.async.} =
  try:
    var res = await testRedirection1(address, absolute, maxreconnections,
                                     maxreconnections + 1)
  except HttpProtocolError:
    result = true

proc testRedirection2(address: TransportAddress,
                      absolute: bool,
                      maxreconnections: int,
                      reconnections: int): Future[bool] {.async.} =
  var baseurl = "http://" & $address & "/1"
  var count = 0
  proc client(server: StreamServer, transp: StreamTransport) {.async.} =
    var tobreak = false
    while true:
      var url: Uri
      var buffer = newSeq[byte](HttpMaxHeadersSize)
      var length = await transp.readUntil(addr buffer[0], HttpMaxHeadersSize,
                                          HttpHeadersMark)
      var header = buffer.parseRequest()
      if header.success():
        var uri = parseUri(header.uri())
        if absolute:
          var base = parseUri(baseurl)
          url = combine(base, uri)
        else:
          url = uri
        var reqn = parseInt(url.path[1..^1])
        url.path = "/" & $(reqn + 1)

        var answer: string
        if count < reconnections:
          answer = "HTTP/1.1 301 OK\r\nLocation: " & $url &
                   "\r\nContent-Length: 0\r\n\r\n"
          inc(count)
        else:
          answer = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nHELLO"
          tobreak = true

        var res = await transp.write(answer)
        doAssert(res == len(answer))
        if tobreak:
          break

    await transp.closeWait()

  var server = createStreamServer(address, client, {ReuseAddr})
  server.start()

  var req = HttpRequest.init(MethodGet, baseurl, version = HttpVersion11)
  var session = HttpSession.init(maxreconnections)
  try:
    var resp = await session.request(req)
    if resp.code == 200:
      var data = await resp.getBody()
      if len(data) == 5:
        result = true
  finally:
    server.stop()
    await server.closeWait()

proc testRedirectionOvermax2(address: TransportAddress,
                             absolute: bool,
                             maxreconnections: int): Future[bool] {.async.} =
  try:
    var res = await testRedirection2(address, absolute, maxreconnections,
                                     maxreconnections + 1)
  except HttpProtocolError:
    result = true

suite "Application level HTTP client test suite":
  test "Simple HTTP/1.0 GET http://www.google.com/ test":
    check waitFor(simpleTest(HttpVersion10)) == true
  test "Simple HTTP/1.1 GET http://www.google.com/ test":
    check waitFor(simpleTest(HttpVersion11)) == true
  test "Redirection HTTP/1.0 absolute location test":
    check waitFor(testRedirection1(initTAddress("127.0.0.1:53000"),
                                   true, 10, 5)) == true
  test "Redirection HTTP/1.0 relative location test":
    check waitFor(testRedirection1(initTAddress("127.0.0.1:53000"),
                                   false, 10, 5)) == true
  test "Too many redirections HTTP/1.0 absolute location test":
    check waitFor(testRedirectionOvermax1(initTAddress("127.0.0.1:53000"),
                                          true, 10)) == true
  test "Too many redirections HTTP/1.0 relative location test":
    check waitFor(testRedirectionOvermax1(initTAddress("127.0.0.1:53000"),
                                          false, 10)) == true
  test "Redirection HTTP/1.1 absolute location test":
    check waitFor(testRedirection2(initTAddress("127.0.0.1:53000"),
                                   true, 10, 5)) == true
  test "Redirection HTTP/1.1 relative location test":
    check waitFor(testRedirection2(initTAddress("127.0.0.1:53000"),
                                   false, 10, 5)) == true
  test "Too many redirections HTTP/1.1 absolute location test":
    check waitFor(testRedirectionOvermax2(initTAddress("127.0.0.1:53000"),
                                          true, 10)) == true
  test "Too many redirections HTTP/1.1 relative location test":
    check waitFor(testRedirectionOvermax2(initTAddress("127.0.0.1:53000"),
                                          false, 10)) == true

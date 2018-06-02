#              Asyncdispatch2 Test Suite
#                 (c) Copyright 2018
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

import strutils, unittest
import ../asyncdispatch2

when isMainModule:
  suite "TransportAddress test suite":
    test "initTAddress(string)":
      check $initTAddress("0.0.0.0:0") == "0.0.0.0:0"
      check $initTAddress("255.255.255.255:65535") == "255.255.255.255:65535"
      check $initTAddress("[::]:0") == "[::]:0"
      check $initTAddress("[FFFF:FFFF:FFFF:FFFF:FFFF:FFFF:FFFF:FFFF]:65535") ==
        "[ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff]:65535"
    test "initTAddress(string, Port)":
      check $initTAddress("0.0.0.0", Port(0)) == "0.0.0.0:0"
      check $initTAddress("255.255.255.255", Port(65535)) ==
        "255.255.255.255:65535"
      check $initTAddress("::", Port(0)) == "[::]:0"
      check $initTAddress("FFFF:FFFF:FFFF:FFFF:FFFF:FFFF:FFFF:FFFF",
                          Port(65535)) ==
        "[ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff]:65535"
    test "initTAddress(string, int)":
      check $initTAddress("0.0.0.0", 0) == "0.0.0.0:0"
      check $initTAddress("255.255.255.255", 65535) ==
        "255.255.255.255:65535"
      check $initTAddress("::", 0) == "[::]:0"
      check $initTAddress("FFFF:FFFF:FFFF:FFFF:FFFF:FFFF:FFFF:FFFF", 65535) ==
        "[ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff]:65535"
    test "resolveTAddress(string)":
      var numeric = [
        "0.0.0.0:0",
        "255.0.0.255:54321",
        "128.128.128.128:12345",
        "255.255.255.255:65535",
        "[::]:0",
        "[ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff]:65535",
        "[aaaa:bbbb:cccc:dddd:eeee:ffff::1111]:12345",
        "[aaaa:bbbb:cccc:dddd:eeee:ffff::]:12345",
        "[a:b:c:d:e:f::]:12345",
        "[2222:3333:4444:5555:6666:7777:8888:9999]:56789"
      ]
      var hostnames = [
        "www.google.com:443",
        "www.github.com:443"
      ]
      for item in numeric:
        var taseq = resolveTAddress(item)
        check len(taseq) == 1
        check $taseq[0] == item

      for item in hostnames:
        var taseq = resolveTAddress(item)
        check len(taseq) >= 1

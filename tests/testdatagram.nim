#                Chronos Test Suite
#            (c) Copyright 2018-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)
import std/[strutils, net]
import stew/byteutils
import ".."/chronos/unittest2/asynctests
import ".."/chronos

{.used.}

suite "Datagram Transport test suite":
  teardown:
    checkLeaks()

  const
    TestsCount = 2000
    ClientsCount = 20
    MessagesCount = 20

    m1 = "sendTo(pointer) test (" & $TestsCount & " messages)"
    m2 = "send(pointer) test (" & $TestsCount & " messages)"
    m3 = "sendTo(string) test (" & $TestsCount & " messages)"
    m4 = "send(string) test (" & $TestsCount & " messages)"
    m5 = "sendTo(seq[byte]) test (" & $TestsCount & " messages)"
    m6 = "send(seq[byte]) test (" & $TestsCount & " messages)"
    m7 = "Unbounded multiple clients with messages (" & $ClientsCount &
         " clients x " & $MessagesCount & " messages)"
    m8 = "Bounded multiple clients with messages (" & $ClientsCount &
         " clients x " & $MessagesCount & " messages)"

  type
    DatagramSocketType {.pure.} = enum
      Bound, Unbound

  proc client1(transp: DatagramTransport,
               raddr: TransportAddress): Future[void] {.async: (raises: []).} =
    try:
      var pbytes = transp.getMessage()
      var nbytes = len(pbytes)
      if nbytes > 0:
        var data = newString(nbytes + 1)
        copyMem(addr data[0], addr pbytes[0], nbytes)
        data.setLen(nbytes)
        if data.startsWith("REQUEST"):
          var numstr = data[7..^1]
          var num = parseInt(numstr)
          var ans = "ANSWER" & $num
          await transp.sendTo(raddr, addr ans[0], len(ans))
        else:
          var err = "ERROR"
          await transp.sendTo(raddr, addr err[0], len(err))
      else:
        var counterPtr = cast[ptr int](transp.udata)
        counterPtr[] = -1
        transp.close()
    except CatchableError as exc:
      raiseAssert exc.msg

  proc client2(transp: DatagramTransport,
               raddr: TransportAddress): Future[void] {.async: (raises: []).} =
    try:
      var pbytes = transp.getMessage()
      var nbytes = len(pbytes)
      if nbytes > 0:
        var data = newString(nbytes + 1)
        copyMem(addr data[0], addr pbytes[0], nbytes)
        data.setLen(nbytes)
        if data.startsWith("ANSWER"):
          var counterPtr = cast[ptr int](transp.udata)
          counterPtr[] = counterPtr[] + 1
          if counterPtr[] == TestsCount:
            transp.close()
          else:
            var ta = initTAddress("127.0.0.1:33336")
            var req = "REQUEST" & $counterPtr[]
            await transp.sendTo(ta, addr req[0], len(req))
        else:
          var counterPtr = cast[ptr int](transp.udata)
          counterPtr[] = -1
          transp.close()
      else:
        ## Read operation failed with error
        var counterPtr = cast[ptr int](transp.udata)
        counterPtr[] = -1
        transp.close()
    except CatchableError as exc:
      raiseAssert exc.msg

  proc client3(transp: DatagramTransport,
               raddr: TransportAddress): Future[void] {.async: (raises: []).} =
    try:
      var pbytes = transp.getMessage()
      var nbytes = len(pbytes)
      if nbytes > 0:
        var data = newString(nbytes + 1)
        copyMem(addr data[0], addr pbytes[0], nbytes)
        data.setLen(nbytes)
        if data.startsWith("ANSWER"):
          var counterPtr = cast[ptr int](transp.udata)
          counterPtr[] = counterPtr[] + 1
          if counterPtr[] == TestsCount:
            transp.close()
          else:
            var req = "REQUEST" & $counterPtr[]
            await transp.send(addr req[0], len(req))
        else:
          var counterPtr = cast[ptr int](transp.udata)
          counterPtr[] = -1
          transp.close()
      else:
        ## Read operation failed with error
        var counterPtr = cast[ptr int](transp.udata)
        counterPtr[] = -1
        transp.close()
    except CatchableError as exc:
      raiseAssert exc.msg

  proc client4(transp: DatagramTransport,
               raddr: TransportAddress): Future[void] {.async: (raises: []).} =
    try:
      var pbytes = transp.getMessage()
      var nbytes = len(pbytes)
      if nbytes > 0:
        var data = newString(nbytes + 1)
        copyMem(addr data[0], addr pbytes[0], nbytes)
        data.setLen(nbytes)
        if data.startsWith("ANSWER"):
          var counterPtr = cast[ptr int](transp.udata)
          counterPtr[] = counterPtr[] + 1
          if counterPtr[] == MessagesCount:
            transp.close()
          else:
            var req = "REQUEST" & $counterPtr[]
            await transp.send(addr req[0], len(req))
        else:
          var counterPtr = cast[ptr int](transp.udata)
          counterPtr[] = -1
          transp.close()
      else:
        ## Read operation failed with error
        var counterPtr = cast[ptr int](transp.udata)
        counterPtr[] = -1
        transp.close()
    except CatchableError as exc:
      raiseAssert exc.msg

  proc client5(transp: DatagramTransport,
               raddr: TransportAddress): Future[void] {.async: (raises: []).} =
    try:
      var pbytes = transp.getMessage()
      var nbytes = len(pbytes)
      if nbytes > 0:
        var data = newString(nbytes + 1)
        copyMem(addr data[0], addr pbytes[0], nbytes)
        data.setLen(nbytes)
        if data.startsWith("ANSWER"):
          var counterPtr = cast[ptr int](transp.udata)
          counterPtr[] = counterPtr[] + 1
          if counterPtr[] == MessagesCount:
            transp.close()
          else:
            var req = "REQUEST" & $counterPtr[]
            await transp.sendTo(raddr, addr req[0], len(req))
        else:
          var counterPtr = cast[ptr int](transp.udata)
          counterPtr[] = -1
          transp.close()
      else:
        ## Read operation failed with error
        var counterPtr = cast[ptr int](transp.udata)
        counterPtr[] = -1
        transp.close()
    except CatchableError as exc:
      raiseAssert exc.msg

  proc client6(transp: DatagramTransport,
               raddr: TransportAddress): Future[void] {.async: (raises: []).} =
    try:
      var pbytes = transp.getMessage()
      var nbytes = len(pbytes)
      if nbytes > 0:
        var data = newString(nbytes + 1)
        copyMem(addr data[0], addr pbytes[0], nbytes)
        data.setLen(nbytes)
        if data.startsWith("REQUEST"):
          var numstr = data[7..^1]
          var num = parseInt(numstr)
          var ans = "ANSWER" & $num
          await transp.sendTo(raddr, ans)
        else:
          var err = "ERROR"
          await transp.sendTo(raddr, err)
      else:
        ## Read operation failed with error
        var counterPtr = cast[ptr int](transp.udata)
        counterPtr[] = -1
        transp.close()
    except CatchableError as exc:
      raiseAssert exc.msg

  proc client7(transp: DatagramTransport,
               raddr: TransportAddress): Future[void] {.async: (raises: []).} =
    try:
      var pbytes = transp.getMessage()
      var nbytes = len(pbytes)
      if nbytes > 0:
        var data = newString(nbytes + 1)
        copyMem(addr data[0], addr pbytes[0], nbytes)
        data.setLen(nbytes)
        if data.startsWith("ANSWER"):
          var counterPtr = cast[ptr int](transp.udata)
          counterPtr[] = counterPtr[] + 1
          if counterPtr[] == TestsCount:
            transp.close()
          else:
            var req = "REQUEST" & $counterPtr[]
            await transp.sendTo(raddr, req)
        else:
          var counterPtr = cast[ptr int](transp.udata)
          counterPtr[] = -1
          transp.close()
      else:
        ## Read operation failed with error
        var counterPtr = cast[ptr int](transp.udata)
        counterPtr[] = -1
        transp.close()
    except CatchableError as exc:
      raiseAssert exc.msg

  proc client8(transp: DatagramTransport,
               raddr: TransportAddress): Future[void] {.async: (raises: []).} =
    try:
      var pbytes = transp.getMessage()
      var nbytes = len(pbytes)
      if nbytes > 0:
        var data = newString(nbytes + 1)
        copyMem(addr data[0], addr pbytes[0], nbytes)
        data.setLen(nbytes)
        if data.startsWith("ANSWER"):
          var counterPtr = cast[ptr int](transp.udata)
          counterPtr[] = counterPtr[] + 1
          if counterPtr[] == TestsCount:
            transp.close()
          else:
            var req = "REQUEST" & $counterPtr[]
            await transp.send(req)
        else:
          var counterPtr = cast[ptr int](transp.udata)
          counterPtr[] = -1
          transp.close()
      else:
        ## Read operation failed with error
        var counterPtr = cast[ptr int](transp.udata)
        counterPtr[] = -1
        transp.close()
    except CatchableError as exc:
      raiseAssert exc.msg

  proc client9(transp: DatagramTransport,
               raddr: TransportAddress): Future[void] {.async: (raises: []).} =
    try:
      var pbytes = transp.getMessage()
      var nbytes = len(pbytes)
      if nbytes > 0:
        var data = newString(nbytes + 1)
        copyMem(addr data[0], addr pbytes[0], nbytes)
        data.setLen(nbytes)
        if data.startsWith("REQUEST"):
          var numstr = data[7..^1]
          var num = parseInt(numstr)
          var ans = "ANSWER" & $num
          var ansseq = newSeq[byte](len(ans))
          copyMem(addr ansseq[0], addr ans[0], len(ans))
          await transp.sendTo(raddr, ansseq)
        else:
          var err = "ERROR"
          var errseq = newSeq[byte](len(err))
          copyMem(addr errseq[0], addr err[0], len(err))
          await transp.sendTo(raddr, errseq)
      else:
        ## Read operation failed with error
        var counterPtr = cast[ptr int](transp.udata)
        counterPtr[] = -1
        transp.close()
    except CatchableError as exc:
      raiseAssert exc.msg

  proc client10(transp: DatagramTransport,
                raddr: TransportAddress): Future[void] {.async: (raises: []).} =
    try:
      var pbytes = transp.getMessage()
      var nbytes = len(pbytes)
      if nbytes > 0:
        var data = newString(nbytes + 1)
        copyMem(addr data[0], addr pbytes[0], nbytes)
        data.setLen(nbytes)
        if data.startsWith("ANSWER"):
          var counterPtr = cast[ptr int](transp.udata)
          counterPtr[] = counterPtr[] + 1
          if counterPtr[] == TestsCount:
            transp.close()
          else:
            var req = "REQUEST" & $counterPtr[]
            var reqseq = newSeq[byte](len(req))
            copyMem(addr reqseq[0], addr req[0], len(req))
            await transp.sendTo(raddr, reqseq)
        else:
          var counterPtr = cast[ptr int](transp.udata)
          counterPtr[] = -1
          transp.close()
      else:
        ## Read operation failed with error
        var counterPtr = cast[ptr int](transp.udata)
        counterPtr[] = -1
        transp.close()
    except CatchableError as exc:
      raiseAssert exc.msg

  proc client11(transp: DatagramTransport,
                raddr: TransportAddress): Future[void] {.async: (raises: []).} =
    try:
      var pbytes = transp.getMessage()
      var nbytes = len(pbytes)
      if nbytes > 0:
        var data = newString(nbytes + 1)
        copyMem(addr data[0], addr pbytes[0], nbytes)
        data.setLen(nbytes)
        if data.startsWith("ANSWER"):
          var counterPtr = cast[ptr int](transp.udata)
          counterPtr[] = counterPtr[] + 1
          if counterPtr[] == TestsCount:
            transp.close()
          else:
            var req = "REQUEST" & $counterPtr[]
            var reqseq = newSeq[byte](len(req))
            copyMem(addr reqseq[0], addr req[0], len(req))
            await transp.send(reqseq)
        else:
          var counterPtr = cast[ptr int](transp.udata)
          counterPtr[] = -1
          transp.close()
      else:
        ## Read operation failed with error
        var counterPtr = cast[ptr int](transp.udata)
        counterPtr[] = -1
        transp.close()
    except CatchableError as exc:
      raiseAssert exc.msg

  proc testPointerSendTo(): Future[int] {.async.} =
    ## sendTo(pointer) test
    var ta = initTAddress("127.0.0.1:33336")
    var counter = 0
    var dgram1 = newDatagramTransport(client1, udata = addr counter, local = ta)
    var dgram2 = newDatagramTransport(client2, udata = addr counter)
    var data = "REQUEST0"
    await dgram2.sendTo(ta, addr data[0], len(data))
    await dgram2.join()
    dgram1.close()
    await dgram1.join()
    result = counter

  proc testPointerSend(): Future[int] {.async.} =
    ## send(pointer) test
    var ta = initTAddress("127.0.0.1:33337")
    var counter = 0
    var dgram1 = newDatagramTransport(client1, udata = addr counter, local = ta)
    var dgram2 = newDatagramTransport(client3, udata = addr counter, remote = ta)
    var data = "REQUEST0"
    await dgram2.send(addr data[0], len(data))
    await dgram2.join()
    dgram1.close()
    await dgram1.join()
    result = counter

  proc testStringSendTo(): Future[int] {.async.} =
    ## sendTo(string) test
    var ta = initTAddress("127.0.0.1:33338")
    var counter = 0
    var dgram1 = newDatagramTransport(client6, udata = addr counter, local = ta)
    var dgram2 = newDatagramTransport(client7, udata = addr counter)
    var data = "REQUEST0"
    await dgram2.sendTo(ta, data)
    await dgram2.join()
    dgram1.close()
    await dgram1.join()
    result = counter

  proc testStringSend(): Future[int] {.async.} =
    ## send(string) test
    var ta = initTAddress("127.0.0.1:33339")
    var counter = 0
    var dgram1 = newDatagramTransport(client6, udata = addr counter, local = ta)
    var dgram2 = newDatagramTransport(client8, udata = addr counter, remote = ta)
    var data = "REQUEST0"
    await dgram2.send(data)
    await dgram2.join()
    dgram1.close()
    await dgram1.join()
    result = counter

  proc testSeqSendTo(): Future[int] {.async.} =
    ## sendTo(string) test
    var ta = initTAddress("127.0.0.1:33340")
    var counter = 0
    var dgram1 = newDatagramTransport(client9, udata = addr counter, local = ta)
    var dgram2 = newDatagramTransport(client10, udata = addr counter)
    var data = "REQUEST0"
    var dataseq = newSeq[byte](len(data))
    copyMem(addr dataseq[0], addr data[0], len(data))
    await dgram2.sendTo(ta, dataseq)
    await dgram2.join()
    dgram1.close()
    await dgram1.join()
    result = counter

  proc testSeqSend(): Future[int] {.async.} =
    ## send(seq) test
    var ta = initTAddress("127.0.0.1:33341")
    var counter = 0
    var dgram1 = newDatagramTransport(client9, udata = addr counter, local = ta)
    var dgram2 = newDatagramTransport(client11, udata = addr counter, remote = ta)
    var data = "REQUEST0"
    var dataseq = newSeq[byte](len(data))
    copyMem(addr dataseq[0], addr data[0], len(data))
    await dgram2.send(data)
    await dgram2.join()
    dgram1.close()
    await dgram1.join()
    result = counter

  #

  proc waitAll(futs: seq[Future[void]]): Future[void] =
    var counter = len(futs)
    var retFuture = newFuture[void]("waitAll")
    proc cb(udata: pointer) =
      dec(counter)
      if counter == 0:
        retFuture.complete()
    for fut in futs:
      fut.addCallback(cb)
    return retFuture

  proc test3(bounded: bool): Future[int] {.async.} =
    var ta: TransportAddress
    if bounded:
      ta = initTAddress("127.0.0.1:33240")
    else:
      ta = initTAddress("127.0.0.1:33241")
    var counter = 0
    var dgram1 = newDatagramTransport(client1, udata = addr counter, local = ta)
    var clients = newSeq[Future[void]](ClientsCount)
    var grams = newSeq[DatagramTransport](ClientsCount)
    var counters = newSeq[int](ClientsCount)
    for i in 0..<ClientsCount:
      var data = "REQUEST0"
      if bounded:
        grams[i] = newDatagramTransport(client4, udata = addr counters[i],
                                        remote = ta)
        await grams[i].send(addr data[0], len(data))
      else:
        grams[i] = newDatagramTransport(client5, udata = addr counters[i])
        await grams[i].sendTo(ta, addr data[0], len(data))
      clients[i] = grams[i].join()

    await waitAll(clients)
    dgram1.close()
    await dgram1.join()
    result = 0
    for i in 0..<ClientsCount:
      result += counters[i]

  proc testConnReset(): Future[bool] {.async.} =
    var ta = initTAddress("127.0.0.1:0")
    var counter = 0
    proc clientMark(transp: DatagramTransport,
                    raddr: TransportAddress): Future[void] {.async: (raises: []).} =
      counter = 1
      transp.close()
    var dgram1 = newDatagramTransport(client1, local = ta)
    var localta = dgram1.localAddress()
    dgram1.close()
    await dgram1.join()
    var dgram2 = newDatagramTransport(clientMark)
    var data = "MESSAGE"
    asyncSpawn dgram2.sendTo(localta, data)
    await sleepAsync(2000.milliseconds)
    result = (counter == 0)
    dgram2.close()
    await dgram2.join()

  proc testTransportClose(): Future[bool] {.async.} =
    var ta = initTAddress("127.0.0.1:45000")
    proc clientMark(transp: DatagramTransport,
                    raddr: TransportAddress): Future[void] {.async: (raises: []).} =
      discard
    var dgram = newDatagramTransport(clientMark, local = ta)
    dgram.close()
    try:
      await wait(dgram.join(), 1.seconds)
      result = true
    except CatchableError:
      discard

  proc testBroadcast(): Future[int] {.async.} =
    const expectMessage = "BROADCAST MESSAGE"
    var ta1 = initTAddress("0.0.0.0:45010")
    var bta = initTAddress("255.255.255.255:45010")
    var res = 0
    proc clientMark(transp: DatagramTransport,
                     raddr: TransportAddress): Future[void] {.async: (raises: []).} =
      try:
        var bmsg = transp.getMessage()
        var smsg = string.fromBytes(bmsg)
        if smsg == expectMessage:
          inc(res)
        transp.close()
      except CatchableError as exc:
        raiseAssert exc.msg
    var dgram1 = newDatagramTransport(clientMark, local = ta1,
                                      flags = {Broadcast}, ttl = 2)
    await dgram1.sendTo(bta, expectMessage)
    await wait(dgram1.join(), 5.seconds)
    result = res

  proc testAnyAddress(): Future[int] {.async.} =
    var expectStr = "ANYADDRESS MESSAGE"
    var expectSeq = expectStr.toBytes()
    let ta = initTAddress("0.0.0.0:0")
    var res = 0
    var event = newAsyncEvent()

    proc clientMark1(transp: DatagramTransport,
                     raddr: TransportAddress): Future[void] {.async: (raises: []).} =
      try:
        var bmsg = transp.getMessage()
        var smsg = string.fromBytes(bmsg)
        if smsg == expectStr:
          inc(res)
        event.fire()
      except CatchableError as exc:
        raiseAssert exc.msg


    proc clientMark2(transp: DatagramTransport,
                     raddr: TransportAddress): Future[void] {.async: (raises: []).} =
      discard

    var dgram1 = newDatagramTransport(clientMark1, local = ta)
    let la = dgram1.localAddress()
    var dgram2 = newDatagramTransport(clientMark2)
    var dgram3 = newDatagramTransport(clientMark2,
                                      remote = la)
    await dgram2.sendTo(la, addr expectStr[0], len(expectStr))
    await event.wait()
    event.clear()
    await dgram2.sendTo(la, expectStr)
    await event.wait()
    event.clear()
    await dgram2.sendTo(la, expectSeq)
    await event.wait()
    event.clear()
    await dgram3.send(addr expectStr[0], len(expectStr))
    await event.wait()
    event.clear()
    await dgram3.send(expectStr)
    await event.wait()
    event.clear()
    await dgram3.send(expectSeq)
    await event.wait()
    event.clear()

    await dgram1.closeWait()
    await dgram2.closeWait()
    await dgram3.closeWait()

    result = res

  proc performDualstackTest(
         sstack: DualStackType, saddr: TransportAddress,
         cstack: DualStackType, caddr: TransportAddress
       ): Future[bool] {.async.} =
    var
      expectStr = "ANYADDRESS MESSAGE"
      event = newAsyncEvent()
      res = 0

    proc process1(transp: DatagramTransport,
                  raddr: TransportAddress): Future[void] {.async: (raises: []).} =
      try:
        var bmsg = transp.getMessage()
        var smsg = string.fromBytes(bmsg)
        if smsg == expectStr:
          inc(res)
        event.fire()
      except CatchableError as exc:
        raiseAssert exc.msg

    proc process2(transp: DatagramTransport,
                  raddr: TransportAddress): Future[void] {.async: (raises: []).} =
      discard

    let
      sdgram = newDatagramTransport(process1, local = saddr,
                                    dualstack = sstack)
      localcaddr =
        if caddr.family == AddressFamily.IPv4:
          AnyAddress
        else:
          AnyAddress6

      cdgram = newDatagramTransport(process2, local = localcaddr,
                                    dualstack = cstack)

    var address = caddr
    address.port = sdgram.localAddress().port

    try:
      await cdgram.sendTo(address, addr expectStr[0], len(expectStr))
    except CatchableError:
      discard
    try:
      await event.wait().wait(500.milliseconds)
    except CatchableError:
      discard

    await allFutures(sdgram.closeWait(), cdgram.closeWait())
    res == 1

  proc performAutoAddressTest(port: Port,
                              family: AddressFamily): Future[bool] {.async.} =
    var
      expectRequest1 = "AUTO REQUEST1"
      expectRequest2 = "AUTO REQUEST2"
      expectResponse = "AUTO RESPONSE"
      mappedResponse = "MAPPED RESPONSE"
      event = newAsyncEvent()
      event2 = newAsyncEvent()
      res = 0

    proc process1(transp: DatagramTransport,
                  raddr: TransportAddress): Future[void] {.
         async: (raises: []).} =
      try:
        var
          bmsg = transp.getMessage()
          smsg = string.fromBytes(bmsg)
        if smsg == expectRequest1:
          inc(res)
          await noCancel transp.sendTo(
            raddr, addr expectResponse[0], len(expectResponse))
        elif smsg == expectRequest2:
          inc(res)
          await noCancel transp.sendTo(
            raddr, addr mappedResponse[0], len(mappedResponse))
      except TransportError as exc:
        raiseAssert exc.msg
      except CancelledError as exc:
        raiseAssert exc.msg

    proc process2(transp: DatagramTransport,
                  raddr: TransportAddress): Future[void] {.
         async: (raises: []).} =
      try:
        var
          bmsg = transp.getMessage()
          smsg = string.fromBytes(bmsg)
        if smsg == expectResponse:
          inc(res)
        event.fire()
      except TransportError as exc:
        raiseAssert exc.msg
      except CancelledError as exc:
        raiseAssert exc.msg

    proc process3(transp: DatagramTransport,
                  raddr: TransportAddress): Future[void] {.
         async: (raises: []).} =
      try:
        var
          bmsg = transp.getMessage()
          smsg = string.fromBytes(bmsg)
        if smsg == mappedResponse:
          inc(res)
        event2.fire()
      except TransportError as exc:
        raiseAssert exc.msg
      except CancelledError as exc:
        raiseAssert exc.msg

    let sdgram =
      block:
        var res: DatagramTransport
        var currentPort = port
        for i in 0 ..< 10:
          res =
            try:
              newDatagramTransport(process1, currentPort,
                                   flags = {ServerFlags.ReusePort})
            except TransportOsError:
              echo "Unable to create transport on port ", currentPort
              currentPort = Port(uint16(currentPort) + 1'u16)
              nil
          if not(isNil(res)):
            break
        doAssert(not(isNil(res)), "Unable to create transport, giving up")
        res

    var
      address =
        case family
        of AddressFamily.IPv4:
          initTAddress("127.0.0.1:0")
        of AddressFamily.IPv6:
          initTAddress("::1:0")
        of AddressFamily.Unix, AddressFamily.None:
          raiseAssert "Not allowed"

    let
      cdgram =
        case family
        of AddressFamily.IPv4:
          newDatagramTransport(process2, local = address)
        of AddressFamily.IPv6:
          newDatagramTransport6(process2, local = address)
        of AddressFamily.Unix, AddressFamily.None:
          raiseAssert "Not allowed"

    address.port = sdgram.localAddress().port

    try:
      await noCancel cdgram.sendTo(
        address, addr expectRequest1[0], len(expectRequest1))
    except TransportError:
      discard

    if family == AddressFamily.IPv6:
      var remote = initTAddress("127.0.0.1:0")
      remote.port = sdgram.localAddress().port
      let wtransp =
        newDatagramTransport(process3, local = initTAddress("0.0.0.0:0"))
      try:
        await noCancel wtransp.sendTo(
          remote, addr expectRequest2[0], len(expectRequest2))
      except TransportError as exc:
        raiseAssert "Got transport error, reason = " & $exc.msg

      try:
        await event2.wait().wait(1.seconds)
      except CatchableError:
        discard

      await wtransp.closeWait()

    try:
      await event.wait().wait(1.seconds)
    except CatchableError:
      discard

    await allFutures(sdgram.closeWait(), cdgram.closeWait())

    if family == AddressFamily.IPv4:
      res == 2
    else:
      res == 4

  proc performAutoAddressTest2(
    address1: Opt[IpAddress],
    address2: Opt[IpAddress],
    port: Port,
    sendType: AddressFamily,
    boundType: DatagramSocketType
  ): Future[bool] {.async.} =
    let
      expectRequest = "TEST REQUEST"
      expectResponse = "TEST RESPONSE"
      event = newAsyncEvent()
    var res = 0

    proc process1(transp: DatagramTransport,
                  raddr: TransportAddress): Future[void] {.
         async: (raises: []).} =
      if raddr.family != sendType:
        raiseAssert "Incorrect address family received [" & $raddr &
                    "], expected [" & $sendType & "]"
      try:
        let
          bmsg = transp.getMessage()
          smsg = string.fromBytes(bmsg)
        if smsg == expectRequest:
          inc(res)
        await noCancel transp.sendTo(
          raddr, unsafeAddr expectResponse[0], len(expectResponse))
      except TransportError as exc:
        raiseAssert exc.msg
      except CancelledError as exc:
        raiseAssert exc.msg

    proc process2(transp: DatagramTransport,
                  raddr: TransportAddress): Future[void] {.
         async: (raises: []).} =
      if raddr.family != sendType:
        raiseAssert "Incorrect address family received [" & $raddr &
                    "], expected [" & $sendType & "]"
      try:
        let
          bmsg = transp.getMessage()
          smsg = string.fromBytes(bmsg)
        if smsg == expectResponse:
          inc(res)
        event.fire()
      except TransportError as exc:
        raiseAssert exc.msg
      except CancelledError as exc:
        raiseAssert exc.msg

    let
      serverFlags = {ServerFlags.ReuseAddr}
      server = newDatagramTransport(process1, flags = serverFlags,
                                    local = address1, localPort = port)
      serverAddr = server.localAddress()
      serverPort = serverAddr.port
      remoteAddress =
        case sendType
        of AddressFamily.IPv4:
          var res = initTAddress("127.0.0.1:0")
          res.port = serverPort
          res
        of AddressFamily.IPv6:
          var res = initTAddress("[::1]:0")
          res.port = serverPort
          res
        else:
          raiseAssert "Incorrect sending type"
      remoteIpAddress = Opt.some(remoteAddress.toIpAddress())
      client =
        case boundType
        of DatagramSocketType.Bound:
          newDatagramTransport(process2,
                               localPort = Port(0), remotePort = serverPort,
                               local = address2, remote = remoteIpAddress)
        of DatagramSocketType.Unbound:
          newDatagramTransport(process2,
                               localPort = Port(0), remotePort = Port(0),
                               local = address2)

    try:
      case boundType
      of DatagramSocketType.Bound:
        await noCancel client.send(
          unsafeAddr expectRequest[0], len(expectRequest))
      of DatagramSocketType.Unbound:
        await noCancel client.sendTo(remoteAddress,
          unsafeAddr expectRequest[0], len(expectRequest))
    except TransportError as exc:
      raiseAssert "Could not send datagram to remote peer, reason = " & $exc.msg

    try:
      await event.wait().wait(1.seconds)
    except CatchableError:
      discard

    await allFutures(server.closeWait(), client.closeWait())

    res == 2

  test "close(transport) test":
    check waitFor(testTransportClose()) == true
  test m1:
    check waitFor(testPointerSendTo()) == TestsCount
  test m2:
    check waitFor(testPointerSend()) == TestsCount
  test m3:
    check waitFor(testStringSendTo()) == TestsCount
  test m4:
    check waitFor(testStringSend()) == TestsCount
  test m5:
    check waitFor(testSeqSendTo()) == TestsCount
  test m6:
    check waitFor(testSeqSend()) == TestsCount
  test m7:
    check waitFor(test3(false)) == ClientsCount * MessagesCount
  test m8:
    check waitFor(test3(true)) == ClientsCount * MessagesCount
  test "Datagram connection reset test":
    check waitFor(testConnReset()) == true
  test "Broadcast test":
    check waitFor(testBroadcast()) == 1
  test "0.0.0.0/::0 (INADDR_ANY) test":
    check waitFor(testAnyAddress()) == 6
  asyncTest "[IP] getDomain(socket) [SOCK_DGRAM] test":
    if isAvailable(AddressFamily.IPv4) and isAvailable(AddressFamily.IPv6):
      block:
        let res = createAsyncSocket2(Domain.AF_INET, SockType.SOCK_DGRAM,
                                     Protocol.IPPROTO_UDP)
        check res.isOk()
        let fres = getDomain(res.get())
        check fres.isOk()
        discard unregisterAndCloseFd(res.get())
        check fres.get() == AddressFamily.IPv4

      block:
        let res = createAsyncSocket2(Domain.AF_INET6, SockType.SOCK_DGRAM,
                                     Protocol.IPPROTO_UDP)
        check res.isOk()
        let fres = getDomain(res.get())
        check fres.isOk()
        discard unregisterAndCloseFd(res.get())
        check fres.get() == AddressFamily.IPv6

      when not(defined(windows)):
        block:
          let res = createAsyncSocket2(Domain.AF_UNIX, SockType.SOCK_DGRAM,
                                       Protocol.IPPROTO_IP)
          check res.isOk()
          let fres = getDomain(res.get())
          check fres.isOk()
          discard unregisterAndCloseFd(res.get())
          check fres.get() == AddressFamily.Unix
    else:
      skip()
  asyncTest "[IP] DualStack [UDP] server [DualStackType.Auto] test":
    if isAvailable(AddressFamily.IPv4) and isAvailable(AddressFamily.IPv6):
      let serverAddress = initTAddress("[::]:0")
      check:
        (await performDualstackTest(
           DualStackType.Auto, serverAddress,
           DualStackType.Auto, initTAddress("127.0.0.1:0"))) == true
      check:
        (await performDualstackTest(
           DualStackType.Auto, serverAddress,
           DualStackType.Auto, initTAddress("127.0.0.1:0").toIPv6())) == true
      check:
        (await performDualstackTest(
           DualStackType.Auto, serverAddress,
           DualStackType.Auto, initTAddress("[::1]:0"))) == true
    else:
      skip()
  asyncTest "[IP] DualStack [UDP] server [DualStackType.Enabled] test":
    if isAvailable(AddressFamily.IPv4) and isAvailable(AddressFamily.IPv6):
      let serverAddress = initTAddress("[::]:0")
      check:
        (await performDualstackTest(
           DualStackType.Enabled, serverAddress,
           DualStackType.Auto, initTAddress("127.0.0.1:0"))) == true
        (await performDualstackTest(
           DualStackType.Enabled, serverAddress,
           DualStackType.Auto, initTAddress("127.0.0.1:0").toIPv6())) == true
        (await performDualstackTest(
           DualStackType.Enabled, serverAddress,
           DualStackType.Auto, initTAddress("[::1]:0"))) == true
    else:
      skip()
  asyncTest "[IP] DualStack [UDP] server [DualStackType.Disabled] test":
    if isAvailable(AddressFamily.IPv4) and isAvailable(AddressFamily.IPv6):
      let serverAddress = initTAddress("[::]:0")
      check:
        (await performDualstackTest(
           DualStackType.Disabled, serverAddress,
           DualStackType.Auto, initTAddress("127.0.0.1:0"))) == false
        (await performDualstackTest(
           DualStackType.Disabled, serverAddress,
           DualStackType.Auto, initTAddress("127.0.0.1:0").toIPv6())) == false
        (await performDualstackTest(
           DualStackType.Disabled, serverAddress,
           DualStackType.Auto, initTAddress("[::1]:0"))) == true
    else:
      skip()
  asyncTest "[IP] Auto-address constructor test (*:0)":
    if isAvailable(AddressFamily.IPv6):
      check:
        (await performAutoAddressTest(Port(0), AddressFamily.IPv6)) == true
      # If IPv6 is available newAutoDatagramTransport should bind to `::` - this
      # means that we should be able to connect to it via IPV4_MAPPED address,
      # but only when IPv4 is also available.
      if isAvailable(AddressFamily.IPv4):
        check:
          (await performAutoAddressTest(Port(0), AddressFamily.IPv4)) == true
    else:
      # If IPv6 is not available newAutoDatagramTransport should bind to
      # `0.0.0.0` - this means we should be able to connect to it via IPv4
      # address.
      if isAvailable(AddressFamily.IPv4):
        check:
          (await performAutoAddressTest(Port(0), AddressFamily.IPv4)) == true
  asyncTest "[IP] Auto-address constructor test (*:30231)":
    if isAvailable(AddressFamily.IPv6):
      check:
        (await performAutoAddressTest(Port(30231), AddressFamily.IPv6)) == true
      # If IPv6 is available newAutoDatagramTransport should bind to `::` - this
      # means that we should be able to connect to it via IPV4_MAPPED address,
      # but only when IPv4 is also available.
      if isAvailable(AddressFamily.IPv4):
        check:
          (await performAutoAddressTest(Port(30231), AddressFamily.IPv4)) ==
            true
    else:
      # If IPv6 is not available newAutoDatagramTransport should bind to
      # `0.0.0.0` - this means we should be able to connect to it via IPv4
      # address.
      if isAvailable(AddressFamily.IPv4):
        check:
          (await performAutoAddressTest(Port(30231), AddressFamily.IPv4)) ==
            true

  for socketType in DatagramSocketType:
    for portNumber in [Port(0), Port(30231)]:
      asyncTest "[IP] IPv6 mapping test (" & $socketType &
                "/auto-auto:" & $int(portNumber) & ")":
        if isAvailable(AddressFamily.IPv6):
          let
            address1 = Opt.none(IpAddress)
            address2 = Opt.none(IpAddress)

          check:
            (await performAutoAddressTest2(
              address1, address2, portNumber, AddressFamily.IPv4, socketType))
            (await performAutoAddressTest2(
              address1, address2, portNumber, AddressFamily.IPv6, socketType))
        else:
          skip()

      asyncTest "[IP] IPv6 mapping test (" & $socketType &
                "/auto-ipv6:" & $int(portNumber) & ")":
        if isAvailable(AddressFamily.IPv6):
          let
            address1 = Opt.none(IpAddress)
            address2 = Opt.some(initTAddress("[::1]:0").toIpAddress())
          check:
            (await performAutoAddressTest2(
              address1, address2, portNumber, AddressFamily.IPv6, socketType))
        else:
          skip()

      asyncTest "[IP] IPv6 mapping test (" & $socketType &
                "/auto-ipv4:" & $int(portNumber) & ")":
        if isAvailable(AddressFamily.IPv6):
          let
            address1 = Opt.none(IpAddress)
            address2 = Opt.some(initTAddress("127.0.0.1:0").toIpAddress())
          check:
            (await performAutoAddressTest2(address1, address2, portNumber,
                                           AddressFamily.IPv4, socketType))
        else:
          skip()

      asyncTest "[IP] IPv6 mapping test (" & $socketType &
                "/ipv6-auto:" & $int(portNumber) & ")":
        if isAvailable(AddressFamily.IPv6):
          let
            address1 = Opt.some(initTAddress("[::1]:0").toIpAddress())
            address2 = Opt.none(IpAddress)
          check:
            (await performAutoAddressTest2(address1, address2, portNumber,
                                           AddressFamily.IPv6, socketType))
        else:
          skip()

      asyncTest "[IP] IPv6 mapping test (" & $socketType &
                "/ipv4-auto:" & $int(portNumber) & ")":
        if isAvailable(AddressFamily.IPv6):
          let
            address1 = Opt.some(initTAddress("127.0.0.1:0").toIpAddress())
            address2 = Opt.none(IpAddress)
          check:
            (await performAutoAddressTest2(address1, address2, portNumber,
                                           AddressFamily.IPv4, socketType))
        else:
          skip()

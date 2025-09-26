#                Chronos Test Suite
#            (c) Copyright 2018-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)
import unittest2
import ../chronos, ../chronos/unittest2/asynctests

{.used.}

suite "WaitGroup":
  teardown:
    checkLeaks()

  asyncTest "negative count":
    expect AssertionDefect:
        discard newWaitGroup(-1)

  asyncTest "zero count":
    let wg = newWaitGroup(0)
    check wg.wait().finished

  asyncTest "zero count - done no effect":
    let wg = newWaitGroup(0)
    check wg.wait().finished
    
    wg.done()
    check wg.wait().finished

  asyncTest "count down to finish":
    let wg = newWaitGroup(3)
    
    wg.done()
    check not wg.wait().finished
    wg.done()
    check not wg.wait().finished
    wg.done()
    check wg.wait().finished

  asyncTest "async count down to finish":
    const count = 30
    let wg = newWaitGroup(count)
    
    proc countDown() {.async.} =
      await sleepAsync(5.millis)
      wg.done()
    for i in 0 ..< count:
      asyncSpawn countDown()

    check not wg.wait().finished
    check await wg.wait().withTimeout(15.millis)
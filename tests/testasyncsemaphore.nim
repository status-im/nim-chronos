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

suite "AsyncSemaphore":
  teardown:
    checkLeaks()

  asyncTest "default size":
    let sema = newAsyncSemaphore()
    check sema.availableSlots == 1

  asyncTest "custom size":
    let sema = newAsyncSemaphore(3)
    check sema.availableSlots == 3

  asyncTest "invalid size":
    expect AssertionDefect:
      discard newAsyncSemaphore(0)

  asyncTest "should acquire":
    let sema = newAsyncSemaphore(3)

    await sema.acquire()
    check sema.availableSlots == 2
    await sema.acquire()
    check sema.availableSlots == 1
    await sema.acquire()
    check sema.availableSlots == 0

  asyncTest "should release":
    let sema = newAsyncSemaphore(3)

    await sema.acquire()
    await sema.acquire()
    await sema.acquire()
    
    sema.release()
    check sema.availableSlots == 1
    sema.release()
    check sema.availableSlots == 2
    sema.release()
    check sema.availableSlots == 3

  asyncTest "initial release":
    let sema = newAsyncSemaphore(3)

    expect AsyncSemaphoreError: # should not release
      sema.release() 

  asyncTest "double release":
    let sema = newAsyncSemaphore(3)
    
    await sema.acquire()
    sema.release()
    expect AsyncSemaphoreError: # should not release
      sema.release() 

  asyncTest "should queue acquire":
    let sema = newAsyncSemaphore(1)

    await sema.acquire()
    let fut = sema.acquire()

    check sema.availableSlots == 0
    sema.release()
    sema.release()

    await fut
    check fut.finished()

  asyncTest "should tryAcquire":
    let sema = newAsyncSemaphore(1)
    await sema.acquire()
    check sema.tryAcquire() == false

  asyncTest "should tryAcquire and acquire":
    let sema = newAsyncSemaphore(4)
    check sema.tryAcquire() == true
    check sema.tryAcquire() == true
    check sema.tryAcquire() == true
    check sema.tryAcquire() == true
    check sema.availableSlots == 0

    let fut = sema.acquire()
    check fut.finished == false
    check sema.availableSlots == 0

    sema.release()
    sema.release()
    sema.release()
    sema.release()
    sema.release()

    check fut.finished == true
    check sema.availableSlots == 4

  asyncTest "should cancel sequential semaphore slot":
    let sema = newAsyncSemaphore(1)

    await sema.acquire()

    let
      tmp = sema.acquire()
      tmp2 = sema.acquire()
    check:
      not tmp.finished()
      not tmp2.finished()

    tmp.cancel()
    sema.release()

    check tmp2.finished()

    sema.release()

    check await sema.acquire().withTimeout(10.millis)

  asyncTest "should handle out of order cancellations":
    let sema = newAsyncSemaphore(1)

    await sema.acquire() # 1st acquire
    let tmp1 = sema.acquire() # 2nd acquire
    check not tmp1.finished()

    let tmp2 = sema.acquire() # 3rd acquire
    check not tmp2.finished()

    let tmp3 = sema.acquire() # 4th acquire
    check not tmp3.finished()

    # up to this point, we've called acquire 4 times
    tmp1.cancel() # 1st release (implicit)
    tmp2.cancel() # 2nd release (implicit)

    check not tmp3.finished() # check that we didn't release the wrong slot

    sema.release() # 3rd release (explicit)
    check tmp3.finished()

    sema.release() # 4th release
    check await sema.acquire().withTimeout(10.millis)

  asyncTest "should properly handle timeouts and cancellations":
    let sema = newAsyncSemaphore(1)

    await sema.acquire()
    check not (await sema.acquire().withTimeout(1.millis))
      # should not acquire but cancel
    sema.release()

    check await sema.acquire().withTimeout(10.millis)
    

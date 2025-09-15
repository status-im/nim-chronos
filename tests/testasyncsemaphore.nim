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
  asyncTest "should acquire":
    let sema = newAsyncSemaphore(3)

    await sema.acquire()
    await sema.acquire()
    await sema.acquire()

    check sema.count == 0

  asyncTest "should release":
    let sema = newAsyncSemaphore(3)

    await sema.acquire()
    await sema.acquire()
    await sema.acquire()

    check sema.count == 0
    sema.release()
    sema.release()
    sema.release()
    check sema.count == 3

  asyncTest "should queue acquire":
    let sema = newAsyncSemaphore(1)

    await sema.acquire()
    let fut = sema.acquire()

    check sema.count == 0
    sema.release()
    sema.release()
    check sema.count == 1

    await sleepAsync(10.millis)
    check fut.finished()

  asyncTest "should keep count == size":
    let sema = newAsyncSemaphore(1)
    sema.release()
    sema.release()
    sema.release()
    check sema.count == 1

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
    check sema.count == 0

    let fut = sema.acquire()
    check fut.finished == false
    check sema.count == 0

    sema.release()
    sema.release()
    sema.release()
    sema.release()
    sema.release()

    check fut.finished == true
    check sema.count == 4

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

  asyncTest "should handle forceAcquire properly":
    let sema = newAsyncSemaphore(1)

    await sema.acquire()
    check not (await sema.acquire().withTimeout(1.millis))
      # should not acquire but cancel

    let
      fut1 = sema.acquire()
      fut2 = sema.acquire()

    sema.forceAcquire()
    sema.release()

    await fut1 or fut2 or sleepAsync(1.millis)
    check:
      fut1.finished()
      not fut2.finished()

    sema.release()
    await fut1 or fut2 or sleepAsync(1.millis)
    check:
      fut1.finished()
      fut2.finished()

    sema.forceAcquire()
    sema.forceAcquire()

    let
      fut3 = sema.acquire()
      fut4 = sema.acquire()
      fut5 = sema.acquire()
    sema.release()
    sema.release()
    await sleepAsync(1.millis)
    check:
      fut3.finished()
      fut4.finished()
      not fut5.finished()

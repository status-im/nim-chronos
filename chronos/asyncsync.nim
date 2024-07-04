#
#            Chronos synchronization primitives
#
#           (c) Copyright 2018-Present Eugene Kabanov
#  (c) Copyright 2018-Present Status Research & Development GmbH
#
#                Licensed under either of
#    Apache License, version 2.0, (LICENSE-APACHEv2)
#                MIT license (LICENSE-MIT)

## This module implements some core synchronization primitives.

{.push raises: [].}

import std/[sequtils, math, deques, tables, typetraits]
import ./asyncloop
export asyncloop

type
  AsyncLock* = ref object of RootRef
    ## A primitive lock is a synchronization primitive that is not owned by
    ## a particular coroutine when locked. A primitive lock is in one of two
    ## states, ``locked`` or ``unlocked``.
    ##
    ## When more than one coroutine is blocked in ``acquire()`` waiting for
    ## the state to turn to unlocked, only one coroutine proceeds when a
    ## ``release()`` call resets the state to unlocked; first coroutine which
    ## is blocked in ``acquire()`` is being processed.
    locked: bool
    acquired: bool
    waiters: seq[Future[void].Raising([CancelledError])]

  AsyncEvent* = ref object of RootRef
    ## A primitive event object.
    ##
    ## An event manages a flag that can be set to `true` with the ``fire()``
    ## procedure and reset to `false` with the ``clear()`` procedure.
    ## The ``wait()`` coroutine blocks until the flag is `false`.
    ##
    ## If more than one coroutine blocked in ``wait()`` waiting for event
    ## state to be signaled, when event get fired, then all coroutines
    ## continue proceeds in order, they have entered waiting state.
    flag: bool
    waiters: seq[Future[void].Raising([CancelledError])]

  AsyncQueue*[T] = ref object of RootRef
    ## A queue, useful for coordinating producer and consumer coroutines.
    ##
    ## If ``maxsize`` is less than or equal to zero, the queue size is
    ## infinite. If it is an integer greater than ``0``, then "await put()"
    ## will block when the queue reaches ``maxsize``, until an item is
    ## removed by "await get()".
    getters: seq[Future[void].Raising([CancelledError])]
    putters: seq[Future[void].Raising([CancelledError])]
    queue: Deque[T]
    maxsize: int

  AsyncQueueEmptyError* = object of AsyncError
    ## ``AsyncQueue`` is empty.
  AsyncQueueFullError* = object of AsyncError
    ## ``AsyncQueue`` is full.
  AsyncLockError* = object of AsyncError
    ## ``AsyncLock`` is either locked or unlocked.

  AsyncEventQueueFullError* = object of AsyncError

  EventQueueKey* = distinct uint64

  EventQueueReader* = object
    key: EventQueueKey
    offset: int
    waiter: Future[void].Raising([CancelledError])
    overflow: bool

  AsyncEventQueue*[T] = ref object of RootObj
    readers: seq[EventQueueReader]
    queue: Deque[T]
    counter: uint64
    limit: int
    offset: int

proc newAsyncLock*(): AsyncLock =
  ## Creates new asynchronous lock ``AsyncLock``.
  ##
  ## Lock is created in the unlocked state. When the state is unlocked,
  ## ``acquire()`` changes the state to locked and returns immediately.
  ## When the state is locked, ``acquire()`` blocks until a call to
  ## ``release()`` in another coroutine changes it to unlocked.
  ##
  ## The ``release()`` procedure changes the state to unlocked and returns
  ## immediately.

  AsyncLock()

proc wakeUpFirst(lock: AsyncLock): bool {.inline.} =
  ## Wake up the first waiter if it isn't done.
  var i = 0
  var res = false
  while i < len(lock.waiters):
    let waiter = lock.waiters[i]
    inc(i)
    if not(waiter.finished()):
      waiter.complete()
      res = true
      break
  if i > 0:
    when compiles(lock.waiters.delete(0 .. (i - 1))):
      lock.waiters.delete(0 .. (i - 1))
    else:
      lock.waiters.delete(0, i - 1)
  res

proc checkAll(lock: AsyncLock): bool {.inline.} =
  ## Returns ``true`` if waiters array is empty or full of cancelled futures.
  for fut in lock.waiters.mitems():
    if not(fut.cancelled()):
      return false
  return true

proc acquire*(lock: AsyncLock) {.async: (raises: [CancelledError]).} =
  ## Acquire a lock ``lock``.
  ##
  ## This procedure blocks until the lock ``lock`` is unlocked, then sets it
  ## to locked and returns.
  if not(lock.locked) and lock.checkAll():
    lock.acquired = true
    lock.locked = true
  else:
    let w = Future[void].Raising([CancelledError]).init("AsyncLock.acquire")
    lock.waiters.add(w)
    await w
    lock.acquired = true
    lock.locked = true

proc locked*(lock: AsyncLock): bool =
  ## Return `true` if the lock ``lock`` is acquired, `false` otherwise.
  lock.locked

proc release*(lock: AsyncLock) {.raises: [AsyncLockError].} =
  ## Release a lock ``lock``.
  ##
  ## When the ``lock`` is locked, reset it to unlocked, and return. If any
  ## other coroutines are blocked waiting for the lock to become unlocked,
  ## allow exactly one of them to proceed.
  if lock.locked:
    # We set ``lock.locked`` to ``false`` only when there no active waiters.
    # If active waiters are present, then ``lock.locked`` will be set to `true`
    # in ``acquire()`` procedure's continuation.
    if not(lock.acquired):
      raise newException(AsyncLockError, "AsyncLock was already released!")
    else:
      lock.acquired = false
      if not(lock.wakeUpFirst()):
        lock.locked = false
  else:
    raise newException(AsyncLockError, "AsyncLock is not acquired!")

proc newAsyncEvent*(): AsyncEvent =
  ## Creates new asyncronous event ``AsyncEvent``.
  ##
  ## An event manages a flag that can be set to `true` with the `fire()`
  ## procedure and reset to `false` with the `clear()` procedure.
  ## The `wait()` procedure blocks until the flag is `true`. The flag is
  ## initially `false`.
  AsyncEvent()

proc wait*(event: AsyncEvent): Future[void] {.
     async: (raw: true, raises: [CancelledError]).} =
  ## Block until the internal flag of ``event`` is `true`.
  ## If the internal flag is `true` on entry, return immediately. Otherwise,
  ## block until another task calls `fire()` to set the flag to `true`,
  ## then return.
  let retFuture = newFuture[void]("AsyncEvent.wait")
  proc cancellation(udata: pointer) {.gcsafe, raises: [].} =
    event.waiters.keepItIf(it != retFuture)
  if not(event.flag):
    retFuture.cancelCallback = cancellation
    event.waiters.add(retFuture)
  else:
    retFuture.complete()
  retFuture

proc fire*(event: AsyncEvent) =
  ## Set the internal flag of ``event`` to `true`. All tasks waiting for it
  ## to become `true` are awakened. Task that call `wait()` once the flag is
  ## `true` will not block at all.
  if not(event.flag):
    event.flag = true
    for fut in event.waiters:
      if not(fut.finished()): # Could have been cancelled
        fut.complete()
    event.waiters.setLen(0)

proc clear*(event: AsyncEvent) =
  ## Reset the internal flag of ``event`` to `false`. Subsequently, tasks
  ## calling `wait()` will block until `fire()` is called to set the internal
  ## flag to `true` again.
  event.flag = false

proc isSet*(event: AsyncEvent): bool =
  ## Return `true` if and only if the internal flag of ``event`` is `true`.
  event.flag

proc newAsyncQueue*[T](maxsize: int = 0): AsyncQueue[T] =
  ## Creates a new asynchronous queue ``AsyncQueue``.

  AsyncQueue[T](
    queue: initDeque[T](),
    maxsize: maxsize
  )

proc wakeupNext(waiters: var seq) {.inline.} =
  var i = 0
  while i < len(waiters):
    let waiter = waiters[i]
    inc(i)

    if not(waiter.finished()):
      waiter.complete()
      break

  if i > 0:
    when compiles(waiters.delete(0 .. (i - 1))):
      waiters.delete(0 .. (i - 1))
    else:
      waiters.delete(0, i - 1)

proc full*[T](aq: AsyncQueue[T]): bool {.inline.} =
  ## Return ``true`` if there are ``maxsize`` items in the queue.
  ##
  ## Note: If the ``aq`` was initialized with ``maxsize = 0`` (default),
  ## then ``full()`` is never ``true``.
  if aq.maxsize <= 0:
    false
  else:
    (len(aq.queue) >= aq.maxsize)

proc empty*[T](aq: AsyncQueue[T]): bool {.inline.} =
  ## Return ``true`` if the queue is empty, ``false`` otherwise.
  (len(aq.queue) == 0)

proc addFirstImpl[T](aq: AsyncQueue[T], item: T) =
  aq.queue.addFirst(item)
  aq.getters.wakeupNext()

proc addLastImpl[T](aq: AsyncQueue[T], item: T) =
  aq.queue.addLast(item)
  aq.getters.wakeupNext()

proc popFirstImpl[T](aq: AsyncQueue[T]): T =
  let res = aq.queue.popFirst()
  aq.putters.wakeupNext()
  res

proc popLastImpl[T](aq: AsyncQueue[T]): T =
  let res = aq.queue.popLast()
  aq.putters.wakeupNext()
  res

proc addFirstNoWait*[T](aq: AsyncQueue[T], item: T) {.
     raises: [AsyncQueueFullError].} =
  ## Put an item ``item`` to the beginning of the queue ``aq`` immediately.
  ##
  ## If queue ``aq`` is full, then ``AsyncQueueFullError`` exception raised.
  if aq.full():
    raise newException(AsyncQueueFullError, "AsyncQueue is full!")
  aq.addFirstImpl(item)

proc addLastNoWait*[T](aq: AsyncQueue[T], item: T) {.
     raises: [AsyncQueueFullError].} =
  ## Put an item ``item`` at the end of the queue ``aq`` immediately.
  ##
  ## If queue ``aq`` is full, then ``AsyncQueueFullError`` exception raised.
  if aq.full():
    raise newException(AsyncQueueFullError, "AsyncQueue is full!")
  aq.addLastImpl(item)

proc popFirstNoWait*[T](aq: AsyncQueue[T]): T {.
     raises: [AsyncQueueEmptyError].} =
  ## Get an item from the beginning of the queue ``aq`` immediately.
  ##
  ## If queue ``aq`` is empty, then ``AsyncQueueEmptyError`` exception raised.
  if aq.empty():
    raise newException(AsyncQueueEmptyError, "AsyncQueue is empty!")
  aq.popFirstImpl()

proc popLastNoWait*[T](aq: AsyncQueue[T]): T {.
     raises: [AsyncQueueEmptyError].} =
  ## Get an item from the end of the queue ``aq`` immediately.
  ##
  ## If queue ``aq`` is empty, then ``AsyncQueueEmptyError`` exception raised.
  if aq.empty():
    raise newException(AsyncQueueEmptyError, "AsyncQueue is empty!")
  aq.popLastImpl()

proc addFirst*[T](aq: AsyncQueue[T], item: T) {.
     async: (raises: [CancelledError]).} =
  ## Put an ``item`` to the beginning of the queue ``aq``. If the queue is full,
  ## wait until a free slot is available before adding item.
  while aq.full():
    let putter =
      Future[void].Raising([CancelledError]).init("AsyncQueue.addFirst")
    aq.putters.add(putter)
    try:
      await putter
    except CancelledError as exc:
      if not(aq.full()) and not(putter.cancelled()):
        aq.putters.wakeupNext()
      raise exc
  aq.addFirstImpl(item)

proc addLast*[T](aq: AsyncQueue[T], item: T) {.
     async: (raises: [CancelledError]).} =
  ## Put an ``item`` to the end of the queue ``aq``. If the queue is full,
  ## wait until a free slot is available before adding item.
  while aq.full():
    let putter =
      Future[void].Raising([CancelledError]).init("AsyncQueue.addLast")
    aq.putters.add(putter)
    try:
      await putter
    except CancelledError as exc:
      if not(aq.full()) and not(putter.cancelled()):
        aq.putters.wakeupNext()
      raise exc
  aq.addLastImpl(item)

proc popFirst*[T](aq: AsyncQueue[T]): Future[T] {.
     async: (raises: [CancelledError]).} =
  ## Remove and return an ``item`` from the beginning of the queue ``aq``.
  ## If the queue is empty, wait until an item is available.
  while aq.empty():
    let getter =
      Future[void].Raising([CancelledError]).init("AsyncQueue.popFirst")
    aq.getters.add(getter)
    try:
      await getter
    except CancelledError as exc:
      if not(aq.empty()) and not(getter.cancelled()):
        aq.getters.wakeupNext()
      raise exc
  aq.popFirstImpl()

proc popLast*[T](aq: AsyncQueue[T]): Future[T] {.
     async: (raises: [CancelledError]).} =
  ## Remove and return an ``item`` from the end of the queue ``aq``.
  ## If the queue is empty, wait until an item is available.
  while aq.empty():
    let getter =
      Future[void].Raising([CancelledError]).init("AsyncQueue.popLast")
    aq.getters.add(getter)
    try:
      await getter
    except CancelledError as exc:
      if not(aq.empty()) and not(getter.cancelled()):
        aq.getters.wakeupNext()
      raise exc
  aq.popLastImpl()

proc putNoWait*[T](aq: AsyncQueue[T], item: T) {.
     raises: [AsyncQueueFullError].} =
  ## Alias of ``addLastNoWait()``.
  aq.addLastNoWait(item)

proc getNoWait*[T](aq: AsyncQueue[T]): T {.
     raises: [AsyncQueueEmptyError].} =
  ## Alias of ``popFirstNoWait()``.
  aq.popFirstNoWait()

proc put*[T](aq: AsyncQueue[T], item: T): Future[void] {.
     async: (raw: true, raises: [CancelledError]).} =
  ## Alias of ``addLast()``.
  aq.addLast(item)

proc get*[T](aq: AsyncQueue[T]): Future[T] {.
     async: (raw: true, raises: [CancelledError]).} =
  ## Alias of ``popFirst()``.
  aq.popFirst()

proc clear*[T](aq: AsyncQueue[T]) {.inline.} =
  ## Clears all elements of queue ``aq``.
  aq.queue.clear()

proc len*[T](aq: AsyncQueue[T]): int {.inline.} =
  ## Return the number of elements in ``aq``.
  len(aq.queue)

proc size*[T](aq: AsyncQueue[T]): int {.inline.} =
  ## Return the maximum number of elements in ``aq``.
  len(aq.maxsize)

proc `[]`*[T](aq: AsyncQueue[T], i: Natural) : T {.inline.} =
  ## Access the i-th element of ``aq`` by order from first to last.
  ## ``aq[0]`` is the first element, ``aq[^1]`` is the last element.
  aq.queue[i]

proc `[]`*[T](aq: AsyncQueue[T], i: BackwardsIndex) : T {.inline.} =
  ## Access the i-th element of ``aq`` by order from first to last.
  ## ``aq[0]`` is the first element, ``aq[^1]`` is the last element.
  aq.queue[len(aq.queue) - int(i)]

proc `[]=`* [T](aq: AsyncQueue[T], i: Natural, item: T) {.inline.} =
  ## Change the i-th element of ``aq``.
  aq.queue[i] = item

proc `[]=`* [T](aq: AsyncQueue[T], i: BackwardsIndex, item: T) {.inline.} =
  ## Change the i-th element of ``aq``.
  aq.queue[len(aq.queue) - int(i)] = item

iterator items*[T](aq: AsyncQueue[T]): T {.inline.} =
  ## Yield every element of ``aq``.
  for item in aq.queue.items():
    yield item

iterator mitems*[T](aq: AsyncQueue[T]): var T {.inline.} =
  ## Yield every element of ``aq``.
  for mitem in aq.queue.mitems():
    yield mitem

iterator pairs*[T](aq: AsyncQueue[T]): tuple[key: int, val: T] {.inline.} =
  ## Yield every (position, value) of ``aq``.
  for pair in aq.queue.pairs():
    yield pair

proc contains*[T](aq: AsyncQueue[T], item: T): bool {.inline.} =
  ## Return true if ``item`` is in ``aq`` or false if not found. Usually used
  ## via the ``in`` operator.
  for e in aq.queue.items():
    if e == item: return true
  false

proc `$`*[T](aq: AsyncQueue[T]): string =
  ## Turn an async queue ``aq`` into its string representation.
  var res = "["
  for item in aq.queue.items():
    if len(res) > 1: res.add(", ")
    res.addQuoted(item)
  res.add("]")
  res

proc `==`(a, b: EventQueueKey): bool {.borrow.}

proc compact(ab: AsyncEventQueue) {.raises: [].} =
  if len(ab.readers) > 0:
    let minOffset =
      block:
        var res = -1
        for reader in ab.readers.items():
          if not(reader.overflow):
            res = reader.offset
            break
        res

    if minOffset == -1:
      ab.offset += len(ab.queue)
      ab.queue.clear()
    else:
      doAssert(minOffset >= ab.offset)
      if minOffset > ab.offset:
        let delta = minOffset - ab.offset
        ab.queue.shrink(fromFirst = delta)
        ab.offset += delta
  else:
    ab.queue.clear()

proc getReaderIndex(ab: AsyncEventQueue, key: EventQueueKey): int =
  for index, value in ab.readers.pairs():
    if value.key == key:
      return index
  -1

proc newAsyncEventQueue*[T](limitSize = 0): AsyncEventQueue[T] {.
     raises: [].} =
  ## Creates new ``AsyncEventBus`` maximum size of ``limitSize`` (default is
  ## ``0`` which means that there no limits).
  ##
  ## When number of events emitted exceeds ``limitSize`` - emit() procedure
  ## will discard new events, consumers which has number of pending events
  ## more than ``limitSize`` will get ``AsyncEventQueueFullError``
  ## error.
  doAssert(limitSize >= 0, "Limit size should be non-negative integer")
  let queue =
    if limitSize == 0:
      initDeque[T]()
    elif isPowerOfTwo(limitSize + 1):
      initDeque[T](limitSize + 1)
    else:
      initDeque[T](nextPowerOfTwo(limitSize + 1))
  AsyncEventQueue[T](counter: 0'u64, queue: queue, limit: limitSize)

proc len*(ab: AsyncEventQueue): int {.raises: [].} =
  len(ab.queue)

proc register*(ab: AsyncEventQueue): EventQueueKey {.raises: [].} =
  inc(ab.counter)
  let reader = EventQueueReader(key: EventQueueKey(ab.counter),
                                offset: ab.offset + len(ab.queue),
                                overflow: false)
  ab.readers.add(reader)
  EventQueueKey(ab.counter)

proc unregister*(ab: AsyncEventQueue, key: EventQueueKey) {.
     raises: [] .} =
  let index = ab.getReaderIndex(key)
  if index >= 0:
    let reader = ab.readers[index]
    # Completing pending Future to avoid deadlock.
    if not(isNil(reader.waiter)) and not(reader.waiter.finished()):
      reader.waiter.complete()
    ab.readers.delete(index)
    ab.compact()

proc close*(ab: AsyncEventQueue) {.raises: [].} =
  for reader in ab.readers.items():
    if not(isNil(reader.waiter)) and not(reader.waiter.finished()):
      reader.waiter.complete()
  ab.readers.reset()
  ab.queue.clear()

proc closeWait*(ab: AsyncEventQueue): Future[void] {.
     async: (raw: true, raises: []).} =
  let retFuture = newFuture[void]("AsyncEventQueue.closeWait()",
                                  {FutureFlag.OwnCancelSchedule})
  proc continuation(udata: pointer) {.gcsafe.} =
    retFuture.complete()

  # Ignore cancellation requests - we'll complete the future soon enough
  retFuture.cancelCallback = nil

  ab.close()
  # Schedule `continuation` to be called only after all the `reader`
  # notifications will be scheduled and processed.
  callSoon(continuation)
  retFuture

template readerOverflow*(ab: AsyncEventQueue,
                         reader: EventQueueReader): bool =
  ab.limit + (reader.offset - ab.offset) <= len(ab.queue)

proc emit*[T](ab: AsyncEventQueue[T], data: T) =
  if len(ab.readers) > 0:
    # We enqueue `data` only if there active reader present.
    var changesPresent = false
    let couldEmit =
      if ab.limit == 0:
        true
      else:
        # Because ab.readers is sequence sorted by `offset`, we will apply our
        # limit to the most recent consumer.
        if ab.readerOverflow(ab.readers[^1]):
          false
        else:
          true

    if couldEmit:
      if ab.limit != 0:
        for reader in ab.readers.mitems():
          if not(reader.overflow):
            if ab.readerOverflow(reader):
              reader.overflow = true
              changesPresent = true
      ab.queue.addLast(data)
      for reader in ab.readers.mitems():
        if not(isNil(reader.waiter)) and not(reader.waiter.finished()):
          reader.waiter.complete()
    else:
      for reader in ab.readers.mitems():
        if not(reader.overflow):
          reader.overflow = true
          changesPresent = true

    if changesPresent:
      ab.compact()

proc waitEvents*[T](ab: AsyncEventQueue[T],
                    key: EventQueueKey,
                    eventsCount = -1): Future[seq[T]] {.
     async: (raises: [AsyncEventQueueFullError, CancelledError]).} =
  ## Wait for events
  var
    events: seq[T]
    resetFuture = false

  while true:
    # We need to obtain reader index at every iteration, because `ab.readers`
    # sequence could be changed after `await waitFuture` call.
    let index = ab.getReaderIndex(key)
    if index < 0:
      # We going to return everything we have in `events`.
      break

    if resetFuture:
      resetFuture = false
      ab.readers[index].waiter = nil

    let reader = ab.readers[index]
    doAssert(isNil(reader.waiter),
             "Concurrent waits on same key are not allowed!")

    if reader.overflow:
      raise newException(AsyncEventQueueFullError,
                         "AsyncEventQueue size exceeds limits")

    let length = len(ab.queue) + ab.offset
    doAssert(length >= ab.readers[index].offset)
    if length == ab.readers[index].offset:
      # We are at the end of queue, it means that we should wait for new events.
      let waitFuture = Future[void].Raising([CancelledError]).init(
        "AsyncEventQueue.waitEvents")
      ab.readers[index].waiter = waitFuture
      resetFuture = true
      await waitFuture
    else:
      let
        itemsInQueue = length - ab.readers[index].offset
        itemsOffset = ab.readers[index].offset - ab.offset
        itemsCount =
          if eventsCount <= 0:
            itemsInQueue
          else:
            min(itemsInQueue, eventsCount - len(events))

      for i in 0 ..< itemsCount:
        events.add(ab.queue[itemsOffset + i])
      ab.readers[index].offset += itemsCount

      # Keep readers sequence sorted by `offset` field.
      var slider = index
      while (slider + 1 < len(ab.readers)) and
            (ab.readers[slider].offset > ab.readers[slider + 1].offset):
        swap(ab.readers[slider], ab.readers[slider + 1])
        inc(slider)

      # Shrink data queue.
      ab.compact()

      if (eventsCount <= 0) or (len(events) == eventsCount):
        break

  events

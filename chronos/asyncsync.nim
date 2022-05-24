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

{.push raises: [Defect].}

import std/[sequtils, deques, tables, typetraits]
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
    waiters: seq[Future[void]]

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
    waiters: seq[Future[void]]

  AsyncQueue*[T] = ref object of RootRef
    ## A queue, useful for coordinating producer and consumer coroutines.
    ##
    ## If ``maxsize`` is less than or equal to zero, the queue size is
    ## infinite. If it is an integer greater than ``0``, then "await put()"
    ## will block when the queue reaches ``maxsize``, until an item is
    ## removed by "await get()".
    getters: seq[Future[void]]
    putters: seq[Future[void]]
    queue: Deque[T]
    maxsize: int

  AsyncQueueEmptyError* = object of CatchableError
    ## ``AsyncQueue`` is empty.
  AsyncQueueFullError* = object of CatchableError
    ## ``AsyncQueue`` is full.
  AsyncLockError* = object of CatchableError
    ## ``AsyncLock`` is either locked or unlocked.

  EventBusSubscription*[T] = proc(bus: AsyncEventBus,
                                  payload: EventPayload[T]): Future[void] {.
                                  gcsafe, raises: [Defect].}
    ## EventBus subscription callback type.

  EventBusAllSubscription* = proc(bus: AsyncEventBus,
                                  event: AwaitableEvent): Future[void] {.
                                  gcsafe, raises: [Defect].}
    ## EventBus subscription callback type.

  EventBusCallback = proc(bus: AsyncEventBus, event: string, key: EventBusKey,
                          data: EventPayloadBase) {.
                          gcsafe, raises: [Defect].}

  EventBusKey* = object
    ## Unique subscription key.
    eventName: string
    typeName: string
    unique: uint64
    cb: EventBusCallback

  EventItem = object
    waiters: seq[FutureBase]
    subscribers: seq[EventBusKey]

  AsyncEventBus* = ref object of RootObj
    ## An eventbus object.
    counter: uint64
    events: Table[string, EventItem]
    subscribers: seq[EventBusKey]
    waiters: seq[Future[AwaitableEvent]]

  EventPayloadBase* = ref object of RootObj
    loc: ptr SrcLoc

  EventPayload*[T] = ref object of EventPayloadBase
    ## Eventbus' event payload object
    value: T

  AwaitableEvent* = object
    ## Eventbus' event payload object
    eventName: string
    payload: EventPayloadBase

  EventQueueKey* = distinct uint64

  EventQueueReader* = object
    key: EventQueueKey
    offset: int
    waiter: Future[void]

  AsyncEventQueue*[T] = ref object of RootObj
    readers: seq[EventQueueReader]
    queue: Deque[T]
    counter: uint64
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

  # Workaround for callSoon() not worked correctly before
  # getThreadDispatcher() call.
  discard getThreadDispatcher()
  AsyncLock(waiters: newSeq[Future[void]](), locked: false, acquired: false)

proc wakeUpFirst(lock: AsyncLock): bool {.inline.} =
  ## Wake up the first waiter if it isn't done.
  var i = 0
  var res = false
  while i < len(lock.waiters):
    var waiter = lock.waiters[i]
    inc(i)
    if not(waiter.finished()):
      waiter.complete()
      res = true
      break
  if i > 0:
    lock.waiters.delete(0, i - 1)
  res

proc checkAll(lock: AsyncLock): bool {.inline.} =
  ## Returns ``true`` if waiters array is empty or full of cancelled futures.
  for fut in lock.waiters.mitems():
    if not(fut.cancelled()):
      return false
  return true

proc acquire*(lock: AsyncLock) {.async.} =
  ## Acquire a lock ``lock``.
  ##
  ## This procedure blocks until the lock ``lock`` is unlocked, then sets it
  ## to locked and returns.
  if not(lock.locked) and lock.checkAll():
    lock.acquired = true
    lock.locked = true
  else:
    var w = newFuture[void]("AsyncLock.acquire")
    lock.waiters.add(w)
    await w
    lock.acquired = true
    lock.locked = true

proc locked*(lock: AsyncLock): bool =
  ## Return `true` if the lock ``lock`` is acquired, `false` otherwise.
  lock.locked

proc release*(lock: AsyncLock) {.raises: [Defect, AsyncLockError].} =
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

  # Workaround for callSoon() not worked correctly before
  # getThreadDispatcher() call.
  discard getThreadDispatcher()
  AsyncEvent(waiters: newSeq[Future[void]](), flag: false)

proc wait*(event: AsyncEvent): Future[void] =
  ## Block until the internal flag of ``event`` is `true`.
  ## If the internal flag is `true` on entry, return immediately. Otherwise,
  ## block until another task calls `fire()` to set the flag to `true`,
  ## then return.
  var w = newFuture[void]("AsyncEvent.wait")
  if not(event.flag):
    event.waiters.add(w)
  else:
    w.complete()
  w

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

  # Workaround for callSoon() not worked correctly before
  # getThreadDispatcher() call.
  discard getThreadDispatcher()
  AsyncQueue[T](
    getters: newSeq[Future[void]](),
    putters: newSeq[Future[void]](),
    queue: initDeque[T](),
    maxsize: maxsize
  )

proc wakeupNext(waiters: var seq[Future[void]]) {.inline.} =
  var i = 0
  while i < len(waiters):
    var waiter = waiters[i]
    inc(i)

    if not(waiter.finished()):
      waiter.complete()
      break

  if i > 0:
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

proc addFirstNoWait*[T](aq: AsyncQueue[T], item: T) {.
    raises: [Defect, AsyncQueueFullError].}=
  ## Put an item ``item`` to the beginning of the queue ``aq`` immediately.
  ##
  ## If queue ``aq`` is full, then ``AsyncQueueFullError`` exception raised.
  if aq.full():
    raise newException(AsyncQueueFullError, "AsyncQueue is full!")
  aq.queue.addFirst(item)
  aq.getters.wakeupNext()

proc addLastNoWait*[T](aq: AsyncQueue[T], item: T) {.
    raises: [Defect, AsyncQueueFullError].}=
  ## Put an item ``item`` at the end of the queue ``aq`` immediately.
  ##
  ## If queue ``aq`` is full, then ``AsyncQueueFullError`` exception raised.
  if aq.full():
    raise newException(AsyncQueueFullError, "AsyncQueue is full!")
  aq.queue.addLast(item)
  aq.getters.wakeupNext()

proc popFirstNoWait*[T](aq: AsyncQueue[T]): T {.
    raises: [Defect, AsyncQueueEmptyError].} =
  ## Get an item from the beginning of the queue ``aq`` immediately.
  ##
  ## If queue ``aq`` is empty, then ``AsyncQueueEmptyError`` exception raised.
  if aq.empty():
    raise newException(AsyncQueueEmptyError, "AsyncQueue is empty!")
  let res = aq.queue.popFirst()
  aq.putters.wakeupNext()
  res

proc popLastNoWait*[T](aq: AsyncQueue[T]): T {.
    raises: [Defect, AsyncQueueEmptyError].} =
  ## Get an item from the end of the queue ``aq`` immediately.
  ##
  ## If queue ``aq`` is empty, then ``AsyncQueueEmptyError`` exception raised.
  if aq.empty():
    raise newException(AsyncQueueEmptyError, "AsyncQueue is empty!")
  let res = aq.queue.popLast()
  aq.putters.wakeupNext()
  res

proc addFirst*[T](aq: AsyncQueue[T], item: T) {.async.} =
  ## Put an ``item`` to the beginning of the queue ``aq``. If the queue is full,
  ## wait until a free slot is available before adding item.
  while aq.full():
    var putter = newFuture[void]("AsyncQueue.addFirst")
    aq.putters.add(putter)
    try:
      await putter
    except CatchableError as exc:
      if not(aq.full()) and not(putter.cancelled()):
        aq.putters.wakeupNext()
      raise exc
  aq.addFirstNoWait(item)

proc addLast*[T](aq: AsyncQueue[T], item: T) {.async.} =
  ## Put an ``item`` to the end of the queue ``aq``. If the queue is full,
  ## wait until a free slot is available before adding item.
  while aq.full():
    var putter = newFuture[void]("AsyncQueue.addLast")
    aq.putters.add(putter)
    try:
      await putter
    except CatchableError as exc:
      if not(aq.full()) and not(putter.cancelled()):
        aq.putters.wakeupNext()
      raise exc
  aq.addLastNoWait(item)

proc popFirst*[T](aq: AsyncQueue[T]): Future[T] {.async.} =
  ## Remove and return an ``item`` from the beginning of the queue ``aq``.
  ## If the queue is empty, wait until an item is available.
  while aq.empty():
    var getter = newFuture[void]("AsyncQueue.popFirst")
    aq.getters.add(getter)
    try:
      await getter
    except CatchableError as exc:
      if not(aq.empty()) and not(getter.cancelled()):
        aq.getters.wakeupNext()
      raise exc
  return aq.popFirstNoWait()

proc popLast*[T](aq: AsyncQueue[T]): Future[T] {.async.} =
  ## Remove and return an ``item`` from the end of the queue ``aq``.
  ## If the queue is empty, wait until an item is available.
  while aq.empty():
    var getter = newFuture[void]("AsyncQueue.popLast")
    aq.getters.add(getter)
    try:
      await getter
    except CatchableError as exc:
      if not(aq.empty()) and not(getter.cancelled()):
        aq.getters.wakeupNext()
      raise exc
  return aq.popLastNoWait()

proc putNoWait*[T](aq: AsyncQueue[T], item: T) {.
    raises: [Defect, AsyncQueueFullError].} =
  ## Alias of ``addLastNoWait()``.
  aq.addLastNoWait(item)

proc getNoWait*[T](aq: AsyncQueue[T]): T {.
    raises: [Defect, AsyncQueueEmptyError].} =
  ## Alias of ``popFirstNoWait()``.
  aq.popFirstNoWait()

proc put*[T](aq: AsyncQueue[T], item: T): Future[void] {.inline.} =
  ## Alias of ``addLast()``.
  aq.addLast(item)

proc get*[T](aq: AsyncQueue[T]): Future[T] {.inline.} =
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
  return false

proc `$`*[T](aq: AsyncQueue[T]): string =
  ## Turn an async queue ``aq`` into its string representation.
  var res = "["
  for item in aq.queue.items():
    if len(res) > 1: res.add(", ")
    res.addQuoted(item)
  res.add("]")
  res

template generateKey(typeName, eventName: string): string =
  "type[" & typeName & "]-key[" & eventName & "]"

proc newAsyncEventBus*(): AsyncEventBus =
  ## Creates new ``AsyncEventBus``.
  AsyncEventBus(counter: 0'u64, events: initTable[string, EventItem]())

template get*[T](payload: EventPayload[T]): T =
  ## Returns event payload data.
  payload.value

template location*(payload: EventPayloadBase): SrcLoc =
  ## Returns source location address of event emitter.
  payload.loc[]

proc get*(event: AwaitableEvent, T: typedesc): T =
  ## Returns event's payload of type ``T`` from event ``event``.
  cast[EventPayload[T]](event.payload).value

template event*(event: AwaitableEvent): string =
  ## Returns event's name from event ``event``.
  event.eventName

template location*(event: AwaitableEvent): SrcLoc =
  ## Returns source location address of event emitter.
  event.payload.loc[]

proc waitEvent*(bus: AsyncEventBus, T: typedesc, event: string): Future[T] =
  ## Wait for the event from AsyncEventBus ``bus`` with name ``event``.
  ##
  ## Returned ``Future[T]`` will hold event's payload of type ``T``.
  var default: EventItem
  var retFuture = newFuture[T]("AsyncEventBus.waitEvent")
  let eventKey = generateKey(T.name, event)
  proc cancellation(udata: pointer) {.gcsafe, raises: [Defect].} =
    if not(retFuture.finished()):
      bus.events.withValue(eventKey, item):
        item.waiters.keepItIf(it != cast[FutureBase](retFuture))
  retFuture.cancelCallback = cancellation
  let baseFuture = cast[FutureBase](retFuture)
  bus.events.mgetOrPut(eventKey, default).waiters.add(baseFuture)
  retFuture

proc waitAllEvents*(bus: AsyncEventBus): Future[AwaitableEvent] =
  ## Wait for any event from AsyncEventBus ``bus``.
  ##
  ## Returns ``Future`` which holds helper object. Using this object you can
  ## retrieve event's name and payload.
  var retFuture = newFuture[AwaitableEvent]("AsyncEventBus.waitAllEvents")
  proc cancellation(udata: pointer) {.gcsafe, raises: [Defect].} =
    if not(retFuture.finished()):
      bus.waiters.keepItIf(it != retFuture)
  retFuture.cancelCallback = cancellation
  bus.waiters.add(retFuture)
  retFuture

proc subscribe*[T](bus: AsyncEventBus, event: string,
                   callback: EventBusSubscription[T]): EventBusKey =
  ## Subscribe to the event ``event`` passed through eventbus ``bus`` with
  ## callback ``callback``.
  ##
  ## Returns key that can be used to unsubscribe.
  proc trampoline(tbus: AsyncEventBus, event: string, key: EventBusKey,
                  data: EventPayloadBase) {.gcsafe, raises: [Defect].} =
    let payload = cast[EventPayload[T]](data)
    asyncSpawn callback(bus, payload)

  let subkey =
    block:
      inc(bus.counter)
      EventBusKey(eventName: event, typeName: T.name, unique: bus.counter,
                  cb: trampoline)

  var default: EventItem
  let eventKey = generateKey(T.name, event)
  bus.events.mgetOrPut(eventKey, default).subscribers.add(subkey)
  subkey

proc subscribeAll*(bus: AsyncEventBus,
                   callback: EventBusAllSubscription): EventBusKey =
  ## Subscribe to all events passed through eventbus ``bus`` with callback
  ## ``callback``.
  ##
  ## Returns key that can be used to unsubscribe.
  proc trampoline(tbus: AsyncEventBus, event: string, key: EventBusKey,
                  data: EventPayloadBase) {.gcsafe, raises: [Defect].} =
    let event = AwaitableEvent(eventName: event, payload: data)
    asyncSpawn callback(bus, event)

  let subkey =
    block:
      inc(bus.counter)
      EventBusKey(eventName: "", typeName: "", unique: bus.counter,
                  cb: trampoline)
  bus.subscribers.add(subkey)
  subkey

proc unsubscribe*(bus: AsyncEventBus, key: EventBusKey) =
  ## Cancel subscription of subscriber with key ``key`` from eventbus ``bus``.
  let eventKey = generateKey(key.typeName, key.eventName)

  # Clean event's subscribers.
  bus.events.withValue(eventKey, item):
    item.subscribers.keepItIf(it.unique != key.unique)

  # Clean subscribers subscribed to all events.
  bus.subscribers.keepItIf(it.unique != key.unique)

proc emit[T](bus: AsyncEventBus, event: string, data: T, loc: ptr SrcLoc) =
  let
    eventKey = generateKey(T.name, event)
    payload =
      block:
        var data = EventPayload[T](value: data, loc: loc)
        cast[EventPayloadBase](data)

  # Used to capture the "subscriber" variable in the loops
  # sugar.capture doesn't work in Nim <1.6
  proc triggerSubscriberCallback(subscriber: EventBusKey) =
    callSoon(proc(udata: pointer) =
      subscriber.cb(bus, event, subscriber, payload)
    )

  bus.events.withValue(eventKey, item):
    # Schedule waiters which are waiting for the event ``event``.
    for waiter in item.waiters:
      var fut = cast[Future[T]](waiter)
      fut.complete(data)
    # Clear all the waiters.
    item.waiters.setLen(0)

    # Schedule subscriber's callbacks, which are subscribed to the event.
    for subscriber in item.subscribers:
      triggerSubscriberCallback(subscriber)

  # Schedule waiters which are waiting all events
  for waiter in bus.waiters:
    waiter.complete(AwaitableEvent(eventName: event, payload: payload))
  # Clear all the waiters.
  bus.waiters.setLen(0)

  # Schedule subscriber's callbacks which are subscribed to all events.
  for subscriber in bus.subscribers:
    triggerSubscriberCallback(subscriber)

template emit*[T](bus: AsyncEventBus, event: string, data: T) =
  ## Emit new event ``event`` to the eventbus ``bus`` with payload ``data``.
  emit(bus, event, data, getSrcLocation())

proc emitWait[T](bus: AsyncEventBus, event: string, data: T,
                 loc: ptr SrcLoc): Future[void] =
  var retFuture = newFuture[void]("AsyncEventBus.emitWait")
  proc continuation(udata: pointer) {.gcsafe.} =
    if not(retFuture.finished()):
      retFuture.complete()
  emit(bus, event, data, loc)
  callSoon(continuation)
  return retFuture

template emitWait*[T](bus: AsyncEventBus, event: string,
                      data: T): Future[void] =
  ## Emit new event ``event`` to the eventbus ``bus`` with payload ``data`` and
  ## wait until all the subscribers/waiters will receive notification about
  ## event.
  emitWait(bus, event, data, getSrcLocation())

proc `==`(a, b: EventQueueKey): bool {.borrow.}

proc compact[T](ab: AsyncEventQueue[T]) =
  if len(ab.readers) > 0:
    let minOffset = ab.readers[0].offset
    doAssert(minOffset >= ab.offset)
    if minOffset > ab.offset:
      let delta = minOffset - ab.offset
      ab.queue.shrink(fromFirst = delta)
      ab.offset += delta
  else:
    ab.queue.clear()

proc getReaderIndex[T](ab: AsyncEventQueue[T], key: EventQueueKey): int =
  for index, value in ab.readers.pairs():
    if value.key == key:
      return index
  -1

proc newAsyncEventQueue*[T](): AsyncEventQueue[T] =
  ## Creates new ``AsyncEventBus``.
  AsyncEventQueue[T](counter: 0'u64, queue: initDeque[T]())

proc len*[T](ab: AsyncEventQueue[T]): int =
  len(ab.queue)

proc register*[T](ab: AsyncEventQueue[T]): EventQueueKey =
  inc(ab.counter)
  let reader = EventQueueReader(key: EventQueueKey(ab.counter),
                                offset: ab.offset + len(ab.queue))
  ab.readers.add(reader)
  EventQueueKey(ab.counter)

proc unregister*[T](ab: AsyncEventQueue[T], key: EventQueueKey) =
  let index = ab.getReaderIndex(key)
  if index >= 0:
    let reader = ab.readers[index]
    # Completing pending Future to avoid deadlock.
    if not(isNil(reader.waiter)) and not(reader.waiter.finished()):
      reader.waiter.complete()
    ab.readers.delete(index)
    ab.compact()

proc emit*[T](ab: AsyncEventQueue[T], data: T) =
  if len(ab.readers) > 0:
    # We enqueue `data` only if there active reader present.
    ab.queue.addLast(data)
    for reader in ab.readers.items():
      if not(isNil(reader.waiter)) and not(reader.waiter.finished()):
        reader.waiter.complete()

proc close*[T](ab: AsyncEventQueue[T]) =
  for reader in ab.readers.items():
    if not(isNil(reader.waiter)) and not(reader.waiter.finished()):
      reader.waiter.complete()
  # This could generate leak, shrink() is not yet implemented for sequences.
  ab.readers.setLen(0)
  ab.queue.clear()

proc waitEvents*[T](ab: AsyncEventQueue[T],
                    key: EventQueueKey,
                    eventsCount = -1): Future[seq[T]] {.async.} =
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

    let length = len(ab.queue) + ab.offset
    doAssert(length >= ab.readers[index].offset)
    if length == ab.readers[index].offset:
      # We are at the end of queue, it means that we should wait for new events.
      let waitFuture = newFuture[void]("AsyncEventQueue.waitEvents")
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

  return events

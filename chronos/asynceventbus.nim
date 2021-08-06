#
#               Chronos asynchronous event bus
#
#  (c) Copyright 2018-Present Status Research & Development GmbH
#
#                Licensed under either of
#    Apache License, version 2.0, (LICENSE-APACHEv2)
#                MIT license (LICENSE-MIT)

{.push raises: [Defect].}

import std/[tables, sequtils, typetraits]
import ./asyncloop

type
  EventDataBase* = ref object of RootObj

  EventData*[T] = ref object of EventDataBase
    value*: T

  EventBusSubscription*[T] = proc(bus: EventBus, data: T): Future[void] {.
                               gcsafe, raises: [Defect].}

  EventBusCallback* = proc(bus: EventBus, data: EventDataBase) {.
                        gcsafe, raises: [Defect].}

  EventBusKey* = object
    bus: EventBus
    key: string
    cb: EventBusCallback

  EventItem* = object
    waiters*: seq[FutureBase]
    subscribers*: seq[EventBusCallback]

  EventBus* = ref object of RootObj
    events: Table[string, EventItem]

  FooObj* = object
    data1*: int
    data2*: string

proc newEventBus*(): EventBus =
  EventBus(events: initTable[string, EventItem]())

proc generateKey(typeName, eventName: string): string =
  # Generate unique key based on type and event name
  "type[" & typeName & "]-key[" & eventName & "]"

proc init[T](t: typedesc[EventBusCallback], bus: EventBus,
             callback: EventBusSubscription[T]): EventBusCallback =
  # Generate trampoline callback which will perform type conversion.
  proc trampoline(bus: EventBus, data: EventDataBase) {.
       gcsafe, raises: [Defect].} =
    let item = cast[EventData[T]](data)
    asyncSpawn callback(bus, item.value)
  trampoline

proc init[T](t: typedesc[EventDataBase], data: T): EventDataBase =
  var data = EventData[T](value: data)
  cast[EventDataBase](data)

proc waitEvent*(bus: EventBus, T: typedesc, event: string): Future[T] =
  var default: EventItem
  var retFuture = newFuture[T]("eventbus.waitEvent")
  let key = generateKey(T.name, event)

  proc cancellation(udata: pointer) {.gcsafe.} =
    if not(retFuture.finished()):
      bus.events.withValue(key, item):
        item.waiters.keepItIf(it != cast[FutureBase](retFuture))

  retFuture.cancelCallback = cancellation
  bus.events.mgetOrPut(key, default).waiters.add(cast[FutureBase](retFuture))
  retFuture

proc subscribe*[T](bus: EventBus, event: string,
                   callback: EventBusSubscription[T]): EventBusKey =
  var default: EventItem
  let key = generateKey(T.name, event)
  let subkey = EventBusCallback.init(bus, callback)
  bus.events.mgetOrPut(key, default).subscribers.add(subkey)
  EventBusKey(bus: bus, key: key, cb: subkey)

proc unsubscribe*(bus: EventBus, key: EventBusKey) =
  bus.events.withValue(key.key, item):
    item.subscribers.keepItIf(it != key.cb)

proc pushEvent*[T](bus: EventBus, event: string, data: T) =
  let key = generateKey(T.name, event)
  bus.events.withValue(key, item):
    let eventData = EventDataBase.init(data)
    for waiter in item.waiters:
      var fut = cast[Future[T]](waiter)
      fut.complete(data)
    item.waiters.setLen(0)
    for subscriber in item.subscribers:
      subscriber(bus, eventData)

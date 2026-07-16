#                     Chronos
#
#  (c) Copyright 2026-Present Status Research & Development GmbH
#
#                Licensed under either of
#    Apache License, version 2.0, (LICENSE-APACHEv2)
#                MIT license (LICENSE-MIT)

## Intrusive multi-producer, single-consumer linked list courtesy of D.Vyukov:
##
## https://groups.google.com/g/lock-free/c/Vd9xuHrLggE/m/B9-URa3B37MJ
##
## https://github.com/grivet/mpsc-queue/blob/main/mpsc-queue.h is a modernised
## version thereof upon which this implementation is based.

{.push raises: [], gcsafe.}

import std/atomics

type
  MpscNode* {.inheritable, pure.} = object
    ## Base node type. All node types used with ``MpscQueue`` should embed
    ## or inherit from this, or at minimum have an ``Atomic[ptr MpscNode]``
    ## field named ``next``.
    next*: Atomic[ptr MpscNode]

  MpscQueue*[T] = object
    ## Lock-free Michael & Scott MPSC queue parameterized by node type ``T``.
    ##
    ## ``T`` must have an ``Atomic[ptr T]`` field called ``next`` (which
    ## is naturally the case if ``T`` embeds ``MpscNode`` or declares its
    ## own ``next`` field of the right type).
    head: Atomic[ptr MpscNode]
    tail: Atomic[ptr MpscNode]
    stub: MpscNode

# We need the `stub` pointer to be stable after init so neither moves nor copies
# are permissible
proc `=copy`[T](a: var MpscQueue[T], b: MpscQueue[T]) {.error.}
proc `=move`[T](a: var MpscQueue[T], b: MpscQueue[T]) {.error.}

proc init*[T](q: var MpscQueue[T]) =
  ## Initialize the queue - must be called before any other ops

  q.head.store(addr q.stub, moRelaxed)
  q.tail.store(addr q.stub, moRelaxed)
  q.stub.next.store(nil, moRelaxed)

proc push*[T](q: var MpscQueue[T], node: ptr T) =
  ## Push a node into the queue - may be called concurrently by multiple
  ## producers.
  node[].next.store(nil, moRelaxed)

  let prev = q.head.exchange(node, moAcquireRelease)
  prev[].next.store(node, moRelease)

proc pop*[T](q: var MpscQueue[T]): ptr T =
  ## Try to pop the next node. Returns ``true`` if an item was popped,
  ## and ``nil`` otherwise.
  ##
  ## Only a single consumer may call this function concurrently.
  while true:
    var
      tail = q.tail.load(moRelaxed)
      next = tail.next.load(moAcquire)

    if tail == addr q.stub:
      if next == nil:
        if tail != q.head.load(moAcquire):
          continue

        return nil

      q.tail.store(next, moRelaxed)
      tail = next
      next = tail.next.load(moAcquire)

    if next != nil:
      q.tail.store(next, moRelaxed)
      return (ptr T)(tail)

    if tail != q.head.load(moAcquire):
      continue

    q.push(cast[ptr T](addr q.stub))

    next = tail.next.load(moAcquire)
    if next != nil:
      q.tail.store(next, moRelaxed)
      return (ptr T)(tail)

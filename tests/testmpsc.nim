#                Chronos Test Suite
#            (c) Copyright 2026-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

import unittest2, ../chronos/internal/mpsc

{.used.}

type
  TestNode = object of MpscNode
    value: int

  MpscTestQueue = MpscQueue[TestNode]

proc newTestNode(v: int): ptr TestNode =
  result = createShared(TestNode)
  result[].value = v

suite "MPSC semantics":
  test "single push and pop":
    var q: MpscTestQueue
    q.init()
    let node = newTestNode(42)
    q.push(node)

    let popped = q.pop()
    check popped != nil
    check popped[].value == 42

  test "multiple push and FIFO pop":
    var q: MpscTestQueue
    q.init()
    let n1 = newTestNode(1)
    let n2 = newTestNode(2)
    let n3 = newTestNode(3)
    q.push(n1)
    q.push(n2)
    q.push(n3)

    check q.pop()[].value == 1
    check q.pop()[].value == 2
    check q.pop()[].value == 3
    check q.pop() == nil # Queue is empty

    deallocShared(n1)
    deallocShared(n2)
    deallocShared(n3)

  test "pop on empty queue":
    var q: MpscTestQueue
    q.init()
    check q.pop() == nil

  test "pop non-blocking drain":
    var q: MpscTestQueue
    q.init()

    # Push some items
    var nodes = newSeq[ptr TestNode]()
    for i in 0 ..< 100:
      let node = newTestNode(i)
      nodes.add(node)
      q.push(node)

    # Drain using pop
    var total = 0
    while true:
      let node = q.pop()
      if node == nil:
        break
      check node[].value == total
      inc total

    check total == 100
    # After draining all items, pop should return nil
    check q.pop() == nil

    # Free all nodes
    for n in nodes:
      deallocShared(n)

suite "MPSC stress test":
  setup:
    var q: MpscQueue[TestNode]
    q.init()

  test "10000 push/pop":
    when defined(gcOrc):
      # TODO https://github.com/nim-lang/Nim/issues/26014
      skip()
    else:
      const count = 10000
      var nodes = newSeq[ptr TestNode](count)

      # Push all
      for i in 0 ..< count:
        nodes[i] = newTestNode(i)
        q.push(nodes[i])

      # Pop all
      for i in 0 ..< count:
        let node = q.pop()
        check node != nil
        check node[].value == i

      check q.pop() == nil # Queue is empty

      # Cleanup
      for node in nodes:
        deallocShared(node)

  test "interleaved push/pop":
    when defined(gcOrc):
      # TODO https://github.com/nim-lang/Nim/issues/26014
      skip()
    else:
      var nodes = newSeq[ptr TestNode]()
      var popIdx = 0

      for i in 0 ..< 1000:
        let node = newTestNode(i)
        nodes.add(node)
        q.push(node)

        # Pop every other one
        if i mod 2 == 0:
          let popped = q.pop()
          check popped != nil
          check popped[].value == popIdx
          inc popIdx

      # Drain remaining
      while true:
        let node = q.pop()
        if node == nil:
          break
        check node[].value == popIdx
        inc popIdx

      check popIdx == 1000 # All 1000 items were popped

      # Free all nodes
      for n in nodes:
        deallocShared(n)

  test "multiple producers, single consumer":
    when defined(gcOrc):
      # TODO https://github.com/nim-lang/Nim/issues/26014
      skip()
    else:
      const Producers = 8
      const ItemsPerProducer = 10000

      type ProdArg = object
        q: ptr MpscQueue[TestNode]
        startId: int

      var threads = newSeq[Thread[ProdArg]](Producers)

      proc producer(arg: ProdArg) {.thread.} =
        for i in 0 ..< ItemsPerProducer:
          let node = newTestNode(arg.startId * ItemsPerProducer + i)
          arg.q[].push(node)

      for i in 0 ..< Producers:
        let arg = ProdArg(q: addr q, startId: i)
        createThread(threads[i], producer, arg)

      # Wait for all producers
      joinThreads(threads)

      # Verify all items were pushed
      var total = 0
      while true:
        let node = q.pop()
        if node == nil:
          break
        check node[].value >= 0
        check node[].value < Producers * ItemsPerProducer
        deallocShared(node)
        inc total

      check total == Producers * ItemsPerProducer

  test "100000 items with 100 producers":
    when defined(gcOrc):
      skip()
    else:
      const Producers = 100
      const ItemsPerProducer = 1000

      type ProdArg = object
        q: ptr MpscQueue[TestNode]
        startId: int

      var threads = newSeq[Thread[ProdArg]](Producers)

      proc producer(arg: ProdArg) {.thread.} =
        for i in 0 ..< ItemsPerProducer:
          let node = newTestNode(arg.startId * ItemsPerProducer + i)
          arg.q[].push(node)

      for i in 0 ..< Producers:
        let arg = ProdArg(q: addr q, startId: i)
        createThread(threads[i], producer, arg)

      # Wait for all producers
      joinThreads(threads)

      # Drain and verify
      var total = 0
      while true:
        let node = q.pop()
        if node == nil:
          break
        deallocShared(node)
        inc total

      check total == Producers * ItemsPerProducer

  test "concurrent producers with busy-loop consumer":
    when defined(gcOrc):
      # TODO https://github.com/nim-lang/Nim/issues/26014
      skip()
    else:      
      # Producers push items while a single consumer busy-loops,
      # calling pop() until it has received the expected total.
      const Producers = 8
      const ItemsPerProducer = 5000
      const TotalItems = Producers * ItemsPerProducer

      type ProdArg = object
        q: ptr MpscQueue[TestNode]
        startId: int

      var threads = newSeq[Thread[ProdArg]](Producers)

      proc producer(arg: ProdArg) {.thread.} =
        for i in 0 ..< ItemsPerProducer:
          let node = newTestNode(arg.startId * ItemsPerProducer + i)
          arg.q[].push(node)

      # Spawn producers
      for i in 0 ..< Producers:
        let arg = ProdArg(q: addr q, startId: i)
        createThread(threads[i], producer, arg)

      # Consumer busy-loops: keep calling pop() concurrently with the
      # producers until we've collected the expected number of items.
      var total = 0
      while total < TotalItems:
        let node = q.pop()
        if node != nil:
          check node[].value < TotalItems
          check node[].value >= 0
          inc total
          deallocShared(node)
        # On nil we simply retry (busy-loop)

      # All producers must have finished by now
      joinThreads(threads)

      check total == TotalItems

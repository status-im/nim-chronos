#                Chronos Test Suite
#            (c) Copyright 2018-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

## Tests for `chronos/internal/callbackqueue.nim`'s `CallbackQueue[T]`,
## independent of the contextvars suite: growth mid-drain (including
## while a callback reentrantly schedules more work), ordering,
## integrity across a Defect unwind, and ref-field preservation under
## repeated growth.

import unittest2
import ../chronos/internal/callbackqueue

{.used.}

type
  TestPayload = ref object
    value: int

  TestItem = object
    tag: int
    payload: TestPayload

proc newItem(tag: int): TestItem =
  TestItem(tag: tag, payload: TestPayload(value: tag))

proc drain(q: var CallbackQueue[TestItem]): seq[int] =
  ## Pop everything currently in `q` (a plain len-snapshot drain, no
  ## sentinel), in FIFO order, returning the popped tags.
  let n = q.len
  for _ in 0 ..< n:
    let item = q.popFirst()
    result.add(item.tag)

suite "CallbackQueue: basic semantics":
  test "zero-value queue is valid and empty":
    # Zero value must be usable without an `initCallbackQueue` call --
    # asyncengine.nim's `ticks` field relies on this.
    var q: CallbackQueue[TestItem]
    check q.len == 0

    # First addLast on a never-initialized queue must lazily grow from
    # capacity zero rather than fault.
    q.addLast(newItem(1))
    check q.len == 1
    check q.popFirst().tag == 1
    check q.len == 0

  test "FIFO order, single push/pop":
    var q = initCallbackQueue[TestItem]()
    q.addLast(newItem(1))
    q.addLast(newItem(2))
    q.addLast(newItem(3))
    check q.len == 3
    check q.popFirst().tag == 1
    check q.popFirst().tag == 2
    check q.popFirst().tag == 3
    check q.len == 0

  test "initCallbackQueue rounds capacity up to a power of two":
    # No public `cap` accessor, so this exercises the rounding
    # indirectly: a non-power-of-two initial capacity must still accept
    # at least that many items without growing prematurely.
    var q = initCallbackQueue[TestItem](5)
    for i in 0 ..< 5:
      q.addLast(newItem(i))
    check q.len == 5
    for i in 0 ..< 5:
      check q.popFirst().tag == i

  test "prependNoGrow ordering: sentinel re-insertion at the front":
    # Mirrors the sole real caller: asyncengine.nim's poll() re-inserts
    # a sentinel at the front of an already-fully-drained batch.
    var q = initCallbackQueue[TestItem]()
    q.addLast(newItem(10))
    discard q.popFirst() # drain to empty, as the real caller always does
    check q.len == 0

    q.prependNoGrow(newItem(999))
    q.addLast(newItem(1))
    q.addLast(newItem(2))
    check q.len == 3
    check q.popFirst().tag == 999
    check q.popFirst().tag == 1
    check q.popFirst().tag == 2

  test "sentinel field fidelity through moves (full-struct value, not identity)":
    # The sentinel is compared by full-struct value (see `isSentinel` in
    # asyncengine.nim); its `ref` field (`context`, mirrored here by
    # `payload`) must survive as the same ref, not a copy, across
    # addLast/popFirst and a growth relocation.
    var q = initCallbackQueue[TestItem](2)
    let sentinel = newItem(-1)
    let sentinelPayloadAddr = cast[int](sentinel.payload)

    q.addLast(sentinel)
    # Force growth while the sentinel is still queued.
    q.addLast(newItem(1))
    q.addLast(newItem(2))
    q.addLast(newItem(3))

    let popped = q.popFirst()
    check popped.tag == -1
    check popped == sentinel
    check cast[int](popped.payload) == sentinelPayloadAddr
    check popped.payload.value == -1

    discard drain(q)

suite "CallbackQueue: growth":
  test "growth preserves order, non-wrapped region":
    var q = initCallbackQueue[TestItem](2)
    const count = 50
    for i in 0 ..< count:
      q.addLast(newItem(i))
    check q.len == count
    for i in 0 ..< count:
      check q.popFirst().tag == i
    check q.len == 0

  test "wrapped-region growth: live region spans the physical end of the buffer":
    # Advances head/tail past the wrap boundary before growing, so
    # grow() must relocate a live region physically split across the end
    # and start of the backing array (two copyMem segments), not a
    # contiguous one.
    var q = initCallbackQueue[TestItem](4)
    for i in 0 ..< 4:
      q.addLast(newItem(i))
    for i in 0 ..< 3:
      check q.popFirst().tag == i
    check q.len == 1

    for i in 4 ..< 8:
      q.addLast(newItem(i))
    check q.len == 5 # item 3 (never popped) + items 4..7, post-grow

    q.addLast(newItem(8))
    check q.len == 6

    let popped = drain(q)
    check popped == @[3, 4, 5, 6, 7, 8]

  test "repeated growth cycles preserve ref-field values under memory pressure":
    # grow()'s zeroMem calls prevent a stale ref left in the old backing
    # array from being decref'd a second time when that array's
    # destructor runs. Repeated growth cycles interleaved with unrelated
    # heap allocations increase the odds of surfacing a missing zeroMem
    # as observable corruption rather than it sitting inert.
    var q = initCallbackQueue[TestItem](2)
    var expected: seq[int]
    var popped: seq[int]
    for cycle in 0 ..< 200:
      # Push enough to force growth most cycles; pop most back off but
      # leave a couple alive so grow() relocates a live, ref-bearing
      # region every time.
      for i in 0 ..< 6:
        let tag = cycle * 10 + i
        q.addLast(newItem(tag))
        expected.add tag
      for i in 0 ..< 4:
        let item = q.popFirst()
        popped.add item.tag
        check item.payload.value == item.tag
      # Unrelated heap noise encourages the allocator to reuse whatever
      # grow() just freed.
      discard newSeq[int](64)
      discard newString(64)

    while q.len > 0:
      let item = q.popFirst()
      popped.add item.tag
      check item.payload.value == item.tag

    check popped == expected

  test "growth during reentrant drain across capacity boundaries":
    # Mirrors asyncengine.nim's drain protocol: a callback fires (head
    # already advanced) and reentrantly schedules more work onto the
    # same queue, driving q.len past capacity while head is mid-buffer
    # rather than fresh.
    var q = initCallbackQueue[TestItem](4)
    q.addLast(newItem(0))

    var processed: seq[int]
    var nextTag = 1
    var scheduled = 1 # item 0, already scheduled above
    const totalToSchedule = 25

    while q.len > 0:
      let item = q.popFirst()
      processed.add(item.tag)
      for _ in 0 ..< 2:
        if scheduled < totalToSchedule:
          q.addLast(newItem(nextTag))
          inc nextTag
          inc scheduled

    check processed.len == totalToSchedule
    for i, tag in processed:
      check tag == i
    check q.len == 0

suite "CallbackQueue: integrity under unwind":
  test "post-Defect-unwind queue integrity":
    # popFirst advances head and clears the vacated slot before handing
    # the value to the caller, so a callback that raises must not
    # corrupt the queue for subsequent drains. The try wraps the whole
    # drain loop (not one iteration) to reproduce an unwind out of the
    # loop, mirroring a Defect surfacing from the real poll().
    var q = initCallbackQueue[TestItem](4)
    for i in 0 ..< 6:
      q.addLast(newItem(i))

    var processed: seq[int]
    var raised = false
    try:
      while q.len > 0:
        let item = q.popFirst()
        if item.tag == 3:
          raise (ref ValueError)(msg: "simulated callback failure")
        processed.add(item.tag)
    except ValueError:
      raised = true

    check raised
    check processed == @[0, 1, 2]
    # Item 3 was popped (head already advanced past it before the raise)
    # but never reached `processed` -- consumed and discarded, not
    # corrupting the queue.
    check q.len == 2 # items 4, 5 remain, unprocessed

    # Queue must remain usable after the unwind.
    check q.popFirst().tag == 4
    check q.popFirst().tag == 5
    check q.len == 0
    q.addLast(newItem(100))
    check q.popFirst().tag == 100

suite "CallbackQueue: raw-access guardrail":
  test "private fields do not compile from outside the module":
    # `data`/`head`/`tail` are private; every touch must go through the
    # five public entry points.
    check(not compiles(block:
      var q: CallbackQueue[TestItem]
      discard q.data))
    check(not compiles(block:
      var q: CallbackQueue[TestItem]
      discard q.head))
    check(not compiles(block:
      var q: CallbackQueue[TestItem]
      discard q.tail))

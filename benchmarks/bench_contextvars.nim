#                Chronos Benchmark Suite
#            (c) Copyright 2021-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

## Continuation-local storage (contextvars) cost benchmark.
##
## Each metric runs twice in the same binary: once unused (no binder
## ever pushed, nil ambient context) and once with a contextVar bound
## around the hot loop. Both numbers and their delta are printed
## together.
##
## Bias controls: median-of-`Trials` per phase; `GC_fullCollect()`
## before and after every phase; unused/bound run order alternates per
## metric (`runBothWorlds`/`runBothWorldsInt`).
##
## Chain-depth ladder: `chainVars[0]` .. `chainVars[15]` are a runtime
## `array[16, ContextVar[int]]`, raw-constructed at module init and
## bound via `bindDepth`, a `when`-recursive static-unrolled template
## (no runtime-parametrized "chain of depth N" exists -- unrolling per
## depth is what keeps per-node overhead honest, not loop-amortized).
## `bindDepth(D)` binds `chainVars[0]` outermost through `chainVars[D-1]`
## innermost, so reading `chainVars[0]` at depth D walks all D nodes --
## the worst-case lookup for that depth.
##
## Timing uses `getMonoTime().ticks` differences directly as
## nanoseconds (valid on POSIX, backed by `clock_gettime`).
##
## To compare against a base commit: build and run this file
## identically in both checkouts, once per memory manager, and diff the
## logs by hand.
##
## Run via `nimble benchmarks` (release, both benchmarks/bench_*.nim) or
## directly:
##   nim c -d:release --mm:orc  -r benchmarks/bench_contextvars
##   nim c -d:release --mm:refc -r benchmarks/bench_contextvars

import std/[algorithm, monotimes, strformat]

import chronos
import chronos/contextvars

{.used.}

# --- trial configuration ----------------------------------------------------

const
  Trials = 5
    ## Odd, so the median is a genuine sample rather than an average of
    ## two middle elements.
  CallSoonN = 300_000
  SleepChainN = 30_000
  FutureChurnN = 300_000
  MemPendingFutureN = 150_000
  MemQueuedCallbackN = 150_000
  ChainReadN = 300_000
  MixedBatchN = 300_000

# --- contextVar declarations -------------------------------------------------
# `benchVar`/`mixedVar` back the single-var metrics, raw-constructed --
# private by the constructor's own default (this file is an executable,
# not a library). `chainVars` backs the depth ladder: a per-declaration
# sugar macro cannot mint an indexable family, so the ladder is a
# raw-constructed `array[16, ContextVar[int]]` instead, filled at module
# init (before any thread is created). Named `chainVars`, not `chain`, to
# stay distinct from the local `chain()` procs metric 2 declares below
# (an unrelated await chain).

let benchVar = newContextVar("benchVar", 0)
let mixedVar = newContextVar("mixedVar", 0)

var chainVars: array[16, ContextVar[int]]
for i in 0 ..< chainVars.len:
  chainVars[i] = newContextVar[int]("chain" & $(i + 1), 0)

template bindDepthFrom(i, depth: static int, body: untyped): untyped =
  when i >= depth:
    body
  else:
    chainVars[i].withValue(1):
      bindDepthFrom(i + 1, depth, body)

template bindDepth(depth: static int, body: untyped): untyped =
  ## Nests `withValue` for `chainVars[0] .. chainVars[depth-1]`,
  ## outermost to innermost -- `chainVars[0]` is bound first (oldest, at
  ## the bottom of the stack) and `chainVars[depth-1]` last (newest, at
  ## the top), so reading `chainVars[0]` inside `body` always walks the
  ## full `depth` nodes regardless of how deep the ladder goes. Replaces
  ## the old macro-expansion `withChainDepth` with the same nesting
  ## order, runtime-parametrized over the array but still unrolled per
  ## depth at compile time via `static`.
  static:
    doAssert depth in 1 .. chainVars.len, "bindDepth: depth out of the hand-declared ladder"
  bindDepthFrom(0, depth, body)

# --- median-of-N trial infrastructure ----------------------------------------

proc median(samples: var seq[float]): float =
  samples.sort()
  samples[samples.len div 2]

proc medianInt(samples: var seq[int]): int =
  samples.sort()
  samples[samples.len div 2]

proc benchMedian(trials: int, fn: proc(): float {.closure.}): float =
  ## Run `fn` `trials` times, `GC_fullCollect`ing before and after every
  ## trial (not only around the memory metrics), and return the median.
  ## `fn` is expected to return its own ns/op figure already normalized
  ## by iteration count.
  var samples = newSeq[float](trials)
  for i in 0 ..< trials:
    GC_fullCollect()
    samples[i] = fn()
    GC_fullCollect()
  median(samples)

proc benchMedianInt(trials: int, fn: proc(): int {.closure.}): int =
  var samples = newSeq[int](trials)
  for i in 0 ..< trials:
    GC_fullCollect()
    samples[i] = fn()
    GC_fullCollect()
  medianInt(samples)

var worldOrderBoundFirst = false
  ## Toggled by every `runBothWorlds`/`runBothWorldsInt` call so a fixed
  ## unused-then-bound order cannot make warm-allocator/branch-predictor
  ## carryover systematic across metrics.

proc reportFloat(name: string, unused, bound: float) =
  let delta = if unused == 0.0: 0.0 else: (bound - unused) / unused * 100.0
  echo &"{name:<34} unused={unused:10.2f} ns/op   bound={bound:10.2f} ns/op   delta={delta:+7.1f}%"

proc reportInt(name: string, unused, bound: int) =
  let delta = if unused == 0: 0.0 else: (bound - unused).float / unused.float * 100.0
  echo &"{name:<34} unused={unused:8} B/op     bound={bound:8} B/op     delta={delta:+7.1f}%"

proc runBothWorlds(name: string, unusedFn, boundFn: proc(): float {.closure.}) =
  var unused, bound: float
  if worldOrderBoundFirst:
    bound = benchMedian(Trials, boundFn)
    unused = benchMedian(Trials, unusedFn)
  else:
    unused = benchMedian(Trials, unusedFn)
    bound = benchMedian(Trials, boundFn)
  worldOrderBoundFirst = not worldOrderBoundFirst
  reportFloat(name, unused, bound)

proc runBothWorldsInt(name: string, unusedFn, boundFn: proc(): int {.closure.}) =
  var unused, bound: int
  if worldOrderBoundFirst:
    bound = benchMedianInt(Trials, boundFn)
    unused = benchMedianInt(Trials, unusedFn)
  else:
    unused = benchMedianInt(Trials, unusedFn)
    bound = benchMedianInt(Trials, boundFn)
  worldOrderBoundFirst = not worldOrderBoundFirst
  reportInt(name, unused, bound)

# --- metric 1: callSoon schedule+fire ----------------------------------------

proc benchCallSoonUnused(n: int): float =
  var count = 0
  proc cb(u: pointer) {.gcsafe, raises: [].} =
    inc count
  let start = getMonoTime().ticks
  var scheduled = 0
  while scheduled < n:
    let batch = min(10_000, n - scheduled)
    for i in 0 ..< batch:
      callSoon(cb, nil)
    inc scheduled, batch
    poll()
  while count < n:
    poll()
  (getMonoTime().ticks - start).float / n.float

proc benchCallSoonBound(n: int): float =
  var count = 0
  proc cb(u: pointer) {.gcsafe, raises: [].} =
    inc count
  benchVar.withValue(1):
    let start = getMonoTime().ticks
    var scheduled = 0
    while scheduled < n:
      let batch = min(10_000, n - scheduled)
      for i in 0 ..< batch:
        callSoon(cb, nil)
      inc scheduled, batch
      poll()
    while count < n:
      poll()
    result = (getMonoTime().ticks - start).float / n.float

# --- metric 2: sleepAsync(0) await chain --------------------------------------

proc benchSleepChainUnused(n: int): float =
  proc chain(): Future[void] {.async.} =
    for i in 0 ..< n:
      await sleepAsync(0.milliseconds)
  let start = getMonoTime().ticks
  waitFor chain()
  (getMonoTime().ticks - start).float / n.float

proc benchSleepChainBound(n: int): float =
  proc chain(): Future[void] {.async.} =
    benchVar.withValue(1):
      for i in 0 ..< n:
        await sleepAsync(0.milliseconds)
  let start = getMonoTime().ticks
  waitFor chain()
  (getMonoTime().ticks - start).float / n.float

# --- metric 3: future create/await -------------------------------------------

proc benchFutureChurnUnused(n: int): float =
  proc mk(): Future[int] {.async.} =
    return 1
  proc run(): Future[int] {.async.} =
    var acc = 0
    for i in 0 ..< n:
      acc += await mk()
    return acc
  let start = getMonoTime().ticks
  discard waitFor run()
  (getMonoTime().ticks - start).float / n.float

proc benchFutureChurnBound(n: int): float =
  proc mk(): Future[int] {.async.} =
    return 1
  proc run(): Future[int] {.async.} =
    var acc = 0
    benchVar.withValue(1):
      for i in 0 ..< n:
        acc += await mk()
    return acc
  let start = getMonoTime().ticks
  discard waitFor run()
  (getMonoTime().ticks - start).float / n.float

# --- metric 4: mem / pending future -------------------------------------------

proc benchMemPendingFutureUnused(n: int): int =
  var futs = newSeqOfCap[Future[void]](n)
  GC_fullCollect()
  let before = getOccupiedMem()
  for i in 0 ..< n:
    futs.add newFuture[void]("bench")
  result = (getOccupiedMem() - before) div n
  GC_fullCollect()
  for f in futs:
    f.complete()

proc benchMemPendingFutureBound(n: int): int =
  var futs = newSeqOfCap[Future[void]](n)
  GC_fullCollect()
  benchVar.withValue(1):
    let before = getOccupiedMem()
    for i in 0 ..< n:
      futs.add newFuture[void]("bench")
    result = (getOccupiedMem() - before) div n
  GC_fullCollect()
  for f in futs:
    f.complete()

# --- metric 5: mem / queued callback ------------------------------------------
#
# callSoon always queues onto the one per-thread dispatcher's Deque,
# whose backing buffer capacity only grows -- so median-of-N or
# back-to-back measurement on the same thread would collapse to ~0
# bytes/op after the first run warms the capacity. Each world instead
# gets a fresh OS thread with its own pristine-capacity dispatcher.

var queuedCallbackMemResult: int
  ## Set by `queuedCallbackMemThread` on its own thread, read on the
  ## main thread after `joinThread` establishes the happens-before edge.

proc queuedCallbackMemThread(bound: bool) {.thread, nimcall.} =
  var count = 0
  proc cb(u: pointer) {.gcsafe, raises: [].} =
    inc count
  GC_fullCollect()
  template measure() =
    let before = getOccupiedMem()
    for i in 0 ..< MemQueuedCallbackN:
      callSoon(cb, nil)
    queuedCallbackMemResult = (getOccupiedMem() - before) div MemQueuedCallbackN
  if bound:
    benchVar.withValue(1):
      measure()
  else:
    measure()
  GC_fullCollect()
  while count < MemQueuedCallbackN:
    poll()

proc benchMemQueuedCallbackFresh(bound: bool): int =
  var t: Thread[bool]
  createThread(t, queuedCallbackMemThread, bound)
  joinThread(t)
  queuedCallbackMemResult

# --- bound single-var steady state / chain-depth ladder ----------------------

proc benchChainReadUnused(n: int): float =
  var acc = 0
  let start = getMonoTime().ticks
  for i in 0 ..< n:
    acc += chainVars[0].value
  result = (getMonoTime().ticks - start).float / n.float
  doAssert acc == 0, "unbound chainVars[0].value must read the declared default"

proc benchChainReadBound(n: int, depth: static int): float =
  var acc = 0
  bindDepth(depth):
    let start = getMonoTime().ticks
    for i in 0 ..< n:
      acc += chainVars[0].value
    result = (getMonoTime().ticks - start).float / n.float
  doAssert acc == n, "chainVars[0].value must read its bound value (1) at every depth"

# --- mixed bound/unbound batch (branch-predictor-hostile interleaving) -------

proc benchMixedBatch(n: int): float =
  var count = 0
  proc cb(u: pointer) {.gcsafe, raises: [].} =
    inc count
  let start = getMonoTime().ticks
  var scheduled = 0
  while scheduled < n:
    let batch = min(10_000, n - scheduled)
    for i in 0 ..< batch:
      if (scheduled + i) mod 2 == 0:
        callSoon(cb, nil)
      else:
        mixedVar.withValue(1):
          callSoon(cb, nil)
    inc scheduled, batch
    poll()
  while count < n:
    poll()
  (getMonoTime().ticks - start).float / n.float

# --- report -------------------------------------------------------------------

proc runReport() =
  const mmName =
    when defined(gcOrc): "orc"
    elif defined(gcArc): "arc"
    elif defined(gcRefc): "refc"
    elif defined(gcMarkAndSweep): "markAndSweep"
    else: "unknown"
  echo &"chronos contextvars benchmark -- mm={mmName} release={defined(release)}"
  echo ""

  echo "-- struct sizes --"
  echo &"sizeof(AsyncCallback):        {sizeof(AsyncCallback)} bytes"
  block:
    let sizeofProbe = newFuture[void]("sizeof-probe")
    echo &"sizeof(Future[void] object): {sizeof(sizeofProbe[])} bytes"
    sizeofProbe.complete()
  echo ""

  echo "-- five metrics, both worlds (unused vs. one contextVar bound around the hot loop) --"
  runBothWorlds("callSoon schedule+fire",
    proc(): float = benchCallSoonUnused(CallSoonN),
    proc(): float = benchCallSoonBound(CallSoonN))
  runBothWorlds("sleepAsync(0) await chain",
    proc(): float = benchSleepChainUnused(SleepChainN),
    proc(): float = benchSleepChainBound(SleepChainN))
  runBothWorlds("future create/await",
    proc(): float = benchFutureChurnUnused(FutureChurnN),
    proc(): float = benchFutureChurnBound(FutureChurnN))
  runBothWorldsInt("mem / pending future",
    proc(): int = benchMemPendingFutureUnused(MemPendingFutureN),
    proc(): int = benchMemPendingFutureBound(MemPendingFutureN))
  block:
    # Single-shot, fresh-dispatcher-per-world -- see the comment above
    # `queuedCallbackMemThread` for why this metric cannot use the
    # shared median-of-N machinery.
    var unused, bound: int
    if worldOrderBoundFirst:
      bound = benchMemQueuedCallbackFresh(true)
      unused = benchMemQueuedCallbackFresh(false)
    else:
      unused = benchMemQueuedCallbackFresh(false)
      bound = benchMemQueuedCallbackFresh(true)
    worldOrderBoundFirst = not worldOrderBoundFirst
    reportInt("mem / queued callback", unused, bound)
  echo ""

  echo "-- bound single-var steady state + chain-depth ladder (contextLookup O(depth) walk) --"
  let unboundRead = benchMedian(Trials, proc(): float = benchChainReadUnused(ChainReadN))
  echo &"chain[0].value read, unbound (epsilon baseline) {unboundRead:10.2f} ns/op"
  let depth1 = benchMedian(Trials, proc(): float = benchChainReadBound(ChainReadN, 1))
  echo &"chain[0].value read, bound, depth=1 (steady state){depth1:10.2f} ns/op"
  let depth4 = benchMedian(Trials, proc(): float = benchChainReadBound(ChainReadN, 4))
  echo &"chain[0].value read, bound, depth=4               {depth4:10.2f} ns/op"
  let depth16 = benchMedian(Trials, proc(): float = benchChainReadBound(ChainReadN, 16))
  echo &"chain[0].value read, bound, depth=16              {depth16:10.2f} ns/op"
  echo ""

  echo "-- mixed bound/unbound batch (branch-predictor-hostile interleaving) --"
  let mixed = benchMedian(Trials, proc(): float = benchMixedBatch(MixedBatchN))
  echo &"callSoon schedule+fire, alternating bound/unbound  {mixed:10.2f} ns/op"

when isMainModule:
  runReport()

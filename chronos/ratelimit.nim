#
#                 Chronos Rate Limiter
#              (c) Copyright 2020-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

## This module implements rate limiting algorithm which is heavy inspired by
## article "How we built rate limiting capable of scaling to millions of
## domains" by Julien Desgats.
## https://blog.cloudflare.com/counting-things-a-lot-of-different-things/
##
## Performance of this algorithm mostly depends on performance of hash table,
## in our case it depends on performance of Nim's Tables.
##
## Implementation supports standalone rate limiters for specific subject
## (URL, resource name or any other identifier) and rate limiters for
## for specific subject (URL, resource name or any other identifier) and
## consumers of this subject (resource). So you can rate limit specific consumer
## access to a specific resource.
##
## This is example on how to use rate limit for specific resource only:
##
##  .. code-block::nim
##    var limiter = RateLimiter.init()
##    # We are limiting access to resource "/some/resource" to rate 5 req/sec.
##    limiter.newRateCounter("/some/resource", 1.seconds, 5)
##
##    var sucess = 0
##    var failed = 0
##    for i in 0 ..< 100:
##      # We are performing check using `checkRate(resource)`.
##      if rlim.checkRate("/some/resource"):
##        inc(succeed)
##      else:
##        inc(failed)
##    echo "Number of successfull requests = ", succeed
##    echo "Number of failed requests = ", failed
##
## Next example is how to use rate limit for resource and consumers:
##
##  .. code-block::nim
##    var limiter = RateLimiter.init()
##    # We are limiting access to resource "/some/resource" to rate 5 req/sec.
##    limiter.newRateCounter("/some/resource", 1.seconds, 5)
##    # We going to introduce 3 consumers, so we declaring 3 counters.
##    var success = @[0, 0, 0]
##    var failed = @[0, 0, 0]
##
##    for i in 0 ..< 100:
##      if rlim.checkRate("/some/resource", "client1"):
##        inc(success[0])
##      else:
##        inc(failed[0])
##
##    for i in 0 ..< 100:
##      if rlim.checkRate("/some/resource", "client2"):
##        inc(success[1])
##      else:
##        inc(failed[1])
##
##    for i in 0 ..< 100:
##      if rlim.checkRate("/some/resource", "client3"):
##        inc(success[2])
##      else:
##        inc(failed[2])
##
##    echo "[client1] Number of successfull requests = ", succeed[0]
##    echo "[client1] Number of failed requests = ", failed[0]
##    echo "[client2] Number of successfull requests = ", succeed[1]
##    echo "[client2] Number of failed requests = ", failed[1]
##    echo "[client3] Number of successfull requests = ", succeed[2]
##    echo "[client3] Number of failed requests = ", failed[2]
##
## When using two counter you can easily apply per-resource and per-consumer
## rate limits at once, but beware using ``checkRate()`` procedure inside of
## ``if`` statement.
##
##  .. code-block::nim
##    # ...
##    if rlim.checkRate("/some/resource") and
##       rlim.checkRate("/some/resource/consumers", "client1"):
##      echo "Request received"
##
## If initial ``rlim.checkRate("/some/resource")`` returns ``false`` then
## second statement
## ``rlim.checkRate("/some/resource/consumers", "client1")`` will not be
## executed at all and so access will not be properly counted.
##
## To avoid this problem get results of checks before checking it in ``if``
## statement.
##
##  .. code-block::nim
##    # ...
##    let check1 = rlim.checkRate("/some/resource")
##    let check2 = rlim.checkRate("/some/resource/consumers", "client1")
##    if check1 and check2:
##      echo "Request received"
##
import tables, timer

type
  RateCounter* = object
    period*: Duration
    maxreqs*: float
    start*: int64
    requests*: array[2, uint64]

  RateLimiter* = ref object
    rates*: Table[string, RateCounter]
    counters*: Table[string, RateCounter]

proc init*(t: typedesc[RateLimiter]): RateLimiter =
  ## Crate new RateLimiter object.
  RateLimiter(rates: initTable[string, RateCounter]())

proc newRateCounter*(rl: RateLimiter, name: string, period: Duration,
                     requests: uint64) =
  ## Create new limiter for requests with name ``name``, to allow only
  ## number of ``requests`` per period of time ``time``.
  ##
  ## This limiter could be used as standalone, or it can be used as base
  ## for other
  ##
  ## For example to rate limit request with name ``test1`` for
  ## 10 requests per minute:
  ## newRateCounter(rl, "test1", 1.minutes, 10'u64)
  ## or to rate limit request with name "test2" for 1_000 requests per
  ## 10 seconds:
  ## newRateCounter(rl, "test", 10.seconds, 1_000'u64)
  let counter = RateCounter(period: period, maxreqs: float(requests))
  rl.rates[name] = counter

proc removeRate*(rl: RateLimiter, name: string) =
  ## Remove subject with name ``name`` from rate-limiter ``rl``.
  rl.rates.del(name)
  rl.counters.del(name)

proc removeCounter*(rl: RateLimiter, name: string, remote: string = "") =
  ## Remove subject with name ``name`` and identifier ``remote`` from
  ## rate-limiter ``rl``.
  let key = if len(remote) > 0: name & "|" & remote else: name
  rl.counters.del(key)

template nanoseconds(a: Moment): int64 =
  (a - Moment()).nanoseconds()

proc getCounter*(rl: RateLimiter, name: string,
                 remote: string = ""): RateCounter =
  ## Obtain current counter object for subject with name ``name`` and
  ## identifier ``remote``.
  let key = if len(remote) > 0: name & "|" & remote else: name
  rl.counters.getOrDefault(key)

proc checkRate*(rl: RateLimiter, name: string, remote: string = ""): bool =
  ## Returns ``true`` if request with subject ``name`` and optional value
  ## ``remote`` still follows rate limiting rules for subject ``name``.
  let key = if len(remote) > 0: name & "|" & remote else: name
  rl.counters.withValue(key, ctr) do:
    let curtime = Moment.now().nanoseconds()
    let nanosInPeriod = ctr.period.nanoseconds()
    let current = curtime div nanosInPeriod
    var index = current - ctr.start
    let rate =
      if index == 0:
        # Request still in first counter
        inc(ctr.requests[0])
        float(ctr.requests[0])
      elif index == 1:
        # Request in second counter
        inc(ctr.requests[1])
        let modulo = curtime mod nanosInPeriod
        float(ctr.requests[0]) *
          (float(nanosInPeriod - modulo) / float(nanosInPeriod)) +
          float(ctr.requests[1])
      elif index == 2:
        # Request passed second counter
        inc(ctr.start)
        ctr.requests[0] = ctr.requests[1]
        ctr.requests[1] = 1'u64
        let modulo = curtime mod nanosInPeriod
        float(ctr.requests[0]) *
          (float(nanosInPeriod - modulo) / float(nanosInPeriod)) +
          float(ctr.requests[1])
      else:
        # Request after big timeout
        ctr.start = current
        ctr.requests[0] = 1'u64
        ctr.requests[1] = 0'u64
        float(0.0)
    return (rate <= ctr.maxreqs)
  do:
    var rate = rl.rates.getOrDefault(name)
    if rate.maxreqs > 0.0 and rate.period != ZeroDuration:
      let curtime = Moment.now().nanoseconds()
      let nanosInPeriod = rate.period.nanoseconds()
      let current = curtime div nanosInPeriod
      rate.start = current
      rate.requests[0] = 1'u64
      rate.requests[1] = 0'u64
      rl.counters[key] = rate
      return true
    else:
      return true

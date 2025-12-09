# TokenBucket — Usage Modes (Overview)

TokenBucket provides several usage modes and patterns depending on how you want to rate-limit:

- Continuous mode (default):
	- Mints tokens proportionally to elapsed time at a constant rate (`capacity / fillDuration`), adding only whole tokens.
	- When the bucket is full for an interval, the elapsed time is burned (no “credit banking”).
	- If an update would overfill, budget is clamped to capacity and leftover elapsed time is discarded; `lastUpdate` is set to the current time.
	- Nanosecond-level accounting for precise behavior.

- Discrete mode:
	- Replenishes only after a full `fillDuration` has elapsed (step-like refill behavior).
	- Before the period boundary, budget does not increase; after the boundary, budget jumps to capacity.
	- Use when you need hard period boundaries rather than proportional accrual.
	- If you need exact start time for period alignment, set `startTime` argument of `new` constructor.

- Manual-only replenish (fillDuration = 0):
	- Disables automatic minting; tokens can only be added via `replenish(tokens)`.
	- Replenish is capped at capacity and wakes pending consumers.

- Synchronous consumption: `tryConsume(tokens, now)`
	- Attempts to consume immediately; returns `true` on success, `false` otherwise.
	- If consuming from full, `lastUpdate` is set to `now` (prevents idle-at-full credit banking in Continuous mode).

- Asynchronous consumption: `consume(tokens, now) -> Future[void]`
	- Returns a future that completes when tokens become available (or can be cancelled).
	- Internally, the waiter is woken around the time enough tokens are expected to accrue, or earlier if `replenish()` is called.

- Capacity and timing introspection: `getAvailableCapacity(now)`
	- Computes the budget as of `now` without mutating bucket state.

- Manual replenishment: `replenish(tokens, now)`
	- Adds tokens (capped to capacity), updates timing, and wakes waiters.

The sections below illustrate Continuous semantics with concrete timelines and compare them with the older algorithm for context.

# Example Scenarios for Continuous Mode
## TokenBucket Continuous Mode — Scenario 1 Timeline

Assumptions:
- Capacity `C = 10`
- `fillDuration = 1s` (per-token time: 100ms)
- Start: `t = 0ms`, `budget = 10`, `lastUpdate = 0ms`

Legend:
- Minted tokens: tokens added by Continuous update at that step (TA)
- Budget after mint: budget after minting, before the consume at that row
- Budget after consume: budget left after processing the request at that row
- LU set?: whether `lastUpdate` changes at that step (reason)

Only request events are listed below (no passive availability checks):

| Time    | Elapsed from LU | Budget (in) | Request tokens | Minted tokens (TA) | Budget after mint | Budget after consume | LU set?                          |
|---------|------------------|-------------|----------------|--------------------|-------------------|----------------------|-----------------------------------|
| 0 ms    | n/a              | 10          | 7              | 0                  | 10                | 3                    | yes (consume/full → 0 ms)         |
| 200 ms  | 200 ms           | 3           | 5              | 2                  | 5                 | 0                    | yes (update → 200 ms)             |
| 650 ms  | 450 ms           | 0           | 3              | 4                  | 4                 | 1                    | yes (update → 600 ms)             |
| 1200 ms | 600 ms           | 1           | 6              | 6                  | 7                 | 1                    | yes (update → 1200 ms)            |
| 1800 ms | 600 ms           | 1           | 5              | 6                  | 7                 | 2                    | yes (update → 1800 ms)            |
| 2100 ms | 300 ms           | 2           | 10             | 3                  | 5                 | 5 (insufficient)     | yes (update → 2100 ms)            |
| 2600 ms | 500 ms           | 5           | 10             | 5 (to cap)         | 10 (hit cap)      | 0                    | yes (update hit cap → 2600 ms); yes (consume/full → 2600 ms) |

Notes:
- When an update would overfill the bucket, it is clamped to capacity and `lastUpdate` is set to the current time; leftover elapsed time is discarded.
- Consuming from a full bucket sets `lastUpdate` to the consume time (prevents idle-at-full credit banking).

### Consumption Summary (0–3s window)

Per `fillDuration` period (1s each):

| Period         | Requests within period                         | Tokens consumed |
|----------------|-------------------------------------------------|-----------------|
| 0–1000 ms      | 0ms:7, 200ms:5, 650ms:3                        | 15              |
| 1000–2000 ms   | 1200ms:6, 1800ms:5                             | 11              |
| 2000–3000 ms   | 2100ms:10 (insufficient), 2600ms:10 (consumed) | 10              |

Total consumed over 3 seconds: 15 + 11 + 10 = 36 tokens.

## High-rate single-token requests (Continuous)

Settings:
- Capacity `C = 10`, `fillDuration = 10ms` (per-token time: 1ms)
- Window to observe: `0–40ms` (4 full periods)
- Requests are 1 token each; batches occur at specific timestamps.

We show how the bucket rejects attempts that exceed the available budget at each instant, ensuring no more than `capacity + minted` tokens are usable in any time frame. Over `0–40ms`, at most `10 (initial capacity) + 4 × 10 (mint) = 50` tokens can be consumed.

Request batches and outcomes:

| Time   | Elapsed from LU | Budget before | Minted (PT→TA) | Budget after mint | Requests (×1) | Accepted | Rejected | Budget after consume | LU after |
|--------|------------------|---------------|-----------------|-------------------|---------------|----------|----------|----------------------|---------|
| 0 ms   | n/a              | 10            | 0               | 10                | 12            | 10       | 2        | 0                    | 0 ms    |
| 5 ms   | 5 ms             | 0             | 5 → 5           | 5                 | 7             | 5        | 2        | 0                    | 5 ms    |
| 10 ms  | 5 ms             | 0             | 5 → 5           | 5                 | 15            | 5        | 10       | 0                    | 10 ms   |
| 12 ms  | 2 ms             | 0             | 2 → 2           | 2                 | 3             | 2        | 1        | 0                    | 12 ms   |
| 20 ms  | 8 ms             | 0             | 8 → 8           | 8                 | 25            | 8        | 17       | 0                    | 20 ms   |
| 30 ms  | 10 ms            | 0             | 10 → 10         | 10                | 9             | 9        | 0        | 1                    | 30 ms   |
| 31 ms  | 1 ms             | 1             | 1 → 1           | 2                 | 3             | 2        | 1        | 0                    | 31 ms   |
| 40 ms  | 9 ms             | 0             | 9 → 9           | 9                 | 20            | 9        | 11       | 0                    | 40 ms   |

Totals over 0–40ms:
- Attempted: 12 + 7 + 15 + 3 + 25 + 9 + 3 + 20 = 94 requests
- Accepted: 10 + 5 + 5 + 2 + 8 + 9 + 2 + 9 = 50 tokens (matches `10 + 4×10`)
- Rejected: 94 − 50 = 44 requests

Why the rejections happen (preventing overuse):
- At any given instant, you can only consume up to the tokens currently in the bucket.
- Between instants, tokens mint continuously at `capacity / fillDuration = 1 token/ms`; the table shows how many become available just before each batch.
- When a batch demands more than available, the excess is rejected (or would be queued with `consume()`), enforcing the rate limit.
- Over any observation window, the maximum consumable tokens = initial available (up to capacity) + tokens minted during that window; here, that cap is `10 + (40ms × 1/ms) = 50`.
# SI — Limit Order Book, Matching Engine, and Market Design Laboratory

A single-instrument limit order book and matching engine in C++, built for latency and measured rigorously, wrapped in an agent-based market simulator that lets you change the rules of the market and observe what happens.

---

## Goal

Three claims, each backed by an artifact in this repository:

1. **Exchange-grade matching, done correctly.** Price-time priority, full order type coverage, faithful edge-case behaviour. Evidenced by a differential fuzz harness against a deliberately naive reference implementation.

2. **Latency engineering that is measured, not asserted.** Data structures chosen for cache behaviour, zero allocation on the hot path, and a documented sequence of optimizations each with before/after percentiles and a confirmed mechanism. Evidenced by `BENCHMARKS.md`.

3. **Market microstructure understood, not decorated.** Spread, depth, impact, and adverse selection emerge from agent interaction rather than being hardcoded, and the simulator is used to run controlled experiments on market rules. Evidenced by the experiment results in `docs/`.

The engine's speed is not an end in itself here. It is the enabling constraint: a parameter sweep is hundreds of replications of a market, and an engine fast enough makes that interactive rather than an overnight job.

---

## What the system does

```
config + seed → agents → orders → [matching engine] → feed → analytics
                  ↑                                     │
                  └─────────────────────────────────────┘
                        (agents react to the book)
```

Nothing about the market is scripted. The only exogenous input is a latent fundamental value `V(t)` following a random walk. Price, spread, depth, volatility clustering, and market impact all emerge from agents reacting to each other and to their own delayed views of the book.

---

## Design

### Engine

- Prices are `int64_t` tick counts. No floating point anywhere in the engine.
- Price levels in a flat array over a bounded tick range, indexed arithmetically.
- Best bid/ask tracked incrementally, backed by a bitset over occupied levels for next-level lookup.
- Resting orders in an intrusive doubly-linked FIFO per level, nodes living in a pre-allocated slab with 32-bit index links.
- `order_id → slab index` via an open-addressing hash map, pre-sized, never rehashed on the hot path.
- Cancel is O(1): one hash lookup, one unlink, one free-list push.
- Order types: limit, market (with tick protection), IOC, FOK, post-only, cancel, modify. Size decrease keeps queue position; price change or size increase does not.
- No allocation, no exceptions, no virtual dispatch, no I/O, no logging on the hot path. Cold paths are out-of-line.

The engine has no clock and no sockets, depends on nothing, and does not know whether it is being benchmarked or driven live.

### Agents

Each agent has its own RNG stream seeded from `(global_seed, agent_id)`, its own feed latency, and its own order latency — both drawn from configurable distributions. An agent sees the book as its delayed feed has delivered it, not as it currently is. Adverse selection is not implemented anywhere; it falls out of this.

- **Noise traders** — Poisson (or Hawkes) arrivals, no view, random side and size. The volume that makes market making viable.
- **Market makers** — quote two-sided around their mid estimate, skew against inventory, re-quote on a timer and on large moves. The source of resting depth.
- **Informed traders** — act on a noisy, delayed estimate of `V(t)`. What anchors price to the fundamental, and what makes market making risky.
- **Momentum traders** — react to recent signed trade flow. Source of amplification and instability.

### Execution modes

| Mode | Clock | Driver | Determinism |
|---|---|---|---|
| Batch / experiment | virtual | live agents | byte-identical per seed |
| Benchmark | none (open loop) | recorded flow tape | byte-identical per seed |
| Interactive | `steady_clock` | live agents + human | replayable from order log |

Same engine, same agent code, three harnesses. Benchmarks run against a deterministic tape so that measurement is reproducible; agents are never in the measured path.

### Concurrency

Matching for a single instrument is strictly single-threaded — price-time priority is a total order, and that is the correct design rather than a limitation. Parallelism lives elsewhere, and four configurations are benchmarked against each other:

| | Architecture |
|---|---|
| **A** | Monolithic — decode, match, encode, publish on one thread |
| **B** | Pipelined — decode / match / encode across threads joined by SPSC rings |
| **C** | Sharded — N engine threads over disjoint instrument sets |
| **D** | Shared book behind a mutex, N workers — the deliberate strawman |

SPSC rings use power-of-two masking, locally cached opposite indices, acquire/release ordering, cache-line padding between producer and consumer state, and batched publish. All threads pinned; core placement is treated as a measured variable.

The headline result is **p99 latency against offered load** for all four configurations, not a single number per configuration. Config A is expected to win at low load — a ring handoff costs a cache line transfer that buys nothing when there is no work to overlap — and the crossover point where B takes over is the finding.

Configuration C is also how experiment sweeps are run: independent replications are perfectly parallel.

### Market data feed

ITCH-style binary: `AddOrder`, `OrderExecuted`, `OrderCancelled`, `OrderReplaced`, `Trade`, each with a monotonic sequence number, plus periodic snapshots for late joiners. A `reconstruct` tool rebuilds the book from a recorded feed and asserts it matches the engine's final state — both a correctness test and proof that the feed is complete.

---

## Benchmark methodology

- **Open loop.** Arrival schedule is fixed in advance; if the engine falls behind, the lateness is measured. A closed-loop harness would silently hide queueing delay (coordinated omission).
- **Percentiles, never means.** p50 / p90 / p99 / p99.9 / max, into HDR histograms recorded in pre-allocated storage.
- `rdtscp` with the timer's own overhead measured and subtracted; `constant_tsc` and `nonstop_tsc` verified.
- Threads pinned, turbo and frequency scaling disabled, warmup discarded.
- Run-to-run variance reported across repeated runs. A result that cannot be reproduced is not a result.
- `perf stat` counters captured alongside each optimization to confirm the mechanism matches the hypothesis.

`BENCHMARKS.md` records every change as a commit, a one-line description, before/after percentiles, and the mechanism. Entries where the number got worse and the change was reverted are kept.

---

## Market design laboratory

The primary interface is not a trading screen — it is an experiment designer. You choose a baseline market configuration, pick parameters to sweep, run replications, and compare outcomes.

**Rules you can change:** tick size, maker/taker fees and rebates, lot size, price-time vs pro-rata allocation, self-trade prevention, market order protection bands, post-only availability.

**Population you can change:** counts and parameters of each agent type, latency distributions per type, uniform vs stratified latency.

**Environment you can change:** fundamental volatility and jump behaviour, Poisson vs Hawkes arrival clustering.

**Outcomes measured on every run:**

- *Market quality* — time-weighted spread, depth at touch and at N ticks, effective and realized spread, price efficiency against `V`, volatility, fill ratios, time-to-fill.
- *Welfare split* — market maker P&L, informed trader P&L, noise trader costs, fees collected. Most rule changes move value rather than destroying it; showing where is the point.
- *Fragility* — recovery time after a liquidity shock, worst gap, depth resilience.

### Experimental discipline

- **Common random numbers** across compared configurations, so differences are attributable to the rule change rather than to luck.
- **Replications with confidence intervals.** No single-run results, no bar charts without error bars.
- **Burn-in** discarded before measurement, with the length stated.
- **Baseline validation before any experiment.** The baseline must reproduce known stylized facts — fat-tailed returns, volatility clustering, square-root impact, imbalance predicting the next move — before comparative results from it mean anything.

### Preset experiments

- Tick size sweep: does a smaller tick narrow spreads, or fragment depth and erode queue priority?
- Maker rebate sweep: how much of a rebate is passed through to the quoted spread?
- Latency stratification: a market with a fast minority versus one with uniform latency at the same mean.
- Price-time versus pro-rata allocation.
- Informed trader density: spread should widen endogenously.

---

## Scope and honesty

**In scope:** matching engine, full order type set, binary feed, agent-based flow, threading comparison, benchmark harness, microstructure measurement, experiment runner, web interface with a manual trading seat.

**Out of scope:** multi-venue routing, auctions and halts, cross-asset effects, kernel bypass, anything resembling a real firm's strategies.

**What this is not:** a model of any real market. Results are statements about this model under these parameters. "In this model, pro-rata allocation increased quoted depth by X%" is defensible; "pro-rata allocation increases depth" is not.

---

## Milestones

1. Core book, naive reference implementation, differential fuzz harness — all green before any optimization.
2. Agents and the virtual-time simulator; a market that produces plausible output.
3. Open-loop benchmark harness; establish the config A baseline.
4. Optimization pass — slab, flat levels, bitset, struct layout — each change benchmarked and logged individually.
5. SPSC ring; configs B, C, D; the load sweep and comparison.
6. Feed and reconstructor.
7. Experiment runner, replications, common random numbers.
8. Gateway and web interface.
9. Baseline validation, preset experiments, writeup.

Steps 3 and 4 stay in that order. A baseline measured after optimizing is not a baseline.

---

## Build

```sh
cmake --preset release
cmake --build --preset release
ctest --preset release
```

Presets: `debug`, `release`, `asan`, `tsan`, `bench`.

## Layout

```
engine/       matching core — no I/O, no threads, no dependencies
feed/         binary market data encoding, sequencing, snapshots
sim/          virtual clock, event queue, latency models, agents
concurrency/  SPSC ring, cache-line utilities, thread pinning
analytics/    microstructure metrics over recorded feeds
experiments/  sweep runner, replication, common random numbers, statistics
gateway/      real-time process: drives engine, serves WebSocket
bench/        open-loop benchmark harness and histograms
tools/        flowgen, replay, reconstruct, sweep CLIs
tests/        unit, reference implementation, differential fuzz, determinism
web/          browser client
configs/      baseline, scenarios, experiment definitions
docs/         design notes and experiment results
```

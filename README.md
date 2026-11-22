# SI — Limit Order Book, Matching Engine, and Market Design Laboratory

A single-instrument limit order book and matching engine in C++, built for latency and measured rigorously, wrapped in an agent-based market simulator that lets you change the rules of the market and observe what happens.

---

## Table of Contents

- [Goal](#goal)
- [What the System Does](#what-the-system-does)
- [Design](#design)
  - [Engine](#engine)
  - [Agents](#agents)
  - [Execution Modes](#execution-modes)
  - [Architecture](#architecture)
  - [Concurrency](#concurrency)
  - [Market Data Feed](#market-data-feed)
- [Benchmark Methodology](#benchmark-methodology)
- [Market Design Laboratory](#market-design-laboratory)
- [API](#api)
- [Setup and Development](#setup-and-development)
  - [Prerequisites](#prerequisites)
  - [Clone and Build](#clone-and-build)
  - [Pre-commit Hooks](#pre-commit-hooks)
  - [Workflow: Issues, Branches, and PRs](#workflow-issues-branches-and-prs)
  - [Commit Message Format](#commit-message-format)
  - [Branch Naming Convention](#branch-naming-convention)
  - [What Happens Automatically](#what-happens-automatically)
- [Layout](#layout)
- [Scope and Honesty](#scope-and-honesty)
- [Milestones](#milestones)

---

## Goal

Three claims, each backed by an artifact in this repository:

1. **Exchange-grade matching, done correctly.** Price-time priority, full order type coverage, faithful edge-case behaviour. Evidenced by a differential fuzz harness against a deliberately naive reference implementation.

2. **Latency engineering that is measured, not asserted.** Data structures chosen for cache behaviour, zero allocation on the hot path, and a documented sequence of optimizations each with before/after percentiles and a confirmed mechanism. Evidenced by `BENCHMARKS.md`.

3. **Market microstructure understood, not decorated.** Spread, depth, impact, and adverse selection emerge from agent interaction rather than being hardcoded, and the simulator is used to run controlled experiments on market rules. Evidenced by the experiment results in `docs/`.

The engine's speed is not an end in itself here. It is the enabling constraint: a parameter sweep is hundreds of replications of a market, and an engine fast enough makes that interactive rather than an overnight job.

---

## What the System Does

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

### Execution Modes

| Mode | Clock | Driver | Determinism |
|---|---|---|---|
| Batch / experiment | virtual | live agents | byte-identical per seed |
| Benchmark | none (open loop) | recorded flow tape | byte-identical per seed |

Same engine, same agent code, two harnesses. Benchmarks run against a deterministic tape so that measurement is reproducible; agents are never in the measured path.

### Architecture

The system is split into a C++ backend and a browser frontend, communicating over HTTP/JSON.

The backend is a single C++ binary with an embedded HTTP server. It receives a simulation configuration, runs the engine and agents, and returns results. The core boundary is a function: `SimResult run_simulation(const SimConfig& config)`. Everything above it (HTTP, JSON parsing, job management) is a thin shell; everything below it (engine, agents, analytics) is the project.

The frontend submits configurations, polls for progress, and renders results. During a run, the backend flushes computed data progressively — the chart grows from left to right as the simulation advances. Summary metrics arrive only when the run completes.

No WebSockets. Five stateless HTTP endpoints handle all communication (see [API](#api) below).

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

### Market Data Feed

ITCH-style binary: `AddOrder`, `OrderExecuted`, `OrderCancelled`, `OrderReplaced`, `Trade`, each with a monotonic sequence number, plus periodic snapshots for late joiners. A `reconstruct` tool rebuilds the book from a recorded feed and asserts it matches the engine's final state — both a correctness test and proof that the feed is complete.

---

## Benchmark Methodology

- **Open loop.** Arrival schedule is fixed in advance; if the engine falls behind, the lateness is measured. A closed-loop harness would silently hide queueing delay (coordinated omission).
- **Percentiles, never means.** p50 / p90 / p99 / p99.9 / max, into HDR histograms recorded in pre-allocated storage.
- `rdtscp` with the timer's own overhead measured and subtracted; `constant_tsc` and `nonstop_tsc` verified.
- Threads pinned, turbo and frequency scaling disabled, warmup discarded.
- Run-to-run variance reported across repeated runs. A result that cannot be reproduced is not a result.
- `perf stat` counters captured alongside each optimization to confirm the mechanism matches the hypothesis.

`BENCHMARKS.md` records every change as a commit, a one-line description, before/after percentiles, and the mechanism. Entries where the number got worse and the change was reverted are kept.

---

## Market Design Laboratory

The primary interface is not a trading screen — it is an experiment designer. You choose a baseline market configuration, pick parameters to sweep, run replications, and compare outcomes.

**Rules you can change:** tick size, maker/taker fees and rebates, lot size, price-time vs pro-rata allocation, self-trade prevention, market order protection bands, post-only availability.

**Population you can change:** counts and parameters of each agent type, latency distributions per type, uniform vs stratified latency.

**Environment you can change:** fundamental volatility and jump behaviour, Poisson vs Hawkes arrival clustering.

**Outcomes measured on every run:**

- *Market quality* — time-weighted spread, depth at touch and at N ticks, effective and realized spread, price efficiency against `V`, volatility, fill ratios, time-to-fill.
- *Welfare split* — market maker P&L, informed trader P&L, noise trader costs, fees collected. Most rule changes move value rather than destroying it; showing where is the point.
- *Fragility* — recovery time after a liquidity shock, worst gap, depth resilience.

### Experimental Discipline

- **Common random numbers** across compared configurations, so differences are attributable to the rule change rather than to luck.
- **Replications with confidence intervals.** No single-run results, no bar charts without error bars.
- **Burn-in** discarded before measurement, with the length stated.
- **Baseline validation before any experiment.** The baseline must reproduce known stylized facts — fat-tailed returns, volatility clustering, square-root impact, imbalance predicting the next move — before comparative results from it mean anything.

### Preset Experiments

- Tick size sweep: does a smaller tick narrow spreads, or fragment depth and erode queue priority?
- Maker rebate sweep: how much of a rebate is passed through to the quoted spread?
- Latency stratification: a market with a fast minority versus one with uniform latency at the same mean.
- Price-time versus pro-rata allocation.
- Informed trader density: spread should widen endogenously.

---

## API

Five endpoints. All JSON, all stateless HTTP.

| # | Trigger | Method | Path | Frontend sends | Backend returns |
|---|---|---|---|---|---|
| 1 | App loads | `GET` | `/api/schema` | nothing | parameter metadata |
| 2 | User hits Run | `POST` | `/api/simulations` | full config | run\_id |
| 3 | Polling loop | `GET` | `/api/simulations/{id}` | nothing | status + progress |
| 4 | During/after run | `GET` | `/api/simulations/{id}/result` | nothing | candles + series + metrics |
| 5 | User hits Cancel | `DELETE` | `/api/simulations/{id}` | nothing | confirmation |

### 1. `GET /api/schema` — parameter metadata

Returns the definition of every configurable parameter: type, min, max, default, unit, allowed values. The frontend builds its config form from this rather than hardcoding fields, so adding a parameter later requires no frontend change.

Covers: instrument settings, fundamental parameters, market rules, per-population-type strategy parameters, latency distribution options, and simulation settings (horizon, base interval, threading config).

### 2. `POST /api/simulations` — submit a run

Accepts the full simulation configuration. Validates every field against the schema. On success, returns `202` with a `run_id` and begins the simulation. On validation failure, returns `400` with a field-level error (`code`, `field`, `message`).

The backend does not block until the simulation finishes — it returns immediately and the frontend polls for progress.

#### Request body

```jsonc
{
  "seed": 42,
  "horizon_ns": 60000000000,          // 60 simulated seconds; min 1 min, max 24 hours
  "base_interval_ns": 100000000,       // 100ms — the smallest candle

  "instrument": {
    "tick_size": 1,                    // smallest price increment, in price units
    "initial_price": 10000,            // ticks
    "lot_size": 1,                     // minimum order size
    "price_band_ticks": 5000           // bounded tick range for the flat level array
  },

  "fundamental": {
    "volatility_per_sec": 0.0002,      // explicit time unit
    "jump_rate_per_sec": 0.0,
    "jump_size": 0.0
  },

  "rules": {
    "allocation": "price_time",        // "price_time" | "pro_rata"
    "maker_fee_bps": -0.2,             // negative = rebate
    "taker_fee_bps": 0.5,
    "post_only_enabled": true,
    "market_order_protection_ticks": 50,
    "self_trade_prevention": "cancel_oldest"  // "none" | "cancel_oldest" | "cancel_newest" | "cancel_both"
  },

  "populations": [
    {
      "type": "noise",
      "count": 200,
      "params": {
        "arrival_rate_per_sec": 5.0,
        "market_order_prob": 0.3,
        "size_dist":  { "kind": "lognormal", "mu": 4.0, "sigma": 1.0 },
        "depth_dist": { "kind": "geometric", "p": 0.4 }
      },
      "feed_latency":  { "kind": "lognormal", "median_ns": 500000, "sigma": 0.8 },
      "order_latency": { "kind": "lognormal", "median_ns": 300000, "sigma": 0.8 }
    },
    {
      "type": "market_maker",
      "count": 5,
      "params": {
        "half_spread_ticks": 2,
        "quote_size": 100,
        "refresh_ms": 50,
        "inventory_limit": 1000,
        "skew_factor": 0.002
      },
      "feed_latency":  { "kind": "lognormal", "median_ns": 20000, "sigma": 0.5 },
      "order_latency": { "kind": "lognormal", "median_ns": 15000, "sigma": 0.5 }
    },
    {
      "type": "informed",
      "count": 10,
      "params": {
        "signal_noise": 0.3,
        "signal_delay_ms": 100,
        "threshold_ticks": 3,
        "aggression": 0.5
      },
      "feed_latency":  { "kind": "lognormal", "median_ns": 50000, "sigma": 0.6 },
      "order_latency": { "kind": "lognormal", "median_ns": 30000, "sigma": 0.6 }
    },
    {
      "type": "momentum",
      "count": 15,
      "params": {
        "lookback_ms": 500,
        "aggression": 0.3,
        "size_dist": { "kind": "lognormal", "mu": 3.0, "sigma": 0.8 }
      },
      "feed_latency":  { "kind": "lognormal", "median_ns": 200000, "sigma": 0.7 },
      "order_latency": { "kind": "lognormal", "median_ns": 150000, "sigma": 0.7 }
    }
  ],

  "engine": { "threading": "A" }
}
```

Distributions are tagged unions: `{ "kind": "<name>", ...params }`. Supported kinds: `lognormal`, `uniform`, `constant`. Adding a distribution later does not break the schema.

Each population has per-type strategy parameters under `params`, plus `feed_latency` and `order_latency` controlling how stale the agent's view is and how long its orders take to arrive at the engine.

### 3. `GET /api/simulations/{id}` — poll status

Lightweight. Returns the current state of a run.

```jsonc
// queued
{ "run_id": "r_8f3a1b", "status": "queued" }

// running — progress is simulated_time_elapsed / horizon
{ "run_id": "r_8f3a1b", "status": "running", "progress": 0.42 }

// done
{ "run_id": "r_8f3a1b", "status": "completed" }

// failed — field-level error when possible
{ "run_id": "r_8f3a1b", "status": "failed",
  "error": { "code": "degenerate_market",
             "message": "book empty >90% of simulated time; add market makers" } }
```

Frontend polls every 500ms. Once `status` is `"running"`, it also begins fetching results for progressive rendering.

### 4. `GET /api/simulations/{id}/result` — fetch data

The main payload. While the simulation is running, returns whatever has been computed so far. Arrays grow as the simulation advances; summary metrics are `null` until `complete` is `true`.

#### Response structure

**Top level:**

| Field | Type | Description |
|---|---|---|
| `run_id` | string | Server-assigned identifier |
| `seed` | int64 | Echoed from request |
| `config_hash` | string | SHA-256 of canonicalized config; same hash + seed = identical result |
| `complete` | boolean | `false` while computing, `true` when final |

**`meta` — simulation parameters echoed back:**

| Field | Type | Unit | Description |
|---|---|---|---|
| `horizon_ns` | int64 | ns | Total simulated time requested |
| `base_interval_ns` | int64 | ns | Candle width (100,000,000 = 100ms) |
| `tick_size` | int | price units | Smallest price increment |
| `price_scale` | int | | ticks / price\_scale = display price |
| `burn_in_ns` | int64 | ns | Discarded warm-up time before measurement |
| `sim_wall_ms` | int64 | ms | Wall-clock time for the simulation; `null` while incomplete |

**`candles` — columnar, base resolution (100ms), trade-price based:**

| Field | Type | Description |
|---|---|---|
| `t` | int64[] | Bucket start time, ns since sim start (after burn-in) |
| `o` | int64[] | Open price in ticks |
| `h` | int64[] | High price in ticks |
| `l` | int64[] | Low price in ticks |
| `c` | int64[] | Close price in ticks |
| `v` | int64[] | Total volume traded |
| `n` | int32[] | Number of trades |

All arrays are the same length. Index `i` describes the same time window across all of them. Empty buckets (no trades): `n = 0`, `v = 0`, `o = h = l = c` carried from previous close. Candles aggregate upward losslessly: the client produces 1s, 5s, or any multiple of 100ms candles purely locally — no re-request needed.

**`series` — same time grid as candles, sampled at each candle boundary:**

| Field | Type | Description |
|---|---|---|
| `mid` | int64[] | Mid price in ticks |
| `fundamental` | int64[] | V(t) in ticks — the hidden true value |
| `spread_ticks` | int32[] | Bid-ask spread in ticks |
| `depth_bid` | int64[] | Total resting quantity on bid side, top 5 levels |
| `depth_ask` | int64[] | Total resting quantity on ask side, top 5 levels |
| `imbalance` | float[] | (depth\_bid - depth\_ask) / (depth\_bid + depth\_ask), range -1.0 to 1.0 |

V(t) is the only data in the response that wouldn't exist in a real market. Overlaying it on the mid price chart shows the market discovering value — the unique advantage of a simulation. The frontend provides a toggle to show/hide it.

**`market_quality` — summary statistics over the full run; `null` while incomplete:**

| Field | Type | Description |
|---|---|---|
| `time_weighted_spread_ticks` | float | Spread averaged over time, not over trades |
| `effective_spread_bps` | float | What traders actually paid: `2 * |trade_price - mid| / mid` |
| `realized_spread_bps` | float | What makers earned after adverse selection: uses mid 1s after trade |
| `price_efficiency_rmse` | float | RMSE of |mid - V| in ticks |
| `realized_volatility` | float | Std dev of returns at sampling interval |
| `fill_ratio` | float | Fraction of submitted limit orders that filled |
| `median_time_to_fill_ns` | int64 | Median time from submission to fill for limit orders |

**`agents[]` — per-population results; `null` while incomplete:**

| Field | Type | Description |
|---|---|---|
| `type` | string | `"noise"` \| `"market_maker"` \| `"informed"` \| `"momentum"` |
| `count` | int | Number of agents in this population |
| `pnl_total` | float | Sum P&L across all agents of this type |
| `pnl_mean` | float | Per-agent mean |
| `pnl_std` | float | Per-agent standard deviation |
| `pnl_p5` | float | 5th percentile |
| `pnl_p95` | float | 95th percentile |
| `volume` | int64 | Total quantity traded |
| `fill_ratio` | float | For types that submit limit orders |
| `fees_paid` | float | Positive = paid; negative = rebate received |
| `markout_1s_ticks` | float | Avg mid displacement 1 second after their fills |

Markout is the key signal: negative for market makers means they were adversely selected (sold to informed flow that pushed the price against them). The gap between effective spread and realized spread *is* adverse selection, quantified.

**`engine` — performance report; latency stats are cumulative and update during progressive rendering, throughput is `null` until complete:**

| Field | Type | Description |
|---|---|---|
| `total_commands` | int64 | orders + cancels + modifies |
| `orders` | int64 | |
| `cancels` | int64 | |
| `modifies` | int64 | |
| `trades` | int64 | Fills generated |
| `sim_wall_ms` | int64 | Wall-clock time; `null` while incomplete |
| `throughput_ops_sec` | int64 | total\_commands / sim\_wall\_seconds; `null` while incomplete |
| `threading` | string | `"A"` \| `"B"` \| `"C"` \| `"D"` |
| `latency_ns` | object | Per-command-type histograms (see below) |
| `note` | string | Always: `"engine-internal command processing only; excludes agent logic and I/O"` |

Each entry in `latency_ns` (`overall`, `limit_resting`, `limit_crossing`, `cancel`, `modify`):

| Field | Type | Description |
|---|---|---|
| `p50` | int64 | 50th percentile, nanoseconds |
| `p90` | int64 | 90th percentile |
| `p99` | int64 | 99th percentile |
| `p999` | int64 | 99.9th percentile |
| `max` | int64 | Maximum observed |
| `bucket_width_ns` | int64 | Histogram bucket width |
| `buckets` | int64[] | Counts per bucket, for rendering a histogram chart |

**`warnings[]` — non-fatal issues detected during the run:**

| Field | Type | Description |
|---|---|---|
| `code` | string | Machine-readable: `"thin_book"`, `"price_dislocation"`, etc. |
| `message` | string | Human-readable explanation |

#### Progressive rendering

While `complete` is `false`, the frontend polls the result endpoint every 1-2 seconds. Candle and series arrays grow — the backend appends but never revises earlier entries. The chart extends to the right. Engine stats update cumulatively. `market_quality` and `agents` remain `null` until the run finishes.

The backend writes candles in strict time order. A candle at time `t` is finalized before the simulation advances past `t + base_interval_ns`. No global post-processing is applied to the candle array — everything is computable incrementally.

### 5. `DELETE /api/simulations/{id}` — cancel

Signals the simulation to stop, discards partial results.

```json
{ "run_id": "r_8f3a1b", "status": "cancelled" }
```

---

## Setup and Development

### Prerequisites

- **C++20 compiler**: GCC 12+ or Clang 15+
- **CMake** 3.20+
- **Python** 3.8+ (for pre-commit hooks)
- **GitHub CLI** (`gh`): install with `winget install --id GitHub.cli` (Windows) or your package manager, then `gh auth login`
- **LLVM/Clang tools**: install with `winget install LLVM.LLVM` (Windows) or your package manager — provides `clang-format` and `clang-tidy`
- **pre-commit**: `pip install pre-commit`

### Clone and Build

```bash
git clone https://github.com/tudor-stack/Market-simulator.git
cd Market-simulator
cmake -B build
cmake --build build
```

Running `cmake -B build` automatically installs the pre-commit hooks if `pre-commit` is on your PATH. If not, install them manually:

```bash
pre-commit install
pre-commit install --hook-type commit-msg
pre-commit install --hook-type pre-push
```

### Pre-commit Hooks

The following hooks run automatically on every commit:

| Hook | What it does | When |
|---|---|---|
| `trailing-whitespace` | Removes trailing whitespace | pre-commit |
| `end-of-file-fixer` | Ensures files end with a newline | pre-commit |
| `check-yaml` | Validates YAML syntax | pre-commit |
| `check-json` | Validates JSON syntax | pre-commit |
| `clang-format` | Formats C++ code to project style | pre-commit |
| `commit-msg-format` | Enforces commit message format | commit-msg |
| `branch-name-check` | Enforces branch naming convention | pre-push |

Configuration lives in `.pre-commit-config.yaml`. C++ style is defined in `.clang-format`. Static analysis checks are defined in `.clang-tidy` (used in CI, not as a local hook).

### Workflow: Issues, Branches, and PRs

All work goes through tickets. No branch exists without an issue.

**1. Create an issue**

Go to Issues → New issue → pick one of the five forms:

| Form | Label | Branch prefix |
|---|---|---|
| Feature | `type:feature` | `feature/` |
| Bug | `type:bug` | `bugfix/` |
| Performance | `type:perf` | `perf/` |
| Experiment | `type:experiment` | `experiment/` |
| Chore | `type:chore` | `chore/` |

Keep the title short — it becomes part of the branch name.

**2. Branch is created automatically**

When you submit the issue, a GitHub Action reads the type label and title, and creates a branch:

```
<type>/<issue-number>_<title_lowercase_underscored>
```

For example, issue #42 "Cancel order by ID" with label `type:feature` becomes `feature/42_cancel_order_by_id`.

The branch is linked to the issue in the Development sidebar. The title is truncated to 50 characters and stripped of punctuation.

**3. Check out and work**

```bash
git fetch
git checkout <branch-name>
```

Commit messages must follow this format:

```
<branch-name>: <description>
```

For example:

```
feature/42_cancel_order_by_id: implement cancel by order ID
```

The commit-msg hook rejects messages that don't match this format.

**4. Open a PR**

```bash
git push origin <branch-name>
gh pr create --title "<branch-name>: <description>" --body "Closes #<issue-number>"
```

The `Closes #N` in the PR body links the PR to the issue and auto-closes it on merge.

**5. Merge**

Squash merge on GitHub. On merge:
- The issue closes (from `Closes #N`)
- The branch is deleted automatically
- The Project board card moves to Done

### Commit Message Format

Every commit message must match:

```
<type>/<number>_<name>: <message>
```

Examples:

```
feature/42_cancel_order_by_id: implement cancel logic
bugfix/15_segfault_on_empty_book: add null check before dequeue
chore/3_project_scaffold: add CMakeLists and stub main
```

The pre-commit hook enforces this. To bypass for infrastructure commits on `main` (rare): `git commit --no-verify`.

### Branch Naming Convention

```
<type>/<issue-number>_<short_title>
```

- `type` is one of: `feature`, `bugfix`, `perf`, `experiment`, `chore`
- `issue-number` is the GitHub issue number
- `short_title` is lowercase, underscores instead of spaces, no punctuation

A repository ruleset blocks creating branches that don't start with one of the five prefixes. Direct pushes to `main` are blocked — all changes go through PRs.

### What Happens Automatically

| Event | What happens |
|---|---|
| Issue created | Branch is auto-created and linked to the issue |
| Issue added to repo | Appears on the Project board (Backlog) |
| PR merged with `Closes #N` | Issue closes, branch deletes, board card moves to Done |
| Issue closed manually | Linked branch is auto-deleted |

---

## Layout

```
engine/       matching core — no I/O, no threads, no dependencies
feed/         binary market data encoding, sequencing, snapshots
sim/          virtual clock, event queue, latency models, agents
concurrency/  SPSC ring, cache-line utilities, thread pinning
analytics/    microstructure metrics over recorded feeds
experiments/  sweep runner, replication, common random numbers, statistics
api/          HTTP server, JSON serialization, job registry
gateway/      simulation driver: wires engine, agents, and analytics
bench/        open-loop benchmark harness and histograms
tools/        flowgen, replay, reconstruct, sweep CLIs
tests/        unit, reference implementation, differential fuzz, determinism
web/          browser client
configs/      baseline, scenarios, experiment definitions
docs/         design notes and experiment results
scripts/      hook scripts and development utilities
```

---

## Scope and Honesty

**In scope:** matching engine, full order type set, binary feed, agent-based flow, threading comparison, benchmark harness, microstructure measurement, experiment runner, web interface for market design experiments.

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

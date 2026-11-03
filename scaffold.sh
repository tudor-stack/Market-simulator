#!/usr/bin/env bash
# Creates the SI project directory structure. Safe to re-run: never overwrites.
set -euo pipefail

dirs=(
  cmake

  engine/include/si/engine
  engine/src

  feed/include/si/feed
  feed/src

  sim/include/si/sim
  sim/include/si/sim/agents
  sim/src
  sim/src/agents

  concurrency/include/si/concurrency
  concurrency/src

  analytics/include/si/analytics
  analytics/src

  experiments/include/si/experiments
  experiments/src

  gateway/include/si/gateway
  gateway/src

  bench

  tools/flowgen
  tools/replay
  tools/reconstruct
  tools/sweep

  tests/unit
  tests/reference
  tests/fuzz
  tests/determinism

  configs/scenarios
  configs/experiments

  web/src/components
  web/src/views
  web/src/feed
  web/public

  docs/results
  docs/design

  third_party
)

for d in "${dirs[@]}"; do
  mkdir -p "$d"
  [ -z "$(ls -A "$d")" ] && touch "$d/.gitkeep"
done

echo "structure created"

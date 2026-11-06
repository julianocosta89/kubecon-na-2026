#!/usr/bin/env bash
# The dry-run protocol from the demo doc, unattended:
#   for each scenario: apply it, run WARMUP_MIN + MEASURE_MIN under fixed load,
#   then switch the payment failure on for FLAG_MINUTES and count what's kept.
#   In 02 and 04 also surge the load (load generator 1 → 3 pods) for 5 min: fixed 10% vs. a budget.
#   At the end: the scorecard.
# Run it twice. If the two scorecards differ by more than ~10%, find out why.
# On a Mac, keep the laptop awake:  caffeinate -i bash scripts/dry-run.sh
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_context

per_stage=$((WARMUP_MIN + MEASURE_MIN + FLAG_MINUTES + 2))
info "Dry run: scenarios 00 → 04, about $((per_stage * 5 + 12)) min. Started $(date '+%H:%M')."
bash "$ROOT/scripts/port-forward.sh" start >/dev/null

for stage in 00 01 02 03 04; do
  bash "$ROOT/scripts/run.sh" "$stage" --no-notes > "$RUN_DIR/dry-run-stage-$stage.log" 2>&1
  grep -m1 'live in' "$RUN_DIR/dry-run-stage-$stage.log" || true
  info "Scenario $stage: measuring for $((WARMUP_MIN + MEASURE_MIN)) min (first $WARMUP_MIN are warm-up)"
  sleep $(((WARMUP_MIN + MEASURE_MIN) * 60))
  python3 "$ROOT/scripts/demo.py" errors-kept --stage "$stage"
  if [[ $stage == 02 || $stage == 04 ]]; then
    sleep 60   # let the failure run drain before the surge
    python3 "$ROOT/scripts/demo.py" surge --stage "$stage"
  fi
done

python3 "$ROOT/scripts/demo.py" scorecard
info "Back to the start state for the talk: make run 00"

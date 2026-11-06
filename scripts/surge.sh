#!/usr/bin/env bash
# make surge [on|off]: triple the shop's traffic, or go back to normal.
#   on   load generator 1 → SURGE_REPLICAS pods (10 users each)
#   off  back to 1 pod, and cancel a surge `make run 04` scheduled
#        (every `make run` does both too)
#   on --auto   what `make run 04` runs after SURGE_DELAY seconds: no notes
# More pods rather than more users per pod: each pod runs the same 10 users,
# browser user included, so the traffic mix stays the same. One pod with 30
# users runs out of CPU and its browser traffic drops.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
need kubectl
require_context

mode=${1:-on}
auto=false; [[ ${2:-} == --auto ]] && auto=true
if $auto; then
  rm -f "$SURGE_PID"          # this is the scheduled run; nothing left to cancel
else
  cancel_auto_surge           # by hand: now (on) or not at all (off)
fi
case $mode in
  on)  pods=$SURGE_REPLICAS ;;
  off) pods=1 ;;
  *)   die "usage: make surge        (on: $SURGE_REPLICAS load generator pods)
       make surge off    (back to 1)" ;;
esac

before=$(k get deploy/load-generator -o jsonpath='{.spec.replicas}')
stage=$(current_stage)

if [[ $before == "$pods" ]]; then
  ok "Load generator already at $pods pod(s): nothing to change"
  exit 0
fi

k scale deploy/load-generator --replicas="$pods" >/dev/null
echo "$(date +%s) load $pods" >> "$RUN_DIR/events.log"   # the scorecard cuts its windows here
info "Load generator: $before → $pods pods ($((before * 10)) → $((pods * 10)) users)"
k rollout status deploy/load-generator --timeout=3m >/dev/null || warn "load generator pods not ready yet"
ok "Done. $((pods * 10)) users shopping"
$auto && exit 0
echo

hr
if [[ $mode == on ]]; then
  cat <<EOF
${B}SURGE ON${N}: three times the shoppers, three times the traces, of the same kinds.
The new pods need ~30 s to start shopping, the charts ~1 min to catch up.

${B}WHERE TO LOOK${N}  $PERSES_URL
  Row 1  "received" triples.
EOF
  if [[ $stage == 04 ]]; then
    cat <<EOF
  Row 5  dashed "a fixed 10% would send" triples with the traffic;
         solid "kept by the gateway" stays near the dotted budget.
         Traces dropped by the budget rule triple, kept ones don't,
         and "1 in N" climbs: the sampler adapting.

${B}NEXT${N}  make surge off
EOF
  else
    case $stage in
      02|03) what="keeps a fixed share (10%)" ;;
      *)     what="keeps everything" ;;
    esac
    cat <<EOF
  Scenario $stage $what, so "sent to Jaeger" triples too.
  That's the problem scenario 04 solves.

${B}NEXT${N}  make surge off
EOF
  fi
else
  cat <<EOF
${B}SURGE OFF${N}: back to the normal load (1 pod, 10 users).
  Within a minute "received" drops back. In scenario 04 the budget's "1 in N"
  relaxes again over the next few 15 s adjustments.
EOF
fi
hr

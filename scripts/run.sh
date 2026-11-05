#!/usr/bin/env bash
# Switch the demo to one scenario with a single `helm upgrade`, wait for it to
# roll, then print why the scenario exists, what changed in the cluster (a real
# before/after diff, read back from Kubernetes), and where to look.
#
#   scripts/run.sh 00|01|02|03|04 [--no-notes]
#   (make run 01 calls this; make start calls it with 00 --no-notes)
set -euo pipefail
source "$(dirname "$0")/lib.sh"
need helm kubectl
require_context

SCENARIO="${1:-}"
NOTES=true
[[ ${2:-} == --no-notes ]] && NOTES=false

case "$SCENARIO" in
  00) layers="common 00-baseline" ;;
  01) layers="common 00-baseline 01-instrumentation-off" ;;
  02) layers="common 00-baseline 01-instrumentation-off 02-filter-probabilistic" ;;
  03) layers="common 00-baseline 01-instrumentation-off 03-tail-sampling"; gateway_mode="tail" ;;
  # 04: the agents are set up exactly as in 03; only the gateway changes.
  04) layers="common 00-baseline 01-instrumentation-off 03-tail-sampling"; gateway_mode="adaptive" ;;
  *)  die "usage: make run 01|02|03|04   (make run 00 goes back to the baseline)" ;;
esac
args=()
for layer in $layers; do args+=(-f "$ROOT/values/$layer.yaml"); done

# ── Snapshots for the "what changed" diff ─────────────────────────────────────
# 1. the Collector config as Kubernetes holds it (rendered ConfigMap)
# 2. every environment variable of every demo service, one "service: NAME=value" per line
# 3. the gateway's Collector config
snapshot() {  # $1 = file prefix
  k get configmap otel-collector-agent -o jsonpath='{.data.relay}' > "$1.collector" 2>/dev/null || : > "$1.collector"
  k get configmap "$GATEWAY_RELEASE" -o jsonpath='{.data.relay}' > "$1.gateway" 2>/dev/null || : > "$1.gateway"
  # shellcheck disable=SC2016  # $d belongs to kubectl's Go template, not to bash
  k get deploy -o go-template='{{range .items}}{{$d := .metadata.name}}{{range .spec.template.spec.containers}}{{range .env}}{{$d}}: {{.name}}={{if .value}}{{.value}}{{end}}{{"\n"}}{{end}}{{end}}{{end}}' \
    2>/dev/null | sort > "$1.env" || : > "$1.env"
}

first_install=false
helm status "$RELEASE" -n "$NAMESPACE" >/dev/null 2>&1 || first_install=true
prev="$(current_stage)"
before="$RUN_DIR/before"; after="$RUN_DIR/after"
$first_install || snapshot "$before"

# Scenarios 03 and 04 send every trace to the gateway: put it in the right mode
# before the agents start routing to it.
if [[ -n ${gateway_mode:-} ]]; then
  bash "$ROOT/scripts/gateway.sh" up "$gateway_mode"
fi

wait_flag=()
if $first_install; then
  info "Installing the OTel Demo (chart $DEMO_CHART_VERSION). Pulling images takes several minutes the first time."
  wait_flag=(--wait --timeout 20m)
else
  info "Switching to scenario $SCENARIO (from ${prev})"
fi
t0=$(date +%s)
helm upgrade --install "$RELEASE" open-telemetry/opentelemetry-demo \
  --version "$DEMO_CHART_VERSION" -n "$NAMESPACE" --create-namespace \
  "${args[@]}" ${wait_flag[@]+"${wait_flag[@]}"} >/dev/null
info "Waiting for the Collector and the services to finish restarting"
wait_rollouts
t1=$(date +%s)
echo "$t1 $SCENARIO" >> "$STAGES_LOG"
ok "Scenario $SCENARIO live in $((t1 - t0))s"

$NOTES || exit 0

# Port-forwards survive pod restarts, but start them if nobody did.
if ! port_open "$PORT_PERSES" || ! port_open "$PORT_SHOP"; then
  bash "$ROOT/scripts/port-forward.sh" start >/dev/null 2>&1
fi

# ── Part 1: why this scenario ─────────────────────────────────────────────────
echo
hr
print_notes "$SCENARIO" 1

# ── What changed, read back from the cluster ──────────────────────────────────
if ! $first_install; then
  snapshot "$after"
  echo
  echo "${B}WHAT CHANGED IN THE CLUSTER${N}  ${DIM}(read back from Kubernetes: before → after)${N}"
  changed=false

  show_diff() {  # $1 = before file, $2 = after file
    # diff exits 1 when the files differ, which is the case we're in.
    { diff -U2 "$1" "$2" || true; } | tail -n +3 | while IFS= read -r line; do
      case "$line" in
        +*) printf '    %s%s%s\n' "$G" "$line" "$N" ;;
        -*) printf '    %s%s%s\n' "$R" "$line" "$N" ;;
        @@*) printf '    %s···%s\n' "$DIM" "$N" ;;
        *) printf '    %s%s%s\n' "$DIM" "$line" "$N" ;;
      esac
    done
  }

  echo
  echo "  Agent Collector config  ${DIM}(ConfigMap otel-collector-agent)${N}"
  if cmp -s "$before.collector" "$after.collector"; then
    echo "    no change"
  else
    changed=true
    agents=$(k get ds otel-collector-agent -o jsonpath='{.status.numberReady}' 2>/dev/null || true)
    echo "    ${DIM}→ ${agents:-all} agent pods restarted to load it${N}"
    show_diff "$before.collector" "$after.collector"
  fi

  echo
  echo "  Gateway Collector config  ${DIM}(ConfigMap $GATEWAY_RELEASE)${N}"
  gateway_changed=false
  if cmp -s "$before.gateway" "$after.gateway"; then
    echo "    no change"
  else
    changed=true; gateway_changed=true
    echo "    ${DIM}→ the 2 gateway pods restarted to load it${N}"
    show_diff "$before.gateway" "$after.gateway"
  fi

  echo
  echo "  Service environment variables  ${DIM}(a changed service restarts with them)${N}"
  added=$(comm -13 "$before.env" "$after.env")
  removed=$(comm -23 "$before.env" "$after.env")
  if [[ -z $added && -z $removed ]]; then
    echo "    no change"
  else
    changed=true
    [[ -n $removed ]] && echo "$removed" | while IFS= read -r l; do printf '    %s- %s%s\n' "$R" "$l" "$N"; done
    [[ -n $added ]] && echo "$added" | while IFS= read -r l; do printf '    %s+ %s%s\n' "$G" "$l" "$N"; done
  fi

  if [[ -n ${gateway_mode:-} ]]; then
    proc=tail_sampling; [[ $gateway_mode == adaptive ]] && proc=adaptive_tail_sampling
    echo
    echo "  Gateway tier, now receiving every trace"
    k get pods -l "app.kubernetes.io/instance=$GATEWAY_RELEASE" --no-headers 2>/dev/null \
      | awk '{printf "    %-45s %s\n", $1, $3}'
    # The diff above already shows it when the gateway config just changed.
    if ! $gateway_changed; then
      echo "    ${DIM}the $proc processor, as the gateway runs it:${N}"
      k get configmap "$GATEWAY_RELEASE" -o jsonpath='{.data.relay}' 2>/dev/null \
        | awk -v p="  $proc:" '$0==p{f=1;next} f&&/^  [^ ]/{exit} f' | sed 's/^/    /'
    fi
  fi

  $changed || { echo; echo "  ${DIM}Already in scenario $SCENARIO: nothing to change.${N}"; }
  echo
fi

# ── Part 2: where to look, what to say, what's next ───────────────────────────
print_notes "$SCENARIO" 2
hr

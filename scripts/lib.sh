# Shared helpers. Sourced by every script; not meant to run on its own.
# shellcheck shell=bash

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_DIR="$ROOT/.run"
RESULTS_DIR="$ROOT/results"
mkdir -p "$RUN_DIR" "$RESULTS_DIR"

# settings.env provides defaults; values already in the environment win
# (the Makefile exports command-line overrides).
while IFS='=' read -r key value; do
  [[ $key =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
  [[ -n "${!key:-}" ]] || export "$key=$value"
done < "$ROOT/settings.env"

# shellcheck disable=SC2034  # colors are used by the scripts that source this file
if [[ -t 1 ]]; then
  B=$'\e[1m'; DIM=$'\e[2m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; C=$'\e[36m'; N=$'\e[0m'
else
  B=""; DIM=""; G=""; Y=""; R=""; C=""; N=""
fi

info() { printf '%s==>%s %s\n' "$C" "$N" "$*"; }
ok()   { printf '%s ✓%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%s !%s %s\n' "$Y" "$N" "$*" >&2; }
die()  { printf '%s ✗%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

need() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' is not installed or not on PATH"
  done
}

k() { kubectl -n "$NAMESPACE" "$@"; }

# Every script that changes the cluster calls this first, so a demo command
# never lands on whatever cluster kubectl happened to point at.
# Set KUBE_CONTEXT= (empty) in settings.env to use any cluster.
require_context() {
  [[ -z ${KUBE_CONTEXT:-} ]] && return 0
  local current
  current=$(kubectl config current-context 2>/dev/null || echo "none")
  [[ $current == "$KUBE_CONTEXT" ]] || die "kubectl points at '$current', expected '$KUBE_CONTEXT'.
   Run 'make start' (creates it if needed and switches to it), or: kubectl config use-context $KUBE_CONTEXT"
}

# Stage log: one line per applied stage, "<epoch> <stage>".
STAGES_LOG="$RUN_DIR/stages.log"
current_stage() { [[ -s $STAGES_LOG ]] && tail -n1 "$STAGES_LOG" | awk '{print $2}' || echo "none"; }

# Wait until the Collector DaemonSet and every Deployment have finished rolling.
wait_rollouts() {
  k rollout status ds/otel-collector-agent --timeout=5m >/dev/null
  local d
  for d in $(k get deploy -o name); do
    k rollout status "$d" --timeout=5m >/dev/null || warn "$d did not finish rolling out"
  done
}

port_open() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

hr() { printf '%s%s%s\n' "$DIM" "────────────────────────────────────────────────────────────────────────" "$N"; }

# A surge scheduled by `make run 04` (scripts/surge.sh on --auto, in the background).
SURGE_PID="$RUN_DIR/surge.pid"
cancel_auto_surge() {
  [[ -f $SURGE_PID ]] || return 0
  kill "$(cat "$SURGE_PID")" 2>/dev/null || true
  rm -f "$SURGE_PID"
}

PERSES_URL="http://localhost:$PORT_PERSES/projects/opentelemetry-demo/dashboards/sampling-demo"

# Print one part of stages/NN.txt with the URLs filled in.
# The file has two parts split by a line "@@CHANGES@@": part 1 comes before the
# list of cluster changes, part 2 after it.
print_notes() {  # $1 = scenario, $2 = 1|2
  awk -v want="$2" '/^@@CHANGES@@$/{part++; next} (part+1)==want' "$ROOT/stages/$1.txt" \
    | sed -e "s#{{SHOP}}#http://localhost:$PORT_SHOP#g" \
          -e "s#{{PERSES}}#$PERSES_URL#g" \
          -e "s#{{GW}}#$GATEWAY_RELEASE#g" \
          -e "s#{{SURGE_DELAY}}#${SURGE_DELAY:-0}#g" \
          -e "s#^\([A-Z][A-Z0-9 ,'():+-]*\)\$#$B\1$N#"
}

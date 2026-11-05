#!/usr/bin/env bash
# make start: everything from nothing to the baseline (scenario 00).
#   1. kind cluster (1 control plane + 3 workers)
#   2. Helm repository
#   3. Perses (the live dashboard)
#   4. OTel Demo at the baseline
#   5. Tail-sampling gateway (idle until scenario 03)
#   6. Port-forwards
# Safe to run again: every step skips what already exists.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
need kind docker kubectl helm python3

step() { printf '\n%s[%s/6] %s%s\n' "$B" "$1" "$2" "$N"; }

step 1 "kind cluster '$KIND_CLUSTER'"
bash "$ROOT/scripts/cluster.sh" up
require_context

step 2 "Helm repository"
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null 2>&1 || true
helm repo update open-telemetry >/dev/null
ok "open-telemetry charts up to date"

step 3 "Perses"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
k create configmap perses-files \
  --from-file="$ROOT/perses/config.yaml" --from-file="$ROOT/perses/provisioning/" \
  --dry-run=client -o yaml | k apply -f - >/dev/null
sed "s|__PERSES_IMAGE__|$PERSES_IMAGE|" "$ROOT/k8s/perses.yaml" | k apply -f - >/dev/null
# Restart so edits in perses/ are picked up (each file is a subPath mount).
k rollout restart deploy/perses >/dev/null
k rollout status deploy/perses --timeout=5m >/dev/null
ok "Perses ready ($PERSES_IMAGE)"

step 4 "OpenTelemetry Demo at the baseline (scenario 00)"
bash "$ROOT/scripts/run.sh" 00 --no-notes

step 5 "Tail-sampling gateway"
bash "$ROOT/scripts/gateway.sh" up

step 6 "Port-forwards"
bash "$ROOT/scripts/port-forward.sh" start

echo
hr
print_notes 00 1
echo
print_notes 00 2
hr

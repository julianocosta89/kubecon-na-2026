#!/usr/bin/env bash
# make stop: stop the port-forwards and delete the kind cluster with everything
# in it. Only the cluster named KIND_CLUSTER is touched. results/ is kept.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
need kind

info "Stopping port-forwards"
bash "$ROOT/scripts/port-forward.sh" stop >/dev/null 2>&1 || true

if kind get clusters 2>/dev/null | grep -qx "$KIND_CLUSTER"; then
  info "Deleting kind cluster '$KIND_CLUSTER' (the demo, Perses, the gateway and their data go with it)"
  kind delete cluster --name "$KIND_CLUSTER"
else
  info "kind cluster '$KIND_CLUSTER' doesn't exist; nothing to delete"
fi

rm -f "$STAGES_LOG" "$RUN_DIR"/before.* "$RUN_DIR"/after.* "$RUN_DIR/gateway-mode"
ok "Clean. Measurements in results/ are kept. Start again with: make start"

#!/usr/bin/env bash
# The gateway tier (a second Collector release) that scenarios 03 and 04 send
# every trace to. `make start` installs it idle, so a scenario switch is only a
# config flip.
#
#   scripts/gateway.sh up [tail|adaptive]   tail = scenario 03 (default), adaptive = scenario 04
#   scripts/gateway.sh down
set -euo pipefail
source "$(dirname "$0")/lib.sh"
need helm kubectl
require_context

case "${1:-up}" in
  up)
    mode="${2:-tail}"
    files=(-f "$ROOT/values/gateway.yaml")
    case "$mode" in
      tail)     label="tail_sampling: keep errors, keep slow, 10% of the rest" ;;
      adaptive) label="adaptive_tail_sampling: keep errors, a spans/s budget for the rest"
                files+=(-f "$ROOT/values/gateway-adaptive.yaml") ;;
      *) die "usage: $0 up [tail|adaptive]" ;;
    esac
    info "Gateway $GATEWAY_RELEASE → $label"
    helm upgrade --install "$GATEWAY_RELEASE" open-telemetry/opentelemetry-collector \
      --version "$GATEWAY_CHART_VERSION" -n "$NAMESPACE" --create-namespace \
      "${files[@]}" --wait --timeout 5m >/dev/null
    k rollout status "deploy/$GATEWAY_RELEASE" --timeout=5m >/dev/null
    echo "$mode" > "$RUN_DIR/gateway-mode"
    ok "$GATEWAY_RELEASE ready ($mode)"
    ;;
  down)
    case "$(current_stage)" in
      03|04) die "Scenario $(current_stage) is live and sends traces to the gateway. Run 'make run 02' first." ;;
    esac
    helm uninstall "$GATEWAY_RELEASE" -n "$NAMESPACE"
    rm -f "$RUN_DIR/gateway-mode"
    ;;
  *) die "usage: $0 up [tail|adaptive] | down" ;;
esac

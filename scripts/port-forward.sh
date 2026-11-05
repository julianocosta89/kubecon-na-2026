#!/usr/bin/env bash
# Background port-forwards that come back by themselves if a pod restarts.
#
#   scripts/port-forward.sh start|stop|status
set -euo pipefail
source "$(dirname "$0")/lib.sh"

# name  service           local:remote
FORWARDS="shop        frontend-proxy    $PORT_SHOP:8080
perses      perses            $PORT_PERSES:8080
jaeger      jaeger            $PORT_JAEGER:16686
prometheus  prometheus        $PORT_PROMETHEUS:9090"

start() {
  need kubectl
  require_context
  echo "$FORWARDS" | while read -r name svc ports; do
    pidfile="$RUN_DIR/pf-$name.pid"
    if [[ -f $pidfile ]] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
      continue
    fi
    nohup bash -c "while true; do kubectl -n '$NAMESPACE' port-forward 'svc/$svc' '$ports' >/dev/null 2>&1; sleep 1; done" \
      >/dev/null 2>&1 &
    echo $! > "$pidfile"
  done
  sleep 3
  status
}

stop() {
  local pidfile pid
  for pidfile in "$RUN_DIR"/pf-*.pid; do
    [[ -f $pidfile ]] || continue
    pid=$(cat "$pidfile")
    pkill -P "$pid" 2>/dev/null || true
    kill "$pid" 2>/dev/null || true
    rm -f "$pidfile"
  done
  ok "port-forwards stopped"
}

status() {
  local name svc ports lport
  echo "$FORWARDS" | while read -r name svc ports; do
    lport=${ports%%:*}
    if port_open "$lport"; then
      ok "$(printf '%-11s localhost:%-6s → svc/%s' "$name" "$lport" "$svc")"
    else
      warn "$(printf '%-11s localhost:%-6s → svc/%s  (not answering yet)' "$name" "$lport" "$svc")"
    fi
  done
}

case "${1:-status}" in
  start) start ;;
  stop) stop ;;
  status) status ;;
  *) die "usage: $0 start|stop|status" ;;
esac

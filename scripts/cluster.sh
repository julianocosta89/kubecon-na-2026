#!/usr/bin/env bash
# The local kind cluster (kind/cluster.yaml: 1 control plane + 3 workers).
#
#   scripts/cluster.sh up        create it if missing, switch kubectl to it
#   scripts/cluster.sh down      delete it
#   scripts/cluster.sh context   fail unless kubectl points at KUBE_CONTEXT
set -euo pipefail
source "$(dirname "$0")/lib.sh"

up() {
  need kind docker kubectl
  docker info >/dev/null 2>&1 || die "'docker info' fails. Start your container runtime first."
  if kind get clusters 2>/dev/null | grep -qx "$KIND_CLUSTER"; then
    ok "kind cluster '$KIND_CLUSTER' already exists"
  else
    info "Creating kind cluster '$KIND_CLUSTER': 1 control plane + 3 workers (about 1–2 min)"
    image_args=()
    [[ -n ${KIND_NODE_IMAGE:-} ]] && image_args=(--image "$KIND_NODE_IMAGE")
    kind create cluster --name "$KIND_CLUSTER" --config "$ROOT/kind/cluster.yaml" \
      ${image_args[@]+"${image_args[@]}"} --wait 180s
  fi
  kubectl config use-context "kind-$KIND_CLUSTER" >/dev/null
  ok "kubectl context: kind-$KIND_CLUSTER"
  kubectl get nodes --no-headers | awk '{printf "  %-40s %-8s %s\n", $1, $2, $5}'
}

down() {
  need kind
  bash "$ROOT/scripts/port-forward.sh" stop >/dev/null 2>&1 || true
  kind delete cluster --name "$KIND_CLUSTER"
  rm -f "$STAGES_LOG"
  ok "kind cluster '$KIND_CLUSTER' deleted (results/ kept)"
}

case "${1:-up}" in
  up) up ;;
  down) down ;;
  context) require_context ;;
  *) die "usage: $0 up|down|context" ;;
esac

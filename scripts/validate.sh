#!/usr/bin/env bash
# Pre-show check, no cluster changes:
#   1. `helm template` every scenario and both gateway modes (catches YAML and merge mistakes)
#   2. print each stage's rendered traces pipelines
#   3. if docker is available, run `otelcol-contrib validate` on every rendered
#      Collector config with the exact Collector version the charts pin.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
need helm

# Fully qualified, so a Podman-backed docker doesn't ask which registry "otel/..." means.
COLLECTOR_IMAGE=docker.io/otel/opentelemetry-collector-contrib:0.164.0
# Inside the project, not /tmp: a podman machine on macOS only shares /Users with its VM.
tmp=$(mktemp -d "$RUN_DIR/validate.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

render_agent() {  # $1 = stage, $2.. = layers
  local stage=$1; shift
  local args=() layer
  for layer in "$@"; do args+=(-f "$ROOT/values/$layer.yaml"); done
  helm template "$RELEASE" open-telemetry/opentelemetry-demo --version "$DEMO_CHART_VERSION" \
    -n "$NAMESPACE" "${args[@]}" \
    --show-only charts/opentelemetry-collector/templates/configmap-agent.yaml \
    | awk '/^  relay: \|/{p=1;next} p&&/^$/{print;next} p&&/^    /{sub(/^    /,"");print;next} p{exit}' > "$tmp/agent-$stage.yaml"
}

info "Rendering with demo chart $DEMO_CHART_VERSION and collector chart $GATEWAY_CHART_VERSION"
render_agent 00 common 00-baseline
render_agent 01 common 00-baseline 01-instrumentation-off
render_agent 02 common 00-baseline 01-instrumentation-off 02-filter-probabilistic
render_agent 03 common 00-baseline 01-instrumentation-off 03-tail-sampling
helm template "$GATEWAY_RELEASE" open-telemetry/opentelemetry-collector --version "$GATEWAY_CHART_VERSION" \
  -n "$NAMESPACE" -f "$ROOT/values/gateway.yaml" --show-only templates/configmap.yaml \
  | awk '/^  relay: \|/{p=1;next} p&&/^$/{print;next} p&&/^    /{sub(/^    /,"");print;next} p{exit}' > "$tmp/gateway.yaml"
helm template "$GATEWAY_RELEASE" open-telemetry/opentelemetry-collector --version "$GATEWAY_CHART_VERSION" \
  -n "$NAMESPACE" -f "$ROOT/values/gateway.yaml" -f "$ROOT/values/gateway-adaptive.yaml" --show-only templates/configmap.yaml \
  | awk '/^  relay: \|/{p=1;next} p&&/^$/{print;next} p&&/^    /{sub(/^    /,"");print;next} p{exit}' > "$tmp/gateway-adaptive.yaml"

for stage in 00 01 02 03; do
  [[ -s $tmp/agent-$stage.yaml ]] || die "stage $stage rendered an empty Collector config"
  echo "${B}stage $stage${N} traces pipelines:"
  awk '/^  pipelines:/{p=1;next} p&&/^  [a-z]/{exit} p&&/^    [^ ]/{show=($1 ~ /^traces/)} p&&show' "$tmp/agent-$stage.yaml" | sed 's/^/  /'
done
ok "helm template: every scenario and both gateway modes render"

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  warn "docker isn't available, so the Collector itself didn't validate the configs."
  exit 0
fi

info "Validating each config with $COLLECTOR_IMAGE"
for f in agent-00 agent-01 agent-02 agent-03 gateway gateway-adaptive; do
  # Outside a cluster two preset receivers check for things only a pod has:
  # the kubelet receiver wants a service-account token, the host-metrics
  # receiver wants the node's filesystem mounted at /hostfs. Override just
  # those two checks; the rest of the config is validated as rendered.
  extra=()
  [[ $f == agent-* ]] && extra=(--feature-gates=service.profilesSupport
    --set=receivers::kubeletstats::auth_type=none
    --set=receivers::hostmetrics::root_path=/)
    # label=disable: if docker is Podman underneath, SELinux would block the bind
  # mount (same reason as in Compose). Plain Docker accepts and ignores it.
  if docker run --rm --security-opt label=disable -v "$tmp:/cfg:ro" \
      -e MY_POD_IP=127.0.0.1 -e K8S_NODE_IP=127.0.0.1 -e K8S_NODE_NAME=node \
      "$COLLECTOR_IMAGE" validate --config="/cfg/$f.yaml" ${extra[@]+"${extra[@]}"} >"$tmp/$f.out" 2>&1; then
    ok "$f"
  else
    tail -n 3 "$tmp/$f.out" >&2
    die "$f is not a valid Collector config"
  fi
done

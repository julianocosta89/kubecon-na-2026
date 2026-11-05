# Astronomy Shop sampling demo — KubeCon NA 2026

The live demo for the sampling talk: the same OpenTelemetry Demo shop under the same load,
switched through five scenarios. Each scenario moves the "keep or drop this telemetry?"
decision to a different point of the pipeline, so the audience sees what each point saves,
costs and loses.

```text
app ──► network ──► Collector agents ──► gateway ──► Jaeger
 01                  02                   03  tail sampling (10% of the rest)
 don't create it     filter + sample 10%  04  adaptive tail sampling (a budget)
```

The earlier you decide, the more you save, and the less you know when you decide.

## The commands

```sh
make start      # kind cluster + everything, at the baseline (scenario 00)
make run 01     # rung 0:    stop creating telemetry nobody needs (flagd, frontend http)
make run 02     # rungs 2+3: drop named noise, then keep 10% of traces
make run 03     # rung 4:    tail sampling on a gateway tier
make run 04     # rung 4+:   adaptive tail sampling: a budget instead of a percentage
make stop       # delete the cluster and everything in it
```

`make run 00` goes back to the baseline. Scenarios can run in any order, and running one
twice is harmless.

Every `make run` prints three things:
1. **The idea**: what this rung is and why it exists.
2. **What changed in the cluster**: a real before/after diff, read back from Kubernetes.
   It shows the Collector's config as Kubernetes holds it, and every service environment
   variable that was added or removed. Scenario 03 also lists the gateway pods and the
   tail-sampling policies they run.
3. **Where to look and what to say**: which Perses rows move and how, the flag to flip, the
   trade-off, and the next command.

| Scenario | Rung | What it does | Script |
|---|---|---|---|
| 00 | — | Everything instrumented, nothing sampled | Stage A |
| 01 | 0 | flagd stops tracing, frontend drops its `http` instrumentation: ~1 in 5 spans, two env vars (no Collector change) | Stage B |
| 02 | 2 + 3 | OTTL filter for noise we can name, then probabilistic 10% in the agents | Stage C |
| 03 | 4 | Agents route by trace ID to 2 gateway pods: keep errors, keep slow, 10% of the rest | Stage D |
| 04 | 4+ | Same gateway, `adaptive_tail_sampling`: keep errors, the rest shares a ~15 spans/s budget per pod. Flip `loadGeneratorFloodHomepage` to show it | after Stage D |

## What `make start` builds

1. A kind cluster, `kubecon-sampling`: 1 control plane + 3 workers (`kind/cluster.yaml`).
   Three workers means three Collector agents (the demo's Collector is a DaemonSet), so the
   spans of one trace land on different agents. That's why scenario 03 needs the
   load-balancing exporter.
2. **Perses**, the live dashboard (`perses/`, `k8s/perses.yaml`).
3. The **OpenTelemetry Demo** 3.1.0 at the baseline (Helm chart 0.42.6, Collector bumped to 0.164.0),
   load generator at 10 users.
4. The tail-sampling **gateway** (Collector chart 0.173.1, same Collector 0.164.0), idle until
   scenario 03. Scenario 04 switches it to adaptive tail sampling (`values/gateway-adaptive.yaml`).
5. Port-forwards that reconnect by themselves when a pod restarts.

It's safe to run again: every step skips what already exists, and Perses picks up edits to
`perses/`.

## Browser tabs (the script's order)

| Tab | What | URL |
|---|---|---|
| 1 | Shop | http://localhost:8080 |
| 2 | Jaeger | http://localhost:8080/jaeger/ui |
| 3 | Editor with `values/`, zoom 160% | local |
| 4 | Perses "Sampling demo" | http://localhost:8090/projects/opentelemetry-demo/dashboards/sampling-demo |
| 5 | flagd UI (paymentFailure) | http://localhost:8080/feature |
| 6 | Backup recording | local |

Every tool on stage is a CNCF project. The Perses dashboard has four rows:
1. **What reaches the backend**: spans received by the Collector vs. sent to Jaeger, and
   the share kept.
2. **What it costs**: Collector CPU and memory per tier, and service CPU and memory.
3. **The failure**: the number of failed payments, counted by span metrics (every one), next to the failed
   payment traces in Jaeger (what's left to debug with).
4. **Tail sampling** (scenario 03): traces kept per policy, and decisions.
5. **Adaptive sampling** (scenario 04): spans kept by the budget against a dashed "a fixed 10%
   would send" line, traces kept and dropped per rule, and the 1-in-N rate the budget settles on.

Prometheus, which Perses reads, isn't shown on stage.

## Prerequisites

- `docker` (Docker, or Podman behind it) with at least **10 GB of memory and 6 CPUs**.
- `kind`, `kubectl`, `helm` 3, `python3` 3.8+, `make`.

The scripts only ever touch the kubectl context `kind-kubecon-sampling`; anything else is
refused. `make stop` deletes only that cluster.

### Podman

Nothing to change: every script calls `docker`, which your setup routes to Podman.

- No `label=disable` needed for the Collector: it runs as a pod and reads the kubelet and the
  Kubernetes API, never a container socket. `scripts/validate.sh` is the one place that
  bind-mounts a folder into a container, and it passes `--security-opt label=disable` itself.
- On macOS, give the podman machine room and make it rootful (kind is more reliable that way):
  `podman machine stop && podman machine set --rootful --memory 12288 --cpus 6 && podman machine start`
- If `make start` fails while creating nodes, run it as
  `KIND_EXPERIMENTAL_PROVIDER=podman make start` (kind's own Podman mode).
- If pods crash with "too many open files", raise the VM's inotify limits (a known kind issue
  with many pods), then `make stop && make start`:
  `podman machine ssh sudo sysctl -w fs.inotify.max_user_instances=512 fs.inotify.max_user_watches=524288`

## Dry-run tools (fill every [TK])

These aren't make commands; run them directly while the cluster is up.

```sh
bash scripts/validate.sh                       # render every scenario; the Collector validates each config
python3 scripts/demo.py scopes                 # spans per trace by instrumentation library, with the env var that turns each off
python3 scripts/demo.py overhead               # SDK on vs. off CPU: checkout (Go), ad (Java), cart (.NET), ~30 min each
caffeinate -i bash scripts/dry-run.sh          # every scenario 15 min + payment-failure test, + homepage flood in 02 and 04, then the scorecard (~2 h)
python3 scripts/demo.py flood                  # homepage flood for 5 min: spans received vs. sent, before and during
python3 scripts/demo.py scorecard              # print and save results/scorecard-*.md
python3 scripts/demo.py flag paymentFailure 50%   # same as the flagd UI; "off" to stop
```

1. Optional: `make start`, wait 10 min, run `scopes` to see what else is noisy. Scenario 01
   already turns off flagd's tracing and the frontend's `http` instrumentation
   (`values/01-instrumentation-off.yaml` explains both picks and what was ruled out).
2. Run `overhead` at the baseline (the "in-process tax" numbers for Stage A).
3. Run `dry-run.sh` twice. If the scorecards differ by more than ~10%, find out why.
4. Copy `results/scorecard-*.md` into the scorecard slide and the `[TK]` spots.
5. `make run 00` to leave it in the talk's start state.

The scorecard window per scenario is minutes 5–15 after it went live, cut short if the next
scenario or a flag change came first. Settings (users, flag variant, windows, ports) are in
`settings.env`.

## What differs from the flow doc, and why

- **The demo's Collector is a DaemonSet now**, and recent Collectors use snake_case component
  names: `load_balancing`, `otlp_grpc`, `span_metrics`, `resource_detection`.
- **Collector 0.164.0 instead of the chart's 0.160.0**, for agents and gateway alike. Scenario 04's
  `adaptive_tail_sampling` processor ships in `otelcol-contrib` from v0.163.0 and is **alpha**.
  Every scenario's config validates on 0.164.0, and the metric names the dashboard uses are
  unchanged. The tag is set in `values/common.yaml`, `values/gateway.yaml` and
  `scripts/validate.sh`; keep them in step.
- **Adaptive tail sampling settles near its budget, not exactly on it.** Every kind of trace
  keeps a minimum share. Tested locally on 0.164.0 with a 15 spans/s budget: traffic up 5.7x
  during a flood, spans kept up only 1.3x (to ~34/s, where a fixed 10% would have kept ~74/s),
  every error kept. Kept volume is lumpy, because a kept flood trace counts all its spans at once.
- **There are no health-check spans in this demo**, so `url.path == "/health"` would drop nothing.
  Scenario 02's filter drops the proxy's own tooling traffic instead: the browser's OTLP uploads,
  the Jaeger UI, the flag UI, the load-generator UI. Script line for Stage C: "First we drop
  noise we can name: the proxy tracing our own telemetry uploads and tool UIs."
- **Span metrics stay complete.** Scenarios 02 and 03 split traces into two pipelines with a
  `forward` connector: span metrics see 100%, only the second branch is filtered and sampled.
  The gap between the two is the "blind spot" moment in Perses row 3.
- **The gateway is found by DNS**, through a headless service; the `k8s` resolver would need
  extra RBAC.
- **Go has no `OTEL_SDK_DISABLED`.** For checkout the "off" run uses
  `OTEL_TRACES_SAMPLER=always_off`, which leaves metrics and logs on; the scorecard labels it as
  an approximation. Java uses `OTEL_JAVAAGENT_ENABLED=false`, .NET (cart) `OTEL_SDK_DISABLED=true`.
- **Rung 0 has two picks, both measured on the running shop.** The first guess (frontend,
  `net,dns`) produced zero spans. Instead: flagd traces every flag lookup as three spans (~1 in 8
  spans; `OTEL_TRACES_EXPORTER=none`), and the frontend's `http` instrumentation duplicates every
  Next.js server span and traces every static file (~1 in 10; `OTEL_NODE_DISABLED_INSTRUMENTATIONS=http`).
  Stage B line: "Two environment variables, and one in five spans is never created. Our flag
  service traced every lookup three times, and our frontend recorded every request twice."
- **kind kubelets use self-signed certificates**, so `values/common.yaml` sets
  `insecure_skip_verify` on the kubelet receiver. Without it there are no pod CPU numbers.
- **Load:** the chart default is 5 users; `values/common.yaml` sets 10. Change it there only.

## If something breaks on stage

| Symptom | Do this |
|---|---|
| A scenario misbehaves | `make run <previous scenario>`: every scenario is a complete, repeatable state |
| Perses or the shop stops answering | port-forwards reconnect on their own; if not, `bash scripts/port-forward.sh start` |
| A Perses panel is empty | edit the panel to see its PromQL; run it in Prometheus (localhost:9090) |
| Traces late in scenario 03 | expected: the gateway waits 10 s per trace |
| Anything else | the backup recording (tab 6), same lines |

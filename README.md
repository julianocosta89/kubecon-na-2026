# Sample Smarter, Not Harder (Or Not At All!)

The live demo from the talk *Sample Smarter, Not Harder (Or Not At All!)* at KubeCon +
CloudNativeCon North America 2026, by Juliano Costa (Dash0) and Reese Lee (New Relic). It runs
on the OpenTelemetry Astronomy Shop.

Telemetry costs something long before it reaches a backend. The app has to create it, the
network has to carry it, and every Collector along the way has to process it. Sampling decides
what to keep, but *where* you decide matters as much as *what* you decide. This repository runs
the [OpenTelemetry Demo](https://github.com/open-telemetry/opentelemetry-demo) on a local kind
cluster and walks through five scenarios. All five use the same shop under the same load; each
moves the "keep or drop?" decision to a different point of the pipeline:

```text
app ──► network ──► Collector agents ──► gateway ──► Jaeger
 01                  02                   03  tail sampling (keep errors + 10% of the rest)
 don't create it     filter + sample 10%  04  adaptive tail sampling (a spans/s budget)
```

**The earlier you decide, the more you save, and the less you know when you decide.**

Everything you see is open source and vendor-neutral: the OpenTelemetry Collector, Jaeger,
Prometheus and [Perses](https://perses.dev) for the dashboard.

## Requirements

- `docker` with at least **10 GB of memory and 6 CPUs** for the cluster. Podman behind a `docker`
  command works too; see [Podman](#podman).
- [`kind`](https://kind.sigs.k8s.io), `kubectl`, [`helm`](https://helm.sh) 3, `python3` 3.8+ and `make`.
- Time for the first start: it pulls images for about 20 services.

## Quick start

```sh
git clone https://github.com/julianocosta89/kubecon-na-2026.git
cd kubecon-na-2026
make start        # cluster + everything, at the baseline (scenario 00)
make run 01       # then 02, 03, 04: each prints what changed and where to look
make stop         # delete the cluster and everything in it
```

That's the whole interface:

| Command | What it does |
|---|---|
| `make start` | Creates the kind cluster and deploys everything at the baseline (scenario 00) |
| `make run 01` | Rung 0: stop creating telemetry nobody needs |
| `make run 02` | Rungs 2 and 3: drop noise you can name, then keep 10% of traces |
| `make run 03` | Rung 4: tail sampling on a gateway tier |
| `make run 04` | Adaptive tail sampling: a budget instead of a percentage |
| `make run 00` | Back to the baseline |
| `make stop` | Deletes the cluster and everything in it |

Scenarios can run in any order, and running one twice is harmless. Every `make run` prints three
things:

1. **The idea**: what this rung is and why it exists.
2. **What changed in the cluster**: a real before/after diff, read back from Kubernetes. It
   covers the agent Collectors' config, the gateway Collector's config, and every service
   environment variable that was added or removed. So you see exactly what each scenario does,
   whichever scenario you came from.
3. **Where to look**: which dashboard rows move and how, the feature flag to flip, the
   trade-off, and the next command.

## What `make start` builds

1. **A kind cluster** named `kubecon-sampling`: 1 control plane and 3 workers. Three workers means
   three Collector agents, because the demo's Collector runs as a DaemonSet. The spans of one
   trace really do land on different agents, which is why tail sampling (scenario 03) needs a
   gateway tier.
2. **Perses**, the live dashboard, with Prometheus and Jaeger as datasources.
3. **The OpenTelemetry Demo** 3.1.0 (Helm chart 0.42.6, with the Collector bumped to 0.164.0). Its
   load generator shops nonstop with 10 users.
4. **A gateway Collector tier**: 2 pods, the same Collector version, idle until scenario 03.
5. **Port-forwards** to your machine that reconnect by themselves when a pod restarts.

Running `make start` again skips whatever already exists, reloads the dashboard and puts the
demo back to the baseline.

When it finishes, open:

| What | URL |
|---|---|
| Perses, "Sampling demo" dashboard | http://localhost:8090/projects/opentelemetry-demo/dashboards/sampling-demo |
| Jaeger | http://localhost:8080/jaeger/ui |
| The shop | http://localhost:8080 |
| Feature flags (flagd UI) | http://localhost:8080/feature |

## Walkthrough

Give each scenario a few minutes before you compare numbers. The load generator's traffic swings
about ±10% from minute to minute, so compare levels, not single points.

### Scenario 00: the baseline

Every library is instrumented, nothing is filtered, nothing is sampled: this is the bill the
other scenarios cut. In Perses, row 1's "received" and "sent to Jaeger" lines lie on top of each
other, and "Share of spans kept" is about 100%. In Jaeger, open a `checkout` trace to see what
one purchase costs in telemetry.

### Scenario 01: don't create it

```sh
make run 01
```

The cheapest span is the one you never create. Sampling asks "should I keep this telemetry?";
this asks "should I create it at all?". Two environment variables, both picked by measuring this
shop:

- **flagd**, the feature-flag service, records every flag lookup as three spans: about 1 in 8 of
  all spans. Nobody debugs a flag lookup. `OTEL_TRACES_EXPORTER=none` stops flagd from creating
  them. Its metrics keep flowing.
- **frontend**: Node's `http` instrumentation duplicates the server span Next.js already records
  for every request, and adds a span for every static file. That's about 1 in 10 spans.
  `OTEL_NODE_DISABLED_INSTRUMENTATIONS=http` removes them, and traces stay connected because
  Next.js picks up the incoming trace context itself.

**Look for:** row 1's lines step down about 20% together, while "Share of spans kept" stays near
100%. You create less instead of dropping more. In Jaeger, a frontend request now has one server
span instead of two.

**Trade-off:** if flagd is ever the problem, there are no flagd spans to look at.
`values/01-instrumentation-off.yaml` explains both picks and lists the noisy sources that can't be
switched off by env var.

### Scenario 02: filter, then sample 10%

```sh
make run 02
```

The Collector agents decide, in two cheap steps:

- **Filter** (rung 2): an OTTL rule drops noise you can name. Here, that's the proxy tracing our
  own tooling: browser telemetry uploads and the Jaeger, flag and load-generator UIs.
- **Probabilistic sampling** (rung 3): keep 10% of traces. The sampler hashes the trace ID, so all
  three agents agree on every trace without talking to each other.

Span metrics are computed before both steps, so request and error rates stay complete.

**Look for:** row 1's "sent to Jaeger" drops to about a tenth of "received", and Collector CPU
barely moves.

**The blind spot:** break payments and count what's left to debug.

1. In the flagd UI, set `paymentFailure` to **100%**. The shop places only about 6 orders a minute,
   so lower values give too few failures to see.
2. Set Perses' time range to **Last 5 minutes** and wait a few minutes. Row 3 shows "Failed
   payments" (every one, from span metrics) next to the failed-payment traces in Jaeger. About
   1 in 10 failures has a trace: "30 payments failed, you get 3 to debug with."
3. Set `paymentFailure` back to **off**.

**Trade-off:** you decided before you knew how the request would end, so errors are sampled like
everything else.

### Scenario 03: tail sampling

```sh
make run 03
```

Wait until the whole trace has arrived, then decide with full knowledge: keep every trace with
an error, keep every trace slower than 2 s, and keep 10% of the rest. One Collector has to see
all of a trace's spans, so the agents route each span by trace ID to one of the 2 gateway pods,
which hold every trace for 10 s.

**Look for:** row 2 shows the gateway's own CPU and memory, the cost of the extra tier. Row 4
shows how many traces each policy keeps.

**The same failure, kept:** repeat the `paymentFailure` steps from scenario 02. Now the trace
list on the right matches the count on the left: "30 payments failed, you get all 30."
Traces show up 10–15 s late, because the gateway waits that long before deciding.

### Scenario 04: adaptive tail sampling

```sh
make run 04
```

"10%" is a promise about a ratio, not about your bill: if traffic triples, so does what you
keep. The same gateway now runs `adaptive_tail_sampling` instead. It keeps every trace with an
error, and everything else shares a budget of about 15 spans/s per gateway pod. The sampler
learns a rate for each kind of trace (the service that started it plus the routes it touched)
and adjusts every 15 s. A kind that suddenly floods in gets sampled hard, while rare kinds keep
a bigger share.

**The flood:**

1. In the flagd UI, switch `loadGeneratorFloodHomepage` **on**. The load generator now hits the
   homepage 100 times per flood task.
2. After about a minute, row 1's "received" line jumps several times over while "sent to Jaeger"
   barely moves. In row 5, the dashed "a fixed 10% would send" line jumps with the traffic, and
   "kept by the gateway" stays near the dotted budget line. The "1 in N" rate climbs: that's the
   sampler adapting.
3. Switch the flood **off** again; it's heavy on a laptop.

**Trade-off:** you pay a fixed amount, not a fixed fraction. Every kind of trace keeps a minimum
share, so it settles near the budget rather than exactly on it. The processor is **alpha**: it
shipped in `otelcol-contrib` v0.163.0 (October 2026).

### Done

```sh
make stop
```

This deletes the kind cluster with everything in it. Anything under `results/` is kept.

## The dashboard

The Perses dashboard "Sampling demo" has five rows:

1. **What reaches the backend**: spans received by the Collector vs. sent to Jaeger, and the
   share kept.
2. **What it costs**: Collector CPU and memory per tier, and service CPU and memory.
3. **The failure**: the number of failed payments, counted by span metrics, next to the failed
   payment traces in Jaeger. Use "Last 5 minutes" so both cover the same window.
4. **Tail sampling** (scenario 03): traces kept per policy, and sampled vs. not.
5. **Adaptive sampling** (scenario 04): spans kept by the gateway against a fixed-10% reference
   and the budget, traces kept and dropped per rule, and the 1-in-N rate the budget settles on.

The dashboard and its datasources are files in `perses/`. After editing them, `make start`
reloads Perses (and resets the demo to the baseline). To reload only Perses:

```sh
kubectl -n otel-demo create configmap perses-files \
  --from-file=perses/config.yaml --from-file=perses/provisioning/ \
  --dry-run=client -o yaml | kubectl -n otel-demo apply -f -
kubectl -n otel-demo rollout restart deploy/perses
```

## How it works

| Path | What it holds |
|---|---|
| `values/common.yaml` | Settings for every scenario: 10 users, Collector 0.164.0, span metrics every 15 s, two fixes for the chart and for kind |
| `values/00-baseline.yaml` … `03-tail-sampling.yaml` | One Helm values layer per scenario |
| `values/gateway.yaml`, `values/gateway-adaptive.yaml` | The gateway tier: tail sampling (03), and the adaptive overlay (04) |
| `stages/NN.txt` | The explanations `make run NN` prints |
| `perses/`, `k8s/perses.yaml` | The dashboard, its datasources, and the Perses deployment |
| `kind/cluster.yaml` | The kind cluster: 1 control plane + 3 workers |
| `scripts/` | What the make targets run, plus the measuring tools below |
| `settings.env` | Names, versions, ports and dry-run settings |

The scenarios are layered Helm values, applied with one `helm upgrade` each:

| Scenario | Agents (the demo's Collector) | Gateway |
|---|---|---|
| 00 | common + 00 | idle |
| 01 | common + 00 + 01 | idle |
| 02 | common + 00 + 01 + 02 | idle |
| 03 | common + 00 + 01 + 03 | `gateway.yaml` |
| 04 | common + 00 + 01 + 03 | `gateway.yaml` + `gateway-adaptive.yaml` |

Helm merges maps across files but replaces lists, so each scenario restates any pipeline it
touches in full. Scenarios 02–04 split the traces pipeline with a `forward` connector: span
metrics see 100% of spans, and only the second branch is filtered and sampled.

Every script only ever acts on the kubectl context `kind-kubecon-sampling` and refuses any
other, so a demo command can't touch another cluster by accident.

## Measuring it yourself

These tools aren't make targets; run them while the cluster is up:

```sh
bash scripts/validate.sh                     # render every scenario; the Collector validates each config
python3 scripts/demo.py scopes               # spans per trace by instrumentation library, with the env var that turns each off
python3 scripts/demo.py overhead             # app CPU with the SDK on vs. off: checkout (Go), ad (Java), cart (.NET), ~30 min each
python3 scripts/demo.py flood                # homepage flood for 5 min: spans received vs. sent, before and during
python3 scripts/demo.py flag paymentFailure 100%   # same as the flagd UI; "off" to stop
caffeinate -i bash scripts/dry-run.sh        # every scenario 15 min + failure test (+ flood in 02 and 04), then the scorecard (~2 h)
python3 scripts/demo.py scorecard            # print and save results/scorecard-*.md
```

`caffeinate` keeps a Mac awake during the run; leave it out elsewhere. The scorecard takes the
median of minutes 5–15 after each scenario went live, cut short when the next scenario or a flag
change comes first. Run the dry run twice: if the two scorecards differ by more than ~10%, find
out why before trusting either. The timings, users and flag variant are in `settings.env`.

## Notes

- **Collector 0.164.0 instead of the chart's 0.160.0**, for agents and gateway alike. Scenario
  04's processor needs v0.163.0 or later. Every scenario's config validates on 0.164.0. The version
  is set in `values/common.yaml`, `values/gateway.yaml` and `scripts/validate.sh`; keep them in
  step.
- **The load generator sends no telemetry in the stock Helm chart.** The chart points it at the
  Collector's HTTP port (4318), but it uses gRPC exporters. Docker Compose uses 4317, and so does
  `values/common.yaml`.
- **kind's kubelets use self-signed certificates.** Without `insecure_skip_verify` on the kubelet
  receiver there are no pod CPU or memory numbers.
- **Span metrics are pushed every 15 s** instead of every 60 s, so 1-minute rates always have
  data and the failure panels react quickly.
- **Go has no `OTEL_SDK_DISABLED`.** For the Go service, the "SDK off" run in `overhead` uses
  `OTEL_TRACES_SAMPLER=always_off`, which leaves metrics and logs on. The scorecard labels that
  result as an approximation.
- **Adaptive tail sampling, tested locally on 0.164.0** with a 15 spans/s budget: traffic up 5.7×
  during a flood, spans kept up only 1.3× (to ~34/s, where a fixed 10% would have kept ~74/s), and
  every error kept. Kept volume is lumpy, because a kept flood trace counts all its spans at once.

### Podman

Every script calls `docker`, so Podman works when `docker` routes to it.

- The Collector doesn't need `label=disable`: it runs as a pod and reads the kubelet and the
  Kubernetes API, never a container socket. `scripts/validate.sh` is the one place that mounts a
  folder into a container, and it passes `--security-opt label=disable` itself.
- On macOS, make the podman machine rootful and give it room:
  `podman machine stop && podman machine set --rootful --memory 12288 --cpus 6 && podman machine start`
- If `make start` fails while creating nodes, try `KIND_EXPERIMENTAL_PROVIDER=podman make start`.
- If pods crash with "too many open files", raise the VM's inotify limits, then
  `make stop && make start`:
  `podman machine ssh sudo sysctl -w fs.inotify.max_user_instances=512 fs.inotify.max_user_watches=524288`

## Troubleshooting

| Symptom | Do this |
|---|---|
| A scenario misbehaves | `make run` the previous scenario; every scenario is a complete, repeatable state |
| Perses or the shop stops answering | The port-forwards reconnect on their own; if not, `bash scripts/port-forward.sh start` |
| A Perses panel says "no data" | Give it a minute after a switch; to debug, edit the panel to see its PromQL and run it in Prometheus at http://localhost:9090 |
| No failed payments show up | Set `paymentFailure` to 100%, set Perses to "Last 5 minutes", and wait 2–3 minutes |
| Traces arrive late in scenarios 03 and 04 | Expected: the gateway waits for the whole trace before deciding |
| `make` refuses with a kubectl context error | Run `make start`; it creates the cluster if needed and switches kubectl to it |

## Presenting it

For the speakers, the scenarios map to the demo script like this:

| Scenario | Script segment |
|---|---|
| 00 | Stage A (0:00–1:30) |
| 01 | Stage B (1:30–3:00) |
| 02 | Stage C (3:00–5:00) |
| 03 | Stage D (5:00–7:00) |
| 04 | After Stage D, about 1.5 min more |

Suggested lines, all based on this setup's measurements:

- **Stage B:** "Two environment variables, and one in five spans is never created. Our flag
  service traced every lookup three times, and our frontend recorded every request twice."
- **Stage C, filter:** "First we drop noise we can name: the proxy tracing our own telemetry
  uploads and tool UIs." (The demo has no health-check spans to filter.)
- **Stage C, failure:** "30 payments failed. You get 3 to debug with."
- **Stage D:** "30 payments failed. You get all 30."
- **Scenario 04:** "A percentage is a promise about a ratio; a budget is a promise about your bill."

Before going on stage: run `make run 00`, set Perses to "Last 5 minutes" for the failure
moments, and keep both flags off until their scenario.

## License

[Apache License 2.0](LICENSE).

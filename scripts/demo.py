#!/usr/bin/env python3
"""Demo helpers. Python 3.8+, standard library only.

Talks to the cluster through the port-forwards that `make start` opens:
  flag UI    http://localhost:$PORT_SHOP/feature/api
  Jaeger     http://localhost:$PORT_JAEGER/jaeger/ui/api   (direct, so our own
             queries don't create proxy spans)
  Prometheus http://localhost:$PORT_PROMETHEUS/api/v1

Subcommands:
  flag NAME VARIANT|off   set a flagd flag the same way the flagd UI does
  scopes [--service S]    rank instrumentation scopes, to pick the rung-0 library
  errors-kept             flag on for FLAG_MINUTES, count failed spans kept vs. counted
  flood                   homepage flood for a few minutes: spans received vs. sent, before and during
  overhead                SDK on vs. off CPU for OVERHEAD_SERVICES
  scorecard               the scorecard numbers for every stage in the stage log
"""
import argparse
import datetime as dt
import json
import math
import os
import statistics
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RUN_DIR = os.path.join(ROOT, ".run")
RESULTS_DIR = os.path.join(ROOT, "results")
os.makedirs(RUN_DIR, exist_ok=True)
os.makedirs(RESULTS_DIR, exist_ok=True)


def load_settings():
    s = {}
    with open(os.path.join(ROOT, "settings.env")) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            s[k] = os.environ.get(k) or v
    return s


S = load_settings()
NS = S["NAMESPACE"]
SHOP = "http://localhost:%s" % S["PORT_SHOP"]
JAEGER = "http://localhost:%s/jaeger/ui/api" % S["PORT_JAEGER"]
PROM = "http://localhost:%s/api/v1" % S["PORT_PROMETHEUS"]
WARMUP = int(S["WARMUP_MIN"]) * 60
MEASURE = int(S["MEASURE_MIN"]) * 60

TTY = sys.stdout.isatty()


def c(code, text):
    return "\033[%sm%s\033[0m" % (code, text) if TTY else text


def info(msg):
    print(c("36", "==>"), msg, flush=True)


def die(msg):
    print(c("31", " ✗"), msg, file=sys.stderr)
    sys.exit(1)


def http_json(url, body=None, timeout=60):
    data = None
    headers = {"Accept": "application/json"}
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except urllib.error.URLError as e:
        die("%s → %s\n   Are the port-forwards up? Run: bash scripts/port-forward.sh start" % (url, e))


def event(kind, detail=""):
    with open(os.path.join(RUN_DIR, "events.log"), "a") as f:
        f.write("%d %s %s\n" % (time.time(), kind, detail))


def stage_log():
    """[(epoch, stage)] in the order stages were applied."""
    path = os.path.join(RUN_DIR, "stages.log")
    if not os.path.exists(path):
        return []
    out = []
    with open(path) as f:
        for line in f:
            parts = line.split()
            if len(parts) == 2:
                out.append((int(parts[0]), parts[1]))
    return out


def current_stage():
    log = stage_log()
    return log[-1][1] if log else None


def sleep_with_progress(seconds, label):
    end = time.time() + seconds
    while True:
        left = int(end - time.time())
        if left <= 0:
            break
        if TTY:
            print("\r   %s: %dm%02ds left " % (label, left // 60, left % 60), end="", flush=True)
        time.sleep(min(15, left))
    if TTY:
        print("\r" + " " * 60 + "\r", end="")


# ───────────────────────────── flags ─────────────────────────────

def set_flag(name, variant):
    current = http_json(SHOP + "/feature/api/read")
    flags = current.get("flags") or die("flag UI returned no flags")
    if name not in flags:
        die("unknown flag %r. Known: %s" % (name, ", ".join(sorted(flags))))
    variants = flags[name].get("variants", {})
    if variant not in variants:
        die("flag %s has no variant %r. Variants: %s" % (name, variant, ", ".join(variants)))
    flags[name]["defaultVariant"] = variant
    http_json(SHOP + "/feature/api/write",
              {"data": {"$schema": "https://flagd.dev/schema/v0/flags.json", "flags": flags}})
    event("flag", "%s=%s" % (name, variant))
    print(c("32", " ✓"), "%s → %s  (flagd picks it up in a second or two; the flagd UI shows it too)"
          % (name, variant))


def cmd_flag(a):
    set_flag(a.name, a.variant)


# ───────────────────────────── Jaeger ─────────────────────────────

def jaeger_traces(service, start, end, limit):
    q = urllib.parse.urlencode({"service": service, "start": int(start * 1e6),
                                "end": int(end * 1e6), "limit": limit})
    return http_json("%s/traces?%s" % (JAEGER, q), timeout=120).get("data") or []


def tag(span, *keys):
    for t in span.get("tags", []):
        if t.get("key") in keys:
            return t.get("value")
    return None


def is_error(span):
    v = tag(span, "error")
    return v is True or str(v).lower() == "true" or tag(span, "otel.status_code") == "ERROR"


def spans_of(trace, service):
    procs = trace.get("processes", {})
    for s in trace.get("spans", []):
        if procs.get(s.get("processID"), {}).get("serviceName") == service:
            yield s


def disable_hint(scope):
    if not scope or scope == "(no scope)":
        return "-"
    if scope.startswith("@opentelemetry/instrumentation-"):
        return "OTEL_NODE_DISABLED_INSTRUMENTATIONS=" + scope.split("instrumentation-", 1)[1]
    if scope.startswith("opentelemetry.instrumentation."):
        return "OTEL_PYTHON_DISABLED_INSTRUMENTATIONS=%s  (entry-point name)" % scope.split(".")[2]
    if scope.startswith("io.opentelemetry."):
        name = scope[len("io.opentelemetry."):].rsplit("-", 1)[0]
        return "OTEL_INSTRUMENTATION_%s_ENABLED=false" % name.upper().replace("-", "_").replace(".", "_")
    if scope.startswith("OpenTelemetry.AutoInstrumentation.") or scope.startswith("OpenTelemetry.Instrumentation."):
        name = scope.split(".")[-1].upper()
        return "auto: OTEL_DOTNET_AUTO_TRACES_%s_INSTRUMENTATION_ENABLED=false; SDK in code: remove Add…Instrumentation()" % name
    if "go.opentelemetry.io/contrib/instrumentation" in scope:
        return "Go: in code only"
    return "app code / framework"


def cmd_scopes(a):
    end = time.time()
    start = end - a.minutes * 60
    services = [a.service] if a.service else sorted(http_json(JAEGER + "/services").get("data") or [])
    if not services:
        die("Jaeger knows no services yet")
    rows = []
    for svc in services:
        counts, traces = {}, 0
        for tr in jaeger_traces(svc, start, end, a.limit):
            traces += 1
            for s in spans_of(tr, svc):
                scope = tag(s, "otel.scope.name", "otel.library.name") or "(no scope)"
                counts[scope] = counts.get(scope, 0) + 1
        total = sum(counts.values())
        for scope, n in counts.items():
            rows.append((svc, scope, n, n / total if total else 0, n / traces if traces else 0))
    rows.sort(key=lambda r: (-r[4], r[0]))
    stage = current_stage()
    print("Spans per trace by instrumentation scope, last %d min, up to %d traces per service%s"
          % (a.minutes, a.limit, "" if stage in (None, "00") else c("33", "   (stage %s is live: run this on stage 00)" % stage)))
    print()
    print("%-18s %-48s %10s %8s  %s" % ("service", "scope", "per trace", "share", "turn it off with"))
    for svc, scope, n, share, per_trace in rows[: a.top]:
        print("%-18s %-48s %10.1f %7.0f%%  %s" % (svc, scope[:48], per_trace, share * 100, disable_hint(scope)))
    print()
    print("Pick a scope with a high 'per trace' that nobody on the team queries, then edit")
    print("values/01-instrumentation-off.yaml. Go and manual-SDK services can't be switched by env var.")


# ─────────────────────────── Prometheus ───────────────────────────

def prom_range(query, start, end, step=30):
    q = urllib.parse.urlencode({"query": query, "start": start, "end": end, "step": step})
    res = http_json("%s/query_range?%s" % (PROM, q))
    if res.get("status") != "success":
        die("Prometheus error for %s: %s" % (query, res))
    return res["data"]["result"]


def prom_instant(query, at):
    q = urllib.parse.urlencode({"query": query, "time": at})
    res = http_json("%s/query?%s" % (PROM, q))
    if res.get("status") != "success":
        die("Prometheus error for %s: %s" % (query, res))
    return res["data"]["result"]


def median_of(series):
    vals = []
    for s in series:
        for _, v in s["values"]:
            f = float(v)
            if not math.isnan(f):
                vals.append(f)
    return statistics.median(vals) if vals else None


def median_by(series, label):
    out = {}
    for s in series:
        vals = [float(v) for _, v in s["values"] if not math.isnan(float(v))]
        if vals:
            out[s["metric"].get(label, "?")] = statistics.median(vals)
    return out


M_ACCEPTED = 'otelcol_receiver_accepted_spans(_total)?'
M_SENT = 'otelcol_exporter_sent_spans(_total)?'
M_CPU = 'otelcol_process_cpu_seconds(_total)?'
M_RSS = 'otelcol_process_memory_rss(_bytes)?'
M_POD_CPU = 'k8s_pod_cpu_usage.*'
M_CALLS = 'traces_span_metrics_calls(_total)?'


def collector_tiers(stage):
    return "otel-collector|otel-gateway" if stage in ("03", "04") else "otel-collector"


def pod_cpu_query(deployments):
    return ('sum by (k8s_deployment_name) ({__name__=~"%s", k8s_namespace_name="%s", k8s_deployment_name=~"%s"})'
            % (M_POD_CPU, NS, "|".join(deployments)))


# ─────────────────────────── errors kept ──────────────────────────

def cmd_errors_kept(a):
    stage = a.stage or current_stage() or die("no scenario applied yet (make start)")
    minutes = a.minutes
    info("Stage %s: %s → %s for %d min, then counting failed payment spans" % (stage, S["FLAG_NAME"], S["FLAG_VARIANT"], minutes))
    set_flag(S["FLAG_NAME"], S["FLAG_VARIANT"])
    t_on = time.time()
    try:
        sleep_with_progress(minutes * 60, "payment failures on")
    finally:
        set_flag(S["FLAG_NAME"], "off")
    t_off = time.time()
    info("Waiting 90 s for tail-sampling decisions and the span-metrics flush")
    time.sleep(90)

    kept = 0
    for tr in jaeger_traces("payment", t_on - 5, t_off + 30, 10000):
        kept += sum(1 for s in spans_of(tr, "payment") if is_error(s))
    q = ('sum(increase({__name__=~"%s", service_name="payment", status_code="STATUS_CODE_ERROR"}[%ds]))'
         % (M_CALLS, int(time.time() - t_on)))
    res = prom_instant(q, time.time())
    counted = float(res[0]["value"][1]) if res else 0.0
    ratio = kept / counted if counted else None
    rec = {"stage": stage, "t_on": int(t_on), "t_off": int(t_off), "variant": S["FLAG_VARIANT"],
           "kept_in_jaeger": kept, "counted_by_span_metrics": round(counted), "ratio": ratio}
    with open(os.path.join(RESULTS_DIR, "errors-kept.jsonl"), "a") as f:
        f.write(json.dumps(rec) + "\n")
    print()
    print("  failed payment spans in Jaeger      %d" % kept)
    print("  failed payment spans (span metrics) %d" % round(counted))
    print("  errors kept                         %s" % ("%.0f%%" % (ratio * 100) if ratio is not None else "n/a"))
    print(c("2", "  saved to results/errors-kept.jsonl"))


# ───────────────────────────── overhead ───────────────────────────

LANGUAGE = {
    "checkout": "go", "product-catalog": "go",
    "ad": "java", "fraud-detection": "java",
    "cart": "dotnet",
    "payment": "node", "frontend": "node",
    "recommendation": "python",
}
SDK_OFF = {
    "go": ("OTEL_TRACES_SAMPLER", "always_off",
           "approximation: the Go SDK has no OTEL_SDK_DISABLED; spans become no-ops, metrics and logs keep running"),
    "java": ("OTEL_JAVAAGENT_ENABLED", "false", ""),
    "dotnet": ("OTEL_SDK_DISABLED", "true", ""),
    "node": ("OTEL_SDK_DISABLED", "true", ""),
    "python": ("OTEL_SDK_DISABLED", "true", "instrumentors still wrap libraries; the SDK behind them is a no-op"),
}


# ───────────────────────────── flood ──────────────────────────────

FLOOD_FLAG = "loadGeneratorFloodHomepage"


def cmd_flood(a):
    """The load generator's homepage flood: what the sampler sends while traffic jumps.
    Scenario 02 (fixed 10%) should send ~10x more during the flood; scenario 04
    (adaptive budget) should stay near its budget."""
    stage = a.stage or current_stage() or die("no scenario applied yet (make start)")
    warm, measure = 120, max(60, a.minutes * 60 - 120)
    tiers = collector_tiers(stage)
    q_in = 'sum(rate({__name__=~"%s", service_name="otel-collector"}[1m]))' % M_ACCEPTED
    q_out = ('sum(rate({__name__=~"%s", service_name=~"%s", exporter="otlp_grpc/jaeger"}[1m]))'
             % (M_SENT, tiers))
    t0 = time.time()
    before_in = median_of(prom_range(q_in, t0 - 300, t0))
    before_out = median_of(prom_range(q_out, t0 - 300, t0))
    info("Scenario %s: %s on for %d min (first 2 are warm-up)" % (stage, FLOOD_FLAG, a.minutes))
    set_flag(FLOOD_FLAG, "on")
    try:
        sleep_with_progress(warm + measure, "homepage flood on")
    finally:
        set_flag(FLOOD_FLAG, "off")
    t1 = time.time()
    flood_in = median_of(prom_range(q_in, t1 - measure, t1))
    flood_out = median_of(prom_range(q_out, t1 - measure, t1))
    rec = {"stage": stage, "t_on": int(t0), "t_off": int(t1),
           "before_in": before_in, "before_out": before_out, "flood_in": flood_in, "flood_out": flood_out}
    with open(os.path.join(RESULTS_DIR, "flood.jsonl"), "a") as f:
        f.write(json.dumps(rec) + "\n")
    ratio = lambda a_, b_: ("x%.1f" % (a_ / b_)) if a_ and b_ else "—"
    print()
    print("                      before   during flood")
    print("  spans received /s   %6s   %6s  (%s)" % (fmt(before_in), fmt(flood_in), ratio(flood_in, before_in)))
    print("  spans sent /s       %6s   %6s  (%s)" % (fmt(before_out), fmt(flood_out), ratio(flood_out, before_out)))
    print(c("2", "  saved to results/flood.jsonl"))


def kubectl(*args):
    subprocess.run(["kubectl", "-n", NS] + list(args), check=True, stdout=subprocess.DEVNULL)


def cmd_overhead(a):
    want = S.get("KUBE_CONTEXT", "")
    if want:
        cur = subprocess.run(["kubectl", "config", "current-context"], capture_output=True, text=True).stdout.strip()
        if cur != want:
            die("kubectl points at %r, expected %r. Run: make start" % (cur, want))
    services = [s for s in a.services.split(",") if s]
    per_phase = WARMUP + MEASURE
    info("SDK on vs. off for %s. %d min per phase, %d min total. Keep the stage and the load fixed meanwhile."
         % (", ".join(services), per_phase // 60, per_phase * 2 * len(services) // 60))
    stage = current_stage()
    for svc in services:
        lang = LANGUAGE.get(svc)
        if lang not in SDK_OFF:
            die("don't know how to turn the SDK off in %r. Known: %s" % (svc, ", ".join(LANGUAGE)))
        var, val, note = SDK_OFF[lang]
        info("%s (%s): phase ON" % (svc, lang))
        on_start = time.time()
        sleep_with_progress(per_phase, "%s on" % svc)
        info("%s: phase OFF  (%s=%s)" % (svc, var, val))
        try:
            kubectl("set", "env", "deploy/" + svc, "%s=%s" % (var, val))
            kubectl("rollout", "status", "deploy/" + svc, "--timeout=5m")
            off_start = time.time()
            sleep_with_progress(per_phase, "%s off" % svc)
        finally:
            kubectl("set", "env", "deploy/" + svc, var + "-")
            kubectl("rollout", "status", "deploy/" + svc, "--timeout=5m")
        on = median_by(prom_range(pod_cpu_query([svc]), on_start + WARMUP, on_start + per_phase), "k8s_deployment_name").get(svc)
        off = median_by(prom_range(pod_cpu_query([svc]), off_start + WARMUP, off_start + per_phase), "k8s_deployment_name").get(svc)
        rec = {"service": svc, "language": lang, "stage": stage, "off_switch": "%s=%s" % (var, val), "note": note,
               "cpu_on_mcores": on and on * 1000, "cpu_off_mcores": off and off * 1000,
               "overhead_pct": ((on - off) / off * 100) if on and off else None,
               "on_start": int(on_start), "off_start": int(off_start)}
        with open(os.path.join(RESULTS_DIR, "overhead.jsonl"), "a") as f:
            f.write(json.dumps(rec) + "\n")
        if rec["overhead_pct"] is None:
            print(c("33", " ! no pod CPU in Prometheus for %s. Check that kubeletstats metrics arrive "
                          "(query k8s_pod_cpu_usage), or measure with 'kubectl top pod'." % svc))
        else:
            print("   %s: on %.0f mcores, off %.0f mcores → overhead %.0f%%%s"
                  % (svc, on * 1000, off * 1000, rec["overhead_pct"], ("   (%s)" % note) if note else ""))


# ───────────────────────────── scorecard ──────────────────────────

def last_jsonl(name, key):
    path = os.path.join(RESULTS_DIR, name)
    out = {}
    if os.path.exists(path):
        with open(path) as f:
            for line in f:
                rec = json.loads(line)
                out[rec[key]] = rec
    return out


def flag_on_times():
    path = os.path.join(RUN_DIR, "events.log")
    out = []
    if os.path.exists(path):
        with open(path) as f:
            for line in f:
                parts = line.split()
                if len(parts) >= 3 and parts[1] == "flag" and not parts[2].endswith("=off"):
                    out.append(int(parts[0]))
    return out


def fmt(v, pattern="%.0f"):
    return pattern % v if v is not None else "—"


def cmd_scorecard(a):
    log = stage_log()
    if not log:
        die("no stages in .run/stages.log yet. Run make start (or bash scripts/dry-run.sh).")
    latest = {}
    for i, (t, stage) in enumerate(log):
        nxt = log[i + 1][0] if i + 1 < len(log) else None
        latest[stage] = (t, nxt)
    flags = flag_on_times()
    errors = last_jsonl("errors-kept.jsonl", "stage")
    overhead = last_jsonl("overhead.jsonl", "service")
    services = [s for s in S["OVERHEAD_SERVICES"].split(",") if s]

    rows = []
    for stage in ["00", "01", "02", "03", "04"]:
        if stage not in latest:
            continue
        t, nxt = latest[stage]
        start = t + WARMUP
        end = t + WARMUP + MEASURE
        for limit in [nxt] + [f for f in flags if f > t]:
            if limit is not None and limit < end:
                end = limit
        end = min(end, time.time())
        short = end - start < MEASURE - 30
        if end <= start + 60:
            rows.append((stage, None, None, None, None, None, {}, "window too short (ran %ds)" % (end - t)))
            continue
        tiers = collector_tiers(stage)
        spans_in = median_of(prom_range('sum(rate({__name__=~"%s", service_name="otel-collector"}[2m]))' % M_ACCEPTED, start, end))
        spans_out = median_of(prom_range('sum(rate({__name__=~"%s", service_name=~"%s", exporter="otlp_grpc/jaeger"}[2m]))' % (M_SENT, tiers), start, end))
        cpu = median_of(prom_range('sum(rate({__name__=~"%s", service_name=~"%s"}[2m]))' % (M_CPU, tiers), start, end))
        rss = median_of(prom_range('sum({__name__=~"%s", service_name=~"%s"})' % (M_RSS, tiers), start, end))
        svc_cpu = median_by(prom_range(pod_cpu_query(services), start, end), "k8s_deployment_name")
        err = errors.get(stage)
        note = "short window: %d min" % ((end - start) // 60) if short else ""
        rows.append((stage, spans_in, spans_out, cpu, rss, err, svc_cpu, note))

    names = {"00": "Baseline", "01": "Noisy instrumentation off", "02": "Filter + probabilistic 10%",
             "03": "Tail sampling", "04": "Adaptive tail sampling"}
    lines = []
    lines.append("# Sampling demo scorecard — %s" % dt.datetime.now().strftime("%Y-%m-%d %H:%M"))
    lines.append("")
    lines.append("Median of minutes %d–%d after each stage went live. Load: same for every stage."
                 % (WARMUP // 60, (WARMUP + MEASURE) // 60))
    lines.append("")
    lines.append("| Stage | Spans in /s | Spans exported /s | Collector CPU · memory | Errors kept | Service CPU (%s) | Note |"
                 % " · ".join(services))
    lines.append("|---|---:|---:|---:|---:|---:|---|")
    for stage, spans_in, spans_out, cpu, rss, err, svc_cpu, note in rows:
        errs = "—"
        if err and err.get("ratio") is not None:
            errs = "%.0f%% (%d/%d)" % (err["ratio"] * 100, err["kept_in_jaeger"], err["counted_by_span_metrics"])
        coll = "%s m · %s MiB" % (fmt(cpu and cpu * 1000), fmt(rss and rss / 2 ** 20))
        svc = " · ".join("%s m" % fmt(svc_cpu.get(s) and svc_cpu.get(s) * 1000) for s in services)
        lines.append("| %s %s | %s | %s | %s | %s | %s | %s |"
                     % (stage, names[stage], fmt(spans_in), fmt(spans_out), coll, errs, svc, note))
    flood = last_jsonl("flood.jsonl", "stage")
    if flood:
        lines.append("")
        lines.append("## Under the homepage flood (loadGeneratorFloodHomepage on)")
        lines.append("")
        lines.append("| Scenario | Spans received /s: before → flood | Spans sent /s: before → flood |")
        lines.append("|---|---:|---:|")
        for st in sorted(flood):
            r = flood[st]
            lines.append("| %s %s | %s → %s | %s → %s |" % (st, names.get(st, ""), fmt(r["before_in"]), fmt(r["flood_in"]),
                                                       fmt(r["before_out"]), fmt(r["flood_out"])))
    if overhead:
        lines.append("")
        lines.append("## In-process overhead (SDK on vs. off, same service, same load)")
        lines.append("")
        lines.append("| Service | Language | On | Off | Overhead | Off switch |")
        lines.append("|---|---|---:|---:|---:|---|")
        for s in services + [s for s in overhead if s not in services]:
            r = overhead.get(s)
            if not r:
                continue
            lines.append("| %s | %s | %s m | %s m | %s | `%s`%s |" % (
                s, r["language"], fmt(r["cpu_on_mcores"]), fmt(r["cpu_off_mcores"]),
                fmt(r["overhead_pct"], "%.0f%%"), r["off_switch"], (" — " + r["note"]) if r["note"] else ""))
        lines.append("")
        lines.append("Compare languages by each service's own on/off delta, not by raw CPU: the services do different work.")
    text = "\n".join(lines) + "\n"
    print(text)
    path = os.path.join(RESULTS_DIR, "scorecard-%s.md" % dt.datetime.now().strftime("%Y%m%d-%H%M"))
    with open(path, "w") as f:
        f.write(text)
    print(c("2", "saved to %s" % os.path.relpath(path, ROOT)))


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    f = sub.add_parser("flag")
    f.add_argument("name")
    f.add_argument("variant")
    f.set_defaults(fn=cmd_flag)

    sc = sub.add_parser("scopes")
    sc.add_argument("--service")
    sc.add_argument("--minutes", type=int, default=10)
    sc.add_argument("--limit", type=int, default=200)
    sc.add_argument("--top", type=int, default=25)
    sc.set_defaults(fn=cmd_scopes)

    e = sub.add_parser("errors-kept")
    e.add_argument("--stage")
    e.add_argument("--minutes", type=int, default=int(S["FLAG_MINUTES"]))
    e.set_defaults(fn=cmd_errors_kept)

    fl = sub.add_parser("flood")
    fl.add_argument("--stage")
    fl.add_argument("--minutes", type=int, default=5)
    fl.set_defaults(fn=cmd_flood)

    o = sub.add_parser("overhead")
    o.add_argument("--services", default=S["OVERHEAD_SERVICES"])
    o.set_defaults(fn=cmd_overhead)

    s = sub.add_parser("scorecard")
    s.set_defaults(fn=cmd_scorecard)

    a = p.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()

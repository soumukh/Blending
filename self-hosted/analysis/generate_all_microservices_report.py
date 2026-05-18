#!/usr/bin/env python3
import argparse
import csv
import math
import re
from collections import defaultdict
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_RESULTS = ROOT / "analysis" / "results"

SUMMARY_COLUMNS = [
    "phase",
    "label",
    "target_service",
    "workload",
    "placement_mode",
    "users",
    "duration_seconds",
    "decision",
    "health_code",
    "locust_exit",
    "metrics_exit",
    "locust_request_count",
    "locust_failure_count",
    "locust_failure_pct",
    "locust_median_ms",
    "locust_avg_latency_ms",
    "locust_p95_ms",
    "locust_p99_ms",
    "locust_req_rate",
    "service",
    "deployment",
    "backend",
    "cpu_pct",
    "mem_pct",
    "service_request_count",
    "service_req_rate",
    "service_error_count",
    "service_error_pct",
    "service_p50_ms",
    "service_p95_ms",
    "service_p99_ms",
    "service_avg_latency_ms",
    "exec_grpc_ms",
    "faas_exec_p99_ms",
    "cold_start_count",
    "cold_start_p99_ms",
    "metric_source",
    "data_quality",
    "stats_file",
    "metrics_file",
]

PAPER_COLUMNS = [
    "Application",
    "Deployment",
    "Load",
    "Target service",
    "Service",
    "Backend",
    "Requests",
    "Fails",
    "Median latency (ms)",
    "Average latency (ms)",
    "p95 latency (ms)",
    "p99 latency (ms)",
    "CPU (%)",
    "Memory (%)",
    "Service p50 latency (ms)",
    "Service p95 latency (ms)",
    "Service p99 latency (ms)",
    "Metric source",
    "Data quality",
]

SWITCH_COLUMNS = [
    "service",
    "faas_to_iaas",
    "iaas_to_faas",
    "high_windows",
    "recovery_windows",
    "logs_with_events",
    "data_quality",
]

SWITCH_RE = re.compile(
    r"\[([A-Za-z0-9_-]+)\]\s+switching\s+(IaaS|FaaS)\s+->\s+(IaaS|FaaS)"
)


def read_csv(path: Path) -> list[dict[str, str]]:
    try:
        with path.open(newline="", encoding="utf-8") as handle:
            return list(csv.DictReader(handle))
    except Exception:
        return []


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except Exception:
        return ""


def to_float(value: object) -> float:
    try:
        parsed = float(value)
    except (TypeError, ValueError):
        return math.nan
    return parsed if math.isfinite(parsed) else math.nan


def fmt_number(value: object, digits: int = 2) -> str:
    parsed = to_float(value)
    if not math.isfinite(parsed):
        return ""
    return f"{parsed:.{digits}f}"


def fmt_int(value: object) -> str:
    parsed = to_float(value)
    if not math.isfinite(parsed):
        return ""
    return str(int(round(parsed)))


def safe_relative(path: Path) -> str:
    try:
        return str(path.relative_to(ROOT))
    except ValueError:
        return str(path)


def deployment_name(phase: str) -> str:
    if phase == "phase1":
        return "IaaS only"
    if phase == "phase3":
        return "Hybrid"
    return phase or "unknown"


def label_from_stats(path: Path) -> str:
    name = path.name
    if name.endswith("_stats.csv"):
        return name[: -len("_stats.csv")]
    return path.stem


def phase_dir_for(phase: str, root: Path) -> Path:
    return root / phase


def latest_scenario_rows(rows: list[dict[str, str]]) -> list[dict[str, str]]:
    latest: dict[tuple[str, str], dict[str, str]] = {}
    for row in rows:
        key = (row.get("phase", ""), row.get("label", ""))
        if key in latest:
            del latest[key]
        latest[key] = row
    return list(latest.values())


def aggregate_row(path: Path) -> dict[str, str]:
    for row in read_csv(path):
        if row.get("Name") == "Aggregated":
            return row
    return {}


def locust_stats(path: Path) -> dict[str, str]:
    aggregate = aggregate_row(path)
    if not aggregate:
        return {
            "locust_request_count": "",
            "locust_failure_count": "",
            "locust_failure_pct": "",
            "locust_median_ms": "",
            "locust_avg_latency_ms": "",
            "locust_p95_ms": "",
            "locust_p99_ms": "",
            "locust_req_rate": "",
        }

    requests = to_float(aggregate.get("Request Count"))
    failures = to_float(aggregate.get("Failure Count"))
    failure_pct = math.nan
    if math.isfinite(requests) and requests > 0 and math.isfinite(failures):
        failure_pct = failures / requests * 100

    return {
        "locust_request_count": fmt_int(requests),
        "locust_failure_count": fmt_int(failures),
        "locust_failure_pct": fmt_number(failure_pct, 4),
        "locust_median_ms": fmt_number(aggregate.get("Median Response Time"), 2),
        "locust_avg_latency_ms": fmt_number(aggregate.get("Average Response Time"), 2),
        "locust_p95_ms": fmt_number(aggregate.get("95%"), 2),
        "locust_p99_ms": fmt_number(aggregate.get("99%"), 2),
        "locust_req_rate": fmt_number(aggregate.get("Requests/s"), 4),
    }


def scenario_status(root: Path) -> list[dict[str, str]]:
    path = root / "scenario_status.csv"
    if path.exists():
        return latest_scenario_rows(read_csv(path))

    rows = []
    for stats in sorted(root.glob("phase*/**/*_stats.csv")):
        if stats.name.endswith("_stats_history.csv"):
            continue
        phase = "phase1" if "phase1" in stats.parts else "phase3"
        label = label_from_stats(stats)
        rows.append(
            {
                "phase": phase,
                "label": label,
                "target_service": "",
                "workload": "",
                "placement_mode": deployment_name(phase),
                "users": "",
                "duration_seconds": "",
                "locust_exit": "",
                "health_code": "",
                "metrics_exit": "",
                "decision": "completed",
            }
        )
    return rows


def metrics_rows(path: Path) -> list[dict[str, str]]:
    rows = read_csv(path)
    if not rows:
        return []
    if "service" not in rows[0]:
        return []
    return rows


def merged_summary(root: Path) -> list[dict[str, str]]:
    rows = []
    for scenario in scenario_status(root):
        phase = scenario.get("phase", "")
        label = scenario.get("label", "")
        if not phase or not label:
            continue

        phase_dir = phase_dir_for(phase, root)
        stats_path = phase_dir / f"{label}_stats.csv"
        metrics_path = phase_dir / f"{label}_metrics.csv"
        locust = locust_stats(stats_path)
        metrics = metrics_rows(metrics_path)

        if not metrics:
            metrics = [
                {
                    "service": "",
                    "deployment": "",
                    "backend": "",
                    "data_quality": "missing_metrics_csv",
                }
            ]

        for metric in metrics:
            row = {
                "phase": phase,
                "label": label,
                "target_service": scenario.get("target_service", ""),
                "workload": scenario.get("workload", ""),
                "placement_mode": scenario.get("placement_mode", ""),
                "users": scenario.get("users", ""),
                "duration_seconds": scenario.get("duration_seconds", ""),
                "decision": scenario.get("decision", ""),
                "health_code": scenario.get("health_code", ""),
                "locust_exit": scenario.get("locust_exit", ""),
                "metrics_exit": scenario.get("metrics_exit", ""),
                "stats_file": safe_relative(stats_path) if stats_path.exists() else "",
                "metrics_file": safe_relative(metrics_path) if metrics_path.exists() else "",
            }
            row.update(locust)
            row.update(
                {
                    "service": metric.get("service", ""),
                    "deployment": metric.get("deployment", ""),
                    "backend": metric.get("backend", ""),
                    "cpu_pct": fmt_number(metric.get("cpu_pct"), 4),
                    "mem_pct": fmt_number(metric.get("mem_pct"), 4),
                    "service_request_count": fmt_number(metric.get("request_count"), 4),
                    "service_req_rate": fmt_number(metric.get("req_rate"), 4),
                    "service_error_count": fmt_number(metric.get("error_count"), 4),
                    "service_error_pct": fmt_number(metric.get("error_pct"), 4),
                    "service_p50_ms": fmt_number(metric.get("p50_ms"), 2),
                    "service_p95_ms": fmt_number(metric.get("p95_ms"), 2),
                    "service_p99_ms": fmt_number(metric.get("p99_ms"), 2),
                    "service_avg_latency_ms": fmt_number(metric.get("avg_latency_ms"), 2),
                    "exec_grpc_ms": fmt_number(metric.get("exec_grpc_ms"), 2),
                    "faas_exec_p99_ms": fmt_number(metric.get("faas_exec_p99_ms"), 2),
                    "cold_start_count": fmt_number(metric.get("cold_start_count"), 4),
                    "cold_start_p99_ms": fmt_number(metric.get("cold_start_p99_ms"), 2),
                    "metric_source": metric.get("metric_source", ""),
                    "data_quality": metric.get("data_quality", ""),
                }
            )
            rows.append(row)
    return rows


def is_comparison_row(row: dict[str, str]) -> bool:
    label = row.get("label", "")
    return label.startswith("phase1_") or label.startswith("phase3_")


def paper_rows(summary_rows: list[dict[str, str]]) -> list[dict[str, str]]:
    rows = []
    for row in summary_rows:
        if not is_comparison_row(row):
            continue
        load = (
            f"{row.get('target_service', '')} "
            f"{row.get('users', '')} users "
            f"({row.get('workload', '')})"
        ).strip()
        rows.append(
            {
                "Application": "GoB",
                "Deployment": deployment_name(row.get("phase", "")),
                "Load": load,
                "Target service": row.get("target_service", ""),
                "Service": row.get("service", ""),
                "Backend": row.get("backend", ""),
                "Requests": row.get("locust_request_count", ""),
                "Fails": row.get("locust_failure_count", ""),
                "Median latency (ms)": row.get("locust_median_ms", ""),
                "Average latency (ms)": row.get("locust_avg_latency_ms", ""),
                "p95 latency (ms)": row.get("locust_p95_ms", ""),
                "p99 latency (ms)": row.get("locust_p99_ms", ""),
                "CPU (%)": row.get("cpu_pct", ""),
                "Memory (%)": row.get("mem_pct", ""),
                "Service p50 latency (ms)": row.get("service_p50_ms", ""),
                "Service p95 latency (ms)": row.get("service_p95_ms", ""),
                "Service p99 latency (ms)": row.get("service_p99_ms", ""),
                "Metric source": row.get("metric_source", ""),
                "Data quality": row.get("data_quality", ""),
            }
        )
    return rows


def switch_window_counts(status_rows: list[dict[str, str]]) -> dict[str, dict[str, int]]:
    windows: dict[str, dict[str, int]] = defaultdict(
        lambda: {"high_windows": 0, "recovery_windows": 0}
    )
    pattern = re.compile(r"^switch_([A-Za-z0-9_-]+)_cycle\d+_(high|low)_")
    for row in status_rows:
        if row.get("decision") != "completed":
            continue
        match = pattern.match(row.get("label", ""))
        if not match:
            continue
        service, kind = match.groups()
        if kind == "high":
            windows[service]["high_windows"] += 1
        else:
            windows[service]["recovery_windows"] += 1
    return windows


def switch_summary(root: Path, status_rows: list[dict[str, str]]) -> list[dict[str, str]]:
    counts: dict[str, dict[str, int]] = defaultdict(
        lambda: {"faas_to_iaas": 0, "iaas_to_faas": 0, "logs_with_events": 0}
    )
    seen_events = set()
    for log_path in sorted(root.glob("phase3/**/*controller*.log")):
        had_event = False
        for line in read_text(log_path).splitlines():
            match = SWITCH_RE.search(line)
            if not match:
                continue
            service, source, target = match.groups()
            event_key = (service, source, target, line.strip())
            if event_key in seen_events:
                continue
            seen_events.add(event_key)
            key = f"{source.lower()}_to_{target.lower()}"
            if key in {"faas_to_iaas", "iaas_to_faas"}:
                counts[service][key] += 1
                had_event = True
        if had_event:
            services_in_log = {
                match.group(1)
                for line in read_text(log_path).splitlines()
                for match in [SWITCH_RE.search(line)]
                if match
            }
            for service in services_in_log:
                counts[service]["logs_with_events"] += 1

    windows = switch_window_counts(status_rows)
    services = sorted(set(counts) | set(windows))
    rows = []
    for service in services:
        row = {
            "service": service,
            "faas_to_iaas": str(counts[service]["faas_to_iaas"]),
            "iaas_to_faas": str(counts[service]["iaas_to_faas"]),
            "high_windows": str(windows[service]["high_windows"]),
            "recovery_windows": str(windows[service]["recovery_windows"]),
            "logs_with_events": str(counts[service]["logs_with_events"]),
            "data_quality": "switches_seen"
            if counts[service]["faas_to_iaas"] or counts[service]["iaas_to_faas"]
            else "no_switch_events_in_logs",
        }
        rows.append(row)
    return rows


def write_csv(path: Path, columns: list[str], rows: list[dict[str, str]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=columns, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def markdown_table(rows: list[dict[str, str]], columns: list[str], limit: int = 20) -> str:
    if not rows:
        return "No rows found."
    clipped = rows[:limit]
    lines = [
        "| " + " | ".join(columns) + " |",
        "| " + " | ".join("---" for _ in columns) + " |",
    ]
    for row in clipped:
        values = [str(row.get(column, "")).replace("|", "\\|").replace("\n", " ") for column in columns]
        lines.append("| " + " | ".join(values) + " |")
    if len(rows) > limit:
        lines.append(f"\nShowing {limit} of {len(rows)} rows.")
    return "\n".join(lines)


def service_coverage(summary_rows: list[dict[str, str]]) -> list[dict[str, str]]:
    by_service: dict[str, dict[str, object]] = defaultdict(
        lambda: {
            "phase1_rows": 0,
            "phase3_rows": 0,
            "max_cpu_pct": math.nan,
            "max_mem_pct": math.nan,
            "quality": set(),
        }
    )
    for row in summary_rows:
        service = row.get("service", "")
        if not service:
            continue
        item = by_service[service]
        phase = row.get("phase", "")
        if phase == "phase1":
            item["phase1_rows"] = int(item["phase1_rows"]) + 1
        if phase == "phase3":
            item["phase3_rows"] = int(item["phase3_rows"]) + 1
        cpu = to_float(row.get("cpu_pct"))
        mem = to_float(row.get("mem_pct"))
        if math.isfinite(cpu):
            current = item["max_cpu_pct"]
            item["max_cpu_pct"] = cpu if not math.isfinite(current) else max(current, cpu)
        if math.isfinite(mem):
            current = item["max_mem_pct"]
            item["max_mem_pct"] = mem if not math.isfinite(current) else max(current, mem)
        quality = row.get("data_quality", "")
        if quality:
            item["quality"].add(quality)

    rows = []
    for service, item in sorted(by_service.items()):
        rows.append(
            {
                "service": service,
                "phase1_rows": str(item["phase1_rows"]),
                "phase3_rows": str(item["phase3_rows"]),
                "max_cpu_pct": fmt_number(item["max_cpu_pct"], 2),
                "max_mem_pct": fmt_number(item["max_mem_pct"], 2),
                "data_quality": ";".join(sorted(item["quality"]))[:180],
            }
        )
    return rows


def comparison_scenarios(summary_rows: list[dict[str, str]]) -> list[dict[str, str]]:
    seen = set()
    rows = []
    for row in summary_rows:
        if not is_comparison_row(row):
            continue
        key = (row.get("phase"), row.get("label"))
        if key in seen:
            continue
        seen.add(key)
        rows.append(
            {
                "phase": row.get("phase", ""),
                "target_service": row.get("target_service", ""),
                "users": row.get("users", ""),
                "requests": row.get("locust_request_count", ""),
                "fails": row.get("locust_failure_count", ""),
                "median_ms": row.get("locust_median_ms", ""),
                "avg_ms": row.get("locust_avg_latency_ms", ""),
                "p99_ms": row.get("locust_p99_ms", ""),
                "decision": row.get("decision", ""),
            }
        )
    return rows


def write_report(
    root: Path,
    summary_rows: list[dict[str, str]],
    paper: list[dict[str, str]],
    switches: list[dict[str, str]],
    out: Path,
) -> None:
    coverage = service_coverage(summary_rows)
    comparisons = comparison_scenarios(summary_rows)
    lines = [
        "# All-Microservices Controlled Stress Report",
        "",
        f"Result root: `{root}`",
        "",
        "This report is generated from testing-only artifacts. It compares VM-A IaaS-only and VM-B hybrid runs with the same calibrated load per target service, then summarizes repeated switching evidence for the four hybrid services.",
        "",
        "The runtime rule is unchanged: CPU above 30% moves active FaaS services to IaaS; sustained CPU at or below 30% moves active IaaS services back to FaaS. The 40% value is only the stress-evidence target used by the workload calibration.",
        "",
        "## Service Coverage",
        "",
        markdown_table(
            coverage,
            ["service", "phase1_rows", "phase3_rows", "max_cpu_pct", "max_mem_pct", "data_quality"],
        ),
        "",
        "## IaaS vs Hybrid Comparison Runs",
        "",
        markdown_table(
            comparisons,
            ["phase", "target_service", "users", "requests", "fails", "median_ms", "avg_ms", "p99_ms", "decision"],
            limit=30,
        ),
        "",
        "## Hybrid Switch Summary",
        "",
        markdown_table(switches, SWITCH_COLUMNS),
        "",
        "## Output Notes",
        "",
        "- `all_microservices_summary.csv` contains one row per scenario and measured microservice.",
        "- `all_microservices_paper_table.csv` keeps Locust request/failure/median/average latency beside Prometheus resource and backend metrics.",
        "- `all_microservices_switch_summary.csv` counts controller switch events from captured placement-controller logs.",
        "- Missing upstream service histograms are preserved as blank fields and marked through `data_quality` rather than inferred.",
        "",
    ]
    out.write_text("\n".join(lines), encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Generate all-microservices stress-test reports."
    )
    parser.add_argument(
        "--root",
        required=True,
        help="Suite result root, e.g. testing/results/all_microservices/<timestamp>",
    )
    parser.add_argument(
        "--out-dir",
        default=str(DEFAULT_RESULTS),
        help="Directory for generated analysis artifacts.",
    )
    args = parser.parse_args()

    root = Path(args.root).resolve()
    out_dir = Path(args.out_dir).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    status_rows = scenario_status(root)
    summary = merged_summary(root)
    paper = paper_rows(summary)
    switches = switch_summary(root, status_rows)

    summary_out = out_dir / "all_microservices_summary.csv"
    paper_out = out_dir / "all_microservices_paper_table.csv"
    switch_out = out_dir / "all_microservices_switch_summary.csv"
    report_out = out_dir / "all_microservices_report.md"

    write_csv(summary_out, SUMMARY_COLUMNS, summary)
    write_csv(paper_out, PAPER_COLUMNS, paper)
    write_csv(switch_out, SWITCH_COLUMNS, switches)
    write_report(root, summary, paper, switches, report_out)

    print(f"Saved {summary_out}")
    print(f"Saved {paper_out}")
    print(f"Saved {switch_out}")
    print(f"Saved {report_out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

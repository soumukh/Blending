#!/usr/bin/env python3
import argparse
import csv
import math
import re
from collections import defaultdict
from pathlib import Path

import pandas as pd


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_RESULTS = ROOT / "analysis" / "results"
SWITCH_RE = re.compile(r"\[(\w+)\] switching (IaaS|FaaS) -> (IaaS|FaaS)")


def to_float(value) -> float:
    try:
        numeric = float(value)
    except (TypeError, ValueError):
        return math.nan
    return numeric if math.isfinite(numeric) else math.nan


def fmt(value: float, digits: int = 2):
    if not math.isfinite(value):
        return ""
    return round(float(value), digits)


def aggregate_row(path: Path) -> dict:
    try:
        df = pd.read_csv(path)
    except Exception:
        return {}
    if "Name" not in df.columns:
        return {}
    rows = df[df["Name"] == "Aggregated"]
    if rows.empty:
        return {}
    return rows.iloc[0].to_dict()


def phase_from_path(path: Path) -> str:
    parts = set(path.parts)
    if "phase1" in parts:
        return "phase1"
    if "phase3" in parts:
        return "phase3"
    return "unknown"


def label_from_stats(path: Path) -> str:
    name = path.name
    if name.endswith("_stats.csv"):
        return name[: -len("_stats.csv")]
    return path.stem


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8").strip()
    except Exception:
        return ""


def health_code_for(prefix: Path) -> str:
    health = prefix.with_name(prefix.name + "_health.txt")
    text = read_text(health)
    match = re.search(r"(\d{3})", text)
    return match.group(1) if match else text


def metrics_quality(prefix: Path) -> str:
    metrics = prefix.with_name(prefix.name + "_metrics.csv")
    if not metrics.exists():
        return "missing_metrics_csv"
    try:
        df = pd.read_csv(metrics)
    except Exception:
        return "unreadable_metrics_csv"
    if "data_quality" not in df.columns:
        return "legacy_metrics_schema"
    values = sorted(set(str(value) for value in df["data_quality"].fillna("")))
    missing = [value for value in values if value and value != "complete"]
    if not missing:
        return "complete"
    return ";".join(missing[:4])


def stats_summary_row(root: Path, stats: Path) -> dict:
    aggregate = aggregate_row(stats)
    prefix = stats.with_name(label_from_stats(stats))
    requests = to_float(aggregate.get("Request Count", ""))
    failures = to_float(aggregate.get("Failure Count", ""))
    failure_pct = math.nan
    if math.isfinite(requests) and requests > 0 and math.isfinite(failures):
        failure_pct = failures / requests * 100
    return {
        "phase": phase_from_path(stats),
        "scenario": label_from_stats(stats),
        "placement_mode": "",
        "decision": "completed" if aggregate else "missing_aggregate",
        "request_count": int(requests) if math.isfinite(requests) else "",
        "failure_count": int(failures) if math.isfinite(failures) else "",
        "failure_pct": fmt(failure_pct, 3),
        "median_ms": fmt(to_float(aggregate.get("Median Response Time", "")), 1),
        "avg_ms": fmt(to_float(aggregate.get("Average Response Time", "")), 2),
        "p95_ms": fmt(to_float(aggregate.get("95%", "")), 1),
        "p99_ms": fmt(to_float(aggregate.get("99%", "")), 1),
        "req_per_sec": fmt(to_float(aggregate.get("Requests/s", "")), 2),
        "health_code": health_code_for(prefix),
        "metrics_quality": metrics_quality(prefix),
        "stats_file": str(stats.relative_to(ROOT)),
    }


def scenario_summary_from_status(root: Path, status_path: Path) -> pd.DataFrame:
    status = pd.read_csv(status_path)
    rows = []
    for _, item in status.iterrows():
        phase = str(item.get("phase", ""))
        label = str(item.get("label", ""))
        stats = root / phase / f"{label}_stats.csv"
        row = stats_summary_row(root, stats) if stats.exists() else {}
        row.update(
            {
                "phase": phase,
                "scenario": label,
                "placement_mode": str(item.get("placement_mode", "")),
                "decision": str(item.get("decision", "")),
                "health_code": str(item.get("health_code", "")),
                "stats_file": str(stats.relative_to(ROOT)) if stats.exists() else "",
            }
        )
        if not row.get("request_count"):
            row["request_count"] = item.get("request_count", "")
        if not row.get("failure_count"):
            row["failure_count"] = item.get("failure_count", "")
        if not row.get("failure_pct"):
            row["failure_pct"] = item.get("failure_pct", "")
        if not row.get("p99_ms"):
            row["p99_ms"] = item.get("p99_ms", "")
        rows.append(row)
    return pd.DataFrame(rows)


def scenario_summary(root: Path) -> pd.DataFrame:
    status_path = root / "scenario_status.csv"
    if status_path.exists():
        return scenario_summary_from_status(root, status_path)

    rows = []
    for stats in sorted(root.glob("phase*/**/*_stats.csv")):
        if stats.name.endswith("_stats_history.csv"):
            continue
        rows.append(stats_summary_row(root, stats))
    return pd.DataFrame(rows)


def switch_summary(root: Path) -> pd.DataFrame:
    counters = defaultdict(lambda: {"iaas_to_faas": 0, "faas_to_iaas": 0})
    for log_path in sorted(root.glob("phase3/**/*controller*.log")):
        for line in read_text(log_path).splitlines():
            match = SWITCH_RE.search(line)
            if not match:
                continue
            service, source, target = match.groups()
            counters[service][f"{source.lower()}_to_{target.lower()}"] += 1

    rows = []
    for service, values in sorted(counters.items()):
        rows.append(
            {
                "service": service,
                "iaas_to_faas": values["iaas_to_faas"],
                "faas_to_iaas": values["faas_to_iaas"],
            }
        )
    return pd.DataFrame(rows, columns=["service", "iaas_to_faas", "faas_to_iaas"])


def markdown_table(df: pd.DataFrame) -> str:
    columns = [str(column) for column in df.columns]
    rows = []
    for _, row in df.iterrows():
        rows.append([str(row[column]) for column in df.columns])

    def clean(value: str) -> str:
        return value.replace("|", "\\|").replace("\n", " ")

    lines = [
        "| " + " | ".join(clean(column) for column in columns) + " |",
        "| " + " | ".join("---" for _ in columns) + " |",
    ]
    for row in rows:
        lines.append("| " + " | ".join(clean(value) for value in row) + " |")
    return "\n".join(lines)


def append_table(lines: list[str], title: str, df: pd.DataFrame):
    lines.append(f"## {title}")
    if df.empty:
        lines.append("")
        lines.append("No rows found.")
        lines.append("")
        return
    lines.append("")
    lines.append(markdown_table(df))
    lines.append("")


def write_report(root: Path, scenarios: pd.DataFrame, switches: pd.DataFrame, out: Path):
    lines = [
        "# Full System Load Simulation Report",
        "",
        f"Result root: `{root}`",
        "",
        "This report summarizes the comprehensive controlled-stress suite across VM-A IaaS-only and VM-B hybrid deployment paths.",
        "",
    ]
    append_table(lines, "Scenario Summary", scenarios)
    append_table(lines, "Hybrid Switch Summary", switches)

    lines.extend(
        [
            "## Notes",
            "",
            "- Locust aggregate rows are authoritative for frontend request counts, failures, median latency, and average latency.",
            "- Prometheus CSVs provide per-service CPU, memory, backend, bridge, OpenFaaS, and controller metrics where available.",
            "- Missing request-level service metrics are expected for upstream images that do not expose Prometheus histograms.",
            "",
        ]
    )
    out.write_text("\n".join(lines), encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Generate full-system report artifacts for the comprehensive suite."
    )
    parser.add_argument(
        "--root",
        required=True,
        help="Suite result root, e.g. testing/results/comprehensive/<timestamp>",
    )
    parser.add_argument(
        "--out-dir",
        default=str(DEFAULT_RESULTS),
        help="Directory for final analysis artifacts.",
    )
    args = parser.parse_args()

    root = Path(args.root).resolve()
    out_dir = Path(args.out_dir).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    scenarios = scenario_summary(root)
    switches = switch_summary(root)

    scenario_out = out_dir / "full_system_scenario_summary.csv"
    switch_out = out_dir / "full_system_switch_summary.csv"
    report_out = out_dir / "full_system_report.md"

    scenarios.to_csv(scenario_out, index=False)
    switches.to_csv(switch_out, index=False)
    write_report(root, scenarios, switches, report_out)

    print(f"Saved {scenario_out}")
    print(f"Saved {switch_out}")
    print(f"Saved {report_out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

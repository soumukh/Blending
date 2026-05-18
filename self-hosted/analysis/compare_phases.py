#!/usr/bin/env python3
import math
import re
from collections import defaultdict
from pathlib import Path

import matplotlib.pyplot as plt
import pandas as pd

from generate_paper_tables import DEFAULT_OUT as PAPER_TABLE
from generate_paper_tables import build_rows as build_paper_rows
from generate_paper_tables import OUTPUT_COLUMNS as PAPER_COLUMNS


ROOT = Path(__file__).resolve().parents[1]
RESULTS = ROOT / "analysis" / "results"
PHASE1 = ROOT / "testing" / "results" / "phase1"
PHASE3 = ROOT / "testing" / "results" / "phase3"
SERVICES = [
    "frontend",
    "productcatalogservice",
    "cartservice",
    "checkoutservice",
    "currencyservice",
    "emailservice",
    "paymentservice",
    "shippingservice",
    "adservice",
    "recommendationservice",
    "redis-cart",
]
MIGRATED = ["emailservice", "currencyservice", "adservice", "shippingservice"]


def pick_row(df: pd.DataFrame, service: str) -> pd.Series:
    rows = df[df.service == service]
    if rows.empty:
        raise RuntimeError(f"missing metrics row for {service}")
    return rows.iloc[0]


def pct_change(before: float, after: float) -> float:
    if not math.isfinite(before) or before == 0 or not math.isfinite(after):
        return math.nan
    return (before - after) / before * 100


def fmt(value: float, digits: int = 1):
    if not math.isfinite(value):
        return math.nan
    return round(float(value), digits)


def to_float(value) -> float:
    try:
        numeric = float(value)
    except (TypeError, ValueError):
        return math.nan
    return numeric if math.isfinite(numeric) else math.nan


def value(row: pd.Series, column: str) -> float:
    if column not in row:
        return math.nan
    return to_float(row[column])


def text(row: pd.Series, column: str) -> str:
    if column not in row:
        return ""
    raw = row[column]
    if pd.isna(raw):
        return ""
    return str(raw)


def load_switches() -> dict:
    switches = defaultdict(lambda: {"iaas_to_faas": 0, "faas_to_iaas": 0})
    log_path = PHASE3 / "placement_controller.log"
    if not log_path.exists():
        return switches

    pattern = re.compile(r"\[(\w+)\] switching (IaaS|FaaS) -> (IaaS|FaaS)")
    with log_path.open(encoding="utf-8") as handle:
        for line in handle:
            match = pattern.search(line)
            if not match:
                continue
            service, source, target = match.groups()
            switches[service][f"{source.lower()}_to_{target.lower()}"] += 1
    return switches


def locust_summary(path: Path, phase: int, load_pattern: str, deployment: str) -> dict:
    df = pd.read_csv(path)
    rows = df[df["Name"] == "Aggregated"]
    if rows.empty:
        raise RuntimeError(f"missing aggregated Locust row in {path}")
    row = rows.iloc[0]
    requests = to_float(row["Request Count"])
    failures = to_float(row["Failure Count"])
    failure_pct = math.nan
    if math.isfinite(requests) and requests > 0 and math.isfinite(failures):
        failure_pct = failures / requests * 100

    return {
        "phase": phase,
        "load_pattern": load_pattern,
        "deployment": deployment,
        "request_count": int(requests) if math.isfinite(requests) else math.nan,
        "failure_count": int(failures) if math.isfinite(failures) else math.nan,
        "failure_pct": fmt(failure_pct, 3),
        "median_ms": fmt(row["Median Response Time"]),
        "avg_ms": fmt(row["Average Response Time"]),
        "p95_ms": fmt(row["95%"]),
        "p99_ms": fmt(row["99%"]),
        "req_per_sec": fmt(row["Requests/s"], 2),
    }


def main() -> int:
    RESULTS.mkdir(parents=True, exist_ok=True)

    p1 = pd.read_csv(PHASE1 / "phase1_linear_metrics.csv")
    p3 = pd.read_csv(PHASE3 / "phase3_linear_metrics.csv")
    switches = load_switches()

    rows = []
    for service in SERVICES:
        r1 = pick_row(p1, service)
        r3 = pick_row(p3, service)
        rows.append(
            {
                "service": service,
                "iaas_p99_ms": fmt(value(r1, "p99_ms")),
                "hybrid_p99_ms": fmt(value(r3, "p99_ms")),
                "p99_improvement_pct": fmt(
                    pct_change(value(r1, "p99_ms"), value(r3, "p99_ms"))
                ),
                "iaas_cpu_pct": fmt(value(r1, "cpu_pct")),
                "hybrid_cpu_pct": fmt(value(r3, "cpu_pct")),
                "iaas_mem_pct": fmt(value(r1, "mem_pct")),
                "hybrid_mem_pct": fmt(value(r3, "mem_pct")),
                "iaas_request_count": fmt(value(r1, "request_count")),
                "hybrid_request_count": fmt(value(r3, "request_count")),
                "iaas_error_pct": fmt(value(r1, "error_pct"), 3),
                "hybrid_error_pct": fmt(value(r3, "error_pct"), 3),
                "hybrid_deployment": text(r3, "deployment"),
                "hybrid_backend": text(r3, "backend"),
                "data_quality": text(r3, "data_quality"),
                "iaas_to_faas": switches[service]["iaas_to_faas"],
                "faas_to_iaas": switches[service]["faas_to_iaas"],
            }
        )

    comparison = pd.DataFrame(rows)
    comparison.to_csv(RESULTS / "comparison_table.csv", index=False, na_rep="")

    load_summary = pd.DataFrame(
        [
            locust_summary(PHASE1 / "phase1_linear_stats.csv", 1, "linear", "IaaS only"),
            locust_summary(PHASE1 / "phase1_bursty_stats.csv", 1, "bursty", "IaaS only"),
            locust_summary(PHASE3 / "phase3_linear_stats.csv", 3, "linear", "Hybrid"),
            locust_summary(PHASE3 / "phase3_bursty_stats.csv", 3, "bursty", "Hybrid"),
        ]
    )
    load_summary.to_csv(RESULTS / "load_summary.csv", index=False, na_rep="")

    paper_table = pd.DataFrame(build_paper_rows(), columns=PAPER_COLUMNS)
    paper_table.to_csv(PAPER_TABLE, index=False)

    print("Service metrics:")
    print(comparison.fillna("").to_string(index=False))
    print("\nEnd-to-end Locust summary:")
    print(load_summary.fillna("").to_string(index=False))
    print("\nPaper-style Table I:")
    print(paper_table.to_string(index=False))

    patterns = ["linear", "bursty"]
    iaas_p99 = [
        load_summary[
            (load_summary.load_pattern == pattern)
            & (load_summary.deployment == "IaaS only")
        ].iloc[0]["p99_ms"]
        for pattern in patterns
    ]
    hybrid_p99 = [
        load_summary[
            (load_summary.load_pattern == pattern)
            & (load_summary.deployment == "Hybrid")
        ].iloc[0]["p99_ms"]
        for pattern in patterns
    ]

    x = range(len(patterns))
    fig, ax = plt.subplots(figsize=(10, 5))
    ax.bar([i - 0.2 for i in x], iaas_p99, width=0.4, label="IaaS only")
    ax.bar([i + 0.2 for i in x], hybrid_p99, width=0.4, label="Hybrid")
    ax.set_xticks(list(x))
    ax.set_xticklabels(patterns)
    ax.set_ylabel("end-to-end p99 latency (ms)")
    ax.set_title("IaaS-only vs Hybrid End-to-End p99 Latency")
    ax.legend()
    fig.tight_layout()
    fig.savefig(RESULTS / "latency_comparison.png", dpi=150)

    print(f"Saved {RESULTS / 'comparison_table.csv'}")
    print(f"Saved {RESULTS / 'load_summary.csv'}")
    print(f"Saved {PAPER_TABLE}")
    print(f"Saved {RESULTS / 'latency_comparison.png'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

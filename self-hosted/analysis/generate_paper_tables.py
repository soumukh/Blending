#!/usr/bin/env python3
import argparse
import csv
import math
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUT = ROOT / "analysis" / "results" / "paper_table_i.csv"

RUNS = [
    {
        "application": "GoB",
        "deployment": "IaaS only",
        "load": "Linear",
        "stats": ROOT / "testing" / "results" / "phase1" / "phase1_linear_stats.csv",
    },
    {
        "application": "GoB",
        "deployment": "IaaS only",
        "load": "Bursty",
        "stats": ROOT / "testing" / "results" / "phase1" / "phase1_bursty_stats.csv",
    },
    {
        "application": "GoB",
        "deployment": "Hybrid",
        "load": "Linear",
        "stats": ROOT / "testing" / "results" / "phase3" / "phase3_linear_stats.csv",
    },
    {
        "application": "GoB",
        "deployment": "Hybrid",
        "load": "Bursty",
        "stats": ROOT / "testing" / "results" / "phase3" / "phase3_bursty_stats.csv",
    },
]

OUTPUT_COLUMNS = [
    "Application",
    "Deployment",
    "Load",
    "# Requests",
    "# Fails",
    "Median latency (ms)",
    "Average latency (ms)",
]


def to_number(value: str) -> float:
    try:
        numeric = float(value)
    except (TypeError, ValueError):
        return math.nan
    return numeric if math.isfinite(numeric) else math.nan


def format_int(value: float) -> str:
    if not math.isfinite(value):
        return ""
    return str(int(round(value)))


def format_float(value: float) -> str:
    if not math.isfinite(value):
        return ""
    return f"{value:.2f}"


def aggregate_row(path: Path) -> dict:
    with path.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        for row in reader:
            if row.get("Name") == "Aggregated":
                return row
    raise RuntimeError(f"missing Aggregated row in {path}")


def build_rows() -> list[dict[str, str]]:
    rows = []
    for run in RUNS:
        locust = aggregate_row(run["stats"])
        rows.append(
            {
                "Application": run["application"],
                "Deployment": run["deployment"],
                "Load": run["load"],
                "# Requests": format_int(to_number(locust.get("Request Count", ""))),
                "# Fails": format_int(to_number(locust.get("Failure Count", ""))),
                "Median latency (ms)": format_int(
                    to_number(locust.get("Median Response Time", ""))
                ),
                "Average latency (ms)": format_float(
                    to_number(locust.get("Average Response Time", ""))
                ),
            }
        )
    return rows


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Generate a Table I-style load-test summary from Locust CSVs."
    )
    parser.add_argument(
        "--out",
        default=str(DEFAULT_OUT),
        help="Output CSV path. Defaults to analysis/results/paper_table_i.csv.",
    )
    args = parser.parse_args()

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    rows = build_rows()

    with out.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=OUTPUT_COLUMNS)
        writer.writeheader()
        writer.writerows(rows)

    print(f"Wrote {len(rows)} rows to {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

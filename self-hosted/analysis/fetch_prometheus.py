#!/usr/bin/env python3
import argparse
import csv
import math
import os
import sys
from typing import Callable, Dict, Iterable

import requests


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

MIGRATED = {
    "currencyservice": "currency",
    "emailservice": "email",
    "shippingservice": "shipping",
    "adservice": "ad",
}

CSV_COLUMNS = [
    "phase",
    "load_pattern",
    "service",
    "deployment",
    "backend",
    "cpu_pct",
    "mem_pct",
    "request_count",
    "req_rate",
    "error_count",
    "error_pct",
    "p50_ms",
    "p95_ms",
    "p99_ms",
    "avg_latency_ms",
    "exec_grpc_ms",
    "faas_exec_p99_ms",
    "cold_start_count",
    "cold_start_p99_ms",
    "metric_source",
    "data_quality",
]

CORE_QUALITY_COLUMNS = [
    "cpu_pct",
    "mem_pct",
    "request_count",
    "error_count",
    "error_pct",
    "p50_ms",
    "p95_ms",
    "p99_ms",
    "avg_latency_ms",
]


def iaas_promql(service: str) -> Dict[str, str]:
    pod_match = f'{service}.*'
    container_filter = (
        f'namespace="default",pod=~"{pod_match}",container!="",container!="POD",image!=""'
    )
    request_filter = f'namespace="default",pod=~"{pod_match}"'

    return {
        "cpu_pct": (
            "100 * avg_over_time(("
            f"sum(rate(container_cpu_usage_seconds_total{{{container_filter}}}[1m])) "
            "/ "
            f"sum(kube_pod_container_resource_limits{{{request_filter},resource=\"cpu\"}})"
            ")[10m:30s])"
        ),
        "mem_pct": (
            "100 * sum(avg_over_time("
            f"container_memory_working_set_bytes{{{container_filter}}}[10m:30s])) "
            "/ sum(avg_over_time("
            f"container_spec_memory_limit_bytes{{{container_filter}}}[10m:30s]))"
        ),
        "request_count": (
            f"sum(increase(http_requests_total{{{request_filter}}}[10m]))"
        ),
        "p99_ms": (
            "histogram_quantile(0.99, sum by (le) "
            f"(rate(http_request_duration_seconds_bucket{{{request_filter}}}[10m]))) * 1000"
        ),
        "p95_ms": (
            "histogram_quantile(0.95, sum by (le) "
            f"(rate(http_request_duration_seconds_bucket{{{request_filter}}}[10m]))) * 1000"
        ),
        "p50_ms": (
            "histogram_quantile(0.50, sum by (le) "
            f"(rate(http_request_duration_seconds_bucket{{{request_filter}}}[10m]))) * 1000"
        ),
        "avg_latency_ms": (
            "1000 * sum(rate("
            f"http_request_duration_seconds_sum{{{request_filter}}}[10m])) "
            "/ sum(rate("
            f"http_request_duration_seconds_count{{{request_filter}}}[10m]))"
        ),
        "req_rate": f"sum(rate(http_requests_total{{{request_filter}}}[1m]))",
        "error_count": (
            "sum(increase("
            f"http_requests_total{{{request_filter},status=~\"5..\"}}[10m]))"
        ),
        "error_pct": (
            "100 * sum(rate("
            f"http_requests_total{{{request_filter},status=~\"5..\"}}[10m])) "
            "/ sum(rate("
            f"http_requests_total{{{request_filter}}}[10m]))"
        ),
        "exec_grpc_ms": (
            "histogram_quantile(0.99, sum by (le) "
            f"(rate(grpc_server_handling_seconds_bucket{{{request_filter}}}[10m]))) * 1000"
        ),
        "faas_exec_p99_ms": "",
        "cold_start_count": "",
        "cold_start_p99_ms": "",
    }


def faas_promql(service: str, function: str) -> Dict[str, str]:
    pod_match = f"({function}-bridge|{function})-.*"
    namespace_filter = 'namespace=~"default|openfaas-fn"'
    container_filter = (
        f'{namespace_filter},pod=~"{pod_match}",container!="",container!="POD",image!=""'
    )
    resource_filter = f'{namespace_filter},pod=~"{pod_match}"'
    bridge_filter = f'service="{function}"'

    return {
        "cpu_pct": (
            "100 * avg_over_time(("
            f"sum(rate(container_cpu_usage_seconds_total{{{container_filter}}}[1m]))"
            ")[10m:30s]) / avg_over_time(("
            f"sum(kube_pod_container_resource_limits{{{resource_filter},resource=\"cpu\"}})"
            ")[10m:30s])"
        ),
        "mem_pct": (
            "100 * sum(avg_over_time("
            f"container_memory_working_set_bytes{{{container_filter}}}[10m:30s])) "
            "/ sum(avg_over_time("
            f"container_spec_memory_limit_bytes{{{container_filter}}}[10m:30s]))"
        ),
        "request_count": (
            f"sum(increase(bridge_invocations_total{{{bridge_filter}}}[10m]))"
        ),
        "p99_ms": (
            "histogram_quantile(0.99, sum by (le) "
            f"(rate(bridge_http_duration_seconds_bucket{{{bridge_filter}}}[10m]))) * 1000"
        ),
        "p95_ms": (
            "histogram_quantile(0.95, sum by (le) "
            f"(rate(bridge_http_duration_seconds_bucket{{{bridge_filter}}}[10m]))) * 1000"
        ),
        "p50_ms": (
            "histogram_quantile(0.50, sum by (le) "
            f"(rate(bridge_http_duration_seconds_bucket{{{bridge_filter}}}[10m]))) * 1000"
        ),
        "avg_latency_ms": (
            "1000 * sum(rate("
            f"bridge_http_duration_seconds_sum{{{bridge_filter}}}[10m])) "
            "/ sum(rate("
            f"bridge_http_duration_seconds_count{{{bridge_filter}}}[10m]))"
        ),
        "req_rate": f"sum(rate(bridge_invocations_total{{{bridge_filter}}}[1m]))",
        "error_count": (
            f"sum(increase(bridge_invocations_total{{{bridge_filter},status!=\"ok\"}}[10m]))"
        ),
        "error_pct": (
            "100 * sum(rate("
            f"bridge_invocations_total{{{bridge_filter},status!=\"ok\"}}[10m])) "
            "/ sum(rate("
            f"bridge_invocations_total{{{bridge_filter}}}[10m]))"
        ),
        "exec_grpc_ms": (
            "histogram_quantile(0.99, sum by (le) "
            f"(rate(bridge_translation_duration_seconds_bucket{{{bridge_filter}}}[10m]))) * 1000"
        ),
        "faas_exec_p99_ms": (
            "histogram_quantile(0.99, sum by (le) "
            f"(rate(gateway_functions_seconds_bucket{{function_name=\"{function}\"}}[10m]))) * 1000"
        ),
        "cold_start_count": (
            f"sum(increase(gateway_function_invocation_started{{function_name=\"{function}\"}}[10m]))"
        ),
        "cold_start_p99_ms": (
            "histogram_quantile(0.99, sum by (le) "
            f"(rate(gateway_function_cold_start_seconds_bucket{{function_name=\"{function}\"}}[10m]))) * 1000"
        ),
    }


def promql(service: str, phase: int) -> Dict[str, str]:
    if phase == 3 and service in MIGRATED:
        return faas_promql(service, MIGRATED[service])
    return iaas_promql(service)


def choose_hybrid_metric(values: Iterable[float]) -> float:
    finite_values = [value for value in values if math.isfinite(value)]
    if not finite_values:
        return math.nan
    return max(finite_values)


def sum_metric(values: Iterable[float]) -> float:
    finite_values = [value for value in values if math.isfinite(value)]
    if not finite_values:
        return math.nan
    return sum(finite_values)


def first_metric(values: Iterable[float]) -> float:
    for value in values:
        if math.isfinite(value):
            return value
    return math.nan


def metric_or(values: Iterable[float], chooser: Callable[[Iterable[float]], float]) -> float:
    return chooser(values)


def query_value(base_url: str, query: str, timeout: int, query_time: float | None) -> float:
    if not query:
        return math.nan

    params = {"query": query}
    if query_time is not None:
        params["time"] = str(query_time)

    response = requests.get(
        f"{base_url.rstrip('/')}/api/v1/query",
        params=params,
        timeout=timeout,
    )
    response.raise_for_status()
    payload = response.json()

    if payload.get("status") != "success":
        raise RuntimeError(payload.get("error", "Prometheus query failed"))

    result = payload.get("data", {}).get("result", [])
    if not result:
        return math.nan

    values = []
    for item in result:
        raw = item.get("value", [None, "NaN"])[1]
        try:
            value = float(raw)
        except (TypeError, ValueError):
            value = math.nan
        if math.isfinite(value):
            values.append(value)

    if not values:
        return math.nan

    return sum(values) / len(values)


def controller_backend(
    prom_url: str, service: str, timeout: int, query_time: float | None
) -> str:
    query = f'controller_service_placement{{service="{service}"}}'
    try:
        value = query_value(prom_url, query, timeout, query_time)
    except Exception as exc:
        print(
            f"warning: {service} controller backend query failed: {exc}",
            file=sys.stderr,
        )
        return "unknown"
    if not math.isfinite(value):
        return "unknown"
    return "iaas" if value >= 0.5 else "faas"


def query_map(
    prom_url: str,
    service: str,
    backend: str,
    queries: Dict[str, str],
    timeout: int,
    query_time: float | None,
) -> Dict[str, float]:
    values = {}
    for metric, query in queries.items():
        try:
            values[metric] = query_value(prom_url, query, timeout, query_time)
        except Exception as exc:
            print(
                f"warning: {service} {backend} {metric} query failed: {exc}",
                file=sys.stderr,
            )
            values[metric] = math.nan
    return values


def choose_dynamic_metric(
    metric: str, backend: str, iaas_values: Dict[str, float], faas_values: Dict[str, float]
) -> float:
    values = [iaas_values.get(metric, math.nan), faas_values.get(metric, math.nan)]
    if metric in {"request_count", "req_rate", "error_count"}:
        return metric_or(values, sum_metric)
    if metric == "error_pct":
        request_count = choose_dynamic_metric("request_count", backend, iaas_values, faas_values)
        error_count = choose_dynamic_metric("error_count", backend, iaas_values, faas_values)
        if math.isfinite(request_count) and request_count > 0 and math.isfinite(error_count):
            return error_count / request_count * 100
        return metric_or(values, choose_hybrid_metric)
    if metric in {"faas_exec_p99_ms", "cold_start_count", "cold_start_p99_ms"}:
        return first_metric([faas_values.get(metric, math.nan)])
    if backend == "iaas":
        return first_metric([iaas_values.get(metric, math.nan), faas_values.get(metric, math.nan)])
    if backend == "faas":
        return first_metric([faas_values.get(metric, math.nan), iaas_values.get(metric, math.nan)])
    return metric_or(values, choose_hybrid_metric)


def data_quality(row: Dict[str, object]) -> str:
    missing = [
        column
        for column in CORE_QUALITY_COLUMNS
        if isinstance(row.get(column), float) and not math.isfinite(row[column])
    ]
    if not missing:
        return "complete"
    return "missing:" + "|".join(missing)


def collect_rows(
    prom_url: str,
    phase: int,
    mode: str,
    services: Iterable[str],
    timeout: int,
    query_time: float | None,
) -> Iterable[Dict[str, object]]:
    for service in services:
        dynamic = phase == 3 and service in MIGRATED
        row: Dict[str, object] = {
            "phase": phase,
            "load_pattern": mode,
            "service": service,
            "deployment": "hybrid-dynamic" if dynamic else "iaas",
            "backend": "unknown" if dynamic else "iaas",
            "metric_source": "prometheus:kubernetes",
        }

        if dynamic:
            backend = controller_backend(prom_url, service, timeout, query_time)
            row["backend"] = backend
            row["metric_source"] = "prometheus:kubernetes|bridge|openfaas|controller"
            iaas_queries = iaas_promql(service)
            faas_queries = faas_promql(service, MIGRATED[service])
            iaas_values = query_map(prom_url, service, "iaas", iaas_queries, timeout, query_time)
            faas_values = query_map(prom_url, service, "faas", faas_queries, timeout, query_time)
            for metric in iaas_queries:
                row[metric] = choose_dynamic_metric(metric, backend, iaas_values, faas_values)

            row["data_quality"] = data_quality(row)
            yield row
            continue

        for metric, query in promql(service, phase).items():
            try:
                row[metric] = query_value(prom_url, query, timeout, query_time)
            except Exception as exc:
                print(
                    f"warning: {service} {metric} query failed: {exc}",
                    file=sys.stderr,
                )
                row[metric] = math.nan

        row["data_quality"] = data_quality(row)
        yield row


def format_value(value: object) -> object:
    if isinstance(value, float):
        if math.isnan(value):
            return ""
        return f"{value:.6f}"
    return value


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Fetch paper-style service metrics from Prometheus."
    )
    parser.add_argument("--prom", required=True, help="Prometheus base URL")
    parser.add_argument("--phase", required=True, type=int, help="Experiment phase")
    parser.add_argument("--mode", required=True, help="Load pattern name")
    parser.add_argument("--out", required=True, help="Output CSV path")
    parser.add_argument(
        "--timeout",
        default=15,
        type=int,
        help="HTTP timeout per Prometheus query in seconds",
    )
    parser.add_argument(
        "--time",
        type=float,
        default=None,
        help="Optional Unix timestamp for historical Prometheus instant queries.",
    )
    args = parser.parse_args()

    rows = list(
        collect_rows(args.prom, args.phase, args.mode, SERVICES, args.timeout, args.time)
    )

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=CSV_COLUMNS)
        writer.writeheader()
        for row in rows:
            writer.writerow({key: format_value(row.get(key, "")) for key in CSV_COLUMNS})

    print(f"Wrote {len(rows)} rows to {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

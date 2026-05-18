# Full System Load Simulation Report

Result root: `/Users/bhaveshrane/Developer/MTP1/AWS_OPENFAAS/openstack2/testing/results/comprehensive/compact30-20260503T152806Z`

This report summarizes the comprehensive controlled-stress suite across VM-A IaaS-only and VM-B hybrid deployment paths.

## Scenario Summary

| phase | scenario | placement_mode | decision | request_count | failure_count | failure_pct | median_ms | avg_ms | p95_ms | p99_ms | req_per_sec | health_code | metrics_quality | stats_file |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| phase1 | phase1_compact_warmup_100 | iaas | completed | 10079 | 0.0 | 0.0 | 400.0 | 549.54 | 1100.0 | 1700.0 | 83.68 | 200 | missing:mem_pct\|request_count\|error_count\|error_pct\|p50_ms\|p95_ms\|p99_ms\|avg_latency_ms | testing/results/comprehensive/compact30-20260503T152806Z/phase1/phase1_compact_warmup_100_stats.csv |
| phase1 | phase1_compact_steady_350 | iaas | completed | 39084 | 0.0 | 0.0 | 1500.0 | 1489.24 | 2300.0 | 2700.0 | 162.22 | 200 | missing:mem_pct\|request_count\|error_count\|error_pct\|p50_ms\|p95_ms\|p99_ms\|avg_latency_ms | testing/results/comprehensive/compact30-20260503T152806Z/phase1/phase1_compact_steady_350_stats.csv |
| phase1 | phase1_compact_spike_700 | iaas | completed | 42193 | 0.0 | 0.0 | 1800.0 | 2205.67 | 4700.0 | 5500.0 | 140.42 | 200 | missing:mem_pct\|request_count\|error_count\|error_pct\|p50_ms\|p95_ms\|p99_ms\|avg_latency_ms | testing/results/comprehensive/compact30-20260503T152806Z/phase1/phase1_compact_spike_700_stats.csv |
| phase3 | phase3_compact_faas_low_80 | force_faas_dynamic | completed | 12512 | 210.0 | 1.678 | 540.0 | 697.77 | 1700.0 | 2200.0 | 59.53 | 200 | missing:mem_pct\|error_count\|error_pct;missing:mem_pct\|request_count\|error_count\|error_pct\|p50_ms\|p95_ms\|p99_ms\|avg_latency_ms | testing/results/comprehensive/compact30-20260503T152806Z/phase3/phase3_compact_faas_low_80_stats.csv |
| phase3 | phase3_compact_iaas_steady_350 | force_iaas | completed | 11008 | 0.0 | 0.0 | 5200.0 | 6845.05 | 15000.0 | 19000.0 | 45.74 | 200 | missing:mem_pct\|error_count\|error_pct;missing:mem_pct\|request_count\|error_count\|error_pct\|p50_ms\|p95_ms\|p99_ms\|avg_latency_ms | testing/results/comprehensive/compact30-20260503T152806Z/phase3/phase3_compact_iaas_steady_350_stats.csv |
| phase3 | phase3_compact_dynamic_ramp_700 | force_faas_dynamic | completed | 66080 | 123.0 | 0.186 | 2200.0 | 2418.69 | 4400.0 | 5300.0 | 137.65 | 200 | missing:mem_pct;missing:mem_pct\|error_count\|error_pct;missing:mem_pct\|request_count\|error_count\|error_pct\|p50_ms\|p95_ms\|p99_ms\|avg_latency_ms | testing/results/comprehensive/compact30-20260503T152806Z/phase3/phase3_compact_dynamic_ramp_700_stats.csv |
| phase3 | phase3_compact_recovery_50 | controller_running | completed | 9500 | 62.0 | 0.653 | 540.0 | 607.84 | 1200.0 | 1500.0 | 39.52 | 200 | missing:mem_pct;missing:mem_pct\|error_count\|error_pct;missing:mem_pct\|request_count\|error_count\|error_pct\|p50_ms\|p95_ms\|p99_ms\|avg_latency_ms | testing/results/comprehensive/compact30-20260503T152806Z/phase3/phase3_compact_recovery_50_stats.csv |

## Hybrid Switch Summary

| service | iaas_to_faas | faas_to_iaas |
| --- | --- | --- |
| currencyservice | 1 | 4 |
| shippingservice | 2 | 2 |

## Notes

- Locust aggregate rows are authoritative for frontend request counts, failures, median latency, and average latency.
- Prometheus CSVs provide per-service CPU, memory, backend, bridge, OpenFaaS, and controller metrics where available.
- Missing request-level service metrics are expected for upstream images that do not expose Prometheus histograms.

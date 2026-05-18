# All-Microservices Controlled Stress Report

Result root: `/Users/bhaveshrane/Developer/MTP1/AWS_OPENFAAS/openstack2/testing/results/all_microservices/allmicro-20260504T132028Z`

This report is generated from testing-only artifacts. It compares VM-A IaaS-only and VM-B hybrid runs with the same calibrated load per target service, then summarizes repeated switching evidence for the four hybrid services.

The runtime rule is unchanged: CPU above 30% moves active FaaS services to IaaS; sustained CPU at or below 30% moves active IaaS services back to FaaS. The 40% value is only the stress-evidence target used by the workload calibration.

## Service Coverage

| service | phase1_rows | phase3_rows | max_cpu_pct | max_mem_pct | data_quality |
| --- | --- | --- | --- | --- | --- |
| adservice | 11 | 61 | 39.74 |  | missing:mem_pct;missing:mem_pct\|error_count\|error_pct;missing:mem_pct\|request_count\|error_count\|error_pct\|p50_ms\|p95_ms\|p99_ms\|avg_latency_ms |
| cartservice | 11 | 61 | 6.02 |  | missing:mem_pct\|request_count\|error_count\|error_pct\|p50_ms\|p95_ms\|p99_ms\|avg_latency_ms |
| checkoutservice | 11 | 61 | 20.43 |  | missing:mem_pct\|request_count\|error_count\|error_pct\|p50_ms\|p95_ms\|p99_ms\|avg_latency_ms |
| currencyservice | 11 | 61 | 69.57 |  | missing:mem_pct;missing:mem_pct\|error_count\|error_pct;missing:mem_pct\|request_count\|error_count\|error_pct\|p50_ms\|p95_ms\|p99_ms\|avg_latency_ms |
| emailservice | 11 | 61 | 17.84 |  | missing:mem_pct;missing:mem_pct\|error_count\|error_pct;missing:mem_pct\|request_count\|error_count\|error_pct\|p50_ms\|p95_ms\|p99_ms\|avg_latency_ms |
| frontend | 11 | 61 | 70.69 |  | missing:mem_pct\|request_count\|error_count\|error_pct\|p50_ms\|p95_ms\|p99_ms\|avg_latency_ms |
| paymentservice | 11 | 61 | 11.11 |  | missing:mem_pct\|request_count\|error_count\|error_pct\|p50_ms\|p95_ms\|p99_ms\|avg_latency_ms |
| productcatalogservice | 11 | 61 | 30.23 |  | missing:mem_pct\|request_count\|error_count\|error_pct\|p50_ms\|p95_ms\|p99_ms\|avg_latency_ms |
| recommendationservice | 11 | 61 | 46.25 |  | missing:mem_pct\|request_count\|error_count\|error_pct\|p50_ms\|p95_ms\|p99_ms\|avg_latency_ms |
| redis-cart | 11 | 61 | 6.46 |  | missing:mem_pct\|request_count\|error_count\|error_pct\|p50_ms\|p95_ms\|p99_ms\|avg_latency_ms |
| shippingservice | 11 | 61 | 27.10 |  | missing:mem_pct;missing:mem_pct\|error_count\|error_pct;missing:mem_pct\|request_count\|error_count\|error_pct\|p50_ms\|p95_ms\|p99_ms\|avg_latency_ms |

## IaaS vs Hybrid Comparison Runs

| phase | target_service | users | requests | fails | median_ms | avg_ms | p99_ms | decision |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| phase1 | frontend | 100 | 36800 | 0 | 550.00 | 586.22 | 1700.00 | completed |
| phase3 | frontend | 100 | 29448 | 261 | 560.00 | 789.75 | 4000.00 | completed |
| phase1 | productcatalogservice | 200 | 56997 | 0 | 790.00 | 823.60 | 1500.00 | completed |
| phase3 | productcatalogservice | 200 | 44984 | 507 | 840.00 | 1101.85 | 6200.00 | completed |
| phase1 | cartservice | 350 | 41774 | 0 | 2600.00 | 2348.40 | 4200.00 | completed |
| phase3 | cartservice | 350 | 34162 | 635 | 2900.00 | 2903.95 | 13000.00 | completed |
| phase1 | checkoutservice | 200 | 50777 | 0 | 860.00 | 1092.29 | 2300.00 | completed |
| phase3 | checkoutservice | 200 | 43180 | 196 | 1100.00 | 1298.89 | 3700.00 | completed |
| phase1 | currencyservice | 50 | 17258 | 0 | 680.00 | 675.51 | 1500.00 | completed |
| phase3 | currencyservice | 50 | 15641 | 96 | 610.00 | 766.96 | 2400.00 | completed |
| phase1 | paymentservice | 200 | 55482 | 0 | 780.00 | 992.32 | 2600.00 | completed |
| phase3 | paymentservice | 200 | 25443 | 127 | 1400.00 | 2264.69 | 16000.00 | completed |
| phase1 | shippingservice | 50 | 29144 | 0 | 310.00 | 430.77 | 1300.00 | completed |
| phase3 | shippingservice | 50 | 25941 | 129 | 390.00 | 493.40 | 1400.00 | completed |
| phase1 | adservice | 100 | 47653 | 0 | 380.00 | 401.71 | 1100.00 | completed |
| phase3 | adservice | 100 | 36792 | 256 | 440.00 | 587.61 | 2900.00 | completed |
| phase1 | recommendationservice | 100 | 47475 | 0 | 380.00 | 404.15 | 1100.00 | completed |
| phase3 | recommendationservice | 100 | 35733 | 259 | 460.00 | 611.62 | 3000.00 | completed |
| phase1 | redis-cart | 100 | 34588 | 0 | 730.00 | 727.54 | 1300.00 | completed |
| phase3 | redis-cart | 100 | 25897 | 281 | 940.00 | 1016.20 | 3600.00 | completed |
| phase1 | emailservice | 50 | 29426 | 0 | 320.00 | 425.72 | 1200.00 | completed |
| phase3 | emailservice | 50 | 25629 | 356 | 400.00 | 501.21 | 1500.00 | completed |

## Hybrid Switch Summary

| service | faas_to_iaas | iaas_to_faas | high_windows | recovery_windows | logs_with_events | data_quality |
| --- | --- | --- | --- | --- | --- | --- |
| adservice | 2 | 8 | 2 | 2 | 16 | switches_seen |
| currencyservice | 14 | 19 | 2 | 2 | 14 | switches_seen |
| emailservice | 0 | 6 | 2 | 2 | 12 | switches_seen |
| shippingservice | 4 | 10 | 2 | 2 | 16 | switches_seen |

## Output Notes

- `all_microservices_summary.csv` contains one row per scenario and measured microservice.
- `all_microservices_paper_table.csv` keeps Locust request/failure/median/average latency beside Prometheus resource and backend metrics.
- `all_microservices_switch_summary.csv` counts controller switch events from captured placement-controller logs.
- Missing upstream service histograms are preserved as blank fields and marked through `data_quality` rather than inferred.

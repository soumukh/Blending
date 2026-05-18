#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

VM_A_IP="${1:-}"
if [ -z "$VM_A_IP" ]; then
  VM_A_IP="$(cd ../iaas/terraform && terraform output -raw vm_a_public_ip)"
fi

FRONTEND="http://${VM_A_IP}:30080"
PROMETHEUS="http://${VM_A_IP}:9090"
RESULTS="${SCRIPT_DIR}/results/phase1"
LOCUST_BIN="${LOCUST_BIN:-locust}"

mkdir -p "$RESULTS"

if ! command -v "$LOCUST_BIN" >/dev/null 2>&1; then
  echo "locust is not installed. Run: pip install -r testing/requirements.txt" >&2
  exit 1
fi

echo "Targeting Online Boutique: ${FRONTEND}"
echo "Prometheus endpoint: ${PROMETHEUS}"
echo "Results directory: ${RESULTS}"
echo "For live monitoring, run: locust -f locustfile_linear.py --host ${FRONTEND}"

run_locust() {
  local label="$1"
  shift

  set +e
  "$LOCUST_BIN" "$@"
  local status=$?
  set -e

  if [ "$status" -ne 0 ]; then
    echo "WARNING: ${label} exited with status ${status}; continuing so reports and metrics are still collected." >&2
  fi
}

run_locust "phase1 linear" \
  -f locustfile_linear.py --host "$FRONTEND" \
  --headless -u 200 -r 10 --run-time 25m \
  --csv "${RESULTS}/phase1_linear" \
  --csv-full-history \
  --html "${RESULTS}/phase1_linear.html" \
  --only-summary

python3 ../analysis/fetch_prometheus.py \
  --prom "$PROMETHEUS" \
  --phase 1 \
  --mode linear \
  --out "${RESULTS}/phase1_linear_metrics.csv"

run_locust "phase1 bursty" \
  -f locustfile_bursty.py --host "$FRONTEND" \
  --headless -u 200 -r 100 --run-time 25m \
  --csv "${RESULTS}/phase1_bursty" \
  --csv-full-history \
  --html "${RESULTS}/phase1_bursty.html" \
  --only-summary

python3 ../analysis/fetch_prometheus.py \
  --prom "$PROMETHEUS" \
  --phase 1 \
  --mode bursty \
  --out "${RESULTS}/phase1_bursty_metrics.csv"

echo "Phase 1 complete."
echo "Linear report: ${RESULTS}/phase1_linear.html"
echo "Bursty report: ${RESULTS}/phase1_bursty.html"

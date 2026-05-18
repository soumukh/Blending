#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$SCRIPT_DIR"

VM_B_IP="${1:-}"
if [ -z "$VM_B_IP" ]; then
  VM_B_IP="$(cd ../hybrid/terraform && terraform output -raw vm_b_public_ip)"
fi

FRONTEND="http://${VM_B_IP}:30080"
PROMETHEUS="http://${VM_B_IP}:9090"
RESULTS="${SCRIPT_DIR}/results/phase3"
LOCUST_BIN="${LOCUST_BIN:-locust}"
SSH_KEY="${ROOT_DIR}/iaas.pem"
RUN_LINEAR="${RUN_LINEAR:-1}"
RUN_BURSTY="${RUN_BURSTY:-1}"

mkdir -p "$RESULTS"

if ! command -v "$LOCUST_BIN" >/dev/null 2>&1; then
  echo "locust is not installed. Run: pip install -r testing/requirements.txt" >&2
  exit 1
fi

echo "Targeting Hybrid Online Boutique: ${FRONTEND}"
echo "Prometheus endpoint: ${PROMETHEUS}"
echo "Results directory: ${RESULTS}"
echo "For live controller logs, run: ssh -i ${SSH_KEY} ubuntu@${VM_B_IP} 'kubectl logs deployment/placement-controller -f'"

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

if [ "$RUN_LINEAR" = "1" ]; then
  run_locust "phase3 linear" \
    -f locustfile_linear.py --host "$FRONTEND" \
    --headless -u 200 -r 10 --run-time 25m \
    --csv "${RESULTS}/phase3_linear" \
    --csv-full-history \
    --html "${RESULTS}/phase3_linear.html" \
    --only-summary

  python3 ../analysis/fetch_prometheus.py \
    --prom "$PROMETHEUS" \
    --phase 3 \
    --mode linear \
    --out "${RESULTS}/phase3_linear_metrics.csv"
else
  echo "Skipping Phase 3 linear run because RUN_LINEAR=${RUN_LINEAR}."
fi

if [ "$RUN_BURSTY" = "1" ]; then
  run_locust "phase3 bursty" \
    -f locustfile_bursty.py --host "$FRONTEND" \
    --headless -u 200 -r 100 --run-time 25m \
    --csv "${RESULTS}/phase3_bursty" \
    --csv-full-history \
    --html "${RESULTS}/phase3_bursty.html" \
    --only-summary

  python3 ../analysis/fetch_prometheus.py \
    --prom "$PROMETHEUS" \
    --phase 3 \
    --mode bursty \
    --out "${RESULTS}/phase3_bursty_metrics.csv"
else
  echo "Skipping Phase 3 bursty run because RUN_BURSTY=${RUN_BURSTY}."
fi

ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "$SSH_KEY" "ubuntu@${VM_B_IP}" \
  'kubectl logs deployment/placement-controller --tail=500' \
  > "${RESULTS}/placement_controller.log" || true

echo "Phase 3 complete."
echo "Linear report: ${RESULTS}/phase3_linear.html"
echo "Bursty report: ${RESULTS}/phase3_bursty.html"

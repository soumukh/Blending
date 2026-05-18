#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$SCRIPT_DIR"

VM_A_IP="${1:-}"
VM_B_IP="${2:-}"

if [ -z "$VM_A_IP" ]; then
  VM_A_IP="$(cd ../iaas/terraform && terraform output -raw vm_a_public_ip)"
fi
if [ -z "$VM_B_IP" ]; then
  VM_B_IP="$(cd ../hybrid/terraform && terraform output -raw vm_b_public_ip)"
fi

SUITE_PROFILE="${SUITE_PROFILE:-full}"
DRY_RUN="${DRY_RUN:-0}"
LOCUST_BIN="${LOCUST_BIN:-locust}"
SSH_KEY="${ROOT_DIR}/iaas.pem"
MAX_FAILURE_PCT="${MAX_FAILURE_PCT:-5}"
MAX_P99_MS="${MAX_P99_MS:-20000}"
TIMESTAMP="${SUITE_TIMESTAMP:-$(date -u +%Y%m%dT%H%M%SZ)}"
RESULT_ROOT="${SCRIPT_DIR}/results/comprehensive/${TIMESTAMP}"
PHASE1_DIR="${RESULT_ROOT}/phase1"
PHASE3_DIR="${RESULT_ROOT}/phase3"
SUMMARY_CSV="${RESULT_ROOT}/scenario_status.csv"

VM_A_FRONTEND="http://${VM_A_IP}:30080"
VM_A_PROM="http://${VM_A_IP}:9090"
VM_B_FRONTEND="http://${VM_B_IP}:30080"
VM_B_PROM="http://${VM_B_IP}:9090"
VM_B_OPENFAAS="http://${VM_B_IP}:8080"

mkdir -p "$PHASE1_DIR" "$PHASE3_DIR"

if [ "$DRY_RUN" != "1" ] && ! command -v "$LOCUST_BIN" >/dev/null 2>&1; then
  echo "locust is not installed. Run: pip install -r testing/requirements.txt" >&2
  exit 1
fi

if [ ! -f "$SUMMARY_CSV" ]; then
  echo "phase,label,scenario,placement_mode,locust_exit,health_code,metrics_exit,request_count,failure_count,failure_pct,p99_ms,decision" > "$SUMMARY_CSV"
fi

log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

run_or_echo() {
  if [ "$DRY_RUN" = "1" ]; then
    printf 'DRY_RUN:'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

ssh_cmd() {
  local command="$1"
  if [ "$DRY_RUN" = "1" ]; then
    echo "DRY_RUN: ssh -i ${SSH_KEY} ubuntu@${VM_B_IP} ${command}"
    return 0
  fi
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "$SSH_KEY" "ubuntu@${VM_B_IP}" "$command"
}

managed_function() {
  case "$1" in
    currencyservice) echo "currency" ;;
    emailservice) echo "email" ;;
    shippingservice) echo "shipping" ;;
    adservice) echo "ad" ;;
    *) echo "unknown" ;;
  esac
}

managed_bridge() {
  printf '%s-bridge\n' "$(managed_function "$1")"
}

require_url() {
  local name="$1"
  local url="$2"
  if [ "$DRY_RUN" = "1" ]; then
    echo "DRY_RUN: require ${name} ${url}"
    return 0
  fi
  local code
  code="$(curl --max-time 10 -s -o /dev/null -w '%{http_code}' "$url" || true)"
  if [ "$code" != "200" ]; then
    echo "ERROR: ${name} check failed at ${url}; http_code=${code}" >&2
    exit 1
  fi
}

health_code() {
  local url="$1"
  if [ "$DRY_RUN" = "1" ]; then
    echo "200"
    return 0
  fi
  curl --max-time 10 -s -o /dev/null -w '%{http_code}' "$url" || true
}

pause_controller() {
  log "Pausing VM-B placement controller"
  ssh_cmd "kubectl -n default scale deployment/placement-controller --replicas=0"
}

resume_controller() {
  log "Starting VM-B placement controller"
  ssh_cmd "kubectl -n default scale deployment/placement-controller --replicas=1 && kubectl -n default rollout status deployment/placement-controller --timeout=180s"
}

force_service_iaas() {
  local service="$1"
  local fn bridge
  fn="$(managed_function "$service")"
  bridge="$(managed_bridge "$service")"
  log "Forcing ${service} to IaaS"
  ssh_cmd "kubectl -n default scale deployment/${service} --replicas=1 && kubectl -n default rollout status deployment/${service} --timeout=180s"
  ssh_cmd "kubectl -n default patch service ${service} --type=merge -p '{\"spec\":{\"selector\":{\"mtp.service\":\"${service}\",\"mtp.backend\":\"iaas\"}}}'"
  ssh_cmd "kubectl -n default scale deployment/${bridge} --replicas=0"
  ssh_cmd "kubectl -n openfaas-fn scale deployment/${fn} --replicas=0"
}

force_service_faas() {
  local service="$1"
  local fn bridge
  fn="$(managed_function "$service")"
  bridge="$(managed_bridge "$service")"
  log "Forcing ${service} to FaaS"
  ssh_cmd "kubectl -n openfaas-fn scale deployment/${fn} --replicas=1 && kubectl -n openfaas-fn rollout status deployment/${fn} --timeout=180s"
  ssh_cmd "kubectl -n default scale deployment/${bridge} --replicas=1 && kubectl -n default rollout status deployment/${bridge} --timeout=180s"
  ssh_cmd "kubectl -n default patch service ${service} --type=merge -p '{\"spec\":{\"selector\":{\"mtp.service\":\"${service}\",\"mtp.backend\":\"faas\"}}}'"
  ssh_cmd "kubectl -n default scale deployment/${service} --replicas=0"
}

force_all_iaas() {
  pause_controller
  for service in currencyservice emailservice shippingservice adservice; do
    force_service_iaas "$service"
  done
}

force_all_faas() {
  pause_controller
  for service in currencyservice emailservice shippingservice adservice; do
    force_service_faas "$service"
  done
}

capture_placement() {
  local out_dir="$1"
  local label="$2"
  local target="${out_dir}/${label}_placement.txt"
  if [ "$DRY_RUN" = "1" ]; then
    echo "DRY_RUN placement capture for ${label}" > "$target"
    return 0
  fi
  ssh_cmd "kubectl -n default get deploy currencyservice emailservice shippingservice adservice currency-bridge email-bridge shipping-bridge ad-bridge -o custom-columns=NAME:.metadata.name,READY:.status.readyReplicas,DESIRED:.spec.replicas --no-headers; echo '--- services'; kubectl -n default get svc currencyservice emailservice shippingservice adservice -o json" > "$target" || true
}

capture_controller_log() {
  local out_dir="$1"
  local label="$2"
  local target="${out_dir}/${label}_controller.log"
  if [ "$DRY_RUN" = "1" ]; then
    echo "DRY_RUN controller log for ${label}" > "$target"
    return 0
  fi
  ssh_cmd "kubectl -n default logs deployment/placement-controller --tail=500" > "$target" || true
}

faas_smoke() {
  local target="${PHASE3_DIR}/openfaas_smoke.csv"
  echo "function,http_code" > "$target"
  for fn in email currency shipping ad; do
    if [ "$DRY_RUN" = "1" ]; then
      echo "${fn},DRY_RUN" >> "$target"
      echo "DRY_RUN: curl ${VM_B_OPENFAAS}/function/${fn}"
    else
      local code
      code="$(curl --max-time 15 -s -o /dev/null -w '%{http_code}' "${VM_B_OPENFAAS}/function/${fn}" || true)"
      echo "${fn},${code}" >> "$target"
      if [ "$code" != "200" ]; then
        echo "ERROR: OpenFaaS smoke check failed for ${fn}; http_code=${code}" >&2
        exit 1
      fi
    fi
  done
}

stats_values() {
  local stats_file="$1"
  if [ "$DRY_RUN" = "1" ] || [ ! -f "$stats_file" ]; then
    echo ",,,"
    return 0
  fi
  python3 - "$stats_file" <<'PY'
import csv
import math
import sys

stats = sys.argv[1]
row = None
with open(stats, newline="", encoding="utf-8") as handle:
    for item in csv.DictReader(handle):
        if item.get("Name") == "Aggregated":
            row = item
            break
if row is None:
    print(",,,")
    raise SystemExit(0)

def number(value):
    try:
        parsed = float(value)
    except (TypeError, ValueError):
        return math.nan
    return parsed if math.isfinite(parsed) else math.nan

requests = number(row.get("Request Count"))
failures = number(row.get("Failure Count"))
failure_pct = math.nan
if requests > 0 and math.isfinite(failures):
    failure_pct = failures / requests * 100
p99 = number(row.get("99%"))

def fmt(value):
    if not math.isfinite(value):
        return ""
    return f"{value:.6f}"

print(",".join([fmt(requests), fmt(failures), fmt(failure_pct), fmt(p99)]))
PY
}

threshold_exceeded() {
  local failure_pct="$1"
  local p99_ms="$2"
  local health="$3"
  python3 - "$failure_pct" "$p99_ms" "$health" "$MAX_FAILURE_PCT" "$MAX_P99_MS" <<'PY'
import math
import sys

failure_pct, p99_ms, health, max_failure, max_p99 = sys.argv[1:]

def number(value):
    try:
        parsed = float(value)
    except (TypeError, ValueError):
        return math.nan
    return parsed if math.isfinite(parsed) else math.nan

bad = False
if health != "200":
    bad = True
if number(failure_pct) > float(max_failure):
    bad = True
if number(p99_ms) > float(max_p99):
    bad = True
print("1" if bad else "0")
PY
}

append_summary() {
  local phase="$1"
  local label="$2"
  local scenario="$3"
  local placement="$4"
  local locust_exit="$5"
  local health="$6"
  local metrics_exit="$7"
  local stats="$8"
  local decision="$9"
  echo "${phase},${label},${scenario},${placement},${locust_exit},${health},${metrics_exit},${stats},${decision}" >> "$SUMMARY_CSV"
}

collect_metrics() {
  local prom="$1"
  local phase_id="$2"
  local mode="$3"
  local out="$4"
  require_url "Prometheus" "${prom}/-/ready"
  if [ "$DRY_RUN" = "1" ]; then
    echo "DRY_RUN metrics for ${mode}" > "$out"
    return 0
  fi
  local query_time
  query_time="$(date +%s)"
  python3 ../analysis/fetch_prometheus.py \
    --prom "$prom" \
    --phase "$phase_id" \
    --mode "$mode" \
    --time "$query_time" \
    --out "$out"
}

run_scenario() {
  local phase="$1"
  local out_dir="$2"
  local host="$3"
  local prom="$4"
  local phase_id="$5"
  local label="$6"
  local scenario="$7"
  local placement="$8"

  local prefix="${out_dir}/${label}"
  local locust_exit="0"
  local metrics_exit="0"
  local health
  local stats
  local exceeded

  log "Running ${phase} ${label} with SCENARIO=${scenario}"

  if [ "$DRY_RUN" = "1" ]; then
    echo "DRY_RUN locust ${label}" > "${prefix}_stats.csv"
  else
    set +e
    SCENARIO="$scenario" SUITE_PROFILE="$SUITE_PROFILE" "$LOCUST_BIN" \
      -f locustfile_comprehensive.py \
      --host "$host" \
      --headless \
      -u 1 \
      -r 1 \
      --csv "$prefix" \
      --csv-full-history \
      --html "${prefix}.html" \
      --only-summary
    locust_exit=$?
    set -e
    if [ "$locust_exit" -ne 0 ]; then
      log "WARNING: ${label} exited with status ${locust_exit}; preserving artifacts and continuing policy checks"
    fi
  fi

  health="$(health_code "$host")"
  echo "$health" > "${prefix}_health.txt"

  set +e
  collect_metrics "$prom" "$phase_id" "$label" "${prefix}_metrics.csv"
  metrics_exit=$?
  set -e

  stats="$(stats_values "${prefix}_stats.csv")"
  exceeded="$(threshold_exceeded "$(echo "$stats" | cut -d, -f3)" "$(echo "$stats" | cut -d, -f4)" "$health")"
  if [ "$exceeded" = "1" ]; then
    append_summary "$phase" "$label" "$scenario" "$placement" "$locust_exit" "$health" "$metrics_exit" "$stats" "threshold_exceeded"
    return 2
  fi

  append_summary "$phase" "$label" "$scenario" "$placement" "$locust_exit" "$health" "$metrics_exit" "$stats" "completed"
  return 0
}

skip_scenario() {
  local phase="$1"
  local label="$2"
  local scenario="$3"
  local placement="$4"
  local reason="$5"
  log "Skipping ${phase} ${label}: ${reason}"
  append_summary "$phase" "$label" "$scenario" "$placement" "" "" "" ",,," "skipped:${reason}"
}

is_heavy() {
  case "$1" in
    stress_ramp_500|spike_500|soak_250|steady_200) return 0 ;;
    *) return 1 ;;
  esac
}

run_phase1() {
  local skip_heavy="0"
  require_url "VM-A frontend" "$VM_A_FRONTEND"
  require_url "VM-A Prometheus" "${VM_A_PROM}/-/ready"

  for scenario in warmup_50 steady_200 stress_ramp_500 spike_500 soak_250 recovery_25; do
    local label="phase1_${scenario}"
    if [ "$skip_heavy" = "1" ] && is_heavy "$scenario"; then
      skip_scenario "phase1" "$label" "$scenario" "iaas" "previous_threshold_exceeded"
      continue
    fi
    set +e
    run_scenario "phase1" "$PHASE1_DIR" "$VM_A_FRONTEND" "$VM_A_PROM" "1" "$label" "$scenario" "iaas"
    local status=$?
    set -e
    if [ "$status" = "2" ]; then
      skip_heavy="1"
    fi
  done
}

prepare_phase3_placement() {
  local label="$1"
  local placement="$2"

  case "$placement" in
    dynamic)
      resume_controller
      ;;
    force_iaas)
      force_all_iaas
      ;;
    force_faas_dynamic)
      force_all_faas
      resume_controller
      ;;
    controller_running)
      resume_controller
      ;;
    *)
      echo "ERROR: unknown placement mode ${placement} for ${label}" >&2
      exit 1
      ;;
  esac
}

run_phase3_scenario() {
  local label="$1"
  local scenario="$2"
  local placement="$3"

  capture_placement "$PHASE3_DIR" "${label}_before"
  prepare_phase3_placement "$label" "$placement"
  capture_placement "$PHASE3_DIR" "${label}_after_prepare"

  set +e
  run_scenario "phase3" "$PHASE3_DIR" "$VM_B_FRONTEND" "$VM_B_PROM" "3" "$label" "$scenario" "$placement"
  local status=$?
  set -e

  capture_placement "$PHASE3_DIR" "${label}_after"
  capture_controller_log "$PHASE3_DIR" "$label"
  return "$status"
}

run_phase3() {
  local skip_heavy="0"
  require_url "VM-B frontend" "$VM_B_FRONTEND"
  require_url "VM-B Prometheus" "${VM_B_PROM}/-/ready"
  resume_controller
  faas_smoke

  run_phase3_scenario "phase3_warmup_50" "warmup_50" "controller_running" || true
  run_phase3_scenario "phase3_iaas_backend_steady_200" "steady_200" "force_iaas" || true
  run_phase3_scenario "phase3_faas_low_recovery_25" "recovery_25" "force_faas_dynamic" || true

  for item in \
    "phase3_dynamic_stress_ramp_500:stress_ramp_500:force_faas_dynamic" \
    "phase3_dynamic_spike_500:spike_500:force_faas_dynamic" \
    "phase3_recovery_25:recovery_25:controller_running" \
    "phase3_soak_250:soak_250:controller_running"; do
    local label scenario placement
    label="$(echo "$item" | cut -d: -f1)"
    scenario="$(echo "$item" | cut -d: -f2)"
    placement="$(echo "$item" | cut -d: -f3)"

    if [ "$skip_heavy" = "1" ] && is_heavy "$scenario"; then
      skip_scenario "phase3" "$label" "$scenario" "$placement" "previous_threshold_exceeded"
      continue
    fi

    set +e
    run_phase3_scenario "$label" "$scenario" "$placement"
    local status=$?
    set -e
    if [ "$status" = "2" ]; then
      skip_heavy="1"
    fi
  done
}

run_phase1_compact30() {
  local skip_heavy="0"
  require_url "VM-A frontend" "$VM_A_FRONTEND"
  require_url "VM-A Prometheus" "${VM_A_PROM}/-/ready"

  for item in \
    "phase1_compact_warmup_100:compact_warmup_100" \
    "phase1_compact_steady_350:compact_steady_350" \
    "phase1_compact_spike_700:compact_spike_700"; do
    local label scenario
    label="$(echo "$item" | cut -d: -f1)"
    scenario="$(echo "$item" | cut -d: -f2)"

    if [ "$skip_heavy" = "1" ]; then
      skip_scenario "phase1" "$label" "$scenario" "iaas" "previous_threshold_exceeded"
      continue
    fi

    set +e
    run_scenario "phase1" "$PHASE1_DIR" "$VM_A_FRONTEND" "$VM_A_PROM" "1" "$label" "$scenario" "iaas"
    local status=$?
    set -e
    if [ "$status" = "2" ]; then
      skip_heavy="1"
    fi
  done
}

run_phase3_compact30() {
  local skip_heavy="0"
  require_url "VM-B frontend" "$VM_B_FRONTEND"
  require_url "VM-B Prometheus" "${VM_B_PROM}/-/ready"
  resume_controller
  faas_smoke

  run_phase3_scenario "phase3_compact_faas_low_80" "compact_faas_low_80" "force_faas_dynamic" || true

  set +e
  run_phase3_scenario "phase3_compact_iaas_steady_350" "compact_steady_350" "force_iaas"
  local status=$?
  set -e
  if [ "$status" = "2" ]; then
    skip_heavy="1"
  fi

  if [ "$skip_heavy" = "1" ]; then
    skip_scenario "phase3" "phase3_compact_dynamic_ramp_700" "compact_dynamic_ramp_700" "force_faas_dynamic" "previous_threshold_exceeded"
  else
    set +e
    run_phase3_scenario "phase3_compact_dynamic_ramp_700" "compact_dynamic_ramp_700" "force_faas_dynamic"
    status=$?
    set -e
    if [ "$status" = "2" ]; then
      skip_heavy="1"
    fi
  fi

  run_phase3_scenario "phase3_compact_recovery_50" "compact_recovery_50" "controller_running" || true
}

run_compact30() {
  run_phase1_compact30
  run_phase3_compact30
}

main() {
  log "Comprehensive suite profile=${SUITE_PROFILE} dry_run=${DRY_RUN}"
  log "Results: ${RESULT_ROOT}"
  log "VM-A: ${VM_A_FRONTEND}"
  log "VM-B: ${VM_B_FRONTEND}"

  if [ "$SUITE_PROFILE" = "compact30" ]; then
    run_compact30
  else
    run_phase1
    run_phase3
  fi

  run_or_echo python3 ../analysis/generate_full_system_report.py --root "$RESULT_ROOT"

  log "Comprehensive suite complete."
  log "Scenario status: ${SUMMARY_CSV}"
  log "Report: ${ROOT_DIR}/analysis/results/full_system_report.md"
}

main "$@"

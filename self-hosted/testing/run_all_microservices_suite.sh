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

DRY_RUN="${DRY_RUN:-0}"
LOCUST_BIN="${LOCUST_BIN:-locust}"
SSH_KEY="${ROOT_DIR}/iaas.pem"
TIMESTAMP="${SUITE_TIMESTAMP:-$(date -u +%Y%m%dT%H%M%SZ)}"
RESULT_ROOT="${SCRIPT_DIR}/results/all_microservices/${TIMESTAMP}"
PHASE1_DIR="${RESULT_ROOT}/phase1"
PHASE3_DIR="${RESULT_ROOT}/phase3"
SUMMARY_CSV="${RESULT_ROOT}/scenario_status.csv"

VM_A_FRONTEND="http://${VM_A_IP}:30080"
VM_A_PROM="http://${VM_A_IP}:9090"
VM_B_FRONTEND="http://${VM_B_IP}:30080"
VM_B_PROM="http://${VM_B_IP}:9090"
VM_B_OPENFAAS="http://${VM_B_IP}:8080"

SERVICES="${SERVICES:-frontend productcatalogservice cartservice checkoutservice currencyservice emailservice paymentservice shippingservice adservice recommendationservice redis-cart}"
HYBRID_SERVICES="currencyservice emailservice shippingservice adservice"
LOAD_LEVELS="${LOAD_LEVELS:-50 100 200 350 500 700 900}"
CPU_TARGET_PCT="${CPU_TARGET_PCT:-40}"
MAX_FAILURE_PCT="${MAX_FAILURE_PCT:-5}"
MAX_P99_MS="${MAX_P99_MS:-20000}"
CALIBRATION_DURATION_SECONDS="${CALIBRATION_DURATION_SECONDS:-180}"
COMPARISON_DURATION_SECONDS="${COMPARISON_DURATION_SECONDS:-300}"
HYBRID_HIGH_SECONDS="${HYBRID_HIGH_SECONDS:-300}"
HYBRID_LOW_SECONDS="${HYBRID_LOW_SECONDS:-360}"
RECOVERY_USERS="${RECOVERY_USERS:-10}"
SWITCH_CYCLES="${SWITCH_CYCLES:-2}"
MIN_WAIT_SECONDS="${MIN_WAIT_SECONDS:-0.05}"
MAX_WAIT_SECONDS="${MAX_WAIT_SECONDS:-0.4}"

mkdir -p "$PHASE1_DIR" "$PHASE3_DIR"

if [ "$DRY_RUN" != "1" ] && ! command -v "$LOCUST_BIN" >/dev/null 2>&1; then
  echo "locust is not installed. Run: pip install -r testing/requirements.txt" >&2
  exit 1
fi

if [ ! -f "$SUMMARY_CSV" ]; then
  echo "phase,label,target_service,workload,placement_mode,users,duration_seconds,locust_exit,health_code,metrics_exit,request_count,failure_count,failure_pct,p99_ms,target_cpu_pct,decision" > "$SUMMARY_CSV"
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

ssh_host() {
  local host="$1"
  local command="$2"
  if [ "$DRY_RUN" = "1" ]; then
    echo "DRY_RUN: ssh -i ${SSH_KEY} ubuntu@${host} ${command}"
    return 0
  fi
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "$SSH_KEY" "ubuntu@${host}" "$command"
}

ssh_vm_b() {
  ssh_host "$VM_B_IP" "$1"
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

is_hybrid_service() {
  case "$1" in
    currencyservice|emailservice|shippingservice|adservice) return 0 ;;
    *) return 1 ;;
  esac
}

workload_for_service() {
  case "$1" in
    frontend) echo "browse" ;;
    productcatalogservice|recommendationservice|adservice) echo "browse-product" ;;
    cartservice|redis-cart) echo "cart" ;;
    checkoutservice|paymentservice|emailservice|shippingservice) echo "checkout" ;;
    currencyservice) echo "currency" ;;
    *) echo "browse" ;;
  esac
}

health_code() {
  local url="$1"
  if [ "$DRY_RUN" = "1" ]; then
    echo "200"
    return 0
  fi
  curl --connect-timeout 3 --max-time 10 -s -o /dev/null -w '%{http_code}' "$url" || true
}

recover_host_if_needed() {
  local label="$1"
  local host="$2"
  local probe="$3"
  local code
  code="$(health_code "$probe")"
  if [ "$code" = "200" ]; then
    return 0
  fi

  log "${label} probe failed (${code}); attempting inner Nova VM recovery"
  ssh_host "$host" 'bash -s' <<'REMOTE'
set -euo pipefail
if sudo virsh list --all --name >/dev/null 2>&1; then
  dom="$(sudo virsh list --all --name | grep -m1 . || true)"
  if [ -n "$dom" ]; then
    state="$(sudo virsh domstate "$dom" || true)"
    echo "domain=${dom} state=${state}"
    if [ "$state" = "paused" ] || [ "$state" = "shut off" ]; then
      sudo virsh destroy "$dom" >/dev/null 2>&1 || true
      sleep 3
      sudo virsh start "$dom"
    fi
  fi
fi
REMOTE
}

wait_for_url() {
  local name="$1"
  local url="$2"
  local attempts="${3:-30}"
  local code
  for _ in $(seq 1 "$attempts"); do
    code="$(health_code "$url")"
    if [ "$code" = "200" ]; then
      return 0
    fi
    sleep 10
  done
  echo "ERROR: ${name} failed at ${url}; last_http_code=${code}" >&2
  return 1
}

preflight() {
  recover_host_if_needed "VM-A" "$VM_A_IP" "$VM_A_FRONTEND"
  recover_host_if_needed "VM-B" "$VM_B_IP" "$VM_B_FRONTEND"
  wait_for_url "VM-A frontend" "$VM_A_FRONTEND"
  wait_for_url "VM-A Prometheus" "${VM_A_PROM}/-/ready"
  wait_for_url "VM-B frontend" "$VM_B_FRONTEND"
  wait_for_url "VM-B Prometheus" "${VM_B_PROM}/-/ready"
  wait_for_url "VM-B OpenFaaS" "${VM_B_OPENFAAS}/healthz"
}

pause_controller() {
  log "Pausing VM-B placement controller"
  ssh_vm_b "kubectl -n default scale deployment/placement-controller --replicas=0"
}

resume_controller() {
  log "Starting VM-B placement controller"
  ssh_vm_b "kubectl -n default scale deployment/placement-controller --replicas=1 && kubectl -n default rollout status deployment/placement-controller --timeout=180s"
}

force_service_iaas() {
  local service="$1"
  local fn bridge
  fn="$(managed_function "$service")"
  bridge="$(managed_bridge "$service")"
  log "Forcing ${service} to IaaS"
  ssh_vm_b "kubectl -n default scale deployment/${service} --replicas=1 && kubectl -n default rollout status deployment/${service} --timeout=180s"
  ssh_vm_b "kubectl -n default patch service ${service} --type=merge -p '{\"spec\":{\"selector\":{\"mtp.service\":\"${service}\",\"mtp.backend\":\"iaas\"}}}'"
  ssh_vm_b "kubectl -n default scale deployment/${bridge} --replicas=0"
  ssh_vm_b "kubectl -n openfaas-fn scale deployment/${fn} --replicas=0"
}

force_service_faas() {
  local service="$1"
  local fn bridge
  fn="$(managed_function "$service")"
  bridge="$(managed_bridge "$service")"
  log "Forcing ${service} to FaaS"
  ssh_vm_b "kubectl -n openfaas-fn scale deployment/${fn} --replicas=1 && kubectl -n openfaas-fn rollout status deployment/${fn} --timeout=180s"
  ssh_vm_b "kubectl -n default scale deployment/${bridge} --replicas=1 && kubectl -n default rollout status deployment/${bridge} --timeout=180s"
  ssh_vm_b "kubectl -n default patch service ${service} --type=merge -p '{\"spec\":{\"selector\":{\"mtp.service\":\"${service}\",\"mtp.backend\":\"faas\"}}}'"
  ssh_vm_b "kubectl -n default scale deployment/${service} --replicas=0"
}

prepare_target_faas() {
  local target="$1"
  local candidate
  pause_controller
  for candidate in $HYBRID_SERVICES; do
    if [ "$candidate" = "$target" ]; then
      force_service_faas "$candidate"
    else
      force_service_iaas "$candidate"
    fi
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
  ssh_vm_b "kubectl -n default get deploy currencyservice emailservice shippingservice adservice currency-bridge email-bridge shipping-bridge ad-bridge -o custom-columns=NAME:.metadata.name,READY:.status.readyReplicas,DESIRED:.spec.replicas --no-headers; echo '--- services'; kubectl -n default get svc currencyservice emailservice shippingservice adservice -o json" > "$target" || true
}

capture_controller_log() {
  local out_dir="$1"
  local label="$2"
  local target="${out_dir}/${label}_controller.log"
  if [ "$DRY_RUN" = "1" ]; then
    echo "DRY_RUN controller log for ${label}" > "$target"
    return 0
  fi
  ssh_vm_b "kubectl -n default logs deployment/placement-controller --tail=800" > "$target" || true
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

row = None
with open(sys.argv[1], newline="", encoding="utf-8") as handle:
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

target_cpu_from_metrics() {
  local metrics_file="$1"
  local service="$2"
  if [ "$DRY_RUN" = "1" ] || [ ! -f "$metrics_file" ]; then
    echo ""
    return 0
  fi
  python3 - "$metrics_file" "$service" <<'PY'
import csv
import math
import sys

with open(sys.argv[1], newline="", encoding="utf-8") as handle:
    for row in csv.DictReader(handle):
        if row.get("service") != sys.argv[2]:
            continue
        try:
            value = float(row.get("cpu_pct", "nan"))
        except ValueError:
            value = math.nan
        print("" if not math.isfinite(value) else f"{value:.6f}")
        break
PY
}

faas_cpu_from_prom() {
  local prom="$1"
  local service="$2"
  local fn
  if [ "$DRY_RUN" = "1" ] || ! is_hybrid_service "$service"; then
    echo ""
    return 0
  fi
  fn="$(managed_function "$service")"
  python3 - "$prom" "$fn" <<'PY'
import json
import math
import sys
import urllib.parse
import urllib.request

prom = sys.argv[1].rstrip("/")
function = sys.argv[2]
pod_match = f"({function}-bridge|{function})-.*"
container_filter = (
    'namespace=~"default|openfaas-fn",'
    f'pod=~"{pod_match}",container!="",container!="POD",image!=""'
)
resource_filter = (
    'namespace=~"default|openfaas-fn",'
    f'pod=~"{pod_match}",resource="cpu"'
)
query = (
    "max_over_time((100 * "
    f"sum(rate(container_cpu_usage_seconds_total{{{container_filter}}}[1m])) "
    "/ "
    f"sum(kube_pod_container_resource_limits{{{resource_filter}}})"
    ")[10m:30s])"
)

try:
    params = urllib.parse.urlencode({"query": query})
    with urllib.request.urlopen(f"{prom}/api/v1/query?{params}", timeout=15) as response:
        payload = json.loads(response.read().decode("utf-8"))
    values = []
    for item in payload.get("data", {}).get("result", []):
        try:
            value = float(item.get("value", ["", "nan"])[1])
        except (TypeError, ValueError):
            value = math.nan
        if math.isfinite(value):
            values.append(value)
    print("" if not values else f"{max(values):.6f}")
except Exception as exc:
    print(f"warning: FaaS CPU evidence query failed: {exc}", file=sys.stderr)
    print("")
PY
}

target_cpu_evidence() {
  local metrics_file="$1"
  local prom="$2"
  local phase_id="$3"
  local service="$4"
  local metric_cpu faas_cpu
  metric_cpu="$(target_cpu_from_metrics "$metrics_file" "$service")"
  if [ "$phase_id" = "3" ] && is_hybrid_service "$service"; then
    faas_cpu="$(faas_cpu_from_prom "$prom" "$service")"
  else
    faas_cpu=""
  fi
  python3 - "$metric_cpu" "$faas_cpu" <<'PY'
import math
import sys

values = []
for item in sys.argv[1:]:
    try:
        value = float(item)
    except (TypeError, ValueError):
        value = math.nan
    if math.isfinite(value):
        values.append(value)
print("" if not values else f"{max(values):.6f}")
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

bad = health != "200"
bad = bad or number(failure_pct) > float(max_failure)
bad = bad or number(p99_ms) > float(max_p99)
print("1" if bad else "0")
PY
}

cpu_reached() {
  local cpu="$1"
  python3 - "$cpu" "$CPU_TARGET_PCT" <<'PY'
import math
import sys

try:
    cpu = float(sys.argv[1])
except (TypeError, ValueError):
    cpu = math.nan
print("1" if math.isfinite(cpu) and cpu >= float(sys.argv[2]) else "0")
PY
}

append_summary() {
  local phase="$1"
  local label="$2"
  local target_service="$3"
  local workload="$4"
  local placement="$5"
  local users="$6"
  local duration="$7"
  local locust_exit="$8"
  local health="$9"
  local metrics_exit="${10}"
  local stats="${11}"
  local target_cpu="${12}"
  local decision="${13}"
  echo "${phase},${label},${target_service},${workload},${placement},${users},${duration},${locust_exit},${health},${metrics_exit},${stats},${target_cpu},${decision}" >> "$SUMMARY_CSV"
}

collect_metrics() {
  local prom="$1"
  local phase_id="$2"
  local mode="$3"
  local out="$4"
  wait_for_url "Prometheus" "${prom}/-/ready" 6
  if [ "$DRY_RUN" = "1" ]; then
    local metric_service
    {
      echo "phase,load_pattern,service,deployment,backend,cpu_pct,mem_pct,request_count,req_rate,error_count,error_pct,p50_ms,p95_ms,p99_ms,avg_latency_ms,exec_grpc_ms,faas_exec_p99_ms,cold_start_count,cold_start_p99_ms,metric_source,data_quality"
      for metric_service in $SERVICES; do
        echo "${phase_id},${mode},${metric_service},dry-run,unknown,,,,,,,,,,,,,,,dry-run,dry_run"
      done
    } > "$out"
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

run_load() {
  local phase="$1"
  local out_dir="$2"
  local host="$3"
  local prom="$4"
  local phase_id="$5"
  local label="$6"
  local service="$7"
  local placement="$8"
  local users="$9"
  local duration="${10}"

  local workload prefix spawn_rate locust_exit health metrics_exit stats target_cpu exceeded decision
  workload="$(workload_for_service "$service")"
  prefix="${out_dir}/${label}"
  spawn_rate="$users"
  if [ "$spawn_rate" -gt 100 ]; then
    spawn_rate=100
  fi

  log "Running ${phase} ${label}: target=${service} workload=${workload} users=${users} duration=${duration}s placement=${placement}"
  if [ "$DRY_RUN" = "1" ]; then
    echo "DRY_RUN locust ${label}" > "${prefix}_stats.csv"
    locust_exit=0
  else
    set +e
    TARGET_SERVICE="$service" \
      MIN_WAIT_SECONDS="$MIN_WAIT_SECONDS" \
      MAX_WAIT_SECONDS="$MAX_WAIT_SECONDS" \
      "$LOCUST_BIN" \
      -f locustfile_all_microservices.py \
      --host "$host" \
      --headless \
      -u "$users" \
      -r "$spawn_rate" \
      --run-time "${duration}s" \
      --csv "$prefix" \
      --csv-full-history \
      --html "${prefix}.html" \
      --exit-code-on-error 0 \
      --only-summary
    locust_exit=$?
    set -e
    if [ "$locust_exit" -ne 0 ]; then
      log "WARNING: ${label} exited with status ${locust_exit}; preserving artifacts"
    fi
  fi

  health="$(health_code "$host")"
  echo "$health" > "${prefix}_health.txt"

  set +e
  collect_metrics "$prom" "$phase_id" "$label" "${prefix}_metrics.csv"
  metrics_exit=$?
  set -e

  stats="$(stats_values "${prefix}_stats.csv")"
  target_cpu="$(target_cpu_evidence "${prefix}_metrics.csv" "$prom" "$phase_id" "$service")"
  exceeded="$(threshold_exceeded "$(echo "$stats" | cut -d, -f3)" "$(echo "$stats" | cut -d, -f4)" "$health")"
  decision="completed"
  if [ "$locust_exit" -ne 0 ]; then
    decision="locust_failed"
    exceeded="1"
  elif [ "$metrics_exit" -ne 0 ]; then
    decision="metrics_failed"
    exceeded="1"
  elif [ "$exceeded" = "1" ]; then
    decision="threshold_exceeded"
  fi

  append_summary "$phase" "$label" "$service" "$workload" "$placement" "$users" "$duration" "$locust_exit" "$health" "$metrics_exit" "$stats" "$target_cpu" "$decision"

  LAST_CPU="$target_cpu"
  LAST_DECISION="$decision"
  if [ "$exceeded" = "1" ]; then
    set +e
    return 1
  fi
  return 0
}

calibrate_load() {
  local service="$1"
  local selected=""
  local best_safe=""
  local reached="0"
  local users

  log "Calibrating ${service} with CPU target ${CPU_TARGET_PCT}%"
  if is_hybrid_service "$service"; then
    prepare_target_faas "$service"
    resume_controller
  else
    resume_controller
  fi

  for users in $LOAD_LEVELS; do
    local label="calibration_${service}_${users}"
    set +e
    run_load "phase3" "$PHASE3_DIR" "$VM_B_FRONTEND" "$VM_B_PROM" "3" "$label" "$service" "calibration" "$users" "$CALIBRATION_DURATION_SECONDS"
    local status=$?
    set -e
    if [ "$status" -eq 0 ]; then
      best_safe="$users"
    fi
    reached="$(cpu_reached "$LAST_CPU")"
    if [ "$reached" = "1" ] && [ "$status" -eq 0 ]; then
      selected="$users"
      break
    fi
    if [ "$status" -ne 0 ]; then
      selected="${best_safe:-$users}"
      break
    fi
  done

  if [ -z "$selected" ]; then
    selected="${best_safe:-50}"
  fi
  CALIBRATED_USERS="$selected"
  log "Selected ${CALIBRATED_USERS} users for ${service}"
  return 0
}

run_same_load_comparison() {
  local service="$1"
  local users="$2"
  run_load "phase1" "$PHASE1_DIR" "$VM_A_FRONTEND" "$VM_A_PROM" "1" "phase1_${service}_${users}" "$service" "iaas-only" "$users" "$COMPARISON_DURATION_SECONDS" || true
  resume_controller
  run_load "phase3" "$PHASE3_DIR" "$VM_B_FRONTEND" "$VM_B_PROM" "3" "phase3_${service}_${users}" "$service" "hybrid" "$users" "$COMPARISON_DURATION_SECONDS" || true
}

run_hybrid_switch_cycles() {
  local service="$1"
  local users="$2"
  local cycle
  for cycle in $(seq 1 "$SWITCH_CYCLES"); do
    local high_label="switch_${service}_cycle${cycle}_high_${users}"
    local low_label="switch_${service}_cycle${cycle}_low_${RECOVERY_USERS}"
    prepare_target_faas "$service"
    capture_placement "$PHASE3_DIR" "${high_label}_before"
    resume_controller
    run_load "phase3" "$PHASE3_DIR" "$VM_B_FRONTEND" "$VM_B_PROM" "3" "$high_label" "$service" "target-faas-high" "$users" "$HYBRID_HIGH_SECONDS" || true
    capture_placement "$PHASE3_DIR" "${high_label}_after"
    capture_controller_log "$PHASE3_DIR" "$high_label"

    run_load "phase3" "$PHASE3_DIR" "$VM_B_FRONTEND" "$VM_B_PROM" "3" "$low_label" "$service" "controller-low-recovery" "$RECOVERY_USERS" "$HYBRID_LOW_SECONDS" || true
    capture_placement "$PHASE3_DIR" "${low_label}_after"
    capture_controller_log "$PHASE3_DIR" "$low_label"
  done
}

main() {
  local service
  log "All-microservices suite dry_run=${DRY_RUN}"
  log "Results: ${RESULT_ROOT}"
  log "VM-A: ${VM_A_FRONTEND}"
  log "VM-B: ${VM_B_FRONTEND}"

  preflight

  for service in $SERVICES; do
    calibrate_load "$service"
    run_same_load_comparison "$service" "$CALIBRATED_USERS"
    if is_hybrid_service "$service"; then
      run_hybrid_switch_cycles "$service" "$CALIBRATED_USERS"
    fi
  done

  run_or_echo python3 ../analysis/generate_all_microservices_report.py --root "$RESULT_ROOT"
  log "All-microservices suite complete."
  log "Scenario status: ${SUMMARY_CSV}"
  log "Report: ${ROOT_DIR}/analysis/results/all_microservices_report.md"
}

main "$@"

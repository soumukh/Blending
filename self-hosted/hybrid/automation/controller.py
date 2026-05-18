#!/usr/bin/env python3
import json
import logging
import math
import os
import subprocess
import time

import requests
from prometheus_client import Counter, Gauge, start_http_server


SERVICES = {
    "currencyservice": {
        "function": "currency",
        "bridge_deployment": "currency-bridge",
        "iaas_deployment": "currencyservice",
    },
    "emailservice": {
        "function": "email",
        "bridge_deployment": "email-bridge",
        "iaas_deployment": "emailservice",
    },
    "shippingservice": {
        "function": "shipping",
        "bridge_deployment": "shipping-bridge",
        "iaas_deployment": "shippingservice",
    },
    "adservice": {
        "function": "ad",
        "bridge_deployment": "ad-bridge",
        "iaas_deployment": "adservice",
    },
}

RESULTS_DIR = os.getenv("RESULTS_DIR", "/results")
PROMETHEUS_URLS = [
    url.strip().rstrip("/")
    for url in os.getenv(
        "PROMETHEUS_URLS",
        os.getenv(
            "PROMETHEUS_URL",
            "http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090,"
            "http://prometheus-operated.monitoring.svc.cluster.local:9090",
        ),
    ).split(",")
    if url.strip()
]
INTERVAL_SECONDS = int(os.getenv("INTERVAL_SECONDS", "30"))
CPU_THRESHOLD_PCT = float(os.getenv("CPU_THRESHOLD_PCT", "30"))
LOW_WINDOWS_TO_FAAS = int(os.getenv("LOW_WINDOWS_TO_FAAS", "3"))
HIGH_WINDOWS_TO_IAAS = int(os.getenv("HIGH_WINDOWS_TO_IAAS", "2"))
COOLDOWN_SECONDS = int(os.getenv("COOLDOWN_SECONDS", "120"))
CPU_RATE_WINDOW = os.getenv("CPU_RATE_WINDOW", "2m")

IAAS = "iaas"
FAAS = "faas"

os.makedirs(RESULTS_DIR, exist_ok=True)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    handlers=[
        logging.StreamHandler(),
        logging.FileHandler(os.path.join(RESULTS_DIR, "placement_decisions.log")),
    ],
)
log = logging.getLogger("placement-controller")

start_http_server(9092)
placement_state = Gauge("controller_service_placement", "1=IaaS 0=FaaS", ["service"])
active_cpu_pct = Gauge(
    "controller_active_backend_cpu_pct",
    "Active backend CPU as a percentage of configured CPU limit",
    ["service", "backend"],
)
low_windows_g = Gauge("controller_consecutive_low_windows", "Low CPU window count", ["service"])
high_windows_g = Gauge("controller_consecutive_high_windows", "High CPU window count", ["service"])
switches_total = Counter(
    "controller_placement_switches_total",
    "Total placement switches",
    ["service", "direction"],
)
blocked_total = Counter(
    "controller_switch_blocked_total",
    "Switches skipped because metrics or readiness were unavailable",
    ["service", "reason"],
)


def kubectl(*args, namespace="default"):
    cmd = ["kubectl", "-n", namespace] + list(args)
    result = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise RuntimeError(f"{' '.join(cmd)} failed: {result.stderr.strip()}")
    return result.stdout.strip()


def scale_deployment(name, replicas, namespace="default"):
    kubectl("scale", "deployment", name, f"--replicas={replicas}", namespace=namespace)


def wait_deployment(name, namespace="default", timeout="120s"):
    kubectl("rollout", "status", f"deployment/{name}", f"--timeout={timeout}", namespace=namespace)


def patch_service_backend(service, backend):
    patch = {"spec": {"selector": {"mtp.service": service, "mtp.backend": backend}}}
    kubectl("patch", "service", service, "--type=merge", "-p", json.dumps(patch))


def service_backend(service, cfg):
    raw = kubectl("get", "service", service, "-o", "json")
    selector = json.loads(raw).get("spec", {}).get("selector", {})
    backend = selector.get("mtp.backend")
    if backend in (IAAS, FAAS):
        return backend

    # Compatibility with older manifests that routed by app label.
    if selector.get("app") == cfg["bridge_deployment"]:
        return FAAS
    if selector.get("app") == cfg["iaas_deployment"]:
        return IAAS
    return None


def prom_scalar(query):
    last_error = None
    for base_url in PROMETHEUS_URLS:
        try:
            response = requests.get(
                f"{base_url}/api/v1/query",
                params={"query": query},
                timeout=5,
            )
            response.raise_for_status()
            payload = response.json()
            if payload.get("status") != "success":
                last_error = payload
                continue
            result = payload.get("data", {}).get("result", [])
            if not result:
                return None
            value = float(result[0]["value"][1])
            if not math.isfinite(value):
                return None
            return value
        except Exception as exc:
            last_error = exc
    log.debug("Prometheus query failed: %s query=%s", last_error, query)
    return None


def cpu_usage_query(namespace, pod_regex):
    return (
        "sum(rate(container_cpu_usage_seconds_total{"
        f'namespace="{namespace}",pod=~"{pod_regex}",container!="",container!="POD",image!=""'
        f"}}[{CPU_RATE_WINDOW}]))"
    )


def cpu_limit_query(namespace, pod_regex):
    return (
        "sum(kube_pod_container_resource_limits{"
        f'namespace="{namespace}",pod=~"{pod_regex}",resource="cpu"'
        "})"
    )


def backend_sources(service, cfg, backend):
    if backend == IAAS:
        return [{"name": "iaas", "namespace": "default", "pod_regex": f"{cfg['iaas_deployment']}-.*"}]
    return [
        {"name": "bridge", "namespace": "default", "pod_regex": f"{cfg['bridge_deployment']}-.*"},
        {"name": "function", "namespace": "openfaas-fn", "pod_regex": f"{cfg['function']}-.*"},
    ]


def backend_cpu_pct(service, cfg, backend):
    total_usage = 0.0
    total_limit = 0.0
    missing = []

    for source in backend_sources(service, cfg, backend):
        usage = prom_scalar(cpu_usage_query(source["namespace"], source["pod_regex"]))
        limit = prom_scalar(cpu_limit_query(source["namespace"], source["pod_regex"]))
        if usage is None or limit is None or limit <= 0:
            missing.append(source["name"])
            continue
        total_usage += usage
        total_limit += limit

    if missing or total_limit <= 0:
        blocked_total.labels(service=service, reason="missing_cpu_metrics").inc()
        log.warning("[%s] missing CPU metrics for %s backend sources: %s", service, backend, ",".join(missing))
        return None

    return (total_usage / total_limit) * 100.0


def reconcile_backend(service, cfg, backend):
    if backend == FAAS:
        scale_deployment(cfg["function"], 1, namespace="openfaas-fn")
        wait_deployment(cfg["function"], namespace="openfaas-fn")
        scale_deployment(cfg["bridge_deployment"], 1)
        wait_deployment(cfg["bridge_deployment"])
        patch_service_backend(service, FAAS)
        scale_deployment(cfg["iaas_deployment"], 0)
        placement_state.labels(service=service).set(0)
    else:
        scale_deployment(cfg["iaas_deployment"], 1)
        wait_deployment(cfg["iaas_deployment"])
        patch_service_backend(service, IAAS)
        scale_deployment(cfg["bridge_deployment"], 0)
        scale_deployment(cfg["function"], 0, namespace="openfaas-fn")
        placement_state.labels(service=service).set(1)


def move_to_faas(service, cfg):
    log.info("[%s] switching IaaS -> FaaS", service)
    scale_deployment(cfg["function"], 1, namespace="openfaas-fn")
    wait_deployment(cfg["function"], namespace="openfaas-fn")
    scale_deployment(cfg["bridge_deployment"], 1)
    wait_deployment(cfg["bridge_deployment"])
    patch_service_backend(service, FAAS)
    scale_deployment(cfg["iaas_deployment"], 0)
    placement_state.labels(service=service).set(0)
    switches_total.labels(service=service, direction="iaas_to_faas").inc()
    log.info("[%s] active backend is now FaaS", service)


def move_to_iaas(service, cfg):
    log.info("[%s] switching FaaS -> IaaS", service)
    scale_deployment(cfg["iaas_deployment"], 1)
    wait_deployment(cfg["iaas_deployment"])
    patch_service_backend(service, IAAS)
    scale_deployment(cfg["bridge_deployment"], 0)
    scale_deployment(cfg["function"], 0, namespace="openfaas-fn")
    placement_state.labels(service=service).set(1)
    switches_total.labels(service=service, direction="faas_to_iaas").inc()
    log.info("[%s] active backend is now IaaS", service)


def main():
    log.info(
        "Controller started. threshold=%.1f%% low_windows=%s high_windows=%s cooldown=%ss prometheus=%s",
        CPU_THRESHOLD_PCT,
        LOW_WINDOWS_TO_FAAS,
        HIGH_WINDOWS_TO_IAAS,
        COOLDOWN_SECONDS,
        ",".join(PROMETHEUS_URLS),
    )

    state = {}
    low_windows = {service: 0 for service in SERVICES}
    high_windows = {service: 0 for service in SERVICES}
    last_switch = {service: 0.0 for service in SERVICES}

    for service, cfg in SERVICES.items():
        backend = service_backend(service, cfg) or IAAS
        try:
            reconcile_backend(service, cfg, backend)
            state[service] = backend
            log.info("[%s] reconciled startup backend=%s", service, backend)
        except Exception as exc:
            state[service] = IAAS
            blocked_total.labels(service=service, reason="startup_reconcile_failed").inc()
            log.warning("[%s] startup reconcile failed: %s", service, exc)

    while True:
        now = time.time()
        for service, cfg in SERVICES.items():
            try:
                observed_backend = service_backend(service, cfg)
                if observed_backend in (IAAS, FAAS) and observed_backend != state[service]:
                    state[service] = observed_backend
                    low_windows[service] = 0
                    high_windows[service] = 0

                backend = state[service]
                cpu_pct = backend_cpu_pct(service, cfg, backend)
                if cpu_pct is None:
                    continue

                active_cpu_pct.labels(service=service, backend=backend).set(cpu_pct)
                cooldown_active = now - last_switch[service] < COOLDOWN_SECONDS

                if backend == IAAS:
                    placement_state.labels(service=service).set(1)
                    high_windows[service] = 0
                    if cpu_pct <= CPU_THRESHOLD_PCT:
                        low_windows[service] += 1
                    else:
                        low_windows[service] = 0

                    log.info(
                        "[%s] backend=IaaS cpu=%.1f%% low=%s/%s",
                        service,
                        cpu_pct,
                        low_windows[service],
                        LOW_WINDOWS_TO_FAAS,
                    )

                    if low_windows[service] >= LOW_WINDOWS_TO_FAAS:
                        if cooldown_active:
                            blocked_total.labels(service=service, reason="cooldown").inc()
                        else:
                            move_to_faas(service, cfg)
                            state[service] = FAAS
                            last_switch[service] = time.time()
                        low_windows[service] = 0
                else:
                    placement_state.labels(service=service).set(0)
                    low_windows[service] = 0
                    if cpu_pct > CPU_THRESHOLD_PCT:
                        high_windows[service] += 1
                    else:
                        high_windows[service] = 0

                    log.info(
                        "[%s] backend=FaaS cpu=%.1f%% high=%s/%s",
                        service,
                        cpu_pct,
                        high_windows[service],
                        HIGH_WINDOWS_TO_IAAS,
                    )

                    if high_windows[service] >= HIGH_WINDOWS_TO_IAAS:
                        if cooldown_active:
                            blocked_total.labels(service=service, reason="cooldown").inc()
                        else:
                            move_to_iaas(service, cfg)
                            state[service] = IAAS
                            last_switch[service] = time.time()
                        high_windows[service] = 0

                low_windows_g.labels(service=service).set(low_windows[service])
                high_windows_g.labels(service=service).set(high_windows[service])
            except Exception as exc:
                blocked_total.labels(service=service, reason="loop_error").inc()
                log.warning("[%s] loop error: %s", service, exc)

        time.sleep(INTERVAL_SECONDS)


if __name__ == "__main__":
    main()

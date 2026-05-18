#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VM_B_PUBLIC_IP="${1:-}"
DEPLOY=0

if [ "${VM_B_PUBLIC_IP}" = "--deploy" ]; then
  VM_B_PUBLIC_IP=""
  DEPLOY=1
fi
if [ "${2:-}" = "--deploy" ]; then
  DEPLOY=1
fi

if [ -z "$VM_B_PUBLIC_IP" ]; then
  VM_B_PUBLIC_IP="$(terraform -chdir="${ROOT_DIR}/hybrid/terraform" output -raw vm_b_public_ip)"
fi

SSH_KEY="${ROOT_DIR}/iaas.pem"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "$SSH_KEY")
SSH=(ssh "${SSH_OPTS[@]}" "ubuntu@${VM_B_PUBLIC_IP}")
SCP=(scp "${SSH_OPTS[@]}")

NOVA_VM_IP="$("${SSH[@]}" 'source /home/ubuntu/env.sh; printf "%s" "$NOVA_VM_IP"')"
REGISTRY="localhost:30500"
FUNCTION_REPOSITORY="mtp-openfaas"

upload_deploy_assets() {
  "${SSH[@]}" 'mkdir -p /home/ubuntu/functions /home/ubuntu/automation /home/ubuntu/k8s/gob /home/ubuntu/k8s/openfaas /home/ubuntu/k8s/grpc-bridge /home/ubuntu/scripts'
  "${SCP[@]}" "${ROOT_DIR}/hybrid/functions/stack.yml" "ubuntu@${VM_B_PUBLIC_IP}:/home/ubuntu/functions/stack.yml"
  "${SCP[@]}" "${ROOT_DIR}/hybrid/k8s/gob/online-boutique-iaas.yaml" "ubuntu@${VM_B_PUBLIC_IP}:/home/ubuntu/k8s/gob/online-boutique-iaas.yaml"
  "${SCP[@]}" "${ROOT_DIR}/hybrid/k8s/openfaas/functions.yaml" "ubuntu@${VM_B_PUBLIC_IP}:/home/ubuntu/k8s/openfaas/functions.yaml"
  "${SCP[@]}" "${ROOT_DIR}"/hybrid/k8s/grpc-bridge/*.yaml "ubuntu@${VM_B_PUBLIC_IP}:/home/ubuntu/k8s/grpc-bridge/"
  "${SCP[@]}" -r "${ROOT_DIR}/hybrid/automation/." "ubuntu@${VM_B_PUBLIC_IP}:/home/ubuntu/automation/"
  "${SCP[@]}" "${ROOT_DIR}/hybrid/scripts/04_deploy_gob_iaas.sh" "${ROOT_DIR}/hybrid/scripts/06_deploy_grpc_bridges.sh" "${ROOT_DIR}/hybrid/scripts/07_deploy_functions.sh" "${ROOT_DIR}/hybrid/scripts/09_deploy_controller.sh" "ubuntu@${VM_B_PUBLIC_IP}:/home/ubuntu/scripts/"
  "${SSH[@]}" 'chmod +x /home/ubuntu/scripts/04_deploy_gob_iaas.sh /home/ubuntu/scripts/06_deploy_grpc_bridges.sh /home/ubuntu/scripts/07_deploy_functions.sh /home/ubuntu/scripts/09_deploy_controller.sh'
}

deploy_remote() {
  if [ "$DEPLOY" -eq 1 ]; then
    "${SSH[@]}" 'bash /home/ubuntu/scripts/04_deploy_gob_iaas.sh && bash /home/ubuntu/scripts/07_deploy_functions.sh && bash /home/ubuntu/scripts/06_deploy_grpc_bridges.sh && bash /home/ubuntu/scripts/09_deploy_controller.sh'
  else
    echo "Images pushed. Deploy on VM-B with:"
    echo "  ssh -i ${SSH_KEY} ubuntu@${VM_B_PUBLIC_IP} 'bash /home/ubuntu/scripts/04_deploy_gob_iaas.sh && bash /home/ubuntu/scripts/07_deploy_functions.sh && bash /home/ubuntu/scripts/06_deploy_grpc_bridges.sh && bash /home/ubuntu/scripts/09_deploy_controller.sh'"
  fi
}

build_and_push_local() {
  command -v docker >/dev/null || return 1
  docker info >/dev/null 2>&1 || return 1

  if ! curl -fsS --max-time 2 "http://${REGISTRY}/v2/" >/dev/null 2>&1; then
  echo "Opening SSH tunnel from ${REGISTRY} to VM-B registry (${NOVA_VM_IP}:30500)..."
  ssh "${SSH_OPTS[@]}" -N -L "127.0.0.1:30500:${NOVA_VM_IP}:30500" "ubuntu@${VM_B_PUBLIC_IP}" &
  TUNNEL_PID=$!
  trap 'kill ${TUNNEL_PID} >/dev/null 2>&1 || true' EXIT
  for _ in $(seq 1 30); do
    curl -fsS --max-time 2 "http://${REGISTRY}/v2/" >/dev/null 2>&1 && break
    sleep 1
  done
  fi

  curl -fsS "http://${REGISTRY}/v2/" >/dev/null

  for fn in email currency shipping ad; do
    docker build --platform linux/amd64 \
      --build-arg "SERVICE=${fn}" \
      -t "${REGISTRY}/${FUNCTION_REPOSITORY}/${fn}:latest" \
      "${ROOT_DIR}/hybrid/functions"
    docker push "${REGISTRY}/${FUNCTION_REPOSITORY}/${fn}:latest"
  done

  for bridge in email currency shipping ad; do
    docker build --platform linux/amd64 \
      --build-arg "SERVICE=${bridge}" \
      -t "${REGISTRY}/${bridge}-bridge:latest" \
      "${ROOT_DIR}/hybrid/grpc-bridge"
    docker push "${REGISTRY}/${bridge}-bridge:latest"
  done

  docker build --platform linux/amd64 \
    -t "${REGISTRY}/placement-controller:latest" \
    "${ROOT_DIR}/hybrid/automation"
  docker push "${REGISTRY}/placement-controller:latest"
}

build_and_push_remote() {
  local remote_build_dir="/home/ubuntu/mtp-step2-build"

  "${SSH[@]}" 'docker info >/dev/null'
  "${SSH[@]}" "rm -rf '${remote_build_dir}' && mkdir -p '${remote_build_dir}'"
  "${SCP[@]}" -r "${ROOT_DIR}/hybrid/functions" "ubuntu@${VM_B_PUBLIC_IP}:${remote_build_dir}/functions"
  "${SCP[@]}" -r "${ROOT_DIR}/hybrid/grpc-bridge" "ubuntu@${VM_B_PUBLIC_IP}:${remote_build_dir}/grpc-bridge"
  "${SCP[@]}" -r "${ROOT_DIR}/hybrid/automation" "ubuntu@${VM_B_PUBLIC_IP}:${remote_build_dir}/automation"

  "${SSH[@]}" '
    if ! curl -fsS --max-time 2 http://127.0.0.1:30500/v2/ >/dev/null 2>&1; then
      if [ -f /tmp/mtp-registry-port-forward.pid ]; then
        kill "$(cat /tmp/mtp-registry-port-forward.pid)" >/dev/null 2>&1 || true
      fi
      nohup kubectl -n registry port-forward --address 127.0.0.1 svc/registry 30500:5000 >/tmp/mtp-registry-port-forward.log 2>&1 &
      echo $! >/tmp/mtp-registry-port-forward.pid
      for _ in $(seq 1 30); do
        curl -fsS --max-time 2 http://127.0.0.1:30500/v2/ >/dev/null 2>&1 && exit 0
        sleep 1
      done
      cat /tmp/mtp-registry-port-forward.log >&2 || true
      exit 1
    fi
  '

  for fn in email currency shipping ad; do
    "${SSH[@]}" "docker build --platform linux/amd64 --build-arg SERVICE=${fn} -t ${REGISTRY}/${FUNCTION_REPOSITORY}/${fn}:latest '${remote_build_dir}/functions'"
    "${SSH[@]}" "docker push ${REGISTRY}/${FUNCTION_REPOSITORY}/${fn}:latest"
  done

  for bridge in email currency shipping ad; do
    "${SSH[@]}" "docker build --platform linux/amd64 --build-arg SERVICE=${bridge} -t ${REGISTRY}/${bridge}-bridge:latest '${remote_build_dir}/grpc-bridge'"
    "${SSH[@]}" "docker push ${REGISTRY}/${bridge}-bridge:latest"
  done

  "${SSH[@]}" "docker build --platform linux/amd64 -t ${REGISTRY}/placement-controller:latest '${remote_build_dir}/automation'"
  "${SSH[@]}" "docker push ${REGISTRY}/placement-controller:latest"
}

if ! build_and_push_local; then
  echo "Local Docker daemon is unavailable; building and pushing from VM-B instead."
  build_and_push_remote
fi

upload_deploy_assets
deploy_remote

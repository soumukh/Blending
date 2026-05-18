#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

run_stack() {
  local name="$1"
  local dir="$2"
  (
    cd "$dir"
    echo "==> Initializing ${name}"
    terraform init
    echo "==> Applying ${name}"
    terraform apply -auto-approve
  )
}

run_stack "VM-A IaaS" "${ROOT_DIR}/iaas/terraform" &
IAAS_PID="$!"

run_stack "VM-B hybrid" "${ROOT_DIR}/hybrid/terraform" &
HYBRID_PID="$!"

set +e
wait "$IAAS_PID"
IAAS_STATUS="$?"
wait "$HYBRID_PID"
HYBRID_STATUS="$?"
set -e

if [ "$IAAS_STATUS" -ne 0 ] || [ "$HYBRID_STATUS" -ne 0 ]; then
  echo "Step 1 failed. VM-A status=${IAAS_STATUS}, VM-B status=${HYBRID_STATUS}" >&2
  exit 1
fi

echo "Step 1 complete."
echo "VM-A: $(cd "${ROOT_DIR}/iaas/terraform" && terraform output -raw vm_a_public_ip)"
echo "VM-B: $(cd "${ROOT_DIR}/hybrid/terraform" && terraform output -raw vm_b_public_ip)"

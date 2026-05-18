#!/usr/bin/env bash
set -euo pipefail

source /home/ubuntu/env.sh

kubectl apply -f /home/ubuntu/k8s/openfaas/functions.yaml

for fn in email currency shipping ad; do
  kubectl -n openfaas-fn rollout status "deployment/${fn}" --timeout=600s
done

bash /home/ubuntu/scripts/wait_for_service.sh \
  "curl -fsS -X POST http://${NOVA_VM_IP}:31112/function/currency -H 'Content-Type: application/json' -d '{\"method\":\"GetSupportedCurrencies\",\"payload\":{}}' | grep -q currencyCodes" \
  300 \
  5

echo "OpenFaaS functions deployed."

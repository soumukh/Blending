#!/usr/bin/env bash
set -euo pipefail

source /home/ubuntu/env.sh

helm repo add openfaas https://openfaas.github.io/faas-netes/
helm repo update

kubectl apply -f https://raw.githubusercontent.com/openfaas/faas-netes/master/namespaces.yml
helm upgrade --install openfaas openfaas/openfaas \
  --namespace openfaas \
  --set functionNamespace=openfaas-fn \
  --set generateBasicAuth=true \
  --set gateway.serviceType=NodePort \
  --set gateway.nodePort=31112 \
  --wait \
  --timeout 15m

kubectl -n openfaas patch svc gateway --type='json' \
  -p='[{"op":"replace","path":"/spec/type","value":"NodePort"},{"op":"add","path":"/spec/ports/0/nodePort","value":31112}]' \
  >/dev/null 2>&1 || true

kubectl apply -f /home/ubuntu/k8s/openfaas/local-registry.yaml
kubectl -n registry rollout status deployment/registry --timeout=300s

bash /home/ubuntu/scripts/wait_for_service.sh "http://${NOVA_VM_IP}:31112/healthz" 300 5
bash /home/ubuntu/scripts/wait_for_service.sh "http://${NOVA_VM_IP}:30500/v2/" 300 5

OPENFAAS_PASSWORD="$(kubectl get secret -n openfaas basic-auth -o jsonpath='{.data.basic-auth-password}' | base64 -d)"
echo "$OPENFAAS_PASSWORD" > /home/ubuntu/openfaas-password.txt
chmod 600 /home/ubuntu/openfaas-password.txt
echo "$OPENFAAS_PASSWORD" | faas-cli login --password-stdin --gateway "http://${NOVA_VM_IP}:31112"

echo "OpenFaaS and local registry are ready."


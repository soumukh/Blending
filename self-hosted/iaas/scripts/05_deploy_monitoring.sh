#!/usr/bin/env bash
set -euo pipefail

source /home/ubuntu/env.sh

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values /home/ubuntu/k8s/monitoring/values.yaml \
  --wait \
  --timeout 15m

kubectl -n monitoring create configmap mtp-phase1-dashboards \
  --from-file=/home/ubuntu/k8s/monitoring/dashboards/ \
  --dry-run=client \
  -o yaml \
  | kubectl label --local -f - grafana_dashboard=1 -o yaml \
  | kubectl apply -f -

kubectl -n monitoring rollout status deployment/kube-prometheus-stack-grafana --timeout=600s
kubectl -n monitoring wait --for=condition=ready pod -l app.kubernetes.io/name=prometheus --timeout=600s

bash /home/ubuntu/scripts/wait_for_service.sh "http://${NOVA_VM_IP}:9090/-/ready" 300 5
bash /home/ubuntu/scripts/wait_for_service.sh "http://${NOVA_VM_IP}:3000/api/health" 300 5

echo "Prometheus and Grafana deployed."


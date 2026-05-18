#!/usr/bin/env bash
set -euo pipefail

kubectl apply -f /home/ubuntu/k8s/gob/

while read -r deployment; do
  kubectl rollout status "$deployment" --timeout=900s
done < <(kubectl get deployment -o name)

kubectl get pods -o wide
kubectl get svc

echo "Online Boutique deployed."

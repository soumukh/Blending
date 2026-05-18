#!/usr/bin/env bash
set -euo pipefail

mkdir -p /home/ubuntu/results

kubectl apply -f /home/ubuntu/automation/controller.yaml
kubectl rollout status deployment/placement-controller --timeout=180s

echo "Placement controller running."
echo "Logs: kubectl logs deployment/placement-controller -f"
echo "Decision log is also written to /results/placement_decisions.log inside the controller pod."

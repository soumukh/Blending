#!/usr/bin/env bash
set -euo pipefail

kubectl apply -f /home/ubuntu/k8s/grpc-bridge/

for bridge in email currency shipping ad; do
  kubectl scale "deployment/${bridge}-bridge" --replicas=0
done

kubectl get deployments -l role=grpc-bridge -o wide
kubectl get svc emailservice currencyservice shippingservice adservice

echo "gRPC bridges deployed dormant; placement controller will scale them when routing to FaaS."

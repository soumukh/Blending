#!/usr/bin/env bash
set -euo pipefail

kubectl apply -f /home/ubuntu/k8s/gob/

for deployment in \
  productcatalogservice \
  checkoutservice \
  cartservice \
  redis-cart \
  paymentservice \
  frontend \
  recommendationservice \
  currencyservice \
  shippingservice \
  emailservice \
  adservice; do
  kubectl rollout status "deployment/${deployment}" --timeout=900s
done

kubectl get pods -o wide
kubectl get svc

echo "Hybrid IaaS-side Online Boutique services deployed with switchable backends ready."

#!/usr/bin/env bash
set -euo pipefail

source /home/ubuntu/env.sh

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ${NOVA_SSH_KEY}"
SSH="ssh ${SSH_OPTS} ubuntu@${NOVA_VM_IP}"
RESOLV_CONF="/etc/rancher/k3s/resolv.conf"
K3S_EXEC="--disable=traefik --service-node-port-range=1-32767 --tls-san=${NOVA_VM_IP} --resolv-conf=${RESOLV_CONF}"

$SSH "sudo mkdir -p /etc/rancher/k3s && printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\noptions timeout:2 attempts:3\n' | sudo tee ${RESOLV_CONF} >/dev/null"
$SSH "printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\noptions timeout:2 attempts:3\n' | sudo tee /etc/resolv.conf >/dev/null"
$SSH "host_name=\$(hostname); grep -q \"[[:space:]]\${host_name}\\([[:space:]]\\|$\\)\" /etc/hosts || echo \"127.0.1.1 \${host_name}\" | sudo tee -a /etc/hosts >/dev/null"
$SSH "if sudo systemctl is-active --quiet k3s && [ -f /etc/rancher/k3s/k3s.yaml ] && { ! sudo grep -R -- '--tls-san=${NOVA_VM_IP}' /etc/systemd/system/k3s.service /etc/systemd/system/k3s.service.env >/dev/null 2>&1 || ! sudo grep -R -- '--resolv-conf=${RESOLV_CONF}' /etc/systemd/system/k3s.service /etc/systemd/system/k3s.service.env >/dev/null 2>&1; }; then sudo /usr/local/bin/k3s-uninstall.sh; fi"
$SSH "set -euo pipefail; if ! sudo systemctl is-active --quiet k3s || [ ! -f /etc/rancher/k3s/k3s.yaml ]; then curl -4fsSL https://get.k3s.io -o /tmp/install-k3s.sh; sudo INSTALL_K3S_EXEC='${K3S_EXEC}' sh /tmp/install-k3s.sh; fi"
$SSH "for _ in \$(seq 1 60); do sudo test -f /etc/rancher/k3s/k3s.yaml && sudo systemctl is-active --quiet k3s && exit 0; sleep 5; done; sudo systemctl status k3s --no-pager || true; sudo journalctl -u k3s -n 120 --no-pager || true; exit 1"
$SSH "sudo chmod 644 /etc/rancher/k3s/k3s.yaml"

mkdir -p /home/ubuntu/.kube
$SSH "sudo cat /etc/rancher/k3s/k3s.yaml" \
  | sed "s/127.0.0.1/${NOVA_VM_IP}/" \
  > /home/ubuntu/.kube/config
chmod 600 /home/ubuntu/.kube/config

kubectl wait --for=condition=ready node --all --timeout=300s
kubectl get nodes -o wide

echo "K3s installed."

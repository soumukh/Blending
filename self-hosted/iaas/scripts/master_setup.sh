#!/usr/bin/env bash
set -euo pipefail

cd /home/ubuntu/scripts

bash 00_prerequisites.sh
bash 01_install_devstack.sh
bash 02_openstack_resources.sh
bash 03_install_k3s.sh
bash 04_deploy_gob.sh
bash 05_deploy_monitoring.sh

source /home/ubuntu/env.sh
PUBLIC_IP="$(curl -fsSL --max-time 10 https://checkip.amazonaws.com || curl -fsSL --max-time 10 https://ifconfig.me || true)"

echo "=== PHASE 1 VM READY ==="
echo "GOB Frontend : http://${PUBLIC_IP}:30080"
echo "Grafana      : http://${PUBLIC_IP}:3000  (admin/admin)"
echo "Prometheus   : http://${PUBLIC_IP}:9090"
echo "Nova VM IP   : ${NOVA_VM_IP}"
echo ""
echo "Run load tests from your Mac:"
echo "  cd testing && bash run_phase1.sh ${PUBLIC_IP}"


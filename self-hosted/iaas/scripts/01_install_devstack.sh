#!/usr/bin/env bash
set -euo pipefail

DEVSTACK_BRANCH="${DEVSTACK_BRANCH:-stable/2024.2}"
HOST_IP="$(hostname -I | awk '{print $1}')"
source /home/ubuntu/mtp_libvirt.env 2>/dev/null || true
LIBVIRT_TYPE="${MTP_LIBVIRT_TYPE:-kvm}"

sudo useradd -s /bin/bash -d /opt/stack -m stack 2>/dev/null || true
echo "stack ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/stack >/dev/null
sudo chmod 440 /etc/sudoers.d/stack

if sudo test -e /opt/stack/devstack && ! sudo test -d /opt/stack/devstack/.git; then
  sudo rm -rf /opt/stack/devstack
fi

if ! sudo test -d /opt/stack/devstack/.git; then
  sudo git clone --branch "$DEVSTACK_BRANCH" https://opendev.org/openstack/devstack /opt/stack/devstack
else
  sudo -u stack git -C /opt/stack/devstack fetch origin "$DEVSTACK_BRANCH"
  sudo -u stack git -C /opt/stack/devstack checkout -B "$DEVSTACK_BRANCH" "origin/$DEVSTACK_BRANCH"
fi
sudo chown -R stack:stack /opt/stack
sudo chmod 755 /opt/stack

sudo -u stack tee /opt/stack/devstack/local.conf >/dev/null <<EOF
[[local|localrc]]
ADMIN_PASSWORD=secret
DATABASE_PASSWORD=secret
RABBIT_PASSWORD=secret
SERVICE_PASSWORD=secret
HOST_IP=${HOST_IP}
FLOATING_RANGE=172.24.4.0/24
IPV4_ADDRS_SAFE_TO_USE=10.0.0.0/22
Q_FLOATING_ALLOCATION_POOL=start=172.24.4.100,end=172.24.4.200
LIBVIRT_TYPE=${LIBVIRT_TYPE}
LOGFILE=/opt/stack/logs/stack.sh.log
LOG_COLOR=False
export OS_AUTH_URL=http://${HOST_IP}/identity/v3/

# Keep DevStack focused on Nova, Neutron, Glance, Keystone, and Horizon.
disable_service tempest
disable_service swift
disable_service cinder
disable_service q-agt neutron-agent q-l3 neutron-l3 q-dhcp neutron-dhcp q-meta neutron-metadata-agent
enable_service key g-api g-reg n-api n-cpu n-sch n-cond placement-api placement-client neutron q-svc ovn-controller ovn-northd ovs-vswitchd ovsdb-server q-ovn-metadata-agent horizon
EOF

if ! sudo test -f /opt/stack/.mtp_devstack_done && sudo test -f /opt/stack/devstack/openrc; then
  if sudo -u stack timeout 30 bash -lc "source /opt/stack/devstack/openrc admin admin && openstack service list >/dev/null && openstack compute service list --service nova-compute >/dev/null"; then
    echo "DevStack is already operational; marking install complete."
    sudo touch /opt/stack/.mtp_devstack_done
  fi
fi

if ! sudo test -f /opt/stack/.mtp_devstack_done; then
  sudo -u stack mkdir -p /opt/stack/logs
  sudo -u stack bash -lc "cd /opt/stack/devstack && ./stack.sh > /opt/stack/logs/stack.sh.console 2>&1" \
    || { sudo tail -200 /opt/stack/logs/stack.sh.console; exit 1; }
  sudo chmod 755 /opt/stack
else
  echo "DevStack appears to be installed already; skipping stack.sh."
fi

sudo -u stack bash -lc "source /opt/stack/devstack/openrc admin admin && openstack service list"
sudo touch /opt/stack/.mtp_devstack_done
echo "DevStack installed."

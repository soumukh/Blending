#!/usr/bin/env bash
set -euo pipefail

set +u
source /opt/stack/devstack/openrc admin admin
set -u

NOVA_KEY="/home/ubuntu/.ssh/mtp_nova_key"
mkdir -p /home/ubuntu/.ssh
if [ ! -f "$NOVA_KEY" ]; then
  ssh-keygen -t rsa -b 4096 -N "" -f "$NOVA_KEY" -C "mtp-nova-key"
fi
chmod 600 "$NOVA_KEY"
chmod 644 "${NOVA_KEY}.pub"

openstack network show mtp-net >/dev/null 2>&1 \
  || openstack network create mtp-net

openstack subnet show mtp-subnet >/dev/null 2>&1 \
  || openstack subnet create mtp-subnet \
    --network mtp-net \
    --subnet-range 192.168.100.0/24 \
    --dns-nameserver 8.8.8.8

openstack router show mtp-router >/dev/null 2>&1 \
  || openstack router create mtp-router
openstack router set mtp-router --external-gateway public
openstack router add subnet mtp-router mtp-subnet 2>/dev/null || true

openstack flavor show mtp.k3s >/dev/null 2>&1 \
  || openstack flavor create --vcpus 4 --ram 8192 --disk 40 mtp.k3s

openstack keypair show mtp-key >/dev/null 2>&1 \
  || openstack keypair create --public-key "${NOVA_KEY}.pub" mtp-key

USER_DATA="/home/ubuntu/mtp_nova_cloud_init.yaml"
NOVA_PUBLIC_KEY="$(cat "${NOVA_KEY}.pub")"
cat >"$USER_DATA" <<EOF
#cloud-config
users:
  - name: ubuntu
    gecos: Ubuntu
    groups: users, admin, sudo
    shell: /bin/bash
    lock_passwd: true
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - ${NOVA_PUBLIC_KEY}
ssh_pwauth: false
disable_root: true
EOF
chmod 600 "$USER_DATA"

if ! openstack image show ubuntu-22.04 >/dev/null 2>&1; then
  wget -qO /tmp/ubuntu-22.04-server-cloudimg-amd64.img \
    https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img
  openstack image create ubuntu-22.04 \
    --file /tmp/ubuntu-22.04-server-cloudimg-amd64.img \
    --disk-format qcow2 \
    --container-format bare \
    --public
fi
bash /home/ubuntu/scripts/wait_for_service.sh \
  "openstack image show ubuntu-22.04 -f value -c status | grep -qi active" \
  300 \
  5

openstack security group show k3s-sg >/dev/null 2>&1 \
  || openstack security group create k3s-sg
openstack security group rule create k3s-sg --protocol tcp --dst-port 1:65535 2>/dev/null || true
openstack security group rule create k3s-sg --protocol udp --dst-port 1:65535 2>/dev/null || true
openstack security group rule create k3s-sg --protocol icmp 2>/dev/null || true

sudo -u stack /opt/stack/data/venv/bin/nova-manage --config-file /etc/nova/nova.conf cell_v2 discover_hosts --verbose || true

delete_k3s_server() {
  openstack server delete k3s-vm
  bash /home/ubuntu/scripts/wait_for_service.sh \
    "! openstack server show k3s-vm >/dev/null 2>&1" \
    180 \
    5
}

create_k3s_server() {
  openstack server create k3s-vm \
    --image ubuntu-22.04 \
    --flavor mtp.k3s \
    --network mtp-net \
    --security-group k3s-sg \
    --key-name mtp-key \
    --user-data "$USER_DATA" \
    --use-config-drive \
    --wait
}

server_floating_ip() {
  openstack server show k3s-vm -f value -c addresses \
    | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' \
    | grep -v '^192\.168\.100\.' \
    | tail -n1 || true
}

available_floating_ip() {
  openstack floating ip list -f value -c "Floating IP Address" -c Port \
    | awk 'NF == 1 || $2 == "None" { print $1; exit }'
}

ensure_floating_ip() {
  local floating_ip
  floating_ip="$(server_floating_ip)"
  if [ -z "$floating_ip" ]; then
    floating_ip="$(available_floating_ip)"
    if [ -z "$floating_ip" ]; then
      floating_ip="$(openstack floating ip create public -f value -c floating_ip_address)"
    fi
    openstack server add floating ip k3s-vm "$floating_ip"
  fi
  echo "$floating_ip"
}

can_ssh_to_vm() {
  local floating_ip="$1"
  ssh -o BatchMode=yes \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=5 \
    -o ConnectionAttempts=1 \
    -i "$NOVA_KEY" \
    "ubuntu@${floating_ip}" \
    true
}

if openstack server show k3s-vm >/dev/null 2>&1; then
  SERVER_STATUS="$(openstack server show k3s-vm -f value -c status)"
  if [ "$SERVER_STATUS" = "ERROR" ]; then
    delete_k3s_server
  fi
fi

SERVER_CREATED=0
if ! openstack server show k3s-vm >/dev/null 2>&1; then
  create_k3s_server
  SERVER_CREATED=1
fi

FLOATING_IP="$(ensure_floating_ip)"

if [ "$SERVER_CREATED" -eq 0 ] && ! can_ssh_to_vm "$FLOATING_IP"; then
  echo "Existing k3s-vm does not accept the configured SSH key; recreating with config-drive user-data."
  delete_k3s_server
  create_k3s_server
  SERVER_CREATED=1
  FLOATING_IP="$(ensure_floating_ip)"
fi

echo "Nova VM floating IP: ${FLOATING_IP}"
bash /home/ubuntu/scripts/wait_for_service.sh \
  "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -i ${NOVA_KEY} ubuntu@${FLOATING_IP} true" \
  300 \
  5

sudo sysctl -w net.ipv4.ip_forward=1
grep -q '^net.ipv4.ip_forward=1$' /etc/sysctl.conf \
  || echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf >/dev/null
DEFAULT_IFACE="$(ip route show default | awk '{print $5; exit}')"

add_nat_rule() {
  local port="$1"
  sudo iptables -t nat -C PREROUTING -p tcp --dport "$port" -j DNAT --to-destination "${FLOATING_IP}:${port}" 2>/dev/null \
    || sudo iptables -t nat -A PREROUTING -p tcp --dport "$port" -j DNAT --to-destination "${FLOATING_IP}:${port}"
}

add_forward_rule() {
  sudo iptables -C FORWARD "$@" 2>/dev/null \
    || sudo iptables -I FORWARD 1 "$@"
}

add_forward_rule -i br-ex -o "$DEFAULT_IFACE" -j ACCEPT
add_forward_rule -i "$DEFAULT_IFACE" -o br-ex -d "$FLOATING_IP" -j ACCEPT
add_forward_rule -i "$DEFAULT_IFACE" -o br-ex -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

add_nat_rule 30080
add_nat_rule 9090
add_nat_rule 3000

sudo iptables -t nat -C POSTROUTING -j MASQUERADE 2>/dev/null \
  || sudo iptables -t nat -A POSTROUTING -j MASQUERADE
sudo iptables -t nat -C POSTROUTING -s 172.24.4.0/24 -o "$DEFAULT_IFACE" -j MASQUERADE 2>/dev/null \
  || sudo iptables -t nat -A POSTROUTING -s 172.24.4.0/24 -o "$DEFAULT_IFACE" -j MASQUERADE

sudo netfilter-persistent save

cat >/home/ubuntu/env.sh <<EOF
export NOVA_VM_IP=${FLOATING_IP}
export NOVA_SSH_KEY=${NOVA_KEY}
EOF
chmod 600 /home/ubuntu/env.sh

echo "OpenStack resources and iptables NAT configured."

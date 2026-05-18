#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

configure_dns() {
  local default_iface
  local dns_servers

  default_iface="$(ip route show default | awk '{print $5; exit}')"
  dns_servers="$(resolvectl dns "$default_iface" 2>/dev/null | awk '{for (i = 4; i <= NF; i++) print $i}' || true)"
  if [ -z "$dns_servers" ]; then
    dns_servers="172.31.0.2"
  fi

  {
    for server in $dns_servers 1.1.1.1 8.8.8.8; do
      echo "nameserver ${server}"
    done | awk '!seen[$0]++'
    echo "options timeout:2 attempts:3"
  } | sudo tee /tmp/mtp-resolv.conf >/dev/null
  sudo install -m 0644 /tmp/mtp-resolv.conf /etc/resolv.conf
  sudo sed -i 's/^#precedence ::ffff:0:0\/96  100/precedence ::ffff:0:0\/96  100/' /etc/gai.conf
  timeout 15 getent hosts opendev.org >/dev/null
}

configure_dns

VMXCOUNT="$(grep -c -E 'vmx|svm' /proc/cpuinfo || true)"
if [ "$VMXCOUNT" -eq 0 ]; then
  echo "ERROR: No VMX/SVM CPU flags found. Nested virtualization is not available."
  echo "Use c8i.4xlarge with nested virtualization enabled, or switch to bare metal."
  exit 1
else
  echo "Nested virtualization flags detected on ${VMXCOUNT} logical CPUs."
  echo "export MTP_LIBVIRT_TYPE=kvm" > /home/ubuntu/mtp_libvirt.env
fi

if grep -q 'svm' /proc/cpuinfo; then
  echo "options kvm_amd nested=1" | sudo tee /etc/modprobe.d/kvm.conf >/dev/null
  sudo modprobe -r kvm_amd 2>/dev/null || true
  sudo modprobe kvm_amd nested=1 || true
fi

chmod 600 /home/ubuntu/mtp_libvirt.env

if grep -q 'vmx' /proc/cpuinfo; then
  echo "options kvm_intel nested=1" | sudo tee /etc/modprobe.d/kvm.conf >/dev/null
  sudo modprobe -r kvm_intel 2>/dev/null || true
  sudo modprobe kvm_intel nested=1 || true
fi

echo iptables-persistent iptables-persistent/autosave_v4 boolean true | sudo debconf-set-selections
echo iptables-persistent iptables-persistent/autosave_v6 boolean true | sudo debconf-set-selections

sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get -o Acquire::ForceIPv4=true update -qq
sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get -o Acquire::ForceIPv4=true install -yq \
  -o Dpkg::Options::=--force-confdef \
  -o Dpkg::Options::=--force-confold \
  apt-transport-https \
  ca-certificates \
  curl \
  git \
  gnupg \
  iptables-persistent \
  jq \
  lsb-release \
  netfilter-persistent \
  openssh-client \
  python3-openstackclient \
  python3-pip \
  software-properties-common \
  unzip \
  wget

if ! command -v kubectl >/dev/null 2>&1; then
  KUBECTL_VERSION="$(curl -4fsSL https://dl.k8s.io/release/stable.txt)"
  curl -4fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
    -o /tmp/kubectl
  sudo install -m 0755 /tmp/kubectl /usr/local/bin/kubectl
fi

if ! command -v helm >/dev/null 2>&1; then
  curl -4fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

if ! command -v faas-cli >/dev/null 2>&1; then
  curl -4fsSL https://cli.openfaas.com | sudo sh
fi

if ! command -v docker >/dev/null 2>&1; then
  curl -4fsSL https://download.docker.com/linux/ubuntu/gpg \
    | sudo gpg --dearmor -o /usr/share/keyrings/docker.gpg
  echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get -o Acquire::ForceIPv4=true update -qq
  sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get -o Acquire::ForceIPv4=true install -yq \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold \
    docker-ce docker-ce-cli containerd.io
fi

sudo usermod -aG docker ubuntu

echo "Prerequisites installed."

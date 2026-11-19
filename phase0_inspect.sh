#!/usr/bin/env bash
set -u

echo "=== 1. OS & KERNEL ==="
hostnamectl

echo -e "\n=== 2. CPU, VIRTUALIZATION & RAM ==="
lscpu | grep -E "Model name|Socket|Thread|NUMA|CPU\(s\)|Virtualization"
free -h
ls -la /dev/kvm 2>/dev/null || echo "/dev/kvm not present"
ls -la /dev/dri 2>/dev/null || echo "/dev/dri (GPU) not present"

echo -e "\n=== 3. STORAGE & LVM LAYOUT ==="
lsblk -f
sudo vgs
sudo lvs

echo -e "\n=== 4. NETWORK INTERFACES, PORTS & FIREWALL ==="
ip -br addr
ss -tulnp
sudo ufw status verbose

echo -e "\n=== 5. USERS & WORKSPACE ==="
grep -E "^(jordan|litellm|openclaw|mediabot):" /etc/passwd || true
ls -la /home/jordan/Documents/SystemBuild 2>/dev/null || echo "Directory not found"

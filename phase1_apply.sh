#!/usr/bin/env bash
# Phase 1: Host Hardening & Storage Provisioning (clawbox, Ubuntu 26.04 LTS)
# Run with:  sudo bash /home/jordan/Documents/SystemBuild/phase1_apply.sh
# Idempotent. Safe ordering: SSH allow rule is added BEFORE `ufw enable`.
set -euo pipefail

LOG=/home/jordan/Documents/SystemBuild/phase1.out
exec > >(tee "$LOG") 2>&1

say() { printf '\n>>> %s\n' "$*"; }

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: must be run as root (use: sudo bash $0)" >&2
  exit 1
fi

###############################################################################
say "1. Syncing PROJECT_MEMORY.md"
###############################################################################
cp /home/jordan/.opencode/plan/PROJECT_MEMORY.md \
   /home/jordan/Documents/SystemBuild/PROJECT_MEMORY.md
chown jordan:jordan /home/jordan/Documents/SystemBuild/PROJECT_MEMORY.md
chmod 664 /home/jordan/Documents/SystemBuild/PROJECT_MEMORY.md

###############################################################################
say "2. Enforcing SSH & home directory permissions"
###############################################################################
chmod 750 /home/jordan
chmod 700 /home/jordan/.ssh
chmod 600 /home/jordan/.ssh/authorized_keys
chown jordan:jordan /home/jordan /home/jordan/.ssh /home/jordan/.ssh/authorized_keys

###############################################################################
say "3. Writing /etc/ssh/sshd_config.d/01-hardening.conf (01- => first-match-wins)"
###############################################################################
install -d -m 755 /etc/ssh/sshd_config.d
cat >/etc/ssh/sshd_config.d/01-hardening.conf <<'SSHEOF'
ListenAddress 192.168.1.133
ListenAddress 127.0.0.1
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
X11Forwarding no
SSHEOF
chmod 644 /etc/ssh/sshd_config.d/01-hardening.conf
chown root:root /etc/ssh/sshd_config.d/01-hardening.conf

# 00-hardening.conf (pre-existing) only contains "PasswordAuthentication no" -> no conflict.
echo "--- /etc/ssh/sshd_config.d/ contents ---"
ls -l /etc/ssh/sshd_config.d/

###############################################################################
say "4. systemd drop-ins: ssh.socket / ssh.service wait for network-online.target"
# NOTE: ssh.socket is ENABLED on this host (ssh.service is disabled), i.e. sshd is
# socket-activated and therefore inherits its listeners from ssh.socket. Setting
# ListenStream= below is what actually pins sshd to 192.168.1.133 + 127.0.0.1.
###############################################################################
install -d -m 755 /etc/systemd/system/ssh.socket.d
cat >/etc/systemd/system/ssh.socket.d/listen.conf <<'SOCKEOF'
[Unit]
Wants=network-online.target
After=network-online.target

[Socket]
ListenStream=
ListenStream=192.168.1.133:22
ListenStream=127.0.0.1:22
SOCKEOF

install -d -m 755 /etc/systemd/system/ssh.service.d
cat >/etc/systemd/system/ssh.service.d/wait-network.conf <<'SRVEOF'
[Unit]
Wants=network-online.target
After=network-online.target
SRVEOF

###############################################################################
say "5. Validating sshd config BEFORE restarting (abort on error)"
###############################################################################
if ! sshd -t; then
  echo "FATAL: 'sshd -t' failed - NOT restarting ssh. Fix the config and re-run." >&2
  exit 1
fi
echo "sshd -t: OK"

systemctl daemon-reload
systemctl restart ssh.socket
systemctl reload-or-restart ssh

# Give sshd a moment, then confirm it is really serving.
sleep 3
if ! systemctl is-active --quiet ssh.service; then
  echo "WARNING: ssh.service is not active. Last 30 journal lines:" >&2
  journalctl -u ssh.service -n 30 --no-pager >&2 || true
fi

###############################################################################
say "6. Configuring UFW (SSH rule added BEFORE enable - no lockout)"
###############################################################################
ufw default deny incoming
ufw default allow outgoing
ufw allow in on eno1 from 192.168.1.0/24 to any port 22 proto tcp comment 'SSH from Wired LAN'
ufw --force enable

###############################################################################
say "7. Creating 90G 'media' Logical Volume (NOT formatted, NOT mounted)"
###############################################################################
if lvs ubuntu-vg/media >/dev/null 2>&1; then
  echo "LV ubuntu-vg/media already exists - skipping lvcreate."
else
  lvcreate -L 90G -n media ubuntu-vg
fi

###############################################################################
say "8. VERIFICATION"
###############################################################################
echo "=== 8a. Permissions ==="
ls -ld /home/jordan /home/jordan/.ssh /home/jordan/.ssh/authorized_keys

echo
echo "=== 8b. Effective sshd config ==="
sshd -T | grep -E "^(listenaddress|permitrootlogin|passwordauthentication|pubkeyauthentication|kbdinteractiveauthentication|x11forwarding)"

echo
echo "=== 8c. Listening sockets (:22) ==="
ss -tulnp | grep ":22 " || echo "(no :22 listener found!)"

echo
echo "=== 8d. ssh.socket / ssh.service status ==="
systemctl is-active ssh.socket ssh.service || true

echo
echo "=== 8e. UFW status ==="
ufw status numbered

echo
echo "=== 8f. LVM (media LV must be UNFORMATTED / UNMOUNTED) ==="
vgs
lvs
lsblk -f /dev/ubuntu-vg/media

echo
echo "=== Phase 1 apply complete ==="

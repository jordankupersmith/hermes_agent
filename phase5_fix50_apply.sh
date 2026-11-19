#!/usr/bin/env bash
#
# Phase 5 — fix 50: make jellyfin-lan-proxy.socket survive a reboot.
#
# Run AS ROOT on clawbox (this host has no sudo — root console or `su -`).
# Idempotent: re-running converges to the same state.
#
# Why this exists
#   1. A socket unit ordered After=network-online.target is a boot-time
#      ordering cycle: sockets.target is ordered before basic.target ->
#      network-online.target, so systemd deletes the socket's start job and
#      nothing listens on 192.168.1.133:8096 after a reboot.
#   2. Without FreeBind=yes the socket starts before DHCP assigns the pinned
#      LAN address and bind() fails with EADDRNOTAVAIL ("Cannot assign
#      requested address").
#   The .service keeps the network-online ordering (legal there) and gains an
#   explicit Wants= to match jellyfin-discovery.service.
#
# What it does
#   1. refuses to run unless euid == 0
#   2. refuses symlinked target paths
#   3. atomically writes the two unit files (root-only temp + rename)
#   4. daemon-reload; restarts the socket ONLY when the listener is not up
#      (an already-listening socket is never dropped needlessly)
#   5. waits for 192.168.1.133:8096 and probes it end-to-end
#   6. installs the canonical root-owned Phase 5 copies via
#      phase5_step1_install.sh  (SKIP_INSTALL=1 to skip)
#
# Usage:
#   bash /home/jordan/Documents/SystemBuild/phase5_fix50_apply.sh
#   SKIP_INSTALL=1 bash /home/jordan/Documents/SystemBuild/phase5_fix50_apply.sh
#
# This script does NOT touch SSH, ufw, libvirt, the media-vm, or any other
# unit. It does NOT reboot the host.
#
set -euo pipefail

SRC_DIR="${SRC_DIR:-/home/jordan/Documents/SystemBuild}"
UNIT_DIR=/etc/systemd/system
SOCKET="$UNIT_DIR/jellyfin-lan-proxy.socket"
SVC="$UNIT_DIR/jellyfin-lan-proxy.service"
INSTALLER="$SRC_DIR/phase5_step1_install.sh"
LAN_IP=192.168.1.133

red()  { printf '\033[31m%s\033[0m\n' "$*" >&2; }
grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
die()  { red "FAIL: $*"; exit 1; }
info() { printf '  %s\n' "$*"; }

# ---------------------------------------------------------------- 1. root check
[ "$(id -u)" -eq 0 ] || die "must run as root (no sudo on this host: use a root console or 'su -')"

echo "=============================================================="
echo " Phase 5 — fix 50: reboot-safe Jellyfin LAN proxy socket"
echo "=============================================================="
info "socket  : $SOCKET"
info "service : $SVC"
echo

# ------------------------------------------------------- 2. path safety
[ -d "$UNIT_DIR" ] || die "unit directory missing: $UNIT_DIR"
[ -L "$UNIT_DIR" ] && die "unit directory is a symlink — refusing: $UNIT_DIR"
for p in "$SOCKET" "$SVC"; do
    [ -L "$p" ] && die "target is a symlink — refusing to replace: $p"
    if [ -e "$p" ] && [ ! -f "$p" ]; then
        die "target exists but is not a regular file: $p"
    fi
done
info "[ok] target paths safe (no symlinks)"

# ------------------------------------------------- 3. atomic unit writes
TMP=""
cleanup() { if [ -n "$TMP" ]; then rm -f "$TMP"; fi; }
trap cleanup EXIT

put_unit() {
    local dst="$1"
    TMP="$(mktemp "$UNIT_DIR/.fix50.XXXXXX")"
    cat >"$TMP"
    chown root:root "$TMP"
    chmod 0644 "$TMP"
    mv -f "$TMP" "$dst"
    TMP=""
}

# fix 50 — NO [Unit] ordering on a socket unit, and FreeBind so the pinned
# LAN IP can be bound before DHCP assigns it. Never a wildcard.
put_unit "$SOCKET" <<'SOKEOF'
[Unit]
Description=Jellyfin LAN proxy listener (192.168.1.133:8096 -> media-vm 8096)

[Socket]
# Pin to the LAN address - never a wildcard.  The ONLY port media exposes.
ListenStream=192.168.1.133:8096
ReusePort=yes
Backlog=100
# fix 50 — bind before DHCP assigns the LAN IP; packets are delivered once it
# appears. A socket unit must NEVER be ordered After=network-online.target:
# sockets.target precedes basic.target, so that ordering is a boot-time cycle
# that deletes this unit's start job.
FreeBind=yes

[Install]
WantedBy=sockets.target
SOKEOF
info "[written] $SOCKET (root:root 644, FreeBind=yes, no network-online ordering)"

# fix 50 — ordering lives on the SERVICE, where it is legal.
put_unit "$SVC" <<'SVCEOF'
[Unit]
Description=Jellyfin LAN proxy relay (systemd-socket-proxyd)
Requires=jellyfin-lan-proxy.socket
After=network-online.target libvirtd.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/lib/systemd/systemd-socket-proxyd 192.168.122.10:8096
DynamicUser=yes
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectSystem=strict
NoNewPrivileges=yes
RestrictAddressFamilies=AF_INET AF_UNIX
# fix 21 — IP-level sandbox: this relay may talk ONLY to the local LAN
# subnet and the media-vm bridge address (deny-by-default).
IPAddressDeny=any
IPAddressAllow=192.168.1.0/24 192.168.122.10
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCEOF
info "[written] $SVC (root:root 644, Wants/After network-online on the service)"

# --------------------------------------- 4. reload + conditional restart
systemctl daemon-reload
info "[ok] systemd daemon-reload"

ACTIVE=0
systemctl is-active --quiet jellyfin-lan-proxy.socket && ACTIVE=1
LISTENER="$(ss -tlnH 'sport = :8096' 2>/dev/null | awk '{print $4}' | sort -u)"

if [ "$ACTIVE" -eq 1 ] && [ "$LISTENER" = "$LAN_IP:8096" ]; then
    info "[keep] socket already active on $LAN_IP:8096 — not restarting (no listener drop)"
else
    echo "  [wait]    starting jellyfin-lan-proxy.socket (listener may drop ~1s)"
    systemctl restart jellyfin-lan-proxy.socket \
        || die "systemctl restart jellyfin-lan-proxy.socket failed — see: journalctl -u jellyfin-lan-proxy.socket -n 20"
fi

# ------------------------------------------- 5. listener + end-to-end probe
for _ in $(seq 1 20); do
    LISTENER="$(ss -tlnH 'sport = :8096' 2>/dev/null | awk '{print $4}' | sort -u)"
    [ "$LISTENER" = "$LAN_IP:8096" ] && break
    sleep 0.5
done
if [ "$LISTENER" = "$LAN_IP:8096" ]; then
    grn "  [PASS] listener: $LISTENER"
else
    die "no listener on $LAN_IP:8096 after 10s (got '${LISTENER:-<none>}') — see: journalctl -u jellyfin-lan-proxy.socket -n 20"
fi

CODE="$(curl -sS -m 8 -o /dev/null -w '%{http_code}' -I "http://$LAN_IP:8096" 2>/dev/null || true)"
case "$CODE" in
    200|301|302) grn "  [PASS] http://$LAN_IP:8096 -> HTTP $CODE" ;;
    *)           die "Jellyfin LAN probe failed (HTTP '${CODE:-000}') — media-vm/Jellyfin down? try: bash /usr/local/sbin/phase5/phase5_diag.sh" ;;
esac

# ------------------------------------------------------- 6. install copies
if [ "${SKIP_INSTALL:-0}" -eq 1 ]; then
    info "[skip] installer not run (SKIP_INSTALL=1)"
else
    [ -f "$INSTALLER" ] || die "installer not found: $INSTALLER"
    echo
    bash "$INSTALLER"
fi

echo
echo "=============================================================="
echo " fix 50 applied"
echo "=============================================================="
echo " Verify (read-only):"
echo "   bash $SRC_DIR/phase5_fix50_verify.sh"
echo
echo " Reboot-safety is proven only by the NEXT legitimate reboot:"
echo "   systemctl is-active jellyfin-lan-proxy.socket && ss -tln | grep :8096"
echo "   (must be up with no manual intervention)"

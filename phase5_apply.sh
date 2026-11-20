#!/usr/bin/env bash
#
# Phase 5 — KVM/libvirt media-vm + Docker media stack + torrent VPN kill-switch
# Host: clawbox (Ubuntu 26.04)   Architecture: Option A
#
# ROOT-ONLY, IDEMPOTENT, ADDITIVE.  Run the CANONICAL ROOT-OWNED copy with:
#
#   bash /usr/local/sbin/phase5/phase5_apply.sh   (run AS ROOT; fix 12 preflight)
#
# All apply + verification output is appended to /var/log/systembuild/phase5.out
# (fix 12 + fix 26: 640 root:root inside a 750 root:root directory with
# u:jordan:x directory traversal ACL + u:jordan:r file ACL, or root:adm 750/640
# fallback when setfacl is unavailable).
# fix 39: the log is APPEND-ONLY (a delimited run header per run, rotated to
# phase5.out.1 at 10 MiB) — a re-run never destroys the previous run's record.
# fix 14 + fix 34: secret values and >=40-char base64 colon values are masked
# in the log, but the log MAY still contain hostnames and IP addresses.
#
# SECURITY NOTE (fix 27 — VPN key rotation):
#   If an earlier version of this script ever ran on this host with a 644
#   media-vm-root.qcow2 root disk image or a 755 /var/lib/libvirt/images
#   directory while real VPN credentials were present, ROTATE the VPN
#   WireGuard private key (and any OpenVPN password) with your VPN provider.
#
# DISCOVERY MODE NOTE (fix 31 — DISCOVERY_MODE=pinned|broadcast):
#   Default is DISCOVERY_MODE=pinned (socat binds 192.168.1.133:7359/udp).
#   Because Linux UDP sockets bound to a unicast IP do NOT receive limited
#   broadcast packets sent to 255.255.255.255:7359, `pinned` mode means
#   Jellyfin clients must enter http://192.168.1.133:8096 manually.
#   Set DISCOVERY_MODE=broadcast to bind 0.0.0.0:7359/udp (restricted via UFW
#   `ufw allow in on eno1 from 192.168.1.0/24 to any port 7359 proto udp`
#   plus systemd IPAddressDeny=any and IPAddressAllow=192.168.1.0/24 192.168.122.10).
#   fix 57 — broadcast mode only works when Jellyfin's responder is reachable on
#   the VM side; phase5_compose.yaml now publishes 192.168.122.10:7359/udp. With
#   only 8096/tcp published, the relay forwarded every probe into a closed port
#   (ICMP port-unreachable) and no client could ever auto-discover the server.
#
# fix 25 — the full root-only install / negative-gate-test / reboot-test /
# re-run procedure is documented in phase5_manual_steps.md (all host commands
# run AS ROOT; this host has no sudo, and `runuser -u <user> --` is used for
# unprivileged checks).
#
# This script (2026-11-09 external-review hardening applied):
#   * installs KVM/libvirt tooling from Ubuntu's GPG-signed archive ONLY
#     (apt: qemu-system-x86, libvirt-daemon-system, libvirt-clients, virtinst,
#     cloud-image-utils, genisoimage, socat) — NO get.docker.com / curl|bash;
#   * runs with umask 077 and stages ALL working files in a root-only
#     mktemp directory under /run (never predictable, world-readable paths);
#     the VM-side vpn.env transfer goes over the encrypted ssh channel
#     straight into a root-written file — no /tmp staging anywhere;
#   * downloads the Debian 13 (trixie) genericcloud image from the IMMUTABLE
#     dated build directory (never the moving 'latest' pointer), staged as
#     .part and verified against the embedded SHA512 pin of record BEFORE it
#     replaces anything; an in-use base image is NEVER deleted on mismatch
#     (a re-run can never break the running VM's backing file). Note:
#     cloud.debian.org publishes NO GPG-signed SHA512SUMS.sign (verified
#     2026-11-09), so the embedded pin — recorded at artifact-write time —
#     is the fail-closed authenticity anchor, cross-referenced live;
#   * passes the 90G raw LV /dev/ubuntu-vg/media into media-vm as virtio
#     disk with serial=media-data-lv (cache=none, io=native) — the guest
#     resolves it as /dev/disk/by-id/virtio-media-data-lv, NEVER by /dev/vdb
#     (device naming is not guaranteed). The LV stays UNMOUNTED on the host;
#     it is formatted ext4 INSIDE the VM only after a fail-closed
#     blkid -p + wipefs -n scan shows ZERO on-disk signatures;
#   * provisions the VM via cloud-init seed ISO: user 'jordan' (uid 1000 =
#     administration/login ONLY — never the stack uid), a dedicated host-only
#     deploy SSH key (/etc/media-vm/deploy_ed25519 — never jordan's LAN key)
#     with its own known_hosts file (VM rebuilds reset exactly that file, never
#     the admin's), docker.io + docker compose v2 + ufw from Debian apt,
#     package_update + package_upgrade + unattended-upgrades (the VM patches
#     itself — it faces the internet as a torrent client);
#     fix 37 — the media stack runs as NUMERIC PUID/PGID 1001, which has NO
#     passwd entry and NO sudo INSIDE media-vm: container-side code execution
#     as the stack uid is therefore not one sudo away from root inside the VM.
#     fix 43 — that "no passwd entry" holds in the GUEST only: on the host,
#     uid 1001 is the unrelated 'hermes' service account (phase 4). The media
#     LV is raw-passthrough and never mounted on the host, so the two uid
#     namespaces never meet; apply+diag assert the guest side live.
#   * hardens media-vm with ufw (deny incoming / allow outgoing; *arr + qBt +
#     Jellyfin reachable ONLY from 192.168.122.0/24) and a torrent-port
#     leak BACKSTOP (DOCKER-USER + ufw deny 6881:6889 tcp+udp — peers can
#     use any port, so this is defense-in-depth, NOT the kill switch; the
#     real L3 isolation is gluetun's netns + qbittorrent's
#     network_mode service:gluetun + Session\Interface=tun0 in [BitTorrent]);
#     a DOCKER-USER inbound source guard covers all published ports because
#     docker's published ports bypass ufw INPUT;
#   * blocks VM->LAN pivots: ufw route DENIES for virbr0 -> RFC1918 placed
#     before the egress allow, PLUS a durable host media-vm-lan-guard unit
#     that pins DROP rules to the TOP of FORWARD (libvirt inserts its own
#     permissive hooks ahead of ufw's chains on every net-start) — verified
#     live with an in-VM probe that must NOT reach 192.168.1.1;
#   * pushes phase5_compose.yaml verbatim into /opt/media-stack/
#     (docker-compose.yml) and tags it against the local source by sha256;
#   * deploys the stack: `docker compose up -d` ALWAYS starts the 7 clearnet
#     apps first; gluetun + qbittorrent start ONLY when /etc/media-vm/vpn.env
#     holds real provider credentials, via `docker compose --profile vpn up
#     -d` (--profile is a global flag: it goes BEFORE the up subcommand) —
#     the same start-gating pattern Phases 3 and 4 use for their secrets;
#   * fix 52 — exposes the family requests UI too: host Caddy terminates TLS on
#     192.168.1.133:8443 (internal CA "Family Media CA") -> Jellyseerr 5055;
#     the ufw row is 192.168.1.0/24-only and every admin UI stays VM/host-only;
#   * fix 41 — exposes Jellyfin to the LAN: 192.168.1.133:8096/tcp via
#     systemd-socket-proxyd (jellyfin-lan-proxy.socket/.service, ALWAYS pinned
#     to the LAN address — never a wildcard) plus a socat UDP relay for the
#     7359 discovery beat whose bind FOLLOWS DISCOVERY_MODE:
#       pinned    -> 192.168.1.133:7359/udp (default; no wildcard bind)
#       broadcast -> 0.0.0.0:7359/udp, restricted by
#                    `ufw allow in on eno1 from 192.168.1.0/24 to any port 7359 proto udp`
#                    and systemd IPAddressDeny=any / IPAddressAllow.
#     fix 50 — a host LAN-facing SOCKET unit must NEVER be ordered after
#     network-online.target: sockets.target is ordered before basic.target,
#     so that creates a boot-time ordering cycle and systemd DELETES the
#     socket's start job (8096 silently dead after reboot). FreeBind=yes lets
#     the socket bind the pinned LAN IP before DHCP assigns it.
#     Both units are sandboxed (DynamicUser, ProtectHome,
#     RestrictAddressFamilies). *arr/qBt are NEVER reachable from the LAN;
#   * appends harvested API keys/URLs (prowlarr/radarr/lidarr/bazarr/jellyfin/
#     qbittorrent) to /opt/media-assistant/.env (600 mediabot:mediabot,
#     APPEND-ONLY, values never echoed) to pre-wire Phase 6 — fix 49: bazarr's
#     key comes from its config/config.yaml (NOT Servarr's config.xml) and the
#     qbittorrent URL is written even while the vpn profile is credential-gated;
#   * verifies V1–V10, including explicit Phase 1–4 untouched checks (SSH
#     posture, UFW state, LVM, litellm on 127.0.0.1:4000, hermes on
#     127.0.0.1:8642/9119 — read-only).
#
# This script NEVER: overwrites /opt/media-assistant/.env values, echoes any
# secret, touches /etc/litellm or /etc/hermes content, formats or mounts the
# media LV on the HOST, disables wlp1s0's permanence, or changes sshd.

set -uo pipefail

# fix 12 — the log lives in a ROOT-OWNED directory (never in jordan's home:
# root's tee/chown/chmod on a jordan-writable path follows planted symlinks),
# and the canonical script + compose copy is root-owned under /usr/local/sbin
# (a jordan-writable source directory is never root-executed again).
LOGDIR=/var/log/systembuild
LOG="$LOGDIR/phase5.out"
SCRIPT_DIR=/usr/local/sbin/phase5
COMPOSE_SRC="$SCRIPT_DIR/phase5_compose.yaml"

# ---- VM constants (audit decisions) -----------------------------------------
VM_NAME=media-vm
VM_MAC=52:54:00:6d:65:6d
VM_IP=192.168.122.10
VM_VCPUS=3
VM_MEMMIB=4096
ROOT_GIB=20
VM_USER=jordan
# fix 3 — IMMUTABLE dated build, never the moving 'latest' pointer: if
# upstream rebuilds, this URL 404s loudly instead of silently swapping bytes.
IMG_NAME=debian-13-genericcloud-amd64-20261103-2651.qcow2
IMG_BASE_URL=https://cloud.debian.org/images/cloud/trixie/20261103-2651
BASE_IMG=/var/lib/libvirt/images/$IMG_NAME
ROOT_IMG=/var/lib/libvirt/images/media-vm-root.qcow2
SEED_ISO=/var/lib/libvirt/images/media-vm-seed.iso
MEDIA_LV=/dev/ubuntu-vg/media
# fix 3 — SHA512 digest OF RECORD, recorded at artifact-write time (2026-11-09).
# cloud.debian.org publishes NO GPG-signed SHA512SUMS.sign (verified 404 on
# 2026-11-09), so THIS embedded pin is the fail-closed authenticity anchor:
# downloads are verified against it before anything is promoted, and an
# in-use base image is never deleted on mismatch. The upstream SHA512SUMS
# fetched next to the image is an advisory CROSS-REFERENCE only.
EXPECTED_SHA512=d25999de0770d4cde1be72c299ba3ad94eac7ea8fd4d18f8cc86c69df69337e2e8a91d64465a9bfd8f2a78c566fcbcb0842eacc91c09efdef72d719d9f13b535

# ---- secrets/config of record -----------------------------------------------
DEB_DIR=/etc/media-vm
DEB_KEY="$DEB_DIR/deploy_ed25519"
DEB_PUB="$DEB_KEY.pub"
VPN_ENV_HOST="$DEB_DIR/vpn.env"        # user fills provider creds HERE
VPN_ENV_VM="/opt/media-stack/vpn.env"  # synced into media-vm (600 root)
MEDIA_ASSISTANT_ENV=/opt/media-assistant/.env

# ---- host LAN exposure units -------------------------------------------------
PROXY_SOCKET=/etc/systemd/system/jellyfin-lan-proxy.socket
PROXY_SERVICE=/etc/systemd/system/jellyfin-lan-proxy.service
DISCO_SERVICE=/etc/systemd/system/jellyfin-discovery.service
# fix 31 — DISCOVERY_MODE=pinned|broadcast (default: pinned -> 192.168.1.133)
DISCOVERY_MODE="${DISCOVERY_MODE:-pinned}"
# fix 30 — libvirt network hook path for media-vm-lan-guard on reboot/net-start
LIBVIRT_HOOK_DIR=/etc/libvirt/hooks
LIBVIRT_NET_HOOK=/etc/libvirt/hooks/network

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Phase 5 must be run as root (login as root, then: bash $0)." >&2
    exit 1
fi

# fix 12 — refuse to run if the log dir or any log file path is a SYMLINK: a
# planted link would make root's writes/ownership changes follow it onto any
# target (e.g. /etc/shadow). Checked BEFORE anything is created.
for LCHK in "$LOGDIR" "$LOG" "$LOG.apt" "$LOG.vi"; do
    if [ -L "$LCHK" ]; then
        echo "FATAL: $LCHK is a symlink — refusing to run (symlink-takeover guard)." >&2
        echo "       Remove the link manually (rm -f $LCHK) and re-run." >&2
        exit 1
    fi
done

# fix 12 — root-owned log directory, 750 root:root.
install -d -m 750 -o root -g root "$LOGDIR"

# fix 12 — preflight: the SCRIPT FILE and $COMPOSE_SRC must be the ROOT-OWNED
# copies in $SCRIPT_DIR: never group/world-writable, never a symlink. Scripts
# and data sourced by root from a jordan-writable path are a takeover vector.
RAW_SELF="${BASH_SOURCE[0]:-$0}"
print_copy_instructions() {
    echo "       Fix (run these AS ROOT — no sudo needed):"
    echo "         install -d -m 0755 -o root -g root /usr/local/sbin/phase5"
    echo "         install -o root -g root -m 0755 <source-dir>/phase5_apply.sh \\"
    echo "              /usr/local/sbin/phase5/phase5_apply.sh"
    echo "         install -o root -g root -m 0644 <source-dir>/phase5_compose.yaml \\"
    echo "              /usr/local/sbin/phase5/phase5_compose.yaml"
    echo "         install -o root -g root -m 0755 <source-dir>/phase5_guardrail_test.sh \\"
    echo "              /usr/local/sbin/phase5/phase5_guardrail_test.sh"
    echo "         install -o root -g root -m 0755 <source-dir>/phase5_diag.sh \\"
    echo "              /usr/local/sbin/phase5/phase5_diag.sh"
    echo "       Then run: bash /usr/local/sbin/phase5/phase5_apply.sh"
}
# fix 24 — also check the directory /usr/local/sbin/phase5 ($SCRIPT_DIR) itself
# (must exist, not be a symlink, be root:root, and not be group/world-writable)
# and use bitwise octal `(( 8#${SELF_MODE} & 8#022 ))` instead of `-ge 2` so
# standard read/exec modes like 0755 or 0644 (digits 4 and 5) are accepted
# while any write bit (2, 3, 6, 7) in group or other is rejected.
if [ -L "$SCRIPT_DIR" ] || [ ! -d "$SCRIPT_DIR" ]; then
    echo "FATAL: $SCRIPT_DIR is missing or a symlink — refusing to run." >&2
    print_copy_instructions
    exit 1
fi
if [ "$(stat -c '%u:%g' "$SCRIPT_DIR" 2>/dev/null)" != "0:0" ]; then
    echo "FATAL: $SCRIPT_DIR is not owned by root:root ($(stat -c '%U:%G' "$SCRIPT_DIR" 2>/dev/null))." >&2
    print_copy_instructions
    exit 1
fi
DIR_MODE="$(stat -c '%a' "$SCRIPT_DIR" 2>/dev/null)"
if [ -n "$DIR_MODE" ]; then
    if (( 8#${DIR_MODE} & 8#022 )); then
        echo "FATAL: $SCRIPT_DIR is group/world-writable (mode $DIR_MODE) — refusing." >&2
        print_copy_instructions
        exit 1
    fi
fi
for SRC_CHK in "$RAW_SELF" "$COMPOSE_SRC"; do
    if [ -L "$SRC_CHK" ]; then
        echo "FATAL: $SRC_CHK is a symlink — refusing to run root code from a linked path." >&2
        print_copy_instructions
        exit 1
    fi
    if [ ! -e "$SRC_CHK" ]; then
        echo "FATAL: $SRC_CHK does not exist." >&2
        print_copy_instructions
        exit 1
    fi
    if [ "$(stat -c '%u:%g' "$SRC_CHK" 2>/dev/null)" != "0:0" ]; then
        echo "FATAL: $SRC_CHK is not owned by root ($(stat -c '%U:%G' "$SRC_CHK" 2>/dev/null));" >&2
        echo "       root must never execute a jordan-owned copy." >&2
        print_copy_instructions
        exit 1
    fi
    SELF_MODE="$(stat -c '%a' "$SRC_CHK" 2>/dev/null)"
    if [ -n "$SELF_MODE" ]; then
        # fix 24 — bitwise octal test for group/other write bits (022)
        if (( 8#${SELF_MODE} & 8#022 )); then
            echo "FATAL: $SRC_CHK is group/world-writable (mode $SELF_MODE) — refusing." >&2
            print_copy_instructions
            exit 1
        fi
    fi
done
# fix 28 — check companion scripts in /usr/local/sbin/phase5/ (warn if not
# installed yet; fail closed if present and symlinked, non-root, or writable).
for COMP_CHK in "$SCRIPT_DIR/phase5_guardrail_test.sh" "$SCRIPT_DIR/phase5_diag.sh"; do
    if [ -L "$COMP_CHK" ]; then
        echo "FATAL: companion script $COMP_CHK is a symlink — refusing." >&2
        print_copy_instructions
        exit 1
    elif [ -e "$COMP_CHK" ]; then
        if [ "$(stat -c '%u:%g' "$COMP_CHK" 2>/dev/null)" != "0:0" ]; then
            echo "FATAL: companion script $COMP_CHK is not owned by root:root ($(stat -c '%U:%G' "$COMP_CHK" 2>/dev/null))." >&2
            print_copy_instructions
            exit 1
        fi
        SELF_MODE="$(stat -c '%a' "$COMP_CHK" 2>/dev/null)"
        if [ -n "$SELF_MODE" ]; then
            if (( 8#${SELF_MODE} & 8#022 )); then
                echo "FATAL: companion script $COMP_CHK is group/world-writable (mode $SELF_MODE) — refusing." >&2
                print_copy_instructions
                exit 1
            fi
        fi
    else
        echo "WARN: companion script $COMP_CHK not installed yet (install into $SCRIPT_DIR as root:root 0755)." >&2
    fi
done
if [ ! -f "$COMPOSE_SRC" ]; then
    echo "FATAL: $COMPOSE_SRC missing — cannot push the compose spec." >&2
    print_copy_instructions
    exit 1
fi

# fix 11 + fix 12 — pre-create all three logs INSIDE the root-owned LOGDIR
# (root:root 640) BEFORE exec tee: a mid-run exit must never strand an
# unreadable or vanished log, and must never chown/chmod on a jordan path.
for LF in "$LOG" "$LOG.apt" "$LOG.vi"; do
    if [ ! -f "$LF" ]; then
        install -m 640 -o root -g root /dev/null "$LF"
    else
        chown root:root "$LF" 2>/dev/null || true
        chmod 640 "$LF" 2>/dev/null || true
    fi
done

# fix 12 + fix 26 — grant jordan traversal (`x` only, no directory list `r`)
# on $LOGDIR (mode 750 root:root + `setfacl -m u:jordan:x "$LOGDIR"`, or
# fallback `chgrp adm "$LOGDIR"` mode 750) AND read access (`u:jordan:r`) on
# each log file (root:root 640, fallback root:adm 640). Without `x` on $LOGDIR,
# a 750 root:root directory blocks `jordan` from reaching the file ACL inside.
grant_log_read() {
    local lf
    if [ -d "$LOGDIR" ] && [ ! -L "$LOGDIR" ]; then
        chown root:root "$LOGDIR" 2>/dev/null || true
        chmod 750 "$LOGDIR" 2>/dev/null || true
        if command -v setfacl >/dev/null 2>&1 && setfacl -m u:jordan:x "$LOGDIR" 2>/dev/null; then
            :
        else
            chgrp adm "$LOGDIR" 2>/dev/null || true
            chmod 750 "$LOGDIR" 2>/dev/null || true
        fi
    fi
    for lf in "$@"; do
        [ -f "$lf" ] || continue
        chown root:root "$lf" 2>/dev/null || true
        chmod 640 "$lf" 2>/dev/null || true
        if command -v setfacl >/dev/null 2>&1 && setfacl -m u:jordan:r "$lf" 2>/dev/null; then
            :
        else
            chgrp adm "$lf" 2>/dev/null || true
            chmod 640 "$lf" 2>/dev/null || true
        fi
    done
}
grant_log_read "$LOG" "$LOG.apt" "$LOG.vi"

# fix 39 — NEVER truncate the log of record. Rotate at 10 MiB (keeping exactly
# one previous run) and append a delimited header for this run instead of
# letting `tee` (without -a) wipe every earlier run.
LOG_SIZE="$(stat -c %s "$LOG" 2>/dev/null || echo 0)"
case "$LOG_SIZE" in ''|*[!0-9]*) LOG_SIZE=0 ;; esac
if [ "$LOG_SIZE" -gt 10485760 ]; then
    mv -f "$LOG" "$LOG.1"
    install -m 640 -o root -g root /dev/null "$LOG"
    grant_log_read "$LOG" "$LOG.1"
    echo "  [rotate]  $LOG exceeded 10 MiB -> previous run kept at $LOG.1" >&2
fi

HOST="$(hostname)"
STAMP="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# fix 39 — append, never overwrite. The header is written before the tee
# redirect so it lands at the top of THIS run's section.
printf '\n===== Phase 5 run %s on %s (euid %s) =====\n' \
    "$STAMP" "$HOST" "$(id -u)" >>"$LOG"
exec > >(tee -a "$LOG") 2>&1

# fix 1 — root-only working dir under /run via mktemp (never a predictable,
# world-readable /tmp path), umask 077 for everything this script creates.
# Shredded + removed on EVERY exit path via the EXIT trap.
umask 077
WORKDIR="$(mktemp -d /run/p5-apply.XXXXXX)"
cleanup_workdir() {
    find "$WORKDIR" -type f -exec shred -u {} >/dev/null 2>&1 \; 2>/dev/null || true
    rm -rf "$WORKDIR" 2>/dev/null || true
}
trap cleanup_workdir EXIT

section() { echo; echo "=============================================================="; echo " $*"; echo "=============================================================="; }
sub()    { echo; echo "----- $* -----"; }

FAILS=0
pass() { echo "  [PASS] $*"; }
fail() { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
note() { echo "  [note] $*"; }

# --- masked .env + vpn.env line-shape validator -----------------------------
# Every non-comment line must be a clean VAR=value: no ' #', no edge
# whitespace, no empty value when the line is being used as a value line.
# Re-used for /etc/media-vm/vpn.env and /opt/media-assistant/.env (V7).
# NEVER echoes values — only counts + var names.
env_lint() {
    local file="$1"
    if [ ! -f "$file" ]; then
        note "$(basename "$file") missing — skipped"
        return 2
    fi
    local bad=0 ln_no=0 line tline var value flags
    while IFS= read -r line || [ -n "$line" ]; do
        ln_no=$((ln_no + 1))
        if [ -z "${line//[[:space:]]/}" ] || [[ "$line" =~ ^[[:space:]]*# ]]; then
            continue
        fi
        tline="${line#"${line%%[![:space:]]*}"}"
        var="${tline%%=*}"
        if [[ "$tline" != *=* ]] || [[ ! "$var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            echo "  [FAIL] $file line $ln_no: not a clean VAR=value line — review manually"
            bad=1
            continue
        fi
        value="${tline#*=}"
        flags=""
        if [ -z "$value" ]; then
            flags="[EMPTY]"
        else
            if [[ "$value" =~ [[:space:]]+# ]]; then flags="$flags [CONTAINS-HASH]"; fi
            if [[ "$value" =~ ^[[:space:]] ]];     then flags="$flags [LEADING-SPACE]"; fi
            if [[ "$value" =~ [[:space:]]$ ]];     then flags="$flags [TRAILING-SPACE]"; fi
            # fix 52 — WireGuard-ready value checks (masked): AirVPN exports
            # carry "10.x.x.x/32, fd7d:.../128" and may arrive quoted. gluetun
            # v3.40 exits 1 on an IPv6 interface address when the VM has IPv6
            # disabled, so flag BOTH shapes before a push.
            if [ "$var" = "WIREGUARD_ADDRESSES" ] && [[ "$value" =~ [,:] ]]; then
                flags="$flags [IPV6-OR-MULTI-ADDR-UNSUPPORTED]"
            fi
            if [[ "$value" =~ ^\".*\"$ || "$value" =~ ^\'.*\'$ ]]; then
                flags="$flags [QUOTED-VALUE]"
            fi
        fi
        if [ -n "$flags" ]; then
            echo "  [FAIL] $file line $ln_no: $var — systemd/compose would mis-read:$flags (value NOT echoed)"
            bad=1
        fi
    done <"$file"
    if [ "$bad" -eq 0 ]; then
        echo "  [PASS] $(basename "$file"): all non-comment lines are clean VAR=value (values NOT echoed)"
    fi
    return "$bad"
}

# --- fix 52: normalize the host vpn.env in place (atomic, values NEVER echoed)
# AirVPN exports look like "PrivateKey = <key>" with "Address = 10.x/32, fd7d:…";
# a hand-converted line can keep a space after '=' or surrounding quotes.
# docker compose's env_file parser tolerates that (godotenv trims), but
# env_lint correctly refuses it — which left a WORKING tunnel unpushable and
# diag S10 permanently red. Strip ONLY edge whitespace/quotes, the IPv6 tail and
# CR line endings; never touch key material. Echoes: changed | same | skip.
vpn_env_normalize() {
    local file="$1" dir tmp
    [ -f "$file" ] || { echo skip; return 0; }
    dir="$(dirname "$file")"
    tmp="$(umask 077; mktemp "$dir/.vpn.env.norm.XXXXXX")" || { echo skip; return 0; }
    sed -E \
        -e 's/\r$//' \
        -e 's/^[[:space:]]+//' \
        -e 's/^([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*/\1=/' \
        -e 's/^(WIREGUARD_(PRIVATE|PRESHARED)_KEY=)"(.*)"$/\1\3/' \
        -e "s/^(WIREGUARD_(PRIVATE|PRESHARED)_KEY=)'(.*)'\$/\\1\\3/" \
        -e 's/^(WIREGUARD_ADDRESSES=[^,]*),.*$/\1/' \
        -e 's/[[:space:]]+$//' \
        "$file" >"$tmp" 2>/dev/null
    if cmp -s "$tmp" "$file"; then
        rm -f "$tmp"
        echo same
        return 0
    fi
    chown --reference="$file" "$tmp" 2>/dev/null || chown root:root "$tmp"
    chmod --reference="$file" "$tmp" 2>/dev/null || chmod 600 "$tmp"
    if mv -f "$tmp" "$file"; then
        echo changed
    else
        rm -f "$tmp"
        echo skip
    fi
}

# --- append_env FILE KEY VALUE — append-only .env writer --------------------
# Same contract as Phase 4's add_secret: never overwrite an existing real
# value; ensure a trailing newline exists before appending; keep every line
# pristine VAR=value (the Phase 3 systemd line-shape lesson); never echo.
append_env() {
    local file="$1" key="$2" value="$3"
    if [ -z "$value" ]; then
        echo "  [skip]    $key: no value available — NOT written"
        return 1
    fi
    if grep -qE "^${key}=[^[:space:]#]" "$file" 2>/dev/null; then
        echo "  [keep]    $key already has a real value (NOT overwritten)"
        return 0
    fi
    if [ ! -s "$file" ] || [ "$(tail -c 1 "$file" | od -An -c | tr -d ' \n')" != "\n" ]; then
        printf '\n' >>"$file"
    fi
    printf '%s=%s\n' "$key" "$value" >>"$file"
    echo "  [added]   $key appended to $file (value NEVER echoed)"
}

# --- ssh helpers to media-vm (fix 10: dedicated known_hosts file; fix 11: a
# verbose variant so real stderr is never swallowed on critical steps) --------
DEB_KH="$DEB_DIR/known_hosts"
ssh_opts=(-i "$DEB_KEY" -o IdentitiesOnly=yes -o UserKnownHostsFile="$DEB_KH"
          -o StrictHostKeyChecking=accept-new -o ConnectTimeout=6)
vmrun()  { ssh "${ssh_opts[@]}" "$VM_USER@$VM_IP" "$@" 2>/dev/null; }  # quiet: probes
vmrunv() { ssh "${ssh_opts[@]}" "$VM_USER@$VM_IP" "$@"; }             # verbose: uploads/setup/compose
vmscp()  { scp -q "${ssh_opts[@]}" "$@" 2>/dev/null; }

# fix 14 + fix 34 — stderr of the log could leak credentials (docker compose
# env-file parse errors or YAML/wg output). Everything verbose that can
# plausibly echo variables is piped through this mask before it reaches tee.
# fix 34: also mask `<name>: <long base64-looking value>` (40+ chars of
# [A-Za-z0-9+/=]), such as WireGuard keys or bearer/API tokens in YAML output.
mask_secrets() {
    sed -E \
        -e 's/((KEY|PASSWORD|TOKEN|SECRET|PRIVATE)[A-Z_]*=).*/\1***/I' \
        -e 's/([A-Za-z0-9_.-]+:[[:space:]]+)[A-Za-z0-9+/=]{40,}([[:space:]]*)$/\1***\2/g'
}

# ======================================================================
section "Phase 5 — KVM media-vm + media stack + torrent kill-switch"
echo " host   : $HOST"
echo " utc    : $STAMP"
echo " euid   : $(id -u) ($(id -un))"
echo " log    : $LOG"
# fix 14 — the log is secret-masked as it flows through tee, but hostnames
# and IPs are NOT masked and MAY still appear (they are not secrets).
echo " masking: credential-shaped values (KEY/PASSWORD/TOKEN/SECRET/PRIVATE*=" \
     ")-> *** ; hostnames/IPs still present"
echo
echo " SAFETY WARNING — read before continuing:"
echo "   * ADDITIVE + IDEMPOTENT: re-running converges to the same state."
echo "   * Installs KVM/libvirt (apt) — first-time network operation."
echo "   * Creates media-vm (3 vCPU / $VM_MEMMIB MiB) with a SHA512-verified"
echo "     Debian 13 (trixie) cloud image root disk and the RAW 90G"
echo "     /dev/ubuntu-vg/media passthrough as a virtio disk with"
echo "     serial=media-data-lv (guest device /dev/disk/by-id/virtio-"
echo "     media-data-lv — never a volatile /dev/vdX name). On the HOST the"
echo "     media LV stays unmounted (never formatted or mounted there)."
echo "   * Inside media-vm: ext4 /data (hardlink layout), docker.io from"
echo "     Debian apt (NO get.docker.com), ufw hardened, compose stack in"
echo "     /opt/media-stack. The 7 clearnet apps start immediately;"
echo "     gluetun + qbittorrent start ONLY with real vpn.env credentials."
echo "   * LAN exposure = Jellyfin + family requests UI: clawbox:8096 -> 192.168.122.10:8096"
echo "     via systemd-socket-proxyd (always pinned to 192.168.1.133), a 7359/udp"
echo "     discovery relay (DISCOVERY_MODE=$DISCOVERY_MODE), and Caddy https://192.168.1.133:8443"
echo "     -> 192.168.122.10:5055 (LAN subnet only; *arr/qBt admin UIs stay off-LAN)."
echo "   * Appends harvested API keys to /opt/media-assistant/.env"
echo "     (append-only, 600 mediabot:mediabot, never echoed; Phase 6 wiring)."
echo "   * Phases 1–4 (ssh/UFW posture, LVM, litellm, hermes) are preserved;"
echo "     V9/V10 verify that read-only."
echo "   * A first apply needs ~10–20 min: apt, ~325M image download,"
echo "     VM boot, docker pulls."
echo "   * SECURITY: until the FIRST Jellyfin admin account is created in the"
echo "     setup wizard, ANY LAN device can claim http://192.168.1.133:8096 —"
echo "     complete the wizard immediately after this apply."
echo "=============================================================="

# --- hard preconditions --------------------------------------------------------
if ! id mediabot >/dev/null 2>&1; then
    echo "FATAL: 'mediabot' user missing (Phase 2 should have created it)." >&2
    exit 1
fi
echo "  [ok]      'mediabot' user present (uid $(id -u mediabot))"
if [ ! -e /dev/kvm ]; then
    echo "FATAL: /dev/kvm missing — AMD-V disabled in firmware?" >&2
    exit 1
fi
echo "  [ok]      /dev/kvm present"
if ! lvs --noheadings -o lv_name "$MEDIA_LV" >/dev/null 2>&1 || [ ! -b "$MEDIA_LV" ]; then
    echo "FATAL: $MEDIA_LV (90G media LV) missing — Phase 1 state changed?" >&2
    exit 1
fi
echo "  [ok]      $MEDIA_LV block device present"
# fix 6 — label-aware gate: raw is the fresh state; an ext4 filesystem with
# OUR media-data label is the expected state after media-vm formatted it on a
# previous run (the host still NEVER mounts it). Anything else is fatal.
# fix 23 — deeper probe: blkid -p (low-level: sees partition tables and any
# signature a plain blkid miss reports as empty) + wipefs -n (dry-run
# signature scan). Any partition table or signature that is NOT our
# ext4+media-data is FATAL — the host never mounts or repurposes this LV.
LV_TYPE="$(blkid -o value -s TYPE "$MEDIA_LV" 2>/dev/null || true)"
LV_LABEL="$(blkid -o value -s LABEL "$MEDIA_LV" 2>/dev/null || true)"
LV_POUT="$(blkid -p "$MEDIA_LV" 2>/dev/null || true)"
LV_WOUT="$(wipefs -n "$MEDIA_LV" 2>/dev/null || true)"
if [ -z "$LV_TYPE" ] && [ -z "$LV_LABEL" ]; then
    if [ -n "$LV_POUT" ] || [ -n "$LV_WOUT" ]; then
        echo "FATAL: $MEDIA_LV carries a signature that blkid -o value did NOT report (fix 23):" >&2
        echo "       blkid -p : ${LV_POUT:-<empty>}" >&2
        echo "       wipefs -n: ${LV_WOUT:-<empty>}" >&2
        echo "       — not raw and not ours; refusing to passthrough. Review manually." >&2
        exit 1
    fi
    echo "  [ok]      media LV is raw (blkid -p + wipefs -n both clean — passthrough safe)"
elif [ "$LV_TYPE" = "ext4" ] && [ "$LV_LABEL" = "media-data" ] \
     && virsh dominfo "$VM_NAME" >/dev/null 2>&1 \
     && ! grep -q 'PTTYPE' <<<"$LV_POUT"; then
    echo "  [ok]      media LV holds the VM-created media-data ext4 ($VM_NAME owns it;"
    echo "            blkid -p/wipefs -n show no foreign signature or partition table;"
    echo "            host still NEVER mounts it — passthrough state of record)"
else
    echo "FATAL: $MEDIA_LV has a filesystem on the HOST (type=${LV_TYPE:-?} label=${LV_LABEL:-none})" >&2
    echo "       that is NOT ours (blkid -p: ${LV_POUT:-<empty>}) — refusing to passthrough." >&2
    echo "       Review lvs/blkid/wipefs manually." >&2
    exit 1
fi

# fix 16 — never let ANY host-side block-device helper (desktop automount,
# udisks2, mount helpers) mount the media LV on the HOST: a persistent udev
# rule hides it from udisks (UDISKS_IGNORE), keyed on the stable DM_NAME the
# device-mapper registers for the ubuntu-vg/media LV (ubuntu--vg-media).
UDEV_RULE=/etc/udev/rules.d/99-media-lv.rules
cat >"$UDEV_RULE" <<'UDEVEOF'
ACTION=="add|change", ENV{DM_NAME}=="ubuntu--vg-media", ENV{UDISKS_IGNORE}="1"
UDEVEOF
chown root:root "$UDEV_RULE"; chmod 644 "$UDEV_RULE"
if udevadm control --reload >/dev/null 2>&1 \
   && udevadm trigger --name-match=/dev/ubuntu-vg/media >/dev/null 2>&1; then
    echo "  [ok]      udev rule installed: /etc/udev/rules.d/99-media-lv.rules"
    echo "            (UDISKS_IGNORE on DM_NAME=ubuntu--vg-media — host auto-mount blocked)"
else
    echo "  *** WARN: udevadm reload/trigger failed (fix 16) — rule written but untested;"
    echo "  ***       verify with: udevadm info /dev/ubuntu-vg/media | grep -i udisks"
fi

# ======================================================================
sub "APPLY 1/7 — apt packages (KVM/libvirt tooling, seed builder, socat, acl)"
PKGS=(qemu-system-x86 libvirt-daemon-system libvirt-clients virtinst
      cloud-image-utils genisoimage dnsmasq-base socat python3-yaml acl
      caddy libnss3-tools)
NEED_APT=()
for p in "${PKGS[@]}"; do
    if ! dpkg -s "$p" >/dev/null 2>&1; then NEED_APT+=("$p"); fi
done
if [ "${#NEED_APT[@]}" -gt 0 ]; then
    echo "  [install] apt-get update + apt-get install -y ${NEED_APT[*]}"
    if apt-get update >>"$LOG.apt" 2>&1 && apt-get install -y "${NEED_APT[@]}" >>"$LOG.apt" 2>&1; then
        echo "  [done]    apt install complete (detailed log: $LOG.apt)"
    else
        echo "  *** WARN: apt install FAILED (offline / mirror unreachable?)."
        echo "  ***       tail: $(tail -3 "$LOG.apt" 2>/dev/null | tr '\n' ' ' | cut -c1-160)"
        echo "  ***       Re-run once online — everything else still fails soft."
    fi
else
    echo "  [ok]      all required packages already installed"
fi
# fix 26 — re-apply $LOGDIR traversal ACL (u:jordan:x) now that `acl` is installed
grant_log_read "$LOG" "$LOG.apt" "$LOG.vi"
if ! command -v virsh >/dev/null 2>&1 || ! command -v virt-install >/dev/null 2>&1; then
    echo "FATAL: libvirt clients/virtinst still absent — cannot provision media-vm."
    echo "       Fix network/apt and re-run." >&2
    exit 1
fi
echo "  [ok]      virsh ($(virsh --version 2>/dev/null)) + virt-install available"

# ======================================================================
sub "APPLY 2/7 — libvirt service + default network + static DHCP reservation"
if systemctl is-active --quiet libvirtd; then
    echo "  [ok]      libvirtd already active"
else
    systemctl enable --now libvirtd >/dev/null 2>&1 || true
    sleep 2
    if systemctl is-active --quiet libvirtd; then
        echo "  [ok]      libvirtd started + enabled"
    else
        echo "FATAL: libvirtd failed to start — journalctl -u libvirtd" >&2
        exit 1
    fi
fi
if virsh net-info default >/dev/null 2>&1; then
    if ! virsh net-info default 2>/dev/null | grep -q "^Active:.*yes"; then
        virsh net-start default >/dev/null && echo "  [ok]      default network started"
    fi
    virsh net-autostart default >/dev/null 2>&1 && echo "  [ok]      default network autostart on"
else
    # fix 32 — root-only host wording (no sudo on clawbox)
    echo "  *** WARN: default network undefined — define it as root and re-run:"
    echo "  ***       virsh net-define /usr/share/libvirt/networks/default.xml"
fi
if virsh net-dumpxml default 2>/dev/null | grep -q "$VM_MAC"; then
    echo "  [ok]      static DHCP host already present ($VM_MAC -> $VM_IP)"
else
    if virsh net-update default add ip-dhcp-host \
        "<host mac='$VM_MAC' name='$VM_NAME' ip='$VM_IP'/>" --live --config >/dev/null 2>&1; then
        echo "  [ok]      static DHCP reservation added: $VM_MAC -> $VM_IP"
    else
        echo "  *** WARN: net-update failed (running libvirt network must have DHCP range);"
        echo "  ***       re-run this script once 'virsh net-dumpxml default' works."
    fi
fi

# ======================================================================
sub "APPLY 3/7 — deploy key + vpn.env skeleton (secrets of record)"
mkdir -p "$DEB_DIR"
chown root:root "$DEB_DIR"; chmod 700 "$DEB_DIR"
if [ ! -f "$DEB_KEY" ]; then
    ssh-keygen -t ed25519 -N "" -f "$DEB_KEY" -C "systembuild-phase5-deploy" -q
    echo "  [created] $DEB_KEY (600) — host-only deploy key for media-vm"
else
    echo "  [ok]      deploy key present ($DEB_KEY)"
fi
chmod 600 "$DEB_KEY" "$DEB_PUB" 2>/dev/null
# fix 10 — dedicated known_hosts for the deploy channel: the VM's host key
# lives HERE (never in root's or jordan's personal known_hosts); a VM rebuild
# resets exactly this file, nothing else.
if [ ! -f "$DEB_KH" ]; then
    install -m 600 /dev/null "$DEB_KH"
    echo "  [created] $DEB_KH (600) — dedicated known_hosts for media-vm"
else
    chmod 600 "$DEB_KH"
    echo "  [ok]      $DEB_KH present (600)"
fi
if [ ! -f "$VPN_ENV_HOST" ]; then
    cat >"$VPN_ENV_HOST" <<'VPNEOF'
# SystemBuild Phase 5 — gluetun v3.40.0 provider credentials (u8s KILL-SWITCH)
# 600 root:root. Synced into media-vm:/opt/media-stack/vpn.env by
# phase5_apply.sh (600 root, read by the docker daemon as gluetun env_file).
#
# THIS FILE IS THE START-GATE: gluetun + qbittorrent stay DOWN while every
# line below is still commented (comment-only skeleton). gluetun and
# qbittorrent run with zero secrets when the stack is skeleton-gated.
#
# Fill ONE VAR=value per line (Phase 3 lesson: NO trailing '#' comments, no
# edge whitespace — remove only the leading '#', then re-run phase5_apply.sh,
# which detects real values and brings up the vpn compose profile).
#
# Choose your provider and uncomment/fill the matching lines:
#   VPN_SERVICE_PROVIDER=
#   VPN_TYPE=wireguard
#   WIREGUARD_PRIVATE_KEY=
#   WIREGUARD_ADDRESSES=
#   SERVER_HOSTNAMES=
#   WIREGUARD_ENDPOINT_PORT= (optional)
#
# OpenVPN-based providers instead use:
#   VPN_SERVICE_PROVIDER=
#   VPN_TYPE=openvpn
#   OPENVPN_USER=
#   OPENVPN_PASSWORD=
#
# SERVER_COUNTRIES= and SERVER_CITIES= are optional selectors for either type.
VPNEOF
    chown root:root "$VPN_ENV_HOST"; chmod 600 "$VPN_ENV_HOST"
    echo "  [created] $VPN_ENV_HOST (600, comment-only skeleton)"
else
    chown root:root "$VPN_ENV_HOST" 2>/dev/null; chmod 600 "$VPN_ENV_HOST"
    echo "  [ok]      vpn.env preserved (NOT overwritten) -> 600 root:root"
fi

# ======================================================================
sub "APPLY 4/7 — cloud image (pin-verified, .part staged) + VM definition + LV passthrough"
# fix 13 + fix 27 — explicitly create and enforce /var/lib/libvirt/images as
# 711 root:root (never 755): qemu traverses via execute bit (711), while
# unprivileged local users cannot list or read images inside. If an earlier
# run ever left this directory 755 or media-vm-root.qcow2 644 with real VPN
# credentials present, rotate the VPN WireGuard private key.
install -d -m 711 -o root -g root /var/lib/libvirt/images
chown root:root /var/lib/libvirt/images
chmod 711 /var/lib/libvirt/images
# fix 19 — the download is staged as ${BASE_IMG}.part INSIDE
# /var/lib/libvirt/images (same filesystem as $BASE_IMG -> atomic mv), mode
# 600 until the SHA512 pin passes. Any stale .part from a crashed earlier
# run is removed before staging. An in-use base image is NEVER deleted
# (a re-run can never break the running VM's backing file).
rm -f "${BASE_IMG}.part" 2>/dev/null || true
base_in_use() {
    virsh dominfo "$VM_NAME" >/dev/null 2>&1 && return 0
    [ -f "$ROOT_IMG" ] && qemu-img info "$ROOT_IMG" 2>/dev/null | grep -q "^backing file"
}
if [ ! -f "$BASE_IMG" ]; then
    echo "  [install] downloading $IMG_NAME from the immutable dated build dir"
    echo "            ($IMG_BASE_URL — never the moving 'latest' pointer)"
    install -m 600 -o root -g root /dev/null "${BASE_IMG}.part" 2>/dev/null || true
    if ! curl -fsSL --retry 3 -o "${BASE_IMG}.part" "$IMG_BASE_URL/$IMG_NAME"; then
        echo "  *** WARN: image download FAILED (offline?). Nothing else can proceed;" >&2
        echo "  ***       re-run this script when online. media-vm not created." >&2
        exit 1
    fi
    echo "  [done]    downloaded $(du -h "${BASE_IMG}.part" | cut -f1) (staged .part 600 — unverified)"
    HAVE="$(sha512sum "${BASE_IMG}.part" | awk '{print $1}')"
    if [ "$HAVE" != "$EXPECTED_SHA512" ]; then
        echo "FATAL: staged image digest does NOT match the embedded pin — fail-closed;" >&2
        echo "       nothing was promoted or replaced (staging .part is removed below)." >&2
        echo "       have: $HAVE" >&2
        echo "       pin : $EXPECTED_SHA512" >&2
        rm -f "${BASE_IMG}.part" 2>/dev/null || true
        exit 1
    fi
    chmod 644 "${BASE_IMG}.part"   # fix 19 — public base image only AFTER verification
    mv -f "${BASE_IMG}.part" "$BASE_IMG"   # fix 19 — atomic promotion
    echo "  [ok]      staged image matches the embedded SHA512 pin -> promoted to $BASE_IMG"
else
    HAVE="$(sha512sum "$BASE_IMG" | awk '{print $1}')"
    if [ "$HAVE" = "$EXPECTED_SHA512" ]; then
        echo "  [ok]      base cloud image present + matches the embedded SHA512 pin: $BASE_IMG"
    elif base_in_use; then
        echo "FATAL: $BASE_IMG no longer matches the pin AND $ROOT_IMG / the $VM_NAME" >&2
        echo "       domain depends on it — NOT deleting (fail-closed). Investigate:" >&2
        echo "       have: $HAVE" >&2
        echo "       pin : $EXPECTED_SHA512" >&2
        exit 1
    else
        echo "FATAL: $BASE_IMG fails the pin and nothing depends on it — removed;" >&2
        echo "       re-run this script to re-download the verified dated build." >&2
        rm -f "$BASE_IMG"
        exit 1
    fi
fi
# --- upstream SHA512SUMS cross-reference (fix 3: advisory ONLY — the embedded
# pin is the authenticity anchor; cloud.debian.org publishes no signed sums) ---
if curl -fsSL --retry 3 -o "$WORKDIR/SHA512SUMS" "$IMG_BASE_URL/SHA512SUMS"; then
    WANT="$(grep -F " $IMG_NAME" "$WORKDIR/SHA512SUMS" | head -n1 | awk '{print $1}')"
    if [ -n "$WANT" ] && [ "$WANT" = "$EXPECTED_SHA512" ]; then
        echo "  [ok]      upstream SHA512SUMS agrees with the embedded pin (cross-ref)"
    else
        echo "  *** WARN: upstream SHA512SUMS entry (${WANT:-absent}) disagrees with the pin —"
        echo "  ***       dated build dirs are immutable, so investigate the mirror;"
        echo "  ***       the embedded pin remains the anchor (already verified above)."
    fi
else
    echo "  [note]    upstream SHA512SUMS unreachable — pin verification already passed"
fi
# --- seed ISO (cloud-init) ---
if [ ! -f "$SEED_ISO" ]; then
    DEPLOY_PUB="$(cat "$DEB_PUB")"
    cat >"$WORKDIR/user-data" <<USEREOF
#cloud-config
# SystemBuild Phase 5 — media-vm (Debian 13 trixie genericcloud) first-boot.
# fix 35: this heredoc is deliberately UNQUOTED so \$DEPLOY_PUB expands. Never
# put backticks or stray \$ here: bash would execute them as root and inject
# command output into the cloud-config (breaking YAML and the SSH key).
# fix 37: user 'jordan' = uid 1000, ADMINISTRATION/LOGIN ONLY. The media stack
# runs as numeric PUID/PGID 1001 (no passwd entry, no sudo), so container-side
# code execution as the stack uid is not one sudo away from root in the VM.
# NOPASSWD sudo is scoped to INSIDE media-vm only (no host sudo for jordan).
# DEBIAN DELTAS vs the original Ubuntu seed: compose v2 is packaged as
# 'docker-compose' (Ubuntu names it docker-compose-v2); 'sudo' is NOT
# preinstalled in Debian genericcloud images, so it is on the package list
# explicitly (cloud-init writes its sudoers.d drop-in for the user above).
hostname: media-vm
manage_etc_hosts: true
users:
  - name: jordan
    gecos: SystemBuild admin user (media-vm only)
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: true
    ssh_authorized_keys:
      - $DEPLOY_PUB
ssh_pwauth: false
package_update: true
package_upgrade: true
packages:
  - sudo
  - docker.io
  - docker-compose
  - ufw
  - qemu-guest-agent
  - unattended-upgrades
runcmd:
  - systemctl enable --now qemu-guest-agent.service
  - systemctl enable docker.service
  - systemctl enable --now unattended-upgrades.service || true
USEREOF
    # fix 35 — fail closed on a mangled seed. An unquoted heredoc is required
    # (the deploy key must expand), so prove the result is what we intended
    # BEFORE it is burned into the seed ISO:
    #   * no backtick survived (a backtick would mean root ran a substitution)
    #   * the deploy key line is present VERBATIM
    #   * the whole document parses as YAML (python3-yaml is in PKGS)
    if [ -z "${DEPLOY_PUB:-}" ]; then
        echo "FATAL: deploy public key is empty — refusing to build the seed ISO." >&2
        exit 1
    fi
    if grep -q '`' "$WORKDIR/user-data"; then
        echo "FATAL: generated user-data contains a backtick (unquoted-heredoc" >&2
        echo "       command substitution) — refusing to build the seed ISO." >&2
        exit 1
    fi
    if ! grep -qxF "      - $DEPLOY_PUB" "$WORKDIR/user-data"; then
        echo "FATAL: generated user-data does not contain the deploy public key" >&2
        echo "       verbatim — the VM would never become reachable. Refusing." >&2
        exit 1
    fi
    if ! python3 -c 'import sys, yaml' >/dev/null 2>&1; then
        echo "FATAL: python3-yaml unavailable — cannot validate generated user-data" >&2
        echo "       (did the apt step in APPLY 1/7 fail?). Refusing to build the seed." >&2
        exit 1
    fi
    python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1]))' "$WORKDIR/user-data" \
        || { echo "FATAL: generated user-data is not valid YAML" >&2; exit 1; }
    echo "  [ok]      user-data validates as YAML; deploy key + hardening present"
    printf 'instance-id: media-vm-01\nlocal-hostname: media-vm\n' >"$WORKDIR/meta-data"
    if cloud-localds "$SEED_ISO" "$WORKDIR/user-data" "$WORKDIR/meta-data" 2>/dev/null; then
        echo "  [created] seed ISO: $SEED_ISO (cloud-localds; deploy pubkey injected)"
    else
        genisoimage -quiet -output "$SEED_ISO" -volid cidata -joliet -rock \
            "$WORKDIR/user-data" "$WORKDIR/meta-data"
        echo "  [created] seed ISO built with genisoimage (cloud-localds unavailable)"
    fi
    # fix 13 — seed ISO stays root-only: it embeds the deploy SSH pubkey but
    # root-only disks are the convention here (600; libvirt reads as root).
    chmod 600 "$SEED_ISO"
    rm -f "$WORKDIR/user-data" "$WORKDIR/meta-data"   # (trap shreds $WORKDIR anyway)
else
    chmod 600 "$SEED_ISO" 2>/dev/null || true   # fix 13 — re-assert 600 on every run
    echo "  [ok]      seed ISO already present: $SEED_ISO"
fi
# --- root overlay disk ---
if [ ! -f "$ROOT_IMG" ]; then
    if qemu-img create -f qcow2 -F qcow2 -b "$BASE_IMG" "$ROOT_IMG" "${ROOT_GIB}G" >/dev/null 2>&1; then
        chmod 600 "$ROOT_IMG"   # fix 13 — NEVER world-readable: the VM root disk carries vpn.env (WG private key)
        echo "  [created] $ROOT_IMG (${ROOT_GIB}G qcow2 overlay on the verified base, 600)"
    else
        echo "FATAL: qemu-img overlay creation failed — inspect manually." >&2
        exit 1
    fi
else
    chmod 600 "$ROOT_IMG" 2>/dev/null || true   # fix 13 — re-assert 600 on every run
    echo "  [ok]      root overlay already present: $ROOT_IMG"
fi
# --- VM definition (skip if it already exists) ---
if virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
    echo "  [ok]      domain $VM_NAME already defined (reused as-is)"
    if [ "$(virsh domstate "$VM_NAME" 2>/dev/null)" = "shut off" ]; then
        virsh start "$VM_NAME" >/dev/null 2>&1 && echo "  [ok]      $VM_NAME was shut off -> started (autostart design)"
    fi
else
    # fix 10 — fresh VM: reset ONLY the deploy channel's host-key entry (the
    # dedicated $DEB_KH file above; root's/jordan's own known_hosts untouched)
    ssh-keygen -R "$VM_IP" -f "$DEB_KH" >/dev/null 2>&1 || true
    echo "  [install] virt-install: $VM_NAME ($VM_VCPUS vCPU, $VM_MEMMIB MiB, $MEDIA_LV raw passthrough)"
    VI_CORE=(--connect qemu:///system --name "$VM_NAME" --memory "$VM_MEMMIB" \
             --vcpus "$VM_VCPUS" --cpu host-passthrough \
             --disk "path=$ROOT_IMG,format=qcow2,bus=virtio" \
             --disk "path=$MEDIA_LV,format=raw,bus=virtio,cache=none,io=native,serial=media-data-lv" \
             --disk "path=$SEED_ISO,device=cdrom" \
             --network "network=default,mac=$VM_MAC" \
             --noautoconsole --wait 0 \
             --events on_reboot=restart,on_poweroff=destroy)
    if ! virt-install --import --os-variant debian13 "${VI_CORE[@]}" >"$LOG.vi" 2>&1; then
        if ! virt-install --import --os-variant generic "${VI_CORE[@]}" >>"$LOG.vi" 2>&1; then
            echo "FATAL: virt-install failed twice — tail of $(basename $LOG.vi):" >&2
            tail -10 "$LOG.vi" >&2
            exit 1
        fi
        echo "  [note]    os-variant debian13 unavailable; used generic"
    fi
    echo "  [done]    $VM_NAME defined and started"
fi
virsh autostart "$VM_NAME" >/dev/null 2>&1 && echo "  [ok]      $VM_NAME autostart = on"

# ======================================================================
sub "APPLY 5/7 — VM bootstrap over SSH: /data ext4, ufw hardening, compose stack"
echo "  [wait]    polling SSH ($VM_USER@$VM_IP) — first boot needs pkg install time"
SSH_UP=0
# fix 38 — package_upgrade on first boot needs more headroom: poll SSH for
# up to 10 min instead of 7.5 min.
for i in $(seq 1 120); do
    if vmrun 'echo vm-up' >/dev/null 2>&1; then SSH_UP=1; break; fi
    if [ "$i" -gt 1 ]; then sleep 5; fi
done
if [ "$SSH_UP" -eq 0 ]; then
    echo "  *** WARN: SSH never came up in 10 min (still cloud-init'ing packages?)"
    echo "  ***       Lowest-risk fix: wait for first boot to finish and re-run this"
    echo "  ***       script — every step above is idempotent."
    # fix 32 — root-only host command (no sudo on clawbox)
    echo "  ***       Diagnose (as root): virsh console $VM_NAME (or virsh start)."
    HOLD_VM=1
else
    echo "  [ok]      VM reachable over SSH after try #$i"
fi
# fix 15 — SSH up does NOT mean cloud-init is done: docker.io/ufw can still be
# mid-install, so vm_setup.sh would half-apply (e.g. missing DOCKER-USER
# chain). Wait for cloud-init (max 600s, exit-code checked) and then ASSERT
# the docker binary + an active daemon before anything talks to it.
if [ "${HOLD_VM:-0}" -eq 0 ]; then
    # fix 38 — package_update + package_upgrade + docker install can exceed 10
    # min on a slow mirror, so the cloud-init wait is 15 min (was 10 min).
    echo "  [wait]    cloud-init status --wait (timeout 900s) — pkg update+upgrade must finish first"
    # fix 15 + fix 29 — timeout(1) wraps the ssh binary, and we capture the
    # SSH/cloud-init exit code separately from `mask_secrets` via PIPESTATUS[0]:
    #   0 = clean done (success)
    #   2 = recoverable warning / degraded done (success with WARN pointing to
    #       /var/log/cloud-init.log inside the VM)
    #   1 or 124 (timeout) or other non-zero = failure (HOLD_VM=1)
    CI_RC=0
    timeout 900 ssh "${ssh_opts[@]}" "$VM_USER@$VM_IP" 'sudo cloud-init status --wait' 2>&1 | mask_secrets || CI_RC="${PIPESTATUS[0]}"
    if [ "$CI_RC" -eq 2 ]; then
        echo "  *** WARN: cloud-init status --wait exited with code 2 (recoverable warning; fix 29)."
        echo "  ***       Proceeding, but inspect /var/log/cloud-init.log inside $VM_NAME."
    fi
    if [ "$CI_RC" -ne 0 ] && [ "$CI_RC" -ne 2 ]; then
        echo "  *** WARN: cloud-init failed or timed out (exit code $CI_RC; 1=error, 124=timeout; fix 15/29)." >&2
        echo "  ***       Diagnosis (as root): virsh console $VM_NAME — then inspect" >&2
        echo "  ***       /var/log/cloud-init.log and /var/log/cloud-init-output.log inside media-vm." >&2
        echo "  ***       HOLD_VM=1 set: in-VM provisioning + key harvest are SKIPPED this run." >&2
        HOLD_VM=1
    elif ! vmrun 'command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker'; then
        echo "  *** WARN: cloud-init done but docker is NOT present/active inside" >&2
        echo "  ***       media-vm (fix 15). Diagnosis: run AS ROOT on clawbox:" >&2
        echo "  ***       ssh $VM_USER@$VM_IP 'sudo systemctl status docker; dpkg -l docker.io'" >&2
        echo "  ***       (the sudo is INSIDE the VM — its jordan needs it). HOLD_VM set —"
        echo "  ***       in-VM provisioning + key harvest are skipped this run."
        HOLD_VM=1
    else
        echo "  [ok]      cloud-init done; docker present + active inside media-vm"
    fi
fi

# fix 1 + fix 33 — vm_put SRC MODE FINAL_PATH: stream the file over the
# encrypted ssh channel into a root-only temp INSIDE the VM, then atomic mv —
# no world-readable VM-side /tmp staging; secrets never appear in ps/argv.
# fix 33: pass MODE and FINAL_PATH as positional arguments to a single-quoted
# remote `sudo sh -c` script so ShellCheck (SC2029/SC2086) is clean while the
# staging path + atomic move semantics are byte-for-byte identical.
vm_put() {
    local src="$1" mode="$2" final="$3"
    local q_mode q_final
    printf -v q_mode '%q' "$mode"
    printf -v q_final '%q' "$final"
    # fix 45 — the staging umask 077 must NOT leak onto the destination
    # DIRECTORY: `mkdir -p` under umask 077 creates /opt/media-stack as
    # 0700 root:root, and jordan then cannot `cd` into it (observed on the
    # first run: "cd: /opt/media-stack: Permission denied" -> compose never
    # started). The dir holds a 644 compose file and a 600 root-only
    # vpn.env, so 0755 is safe and keeps the files themselves sealed.
    # shellcheck disable=SC2029
    vmrunv 'sudo sh -c '\''umask 077; mkdir -p "$(dirname "$2")"; chmod 0755 "$(dirname "$2")"; cat >/root/.p5-stage.tmp; chmod "$1" /root/.p5-stage.tmp; mv -f /root/.p5-stage.tmp "$2"'\'' sh' "$q_mode" "$q_final" <"$src"
}

if [ "${HOLD_VM:-0}" -eq 0 ]; then
    if vm_put "$COMPOSE_SRC" 644 /opt/media-stack/docker-compose.yml; then
        echo "  [pushed]  phase5_compose.yaml -> media-vm:/opt/media-stack/docker-compose.yml (644)"
    else
        echo "  *** WARN: could not push phase5_compose.yaml to media-vm (SSH/upload problem)"
    fi
    # fix 52 — the host vpn.env is AUTHORITATIVE once it holds real credentials.
    # Normalize its line shape in place first (AirVPN "Key = value" exports and
    # a stray space after '=' previously made every push invalid + diag red).
    VPN_ENV_CHANGED=0
    VPN_NORM_STATE="$(vpn_env_normalize "$VPN_ENV_HOST")"
    case "$VPN_NORM_STATE" in
        changed)
            VPN_ENV_CHANGED=1
            echo "  [fix 52]  normalized host vpn.env line shape (edge whitespace/quotes/IPv6 tail; values NEVER echoed)"
            ;;
        same)
            echo "  [ok]      host vpn.env line shape already clean"
            ;;
        *)
            echo "  *** WARN: could not normalize $VPN_ENV_HOST (left untouched)"
            ;;
    esac
    VM_VPN_SHA="$(vmrun "sudo sha256sum $VPN_ENV_VM 2>/dev/null | cut -d' ' -f1" | awk '{print $1}')"
    HOST_VPN_SHA="$(sha256sum "$VPN_ENV_HOST" | awk '{print $1}')"
    if [ "$VM_VPN_SHA" != "$HOST_VPN_SHA" ]; then
        if grep -qE '^VPN_SERVICE_PROVIDER=[^[:space:]#]+' "$VPN_ENV_HOST" 2>/dev/null; then
            # fix 52 — host real credentials: push the host copy when the lint is
            # clean, even if the VM copy already has (older) real values. The old
            # divergence guard silently kept a stale/invalid in-VM vpn.env.
            if env_lint "$VPN_ENV_HOST" >/dev/null 2>&1; then
                if vm_put "$VPN_ENV_HOST" 600 "$VPN_ENV_VM"; then
                    echo "  [pushed]  vpn.env -> media-vm:$VPN_ENV_VM (600 — host real credentials synced; values NEVER echoed)"
                    VPN_ENV_CHANGED=1
                else
                    echo "  *** WARN: vpn.env push to media-vm failed (SSH/upload problem)"
                fi
            else
                echo "  *** WARN: host vpn.env still fails the line-shape lint — NOT pushed"
                echo "            (run env_lint diagnostics above; values are NEVER echoed)"
            fi
        elif [ -n "$VM_VPN_SHA" ] && vmrun "test -n \"\$(sudo grep -E '^VPN_SERVICE_PROVIDER=[^[:space:]#]' $VPN_ENV_VM 2>/dev/null)\"" >/dev/null 2>&1; then
            echo "  [warn]    in-VM vpn.env holds real values while the host copy is a skeleton — left untouched"
            # fix 32 — root-only host command (no sudo on clawbox; sudo is inside VM only)
            echo "            (resolve manually as root: ssh -i $DEB_KEY $VM_USER@$VM_IP 'sudo editor /opt/media-stack/vpn.env')"
        else
            vm_put "$VPN_ENV_HOST" 600 "$VPN_ENV_VM" \
                && echo "  [pushed]  vpn.env -> media-vm:$VPN_ENV_VM (600 — skeleton sync; values NEVER echoed)"
        fi
    else
        echo "  [ok]      vpn.env in media-vm already matches the host copy (600)"
    fi

    # ---- in-VM provisioning script (literal heredoc; runs INSIDE media-vm) ----
    cat >"$WORKDIR/vm_setup.sh" <<'VMEOF'
#!/usr/bin/env bash
# fix 54 — forwarded-port canary: an empty/non-numeric value turns `--dport`
# into a syntax error and used to leave the port backstops half-applied (the
# 2026-11-15 empty-port incident). Fail before touching /data or any rule.
AIRVPN_PORT=37686
case "$AIRVPN_PORT" in
    ''|*[!0-9]*) echo "VM_SETUP_FAIL: AIRVPN_PORT is not numeric" >&2; exit 1 ;;
esac
[ "$AIRVPN_PORT" -ge 1 ] && [ "$AIRVPN_PORT" -le 65535 ] \
    || { echo "VM_SETUP_FAIL: AIRVPN_PORT out of range" >&2; exit 1; }
# ---- A. /data: resolve the media LV by its stable virtio serial (fix 6 —
# NEVER the volatile /dev/vdb name), then format ext4 ONLY when the disk is
# provably signature-free (blkid -p AND wipefs -n; fail-closed otherwise) ----
DATA_DEV=/dev/disk/by-id/virtio-media-data-lv
if [ ! -b "$DATA_DEV" ]; then
    echo "VM_SETUP_FAIL: $DATA_DEV missing — virtio serial not attached to media-vm?"
    exit 1
fi
if [ -n "$(blkid -p "$DATA_DEV" 2>/dev/null)" ] || [ -n "$(wipefs -n "$DATA_DEV" 2>/dev/null)" ]; then
    # on-disk signatures present: acceptable ONLY if they are OUR ext4
    if [ "$(blkid -p -o value -s TYPE "$DATA_DEV" 2>/dev/null)" = "ext4" ] \
       && [ "$(blkid -p -o value -s LABEL "$DATA_DEV" 2>/dev/null)" = "media-data" ]; then
        echo "media-data ext4 already present (previous run) — reusing"
    else
        echo "VM_SETUP_FAIL: $DATA_DEV holds signatures that are NOT our media-data ext4 — refusing"
        exit 1
    fi
else
    mkfs.ext4 -L media-data "$DATA_DEV"
fi
mkdir -p /data
if ! grep -qE '^[[:space:]]*LABEL=media-data' /etc/fstab; then
    printf 'LABEL=media-data /data ext4 defaults,noatime,nofail 0 2\n' >>/etc/fstab
fi
mount -a
# ---- B. directory tree + ownership (fix 37: numeric PUID/PGID 1001 — the
# stack uid has NO passwd entry and NO sudo; jordan (1000) stays admin-only) ----
mkdir -p /data/torrents/movies /data/torrents/music /data/torrents/tv \
         /data/media/movies /data/media/music /data/media/tv \
         /data/config/{gluetun,qbittorrent,prowlarr,radarr,lidarr,sonarr,bazarr,jellyfin,jellyfin-cache,jellyseerr}
chown -R 1001:1001 /data
# ---- C. qBittorrent.conf pre-seed (ONLY when absent — never overwrite).
# fix 5: correct qBt 5.x schema — the network bind, save path and listen port
# all live under [BitTorrent]/Session\* keys; the old bare [Session]/Interface
# and SessionPort keys were silently IGNORED by qBt 5.x.
# fix 72 — THE PATH MATTERS: the linuxserver image runs with $HOME=/config and
# its own service script greps `WebUI\Address` out of
# /config/qBittorrent/qBittorrent.conf, i.e. the file lives in the qBittorrent/
# SUBDIRECTORY. The old path here (without it) was a file our own pre-seed
# invented: qBittorrent never read it, so every key written to it — including
# Session\Interface and the manual-mode path switch — changed nothing while the
# read-back "verified" it. The port only worked because compose passes
# TORRENTING_PORT on the command line. ----
QBC=/data/config/qbittorrent/qBittorrent/qBittorrent.conf
QBC_LEGACY=/data/config/qbittorrent/qBittorrent.conf
mkdir -p /data/config/qbittorrent/qBittorrent
if [ ! -f "$QBC" ]; then
    cat >"$QBC" <<'QBEOF'
[BitTorrent]
Session\DefaultSavePath=/data/torrents
Session\Interface=tun0
Session\InterfaceName=tun0
Session\Port=37686
Session\UseCategoryPathsInManualMode=true
[Preferences]
WebUI\Port=8080
QBEOF
    chown 1001:1001 "$QBC"
    chmod 600 "$QBC"
fi
# fix 72 — retire the ignored duplicate. It was created by an earlier version of
# this script, qBittorrent never reads it, and keeping it has already produced
# three wrong diagnoses (apply V4, diag S3, and "the path switch reverted").
# Only removed when the real conf is present, so we can never delete the only
# copy. Its Session\*/WebUI\* lines are carried over first when the real conf
# lacks them.
if [ -f "$QBC_LEGACY" ] && [ -f "$QBC" ]; then
    LEGACY_KEYS="$(grep -aE '^(Session|WebUI)\\' "$QBC_LEGACY" 2>/dev/null || true)"
    if [ -n "$LEGACY_KEYS" ]; then
        printf '%s\n' "$LEGACY_KEYS" | while IFS= read -r line; do
            key="${line%%=*}"
            grep -qF "$key=" "$QBC" 2>/dev/null || printf '%s\n' "$line" >>"$QBC"
        done
    fi
    rm -f "$QBC_LEGACY"
    echo "qBittorrent.conf retired the ignored duplicate $QBC_LEGACY (fix 72)"
fi
# fix 52 — idempotent migration for VMs provisioned before the AirVPN
# forwarded port existed (pre-seed above is absence-guarded and never re-runs).
# fix 56 — STOP qBittorrent first. On SIGTERM it dumps its in-memory config over
# this file, so an edit made while it runs is silently reverted (and a value
# equal to libtorrent's 6881 default is omitted from that dump entirely — that
# is how the key disappeared on 2026-11-15). The compose `up -d` later in this
# run starts it again, and it then reads the corrected key.
docker stop qbittorrent >/dev/null 2>&1 || true
if grep -qF 'Session\Port=6881' "$QBC" 2>/dev/null; then
    sed -i 's/^Session\\Port=6881$/Session\\Port=37686/' "$QBC"
    chown 1001:1001 "$QBC"
    echo "qBittorrent.conf migrated Session\\Port 6881 -> 37686 (fix 52)"
fi
# fix 54 — repair an empty/non-numeric listen port. The 2026-11-15 empty-port
# incident wrote `Session\Port=` (qBittorrent then listens on nothing) and the
# old migration above only matched the literal 6881.
# fix 56 — ALSO handle a fully ABSENT key: the fix-54 sed above only rewrote an
# existing line, so a conf where qBittorrent had dropped the key passed the
# apply and failed the live diag. Insert it under [BitTorrent] via awk+ENVIRON
# (ENVIRON avoids sed/awk backslash-escape mangling of the literal `Session\`).
if [ -f "$QBC" ] && ! grep -q '^Session\\Port=' "$QBC"; then
    KEYLINE='Session\Port=37686'
    K="$KEYLINE" awk '
        { print }
        !done && $0 == "[BitTorrent]" { print ENVIRON["K"]; done=1 }
        END { if (!done) print "[BitTorrent]\n" ENVIRON["K"] }
    ' "$QBC" >"$QBC.new" && chown 1001:1001 "$QBC.new" && chmod 600 "$QBC.new" \
        && mv -f "$QBC.new" "$QBC"
    echo "qBittorrent.conf inserted missing Session\\Port=37686 (fix 56)"
else
    QBP_CUR="$(sed -n 's/^Session\\Port=\(.*\)$/\1/p' "$QBC" 2>/dev/null | head -n1)"
    case "$QBP_CUR" in
        37686) : ;;
        ''|*[!0-9]*)
            sed -i 's/^Session\\Port=.*$/Session\\Port=37686/' "$QBC"
            chown 1001:1001 "$QBC"
            echo "qBittorrent.conf repaired empty/invalid Session\\Port -> 37686 (fix 54)"
            ;;
        *)
            sed -i 's/^Session\\Port=.*$/Session\\Port=37686/' "$QBC"
            chown 1001:1001 "$QBC"
            echo "qBittorrent.conf rewrote stale Session\\Port $QBP_CUR -> 37686 (fix 56)"
            ;;
    esac
fi
# fix 70 — category paths for MANUAL-mode adds are a SEPARATE switch, and the
# durable copy has to be this file. Radarr adds a torrent with `category` and
# neither `savepath` nor `autoTMM`, so qBittorrent runs it in manual mode, where
# Session\UseCategoryPathsInManualMode (default FALSE) decides between the
# category path and the session save path. Live evidence 2026-11-20: cat=radarr,
# category /data/torrents/movies, torrent still at /data/torrents.
# The live API write is not durable — qBittorrent holds settings in memory and
# writes them 5 s later (SettingsStorage) plus once on a clean shutdown, so a
# container recreate that does not get one loses the value (observed: live True
# before `up -d` recreated the container, False after). Written HERE while
# qBittorrent is stopped, exactly like the port migration above (fix 56).
UCP_CUR="$(sed -n 's/^Session\\UseCategoryPathsInManualMode=\(.*\)$/\1/p' "$QBC" 2>/dev/null | head -n1)"
case "$UCP_CUR" in
    true) : ;;
    '')
        if [ -f "$QBC" ]; then
            KEYLINE='Session\UseCategoryPathsInManualMode=true'
            K="$KEYLINE" awk '
                { print }
                !done && $0 == "[BitTorrent]" { print ENVIRON["K"]; done=1 }
                END { if (!done) print "[BitTorrent]\n" ENVIRON["K"] }
            ' "$QBC" >"$QBC.new" && chown 1001:1001 "$QBC.new" && chmod 600 "$QBC.new" \
                && mv -f "$QBC.new" "$QBC"
            echo "qBittorrent.conf inserted Session\\UseCategoryPathsInManualMode=true (fix 70)"
        fi
        ;;
    *)
        sed -i 's/^Session\\UseCategoryPathsInManualMode=.*$/Session\\UseCategoryPathsInManualMode=true/' "$QBC"
        chown 1001:1001 "$QBC"
        echo "qBittorrent.conf rewrote Session\\UseCategoryPathsInManualMode $UCP_CUR -> true (fix 70)"
        ;;
esac
# ---- D. VM ufw: deny incoming / allow outgoing + torrent-port layer ----
if ! ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw default deny incoming
    ufw default allow outgoing
    ufw --force enable
fi
# management + stack ports reachable ONLY from the libvirt bridge subnet
# fix 52 — sonarr 8989 + jellyseerr 5055 join the VM-only set
for P in 22 8080 9696 7878 8686 8989 6767 8096 5055; do
    ufw allow from 192.168.122.0/24 to any port "$P" proto tcp >/dev/null 2>&1 || true
done
ufw allow from 192.168.122.0/24 to any port 7359 proto udp >/dev/null 2>&1 || true
# torrent peer-port leak BACKSTOP (fix 8: peers can use ANY port, so these
# are defense-in-depth, NOT the kill switch — the real L3 isolation is
# gluetun's netns firewall + qbittorrent riding it via compose
# network_mode: service:gluetun and the Session\Interface=tun0 bind above)
ufw deny proto tcp to any port 6881:6889 >/dev/null 2>&1 || true
ufw deny proto udp to any port 6881:6889 >/dev/null 2>&1 || true
# fix 52 — the AirVPN forwarded port is only reachable THROUGH the tunnel; the
# clearnet NIC must never carry it either (same backstop role as 6881:6889).
ufw deny proto tcp to any port 37686 >/dev/null 2>&1 || true
ufw deny proto udp to any port 37686 >/dev/null 2>&1 || true
# ---- E. durable DOCKER-USER torrent-port guard (survives reboots) ----
NIC="$(ip route show default | awk '/default/{print $5; exit}')"
cat >/usr/sbin/torrent-port-guard <<'TPGEOF'
#!/usr/bin/env bash
NIC="$(ip route show default | awk '/default/{print $5; exit}')"
[ -n "$NIC" ] || NIC=ens3
# fix 56 — converge: delete single-port DROP rows left by an OLDER forwarded
# port. They are inert (deny-only) but non-convergent — after the 37686 move S7
# still showed 51413 rows next to 37686 — and they hide a real port drift.
# Only this script's footprint is touched: `--dport <one port> ... -j DROP`,
# never the 6881:6889 range (`:`), never the inbound --ctorigdstport guards,
# never the current canary.
for T in iptables ip6tables; do
    "$T" -S DOCKER-USER 2>/dev/null | while IFS= read -r R; do
        case "$R" in
            "-A DOCKER-USER"*"--dport "*"-j DROP") ;;
            *) continue ;;
        esac
        case "$R" in *--ctorigdstport*) continue ;; esac
        P="${R#*--dport }"; P="${P%% *}"
        case "$P" in ''|*[!0-9]*) continue ;; 37686) continue ;; esac
        # shellcheck disable=SC2086
        "$T" ${R/-A DOCKER-USER/-D DOCKER-USER} 2>/dev/null || true
    done
done
# outbound container traffic can NEVER hit torrent peer ports on the
# clearnet NIC; omitting -o also covers the IPv6 docker leg
iptables -C DOCKER-USER -p tcp --dport 6881:6889 -o "$NIC" -j DROP 2>/dev/null || \
    iptables -I DOCKER-USER 1 -p tcp --dport 6881:6889 -o "$NIC" -j DROP
iptables -C DOCKER-USER -p udp --dport 6881:6889 -o "$NIC" -j DROP 2>/dev/null || \
    iptables -I DOCKER-USER 1 -p udp --dport 6881:6889 -o "$NIC" -j DROP
ip6tables -C DOCKER-USER -p tcp --dport 6881:6889 -j DROP 2>/dev/null || \
    ip6tables -I DOCKER-USER 1 -p tcp --dport 6881:6889 -j DROP
ip6tables -C DOCKER-USER -p udp --dport 6881:6889 -j DROP 2>/dev/null || \
    ip6tables -I DOCKER-USER 1 -p udp --dport 6881:6889 -j DROP
# fix 52 — same backstop for the single AirVPN forwarded port (37686): only the
# WireGuard netns may listen on it, never the clearnet NIC or the IPv6 leg.
iptables -C DOCKER-USER -p tcp --dport 37686 -o "$NIC" -j DROP 2>/dev/null || \
    iptables -I DOCKER-USER 1 -p tcp --dport 37686 -o "$NIC" -j DROP
iptables -C DOCKER-USER -p udp --dport 37686 -o "$NIC" -j DROP 2>/dev/null || \
    iptables -I DOCKER-USER 1 -p udp --dport 37686 -o "$NIC" -j DROP
ip6tables -C DOCKER-USER -p tcp --dport 37686 -j DROP 2>/dev/null || \
    ip6tables -I DOCKER-USER 1 -p tcp --dport 37686 -j DROP
ip6tables -C DOCKER-USER -p udp --dport 37686 -j DROP 2>/dev/null || \
    ip6tables -I DOCKER-USER 1 -p udp --dport 37686 -j DROP
# fix 7 INBOUND: docker's published ports bypass ufw INPUT entirely, so
# DOCKER-USER itself must reject stack-port connections that do NOT originate
# from the libvirt bridge. Scoped to the clearnet NIC (-i "$NIC") so
# container-to-container traffic on the docker bridge is unaffected.
# fix 18: DOCKER-USER traverses POST-DNAT (host:publishedport -> containerport
# remaps rewrite the dst port BEFORE this hook), so a plain --dport match can
# miss the real published port. Match the ORIGINAL destination port via
# conntrack (--ctorigdstport + --ctdir ORIGINAL) instead — this keeps working
# if the compose spec ever remaps a port.
for P in 8080 9696 7878 8686 8989 6767 8096 5055; do
    iptables -C DOCKER-USER -p tcp -i "$NIC" -m conntrack --ctorigdstport "$P" --ctdir ORIGINAL ! -s 192.168.122.0/24 -j DROP 2>/dev/null || \
        iptables -I DOCKER-USER 1 -p tcp -i "$NIC" -m conntrack --ctorigdstport "$P" --ctdir ORIGINAL ! -s 192.168.122.0/24 -j DROP
done
TPGEOF
chmod 700 /usr/sbin/torrent-port-guard
cat >/etc/systemd/system/torrent-port-guard.service <<'TPGUNITEOF'
[Unit]
Description=SystemBuild torrent-port kill switch (DOCKER-USER layer)
After=docker.service network-online.target
Wants=docker.service
[Service]
Type=oneshot
ExecStart=/usr/sbin/torrent-port-guard
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
TPGUNITEOF
systemctl daemon-reload
systemctl enable torrent-port-guard.service >/dev/null 2>&1 || true
# fix 54 — the DROP rows live in the script, so rewriting it is inert until the
# unit re-runs. `enable --now` is a NO-OP on an already-active unit: that is why
# the 2026-11-15 run kept the stale 6-port guard (diag: "guard count = 6") even
# though the new script on disk carried 8 ports + the forwarded port.
systemctl restart torrent-port-guard.service >/dev/null 2>&1 \
    || echo "VM_SETUP_WARN: torrent-port-guard restart failed (rules update on reboot)" >&2

# ---- fix 59 — media normalization (household policy, permanent) ----------
# Every movie/episode that lands in /data/media is rewritten ONCE to the shape
# this house actually plays:
#   * exactly ONE audio track — the best non-commentary track in the film's
#     original language (the language of the first non-commentary audio
#     stream, which is what remuxes carry first), and NEVER TrueHD/Atmos/
#     DTS-HD (those cannot be decoded by a TV and force a transcode): a
#     compatible codec is stream-copied, anything exotic is re-encoded to
#     AC3 5.1 (MKV) / AAC 5.1 (MP4);
#   * ZERO embedded subtitle tracks. Latin American Spanish cannot be selected
#     from an MKV: the tag is just `spa`, so es-ES and es-419 are
#     indistinguishable. Bazarr supplies `Spanish (Latin America)` as an
#     external .srt, which Jellyfin serves instantly (no demux pass);
#   * video is stream-copied and the filename/extension never changes, so
#     Radarr's file record stays valid.
# fix 61 (2026-11-18) — remuxes lie about their own shape:
#   * a remux usually carries the film AND a cover-art still (mjpeg/png). The
#     still can be stream 0, so "the first video stream" is not the film; the
#     film is chosen by pixel count with cover-art codecs excluded. Mapping the
#     still would emit a ~100 KiB "movie" that still passes a stream-count
#     check — the one failure mode that silently destroys a title;
#   * the CONTAINER duration is not the film's runtime: a longer dub track
#     inflated one 2:36:31 film to 2:40:54, so comparing container durations
#     declared a correct remux truncated. Duration is compared between the
#     source's and the output's primary VIDEO stream — like for like.
# Triggered by a timer + a path unit, serialized with flock, and fail-closed:
# on low space or a failed/truncated verify it keeps the ORIGINAL file. A file
# whose film length cannot be probed is never remuxed (nothing to verify).
# ffmpeg comes from the ALREADY-PINNED jellyfin image (same build Jellyfin
# uses) — no new image, no new port, no new LAN surface.
cat >/usr/local/sbin/media-normalize <<'MEDNORMEOF'
#!/usr/bin/env bash
# fix 59 — normalize media to the household policy (one audio, no embedded subs).
set -uo pipefail
RE_IMG="jellyfin/jellyfin:12.4"
LOG=/var/log/media-normalize.log
STATE=/var/lib/media-normalize
LOCK=/run/media-normalize.lock
ROOTS="/data/media/movies /data/media/tv"
STABLE=120          # a file must be untouched this long before we remux it
FFPROBE=/usr/lib/jellyfin-ffmpeg/ffprobe
FFMPEG=/usr/lib/jellyfin-ffmpeg/ffmpeg

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$LOG"; }
mkdir -p "$STATE" 2>/dev/null || true

# one remux at a time: 3 vCPU, and Jellyfin may be transcoding for the TV
exec 9>"$LOCK" 2>/dev/null || exit 0
flock -n 9 || { log "skip: another sweep is running"; exit 0; }

probe() {   # probe <file> -> ffprobe JSON on stdout
    docker run --rm --entrypoint "$FFPROBE" -v "$1":"$1":ro "$RE_IMG" \
        -v error -print_format json -show_streams -show_format "$1" 2>/dev/null
}
probe_vdur() {  # probe_vdur <file> -> integer seconds of the PRIMARY (film) video stream
    # fix 61 — do NOT use format=duration here. A longer dub track or an
    # mjpeg cover-art stream inflates the container duration, which made a
    # correct remux look truncated (observed: 02:40:54 German dub vs the
    # 02:36:31 film on 2026-11-18). The film is the largest non-cover-art
    # video stream, measured the same way in the source and in the output.
    docker run --rm --entrypoint "$FFPROBE" -v "$1":"$1":ro "$RE_IMG" \
        -v error -print_format json -show_streams "$1" 2>/dev/null \
    | python3 -c '
import json,sys,re
COVER=("mjpeg","png","bmp","gif","webp","ppm")
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
st=[s for s in (d.get("streams") or [])
    if s.get("codec_type")=="video"
    and (s.get("codec_name") or "").lower() not in COVER
    and not ((s.get("disposition") or {}).get("attached_pic"))]
if not st: sys.exit(0)
st.sort(key=lambda s:(int(s.get("width") or 0)*int(s.get("height") or 0),
                      int(s.get("bit_rate") or 0)), reverse=True)
s=st[0]
v=None
d0=s.get("duration")
if d0 not in (None,"","N/A"):
    try: v=float(d0)
    except Exception: v=None
if v is None:
    m=re.match(r"^(\d+):([0-5]\d):([0-5]\d(?:\.\d+)?)$",
               ((s.get("tags") or {}).get("DURATION") or "").strip())
    if m: v=int(m.group(1))*3600+int(m.group(2))*60+float(m.group(3))
if v is None: sys.exit(0)
print(int(v))
'
}
probe_cnt() {   # probe_cnt <file> <a|s|v> -> stream count
    docker run --rm --entrypoint "$FFPROBE" -v "$1":"$1":ro "$RE_IMG" \
        -v error -select_streams "$2" -show_entries stream=index -of csv=p=0 "$1" 2>/dev/null \
        | grep -c .
}

# decide: original-language audio + whether a re-encode is needed
plan() {    # plan <file>
    probe "$1" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
st=d.get("streams") or []
au=[s for s in st if s.get("codec_type")=="audio"]
su=[s for s in st if s.get("codec_type")=="subtitle"]
# fix 61: the film is the largest non-cover-art video stream — never "v:0",
# because remuxes often store an mjpeg/png still first.
COVER=("mjpeg","png","bmp","gif","webp","ppm")
nv=sum(1 for s in st if s.get("codec_type")=="video")
vi=[s for s in st if s.get("codec_type")=="video"
    and (s.get("codec_name") or "").lower() not in COVER
    and not ((s.get("disposition") or {}).get("attached_pic"))]
if not vi: sys.exit(1)
vi.sort(key=lambda s:(int(s.get("width") or 0)*int(s.get("height") or 0),
                      int(s.get("bit_rate") or 0)), reverse=True)
def tag(s,k): return ((s.get("tags") or {}).get(k) or "")
def commentary(s):
    x=tag(s,"title").lower()
    return any(k in x for k in ("commentary","comentario","commentaire","kommentar",
                                "audio description","descriptive","narration"))
main=[s for s in au if not commentary(s)] or au
if not main: sys.exit(1)
lang=(tag(main[0],"language") or "und").lower()          # original language
same=[s for s in main if (tag(s,"language") or "und").lower()==lang] or main
COMPAT=("ac3","eac3","aac","mp3","opus","flac")
# policy order: a codec the TV can decode ALWAYS beats a "better" one it cannot
# (TrueHD/Atmos 8ch must lose to AC3 5.1), then channels, then bitrate.
same.sort(key=lambda s:((s.get("codec_name") or "").lower() in COMPAT,
                        int(s.get("channels") or 0), int(s.get("bit_rate") or 0)),
          reverse=True)
k=same[0]
codec=(k.get("codec_name") or "").lower()
copy_ok = codec in COMPAT
# one audio AND one video (a leftover cover-art stream still needs a pass)
need = 0 if (len(au)==1 and len(su)==0 and copy_ok and nv==1) else 1
print("PLAN_LANG=%s" % lang)
print("PLAN_CODEC=%s" % codec)
print("PLAN_INDEX=%d" % int(k.get("index")))
print("PLAN_VIDX=%d" % int(vi[0].get("index")))
print("PLAN_COPY=%d" % (1 if copy_ok else 0))
print("PLAN_SUBS=%d" % len(su))
print("PLAN_AUDIO=%d" % len(au))
print("PLAN_NEED=%d" % need)
print("PLAN_OK=1")
'
}

for root in $ROOTS; do
    [ -d "$root" ] || continue
    while IFS= read -r -d '' f; do
        case "$f" in */.?*.norm.*|*.norm.*) continue ;; esac
        [ -f "$f" ] || continue
        # never touch a file that is still being written (import/copy)
        now=$(date +%s); mt=$(stat -c %Y "$f" 2>/dev/null) || continue
        [ $((now - mt)) -ge "$STABLE" ] || continue
        key=$(printf '%s' "$f" | sha1sum | cut -d' ' -f1)
        sig=$(stat -c '%Y:%s' "$f" 2>/dev/null)
        [ "$(cat "$STATE/$key" 2>/dev/null)" = "$sig" ] && continue

        P="$(plan "$f")"
        case "$P" in *PLAN_OK=1*) ;; *) log "skip(probe): $f"; continue ;; esac
        eval "$P"
        if [ "$PLAN_NEED" = "0" ]; then
            printf '%s' "$sig" >"$STATE/$key"
            log "ok(already normalized): $f"
            continue
        fi

        dir=$(dirname "$f"); base=$(basename "$f"); ext="${base##*.}"
        tmp="$dir/.$base.norm.$ext"
        # fix 61: the film's own runtime is the only yardstick we can verify
        # against. No probed length -> never remux (we could not tell a
        # complete output from a truncated one, and a blind retry loop would
        # rewrite 30+ GiB every 10 minutes forever).
        d1=$(probe_vdur "$f")
        if [ -z "$d1" ]; then
            log "skip(no duration): cannot probe the film stream: $f"
            continue
        fi
        # headroom: the temp holds the VIDEO stream plus one audio encode — the
        # extra audio/subtitle tracks we drop are never written — so 1.05x plus
        # 256 MiB is enough; a 10% blanket margin refused a 40 GiB remux that
        # would have fit with ~800 MiB to spare (observed 2026-11-18).
        size_kb=$(( $(stat -c %s "$f" 2>/dev/null || echo 0) / 1024 ))
        need_kb=$(( size_kb * 21 / 20 + 262144 ))
        free=$(df -Pk "$dir" 2>/dev/null | awk 'NR==2{print $4}')
        if [ "${free:-0}" -le "$need_kb" ]; then
            log "skip(space): need ~${need_kb} KiB, have ${free:-0} KiB: $f"
            continue
        fi

        args=(-hide_banner -v error -y -i "$f" -map "0:$PLAN_VIDX" -map "0:$PLAN_INDEX"
              -map_metadata 0 -sn -dn)
        if [ "$PLAN_COPY" = "1" ]; then
            args+=(-c:v copy -c:a copy)
        elif [ "$ext" = "mp4" ]; then
            args+=(-c:v copy -c:a aac -ac 6 -b:a 384k)
        else
            args+=(-c:v copy -c:a ac3 -ac 6 -b:a 640k)
        fi
        [ "$ext" = "mp4" ] && args+=(-movflags +faststart)
        args+=("$tmp")

        log "remux: $f (orig_lang=$PLAN_LANG audio=$PLAN_CODEC copy=$PLAN_COPY audio_tracks:$PLAN_AUDIO->1 subs:$PLAN_SUBS->0)"
        if ! docker run --rm --entrypoint "$FFMPEG" -v "$dir":"$dir" "$RE_IMG" \
                "${args[@]}" >>"$LOG" 2>&1; then
            rm -f "$tmp"; log "fail(ffmpeg): kept original: $f"; continue
        fi
        # verify BEFORE replacing: 1 audio, 0 subs, 1 video, and the output's
        # FILM stream within 5 s of the source's (fix 61: not the container —
        # a longer dub track or cover art must not count as the runtime)
        d2=$(probe_vdur "$tmp")
        a2=$(probe_cnt "$tmp" a); s2=$(probe_cnt "$tmp" s); v2=$(probe_cnt "$tmp" v)
        if [ "$a2" = "1" ] && [ "$s2" = "0" ] && [ "$v2" = "1" ] \
           && [ -n "$d1" ] && [ -n "$d2" ] \
           && [ "$d2" -ge $((d1 - 5)) ] && [ "$d2" -le $((d1 + 5)) ]; then
            mv -f "$tmp" "$f" && chown 1001:1001 "$f" 2>/dev/null || true
            printf '%s' "$(stat -c '%Y:%s' "$f" 2>/dev/null)" >"$STATE/$key"
            log "done: $f (audio:$a2 subs:$s2 video:$v2 dur:${d1}s->${d2}s)"
        else
            rm -f "$tmp"
            log "fail(verify a=$a2 s=$s2 v=$v2 dur=${d1}->${d2}): kept original: $f"
        fi
    done < <(find "$root" -type f \( -iname '*.mkv' -o -iname '*.mp4' \) -print0 2>/dev/null)
done
exit 0
MEDNORMEOF
chmod 700 /usr/local/sbin/media-normalize

cat >/etc/systemd/system/media-normalize.service <<'MEDNORMUNITEOF'
[Unit]
Description=SystemBuild media normalization (one audio, no TrueHD/Atmos, no embedded subs)
Documentation=file:///usr/local/sbin/media-normalize
After=docker.service local-fs.target
Wants=docker.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/media-normalize
Nice=10
IOSchedulingClass=idle
TimeoutStartSec=6h
MEDNORMUNITEOF

cat >/etc/systemd/system/media-normalize.timer <<'MEDNORMTIMEREOF'
[Unit]
Description=Periodic media-normalization sweep
[Timer]
OnBootSec=5min
OnUnitActiveSec=10min
AccuracySec=30s
[Install]
WantedBy=timers.target
MEDNORMTIMEREOF

cat >/etc/systemd/system/media-normalize.path <<'MEDNORMPATHEOF'
[Unit]
Description=Normalize media as soon as a title lands in the library
[Path]
PathModified=/data/media/movies
PathModified=/data/media/tv
Unit=media-normalize.service
[Install]
WantedBy=paths.target
MEDNORMPATHEOF

systemctl daemon-reload
systemctl enable --now media-normalize.timer >/dev/null 2>&1 \
    || echo "VM_SETUP_WARN: media-normalize.timer enable failed" >&2
systemctl enable --now media-normalize.path >/dev/null 2>&1 \
    || echo "VM_SETUP_WARN: media-normalize.path enable failed" >&2
echo "VM_SETUP_MEDIA_NORMALIZE: installed (timer 10min + path unit; log /var/log/media-normalize.log)"
echo "VM_SETUP_DONE"
VMEOF
    vmscp "$WORKDIR/vm_setup.sh" "$VM_USER@$VM_IP:/home/jordan/p5_vm_setup.sh"
    # fix 14 — setup output is secret-masked before it reaches the log
    if vmrunv 'sudo bash /home/jordan/p5_vm_setup.sh' 2>&1 | mask_secrets | grep -q VM_SETUP_DONE; then
        echo "  [done]    in-VM provisioning: /data, dir tree, qBt conf, ufw, port guards"
    else
        echo "  *** WARN: in-VM provisioning script did NOT report done — docker and"
        echo "  ***       the compose deploy below may also fail; check"
        echo "  ***       /home/jordan/p5_vm_setup.sh on media-vm (stderr above)."
        echo "  ***       Re-run phase5_apply.sh (idempotent)."
    fi
    vmrun 'rm -f /home/jordan/p5_vm_setup.sh' >/dev/null 2>&1

    # ---- fix 58 — Jellyfin image upgrade (10.10.6 -> 12.4) ----------------
    # Why: the sideloaded Samsung Tizen client of record is built against
    # jellyfin-web 12.z ("0.1.0 compiled 2026/11/06 @ 00h56 with Jellyfin-12.z"),
    # and a 10.10.6 server + 12.z client fails EVERY play request before it
    # reaches PlaybackInfo (the library renders, playback dies instantly).
    # Upstream 12.0 release notes: the DB change is irreversible, so this takes
    # a /data/config/jellyfin tarball first (fail-closed when /data is short on
    # space) and steps 10.10.x -> 10.10.7 -> 12.4 through throwaway containers,
    # BEFORE compose starts the real one. Idempotent: a no-op at 12.4.
    cat >"$WORKDIR/vm_jf_upgrade.sh" <<'JFUPEOF'
#!/usr/bin/env bash
# fix 58 — stepped Jellyfin upgrade for media-vm (root-only, idempotent).
set -uo pipefail

JF_WANT="12.4"
JF_STEP="10.10.7"
CFG=/data/config/jellyfin
CACHE=/data/config/jellyfin-cache
MIG=jellyfin-migrate
BK=""

fail() {
    echo "JF_UPGRADE_FAIL: $*" >&2
    [ -n "$BK" ] && echo "JF_UPGRADE_FAIL: pre-upgrade backup kept at $BK" >&2
    # keep the family UI alive on the OLD container/image rather than leaving
    # jellyfin stopped; compose will retry the upgrade on the next apply run.
    docker start jellyfin >/dev/null 2>&1 || true
    exit 1
}
ok() { echo "JF_UPGRADE_OK: $*"; }

cur_img="$(docker inspect -f '{{.Config.Image}}' jellyfin 2>/dev/null || true)"
cur_ver="${cur_img##*:}"
case "$cur_ver" in ""|latest|*'{{'*) cur_ver="" ;; esac

if [ "$cur_ver" = "$JF_WANT" ]; then
    ok "jellyfin already on $JF_WANT — no migration needed"
    exit 0
fi

# Fresh install (no database yet): nothing to migrate, just pre-pull so the
# compose deploy below cannot fail on a registry hiccup.
if [ ! -f "$CFG/data/jellyfin.db" ]; then
    docker pull "jellyfin/jellyfin:$JF_WANT" >/dev/null 2>&1 \
        || fail "could not pull jellyfin/jellyfin:$JF_WANT"
    ok "fresh install — pulled $JF_WANT (no DB to migrate)"
    exit 0
fi

need_kb="$(du -sk "$CFG" 2>/dev/null | awk '{print $1}')"
need_kb="${need_kb:-0}"
free_kb="$(df -Pk /data | awk 'NR==2 {print $4}')"
free_kb="${free_kb:-0}"
if [ "$free_kb" -le $(( need_kb * 3 / 2 )) ]; then
    fail "not enough free space for the pre-upgrade backup: need ~$(( need_kb * 3 / 2 )) KiB, have ${free_kb} KiB on /data"
fi
BK="/data/config/jellyfin-backup-$(date -u +%Y%m%dT%H%M%SZ)-pre-${cur_ver:-unknown}.tar.gz"
( umask 077; tar -czf "$BK" -C /data/config jellyfin ) \
    || fail "config backup failed — nothing was changed"
chmod 600 "$BK"
echo "JF_UPGRADE_BACKUP: $BK ($(du -h "$BK" | awk '{print $1}'))"

docker rm -f "$MIG" >/dev/null 2>&1 || true
docker stop jellyfin >/dev/null 2>&1 || true

migrate() {
    local tag="$1" i
    echo "JF_UPGRADE_STEP: jellyfin/jellyfin:$tag"
    docker pull "jellyfin/jellyfin:$tag" >/dev/null 2>&1 \
        || fail "could not pull jellyfin/jellyfin:$tag"
    docker rm -f "$MIG" >/dev/null 2>&1 || true
    docker run -d --name "$MIG" \
        -e PUID=1001 -e PGID=1001 -e TZ=Etc/UTC \
        -v "$CFG:/config" -v "$CACHE:/cache" \
        "jellyfin/jellyfin:$tag" >/dev/null \
        || fail "one-shot $tag container did not start"
    # readiness = the DB migration is behind us. Accept the startup banner OR
    # the Kestrel bind (both are logged after the schema migration; the task
    # NAMES are localized in this deployment, but core log lines are English).
    for i in $(seq 1 150); do
        docker logs "$MIG" 2>&1 | grep -qE 'Startup complete|Kestrel is listening' && break
        if ! docker ps --format '{{.Names}}' | grep -qx "$MIG"; then
            docker logs "$MIG" 2>&1 | tail -20 >&2
            docker rm -f "$MIG" >/dev/null 2>&1 || true
            fail "one-shot $tag exited before startup (log tail above)"
        fi
        sleep 2
    done
    docker logs "$MIG" 2>&1 | grep -qE 'Startup complete|Kestrel is listening' \
        || { docker rm -f "$MIG" >/dev/null 2>&1 || true; fail "one-shot $tag never reached startup in 300 s"; }
    docker stop "$MIG" >/dev/null 2>&1 || true
    docker rm -f "$MIG" >/dev/null 2>&1 || true
}

# 12.0 notes: direct upgrades are supported from 10.10.7 / 10.11.x; anything
# older is "strongly encouraged" to reach 10.10.7 first.
if [ -n "$cur_ver" ] && [ "$cur_ver" != "$JF_STEP" ] \
   && [ "$(printf '%s\n%s\n' "$JF_STEP" "$cur_ver" | sort -V | head -n1)" = "$cur_ver" ]; then
    echo "JF_UPGRADE_NOTE: $cur_ver is older than $JF_STEP — stepping through it first"
    migrate "$JF_STEP"
fi

migrate "$JF_WANT"
ok "config migrated to $JF_WANT (compose starts the real container next)"
exit 0
JFUPEOF
    vmscp "$WORKDIR/vm_jf_upgrade.sh" "$VM_USER@$VM_IP:/home/jordan/p5_jf_upgrade.sh"
    if vmrunv 'sudo bash /home/jordan/p5_jf_upgrade.sh' 2>&1 | mask_secrets; then
        echo "  [ok]      jellyfin image migration checked (12.4 target, backup taken when needed)"
        echo "            fix 58: 12.x requires a FULL library scan afterwards (Dashboard ->"
        echo "            Scheduled Tasks -> 'Scan Media Library'), see manual Step 10h."
    else
        echo "  *** WARN: jellyfin upgrade script failed (see JF_UPGRADE_* above)."
        echo "  ***       The pre-upgrade tarball is /data/config/jellyfin-backup-*.tar.gz"
        echo "  ***       inside media-vm; fix the cause and re-run phase5_apply.sh."
    fi
    vmrun 'rm -f /home/jordan/p5_jf_upgrade.sh' >/dev/null 2>&1

    # ---- F. VPN start gate + compose deploy ----
    REAL_CREDS=0
    grep -qE '^VPN_SERVICE_PROVIDER=[^[:space:]#]+' "$VPN_ENV_HOST" && REAL_CREDS=1
    if [ "$REAL_CREDS" -eq 1 ]; then
        echo "  [creds]   real VPN_SERVICE_PROVIDER found in $VPN_ENV_HOST -> vpn profile UP"
        COMPOSE_UP="--profile vpn up -d"
    else
        echo "  [gated]   vpn.env still comment-only -> gluetun + qbittorrent stay DOWN"
        echo "            (fill $VPN_ENV_HOST, then re-run this script or run inside media-vm:"
        echo "             sudo sh -c 'cd /opt/media-stack && docker compose --profile vpn up -d')"
        COMPOSE_UP="up -d"
    fi
    echo "  [install] docker compose $COMPOSE_UP (clearnet seven: prowlarr/radarr/lidarr/sonarr/bazarr/jellyfin/jellyseerr)"
    # fix 45 — the `cd` must happen INSIDE the root shell: as jordan it fails
    # whenever /opt/media-stack is not traversable (see vm_put above), and
    # `&&` then skipped compose entirely (0 containers, V6 FAIL). Running
    # `sudo sh -c 'cd ... && docker compose ...'` needs no cwd permission
    # from the login user and is stable across deploy paths.
    # fix 14 — compose output (env-file parse errors can echo credential
    # lines) is masked before it reaches the log; pipefail keeps the exit code
    if vmrunv "sudo sh -c 'cd /opt/media-stack && (docker compose $COMPOSE_UP || docker-compose $COMPOSE_UP)'" 2>&1 | mask_secrets; then
        echo "  [ok]      docker compose $COMPOSE_UP succeeded (seven clearnet containers active)"
    else
        echo "  *** WARN: docker compose returned non-zero — image pulls offline? or vpn.env"
        echo "  ***       exists on disk but is empty. Inspect output above; re-run to retry"
        echo "  ***       docker compose is idempotent."
    fi
    # fix 52 — docker compose v2.26 does NOT reliably recreate a running
    # container when only its env_file changed. If vpn.env was normalized or
    # pushed above, explicitly recreate the pair so gluetun always reloads the
    # new values (the 2026-11-15 restart loop was exactly this).
    if [ "$REAL_CREDS" -eq 1 ] && [ "${VPN_ENV_CHANGED:-0}" -eq 1 ]; then
        echo "  [reload]  vpn.env changed -> docker compose --profile vpn up -d --force-recreate gluetun qbittorrent"
        if vmrunv "sudo sh -c 'cd /opt/media-stack && (docker compose --profile vpn up -d --force-recreate gluetun qbittorrent || docker-compose --profile vpn up -d --force-recreate gluetun qbittorrent)'" 2>&1 | mask_secrets; then
            echo "  [ok]      gluetun + qbittorrent recreated with the updated vpn.env"
        else
            echo "  *** WARN: force-recreate of gluetun/qbittorrent failed (output above; re-run to retry)"
        fi
    fi
    echo "  [done]    docker compose $COMPOSE_UP issued (pulls may take several minutes)"
    echo "            first-run qBittorrent WebUI password: docker logs qbittorrent | grep temporary"
    echo "            (phase6 will wire a programmatic password/API key for mediabot)"
    # ---- wait for gluetun/qbt state to match the gate (short poll) ----
    sleep 10
    vmrun "sudo docker ps --format '{{.Names}}\t{{.Status}}' | sort" 2>/dev/null
fi

# ======================================================================
sub "APPLY 6/7 — host-side LAN exposure: Jellyfin (socket-proxyd + 7359) + Caddy :8443 family UI"
# fix 2 — VM->LAN pivot guard, part 1 (ufw layer): DENY the virbr0 source
# subnet to ALL RFC1918 destinations BEFORE the generic egress allows. ufw
# evaluates route rules in insertion order, so converge by delete-then-re-add
# on EVERY run: deletes first, then the denies, then the allows — the
# deny-before-allow ordering can never drift.
# fix 17 — the deny list also covers CGNAT (100.64.0.0/10, a VPN/proxy
# egress range some tunnels offer) and link-local (169.254.0.0/16, mDNS/cloud
# config planes): media-vm must not pivot into ANY of these.
for NET in 192.168.0.0/16 10.0.0.0/8 172.16.0.0/12 100.64.0.0/10 169.254.0.0/16; do
    ufw route delete deny from 192.168.122.0/24 to "$NET" >/dev/null 2>&1 || true
done
ufw route delete allow in on virbr0  >/dev/null 2>&1 || true
ufw route delete allow out on virbr0 >/dev/null 2>&1 || true
# fix 17 — same extended deny list in the route re-assertion:
for NET in 192.168.0.0/16 10.0.0.0/8 172.16.0.0/12 100.64.0.0/10 169.254.0.0/16; do
    ufw route deny from 192.168.122.0/24 to "$NET" >/dev/null 2>&1 || true
done
echo "  [ok]      ufw route DENIES converged: 192.168.122.0/24 -> RFC1918 (pivot block)"
# VM egress to the INTERNET + host->VM legs (libvirt NAT + FWD cooperation)
ufw route allow in on virbr0  >/dev/null 2>&1 && echo "  [ok]      ufw route allow in on virbr0 (VM egress out — AFTER the denies)"
ufw route allow out on virbr0 >/dev/null 2>&1 && echo "  [ok]      ufw route allow out on virbr0 (host -> VM, reply legs)"
# fix 2 — part 2 (iptables layer): libvirt inserts its own permissive
# LIBVIRT_FW* hooks at the TOP of FORWARD on every net-start, AHEAD of ufw's
# chains — so a durable unit re-pins the DROPs above them, re-running on
# every libvirtd (re)start via After= + PartOf=.
cat >/usr/local/sbin/media-vm-lan-guard <<'LVGEOF'
#!/usr/bin/env bash
# SystemBuild Phase 5 — pin VM->LAN pivot DROPs to the TOP of FORWARD, above
# the permissive LIBVIRT_FW* hooks libvirt re-inserts on every net-start.
# fix 17 — deny list extended with CGNAT + link-local (see APPLY 6):
for NET in 192.168.0.0/16 10.0.0.0/8 172.16.0.0/12 100.64.0.0/10 169.254.0.0/16; do
    while iptables -C FORWARD -s 192.168.122.0/24 -d "$NET" -j DROP >/dev/null 2>&1; do
        iptables -D FORWARD -s 192.168.122.0/24 -d "$NET" -j DROP
    done
    iptables -I FORWARD 1 -s 192.168.122.0/24 -d "$NET" -j DROP
done
LVGEOF
chmod 700 /usr/local/sbin/media-vm-lan-guard
# fix 30 — NOTE: the systemd unit (`media-vm-lan-guard.service`) alone is
# INSUFFICIENT on reboot because `libvirtd` starts its `default` bridge network
# asynchronously and inserts `LIBVIRT_FWX` at the top of `FORWARD` AFTER
# `libvirtd.service` has already reported started, pushing earlier rules below
# `LIBVIRT_FWX`. Installing `/etc/libvirt/hooks/network` ensures
# `/usr/local/sbin/media-vm-lan-guard` runs on `default started begin` as well.
cat >/etc/systemd/system/media-vm-lan-guard.service <<'LVGUNITEOF'
[Unit]
Description=SystemBuild media-vm -> LAN pivot guard (FORWARD DROPs above libvirt hooks)
# fix 30: systemd unit ordering alone is insufficient on reboot; paired with /etc/libvirt/hooks/network
After=libvirtd.service
PartOf=libvirtd.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/media-vm-lan-guard
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
LVGUNITEOF
# fix 30 — install /etc/libvirt/hooks/network (root:root 0755, /etc/libvirt/hooks
# 0755) to run /usr/local/sbin/media-vm-lan-guard on `default started begin`.
# If /etc/libvirt/hooks/network already exists, update/append a delimited block
# rather than overwriting existing hooks.
install -d -m 0755 -o root -g root "$LIBVIRT_HOOK_DIR"
chown root:root "$LIBVIRT_HOOK_DIR"
chmod 0755 "$LIBVIRT_HOOK_DIR"
if [ -L "$LIBVIRT_NET_HOOK" ]; then
    echo "FATAL: $LIBVIRT_NET_HOOK is a symlink — refusing to write libvirt hook." >&2
    exit 1
fi
HOOK_BEGIN="# >>> phase5 media-vm-lan-guard >>>"
HOOK_END="# <<< phase5 media-vm-lan-guard <<<"
if [ ! -f "$LIBVIRT_NET_HOOK" ]; then
    cat >"$LIBVIRT_NET_HOOK" <<'HOOKEOF'
#!/usr/bin/env bash
set -euo pipefail
# >>> phase5 media-vm-lan-guard >>>
if [ "${1:-}" = "default" ] && [ "${2:-}" = "started" ] && [ "${3:-}" = "begin" ]; then
    /usr/local/sbin/media-vm-lan-guard
fi
# <<< phase5 media-vm-lan-guard <<<
HOOKEOF
else
    HOOK_TMP="$WORKDIR/libvirt-net-hook.tmp"
    awk -v b="$HOOK_BEGIN" -v e="$HOOK_END" '
        $0 == b { skip=1; next }
        $0 == e { skip=0; next }
        !skip { print }
    ' "$LIBVIRT_NET_HOOK" >"$HOOK_TMP"
    cat >>"$HOOK_TMP" <<'HOOKEOF'
# >>> phase5 media-vm-lan-guard >>>
if [ "${1:-}" = "default" ] && [ "${2:-}" = "started" ] && [ "${3:-}" = "begin" ]; then
    /usr/local/sbin/media-vm-lan-guard
fi
# <<< phase5 media-vm-lan-guard <<<
HOOKEOF
    cat "$HOOK_TMP" >"$LIBVIRT_NET_HOOK"
    shred -u "$HOOK_TMP" >/dev/null 2>&1 || rm -f "$HOOK_TMP"
fi
chown root:root "$LIBVIRT_NET_HOOK"
chmod 0755 "$LIBVIRT_NET_HOOK"
echo "  [ok]      $LIBVIRT_NET_HOOK installed (root:root 0755; triggers on 'default started begin')"
# fix 40 — an appended block is useless if the hook it was appended to is not a
# shell script, or if that script exits before reaching the end. Both are WARN
# (never silent) so the operator knows the guard may not run on net-start.
if ! head -n1 "$LIBVIRT_NET_HOOK" 2>/dev/null | grep -qE '^#!.*sh'; then
    echo "  *** WARN: $LIBVIRT_NET_HOOK does not start with a sh/bash shebang." >&2
    echo "  ***       libvirt exec's this file directly; if it is not a shell" >&2
    echo "  ***       script the appended Phase 5 block will never run." >&2
fi
HOOK_EXIT_LN="$(grep -nE '^exit([[:space:]]|$)' "$LIBVIRT_NET_HOOK" 2>/dev/null | head -n1 | cut -d: -f1)"
HOOK_BLOCK_LN="$(grep -nF "$HOOK_BEGIN" "$LIBVIRT_NET_HOOK" 2>/dev/null | tail -n1 | cut -d: -f1)"
if [ -n "$HOOK_EXIT_LN" ] && [ -n "$HOOK_BLOCK_LN" ] && [ "$HOOK_EXIT_LN" -lt "$HOOK_BLOCK_LN" ]; then
    echo "  *** WARN: $LIBVIRT_NET_HOOK has a top-level 'exit' at line $HOOK_EXIT_LN" >&2
    echo "  ***       BEFORE the Phase 5 block at line $HOOK_BLOCK_LN — the pivot" >&2
    echo "  ***       guard will NOT run on net-start. Move the call above that exit." >&2
fi
systemctl daemon-reload
systemctl enable --now media-vm-lan-guard.service >/dev/null 2>&1 \
    && echo "  [ok]      media-vm-lan-guard.service enabled + started (FORWARD-top DROP pins)"
systemctl restart media-vm-lan-guard.service >/dev/null 2>&1 || true
# LAN -> Jellyfin HTTP on the host's LAN address
# fix 46 — plain `ufw status` prints "ALLOW" (no " IN"), so the old probes
# never detected an existing rule and re-issued it on every run. Match the
# real row prefix instead.
if ufw status 2>/dev/null | grep -qE "^8096/tcp( on [^[:space:]]+)?[[:space:]]+ALLOW"; then
    echo "  [ok]      ufw 8096/tcp allow already present"
else
    ufw allow in on eno1 from 192.168.1.0/24 to any port 8096 proto tcp >/dev/null 2>&1 \
        && echo "  [ok]      ufw allow: LAN -> :8096/tcp (Jellyfin HTTP)"
fi
if ufw status 2>/dev/null | grep -qE "^7359/udp( on [^[:space:]]+)?[[:space:]]+ALLOW"; then
    echo "  [ok]      ufw 7359/udp allow already present"
else
    ufw allow in on eno1 from 192.168.1.0/24 to any port 7359 proto udp >/dev/null 2>&1 \
        && echo "  [ok]      ufw allow: LAN -> :7359/udp (discovery beat)"
fi
# ======================================================================
# fix 52 — Family requests UI (Step 8 / Option A2): host Caddy terminates TLS
# on 192.168.1.133:8443 (internal CA "Family Media CA") and reverse-proxies to
# Jellyseerr at 192.168.122.10:5055. Caddy replaces Ubuntu's default :80 site
# BEFORE it is (re)started; admin off + auto_https disable_redirects keep it
# away from :2019 and :80. The LAN-subnet-only ufw row is the only exposure.
CADDYFILE=/etc/caddy/Caddyfile
CADDY_DROPIN=/etc/systemd/system/caddy.service.d/phase5.conf
CADDY_ROOT_CA=/var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt
install -d -m 0755 -o root -g root /etc/caddy /etc/systemd/system/caddy.service.d
cat >"$CADDYFILE" <<'CADDYEOF'
{
    admin off
    auto_https disable_redirects
    local_certs
    pki {
        ca local {
            name "Family Media CA"
        }
    }
}

https://clawbox.local:8443, https://192.168.1.133:8443 {
    bind 192.168.1.133
    tls internal
    header {
        Strict-Transport-Security "max-age=31536000"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "SAMEORIGIN"
        Referrer-Policy "same-origin"
    }
    reverse_proxy 192.168.122.10:5055
}
CADDYEOF
chown root:root "$CADDYFILE"; chmod 0644 "$CADDYFILE"
# fix 52 — boot-safe ordering for a .service unit (unlike a .socket, ordering a
# service after network-online.target is legal) + an IP-level sandbox that can
# reach ONLY loopback, the LAN subnet and the Jellyseerr address.
cat >"$CADDY_DROPIN" <<'CADDYUNITEOF'
[Unit]
After=network-online.target libvirtd.service
Wants=network-online.target

[Service]
ProtectHome=yes
PrivateTmp=yes
NoNewPrivileges=yes
RestrictAddressFamilies=AF_INET AF_UNIX
IPAddressDeny=any
IPAddressAllow=127.0.0.0/8 192.168.1.0/24 192.168.122.10
Restart=on-failure
RestartSec=3
CADDYUNITEOF
chown root:root "$CADDY_DROPIN"; chmod 0644 "$CADDY_DROPIN"
if ufw status 2>/dev/null | grep -qE "^8443/tcp( on [^[:space:]]+)?[[:space:]]+ALLOW"; then
    echo "  [ok]      ufw 8443/tcp allow already present"
else
    ufw allow in on eno1 from 192.168.1.0/24 to any port 8443 proto tcp >/dev/null 2>&1 \
        && echo "  [ok]      ufw allow: LAN -> :8443/tcp (family requests UI via Caddy)"
fi
systemctl daemon-reload
systemctl enable caddy >/dev/null 2>&1 || true
if systemctl is-active --quiet caddy; then
    systemctl restart caddy 2>/dev/null || true
else
    systemctl start caddy 2>/dev/null || true
fi
echo "  [ok]      caddy configured: bind 192.168.1.133:8443 -> 192.168.122.10:5055 (tls internal)"
# fix 52 — one probe initializes the local PKI on first run, then export the CA
# root so family devices can trust the bookmark without a warning.
curl -ksI -m 5 "https://192.168.1.133:8443/" >/dev/null 2>&1 || true
for _i in $(seq 1 15); do
    [ -f "$CADDY_ROOT_CA" ] && break
    sleep 1
    curl -ksI -m 3 "https://192.168.1.133:8443/" >/dev/null 2>&1 || true
done
if [ -f "$CADDY_ROOT_CA" ]; then
    install -m 0644 -o root -g root "$CADDY_ROOT_CA" /etc/media-vm/family-media-ca.crt
    echo "  [ok]      local CA exported: /etc/media-vm/family-media-ca.crt (import on family devices)"
else
    echo "  *** WARN: $CADDY_ROOT_CA not present yet — open https://192.168.1.133:8443 once"
    echo "  ***       (or re-run apply) and the root CA will be exported automatically."
fi
# socket-proxyd: binds the LAN IP only; forwards TCP to the VM
sub "writing $PROXY_SOCKET + $PROXY_SERVICE"
cat >"$PROXY_SOCKET" <<'SOKEOF'
[Unit]
Description=Jellyfin LAN proxy listener (192.168.1.133:8096 -> media-vm 8096)

[Socket]
# Pin to the LAN address - never a wildcard.  The ONLY port media exposes.
ListenStream=192.168.1.133:8096
ReusePort=yes
Backlog=100
# fix 50 — bind before DHCP assigns the LAN IP; packets are delivered once it
# appears. (ssh.socket uses the same mechanism on this host — a socket unit
# must NEVER be ordered After=network-online.target: sockets.target precedes
# basic.target, so that ordering is a boot-time cycle that deletes this unit's
# start job.)
FreeBind=yes

[Install]
WantedBy=sockets.target
SOKEOF
cat >"$PROXY_SERVICE" <<'SVCEOF'
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
chown root:root "$PROXY_SOCKET" "$PROXY_SERVICE"; chmod 644 "$PROXY_SOCKET" "$PROXY_SERVICE"
# best-effort discovery relay (UDP 7359): TV finds Jellyfin automatically; if
# it does not, enter http://192.168.1.133:8096 manually in the TV app.
# fix 20 — the compose spec (canonical source: /usr/local/sbin/phase5/
# phase5_compose.yaml) sets JELLYFIN_PublishedServerUrl=http://192.168.1.133:8096
# on the jellyfin service: without it the discovery response advertises the
# VM-internal 192.168.122.10, which LAN clients cannot reach.
# fix 31 — DISCOVERY_MODE=pinned|broadcast (default: pinned):
#   * pinned: binds 192.168.1.133:7359/udp (clients must enter
#     http://192.168.1.133:8096 manually because a socket bound to a unicast IP
#     on Linux does not receive 255.255.255.255:7359 limited-broadcast packets).
#   * broadcast: binds 0.0.0.0:7359/udp so LAN broadcast auto-discovery works,
#     restricted by `ufw allow in on eno1 from 192.168.1.0/24 to any port 7359 proto udp`
#     plus systemd `IPAddressDeny=any` and `IPAddressAllow=192.168.1.0/24 192.168.122.10`.
case "$DISCOVERY_MODE" in
    pinned)
        DISCO_BIND_ARG="bind=192.168.1.133"
        DISCO_EXEC="/usr/bin/socat -T15 UDP4-LISTEN:7359,bind=192.168.1.133,reuseaddr,fork UDP4:192.168.122.10:7359"
        ;;
    broadcast)
        DISCO_BIND_ARG="bind=0.0.0.0"
        DISCO_EXEC="/usr/bin/socat -T15 UDP4-LISTEN:7359,bind=0.0.0.0,reuseaddr,fork UDP4:192.168.122.10:7359"
        ;;
    *)
        echo "FATAL: invalid DISCOVERY_MODE='$DISCOVERY_MODE' (must be 'pinned' or 'broadcast')" >&2
        exit 1
        ;;
esac
cat >"$DISCO_SERVICE" <<DISCEOF
[Unit]
Description=Jellyfin LAN discovery relay (7359/udp -> media-vm 7359, socat, mode=$DISCOVERY_MODE)
After=network-online.target libvirtd.service
Wants=network-online.target

[Service]
Type=simple
# fix 9 + fix 31: DISCOVERY_MODE=$DISCOVERY_MODE ($DISCO_BIND_ARG)
ExecStart=$DISCO_EXEC
ExecStopPost=/bin/true
DynamicUser=yes
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectSystem=strict
NoNewPrivileges=yes
RestrictAddressFamilies=AF_INET AF_UNIX
# fix 21 + fix 31 — IP-level sandbox for the discovery relay (deny-by-default)
IPAddressDeny=any
IPAddressAllow=192.168.1.0/24 192.168.122.10
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
DISCEOF
chmod 644 "$DISCO_SERVICE"
systemctl daemon-reload
if systemctl is-enabled --quiet jellyfin-discovery.service 2>/dev/null; then
    systemctl restart jellyfin-discovery.service 2>/dev/null || true
else
    systemctl enable --now jellyfin-discovery.service 2>/dev/null || true
fi
if systemctl is-enabled --quiet jellyfin-lan-proxy.socket 2>/dev/null; then
    echo "  [ok]      jellyfin-lan-proxy already enabled"
    # fix 50 — an ENABLED socket can still be failed/inactive after a boot
    # ordering cycle or a pre-DHCP bind error. `start` is idempotent and does
    # not drop an existing listener (unlike `restart`).
    systemctl start jellyfin-lan-proxy.socket 2>/dev/null || true
else
    systemctl enable --now jellyfin-lan-proxy.socket
    echo "  [ok]      jellyfin-lan-proxy.socket enabled + started"
fi

# ======================================================================
# fix 49 — the Servarr apps write config.xml, but bazarr is NOT a Servarr
# app: it stores /data/config/bazarr/config/config.yaml with an indented
# `apikey:` field. The old config.xml-only grep could never find it, so
# BAZARR_API_KEY stayed absent and diag S10 failed forever.
arr_api_key() {
    case "$1" in
        bazarr)
            vmrun "sudo sed -n 's/^[[:space:]]*apikey:[[:space:]]*//p' /data/config/bazarr/config/config.yaml 2>/dev/null | head -n1 | tr -d '[:space:]\"'" 2>/dev/null
            ;;
        *)
            vmrun "sudo grep -o '<ApiKey>[^<]*' /data/config/$1/config.xml 2>/dev/null | head -n1 | cut -d'>' -f2" 2>/dev/null | tr -d '[:space:]'
            ;;
    esac
}

sub "APPLY 7/7 — key harvest into /opt/media-assistant/.env (append-only, masked)"
if [ "${HOLD_VM:-0}" -eq 0 ]; then
    # keys appear after FIRST boot of each app (config.xml / bazarr config.yaml)
    echo "  [wait]    polling for *arr/bazarr ApiKey fields (max ~3 min)"
    for i in $(seq 1 18); do
        KC=0
        for APP in prowlarr radarr lidarr sonarr bazarr; do
            K="$(arr_api_key "$APP")"
            if [ -n "$K" ]; then KC=$((KC + 1)); fi
        done
        [ "$KC" -eq 5 ] && break
        sleep 10
    done
    # mediabot URLs map per app port; qbittorrent's URL is static even while the
    # vpn profile stays credential-gated (fix 49). fix 52 adds sonarr:8989.
    PORTS=(prowlarr:9696 radarr:7878 lidarr:8686 sonarr:8989 bazarr:6767 jellyfin:8096 qbittorrent:8080)
    if [ ! -f "$MEDIA_ASSISTANT_ENV" ]; then
        install -m 600 -o mediabot -g mediabot /dev/null "$MEDIA_ASSISTANT_ENV"
        echo "  [created] $MEDIA_ASSISTANT_ENV (600 mediabot:mediabot) — Phase 2 skeleton absent"
    else
        chown mediabot:mediabot "$MEDIA_ASSISTANT_ENV"; chmod 600 "$MEDIA_ASSISTANT_ENV"
        echo "  [ok]      $MEDIA_ASSISTANT_ENV preserved (NOT overwritten) -> 600 mediabot:mediabot"
    fi
    for pair in "${PORTS[@]}"; do
        APP="${pair%%:*}"; PORT="${pair##*:}"
        KEY="${APP^^}_URL"
        VAL="http://$VM_IP:$PORT"
        if append_env "$MEDIA_ASSISTANT_ENV" "$KEY" "$VAL"; then :; fi
    done
    for APP in prowlarr radarr lidarr sonarr bazarr; do
        K="$(arr_api_key "$APP")"
        [ -n "$K" ] && append_env "$MEDIA_ASSISTANT_ENV" "${APP^^}_API_KEY" "$K"
        [ -n "$K" ] || echo "  [note]    $APP ApiKey not found yet (first-boot config writing?) —"
        [ -n "$K" ] || echo "            re-run phase5_apply.sh after the containers are up to fill it."
    done
else
    echo "  [skip]    key harvest skipped — VM not reachable (fix SSH/cloud-init first)"
fi

# ======================================================================
section "VERIFICATION (echoed — this is what lands in the log file)"

sub "V1 — host prereqs: libvirtd active, KVM usable, tooling present"
systemctl is-active --quiet libvirtd && pass "libvirtd active" || fail "libvirtd not active"
systemctl is-enabled --quiet libvirtd >/dev/null 2>&1 && pass "libvirtd enabled at boot" || fail "libvirtd not enabled"
[ -r /dev/kvm ] && pass "/dev/kvm readable by root (qemu will use /dev/kvm via group perms)" \
                || fail "/dev/kvm not readable"
# fix 42 — docker/compose are VM-side only (V5 verifies them in media-vm).
# Requiring docker on the HOST would fail the run on a clean host that never
# runs containers itself, and the host never invokes docker anywhere.
for t in virsh virt-install qemu-img cloud-localds genisoimage socat; do
    command -v "$t" >/dev/null 2>&1 && pass "tool present: $t" || fail "tool missing: $t"
done
# fix 52 — Caddy terminates TLS for the family requests UI on 192.168.1.133:8443
command -v caddy >/dev/null 2>&1 && pass "tool present: caddy (fix 52 family requests TLS terminator)" \
                                  || fail "tool missing: caddy"
if command -v docker >/dev/null 2>&1; then
    note "docker also present on the host (not required; the stack runs inside media-vm)"
else
    pass "docker correctly NOT required on the host (stack runs inside media-vm — fix 42)"
fi

sub "V2 — libvirt network + media LV integrity (raw passthrough state of record)"
if virsh net-info default >/dev/null 2>&1; then
    S="$(virsh net-info default | awk '/^Active:/{print $2}')"
    A="$(virsh net-info default | awk '/^Autostart:/{print $2}')"
    [ "$S" = "yes" ] && pass "default network active" || fail "default network inactive"
    [ "$A" = "yes" ] && pass "default network autostart on" || fail "default network autostart off"
    if virsh net-dumpxml default 2>/dev/null | grep -qF "$VM_MAC"; then
        pass "static DHCP reservation: $VM_MAC -> $VM_IP"
    else
        fail "static DHCP reservation missing in default network"
    fi
else
    fail "default network not defined"
fi
# fix 6 — label-aware: raw = fresh state; VM-created media-data ext4 =
# expected post-run state (host still NEVER mounts it); anything else fails.
LV_TYPE="$(blkid -o value -s TYPE "$MEDIA_LV" 2>/dev/null)"
LV_LABEL="$(blkid -o value -s LABEL "$MEDIA_LV" 2>/dev/null)"
if [ -z "$LV_TYPE" ]; then
    pass "media LV raw on the host (fresh passthrough state)"
elif [ "$LV_TYPE" = "ext4" ] && [ "$LV_LABEL" = "media-data" ] \
     && virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
    pass "media LV = VM-created media-data ext4 (expected state; host NEVER mounts it)"
else
    fail "media LV has an unexpected host-side filesystem (type=${LV_TYPE:-?} label=${LV_LABEL:-?})"
fi
findmnt "$MEDIA_LV" >/dev/null 2>&1 && fail "media LV mounted on host" || pass "media LV NOT mounted on host"
# fix 16 — the udev anti-automount rule must exist and pin UDISKS_IGNORE
if [ -f /etc/udev/rules.d/99-media-lv.rules ] \
   && grep -qF 'UDISKS_IGNORE' /etc/udev/rules.d/99-media-lv.rules 2>/dev/null; then
    pass "udev rule present: 99-media-lv.rules disables auto-mount of the media LV"
else
    fail "/etc/udev/rules.d/99-media-lv.rules missing or lacking UDISKS_IGNORE"
fi

sub "V3 — media-vm: state, autostart, shape, raw vdb passthrough"
if virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
    ST="$(virsh domstate "$VM_NAME" 2>/dev/null)"
    echo "  domstate: $ST"
    [ "$ST" = "running" ] && pass "$VM_NAME running" || fail "$VM_NAME not running (state=$ST)"
    AS="$(virsh dominfo "$VM_NAME" 2>/dev/null | awk '/^Autostart:/{print $2}')"
    [ "$AS" = "enable" ] && pass "$VM_NAME autostart on" || fail "$VM_NAME autostart off"
    if virsh dumpxml "$VM_NAME" 2>/dev/null | grep -qF "$MEDIA_LV"; then
        pass "dumpxml pins the RAW media LV passthrough ($MEDIA_LV)"
    else
        fail "dumpxml missing the media LV passthrough disk"
    fi
    if virsh dumpxml "$VM_NAME" 2>/dev/null | grep -Fq 'cache=.none.'; then
        pass "pass-through disk uses cache=none (raw-block, cache=none, io=native)"
    else
        note "cache=none attribute not visible in dumpxml header (check disk block manually)"
    fi
    if virsh dumpxml "$VM_NAME" 2>/dev/null | grep -qF '<serial>media-data-lv</serial>'; then
        pass "data disk carries serial=media-data-lv (stable by-id name in the guest)"
    else
        fail "data disk missing serial=media-data-lv (guest cannot resolve virtio-media-data-lv)"
    fi
    BCPU="$(virsh dominfo "$VM_NAME" 2>/dev/null | awk '/^CPU\(s\):/{print $2}')"
    BMEM="$(virsh dominfo "$VM_NAME" 2>/dev/null | awk '/^Max memory:/{print $3}')"
    [ "$BCPU" = "$VM_VCPUS" ] && pass "vCPUs = $BCPU" || fail "vCPUs = $BCPU (want $VM_VCPUS)"
    [ "$BMEM" = "$((VM_MEMMIB * 1024))" ] && pass "Max memory = $BMEM KiB" || fail "Max memory = $BMEM KiB (want $((VM_MEMMIB * 1024)))"
else
    fail "$VM_NAME domain not defined"
fi
# fix 27 — /var/lib/libvirt/images must be root:root 711 (traversal only, no
# directory listing for unprivileged local users).
IMGDIR_PERM="$(stat -c '%U:%G %a' /var/lib/libvirt/images 2>/dev/null)"
if [ "$IMGDIR_PERM" = "root:root 711" ]; then
    pass "/var/lib/libvirt/images is root:root 711 (fix 27)"
else
    fail "/var/lib/libvirt/images ownership/mode is '$IMGDIR_PERM' (want 'root:root 711')"
fi
# fix 13 — the VM root disk stores the synced vpn.env (WireGuard private
# key): it must be 600 while root-owned, or libvirt-qemu-owned with ZERO
# "other" bits (libvirt's dynamic ownership chowns it at VM start).
if [ -f "$ROOT_IMG" ]; then
    ROOT_MODE="$(stat -c '%a' "$ROOT_IMG" 2>/dev/null)"
    ROOT_OWN="$(stat -c '%U' "$ROOT_IMG" 2>/dev/null)"
    if [ "$ROOT_MODE" = "600" ]; then
        pass "$ROOT_IMG is 600 (never world-readable — vpn.env stays inside)"
    elif [ -n "$ROOT_MODE" ] && [ "$ROOT_OWN" = "libvirt-qemu" ] \
         && [ "$((8#$ROOT_MODE & 7))" -eq 0 ]; then
        pass "$ROOT_IMG is libvirt-qemu-owned with no other bits (mode $ROOT_MODE)"
    else
        fail "$ROOT_IMG mode/owner unsafe: mode=${ROOT_MODE:-?} owner=${ROOT_OWN:-?} (want 600, or libvirt-qemu w/o other bits)"
    fi
else
    fail "$ROOT_IMG missing — cannot verify its mode"
fi

sub "V4 — VM reachable; /data space, mount, ownership (fix 37: 1001:1001)"
if [ "${HOLD_VM:-0}" -eq 0 ]; then
    if vmrun 'echo vm-up' >/dev/null 2>&1; then
        pass "SSH deploy key reaches $VM_USER@$VM_IP"
    else
        fail "SSH deploy key cannot reach media-vm"
    fi
    MOUNT="$(vmrun "findmnt -n -o SOURCE,FSTYPE,TARGET /data" 2>/dev/null | head -n1)"
    echo "  /data -> ${MOUNT:-<unreachable>}"
    case "$MOUNT" in
        */dev/*ext4*/data*) pass "/data mounted ext4 (hardlink space ready)" ;;
        "") fail "/data mount not verifiable via SSH" ;;
        *) fail "/data mounted but unexpected: $MOUNT" ;;
    esac
    if vmrun 'test -b /dev/disk/by-id/virtio-media-data-lv' 2>/dev/null; then
        pass "guest resolves /dev/disk/by-id/virtio-media-data-lv (serial pin)"
    else
        fail "guest CANNOT resolve virtio-media-data-lv (serial missing?)"
    fi
    # (mount shape asserted above via findmnt SOURCE; the by-id serial check
    # is the ground truth for WHICH disk /data lives on)
    ODIRS="$(vmrun "stat -c '%u:%g' /data 2>/dev/null" 2>/dev/null)"
    [ "$ODIRS" = "1001:1001" ] && pass "/data owned 1001:1001 (stack PUID/PGID — no sudo, not jordan)" || fail "/data ownership: '$ODIRS' (want 1001:1001)"
    # fix 43 — prove the stack uid really is account-less INSIDE the VM (host
    # uid 1001 is the unrelated 'hermes' service account; namespaces are
    # separate only as long as the guest has no passwd entry for 1001).
    U1001="$(vmrun "getent passwd 1001 2>/dev/null" 2>/dev/null)"
    [ -z "$U1001" ] && pass "guest has NO passwd entry for uid 1001 (numeric stack uid — fix 43)" \
                    || fail "guest uid 1001 is a real account: $U1001"
    JUID="$(vmrun "id -u jordan 2>/dev/null" 2>/dev/null)"
    [ "$JUID" = "1000" ] && pass "guest jordan is uid 1000 (admin/login only)" \
                         || fail "guest jordan uid: '$JUID' (want 1000)"
    XDIRS="$(vmrun "ls /data" 2>/dev/null)"
    echo "  /data contents: ${XDIRS:-<none>}"
    echo "$XDIRS" | grep -qE 'torrents' && echo "$XDIRS" | grep -qE 'media' \
        && pass "/data/{torrents,media} layout exists" \
        || fail "/data layout incomplete: $XDIRS"
    # fix 52 — TV half of the hardlink layout (Sonarr import side)
    if vmrun 'test -d /data/torrents/tv && test -d /data/media/tv' 2>/dev/null; then
        pass "/data/{torrents,media}/tv hardlink halves exist (fix 52)"
    else
        fail "/data/{torrents,media}/tv missing — Sonarr imports would copy, not hardlink"
    fi
    # fix 56 — the listen-port key must EXIST and equal the forwarded port. The
    # fix-54 repair only rewrote an existing line, so the 2026-11-15 apply went
    # green while the conf had no key at all (qBittorrent defaulted to 6881 and
    # dropped it again on exit). Assert the on-disk value here, not just in diag.
    QBP_VM="$(vmrun "sudo grep -F 'Session\Port=' /data/config/qbittorrent/qBittorrent/qBittorrent.conf 2>/dev/null | head -n1 | cut -d= -f2" 2>/dev/null)"
    if [ "$QBP_VM" = "37686" ]; then
        pass "qBittorrent.conf pins Session\\Port=37686 (numeric — fix 56)"
    else
        fail "qBittorrent.conf listen port is '${QBP_VM:-<missing>}' (want 37686 — fix 56)"
    fi
else
    note "VM/A reachability checks skipped (SSH never came up in APPLY 5 — fix + re-run)"
fi

sub "V5 — docker + compose inside media-vm; compose.yml md5 matches the source"
if [ "${HOLD_VM:-0}" -eq 0 ]; then
    if vmrun 'command -v docker >/dev/null 2>&1' 2>/dev/null; then
        pass "docker installed inside media-vm ($(vmrun 'docker --version' 2>/dev/null | head -n1))"
    else
        fail "docker missing inside media-vm (cloud-init packages incomplete)"
    fi
    if vmrun 'docker compose version >/dev/null 2>&1 || docker-compose version >/dev/null 2>&1' 2>/dev/null; then
        pass "compose v2 present ($(vmrun 'docker compose version --short 2>/dev/null || docker-compose version --short' 2>/dev/null | head -n1))"
    else
        fail "docker compose v2 missing inside media-vm"
    fi
    SRC_SHA="$(sha256sum "$COMPOSE_SRC" | awk '{print $1}')"
    VM_SHA="$(vmrun "sudo sha256sum /opt/media-stack/docker-compose.yml 2>/dev/null | cut -d' ' -f1" | awk '{print $1}')"
    echo "  source sha256: $SRC_SHA"
    echo "  vm sha256    : ${VM_SHA:-<none>}"
    [ "$SRC_SHA" = "$VM_SHA" ] && pass "installed compose matches phase5_compose.yaml exactly" \
                               || fail "installed compose does NOT match the canonical source"
else
    note "VM/docker checks skipped (SSH down)"
fi

sub "V6 — containers: seven clearnet up (no crash loops); vpn pair follows the credential gate"
if [ "${HOLD_VM:-0}" -eq 0 ]; then
    PS_OUT="$(vmrun "sudo docker ps -a --format '{{.Names}}\t{{.Status}}' | sort" 2>/dev/null)"
    echo "$PS_OUT" | sed 's/^/  |containers| /'
    # fix 52 — the old `grep -E 'Up|Restarting'` PASSED a crash-looping
    # container. Require Up, and reject both an unhealthy state and Restarting.
    for C in prowlarr radarr lidarr sonarr bazarr jellyfin jellyseerr; do
        C_LINE="$(echo "$PS_OUT" | grep -E "^${C}[[:space:]]" || true)"
        if [ -n "$C_LINE" ] && printf '%s\n' "$C_LINE" | grep -qE 'Up' \
           && ! printf '%s\n' "$C_LINE" | grep -qF '(unhealthy)' \
           && ! printf '%s\n' "$C_LINE" | grep -qF 'Restarting'; then
            pass "$C running"
        else
            fail "$C not running/unhealthy: ${C_LINE:-absent}"
        fi
    done
    # fix 58 — the image pin is only real if the RUNNING container carries it.
    # 10.10.6 + the sideloaded jellyfin-web 12.z Tizen client fails every play
    # request before PlaybackInfo, so a silent-green apply must be impossible.
    JF_IMG="$(vmrun "sudo docker inspect -f '{{.Config.Image}}' jellyfin 2>/dev/null" 2>/dev/null)"
    if [ "$JF_IMG" = "jellyfin/jellyfin:12.4" ]; then
        pass "jellyfin runs the pinned 12.4 image (12.z Tizen client match — fix 58)"
    else
        fail "jellyfin image='${JF_IMG:-absent}' (want jellyfin/jellyfin:12.4 — fix 58)"
    fi
    # fix 60 — a stale Bazarr is invisible until subtitles fail: OpenSubtitles.com
    # answers HTTP 426 to anything below 1.5.4, so verify the RUNNING image.
    BAZ_IMG="$(vmrun "sudo docker inspect -f '{{.Config.Image}}' bazarr 2>/dev/null" 2>/dev/null)"
    if [ "$BAZ_IMG" = "lscr.io/linuxserver/bazarr:1.5.6" ]; then
        pass "bazarr runs the pinned 1.5.6 image (>=1.5.4 required by OpenSubtitles.com — fix 60)"
    else
        fail "bazarr image='${BAZ_IMG:-absent}' (want lscr.io/linuxserver/bazarr:1.5.6 — fix 60)"
    fi
    JF_VER=""
    for _i in $(seq 1 15); do
        JF_VER="$(curl -s -m 3 "http://$VM_IP:8096/System/Info/Public" 2>/dev/null \
                  | sed -n 's/.*"Version":"\([^"]*\)".*/\1/p')"
        case "$JF_VER" in 12.4*) break ;; esac
        sleep 4
    done
    case "$JF_VER" in
        12.4*) pass "jellyfin reports server version $JF_VER" ;;
        *)     fail "jellyfin /System/Info/Public version='${JF_VER:-no reply}' (want 12.4.x — fix 58)" ;;
    esac
    VPN_HAS_CREDS=0
    grep -qE '^VPN_SERVICE_PROVIDER=[^[:space:]#]+' "$VPN_ENV_HOST" 2>/dev/null && VPN_HAS_CREDS=1
    if [ "$VPN_HAS_CREDS" -eq 1 ]; then
        # fix 52 — `Up 2 seconds (health: starting)` is NOT a pass: poll up to
        # 20 s for gluetun's real healthy state, then require Up + healthy for
        # gluetun and Up (not Restarting/unhealthy) for qbittorrent.
        GH=""
        for _i in $(seq 1 10); do
            GH="$(vmrun "sudo docker inspect -f '{{.State.Health.Status}}' gluetun 2>/dev/null" 2>/dev/null)"
            [ "$GH" = "healthy" ] && break
            sleep 2
        done
        if [ "$GH" = "healthy" ]; then
            pass "gluetun Up (healthy) — vpn profile active, tunnel established"
        else
            fail "gluetun health='${GH:-unknown}' (want healthy) — tunnel not established"
        fi
        QB_LINE="$(echo "$PS_OUT" | grep -E "^qbittorrent[[:space:]]" || true)"
        if [ -n "$QB_LINE" ] && printf '%s\n' "$QB_LINE" | grep -qE 'Up' \
           && ! printf '%s\n' "$QB_LINE" | grep -qF '(unhealthy)' \
           && ! printf '%s\n' "$QB_LINE" | grep -qF 'Restarting'; then
            pass "qbittorrent Up (vpn profile active)"
        else
            fail "qbittorrent NOT Up/unhealthy though real VPN credentials exist: ${QB_LINE:-absent}"
        fi
    else
        if echo "$PS_OUT" | grep -qE '^gluetun[[:space:]]|^gluetun$'; then
            fail "gluetun container EXISTS but vpn.env is skeleton — a vpn-profile start must not happen"
        else
            pass "gluetun + qbittorrent correctly ABSENT (start-gated on real vpn.env credentials)"
        fi
    fi
    PORTS="$(vmrun "sudo docker ps --format '{{.Ports}}'" 2>/dev/null | tr '\n' ' ')"
    if echo "$PORTS" | grep -Fq '192.168.122.10'; then
        pass "container ports bound toward 192.168.122.10 (never the LAN)"
    else
        note "no 192.168.122.10 bind text found in docker ps — verify each mapping below"
        echo "  ports: $PORTS"
    fi
    if echo "$PORTS" | grep -qE '0\.0\.0\.0'; then
        fail "a container port is published on 0.0.0.0 (must always bind 192.168.122.10)"
    else
        pass "no 0.0.0.0 published ports"
    fi
    if echo "$PORTS" | grep -Fq '[::]'; then
        fail "a container port is published on [::] (IPv6 wildcard — must bind 192.168.122.10)"
    else
        pass "no [::] (IPv6 wildcard) published ports"
    fi
else
    note "container checks skipped (SSH down)"
fi

sub "V7 — .env hygiene (line-shape; values NEVER echoed) — vpn.env + media-assistant"
env_lint "$VPN_ENV_HOST"
if [ "${HOLD_VM:-0}" -eq 0 ]; then
    # fix 1 — lint a WORKDIR copy (root-only), then shred it: the in-VM
    # vpn.env never lands in a world-readable /tmp file
    vmrun "sudo cat $VPN_ENV_VM" >"$WORKDIR/vpn-env-vm" 2>/dev/null \
        && env_lint "$WORKDIR/vpn-env-vm" || note "in-VM vpn.env not readable (SSH absent?)"
    shred -u "$WORKDIR/vpn-env-vm" >/dev/null 2>&1 || rm -f "$WORKDIR/vpn-env-vm"
fi
if [ -f "$MEDIA_ASSISTANT_ENV" ]; then
    REALCOUNT="$(grep -cvE '^[[:space:]]*(#|$)' "$MEDIA_ASSISTANT_ENV" || true)"
    env_lint "$MEDIA_ASSISTANT_ENV"
    echo "  $MEDIA_ASSISTANT_ENV holds $REALCOUNT real value line(s) — key NAMES only:"
    grep -oE '^[A-Z_]+=' "$MEDIA_ASSISTANT_ENV" | sed 's/=$//' | sed 's/^/    /'
    if grep -qE '^(PROWLARR_URL|RADARR_URL|LIDARR_URL|SONARR_URL|BAZARR_URL|JELLYFIN_URL|QBITTORRENT_URL)=' "$MEDIA_ASSISTANT_ENV"; then
        pass "media-assistant .env has the 7-URL media-stack harvest (fix 52 adds SONARR_URL)"
    else
        echo "  [note]    harvest URLs not yet present (VM reachable? containers up?)"
    fi
    # fix 52 — Sonarr is harvested as URL + API key (Step 8 / family requests)
    if grep -qE '^SONARR_API_KEY=[^[:space:]#]+' "$MEDIA_ASSISTANT_ENV"; then
        pass "media-assistant .env has SONARR_API_KEY (12-key harvest)"
    else
        echo "  [note]    SONARR_API_KEY not harvested yet (first-boot sonarr config.xml?)"
    fi
    OW="$(stat -c '%U:%G %a' "$MEDIA_ASSISTANT_ENV" 2>/dev/null)"
    [ "$OW" = "mediabot:mediabot 600" ] && pass "$MEDIA_ASSISTANT_ENV is 600 mediabot:mediabot" \
                                        || fail "$MEDIA_ASSISTANT_ENV wrong ownership/mode: $OW"
else
    note "$MEDIA_ASSISTANT_ENV missing — harvest will create it on a successful apply"
fi

sub "V8 — LAN exposure: Jellyfin :8096 (+7359) and family UI :8443; *arr/qBt stay off-LAN"
if systemctl is-active --quiet jellyfin-lan-proxy.socket; then
    pass "jellyfin-lan-proxy.socket active (LISTEN pinned to 192.168.1.133:8096)"
else
    fail "jellyfin-lan-proxy.socket NOT active — LAN has no Jellyfin surface"
fi
if systemctl is-active --quiet media-vm-lan-guard.service; then
    pass "media-vm-lan-guard.service active (FORWARD-top pivot DROPs pinned)"
else
    fail "media-vm-lan-guard.service NOT active (VM->LAN pivot guard down)"
fi
# fix 22 — the guard SCRIPTS themselves must be root-owned, non-writable-others
LG_OWN="$(stat -c '%U:%G %a' /usr/local/sbin/media-vm-lan-guard 2>/dev/null)"
case "$LG_OWN" in
    "root:root 700"|"root:root 755") pass "media-vm-lan-guard script root:root safe-mode ($LG_OWN)" ;;
    *) fail "media-vm-lan-guard wrong ownership/mode: '$LG_OWN' (want root:root 700/755)" ;;
esac
# fix 30 — verify /etc/libvirt/hooks (root:root 755) and /etc/libvirt/hooks/network
# (root:root 755, not a symlink, invokes /usr/local/sbin/media-vm-lan-guard)
HOOK_DIR_OWN="$(stat -c '%U:%G %a' "$LIBVIRT_HOOK_DIR" 2>/dev/null)"
if [ -d "$LIBVIRT_HOOK_DIR" ] && [ ! -L "$LIBVIRT_HOOK_DIR" ] && [ "$HOOK_DIR_OWN" = "root:root 755" ]; then
    pass "$LIBVIRT_HOOK_DIR directory exists and is root:root 755 (fix 30)"
else
    fail "$LIBVIRT_HOOK_DIR missing or wrong ownership/mode: '${HOOK_DIR_OWN:-missing}' (want root:root 755)"
fi
HOOK_OWN="$(stat -c '%U:%G %a' "$LIBVIRT_NET_HOOK" 2>/dev/null)"
if [ -f "$LIBVIRT_NET_HOOK" ] && [ ! -L "$LIBVIRT_NET_HOOK" ] \
   && [ "$HOOK_OWN" = "root:root 755" ] \
   && grep -Fq '/usr/local/sbin/media-vm-lan-guard' "$LIBVIRT_NET_HOOK" 2>/dev/null; then
    pass "$LIBVIRT_NET_HOOK present, root:root 755, and invokes media-vm-lan-guard (fix 30)"
else
    fail "$LIBVIRT_NET_HOOK missing, wrong ownership/mode ('${HOOK_OWN:-missing}'), or missing guard invocation"
fi
if [ "${HOLD_VM:-0}" -eq 0 ]; then
    TPG_OWN="$(vmrun "stat -c '%U:%G %a' /usr/sbin/torrent-port-guard 2>/dev/null" 2>/dev/null)"
    case "$TPG_OWN" in
        "root:root 700"|"root:root 755") pass "in-VM torrent-port-guard root:root safe-mode ($TPG_OWN)" ;;
        *) fail "in-VM torrent-port-guard ownership/mode: '$TPG_OWN' (want root:root 700/755)" ;;
    esac
    if vmrun 'systemctl is-active --quiet torrent-port-guard.service' 2>/dev/null; then
        pass "in-VM torrent-port-guard.service active (DOCKER-USER pins live)"
    else
        fail "in-VM torrent-port-guard.service NOT active"
    fi
else
    note "in-VM torrent-port-guard script/unit checks skipped (SSH down)"
fi
ls -la "$PROXY_SOCKET" "$PROXY_SERVICE" "$DISCO_SERVICE" 2>/dev/null
if grep -qF 'ListenStream=192.168.1.133:8096' "$PROXY_SOCKET"; then
    pass "$PROXY_SOCKET pins ListenStream 192.168.1.133:8096 (never a wildcard)"
else
    fail "$PROXY_SOCKET does not pin the LAN-only listen"
fi
# fix 50 — a socket unit ordered after network-online.target forms a boot
# ordering cycle (sockets.target precedes basic.target) and systemd deletes its
# start job; without FreeBind=yes the bind also races DHCP.
if grep -qE '^After=.*network-online' "$PROXY_SOCKET" 2>/dev/null; then
    fail "$PROXY_SOCKET ordered after network-online.target (boot ordering cycle — fix 50)"
else
    pass "$PROXY_SOCKET has no network-online ordering (boot-safe — fix 50)"
fi
if grep -qF 'FreeBind=yes' "$PROXY_SOCKET" 2>/dev/null; then
    pass "$PROXY_SOCKET uses FreeBind=yes (binds before DHCP assigns the LAN IP — fix 50)"
else
    fail "$PROXY_SOCKET missing FreeBind=yes (pre-DHCP bind race — fix 50)"
fi
if grep -qF 'ExecStart=/usr/lib/systemd/systemd-socket-proxyd 192.168.122.10:8096' "$PROXY_SERVICE"; then
    pass "$PROXY_SERVICE forwards 192.168.1.133:8096 -> 192.168.122.10:8096"
else
    fail "$PROXY_SERVICE does not forward to the VM correctly"
fi
H8096="$(ss -tlnH 'sport = :8096' 2>/dev/null | awk '{print $4}' | sort -u)"
echo "  host 8096 listeners: ${H8096:-<none>}"
[ "$H8096" = "192.168.1.133:8096" ] && pass "exactly one 8096 listener, the pinned LAN IP" \
                                     || fail "unexpected 8096 listener set: '$H8096'"
# fix 9 + fix 31 — the socat discovery relay listener check matches the active
# DISCOVERY_MODE (pinned -> 192.168.1.133:7359; broadcast -> 0.0.0.0:7359 with
# UFW + systemd IPAddressDeny/IPAddressAllow restrictions).
H7359="$(ss -ulnH 'sport = :7359' 2>/dev/null | awk '{print $4}' | sort -u)"
echo "  host 7359/udp listeners (DISCOVERY_MODE=$DISCOVERY_MODE): ${H7359:-<none>}"
if [ "$DISCOVERY_MODE" = "pinned" ]; then
    if [ "$H7359" = "192.168.1.133:7359" ]; then
        pass "exactly one 7359/udp listener, pinned to 192.168.1.133:7359 (DISCOVERY_MODE=pinned)"
    else
        fail "unexpected 7359/udp listener set for DISCOVERY_MODE=pinned: '$H7359' (want 192.168.1.133:7359)"
    fi
elif [ "$DISCOVERY_MODE" = "broadcast" ]; then
    case "$H7359" in
        0.0.0.0:7359|"*:7359") BROADCAST_LISTEN=1 ;;
        *)                     BROADCAST_LISTEN=0 ;;
    esac
    if [ "$BROADCAST_LISTEN" -eq 1 ] \
       && grep -Fq 'IPAddressDeny=any' "$DISCO_SERVICE" 2>/dev/null \
       && grep -Fq 'IPAddressAllow=192.168.1.0/24 192.168.122.10' "$DISCO_SERVICE" 2>/dev/null \
       && ufw status 2>/dev/null | grep -qE '^7359/udp( on [^[:space:]]+)?[[:space:]]+(ALLOW|LIMIT)( IN)?[[:space:]]+192\.168\.1\.0/24'; then
        pass "7359/udp listener bound to 0.0.0.0:7359 with UFW + systemd IPAddressAllow/Deny restrictions (DISCOVERY_MODE=broadcast)"
    else
        fail "unexpected 7359/udp listener or missing UFW/IPAddressAllow restriction for DISCOVERY_MODE=broadcast: '$H7359'"
    fi
fi
if curl -s -m 8 -o /dev/null -w '%{http_code}' "http://192.168.1.133:8096/System/Info/Public" 2>/dev/null | grep -q 200; then
    pass "GET http://192.168.1.133:8096/System/Info/Public -> 200 (Jellyfin reaches the LAN)"
else
    note "Jellyfin HTTP probe returned non-200 (containers still pulling? Check docker ps)"
fi
# --- fix 52 — family requests UI: host Caddy TLS terminator on :8443 --------
if systemctl is-active --quiet caddy; then
    pass "caddy.service active (family requests TLS terminator)"
else
    fail "caddy.service NOT active — https://192.168.1.133:8443 is down"
fi
if [ -f /etc/caddy/Caddyfile ] \
   && grep -qF 'bind 192.168.1.133' /etc/caddy/Caddyfile \
   && grep -qF 'admin off' /etc/caddy/Caddyfile \
   && grep -qF 'auto_https disable_redirects' /etc/caddy/Caddyfile; then
    pass "/etc/caddy/Caddyfile pins bind 192.168.1.133, admin off, auto_https disable_redirects"
else
    fail "/etc/caddy/Caddyfile missing or not pinned (bind/admin off/disable_redirects)"
fi
H8443="$(ss -tlnH 'sport = :8443' 2>/dev/null | awk '{print $4}' | sort -u)"
echo "  host 8443 listeners: ${H8443:-<none>}"
[ "$H8443" = "192.168.1.133:8443" ] && pass "exactly one 8443 listener, pinned to the LAN IP" \
                                     || fail "unexpected 8443 listener set: '$H8443'"
CADDY_STRAY=0
for P in 80 443 2019; do
    L="$(ss -tlnH "sport = :$P" 2>/dev/null | awk '{print $4}' | sort -u)"
    if [ -n "$L" ]; then
        fail "Caddy-adjacent host listener on :$P ($L) — expected none (admin off / no :80 redirect)"
        CADDY_STRAY=1
    fi
done
[ "$CADDY_STRAY" -eq 0 ] && pass "no host listeners on :80, :443 or :2019 (Caddy never binds them)"
CADDY_CODE="$(curl -ks -m 8 -o /dev/null -w '%{http_code}' "https://192.168.1.133:8443/" 2>/dev/null || true)"
echo "  LAN relay https://192.168.1.133:8443/ -> HTTP ${CADDY_CODE:-<none>}"
case "$CADDY_CODE" in
    200|302|307) pass "https://192.168.1.133:8443 answers HTTP $CADDY_CODE (Jellyseerr via Caddy)" ;;
    *)           fail "https://192.168.1.133:8443 -> HTTP ${CADDY_CODE:-<none>} (want 200/302/307)" ;;
esac
if [ -f /etc/media-vm/family-media-ca.crt ]; then
    pass "/etc/media-vm/family-media-ca.crt present (import on family devices to trust :8443)"
else
    fail "/etc/media-vm/family-media-ca.crt missing — Caddy local CA was never exported"
fi
# negative controls: *arr / qbt / jellyseerr must have NO LAN listener on this host
ARRLEAK=0
for P in 8080 9696 7878 8686 8989 6767 5055; do
    L="$(ss -tlnH "sport = :$P" 2>/dev/null | awk '{print $4}' | grep -v '^127\.0\.0\.1:' || true)"
    if [ -n "$L" ]; then
        fail "port $P has a non-loopback listener on the HOST (LAN leak): $L"
        ARRLEAK=1
    fi
done
[ "$ARRLEAK" -eq 0 ] && pass "*arr/qBt listener leak-absent on the host (vertical isolation)"
# fix 2 — live probe: media-vm must NOT be able to pivot into the LAN. The
# default gateway 192.168.1.1 must be UNREACHABLE from inside the VM. (A probe
# to 192.168.1.133:22 or ...:8096 is NOT valid — those traverse host INPUT,
# not FORWARD.)
# fix 17 — the TCP connect is now the PRIMARY probe: a router that simply
# drops ICMP does not prove isolation, so ping alone is insufficient. TCP
# connect to 192.168.1.1:80 through FORWARD is real reachability evidence.
# A SECOND probe target (another always-on LAN host answering on a fixed TCP
# port) would strengthen this further, but no such host is currently known in
# this network — the limitation is documented here rather than refused.
if [ "${HOLD_VM:-0}" -eq 0 ]; then
    # fix 36 — a NON-ZERO exit is NOT proof of isolation. ECONNREFUSED (rc=1)
    # means the SYN reached the router and was actively rejected, and any ssh
    # failure also exits non-zero. Only a TIMEOUT (rc=124) proves a silent drop,
    # so capture the remote rc explicitly and require 124.
    PROBE_OUT="$(vmrun 'sudo timeout 4 bash -c "exec 3<>/dev/tcp/192.168.1.1/80" 2>/dev/null; echo RC=$?')"
    case "$PROBE_OUT" in
        *RC=124*)
            pass "VM->LAN pivot TCP probe TIMED OUT at 192.168.1.1:80 (packets dropped — guard effective)"
            ;;
        *RC=126*|*RC=127*)
            fail "VM->LAN pivot TCP probe could not run (rc=126/127 — timeout or bash missing in the VM?) — INCONCLUSIVE"
            ;;
        *RC=0*|*RC=1*)
            fail "VM reached 192.168.1.1:80 (rc=0 connected / rc=1 refused — the packet got through) — pivot guard NOT effective"
            ;;
        *)
            fail "VM->LAN pivot TCP probe INCONCLUSIVE (no rc from the VM — ssh failure?): '${PROBE_OUT:-<empty>}'"
            ;;
    esac
    # secondary ICMP check: rc=1 (no reply) is expected; rc=0 means reached.
    # Anything else (124 timeout / 2 error / empty) is inconclusive, not a pass.
    PING_OUT="$(vmrun 'sudo ping -c1 -W3 192.168.1.1 >/dev/null 2>&1; echo RC=$?')"
    case "$PING_OUT" in
        *RC=0*)   fail "VM->LAN pivot ping probe REACHED 192.168.1.1 — pivot rule regression" ;;
        *RC=124*) note "ping to 192.168.1.1 timed out (secondary; ICMP-drop alone proves nothing)" ;;
        *RC=1*)   note "ping to 192.168.1.1 got no reply (secondary; ICMP-drop alone proves nothing)" ;;
        *)        note "ping probe inconclusive (ssh failure?) — the primary TCP probe above is authoritative" ;;
    esac
fi
# fix 46 — match the REAL ufw row shape, not substrings. A row created with
# `ufw allow in on eno1 from 192.168.1.0/24 to any port 8096 proto tcp` is
# printed as "8096/tcp on eno1   ALLOW IN   192.168.1.0/24", so:
#   * the old `eno1.*ALLOW IN.*8096` probe could never match (8096 precedes
#     eno1) -> permanent misleading note;
#   * the old `grep -Fq 192.168.1.0/24` was satisfied by the *SSH* row, so
#     the "8096+7359 LAN only" pass could fire with no 8096 row at all;
#   * the old wildcard probe `^8096/tcp[[:space:]]+ALLOW IN[[:space:]]+Anywhere`
#     missed the interface form "8096/tcp on eno1 ... Anywhere".
# Each row is now asserted explicitly and fails closed when absent.
UFWS="$(ufw status 2>/dev/null)"
# (ufw prints "ALLOW" in plain `ufw status` and "ALLOW IN" in --verbose, so
# the action regex accepts both; the interface suffix " on eno1" is optional.)
UFW_ROW_8096='^8096/tcp( on [^[:space:]]+)?[[:space:]]+(ALLOW|LIMIT)( IN)?[[:space:]]+192\.168\.1\.0/24'
UFW_ROW_7359='^7359/udp( on [^[:space:]]+)?[[:space:]]+(ALLOW|LIMIT)( IN)?[[:space:]]+192\.168\.1\.0/24'
# fix 52 — the family requests UI row (LAN-subnet only, no wildcard)
UFW_ROW_8443='^8443/tcp( on [^[:space:]]+)?[[:space:]]+(ALLOW|LIMIT)( IN)?[[:space:]]+192\.168\.1\.0/24'
UFW_ANY_ROW='^(8096/tcp|7359/udp|8443/tcp)( \(v6\))?( on [^[:space:]]+)?[[:space:]]+(ALLOW|LIMIT)( IN)?[[:space:]]+(Anywhere|0\.0\.0\.0/0|::/0)'
if printf '%s\n' "$UFWS" | grep -qE "$UFW_ROW_8096"; then
    pass "ufw allows 8096/tcp from 192.168.1.0/24 only (exact row)"
else
    fail "ufw has no '8096/tcp ... ALLOW IN 192.168.1.0/24' row (LAN exposure gate)"
fi
if printf '%s\n' "$UFWS" | grep -qE "$UFW_ROW_7359"; then
    pass "ufw allows 7359/udp from 192.168.1.0/24 only (exact row)"
else
    fail "ufw has no '7359/udp ... ALLOW IN 192.168.1.0/24' row (discovery relay gate)"
fi
# fix 52 — family requests UI row
if printf '%s\n' "$UFWS" | grep -qE "$UFW_ROW_8443"; then
    pass "ufw allows 8443/tcp from 192.168.1.0/24 only (exact row — family requests UI)"
else
    fail "ufw has no '8443/tcp ... ALLOW IN 192.168.1.0/24' row (Caddy gate)"
fi
if printf '%s\n' "$UFWS" | grep -qE "$UFW_ANY_ROW"; then
    fail "ufw has a wildcard-source 8096/7359/8443 allow (must be 192.168.1.0/24 only)"
else
    pass "no wildcard-source 8096/7359/8443 allow in ufw"
fi

sub "V9 — Phase 3 + Phase 4 untouched (read-only sanity)"
if [ -f /etc/litellm/config.yaml ]; then
    N="$(sed 's/[[:space:]]*#.*$//' /etc/litellm/config.yaml | grep -cE '^[[:space:]]*- model_name: ' || true)"
    [ "$N" -eq 3 ] && pass "phase 3 model_list still exactly 3 models" || fail "phase 3 model_list count changed: $N"
else
    note "/etc/litellm/config.yaml missing — unexpected (phase 3)"
fi
if grep -Fq -- '--host 127.0.0.1 --port 4000' /etc/systemd/system/litellm.service 2>/dev/null; then
    pass "litellm.service still binds 127.0.0.1:4000"
else
    fail "litellm.service bind flags missing/changed"
fi
for UNIT_WANT in hermes-serve hermes-api; do
    grep -Fq 'Environment="HERMES_HOME=/var/lib/hermes"' "/etc/systemd/system/$UNIT_WANT.service" 2>/dev/null \
        && pass "$UNIT_WANT.service still hardened + HERMES_HOME pinned" \
        || fail "$UNIT_WANT.service shape changed"
done
if command -v ss >/dev/null 2>&1; then
    LP_BAD=0
    for P in 4000 8642 9119; do
        L="$(ss -tlnH "sport = :$P" 2>/dev/null | awk '{print $4}' | sort -u)"
        if [ "$L" = "127.0.0.1:$P" ]; then
            pass "phase 3/4 listener on 127.0.0.1:$P intact"
        else
            fail "phase 3/4 listener on :$P changed: '$L'"
            LP_BAD=1
        fi
    done
fi
if findmnt -rn -S "$MEDIA_LV" >/dev/null 2>&1; then
    fail "media LV mounted on host (Phase 5 never mounts it there)"
else
    pass "media LV unmounted on host (passthrough intact)"
fi

sub "V10 — host posture: SSH, UFW default-deny, jordan home, VM mgmt block"
if [ -f /etc/ssh/sshd_config.d/01-hardening.conf ]; then
    grep -Fq 'PermitRootLogin no' /etc/ssh/sshd_config.d/01-hardening.conf \
        && grep -Fq 'PasswordAuthentication no' /etc/ssh/sshd_config.d/01-hardening.conf \
        && pass "phase 1 sshd hardening intact"
    grep -Fq 'PermitRootLogin no' /etc/ssh/sshd_config.d/01-hardening.conf \
        || fail "phase 1 sshd hardening broken"
    grep -Fq 'PasswordAuthentication no' /etc/ssh/sshd_config.d/01-hardening.conf \
        || fail "phase 1 sshd PasswordAuthentication broken"
else
    fail "01-hardening.conf missing — phase 1 posture changed"
fi
UFWS="$(ufw status verbose 2>/dev/null)"
echo "$UFWS" | head -n 8 | sed 's/^/  |ufw| /'
if ufw status 2>/dev/null | head -n1 | grep -q active; then
    pass "ufw still active"
else
    fail "ufw not active"
fi
# fix 44 — `ufw status verbose` (0.36.x, and every released ufw) prints the
# policy line as "Default: deny (incoming), allow (outgoing), deny (routed)"
# — lowercase, from backend._get_default_policy(). The old grep for the
# capitalised "Deny incoming" therefore never matched and always failed on a
# healthy host. Parse the actual policy line instead of guessing its casing.
UFW_DEF="$(printf '%s\n' "$UFWS" | grep -m1 '^Default:' || true)"
echo "  ufw policy: ${UFW_DEF:-<no Default: line>}"
case "$UFW_DEF" in
    "Default: deny (incoming)"*)
        pass "ufw default incoming deny preserved"
        ;;
    *)
        fail "ufw default incoming policy changed"
        ;;
esac
SSH_L22="$(ss -tlnH 'sport = :22' 2>/dev/null | awk '{print $4}' | sort -u | tr '\n' '|')"
echo "  ssh listeners: ${SSH_L22:-<none>}"
if [ "$SSH_L22" = "127.0.0.1:22|192.168.1.133:22|" ]; then
    pass "SSH listeners unchanged (192.168.1.133:22 + 127.0.0.1:22 ONLY)"
else
    fail "SSH listener set changed: '$SSH_L22'"
fi
JP="$(stat -c '%U:%G %a' /home/jordan 2>/dev/null)"
[ "$JP" = "jordan:jordan 750" ] && pass "/home/jordan is 750 jordan:jordan" || fail "/home/jordan: $JP"
# the deploy key must never ride jordan's personal keyring
if grep -rF --only-matching -- "$(cat "$DEB_PUB")" /home/jordan/.ssh/authorized_keys 2>/dev/null | grep -q .; then
    fail "deploy key accidentally added to /home/jordan/.ssh/authorized_keys"
else
    pass "deploy key is host-ONLY (/etc/media-vm), not in jordan's keyring"
fi

# ----------------------------------------------------------------------
# fix 12 + fix 26 (+ fix 14) — the logs stay root:root 640 in /var/log/systembuild
# for the whole run (never chown jordan, never 644); jordan gets directory
# traversal via `setfacl -m u:jordan:x "$LOGDIR"` (fallback `chgrp adm "$LOGDIR"`
# mode 750) and file read access via `u:jordan:r` (fallback `root:adm 640`).
grant_log_read "$LOG" "$LOG.apt" "$LOG.vi"
if runuser -u jordan -- head -n1 "$LOG" >/dev/null 2>&1; then
    pass "jordan can traverse $LOGDIR and read $LOG (fix 26 verified via runuser)"
else
    fail "jordan CANNOT read $LOG — check $LOGDIR traversal ACL / adm group membership (fix 26)"
fi
echo "  [done]    logs (root:root 640, jordan-readable): $LOG $LOG.apt $LOG.vi"

echo
echo "=============================================================="
echo "=== Phase 5 apply complete ==="
echo "=== VERIFY_FAILS=$FAILS ==="
echo "=============================================================="
echo
# fix 28 — reference canonical root-owned copies in /usr/local/sbin/phase5/
echo " Next steps:"
echo "   1. bash /usr/local/sbin/phase5/phase5_guardrail_test.sh                      (offline, root or jordan)"
echo "   2. SECURITY — Jellyfin setup wizard: until the FIRST admin account is"
echo "      created, ANY LAN device can claim http://192.168.1.133:8096 —"
echo "      create YOUR admin user NOW, before anything else on the LAN does."
echo "   3. Put real VPN creds into $VPN_ENV_HOST, then re-run this script"
echo "      — gluetun + qbittorrent start only then."
echo "   4. bash /usr/local/sbin/phase5/phase5_diag.sh                                (live smoke, run as root)"
echo "   5. TV: open http://192.168.1.133:8096 (or discovery) in the Jellyfin app."
echo "   6. Family requests UI: open https://192.168.1.133:8443 and import"
echo "      /etc/media-vm/family-media-ca.crt once on each family device."
echo "      Confirm AirVPN forwards port 37686 to this tunnel (else update compose"
echo "      FIREWALL_VPN_INPUT_PORTS/TORRENTING_PORT + Session\\Port together)."
echo "   7. qBittorrent WebUI password: ssh into media-vm and run"
echo "        sudo docker logs qbittorrent | grep temporary"
if [ "$FAILS" -gt 0 ]; then
    echo "Phase 5 finished with $FAILS verification failure(s) — review $LOG" >&2
    exit 1
fi
exit 0

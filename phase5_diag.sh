#!/usr/bin/env bash
#
# Phase 5 live smoke — READ-ONLY, run AFTER phase5_apply.sh succeeded.
# Host: clawbox
#
#   sudo bash /home/jordan/Documents/SystemBuild/phase5_diag.sh
#
# SAFETY:
#   * Prints NO secret values — VPNProvider credentials in /etc/media-vm/vpn.env
#     are read ONLY for a presence check (key NAMES logged, values NEVER);
#     API keys / URLs in /opt/media-assistant/.env are checked for line-shape
#     and presence only (key NAMES + line counts, never values).
#   * Modifies NOTHING on the host or in the VM: virsh read commands, ss,
#     systemctl is-*, ufw status, curl probes (LAN + VM-side), and read-only
#     ssh commands into media-vm (cat/grep/findmnt/docker ps/inspect).
#
# CHECKS (S1–S10; 2026-11-09 external-review fixes folded in; 2026-11-10 fixes
#         47–49: refused-vs-leak probe, ctorigdstport inbound guard, harvest;
#         2026-11-12 fix 51: S10 journal scan is boot-scoped and ignores
#         deliberate SIGTERM restarts; 2026-11-15 fix 52: seven clearnet
#         containers, AirVPN port 37686, Caddy :8443 family requests UI)
#   S1  libvirtd + media-vm running, autostart, raw LV passthrough + serial
#       pin in dumpxml
#   S2  default network active/autostart + static DHCP reservation; media LV
#       label-aware: raw OR the VM-created media-data ext4 (host NEVER mounts)
#   S3  VM SSH (deploy key, dedicated known_hosts): /data ext4 mount, hardlink
#       tree, 1001:1001 stack PUID/PGID (no passwd entry, no sudo), qBt 5.x
#       [BitTorrent] Session\* pre-seed markers
#   S4  containers: seven clearnet Up (not unhealthy/restarting), ports bound
#       to 192.168.122.10 only (no 0.0.0.0 AND no [::]), gluetun (healthy) /
#       qbittorrent state matches the vpn.env credential gate
#   S5  Jellyfin reachable VM-side AND via the LAN relay (192.168.1.133:8096)
#       + the 7359/udp discovery relay pinned to the LAN IP + host Caddy TLS
#       terminator on 192.168.1.133:8443 (Jellyseerr family requests UI)
#   S6  LAN isolation: *arr/qBt/jellyseerr ports answer NOTHING on
#       192.168.1.133; no :80/:443/:2019 listener; media-vm-lan-guard active,
#       pivot DROPs at the TOP of FORWARD, and a live in-VM probe that must
#       NOT reach 192.168.1.1
#   S7  kill-switch live: VM ufw deny rows + DOCKER-USER drops (egress pairs
#       + inbound source guard) + torrent-port-guard active; qbt netns binding
#       when running
#   S8  Phase 3/4 untouched: litellm/hermes-serve/hermes-api active,
#       listeners strictly 127.0.0.1 on 4000/8642/9119
#   S9  host posture: SSH listeners, ufw default deny incoming, jordan home
#   S10 /opt/media-assistant/.env harvest: line-shape + key names (masked)
# =============================================================================

set -uo pipefail

OUTDIR=/tmp/opencode
mkdir -p "$OUTDIR"

DEB_KEY=/etc/media-vm/deploy_ed25519
DEB_KH=/etc/media-vm/known_hosts
VPN_ENV_HOST=/etc/media-vm/vpn.env
MEDIA_ASSISTANT_ENV=/opt/media-assistant/.env
VM_NAME=media-vm
VM_MAC=52:54:00:6d:65:6d
VM_IP=192.168.122.10
LAN_IP=192.168.1.133
MEDIA_LV=/dev/ubuntu-vg/media

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run as root: sudo bash $0" >&2
    exit 1
fi

FAILS=0
pass() { echo "  [PASS] $*"; }
fail() { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
note() { echo "  [note] $*"; }

echo "=== Phase 5 live smoke (read-only) ==="
echo

# fix 10 — same dedicated known_hosts as phase5_apply.sh (never root's own)
ssh_opts=(-i "$DEB_KEY" -o IdentitiesOnly=yes -o UserKnownHostsFile="$DEB_KH" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=6)
vmrun() { ssh "${ssh_opts[@]}" jordan@192.168.122.10 "$@" 2>/dev/null; }

# masked .env line-shape validator (same rules as phase5_apply.sh V7,
# phase3/phase4 V8/G8 — values NEVER echoed)
env_lint() {
    local file="$1" bad=0 ln_no=0 line tline var value flags
    if [ ! -f "$file" ]; then echo "missing"; return 2; fi
    while IFS= read -r line || [ -n "$line" ]; do
        ln_no=$((ln_no + 1))
        if [ -z "${line//[[:space:]]/}" ] || [[ "$line" =~ ^[[:space:]]*# ]]; then continue; fi
        tline="${line#"${line%%[![:space:]]*}"}"
        var="${tline%%=*}"
        if [[ "$tline" != *=* ]] || [[ ! "$var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            echo "  [FAIL] $file line $ln_no: malformed non-comment line (review manually)"
            bad=1; continue
        fi
        value="${tline#*=}"
        flags=""
        [ -z "$value" ] && flags="[EMPTY]"
        [[ "$value" =~ [[:space:]]+# ]] && flags="$flags [CONTAINS-HASH]"
        [[ "$value" =~ ^[[:space:]] ]]  && flags="$flags [LEADING-SPACE]"
        [[ "$value" =~ [[:space:]]$ ]]  && flags="$flags [TRAILING-SPACE]"
        # fix 52 — gluetun v3.40 rejects an IPv6 WireGuard address on an
        # IPv6-disabled VM, and quoted values are a compose/systemd hazard.
        if [ "$var" = "WIREGUARD_ADDRESSES" ] && [[ "$value" =~ [,:] ]]; then
            flags="$flags [IPV6-OR-MULTI-ADDR-UNSUPPORTED]"
        fi
        if [[ "$value" =~ ^\".*\"$ || "$value" =~ ^\'.*\'$ ]]; then
            flags="$flags [QUOTED-VALUE]"
        fi
        if [ -n "$flags" ]; then
            echo "  [FAIL] $file line $ln_no: $var — misparseable:$flags (value NOT echoed)"
            bad=1
        fi
    done <"$file"
    return "$bad"
}

# -----------------------------------------------------------------------------
# S1 — libvirtd + VM state
# -----------------------------------------------------------------------------
echo "--- S1: libvirtd + media-vm state ---"
if systemctl is-active --quiet libvirtd; then
    pass "libvirtd active"
else
    fail "libvirtd NOT active — media-vm cannot be managed"
fi
if virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
    ST="$(virsh domstate "$VM_NAME" 2>/dev/null)"
    [ "$ST" = "running" ] && pass "media-vm running" || fail "media-vm state=$ST (want running)"
    AS="$(virsh dominfo "$VM_NAME" 2>/dev/null | awk '/^Autostart:/{print $2}')"
    [ "$AS" = "enable" ] && pass "media-vm autostart on" || fail "media-vm autostart off"
    if virsh dumpxml "$VM_NAME" 2>/dev/null | grep -qF "$MEDIA_LV"; then
        pass "raw passthrough of $MEDIA_LV pinned in domain XML"
    else
        fail "media LV passthrough missing from domain XML"
    fi
    if virsh dumpxml "$VM_NAME" 2>/dev/null | grep -qF '<serial>media-data-lv</serial>'; then
        pass "data disk serial=media-data-lv (stable by-id name in the guest)"
    else
        fail "data disk missing serial=media-data-lv"
    fi
    DSK="$(virsh dumpxml "$VM_NAME" 2>/dev/null | grep -cE "type='raw'.*dev='vdb'|<source dev=")"
    echo "  raw-disk elements present: $DSK"
else
    fail "media-vm domain not defined (run phase5_apply.sh first)"
fi

# -----------------------------------------------------------------------------
# S2 — libvirt network + host-side LV integrity
# -----------------------------------------------------------------------------
echo
echo "--- S2: libvirt default network + host LV integrity ---"
if virsh net-info default >/dev/null 2>&1; then
    S="$(virsh net-info default | awk '/^Active:/{print $2}')"
    A="$(virsh net-info default | awk '/^Autostart:/{print $2}')"
    [ "$S" = "yes" ] && pass "default network active" || fail "default network inactive"
    [ "$A" = "yes" ] && pass "default network autostart on" || fail "default network autostart off"
    if virsh net-dumpxml default 2>/dev/null | grep -qF "$VM_MAC"; then
        pass "static DHCP reservation present ($VM_MAC)"
    else
        fail "static DHCP reservation missing"
    fi
else
    fail "default network not defined"
fi
# fix 6 — label-aware: raw = fresh; ext4 with OUR media-data label = the
# VM-created filesystem from a successful run (the host still never mounts it)
LV_TYPE="$(blkid -o value -s TYPE "$MEDIA_LV" 2>/dev/null)"
LV_LABEL="$(blkid -o value -s LABEL "$MEDIA_LV" 2>/dev/null)"
if [ -z "$LV_TYPE" ]; then
    pass "media LV raw on the host (fresh passthrough state)"
elif [ "$LV_TYPE" = "ext4" ] && [ "$LV_LABEL" = "media-data" ]; then
    pass "media LV = VM-created media-data ext4 (expected post-run state)"
else
    fail "media LV has an unexpected host-side filesystem (type=${LV_TYPE:-?} label=${LV_LABEL:-?})"
fi
findmnt -rn -S "$MEDIA_LV" >/dev/null 2>&1 && fail "media LV mounted on host" \
                                           || pass "media LV not mounted on host"

# -----------------------------------------------------------------------------
# S3 — VM reachability + storage
# -----------------------------------------------------------------------------
SSH_UP=0
if [ -r "$DEB_KEY" ]; then
    if vmrun 'echo vm-up' >/dev/null 2>&1; then
        SSH_UP=1
        pass "media-vm reachable via the host-only deploy key"
    else
        fail "media-vm SSH unreachable via $DEB_KEY (still booting first time?)"
    fi
else
    fail "deploy key $DEB_KEY missing/unreadable (run as root)"
fi
if [ "$SSH_UP" -eq 1 ]; then
    MOUNT="$(vmrun "findmnt -n -o SOURCE,FSTYPE,TARGET /data" 2>/dev/null | head -n1)"
    echo "  /data -> ${MOUNT:-<none>}"
    case "$MOUNT" in
        */dev/*ext4*/data*) pass "/data mounted ext4" ;;
        "") fail "/data mount unknown (SSH OK but findmnt empty)" ;;
        *) fail "/data mounted unexpectedly: $MOUNT" ;;
    esac
    OWN="$(vmrun "stat -c '%u:%g' /data" 2>/dev/null)"
    [ "$OWN" = "1001:1001" ] && pass "/data owned 1001:1001 (stack PUID/PGID — no sudo, not jordan)" \
                             || fail "/data ownership: '$OWN' (want 1001:1001)"
    # fix 43 — the stack uid must be account-less INSIDE the guest (the host's
    # uid 1001 is 'hermes'; the raw LV is only ever interpreted in the guest)
    U1001="$(vmrun "getent passwd 1001 2>/dev/null" 2>/dev/null)"
    [ -z "$U1001" ] && pass "guest has NO passwd entry for uid 1001 (numeric stack uid — fix 43)" \
                    || fail "guest uid 1001 is a real account: $U1001"
    JUID="$(vmrun "id -u jordan 2>/dev/null" 2>/dev/null)"
    [ "$JUID" = "1000" ] && pass "guest jordan is uid 1000 (admin/login only)" \
                         || fail "guest jordan uid: '$JUID' (want 1000)"
    TREE="$(vmrun "ls /data" 2>/dev/null | tr '\n' ' ')"
    echo "  /data tree: $TREE"
    echo "$TREE" | grep -q torrents && echo "$TREE" | grep -q media \
        && pass "/data/{torrents,media} hardlink layout present" \
        || fail "/data layout incomplete"
    SUBS="$(vmrun "ls /data/torrents /data/media" 2>/dev/null | tr '\n' ' ')"
    echo "$SUBS" | grep -q movies && echo "$SUBS" | grep -q music \
        && pass "{movies,music} subdirs exist on both halves" \
        || fail "subtree incomplete: $SUBS"
    # fix 52 — TV half of the hardlink layout (Sonarr import side)
    if vmrun 'test -d /data/torrents/tv && test -d /data/media/tv' 2>/dev/null; then
        pass "/data/{torrents,media}/tv exist (Sonarr hardlink halves — fix 52)"
    else
        fail "/data/{torrents,media}/tv missing (fix 52)"
    fi
    # fix 5 — assert the qBt 5.x [BitTorrent] Session\* schema (fixed-string
    # greps over ssh; single backslashes survive the double-quoted command)
    QB1="$(vmrun "sudo grep -F 'Session\Interface=tun0' /data/config/qbittorrent/qBittorrent/qBittorrent.conf 2>/dev/null" 2>/dev/null)"
    QB2="$(vmrun "sudo grep -F 'Session\InterfaceName=tun0' /data/config/qbittorrent/qBittorrent/qBittorrent.conf 2>/dev/null" 2>/dev/null)"
    QB3="$(vmrun "sudo grep -F 'Session\DefaultSavePath=/data/torrents' /data/config/qbittorrent/qBittorrent/qBittorrent.conf 2>/dev/null" 2>/dev/null)"
    QBO="$(vmrun "sudo grep -F 'SessionPort' /data/config/qbittorrent/qBittorrent/qBittorrent.conf 2>/dev/null" 2>/dev/null)"
    # fix 52 — the single AirVPN forwarded port is pinned in the 5.x schema
    QBP="$(vmrun "sudo grep -F 'Session\Port=37686' /data/config/qbittorrent/qBittorrent/qBittorrent.conf 2>/dev/null" 2>/dev/null)"
    QBP_OLD="$(vmrun "sudo grep -F 'Session\Port=6881' /data/config/qbittorrent/qBittorrent/qBittorrent.conf 2>/dev/null" 2>/dev/null)"
    if [ -n "$QB1" ] && [ -n "$QB2" ]; then
        pass "qBittorrent.conf pins Session\Interface(+Name)=tun0 (5.x [BitTorrent] schema)"
    else
        note "qBt tun0 bind not found (conf not pre-seeded yet — first apply incomplete?)"
    fi
    if [ -n "$QB3" ]; then
        pass "qBittorrent.conf Session\DefaultSavePath=/data/torrents"
    else
        note "qBt DefaultSavePath not found (conf not pre-seeded yet?)"
    fi
    if [ -n "$QBO" ]; then
        fail "qBittorrent.conf still carries the OLD schema (bare SessionPort — fix 5 not applied)"
    else
        pass "no old-schema qBt keys present"
    fi
    if [ -n "$QBP" ]; then
        pass "qBittorrent.conf Session\\Port=37686 (AirVPN forwarded port — fix 52)"
    else
        fail "qBittorrent.conf does not pin Session\\Port=37686 (key absent or stale — fix 56)"
    fi
    # fix 54 — a bare `Session\Port=` satisfies the grep above but leaves
    # qBittorrent listening on nothing; require a numeric value explicitly.
    QBP_NUM="$(printf '%s\n' "$QBP" | sed -n 's/.*Session\\Port=\([0-9][0-9]*\).*/\1/p' | head -n1)"
    [ -n "$QBP_NUM" ] \
        && pass "qBittorrent.conf Session\\Port is numeric ($QBP_NUM)" \
        || fail "qBittorrent.conf Session\\Port is empty/non-numeric (fix 54) — observed '${QBP_NUM:-<missing>}'"
    if [ -n "$QBP_OLD" ]; then
        fail "qBittorrent.conf still listens on Session\\Port=6881 (migration incomplete)"
    else
        pass "no stale Session\\Port=6881 in qBittorrent.conf"
    fi
    # fix 70 — the durable copy of the manual-mode path switch. Without it every
    # Radarr/Sonarr add (category only, no savepath/autoTMM) lands in the
    # session save path and the category's /data/torrents/<kind> is ignored.
    QBCAT="$(vmrun "sudo grep -F 'Session\UseCategoryPathsInManualMode=true' /data/config/qbittorrent/qBittorrent/qBittorrent.conf 2>/dev/null" 2>/dev/null)"
    QBCAT_OFF="$(vmrun "sudo grep -F 'Session\UseCategoryPathsInManualMode=false' /data/config/qbittorrent/qBittorrent/qBittorrent.conf 2>/dev/null" 2>/dev/null)"
    if [ -n "$QBCAT" ]; then
        pass "qBittorrent.conf Session\\UseCategoryPathsInManualMode=true (fix 70)"
    elif [ -n "$QBCAT_OFF" ]; then
        fail "qBittorrent.conf sets UseCategoryPathsInManualMode=false — *arr adds ignore the category path (fix 70)"
    else
        fail "qBittorrent.conf has no UseCategoryPathsInManualMode key — *arr adds ignore the category path (fix 70)"
    fi
    # fix 72 — the file without the qBittorrent/ subdirectory is NOT read by the
    # app. It was created by an earlier apply, and checking it produced three
    # false PASSes and two wrong diagnoses, so its return is a failure now.
    if vmrun 'test -f /data/config/qbittorrent/qBittorrent.conf' 2>/dev/null; then
        fail "the IGNORED duplicate /data/config/qbittorrent/qBittorrent.conf exists — qBittorrent never reads it (fix 72)"
    else
        pass "no ignored qBittorrent.conf duplicate outside the qBittorrent/ subdirectory (fix 72)"
    fi
    # fix 56 — the conf value is only real if the process LISTENS on it inside
    # gluetun's netns (that is the interface AirVPN forwards to). /proc/net/tcp
    # needs no tools: state 0A = LISTEN, listener remote = 00000000:0000, and the
    # local port is hex (37686 = 0x9336, derived so a port move stays in sync).
    QBP_HEX="$(printf '%04X' 37686)"
    QBL=0
    for _i in 1 2 3 4 5 6; do
        QBL="$(vmrun "sudo docker exec gluetun grep -c ':$QBP_HEX 00000000:0000 0A' /proc/net/tcp" 2>/dev/null)"
        [ "${QBL:-0}" -ge 1 ] 2>/dev/null && break
        sleep 5
    done
    if [ "${QBL:-0}" -ge 1 ] 2>/dev/null; then
        pass "qBittorrent LISTENs on 37686 inside gluetun's netns (0x$QBP_HEX — fix 56)"
    else
        fail "no LISTEN socket on 37686 in gluetun's netns (conf/process mismatch — fix 56)"
    fi
    SG="$(vmrun "sudo systemctl is-active torrent-port-guard.service" 2>/dev/null)"
    [ "$SG" = "active" ] && pass "in-VM torrent-port-guard.service active" \
                         || note "torrent-port-guard state: '${SG:-unknown}'"
fi

# ------------------------------------------------------------------------------
# S4 — containers + vpn gate
# -----------------------------------------------------------------------------
VPN_HAS_CREDS=0
if [ -f "$VPN_ENV_HOST" ] && grep -qE '^VPN_SERVICE_PROVIDER=[^[:space:]#]+' "$VPN_ENV_HOST"; then
    VPN_HAS_CREDS=1
fi
if [ "$SSH_UP" -eq 1 ]; then
    echo
    echo "--- S4: containers (clearnet seven + vpn-profile gate) ---"
    PS_OUT="$(vmrun "sudo docker ps -a --format '{{.Names}}\t{{.Status}}' | sort" 2>/dev/null)"
    echo "$PS_OUT" | sed 's/^/  |containers| /'
    ALLCLEAR=1
    # fix 52 — a crash-looping / unhealthy clearnet container is NOT "Up"
    for C in prowlarr radarr lidarr sonarr bazarr jellyfin jellyseerr; do
        C_LINE="$(echo "$PS_OUT" | grep -E "^${C}[[:space:]]" || true)"
        if [ -n "$C_LINE" ] && printf '%s\n' "$C_LINE" | grep -qE 'Up' \
           && ! printf '%s\n' "$C_LINE" | grep -qF '(unhealthy)' \
           && ! printf '%s\n' "$C_LINE" | grep -qF 'Restarting'; then
            pass "$C Up"
        else
            fail "$C not Up/unhealthy: ${C_LINE:-absent}"
            ALLCLEAR=0
        fi
    done
    # fix 60 — OpenSubtitles.com returns HTTP 426 to any Bazarr below 1.5.4,
    # so the running image is a functional requirement: verify it, not the UI.
    BZ_IMG="$(vmrun "sudo docker inspect -f '{{.Config.Image}}' bazarr 2>/dev/null" 2>/dev/null)"
    case "$BZ_IMG" in
        *bazarr:1.5.6) pass "bazarr image $BZ_IMG (OpenSubtitles.com 1.5.4 gate satisfied — fix 60)" ;;
        *)             fail "bazarr image '${BZ_IMG:-absent}' — OSC rejects <1.5.4 with HTTP 426 (fix 60)" ;;
    esac
    PORTS="$(vmrun "sudo docker ps --format '{{.Names}}\t{{.Ports}}'" 2>/dev/null)"
    echo "$PORTS" | sed 's/^/  |ports| /'
    if echo "$PORTS" | grep -qE '0\.0\.0\.0'; then
        fail "a container port is published on 0.0.0.0 (must bind 192.168.122.10)"
    elif echo "$PORTS" | grep -Fq '[::]'; then
        fail "a container port is published on [::] (IPv6 wildcard — must bind 192.168.122.10)"
    elif echo "$PORTS" | grep -Fq '192.168.122.10'; then
        pass "published ports bind 192.168.122.10 only (no 0.0.0.0, no [::])"
    else
        note "no 192.168.122.10 bind text found — verify mappings above"
    fi
    if [ "$VPN_HAS_CREDS" -eq 1 ]; then
        # fix 52 — "Up 5 seconds (unhealthy)" / "(health: starting)" must FAIL.
        # Poll up to 20 s so a just-restarted gluetun is not a false alarm.
        GH="$(vmrun "sudo docker inspect -f '{{.State.Health.Status}}' gluetun 2>/dev/null" 2>/dev/null)"
        for _i in $(seq 1 10); do
            [ "$GH" = "healthy" ] && break
            sleep 2
            GH="$(vmrun "sudo docker inspect -f '{{.State.Health.Status}}' gluetun 2>/dev/null" 2>/dev/null)"
        done
        case "$GH" in
            healthy) pass "gluetun Up (healthy) — vpn profile active, real credentials present" ;;
            *)       fail "gluetun health='${GH:-unknown}' (want healthy) — tunnel not established" ;;
        esac
        QB_LINE="$(echo "$PS_OUT" | grep -E "^qbittorrent[[:space:]]" || true)"
        if [ -n "$QB_LINE" ] && printf '%s\n' "$QB_LINE" | grep -qE 'Up' \
           && ! printf '%s\n' "$QB_LINE" | grep -qF '(unhealthy)' \
           && ! printf '%s\n' "$QB_LINE" | grep -qF 'Restarting'; then
            pass "qbittorrent Up (vpn profile active — real credentials present)"
        else
            fail "qbittorrent NOT Up/unhealthy though real VPN credentials exist: ${QB_LINE:-absent}"
        fi
        NM="$(vmrun "sudo docker inspect -f '{{.HostConfig.NetworkMode}}' qbittorrent 2>/dev/null" 2>/dev/null)"
        case "$NM" in
            container:*) pass "qbittorrent rides gluetun's netns ($NM)" ;;
            "")          note "qbittorrent netns inspect failed (container down?)" ;;
            *)           fail "qbittorrent NetworkMode='$NM' (want container:<gluetun-id>)" ;;
        esac
    else
        if echo "$PS_OUT" | grep -qE '^gluetun([[:space:]]|$)'; then
            fail "gluetun container exists but vpn.env is a comment-only skeleton —"
            echo "         vpn profile must stay DOWN until real credentials exist"
        else
            pass "gluetun + qbittorrent correctly absent (start-gated on credentials)"
        fi
        if echo "$PS_OUT" | grep -qE '^qbittorrent([[:space:]]|$)'; then
            fail "qbittorrent container exists while vpn.env has no real provider values"
        else
            pass "qbittorrent correctly absent (start-gated on credentials)"
        fi
    fi
else
    note "S4–S7 in-VM checks skipped (SSH down)"
fi

# ------------------------------------------------------------------------------
# S5 — Jellyfin LAN reachability
# -----------------------------------------------------------------------------
echo
echo "--- S5: Jellyfin reachability (VM-side + LAN relay) ---"
code=$(curl -s -m 10 -o "$OUTDIR/p5_jfin_vm.json" -w '%{http_code}' "http://$VM_IP:8096/System/Info/Public" 2>/dev/null || true)
echo "  VM-side  http://$VM_IP:8096/System/Info/Public -> HTTP $code"
[ "$code" = "200" ] && pass "Jellyfin answers on the VM-side address" \
                    || fail "Jellyfin VM-side -> HTTP $code"
if systemctl is-active --quiet jellyfin-lan-proxy.socket; then
    pass "jellyfin-lan-proxy.socket active (LISTEN $LAN_IP:8096)"
else
    note "socket unit not active yet — LAN relay may come up after restart"
fi
code=$(curl -s -m 10 -o "$OUTDIR/p5_jfin_lan.json" -w '%{http_code}' "http://$LAN_IP:8096/System/Info/Public" 2>/dev/null || true)
echo "  LAN relay http://$LAN_IP:8096/System/Info/Public -> HTTP $code"
[ "$code" = "200" ] && pass "Jellyfin answers through the 192.168.1.133:8096 relay" \
                    || fail "LAN relay -> HTTP $code (proxy/socket down, or jellyfin still starting)"
# fix 58 — the server version must match the 12.z image pin. A 10.10.6 server is
# what made the sideloaded Tizen client (jellyfin-web 12.z) fail every play.
JFVER="$(sed -n 's/.*"Version":"\([^"]*\)".*/\1/p' "$OUTDIR/p5_jfin_lan.json" 2>/dev/null | head -n1)"
[ -n "$JFVER" ] || JFVER="$(sed -n 's/.*"Version":"\([^"]*\)".*/\1/p' "$OUTDIR/p5_jfin_vm.json" 2>/dev/null | head -n1)"
echo "  reported version: ${JFVER:-<none>}"
case "$JFVER" in
    12.4*) pass "Jellyfin reports version $JFVER (matches the pinned 12.4 image — fix 58)" ;;
    *)     fail "Jellyfin version '${JFVER:-unknown}' (want 12.4.x — fix 58: a 10.10.6 server cannot serve the 12.z Tizen client)" ;;
esac
LNAME="$(grep -oE '"ServerName"\s*:\s*"[^"]+"' "$OUTDIR/p5_jfin_lan.json" 2>/dev/null | head -n1)"
echo "  reported server: ${LNAME:-<no name field>}"
# fix 9 — the socat discovery relay must be pinned to exactly one address
# fix 31 — match the configured DISCOVERY_MODE: pinned -> $LAN_IP, broadcast ->
# 0.0.0.0 (still exactly one listener; never an unintended third bind).
H7359="$(ss -ulnH 'sport = :7359' 2>/dev/null | awk '{print $4}' | sort -u)"
DISC_UNIT=/etc/systemd/system/jellyfin-discovery.service
if grep -qF 'bind=0.0.0.0' "$DISC_UNIT" 2>/dev/null; then
    EXPECT_7359="0.0.0.0:7359"
    DISC_MODE_HINT="broadcast"
else
    EXPECT_7359="$LAN_IP:7359"
    DISC_MODE_HINT="pinned"
fi
echo "  7359/udp listeners (mode=$DISC_MODE_HINT): ${H7359:-<none>}"
if [ "$DISC_MODE_HINT" = "broadcast" ]; then
    case "$H7359" in
        0.0.0.0:7359|"*:7359") H7359_OK=1 ;;
        *)                     H7359_OK=0 ;;
    esac
else
    [ "$H7359" = "$EXPECT_7359" ] && H7359_OK=1 || H7359_OK=0
fi
[ "$H7359_OK" -eq 1 ] && pass "discovery relay bound to exactly $EXPECT_7359 (DISCOVERY_MODE=$DISC_MODE_HINT)" \
                      || fail "unexpected 7359/udp listener set: '$H7359' (want '$EXPECT_7359')"
# fix 57 — a bound relay is not a WORKING relay: it forwards to the container's
# 7359/udp, which the compose spec must publish on the VM IP. Before fix 57 the
# stack published only 8096/tcp, so every relayed probe hit a closed port
# (ICMP port-unreachable on $VM_IP:7359) and no LAN client ever auto-discovered
# the server. Probe the responder itself: the reply is JSON (Address/Id/Name).
if command -v socat >/dev/null 2>&1; then
    DISCO_VM="$(printf 'who is JellyfinServer?' | timeout 4 socat - "UDP4:$VM_IP:7359" 2>/dev/null | head -c 200)"
    echo "  discovery responder ($VM_IP:7359): ${DISCO_VM:-<no reply>}"
    [ -n "$DISCO_VM" ] && pass "Jellyfin discovery responder answers on the VM side (7359/udp published — fix 57)" \
                       || fail "no reply from $VM_IP:7359 — jellyfin 7359/udp not published (fix 57) or discovery disabled"
    DISCO_LANR="$(printf 'who is JellyfinServer?' | timeout 4 socat - "UDP4:$LAN_IP:7359" 2>/dev/null | head -c 200)"
    echo "  discovery relay   ($LAN_IP:7359): ${DISCO_LANR:-<no reply>}"
    [ -n "$DISCO_LANR" ] && pass "LAN discovery path answers end-to-end (relay -> responder)" \
                         || note "LAN discovery relay gave no reply (clients can still enter $LAN_IP:8096 manually)"
else
    note "socat not installed — discovery responder probe skipped"
fi
# fix 52 — family requests UI (Jellyseerr behind host Caddy on :8443)
if systemctl is-active --quiet caddy; then
    pass "caddy.service active (family requests TLS terminator)"
else
    fail "caddy.service NOT active — https://$LAN_IP:8443 is down"
fi
H8443="$(ss -tlnH 'sport = :8443' 2>/dev/null | awk '{print $4}' | sort -u)"
echo "  8443/tcp listeners: ${H8443:-<none>}"
[ "$H8443" = "$LAN_IP:8443" ] && pass "exactly one 8443 listener, pinned $LAN_IP:8443" \
                               || fail "unexpected 8443 listener set: '$H8443' (want '$LAN_IP:8443')"
CADDY_CODE="$(curl -ks -m 8 -o /dev/null -w '%{http_code}' "https://$LAN_IP:8443/" 2>/dev/null || true)"
echo "  LAN relay https://$LAN_IP:8443/ -> HTTP ${CADDY_CODE:-<none>}"
case "$CADDY_CODE" in
    200|302|307) pass "https://$LAN_IP:8443 answers HTTP $CADDY_CODE (Jellyseerr via Caddy)" ;;
    *)           fail "https://$LAN_IP:8443 -> HTTP ${CADDY_CODE:-<none>} (want 200/302/307)" ;;
esac
if [ -f /etc/media-vm/family-media-ca.crt ]; then
    pass "family-media-ca.crt present (trust anchor for family devices)"
else
    fail "family-media-ca.crt missing — Caddy local CA not exported"
fi

# ------------------------------------------------------------------------------
# S6 — isolation negative probes (LAN)
# -----------------------------------------------------------------------------
echo
echo "--- S6: vertical isolation — *arr/qBt MUST NOT answer on the LAN IP ---"
LEAK=0
# fix 47 — curl ALREADY writes 000 to stdout when the connect fails; the old
# `|| echo` fallback appended a second 000 ("000000"), so a correctly ISOLATED
# port was reported as a LEAK. Swallow curl's non-zero exit instead of echoing.
for P in 8080 9696 7878 8686 8989 6767 5055; do
    code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://$LAN_IP:$P/" 2>/dev/null || true)
    case "$code" in
        000|"") pass "$LAN_IP:$P -> HTTP 000/refused (isolated)" ;;
        *)      fail "$LAN_IP:$P -> HTTP $code (LEAK: this port must never answer on the LAN)"; LEAK=1 ;;
    esac
done
HL="$(ss -tlnH 2>/dev/null | awk '{print $4}' | grep -E ":(8080|9696|7878|8686|8989|6767|5055)$" | grep -v '^127\.0\.0\.1:' || true)"
if [ -n "$HL" ]; then
    fail "host has non-loopback listeners on *arr/qbt/jellyseerr ports: $HL"
else
    pass "no host-side listeners on *arr/qbt/jellyseerr ports (loopback/local only)"
fi
# fix 52 — Caddy must never open its admin endpoint or a plaintext redirect site
STRAY=0
for P in 80 443 2019; do
    L="$(ss -tlnH "sport = :$P" 2>/dev/null | awk '{print $4}' | sort -u)"
    if [ -n "$L" ]; then
        fail "host listener on :$P ($L) — Caddy must not bind :80/:443/:2019"
        STRAY=1
    fi
done
[ "$STRAY" -eq 0 ] && pass "no host listeners on :80, :443 or :2019 (admin off / no redirect)"
# fix 2 — VM->LAN pivot guard, live evidence: unit active, DROPs at the TOP of
# FORWARD (above libvirt's permissive LIBVIRT_FW* hooks), and an in-VM probe
# that must NOT reach the LAN default gateway. (192.168.1.133:22 would
# traverse host INPUT, not FORWARD — not a valid probe.)
if systemctl is-active --quiet media-vm-lan-guard.service; then
    pass "media-vm-lan-guard.service active (FORWARD-top pivot DROPs pinned)"
else
    fail "media-vm-lan-guard.service NOT active (VM->LAN pivot guard down)"
fi
FTOP="$(iptables -S FORWARD 2>/dev/null | head -n4)"
echo "$FTOP" | sed 's/^/  |fwd-top| /'
if echo "$FTOP" | grep -q '192.168.122.0/24' && echo "$FTOP" | grep -q 'DROP'; then
    pass "VM->LAN pivot DROPs sit at the TOP of FORWARD (above libvirt hooks)"
else
    fail "pivot DROPs not at the top of FORWARD — libvirt hooks may precede them"
fi
if [ "$SSH_UP" -eq 1 ]; then
    # fix 36 — only a TIMEOUT proves the packet was dropped. ECONNREFUSED
    # (rc=1) means the SYN reached the router, and an ssh failure also exits
    # non-zero, so a bare `if vmrun ...; then` was a false pass.
    PROBE_OUT="$(vmrun 'sudo timeout 4 bash -c "exec 3<>/dev/tcp/192.168.1.1/80" 2>/dev/null; echo RC=$?')"
    case "$PROBE_OUT" in
        *RC=124*) pass "VM->LAN pivot TCP probe TIMED OUT at 192.168.1.1:80 (dropped — guard effective)" ;;
        *RC=126*|*RC=127*) fail "VM->LAN pivot TCP probe could not run (rc=126/127) — INCONCLUSIVE" ;;
        *RC=0*|*RC=1*) fail "VM reached 192.168.1.1:80 (connected/refused) — pivot guard NOT effective" ;;
        *) fail "VM->LAN pivot probe INCONCLUSIVE (no rc from the VM — ssh failure?): '${PROBE_OUT:-<empty>}'" ;;
    esac
    PING_OUT="$(vmrun 'sudo ping -c1 -W3 192.168.1.1 >/dev/null 2>&1; echo RC=$?')"
    case "$PING_OUT" in
        *RC=0*)   fail "VM->LAN pivot ping probe REACHED 192.168.1.1 — pivot rule regression" ;;
        *RC=124*) note "ping to 192.168.1.1 timed out (secondary; ICMP-drop alone proves nothing)" ;;
        *RC=1*)   note "ping to 192.168.1.1 got no reply (secondary; ICMP-drop alone proves nothing)" ;;
        *)        note "ping probe inconclusive (ssh failure?) — primary TCP probe is authoritative" ;;
    esac
fi

# -----------------------------------------------------------------------------
# S7 — kill-switch live evidence (in-VM)
# -----------------------------------------------------------------------------
if [ "$SSH_UP" -eq 1 ]; then
    echo
    echo "--- S7: kill-switch inside media-vm ---"
    UFWS="$(vmrun "sudo ufw status" 2>/dev/null | head -n30)"
    echo "$UFWS" | sed 's/^/  |vmufw| /'
    echo "$UFWS" | grep -qE "6881:6889.*DENY|DENY.*6881:6889" \
        && pass "VM ufw deny rows for 6881:6889 present" \
        || fail "VM ufw deny 6881:6889 rows missing"
    DU="$(vmrun "sudo iptables -S DOCKER-USER 2>/dev/null" 2>/dev/null)"
    echo "$DU" | sed 's/^/  |docker-user| /'
    NDROP="$(echo "$DU" | grep -cE '\-\-dport 6881:6889.*DROP')"
    [ "$NDROP" -ge 2 ] && pass "DOCKER-USER carries >=2 torrent-port DROP rules (tcp+udp)" \
                       || fail "DOCKER-USER torrent-port DROP count = $NDROP (want >=2)"
    # fix 52 — the single forwarded port is denied on the clearnet NIC too
    U514="$(echo "$UFWS" | grep -cE '37686.*DENY|DENY.*37686')"
    [ "$U514" -ge 2 ] && pass "VM ufw deny rows for 37686 present (tcp+udp)" \
                      || fail "VM ufw deny 37686 rows missing (found $U514)"
    NDROP514="$(echo "$DU" | grep -cE '\-\-dport 37686.*DROP')"
    [ "$NDROP514" -ge 2 ] && pass "DOCKER-USER carries >=2 DROP rules for 37686 (tcp+udp)" \
                          || fail "DOCKER-USER 37686 DROP count = $NDROP514 (want >=2)"
    # fix 7 — inbound source guard on ALL published stack ports (docker
    # published ports bypass ufw INPUT; DOCKER-USER is the enforcement point)
    # fix 48 — the inbound guard matches on conntrack --ctorigdstport (the
    # pre-DNAT published port), NOT --dport; the old regex counted 0 while
    # six DROP rows were plainly present in the same output.
    NIN="$(printf '%s\n' "$DU" | grep -cE '! -s 192\.168\.122\.0/24.*--ctorigdstport [0-9]+.*--ctdir ORIGINAL.*-j DROP')"
    [ "$NIN" -ge 8 ] && pass "DOCKER-USER inbound source guard covers all 8 stack ports" \
                      || fail "DOCKER-USER inbound guard count = $NIN (want >=8)"
    if [ "$VPN_HAS_CREDS" -eq 1 ]; then
        GH="$(vmrun "sudo docker inspect -f '{{.State.Health.Status}}' gluetun 2>/dev/null" 2>/dev/null)"
        case "$GH" in
            healthy) pass "gluetun healthcheck: healthy (tunnel established)" ;;
            starting) note "gluetun healthcheck still 'starting' — re-run diag in a minute" ;;
            *) fail "gluetun healthcheck: '${GH:-unknown}' (tunnel may be failing)" ;;
        esac
    else
        note "S7 gluetun healthcheck skipped — no real credentials yet (expected DOWN)"
    fi
else
    note "S7 skipped (SSH down)"
fi

# -----------------------------------------------------------------------------
# S8 — Phase 3/4 services untouched
# -----------------------------------------------------------------------------
echo
echo "--- S8: Phase 3/4 loopback services untouched ---"
for U in litellm hermes-serve hermes-api; do
    if systemctl is-active --quiet "$U"; then
        pass "$U active"
    else
        fail "$U NOT active"
    fi
done
PBAD=0
for P in 4000 8642 9119; do
    L="$(ss -tlnH "sport = :$P" 2>/dev/null | awk '{print $4}' | sort -u)"
    if [ "$L" = "127.0.0.1:$P" ]; then
        pass "127.0.0.1:$P listener strict"
    else
        fail ":$P listener changed: '$L'"
        PBAD=1
    fi
done
ALT="$(ss -tlnH 2>/dev/null | awk '{print $4}' | grep -vE '^127\.0\.0\.1:' | grep -E ':(4000|8642|9119)$' || true)"
if [ -n "$ALT" ]; then
    fail "phase 3/4 ports bound on non-loopback interfaces: $ALT"
else
    [ "$PBAD" -eq 0 ] && pass "no phase 3/4 port bound off-loopback anywhere"
fi

# -----------------------------------------------------------------------------
# S9 — host posture (SSH/UFW/LVM)
# -----------------------------------------------------------------------------
echo
echo "--- S9: host posture (SSH, ufw default, jordan) ---"
L22="$(ss -tlnH 'sport = :22' 2>/dev/null | awk '{print $4}' | sort -u | tr '\n' '|')"
echo "  ssh: $L22"
[ "$L22" = "127.0.0.1:22|192.168.1.133:22|" ] && pass "SSH listeners unchanged" \
                                              || fail "SSH listener set changed: $L22"
if ufw status 2>/dev/null | head -n1 | grep -q active; then
    pass "ufw active"
else
    fail "ufw not active"
fi
# fix 44 — same parser as phase5_apply V10: ufw prints
# "Default: deny (incoming), ..." in lowercase, so match the real line.
UFW_DEF="$(ufw status verbose 2>/dev/null | grep -m1 '^Default:' || true)"
case "$UFW_DEF" in
    "Default: deny (incoming)"*) pass "ufw default incoming deny preserved" ;;
    *)                           fail "ufw default incoming policy changed" ;;
esac
# fix 46 — exact row match (plain `ufw status` prints "ALLOW", not "ALLOW IN");
# the old substring test was satisfied by the SSH row, so a missing 8096 rule
# could still "pass".
UFWS="$(ufw status 2>/dev/null)"
UFW_ROW_8096='^8096/tcp( on [^[:space:]]+)?[[:space:]]+(ALLOW|LIMIT)( IN)?[[:space:]]+192\.168\.1\.0/24'
UFW_ROW_7359='^7359/udp( on [^[:space:]]+)?[[:space:]]+(ALLOW|LIMIT)( IN)?[[:space:]]+192\.168\.1\.0/24'
# fix 52 — family requests UI (host Caddy TLS terminator)
UFW_ROW_8443='^8443/tcp( on [^[:space:]]+)?[[:space:]]+(ALLOW|LIMIT)( IN)?[[:space:]]+192\.168\.1\.0/24'
UFW_ANY_ROW='^(8096/tcp|7359/udp|8443/tcp)( \(v6\))?( on [^[:space:]]+)?[[:space:]]+(ALLOW|LIMIT)( IN)?[[:space:]]+(Anywhere|0\.0\.0\.0/0|::/0)'
if printf '%s\n' "$UFWS" | grep -qE "$UFW_ROW_8096"; then
    pass "ufw allows 8096/tcp from 192.168.1.0/24 only (exact row)"
else
    fail "ufw has no '8096/tcp ... ALLOW 192.168.1.0/24' row"
fi
if printf '%s\n' "$UFWS" | grep -qE "$UFW_ROW_7359"; then
    pass "ufw allows 7359/udp from 192.168.1.0/24 only (exact row)"
else
    fail "ufw has no '7359/udp ... ALLOW 192.168.1.0/24' row"
fi
if printf '%s\n' "$UFWS" | grep -qE "$UFW_ROW_8443"; then
    pass "ufw allows 8443/tcp from 192.168.1.0/24 only (exact row — family requests UI)"
else
    fail "ufw has no '8443/tcp ... ALLOW 192.168.1.0/24' row"
fi
if printf '%s\n' "$UFWS" | grep -qE "$UFW_ANY_ROW"; then
    fail "wildcard-source 8096/7359/8443 allow present (must be LAN-subnet only)"
else
    pass "no wildcard-source 8096/7359/8443 allow"
fi
JP="$(stat -c '%U:%G %a' /home/jordan 2>/dev/null)"
[ "$JP" = "jordan:jordan 750" ] && pass "/home/jordan 750 jordan:jordan" || fail "/home/jordan: $JP"
# fix 71 — the permanent qBt WebUI credential (written by
# `qbt_admin.sh --set-password`). Optional on a brand-new install, but if it
# exists it must stay root-only: every helper reads it.
QBPWF=/etc/media-vm/qbt_webui_password
if [ -f "$QBPWF" ]; then
    QP="$(stat -c '%U:%G %a' "$QBPWF" 2>/dev/null)"
    case "$QP" in
        "root:root 600") pass "$QBPWF root:root 600 (permanent qBt WebUI credential — fix 71)" ;;
        *)               fail "$QBPWF is '$QP' — want 'root:root 600' (fix 71)" ;;
    esac
else
    note "$QBPWF absent — qBittorrent still uses its first-run temporary password (qbt_admin.sh --set-password)"
fi

# -----------------------------------------------------------------------------
# S10 — media-assistant .env harvest (masked)
# -----------------------------------------------------------------------------
echo
echo "--- S10: /opt/media-assistant/.env harvest + line-shape (masked) ---"
if [ -f "$MEDIA_ASSISTANT_ENV" ]; then
    LINTOUT="$(env_lint "$MEDIA_ASSISTANT_ENV")"
    LR="$?"
    [ -n "$LINTOUT" ] && [ "$LINTOUT" != "missing" ] && echo "$LINTOUT"
    [ "$LR" -eq 0 ] && pass "media-assistant .env line-shape clean (all lines VAR=value)" \
                    || fail "media-assistant .env line-shape violations above"
    N="$(grep -cvE '^[[:space:]]*(#|$)' "$MEDIA_ASSISTANT_ENV" || true)"
    echo "  real value lines: $N (names only):"
    grep -oE '^[A-Z_]+=' "$MEDIA_ASSISTANT_ENV" 2>/dev/null | sed 's/=$//' | sed 's/^/    /'
    MISS=0
    for K in PROWLARR_URL PROWLARR_API_KEY RADARR_URL RADARR_API_KEY \
             LIDARR_URL LIDARR_API_KEY SONARR_URL SONARR_API_KEY \
             BAZARR_URL BAZARR_API_KEY JELLYFIN_URL QBITTORRENT_URL; do
        grep -qE "^${K}=[^[:space:]#]+" "$MEDIA_ASSISTANT_ENV" || MISS=$((MISS + 1))
    done
    if [ "$MISS" -eq 0 ]; then
        pass "all 12 harvested media keys present (values never echoed)"
    elif [ "$SSH_UP" -eq 1 ]; then
        fail "$MISS of 12 harvest keys still missing URLs/API keys"
        echo "         (containers may still be writing first-boot configs — re-run phase5_apply.sh)"
    else
        note "$MISS of 12 harvest keys missing — VM unreachable this run"
    fi
    OW="$(stat -c '%U:%G %a' "$MEDIA_ASSISTANT_ENV" 2>/dev/null)"
    [ "$OW" = "mediabot:mediabot 600" ] && pass ".env is 600 mediabot:mediabot" \
                                        || fail ".env ownership/mode: $OW"
else
    note "$MEDIA_ASSISTANT_ENV missing (a successful apply creates + fills it)"
fi
# host vpn.env shape too (when present)
if [ -f "$VPN_ENV_HOST" ]; then
    LV="$(env_lint "$VPN_ENV_HOST")"
    RV="$?"
    [ -n "$LV" ] && [ "$LV" != "missing" ] && echo "$LV"
    [ "$RV" -eq 0 ] && pass "host vpn.env line-shape clean" \
                    || fail "host vpn.env line-shape violations above"
    NC="$(grep -cvE '^[[:space:]]*(#|$)' "$VPN_ENV_HOST" || true)"
    if [ "$NC" -eq 0 ]; then
        echo "  vpn.env is still a comment-only skeleton (gluetun/qbt correctly gated)"
    else
        echo "  vpn.env holds $NC real value line(s) — key NAMES only:"
        grep -oE '^[A-Z_]+=' "$VPN_ENV_HOST" 2>/dev/null | sed 's/=$//' | sed 's/^/    /'
    fi
else
    note "host vpn.env missing (a successful apply creates the skeleton)"
fi
# -----------------------------------------------------------------------------
# S11 — media normalization (fix 59): one audio, no TrueHD/Atmos, no embedded subs
# -----------------------------------------------------------------------------
echo
echo "--- S11: media normalization (fix 59) ---"
if [ "$SSH_UP" -eq 1 ]; then
    MNS="$(vmrun "sudo stat -c '%U:%G %a' /usr/local/sbin/media-normalize 2>/dev/null")"
    [ "$MNS" = "root:root 700" ] && pass "media-normalize script root:root 700" \
                                || fail "media-normalize script: ${MNS:-absent}"
    MT="$(vmrun 'systemctl is-active media-normalize.timer 2>/dev/null')"
    MP="$(vmrun 'systemctl is-active media-normalize.path 2>/dev/null')"
    [ "$MT" = "active" ] && pass "media-normalize.timer active (10-min sweep)" \
                        || fail "media-normalize.timer is '${MT:-absent}'"
    [ "$MP" = "active" ] && pass "media-normalize.path active (new-title trigger)" \
                        || fail "media-normalize.path is '${MP:-absent}'"
    NF="$(vmrun 'sudo grep -c "fail(" /var/log/media-normalize.log 2>/dev/null')"
    [ "${NF:-0}" -eq 0 ] && pass "no normalizer failures logged" \
                        || note "$NF normalizer failure line(s) — sudo tail /var/log/media-normalize.log"
    echo "  recent normalizer log (track counts only, never media content):"
    vmrun 'sudo tail -n 5 /var/log/media-normalize.log 2>/dev/null' | sed 's/^/    /'
    # visibility only (not a FAIL): the newest library file's stream shape.
    # "audio=1 subs=0" is the target; a fresh import is expected to show more
    # until the next sweep picks it up.
    NEWF="$(vmrun "sudo find /data/media/movies -type f \\( -iname '*.mkv' -o -iname '*.mp4' \\) -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-")"
    if [ -n "$NEWF" ]; then
        NA="$(vmrun "sudo docker run --rm --entrypoint /usr/lib/jellyfin-ffmpeg/ffprobe -v '$NEWF':'$NEWF':ro jellyfin/jellyfin:12.4 -v error -select_streams a -show_entries stream=index -of csv=p=0 '$NEWF' 2>/dev/null | grep -c .")"
        NS="$(vmrun "sudo docker run --rm --entrypoint /usr/lib/jellyfin-ffmpeg/ffprobe -v '$NEWF':'$NEWF':ro jellyfin/jellyfin:12.4 -v error -select_streams s -show_entries stream=index -of csv=p=0 '$NEWF' 2>/dev/null | grep -c .")"
        note "newest library file streams: audio=${NA:-?} subs=${NS:-?} (target audio=1 subs=0)"
    fi
else
    note "S11 skipped (VM unreachable)"
fi

# journal quick-scan (host units Phase 5 owns)
# fix 51 — scan THIS boot only: `journalctl -n 60` without -b reaches back
# through earlier boots, so the pre-fix 2026-11-10 23:34 bind failures were
# reported as current forever even though the live boot was clean. Deliberate
# stops are not failures: apply restarts these relays and systemd logs the
# SIGTERM as `status=143` + `Failed with result 'exit-code'`.
for U in jellyfin-lan-proxy.socket jellyfin-discovery.service caddy.service; do
    ERRS="$(journalctl -b -u "$U" -n 60 --no-pager 2>/dev/null \
        | awk '
            /status=143|exiting on signal 15|Stopping |Stopped / { stop=1; next }
            /Failed with result .exit-code./ && stop == 1 { next }
            { stop=0; print }
        ' \
        | grep -ciE 'traceback|critical|failed|denied|ordering cycle|deleted to break' || true)"
    if [ "${ERRS:-0}" -ge 1 ]; then
        note "$U: $ERRS error-signature line(s) in this boot — review: journalctl -b -u $U -n 20"
    else
        pass "$U journal clean of failure signatures (this boot)"
    fi
done

echo
echo "=== Phase 5 live smoke complete ==="
echo "=== VERIFY_FAILS=$FAILS ==="
if [ "$FAILS" -gt 0 ]; then
    echo "Paste EVERYTHING above back to the agent (no secrets in output — all values masked)." >&2
fi
exit 0

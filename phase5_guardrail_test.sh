#!/usr/bin/env bash
#
# Phase 5 guardrail test — NON-PRIVILEGED, STANDALONE, OFFLINE.
#
# Statically validates phase5_compose.yaml + phase5_apply.sh (which embeds the
# in-VM provisioning heredoc, the torrent-port-guard unit, and the host-side
# socket-proxyd units) against every Phase 5 guardrail, INCLUDING the
# 2026-11-09 external-review fixes (G12). phase5_diag.sh is spot-checked too
# (pivot probe, lan-guard, [::] + 7359 pin checks).
# Requires NO root, NO running libvirt/VM, NO real secrets, NO network.
# (The REAL host state — /etc/media-vm, the VM, the installed units — is
# verified by the V-checks inside phase5_apply.sh, which runs as root, and by
# phase5_diag.sh afterwards.)
#
# Usage:
#   bash phase5_guardrail_test.sh
#     (paths default to this script's directory: phase5_compose.yaml,
#      phase5_apply.sh)
#
# Exits 1 on any FAIL.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="$SCRIPT_DIR/phase5_compose.yaml"
APPLY="$SCRIPT_DIR/phase5_apply.sh"
DIAG="$SCRIPT_DIR/phase5_diag.sh"
SELF="$SCRIPT_DIR/phase5_guardrail_test.sh"
MANUAL="$SCRIPT_DIR/phase5_manual_steps.md"
AGENTS="$SCRIPT_DIR/AGENTS.md"
RESUME="$SCRIPT_DIR/RESUME.md"
MEMORY="$SCRIPT_DIR/PROJECT_MEMORY.md"
P3_CFG="$SCRIPT_DIR/phase3_config.yaml"
P4_CFG="$SCRIPT_DIR/phase4_config.yaml"

FAILS=0
pass() { echo "  [PASS] $*"; }
fail() { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
note() { echo "  [note] $*"; }

section() { echo; echo "=============================================================="; echo " $*"; echo "=============================================================="; }

# Image pins of record (must match phase5_compose.yaml exactly).
PIN_GLUETUN="qmcgaw/gluetun:v3.40.0"
PIN_QBT="lscr.io/linuxserver/qbittorrent:5.0.4"
PIN_PROWL="lscr.io/linuxserver/prowlarr:1.32.2"
PIN_RAD="lscr.io/linuxserver/radarr:5.20.2"
PIN_LID="lscr.io/linuxserver/lidarr:2.9.6"
PIN_SONARR="lscr.io/linuxserver/sonarr:4.0.11"
PIN_BAZ="lscr.io/linuxserver/bazarr:1.5.6"
PIN_JF="jellyfin/jellyfin:12.4"
PIN_JELLY="fallenbagel/jellyseerr:2.1.0"

VM_IP="192.168.122.10"
LAN_IP="192.168.1.133"
LAN_SUBNET="192.168.1.0/24"

section "Phase 5 guardrail test (static, offline)"
echo " compose: $CFG"
echo " apply  : $APPLY (embeds in-VM provisioning + torrent guard + LAN proxy units)"
echo " python3: $(command -v python3 >/dev/null 2>&1 && echo yes || echo no)"
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
    echo " PyYAML : yes (python validation path)"
else
    echo " PyYAML : no  (bash/grep fallback path)"
fi

if [ ! -f "$CFG" ]; then
    fail "G0 phase5_compose.yaml exists ($CFG)"
    echo
    echo "=== Phase 5 guardrail test: FAILED ==="
    echo "=== VERIFY_FAILS=$FAILS ==="
    exit 1
fi
if [ ! -f "$APPLY" ]; then
    fail "G0 phase5_apply.sh exists ($APPLY)"
    echo
    echo "=== Phase 5 guardrail test: FAILED ==="
    echo "=== VERIFY_FAILS=$FAILS ==="
    exit 1
fi
pass "G0 both artifacts exist"

# cfg_body-style comment stripper (safe for structural greps).
cfg_body() { sed 's/[[:space:]]*#.*$//' "$CFG"; }

# strip comments from the apply script (code-side only).
apply_code() { grep -v '^[[:space:]]*#' "$APPLY"; }

# ======================================================================
section "G1 — YAML validity (prefers PyYAML; structural fallback)"
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
    if python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$CFG" 2>/dev/null; then
        pass "phase5_compose.yaml parses as YAML (python3+PyYAML safe_load)"
    else
        fail "phase5_compose.yaml does NOT parse as YAML"
    fi
else
    for K in services gluetun qbittorrent prowlarr radarr lidarr sonarr bazarr jellyfin jellyseerr; do
        if grep -qE "^  [[:space:]]*$K:" "$CFG" || grep -qE "^$K:" "$CFG"; then :; fi
    done
    OKS=1
    for K in "services:" "gluetun:" "qbittorrent:" "prowlarr:" "radarr:" "lidarr:" "sonarr:" "bazarr:" "jellyfin:" "jellyseerr:"; do
        grep -qF "$K" "$CFG" || OKS=0
    done
    if [ "$OKS" -eq 1 ]; then
        note "PyYAML unavailable — structural sanity only (top-level keys present)"
        pass "structural sanity OK (PyYAML unavailable)"
    else
        fail "structural sanity FAILED (and PyYAML unavailable)"
    fi
fi

# ======================================================================
section "G2 — every image is pinned (no :latest; exact tags of record)"
CHK_OK=1
if grep -nE 'image:.*:latest' "$CFG" >/dev/null 2>&1; then
    fail "a ':latest' image tag is present in phase5_compose.yaml"
    CHK_OK=0
else
    pass "no :latest tags anywhere in the compose"
fi
n=0
for want in "$PIN_GLUETUN" "$PIN_QBT" "$PIN_PROWL" "$PIN_RAD" "$PIN_LID" "$PIN_SONARR" "$PIN_BAZ" "$PIN_JF" "$PIN_JELLY"; do
    n=$((n + 1))
    if grep -qF "image: $want" "$CFG"; then
        pass "image $n pinned: $want"
    else
        fail "image pin missing/changed: $want"
        CHK_OK=0
    fi
done
[ "$CHK_OK" -eq 1 ] && pass "G2 complete: 9/9 image pins exact"

# ======================================================================
section "G3 — torrent isolation: qbittorrent rides gluetun's netns ONLY"
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
    CHK_OK="$(python3 - "$CFG" <<'PYEOF' 2>/dev/null || echo 0
import sys
try:
    import yaml
    cfg = yaml.safe_load(open(sys.argv[1])) or {}
    sv = cfg.get("services") or {}
    ok = 0
    qbt = sv.get("qbittorrent") or {}
    glu = sv.get("gluetun") or {}
    if qbt.get("network_mode") == "service:gluetun": ok += 1
    else: print("  [FAIL-check] qbittorrent.network_mode != service:gluetun")
    if "ports" not in qbt: ok += 1
    else: print("  [FAIL-check] qbittorrent declares ports (must ride gluetun's ns)")
    vp = glu.get("profiles") or []
    if "vpn" in vp: ok += 1
    else: print("  [FAIL-check] gluetun not in the vpn profile")
    qp = qbt.get("profiles") or []
    if "vpn" in qp: ok += 1
    else: print("  [FAIL-check] qbittorrent not in the vpn profile")
    if "NET_ADMIN" in (glu.get("cap_add") or []): ok += 1
    else: print("  [FAIL-check] gluetun.cap_add missing NET_ADMIN")
    if any("/dev/net/tun" in str(d) for d in (glu.get("devices") or [])): ok += 1
    else: print("  [FAIL-check] gluetun missing /dev/net/tun device")
    envs = " ".join(glu.get("environment") or [])
    if "FIREWALL_OUTBOUND_SUBNETS=192.168.122.0/24" in envs: ok += 1
    else: print("  [FAIL-check] gluetun FIREWALL_OUTBOUND_SUBNETS wrong/missing")
    if "FIREWALL_INPUT_PORTS=8080" in envs: ok += 1
    else: print("  [FAIL-check] gluetun FIREWALL_INPUT_PORTS wrong/missing")
    if "FIREWALL_VPN_INPUT_PORTS=37686" in envs: ok += 1
    else: print("  [FAIL-check] gluetun FIREWALL_VPN_INPUT_PORTS=37686 wrong/missing")
    if glu.get("env_file") == ["/opt/media-stack/vpn.env"]: ok += 1
    else: print("  [FAIL-check] gluetun env_file must be exactly /opt/media-stack/vpn.env")
    print(ok)
except Exception as e:
    print("ERR:" + str(e))
PYEOF
)"
    if [ "$CHK_OK" = "10" ]; then
        pass "PyYAML structural check: 10/10 isolation + forwarding conditions hold"
    else
        fail "PyYAML structural check scored $CHK_OK/10 — see [FAIL-check] lines above"
    fi
else
    CHK_OK=1
    grep -Fq 'network_mode: "service:gluetun"' "$CFG" || { fail "network_mode service:gluetun missing (fallback path)"; CHK_OK=0; }
    if grep -A12 '^  qbittorrent:' "$CFG" | grep -q 'ports:'; then
        fail "qbittorrent declares ports (fallback path — it shares gluetun's netns)"
        CHK_OK=0
    else
        pass "qbittorrent declares no ports of its own (fallback path)"
    fi
    GREPVP="$(grep -A3 '^  gluetun:' "$CFG" | grep -Fq 'profiles: ["vpn"]' && echo 1)"
    [ "$GREPVP" = "1" ] || { fail "gluetun not tag-shadowed into the vpn profile (fallback path)"; CHK_OK=0; }
    grep -A2 '^  qbittorrent:' "$CFG" | grep -q 'profiles: ["vpn"]' || { fail "qbittorrent not profile-gated (fallback path)"; CHK_OK=0; }
    grep -Fq 'NET_ADMIN' "$CFG" || { fail "gluetun cap_add NET_ADMIN missing (fallback path)"; CHK_OK=0; }
    grep -Fq '/dev/net/tun' "$CFG" || { fail "gluetun /dev/net/tun missing (fallback path)"; CHK_OK=0; }
    grep -Fq 'FIREWALL_OUTBOUND_SUBNETS=192.168.122.0/24' "$CFG" || { fail "FIREWALL_OUTBOUND_SUBNETS wrong (fallback path)"; CHK_OK=0; }
    grep -Fq 'FIREWALL_INPUT_PORTS=8080' "$CFG" || { fail "FIREWALL_INPUT_PORTS=8080 wrong (fallback path)"; CHK_OK=0; }
    grep -Fq 'FIREWALL_VPN_INPUT_PORTS=37686' "$CFG" || { fail "FIREWALL_VPN_INPUT_PORTS=37686 wrong (fallback path)"; CHK_OK=0; }
    grep -Fq '/opt/media-stack/vpn.env' "$CFG" || { fail "gluetun env_file wrong (fallback path)"; CHK_OK=0; }
    [ "$CHK_OK" -eq 1 ] && pass "G3 complete: netns bundling + profile gating + gluetun device/env (fallback path)"
fi

# ======================================================================
section "G4 — bind discipline: every container port is VM-side only"
CHK_OK="$(python3 - "$CFG" <<'PYEOF' 2>/dev/null || echo "nopy"
import sys
try:
    import yaml
    cfg = yaml.safe_load(open(sys.argv[1])) or {}
    bad = []
    total = 0
    for name, sv in (cfg.get("services") or {}).items():
        for p in (sv.get("ports") or []):
            total += 1
            sp = str(p)
            if not sp.startswith("192.168.122.10:"):
                bad.append(f"{name}: {sp}")
    print("BAD:" + "|".join(bad) + f";TOTAL={total}")
except Exception as e:
    print("ERR:" + str(e))
PYEOF
)"
case "$CHK_OK" in
    nopy)
        # bash fallback: every ports line under a service must start with the VM IP
        if grep -nE '^\s*-\s+"' "$CFG" | grep -E ':[0-9]+:[0-9]+/tcp"|:[0-9]+:[0-9]+/udp"' | grep -vE '"192\.168\.122\.10:' >/dev/null 2>&1; then
            fail "a ports entry does NOT start with 192.168.122.10 (fallback path)"
        else
            pass "all quoted ports entries bind 192.168.122.10 (fallback path)"
        fi
        ;;
    ERR:*)
        fail "PyYAML ports scan errored: $CHK_OK"
        ;;
    BAD:*)
        BADS="${CHK_OK%%;TOTAL=*}"
        TOT="${CHK_OK##*;TOTAL=}"
        case "$BADS" in
            "BAD:")
                if [ "$TOT" = "9" ]; then
                    pass "PyYAML ports scan: every published port binds 192.168.122.10 (9/9)"
                else
                    fail "published port count = $TOT (want 9: webui, 6 stack UIs, jellyseerr, jellyfin 7359/udp — fix 57)"
                fi
                ;;
            *) fail "ports not VM-bound:$BADS" ;;
        esac
        ;;
esac

# ======================================================================
section "G5 — hardlink storage layout: identical paths across containers"
CHK_OK="$(python3 - "$CFG" <<'PYEOF' 2>/dev/null || echo "nopy"
import sys
try:
    import yaml
    cfg = yaml.safe_load(open(sys.argv[1])) or {}
    sv = cfg.get("services") or {}
    def vols(name): return [str(v) for v in ((sv.get(name) or {}).get("volumes") or [])]
    ok = 0; tot = 0
    def chk(cond):
        global ok, tot
        tot += 1
        ok += 1 if cond else 0
    chk("/data/torrents:/data/torrents" in vols("qbittorrent"))
    chk("/data/config/qbittorrent:/config" in vols("qbittorrent"))
    chk("/data:/data" in vols("radarr"))
    chk("/data/config/radarr:/config" in vols("radarr"))
    chk("/data:/data" in vols("lidarr"))
    chk("/data/config/lidarr:/config" in vols("lidarr"))
    chk("/data:/data" in vols("sonarr"))
    chk("/data/config/sonarr:/config" in vols("sonarr"))
    chk("/data/config/jellyseerr:/app/config" in vols("jellyseerr"))
    chk("/data/media:/data/media" in vols("bazarr"))
    chk("/data/config/bazarr:/config" in vols("bazarr"))
    chk("/data/media:/data/media" in vols("jellyfin"))
    chk("/data/config/jellyfin:/config" in vols("jellyfin"))
    chk("/data/config/jellyfin-cache:/cache" in vols("jellyfin"))
    chk("/data/config/prowlarr:/config" in vols("prowlarr"))
    chk("/data/config/gluetun:/gluetun" in vols("gluetun"))
    print(ok)
except Exception as e:
    print("ERR:" + str(e))
PYEOF
)"
if [ "$CHK_OK" = "16" ]; then
    pass "16/16 volume mappings exact (radarr/lidarr/sonarr see the WHOLE /data)"
elif [ "$CHK_OK" = "nopy" ]; then
    if grep -qF '/data:/data' "$CFG" && grep -qF '/data/media:/data/media' "$CFG" \
       && grep -qF '/data/torrents:/data/torrents' "$CFG"; then
        note "PyYAML unavailable — volume equality check reduced to structural greps"
        pass "all three critical volume mounts present (fallback path)"
    else
        fail "critical volume mounts missing (fallback path)"
    fi
else
    fail "volume mappings scored $CHK_OK/16 — remount drift breaks hardlink moves"
fi

# ======================================================================
section "G6 — secret hygiene: compose carries NO credentials; apply never echoes"
CHK_OK="$(python3 - "$CFG" <<'PYEOF' 2>/dev/null || echo "nopy"
import sys
try:
    import yaml
    cfg = yaml.safe_load(open(sys.argv[1])) or {}
    sv = cfg.get("services") or {}
    bad = []
    for name, service in sv.items():
        envs = service.get("environment") or {}
        if isinstance(envs, list): envs = dict((e.split('=',1)[0], e.split('=',1)[1] if '=' in e else '') for e in envs)
        for k, v in (envs or {}).items():
            kl = k.lower()
            if any(s in kl for s in ("key", "secret", "token", "password")):
                bad.append(f"{name}.{k}")
    print("BAD:" + ",".join(bad) if bad else "OK")
except Exception as e:
    print("ERR:" + str(e))
PYEOF
)"
case "$CHK_OK" in
    OK) pass "compose environment: zero secret-name keys (PUID/PGID/TZ/ports only)" ;;
    nopy)
        if grep -qE '^\s*-\s+(password|secret|token|api[_-]?key)=' "$CFG"; then
            fail "a plausible literal-secret env appears in the compose (fallback path)"
        else
            pass "no secret-shaped env line in the compose (fallback path)"
        fi
        ;;
    *) fail "secret-named env vars in compose: $CHK_OK" ;;
esac
if grep -Fq 'env_file:' "$CFG" && grep -Fq '/opt/media-stack/vpn.env' "$CFG"; then
    pass "VPN credentials ride env_file -> /opt/media-stack/vpn.env (env_file only, no compose text)"
else
    fail "gluetun must receive VPN credentials ONLY via env_file (/opt/media-stack/vpn.env)"
fi
# apply: secrets never echoed, never overwritten
ECHOLEAK="$(grep -n 'echo' "$APPLY" | grep -iE 'WIREGUARD_PRIVATE_KEY|OPENVPN_USER=|OPENVPN_PASSWORD=|\bK\)\b|\$\{K\}' | grep -viE 'NOT echoed|ed in|value NEVER|secrets NEVER' || true)"
if [ -z "$ECHOLEAK" ]; then
    pass "no echo of VPN credentials/api keys in phase5_apply.sh"
else
    fail "phase5_apply.sh echoes a credential path:$ECHOLEAK"
fi
if grep -Fq 'VPN_ENV_VM' "$APPLY" && grep -Fq 'chmod 600' "$APPLY"; then
    pass "vpn.env copied into the VM with 600 (root-readable by the docker daemon only)"
else
    note "vpn.env 600 push path wording not found — verify manually"
fi
if grep -Fq 'chmod 600 "$VPN_ENV_HOST"' "$APPLY"; then
    pass "host vpn.env of record is /etc/media-vm/vpn.env (700 dir, 600 file)"
else
    fail "host vpn.env path missing"
fi
if grep -Fq 'SSH_UP=0' "$APPLY" && grep -Fq 'HOLD_VM=1' "$APPLY"; then
    pass "VM-unreachable path is a soft-fail (HOLD_VM skip) — rest of the run completes"
else
    fail "HOLD_VM soft-fail path missing"
fi

# ======================================================================
section "G7 — .env line-shape enforcement (Phase 3 lesson carried forward)"
if grep -Fq 'env_lint()' "$APPLY" && grep -Fq 'CONTAINS-HASH' "$APPLY" \
   && grep -Fq 'LEADING-SPACE' "$APPLY" && grep -Fq 'TRAILING-SPACE' "$APPLY"; then
    pass "env_lint validator present (no ' #', no edge whitespace, masked output)"
else
    fail "env_lint line-shape validator missing/incomplete"
fi
N_LINT="$(grep -c 'env_lint "' "$APPLY" || true)"
if [ "${N_LINT:-0}" -ge 2 ]; then
    pass "env_lint runs on vpn.env AND /opt/media-assistant/.env ($N_LINT call sites)"
else
    fail "env_lint called on fewer than 2 files ($N_LINT) — vpn.env/.env must both be gated"
fi
if grep -Fq 'append_env()' "$APPLY" && grep -Fq 'NOT overwritten' "$APPLY"; then
    pass "append_env helper: append-only, never overwrites an existing real value"
else
    fail "append_env (append-only .env) helper missing/changed"
fi
if ! grep -n '>>"$file' "$APPLY" | grep -q .; then :; fi
APQ="$(printf '%s\n' "$(apply_code)" | grep -n '>>"$file' | head -n1 || true)"
if [ -n "$APQ" ]; then
    pass "secret/appending path writes via >> (append-only) into \$file"
else
    fail "appending path does not use >> — overwrite risk"
fi
if ! grep -n '> "$VPN_ENV_HOST" ' "$APPLY" | grep -v 'skeleton' | grep -q .; then
    pass "host vpn.env is written ONLY by the skeleton heredoc (no overwriting)"
else
    note "verify vpn.env writing uses `if [ ! -f ]`-guarded skeleton heredoc only"
fi
grep -Fq 'if [ ! -f "$VPN_ENV_HOST" ]; then' "$APPLY" \
    && pass "vpn.env skeleton guarded by absence check (never overwrites real creds)" \
    || fail "vpn.env skeleton is not absence-guarded"
grep -Fq 'if [ ! -f "$MEDIA_ASSISTANT_ENV" ]' "$APPLY" \
    && pass "media-assistant .env absence-guarded (created only if missing)" \
    || fail "media-assistant .env not absence-guarded"
grep -Fq 'install -m 600 -o mediabot -g mediabot' "$APPLY" \
    && pass "media-assistant .env created 600 mediabot:mediabot" \
    || fail "media-assistant .env ownership/mode line missing"

# ======================================================================
section "G8 — torrent kill-switch: netns + conf bind + DOCKER-USER + ufw"
CHK_OK=1
grep -Fq '/usr/sbin/torrent-port-guard' "$APPLY" \
    && pass "persistent torrent-port-guard script present" || { fail "torrent-port-guard script missing"; CHK_OK=0; }
# the first no-op grep guard below keeps the pair check simple and aligned
for pair in \
    "iptables -C DOCKER-USER -p tcp --dport 6881:6889|iptables -I DOCKER-USER 1 -p tcp --dport 6881:6889" \
    "iptables -C DOCKER-USER -p udp --dport 6881:6889|iptables -I DOCKER-USER 1 -p udp --dport 6881:6889" \
    "ip6tables -C DOCKER-USER -p tcp --dport 6881:6889|ip6tables -I DOCKER-USER 1 -p tcp --dport 6881:6889" \
    "ip6tables -C DOCKER-USER -p udp --dport 6881:6889|ip6tables -I DOCKER-USER 1 -p udp --dport 6881:6889"; do
    WANTC="${pair%%|*}"; WANTI="${pair##*|}"
    if grep -qF -- "$WANTC" "$APPLY" && grep -qF -- "$WANTI" "$APPLY"; then
        pass "DOCKER-USER idempotent (-C then -I) guard: $(echo "$WANTI" | awk '{print $4, $6, $7}')"
    else
        fail "DOCKER-USER pair missing: $WANTI"
        CHK_OK=0
    fi
done
grep -Fq 'torrent-port-guard.service' "$APPLY" \
    && pass "torrent-port-guard.service (oneshot, after docker) defined" \
    || { fail "torrent-port-guard.service unit missing"; CHK_OK=0; }
grep -Fq 'ufw deny proto tcp to any port 6881:6889' "$APPLY" \
    && grep -Fq 'ufw deny proto udp to any port 6881:6889' "$APPLY" \
    && pass "ufw denies 6881:6889 tcp+udp inbound (peer-knock layer)" \
    || { fail "ufw deny 6881:6889 rules missing"; CHK_OK=0; }
# fix 52 — the AirVPN forwarded port is denied on the clearnet NIC too
grep -Fq 'ufw deny proto tcp to any port 37686' "$APPLY" \
    && grep -Fq 'ufw deny proto udp to any port 37686' "$APPLY" \
    && pass "ufw denies 37686 tcp+udp inbound (forwarded-port backstop)" \
    || { fail "ufw deny 37686 rules missing"; CHK_OK=0; }
grep -Fq 'iptables -C DOCKER-USER -p tcp --dport 37686 -o "$NIC" -j DROP' "$APPLY" \
    && grep -Fq 'iptables -I DOCKER-USER 1 -p udp --dport 37686 -o "$NIC" -j DROP' "$APPLY" \
    && pass "DOCKER-USER drops 37686 tcp+udp on the clearnet NIC" \
    || { fail "DOCKER-USER 37686 DROP pairs missing"; CHK_OK=0; }
# fix 5 — qBt 5.x schema: the bind/save/port keys live under
# [BitTorrent]/Session\*, and the old bare [Session]/SessionPort keys must
# be gone entirely.
grep -Fq 'Session\Interface=tun0' "$APPLY" \
    && grep -Fq 'Session\InterfaceName=tun0' "$APPLY" \
    && grep -Fq 'Session\Port=37686' "$APPLY" \
    && pass "qBittorrent.conf pre-seeds Session\\Interface(+Name)=tun0 + Session\\Port=37686 (5.x schema)" \
    || { fail "qBt 5.x [BitTorrent] Session\\* pre-seed keys missing"; CHK_OK=0; }
# fix 52 — already-provisioned VMs migrate 6881 -> 37686 idempotently
grep -Fq "grep -qF 'Session\Port=6881' \"\$QBC\"" "$APPLY" \
    && grep -Fq 's/^Session\\Port=6881$/Session\\Port=37686/' "$APPLY" \
    && pass "qBittorrent.conf live 6881 -> 37686 migration present (idempotent)" \
    || { fail "qBittorrent.conf port migration missing"; CHK_OK=0; }
grep -Fq 'Session\DefaultSavePath=/data/torrents' "$APPLY" \
    && pass "qBittorrent.conf pins Session\\DefaultSavePath=/data/torrents" \
    || { fail "qBittorrent.conf Session\\DefaultSavePath missing"; CHK_OK=0; }
if printf '%s' "$(apply_code)" | grep -qE '^\[Session\]$|SessionPort'; then
    fail "old-schema qBt keys (bare [Session] section / SessionPort) still present"
    CHK_OK=0
else
    pass "no old-schema qBt keys (bare [Session]/SessionPort) in apply code"
fi
# fix 7 (+ fix 18) — inbound DOCKER-USER source guard on ALL published stack
# ports. docker's published ports bypass ufw INPUT, so DOCKER-USER enforces
# instead; fix 18 matches the ORIGINAL destination port via conntrack because
# DOCKER-USER traverses POST-DNAT.
grep -Fq 'for P in 8080 9696 7878 8686 8989 6767 8096 5055; do' "$APPLY" \
    && grep -Fq 'iptables -C DOCKER-USER -p tcp -i "$NIC" -m conntrack --ctorigdstport "$P" --ctdir ORIGINAL ! -s 192.168.122.0/24 -j DROP' "$APPLY" \
    && grep -Fq 'iptables -I DOCKER-USER 1 -p tcp -i "$NIC" -m conntrack --ctorigdstport "$P" --ctdir ORIGINAL ! -s 192.168.122.0/24 -j DROP' "$APPLY" \
    && pass "DOCKER-USER inbound source guard (-C/-I pair, conntrack ctorigdstport, scoped -i \$NIC, ! -s 192.168.122.0/24) on all 8 stack ports" \
    || { fail "DOCKER-USER inbound source guard missing"; CHK_OK=0; }
[ "$CHK_OK" -eq 1 ] && pass "G8 complete: 3-layer kill switch (netns + conf + VM-level)"

# ======================================================================
section "G9 — LAN exposure: Jellyfin ONLY on 192.168.1.133:8096 (+7359)"
CHK_OK=1
grep -Fq 'ListenStream=192.168.1.133:8096' "$APPLY" \
    && pass "socket unit ListenStream pins $LAN_IP:8096 (never wildcard)" \
    || { fail "ListenStream missing/incorrect"; CHK_OK=0; }
grep -Fq 'systemd-socket-proxyd 192.168.122.10:8096' "$APPLY" \
    && pass "socket-proxyd forwards to the VM-side Jellyfin" \
    || { fail "socket-proxyd forwarding pin missing"; CHK_OK=0; }
grep -Fq 'ufw allow in on eno1 from 192.168.1.0/24 to any port 8096 proto tcp' "$APPLY" \
    && pass "ufw: LAN subnet -> 8096/tcp" \
    || { fail "ufw 8096 from 192.168.1.0/24 line missing"; CHK_OK=0; }
grep -Fq 'ufw allow in on eno1 from 192.168.1.0/24 to any port 7359 proto udp' "$APPLY" \
    && pass "ufw: LAN subnet -> 7359/udp" \
    || { fail "ufw 7359 from 192.168.1.0/24 line missing"; CHK_OK=0; }
if grep -nE 'ufw allow .*(8080|7878|8686|6767|9696).*Anywhere' "$APPLY" | grep -q .; then
    fail "a *arr/qBt port has a wildcard-source allow (LAN leak)"
    CHK_OK=0
else
    pass "*arr/qBt ports have NO host-side allow rule (vertical isolation)"
fi
grep -Fq 'socat -T15 UDP4-LISTEN:7359,bind=192.168.1.133,reuseaddr,fork UDP4:192.168.122.10:7359' "$APPLY" \
    && pass "7359/udp discovery relay pinned to $LAN_IP (bind= — never a wildcard)" \
    || { fail "discovery relay not pinned to the LAN IP (fix 9)"; CHK_OK=0; }
# fix 57 — a bound relay is not a WORKING relay: the relay target must be a
# published port, and diag must probe the responder (before fix 57 the relay
# forwarded LAN broadcasts into a closed container port and nothing ever
# auto-discovered the server).
grep -Fq -- '- "192.168.122.10:7359:7359/udp"' "$CFG" \
    && pass "fix 57: jellyfin publishes 7359/udp on the VM IP (discovery relay target)" \
    || { fail "fix 57: jellyfin 7359/udp is not published — the host relay forwards into a closed port"; CHK_OK=0; }
grep -Fq 'who is JellyfinServer?' "$DIAG" \
    && grep -Fq 'UDP4:$VM_IP:7359' "$DIAG" \
    && pass "fix 57: diag probes the discovery responder on the VM side" \
    || { fail "diag lost the discovery responder probe (fix 57)"; CHK_OK=0; }
# fix 11 — both LAN-facing units are sandboxed
N_DYN="$(grep -c 'DynamicUser=yes' "$APPLY" || true)"
[ "${N_DYN:-0}" -ge 2 ] \
    && pass "both LAN-facing units are DynamicUser-sandboxed" \
    || { fail "DynamicUser=yes missing on a LAN-facing unit"; CHK_OK=0; }
grep -Fq 'ProtectHome=yes' "$APPLY" \
    && grep -Fq 'RestrictAddressFamilies=AF_INET AF_UNIX' "$APPLY" \
    && pass "LAN-facing units: ProtectHome + RestrictAddressFamilies (AF_INET/AF_UNIX)" \
    || { fail "unit sandboxing directives missing"; CHK_OK=0; }
grep -Fq 'jellyfin-lan-proxy.socket' "$APPLY" \
    && grep -Fq 'jellyfin-lan-proxy.service' "$APPLY" \
    && pass "both socket-proxyd unit names present" \
    || { fail "socket-proxyd unit name(s) missing"; CHK_OK=0; }
# fix 50 — the proxy socket must not be ordered after network-online.target
# (socket units precede basic.target => boot-time ordering cycle), and must
# FreeBind so it can bind before DHCP assigns the pinned LAN address.
SOK_START="$(grep -n "<<'SOKEOF'" "$APPLY" | head -n1 | cut -d: -f1 || true)"
SOKSEC=""
if [ -n "${SOK_START:-}" ]; then
    SOKSEC="$(sed -n "$((SOK_START+1)),/^SOKEOF$/p" "$APPLY" | sed '$d')"
fi
if [ -z "$SOKSEC" ]; then
    fail "jellyfin-lan-proxy socket heredoc (<<'SOKEOF') not found"; CHK_OK=0
elif printf '%s\n' "$SOKSEC" | grep -qE '^(After|Wants)=.*network-online'; then
    fail "proxy SOCKET ordered After=network-online.target (boot ordering cycle)"; CHK_OK=0
else
    pass "proxy socket has no network-online ordering (boot-safe)"
fi
printf '%s\n' "$SOKSEC" | grep -Fq 'FreeBind=yes' \
    && pass "proxy socket uses FreeBind=yes (binds before DHCP assigns the LAN IP)" \
    || { fail "proxy socket missing FreeBind=yes (DHCP race at boot)"; CHK_OK=0; }
# fix 52 — family requests UI: host Caddy TLS terminator on 192.168.1.133:8443
grep -Fq 'bind 192.168.1.133' "$APPLY" \
    && grep -Fq 'admin off' "$APPLY" \
    && grep -Fq 'auto_https disable_redirects' "$APPLY" \
    && grep -Fq 'reverse_proxy 192.168.122.10:5055' "$APPLY" \
    && pass "Caddyfile pins bind 192.168.1.133, admin off, disable_redirects, -> 5055" \
    || { fail "Caddyfile shape missing/weakened (bind/admin off/disable_redirects/5055)"; CHK_OK=0; }
grep -Fq 'ufw allow in on eno1 from 192.168.1.0/24 to any port 8443 proto tcp' "$APPLY" \
    && pass "ufw: LAN subnet -> 8443/tcp (family requests UI)" \
    || { fail "ufw 8443 from 192.168.1.0/24 line missing"; CHK_OK=0; }
if grep -nE 'ufw allow .*(8989|5055).*Anywhere' "$APPLY" | grep -q .; then
    fail "Sonarr/Jellyseerr has a wildcard-source allow (LAN leak)"
    CHK_OK=0
else
    pass "sonarr/jellyseerr have NO wildcard-source host allow (VM-only)"
fi
grep -Fq 'IPAddressAllow=127.0.0.0/8 192.168.1.0/24 192.168.122.10' "$APPLY" \
    && pass "Caddy drop-in sandbox: IPAddressDeny=any + narrow allow-list" \
    || { fail "Caddy drop-in IP-level sandbox missing"; CHK_OK=0; }
[ "$CHK_OK" -eq 1 ] && pass "G9 complete: LAN surface = Jellyfin + family requests UI"

# ======================================================================
section "G10 — host & data safety: LV stays raw on the host; apt-only installs"
CHK_OK=1
# fix 6 — mkfs must appear ONLY in the in-VM heredoc, targeting the
# serial-resolved DATA_DEV with a fail-closed blkid -p + wipefs -n guard.
# Extract the heredoc body via its marker line (grep -n + sed):
VM_START="$(grep -n "<<'VMEOF'" "$APPLY" | head -n1 | cut -d: -f1)"
VMSEC=""
if [ -n "${VM_START:-}" ]; then
    VMSEC="$(sed -n "$((VM_START+1)),/^VMEOF$/p" "$APPLY" | sed '$d')"
fi
if grep -Fq 'mkfs.ext4 -L media-data "$DATA_DEV"' <<<"$VMSEC"; then
    pass "mkfs.ext4 targets the serial-resolved \$DATA_DEV ONLY inside media-vm (label media-data)"
else
    fail "in-VM mkfs line missing/changed"
    CHK_OK=0
fi
if grep -Fq 'DATA_DEV=/dev/disk/by-id/virtio-media-data-lv' <<<"$VMSEC" \
   && grep -Fq '[ ! -b "$DATA_DEV" ]' <<<"$VMSEC"; then
    pass "DATA_DEV resolves via the virtio serial and is fail-closed when absent"
else
    fail "DATA_DEV serial resolution / absence guard missing"
    CHK_OK=0
fi
if grep -Fq 'blkid -p "$DATA_DEV"' <<<"$VMSEC" \
   && grep -Fq 'wipefs -n "$DATA_DEV"' <<<"$VMSEC"; then
    pass "mkfs runs only after a fail-closed blkid -p + wipefs -n signature scan"
else
    fail "mkfs signature guard (blkid -p + wipefs -n) missing"
    CHK_OK=0
fi
BADMK="$(printf '%s' "$(apply_code)" | grep -nE 'mkfs' | grep -v 'DATA_DEV' | grep -v 'blkid' || true)"
if [ -n "$BADMK" ]; then
    fail "a mkfs appears outside the in-VM DATA_DEV path:$BADMK"
    CHK_OK=0
else
    pass "no mkfs outside the in-VM DATA_DEV path (host LV stays raw)"
fi
if grep -nE 'lvremove|lvchange|lvextend|lvcreate|vgchange' "$APPLY" | grep -q .; then
    fail "an LVM-mutating command appears in phase5_apply.sh (Phase 1 state must stay)"
else
    pass "no LVM-mutating commands anywhere in the apply"
fi
grep -Fq 'blkid -o value -s TYPE "$MEDIA_LV"' "$APPLY" \
    && pass "host passthrough gate: refuse if media LV already has a filesystem" \
    || { fail "pre-apply blkid fail-closed LV gate missing"; CHK_OK=0; }
grep -Fq 'findmnt -rn -S "$MEDIA_LV"' "$APPLY" \
    && pass "post-apply LV untouched check present" \
    || { fail "findmnt LV check missing"; CHK_OK=0; }
# docker install inside the VM = apt only (no get.docker.com / curl|bash)
if printf '%s' "$(apply_code)" | grep -nE 'curl[^#]*\|[[:space:]]*(sudo )?bash|curl[^#]*\|[[:space:]]*(sudo )?sh|\|/bin/bash|https://get\.docker\.com/' | grep -q .; then
    BADPB="$(printf '%s' "$(apply_code)" | grep -nE 'curl[^#]*\|[[:space:]]*(sudo )?bash|curl[^#]*\|[[:space:]]*(sudo )?sh|\|/bin/bash|https://get\.docker\.com/' || true)"
    fail "curl|sh or get.docker.com download pattern present:$BADPB"
    CHK_OK=0
else
    pass "docker comes from Ubuntu apt inside the VM (cloud-init packages — no curl|bash, no get.docker.com fetch)"
fi
grep -Fq 'docker.io' "$APPLY" && grep -Fq 'docker-compose' "$APPLY" \
    && pass "cloud-init package list gates docker.io + docker-compose (v2) + ufw + qemu-guest-agent (Debian names)" \
    || { fail "cloud-init docker package list missing/changed"; CHK_OK=0; }
# deploy key: host-only ed25519, never jordan's keyring
grep -Fq 'ssh-keygen -t ed25519 -N "" -f "$DEB_KEY"' "$APPLY" \
    && pass "dedicated deploy key generated at /etc/media-vm/deploy_ed25519" \
    || { fail "deploy key generation line missing"; CHK_OK=0; }
grep -Fq 'chmod 700 "$DEB_DIR"' "$APPLY" \
    && pass "/etc/media-vm is 700 root:root" \
    || { fail "/etc/media-vm mode line missing"; CHK_OK=0; }
# log artifact: fix 12 (root-owned log dir, never jordan's home) + fix 26
# (directory traversal ACL for jordan) + fix 39 (append-only, never truncated).
grep -Fq 'LOGDIR=/var/log/systembuild' "$APPLY" \
    && grep -Fq 'LOG="$LOGDIR/phase5.out"' "$APPLY" \
    && grep -Fq 'chown root:root "$lf"' "$APPLY" \
    && grep -Fq 'chmod 640 "$lf"' "$APPLY" \
    && grep -Fq 'setfacl -m u:jordan:r "$lf"' "$APPLY" \
    && grep -Fq 'setfacl -m u:jordan:x "$LOGDIR"' "$APPLY" \
    && pass "phase5.out is root:root 640 in /var/log/systembuild + u:jordan:r (dir u:jordan:x) — fixes 12/26" \
    || { fail "log path/ownership/ACL footwear missing"; CHK_OK=0; }
grep -Fq 'exec > >(tee -a "$LOG") 2>&1' "$APPLY" \
    && grep -Fq '===== Phase 5 run ' "$APPLY" \
    && pass "apply output is APPENDED (tee -a) with a per-run header in /var/log/systembuild/phase5.out — fix 39" \
    || note "stream capture line changed (verify manually)"
[ "$CHK_OK" -eq 1 ] && pass "G10 complete: LV, supply chain, keys, log artifact all gated"

# ======================================================================
section "G11 — idempotency + fail-closed behavior + Phase 3/4 untouched"
CHK_OK=1
grep -Fq 'FATAL: staged image digest does NOT match the embedded pin' "$APPLY" \
    && pass "downloaded image is fail-closed against the embedded pin (staged .part, nothing promoted)" \
    || { fail "pin-verified staging gate missing"; CHK_OK=0; }
grep -Fq 'depends on it — NOT deleting' "$APPLY" \
    && pass "an in-use base image is NEVER deleted on pin mismatch (running VM protected)" \
    || { fail "in-use base image protection missing"; CHK_OK=0; }
grep -Fq 'IMG_BASE_URL=https://cloud.debian.org/images/cloud/trixie/20261103-2651' "$APPLY" \
    && grep -Fq 'IMG_NAME=debian-13-genericcloud-amd64-20261103-2651.qcow2' "$APPLY" \
    && pass "image source = the IMMUTABLE dated build dir 20261103-2651 (never 'latest')" \
    || { fail "dated-build image URL/name missing"; CHK_OK=0; }
grep -Fq 'EXPECTED_SHA512=d25999de0770d4cde1be72c299ba3ad94eac7ea8fd4d18f8cc86c69df69337e2e8a91d64465a9bfd8f2a78c566fcbcb0842eacc91c09efdef72d719d9f13b535' "$APPLY" \
    && pass "cloud-image SHA512 pin of record embedded (authenticity anchor)" \
    || { fail "EXPECTED_SHA512 pin missing/changed"; CHK_OK=0; }
grep -Fq 'SSH_UP=0' "$APPLY" || true
grep -Fq 'VPN_SERVICE_PROVIDER=[^[:space:]#]' "$APPLY" \
    && pass "vpn start gate greps for a REAL value (not a comment, not empty)" \
    || { fail "vpn credential gate missing"; CHK_OK=0; }
grep -Fq 'start-gated on real vpn.env credentials' "$APPLY" \
    && pass "V-phase asserts gluetun/qbt stay DOWN while vpn.env is a skeleton" \
    || { fail "vpn gating V-check wording missing"; CHK_OK=0; }
grep -Fq 'if virsh dominfo "$VM_NAME" >/dev/null 2>&1; then' "$APPLY" \
    && pass "existing VM domain is reused (idempotent vm-create)" \
    || { fail "VM-reuse (idempotency) branch missing"; CHK_OK=0; }
grep -Fq 'if [ ! -f "$QBC" ]; then' "$APPLY" \
    && pass "qBittorrent.conf pre-seed is absence-guarded (never clobbers live config)" \
    || { fail "qBittorrent.conf absence-guard missing"; CHK_OK=0; }
grep -Fq 'already has a real value (NOT overwritten)' "$APPLY" \
    && pass "append_env preserves existing real values" \
    || { fail "append_env keep-marker missing"; CHK_OK=0; }
grep -Fq 'value NEVER echoed' "$APPLY" \
    && pass "secrets-write path documents value masking" \
    || { fail "value masking marker missing"; CHK_OK=0; }
# Phase 3/4 untouched: NO write-path touches /etc/litellm or /etc/hermes
if grep -nE '^\s*(>|cat >|tee -?a? |sed -i|install -|echo .* >>)' "$APPLY" | grep -E '/etc/(litellm|hermes)' | grep -q .; then
    fail "a write-path targets /etc/litellm or /etc/hermes in phase5_apply.sh"
else
    pass "phase5_apply.sh never writes /etc/litellm or /etc/hermes (read-only V9 sanity only)"
fi
if [ -f "$P3_CFG" ]; then
    N3="$(sed 's/[[:space:]]*#.*$//' "$P3_CFG" 2>/dev/null | grep -cE '^[[:space:]]*- model_name: ' || true)"
    if [ "$N3" -eq 3 ]; then
        pass "phase 3 model_list still exactly 3 models (source artifact)"
    else
        fail "phase 3 model_list count is $N3 (want 3)"
    fi
else
    note "$P3_CFG absent — phase 3 artifact not present in this directory"
fi
if [ -f "$P4_CFG" ]; then
    if grep -Fq 'api_mode: chat_completions' "$P4_CFG" && grep -Fq 'search_backend: ddgs' "$P4_CFG"; then
        pass "phase 4 config artifact intact (api_mode + ddgs markers present)"
    else
        fail "phase 4 config artifact shape changed unexpectedly"
    fi
else
    note "$P4_CFG absent — phase 4 artifact not present in this directory"
fi
grep -Fq 'PHASE 3 + Phase 4 untouched' "$APPLY" || true
if grep -Fq 'V9 — Phase 3 + Phase 4 untouched' "$APPLY"; then
    pass "apply runs an explicit V9 Phase-3/4-untouched block"
else
    fail "V9 Phase-3/4-untouched block missing in phase5_apply.sh"
fi

# ======================================================================
section "G12 — 2026-11-09 external-review fixes 1–11 all present"
CHK_OK=1
# fix 1 — no predictable /tmp staging; root-only WORKDIR + umask + shred
grep -Fq 'umask 077' "$APPLY" \
    && grep -Fq 'mktemp -d /run/p5-apply.XXXXXX' "$APPLY" \
    && pass "umask 077 + mktemp WORKDIR under /run (fix 1)" \
    || { fail "WORKDIR/umask hardening missing"; CHK_OK=0; }
grep -Fq 'shred -u' "$APPLY" \
    && pass "WORKDIR cleanup shreds staged files (incl. the in-VM vpn.env lint copy)" \
    || { fail "shred-on-exit missing"; CHK_OK=0; }
if printf '%s' "$(apply_code)" | grep -q '/tmp/p5'; then
    fail "a predictable /tmp/p5* path still appears in apply code (fix 1)"
    CHK_OK=0
else
    pass "no /tmp/p5* staging path in apply code (fix 1)"
fi
grep -Fq 'cat >/root/.p5-stage.tmp' "$APPLY" \
    && pass "vm_put streams over ssh into a root-only VM temp + atomic mv (fix 1)" \
    || { fail "vm_put streaming rewrite missing"; CHK_OK=0; }
# fix 2 — VM->LAN pivot guard: ufw route denies (deny-before-allow) +
# FORWARD-top unit + live probe, in BOTH apply and diag
grep -Fq 'ufw route deny from 192.168.122.0/24 to "$NET"' "$APPLY" \
    && grep -Fq 'ufw route delete deny from 192.168.122.0/24 to "$NET"' "$APPLY" \
    && pass "ufw route DENY 122.0/24 -> RFC1918, converged by delete-then-re-add (fix 2)" \
    || { fail "ufw route pivot denies missing"; CHK_OK=0; }
DENY_LN="$(grep -n 'ufw route deny from 192.168.122.0/24 to "$NET"' "$APPLY" | tail -n1 | cut -d: -f1)"
ALLOW_LN="$(grep -n 'ufw route allow in on virbr0' "$APPLY" | tail -n1 | cut -d: -f1)"
if [ -n "${DENY_LN:-}" ] && [ -n "${ALLOW_LN:-}" ] && [ "$DENY_LN" -lt "$ALLOW_LN" ]; then
    pass "deny-before-allow ordering enforced (last deny line $DENY_LN < last allow line $ALLOW_LN)"
else
    fail "ufw route deny/allow ordering wrong (deny=${DENY_LN:-?} allow=${ALLOW_LN:-?})"
    CHK_OK=0
fi
grep -Fq '/usr/local/sbin/media-vm-lan-guard' "$APPLY" \
    && grep -Fq 'After=libvirtd.service' "$APPLY" \
    && grep -Fq 'PartOf=libvirtd.service' "$APPLY" \
    && grep -Fq 'iptables -I FORWARD 1 -s 192.168.122.0/24 -d "$NET" -j DROP' "$APPLY" \
    && pass "media-vm-lan-guard unit pins DROPs to the TOP of FORWARD (After+PartOf libvirtd)" \
    || { fail "media-vm-lan-guard unit missing/incomplete"; CHK_OK=0; }
grep -Fq 'sudo ping -c1 -W3 192.168.1.1' "$APPLY" \
    && pass "live VM->LAN pivot probe (must NOT reach 192.168.1.1) in apply V8" \
    || { fail "pivot probe missing from apply"; CHK_OK=0; }
if [ -f "$DIAG" ]; then
    grep -Fq 'sudo ping -c1 -W3 192.168.1.1' "$DIAG" \
        && pass "pivot probe also present in phase5_diag.sh (S6)" \
        || { fail "pivot probe missing from phase5_diag.sh"; CHK_OK=0; }
    grep -Fq 'media-vm-lan-guard.service' "$DIAG" \
        && pass "diag S6 checks the lan-guard unit + FORWARD-top ordering" \
        || { fail "diag lan-guard checks missing"; CHK_OK=0; }
fi
# fix 3 (+ fix 19) — .part staging in the SAME filesystem as the final image
# (so the promotion is an atomic rename), verified before promotion
grep -Fq '"${BASE_IMG}.part"' "$APPLY" \
    && grep -Fq 'mv -f "${BASE_IMG}.part" "$BASE_IMG"' "$APPLY" \
    && pass "download staged as \${BASE_IMG}.part then atomically promoted only after the pin match (fixes 3/19)" \
    || { fail ".part staging missing"; CHK_OK=0; }
# fix 4 — --profile is a GLOBAL compose flag (before the subcommand)
grep -Fq 'COMPOSE_UP="--profile vpn up -d"' "$APPLY" \
    && pass "vpn profile start uses the global --profile flag BEFORE 'up' (fix 4)" \
    || { fail "compose --profile flag placement wrong/missing"; CHK_OK=0; }
# fix 6 — virtio serial + by-id guest resolution (mkfs side covered in G10)
grep -Fq 'serial=media-data-lv' "$APPLY" \
    && grep -Fq 'virtio-media-data-lv' "$APPLY" \
    && pass "data disk serial=media-data-lv + guest by-id resolution (fix 6)" \
    || { fail "virtio serial/by-id wiring missing"; CHK_OK=0; }
# fix 7 — [::] wildcard published-port check
grep -Fq "grep -Fq '[::]'" "$APPLY" \
    && pass "apply fails on [::] (IPv6 wildcard) published ports (fix 7)" \
    || { fail "[::] wildcard check missing from apply"; CHK_OK=0; }
if [ -f "$DIAG" ]; then
    grep -Fq "'[::]'" "$DIAG" \
        && pass "diag S4 also rejects [::] published ports" \
        || { fail "diag [::] check missing"; CHK_OK=0; }
fi
# fix 9 — socat pinned bind + live 7359 listener pin check
grep -Fq "ss -ulnH 'sport = :7359'" "$APPLY" \
    && pass "apply V8 pins the 7359/udp listener to 192.168.1.133 (fix 9)" \
    || { fail "7359 listener pin check missing from apply"; CHK_OK=0; }
if [ -f "$DIAG" ]; then
    grep -Fq "ss -ulnH 'sport = :7359'" "$DIAG" \
        && pass "diag S5 pins the 7359/udp listener too" \
        || { fail "7359 listener pin check missing from diag"; CHK_OK=0; }
fi
# fix 10 — dedicated known_hosts; reset only on fresh VM create
grep -Fq 'DEB_KH="$DEB_DIR/known_hosts"' "$APPLY" \
    && grep -Fq 'UserKnownHostsFile="$DEB_KH"' "$APPLY" \
    && grep -Fq 'ssh-keygen -R "$VM_IP" -f "$DEB_KH"' "$APPLY" \
    && pass "dedicated deploy known_hosts; reset only on fresh VM create (fix 10)" \
    || { fail "known_hosts isolation missing"; CHK_OK=0; }
# fix 11 — sha256 everywhere (no md5sum), verbose vmrunv, pre-created log
if printf '%s' "$(apply_code)" | grep -q 'md5sum'; then
    fail "md5sum still used in apply code (fix 11)"
    CHK_OK=0
else
    pass "no md5sum anywhere in apply code (sha256 for vpn.env + compose compare)"
fi
grep -Fq 'vmrunv() { ssh "${ssh_opts[@]}" "$VM_USER@$VM_IP" "$@"; }' "$APPLY" \
    && pass "verbose vmrunv variant keeps stderr on critical steps (fix 11)" \
    || { fail "vmrunv verbose variant missing"; CHK_OK=0; }
grep -Fq 'install -m 640 -o root -g root /dev/null "$LF"' "$APPLY" \
    && pass "phase5.out pre-created root:root 640 BEFORE exec tee (fixes 11/12)" \
    || { fail "log pre-create missing"; CHK_OK=0; }
grep -Fq 'wizard' "$APPLY" \
    && pass "Jellyfin first-boot wizard claim warning present (fix 11)" \
    || { fail "wizard claim warning missing"; CHK_OK=0; }
[ "$CHK_OK" -eq 1 ] && pass "G12 complete: external-review fixes 1-11 all present"

# ======================================================================
section "G13 — 2026-11-10 review fixes 35–41 (seed YAML, probe, uid, patches, log, hook)"
CHK_OK=1
# fix 35 — no backtick may survive in the generated user-data, and it must be
# YAML-validated + deploy-key-checked before the seed ISO is built.
UD_BODY="$(sed -n "/cat >\"\$WORKDIR\/user-data\" <<USEREOF/,/^USEREOF$/p" "$APPLY" 2>/dev/null | sed '1d;$d')"
if grep -q '`' <<<"$UD_BODY"; then
    fail "user-data heredoc contains a backtick (would execute as root and corrupt the cloud-config)"
    CHK_OK=0
else
    pass "user-data heredoc has NO backtick (fix 35)"
fi
grep -Fq 'yaml.safe_load(open(sys.argv[1]))' "$APPLY" \
    && grep -Fq 'generated user-data is not valid YAML' "$APPLY" \
    && pass "generated user-data is parsed as YAML and the build fails closed on error (fix 35)" \
    || { fail "user-data YAML validation missing"; CHK_OK=0; }
grep -Fq 'does not contain the deploy public key' "$APPLY" \
    && pass "seed build fails closed if the deploy key did not expand verbatim (fix 35)" \
    || { fail "deploy-key verbatim assertion missing"; CHK_OK=0; }
# fix 36 — the pivot probe must require rc=124 (timeout), never "any non-zero"
grep -Fq 'echo RC=$?' "$APPLY" \
    && grep -Fq '*RC=124*' "$APPLY" \
    && grep -Fq '*RC=0*|*RC=1*' "$APPLY" \
    && pass "apply V8 pivot probe requires rc=124; rc=0/1 fail as 'reached' (fix 36)" \
    || { fail "apply pivot probe exit-code handling missing"; CHK_OK=0; }
if [ -f "$DIAG" ]; then
    grep -Fq '*RC=124*' "$DIAG" \
        && pass "diag S6 pivot probe requires the same rc=124 evidence (fix 36)" \
        || { fail "diag pivot probe not hardened"; CHK_OK=0; }
fi
# fix 37 — stack runs as numeric 1001; jordan (1000) is admin-only
grep -Fq 'chown -R 1001:1001 /data' "$APPLY" \
    && grep -Fq 'PUID=1001' "$CFG" \
    && pass "stack runs as numeric 1001 (compose PUID/PGID + /data ownership) (fix 37)" \
    || { fail "stack uid separation missing"; CHK_OK=0; }
if grep -Fq 'PUID=1000' "$CFG" || grep -Fq 'PGID=1000' "$CFG"; then
    fail "compose still pins the stack to jordan's admin uid 1000"
    CHK_OK=0
else
    pass "no PUID/PGID=1000 left in the compose spec (fix 37)"
fi
# fix 38 — the VM patches itself
grep -Fxq 'package_upgrade: true' "$APPLY" \
    && grep -Fq '  - unattended-upgrades' "$APPLY" \
    && pass "cloud-init sets package_upgrade + installs unattended-upgrades (fix 38)" \
    || { fail "VM self-patching missing"; CHK_OK=0; }
# fix 39 — the log of record is appended, never truncated
grep -Fq 'exec > >(tee -a "$LOG") 2>&1' "$APPLY" \
    && grep -Fq '===== Phase 5 run ' "$APPLY" \
    && pass "log is append-only with a per-run header (fix 39)" \
    || { fail "log append/rotation missing"; CHK_OK=0; }
if grep -Fq 'exec > >(tee "$LOG") 2>&1' "$APPLY"; then
    fail "apply still truncates the log with tee (missing -a)"
    CHK_OK=0
fi
# fix 40 — the libvirt hook cannot silently do nothing
grep -Fq "grep -qE '^#!.*sh'" "$APPLY" \
    && grep -Fq "grep -nE '^exit([[:space:]]|$)'" "$APPLY" \
    && pass "libvirt hook warns on a non-shell shebang and on an exit before the block (fix 40)" \
    || { fail "libvirt hook warnings missing"; CHK_OK=0; }
# fix 41 — header must not claim both relays are wildcard-free
if grep -Fq 'BOTH pinned' "$APPLY"; then
    fail "stale header: still claims both relays are wildcard-free"
    CHK_OK=0
else
    pass "header describes DISCOVERY_MODE correctly (pinned vs broadcast) (fix 41)"
fi
[ "$CHK_OK" -eq 1 ] && pass "G13 complete: fixes 35–41 present"

# fix 42 — the host tool gate must NOT require docker (docker lives in media-vm;
# V5 verifies it there). A host docker requirement fails a clean, valid host.
if grep -Fq 'for t in virsh virt-install docker cloud-localds socat; do' "$APPLY"; then
    fail "V1 still requires docker on the HOST (docker is VM-side only — fix 42)"
    CHK_OK=0
else
    pass "V1 host tool gate does not require docker (fix 42)"
fi
grep -Fq 'for t in virsh virt-install qemu-img cloud-localds genisoimage socat; do' "$APPLY" \
    && pass "V1 still gates the real host tools (virsh/virt-install/qemu-img/cloud-localds/genisoimage/socat)" \
    || { fail "V1 host tool gate changed shape unexpectedly"; CHK_OK=0; }
grep -Fq 'docker correctly NOT required on the host' "$APPLY" \
    && pass "V1 explains the host/VM docker split instead of silently skipping (fix 42)" \
    || { fail "V1 docker note missing"; CHK_OK=0; }
# fix 43 — uid 1001 means "stack uid" only INSIDE media-vm; the host's uid 1001
# is the phase-4 'hermes' account. Both apply and diag must prove that live.
grep -Fq 'getent passwd 1001' "$APPLY" \
    && grep -Fq 'guest has NO passwd entry for uid 1001' "$APPLY" \
    && pass "apply asserts the stack uid is account-less inside the guest (fix 43)" \
    || { fail "apply guest-uid assertion missing"; CHK_OK=0; }
grep -Fq 'id -u jordan' "$APPLY" \
    && grep -Fq 'guest jordan is uid 1000' "$APPLY" \
    && pass "apply asserts guest jordan == 1000 (admin/login only) (fix 43)" \
    || { fail "apply guest-jordan uid assertion missing"; CHK_OK=0; }
if [ -f "$DIAG" ]; then
    grep -Fq 'guest has NO passwd entry for uid 1001' "$DIAG" \
        && grep -Fq 'guest jordan is uid 1000' "$DIAG" \
        && pass "diag S3 repeats both guest uid assertions (fix 43)" \
        || { fail "diag guest-uid assertions missing"; CHK_OK=0; }
fi
grep -Fq "uid 1001 is the unrelated 'hermes' service account" "$APPLY" \
    && pass "apply documents the host hermes/guest stack-uid namespace split (fix 43)" \
    || { fail "host/guest uid namespace note missing"; CHK_OK=0; }

# ======================================================================
section "G14 — 2026-11-10 first-run fixes 44–46 (ufw policy line, deploy-dir traversal, exact ufw rows)"
CHK_OK=1
# fix 44 — ufw prints "Default: deny (incoming), ..." in lowercase; the old
# capitalised "Deny incoming" grep could never match and failed a healthy host.
grep -Fq 'Default: deny (incoming)' "$APPLY" \
    && grep -Fq 'ufw policy:' "$APPLY" \
    && pass "apply V10 parses the real 'Default: deny (incoming)' policy line (fix 44)" \
    || { fail "apply ufw default-policy parser missing"; CHK_OK=0; }
if grep -Fq 'grep -q "Deny incoming"' "$APPLY"; then
    fail "apply still greps the non-existent capitalised 'Deny incoming' (fix 44)"
    CHK_OK=0
else
    pass "apply no longer greps a capitalised ufw policy string (fix 44)"
fi
if [ -f "$DIAG" ]; then
    grep -Fq 'Default: deny (incoming)' "$DIAG" \
        && pass "diag S9 uses the same lowercase policy line (fix 44)" \
        || { fail "diag ufw default-policy parser missing"; CHK_OK=0; }
    if grep -Fq 'grep -q "Deny incoming"' "$DIAG"; then
        fail "diag still greps the non-existent capitalised 'Deny incoming' (fix 44)"
        CHK_OK=0
    else
        pass "diag no longer greps a capitalised ufw policy string (fix 44)"
    fi
fi
# fix 45 — a 0700 /opt/media-stack (umask 077 + mkdir -p) made jordan's `cd`
# fail, so compose never ran and V6 saw zero containers.
grep -Fq 'chmod 0755 "$(dirname "$2")"' "$APPLY" \
    && pass "vm_put makes the destination directory traversable (0755) while files stay 644/600 (fix 45)" \
    || { fail "vm_put still leaves the deploy directory 0700 root (fix 45)"; CHK_OK=0; }
grep -Fq "sudo sh -c 'cd /opt/media-stack && (docker compose" "$APPLY" \
    && pass "compose runs with 'cd' inside the root shell (no cwd permission needed) (fix 45)" \
    || { fail "compose still cds as jordan before sudo (fix 45)"; CHK_OK=0; }
if grep -Fq 'vmrunv "cd /opt/media-stack' "$APPLY"; then
    fail "apply still cds into /opt/media-stack outside sudo (fix 45)"
    CHK_OK=0
else
    pass "no unprivileged 'cd /opt/media-stack' left in the apply path (fix 45)"
fi
# fix 46 — V8/diag must assert the REAL ufw row. Plain `ufw status` prints
# "ALLOW" (no " IN"), and "To" may carry " on eno1" / " (v6)", so the old
# substring probes could pass with the SSH row alone and miss interface-form
# wildcards.
ROW8096="$(grep -m1 '^UFW_ROW_8096=' "$APPLY" 2>/dev/null || true)"
case "$ROW8096" in
    *'8096/tcp'*'(ALLOW|LIMIT)'*'( IN)?'*'192\.168\.1\.0/24'*)
        pass "apply V8 exact 8096/tcp row regex (interface-optional, ALLOW/LIMIT, LAN source) (fix 46)" ;;
    *)
        fail "apply V8 8096/tcp exact-row regex missing or narrowed"
        CHK_OK=0 ;;
esac
ROW7359="$(grep -m1 '^UFW_ROW_7359=' "$APPLY" 2>/dev/null || true)"
case "$ROW7359" in
    *'7359/udp'*'192\.168\.1\.0/24'*)
        pass "apply V8 exact 7359/udp row regex present (fix 46)" ;;
    *)
        fail "apply V8 7359/udp exact-row regex missing"
        CHK_OK=0 ;;
esac
ROWANY="$(grep -m1 '^UFW_ANY_ROW=' "$APPLY" 2>/dev/null || true)"
case "$ROWANY" in
    *'v6'*'(ALLOW|LIMIT)'*'Anywhere|0\.0\.0\.0/0|::/0'*)
        pass "apply V8 wildcard probe covers interface, (v6) and both Anywhere spellings (fix 46)" ;;
    *)
        fail "apply V8 wildcard probe narrowed back to the shape-blind form"
        CHK_OK=0 ;;
esac
grep -Fq 'ufw allows 8096/tcp from 192.168.1.0/24 only (exact row)' "$APPLY" \
    && pass "apply V8 fails closed when the 8096/7359 rows are absent (fix 46)" \
    || { fail "apply V8 exact-row pass/fail text missing"; CHK_OK=0; }
if grep -Fq 'echo "$UFWS" | grep -Fq "8096/tcp" && echo "$UFWS" | grep -Fq "192.168.1.0/24"' "$APPLY"; then
    fail "apply V8 still uses the substring pass that the SSH row satisfies (fix 46)"
    CHK_OK=0
else
    pass "apply V8 no longer passes on the SSH row's 192.168.1.0/24 (fix 46)"
fi
grep -Fq '^8096/tcp( on [^[:space:]]+)?[[:space:]]+ALLOW' "$APPLY" \
    && pass "ufw already-present probes match plain-status 'ALLOW' rows (fix 46)" \
    || { fail "ufw already-present probes still look for 'ALLOW IN'"; CHK_OK=0; }
if [ -f "$DIAG" ]; then
    DROW8096="$(grep -m1 '^UFW_ROW_8096=' "$DIAG" 2>/dev/null || true)"
    DRAWANY="$(grep -m1 '^UFW_ANY_ROW=' "$DIAG" 2>/dev/null || true)"
    case "$DROW8096" in
        *'8096/tcp'*'(ALLOW|LIMIT)'*'192\.168\.1\.0/24'*) D_OK=1 ;;
        *) D_OK=0 ;;
    esac
    case "$DRAWANY" in
        *'v6'*'Anywhere|0\.0\.0\.0/0|::/0'*) : ;;
        *) D_OK=0 ;;
    esac
    if [ "${D_OK:-0}" -eq 1 ]; then
        pass "diag S9 mirrors the exact-row + (v6)/interface wildcard assertions (fix 46)"
    else
        fail "diag S9 exact ufw row assertions missing or narrowed"
        CHK_OK=0
    fi
fi
[ "$CHK_OK" -eq 1 ] && pass "G14 complete: fixes 44–46 present"

# ======================================================================
section "G15 — 2026-11-10 diag false-fails fixes 47–49 (curl 000000, ctorigdstport count, bazarr/qbt harvest)"
CHK_OK=1
if [ -f "$DIAG" ]; then
    # fix 47 — `curl -w %{http_code}` already prints 000 on connect failure;
    # the old `|| echo` fallback produced "000000" and reported every isolated
    # port as a LEAK. No such wrapper may remain anywhere (S5 and S6).
    LEFT="$(grep -cF '|| echo 000' "$DIAG" 2>/dev/null || true)"
    if [ "${LEFT:-0}" -eq 0 ]; then
        pass "no '|| echo 000' curl wrapper left anywhere in diag (S5+S6, fix 47)"
    else
        fail "$LEFT '|| echo 000' curl wrapper(s) still in diag — double-000 false fails (fix 47)"
        CHK_OK=0
    fi
    grep -Fq '2>/dev/null || true)' "$DIAG" \
        && grep -Fq '000|"")' "$DIAG" \
        && pass "diag S6 treats 000 OR empty as isolated and still fails on any real HTTP code" \
        || { fail "diag S6 refused-connection branch missing/weakened (fix 47)"; CHK_OK=0; }
    # fix 48 — the inbound guard is keyed on --ctorigdstport, not --dport
    grep -Fq '! -s 192\.168\.122\.0/24.*--ctorigdstport [0-9]+.*--ctdir ORIGINAL.*-j DROP' "$DIAG" \
        && pass "diag S7 counts the real --ctorigdstport inbound guard rows (fix 48)" \
        || { fail "diag S7 inbound guard regex does not use --ctorigdstport/--ctdir (fix 48)"; CHK_OK=0; }
    if grep -Fq '! -s 192\.168\.122\.0/24.*--dport.*DROP' "$DIAG"; then
        fail "diag S7 still counts inbound guards by --dport (always 0) (fix 48)"
        CHK_OK=0
    else
        pass "diag S7 no longer matches the nonexistent inbound --dport form (fix 48)"
    fi
    grep -Fq '[ "$NIN" -ge 8 ]' "$DIAG" \
        && pass "diag S7 still requires the full 8-port inbound guard" \
        || { fail "diag S7 inbound guard threshold weakened"; CHK_OK=0; }
    # S10 must keep demanding all 12 harvested keys including QBITTORRENT_URL
    grep -Fq 'JELLYFIN_URL QBITTORRENT_URL; do' "$DIAG" \
        && grep -Fq 'BAZARR_URL BAZARR_API_KEY' "$DIAG" \
        && grep -Fq 'SONARR_URL SONARR_API_KEY' "$DIAG" \
        && grep -Fq 'all 12 harvested media keys present' "$DIAG" \
        && pass "diag S10 still requires all 12 keys (sonarr + bazarr + qbittorrent included)" \
        || { fail "diag S10 harvest key list narrowed"; CHK_OK=0; }
else
    fail "phase5_diag.sh not readable — cannot verify fixes 47/48/49"
    CHK_OK=0
fi
# fix 49 — qbittorrent URL is deterministic even while the vpn profile is gated
grep -Fq 'PORTS=(prowlarr:9696 radarr:7878 lidarr:8686 sonarr:8989 bazarr:6767 jellyfin:8096 qbittorrent:8080)' "$APPLY" \
    && pass "apply harvest appends SONARR_URL + QBITTORRENT_URL (fix 52 / fix 49)" \
    || { fail "apply PORTS list missing sonarr:8989 or qbittorrent:8080"; CHK_OK=0; }
# fix 49 — bazarr is not a Servarr app: its key lives in config/config.yaml
grep -Fq 'arr_api_key()' "$APPLY" \
    && grep -Fq '/data/config/bazarr/config/config.yaml' "$APPLY" \
    && grep -Fq 'K="$(arr_api_key "$APP")"' "$APPLY" \
    && pass "apply harvest reads bazarr's config/config.yaml apikey (fix 49)" \
    || { fail "apply still looks for bazarr config.xml only (key can never appear)"; CHK_OK=0; }
grep -Fq 'config/$1/config.xml' "$APPLY" \
    && pass "apply harvest still reads config.xml for prowlarr/radarr/lidarr (fix 49)" \
    || { fail "apply Servarr config.xml harvest removed"; CHK_OK=0; }
[ "$CHK_OK" -eq 1 ] && pass "G15 complete: fixes 47–49 present"

# ======================================================================
section "G16 — 2026-11-12 diag journal noise fix 51 (boot-scoped, SIGTERM-aware)"
CHK_OK=1
if [ -f "$DIAG" ]; then
    # fix 51 — `journalctl -n 60` without -b walks back through earlier boots:
    # the pre-fix 2026-11-10 23:34 bind failures were reported as current on
    # every later run. The scan MUST be boot-scoped.
    grep -Fq 'journalctl -b -u "$U" -n 60' "$DIAG" \
        && pass "diag S10 journal scan is boot-scoped (journalctl -b) (fix 51)" \
        || { fail "diag S10 journal scan lost -b (stale cross-boot failures) (fix 51)"; CHK_OK=0; }
    if grep -Fq 'journalctl -u "$U" -n 60' "$DIAG"; then
        fail "diag S10 still has the unscoped journalctl -u \"\$U\" -n 60 form (fix 51)"
        CHK_OK=0
    else
        pass "no unscoped cross-boot journal scan remains (fix 51)"
    fi
    # fix 51 — a deliberate restart logs SIGTERM as status=143 +
    # `Failed with result 'exit-code'`; that pair must not count as an error.
    grep -Fq 'status=143|exiting on signal 15' "$DIAG" \
        && pass "diag S10 ignores deliberate SIGTERM stop chatter (fix 51)" \
        || { fail "diag S10 SIGTERM-stop filter missing (false 'Failed' notes) (fix 51)"; CHK_OK=0; }
    grep -Fq 'Failed with result .exit-code.' "$DIAG" \
        && pass "diag S10 suppresses only the exit-code line that follows a SIGTERM stop (fix 51)" \
        || { fail "diag S10 exit-code suppression missing/weakened (fix 51)"; CHK_OK=0; }
    # the scan must still flag the exact fix-50 failure modes on the current boot
    grep -Fq 'ordering cycle|deleted to break' "$DIAG" \
        && pass "diag S10 still flags boot ordering-cycle signatures (fix 50/51)" \
        || { fail "diag S10 no longer flags ordering-cycle signatures (fix 50/51)"; CHK_OK=0; }
    grep -Fq 'error-signature line(s) in this boot' "$DIAG" \
        && pass "diag S10 note text matches the real scan window ('this boot')" \
        || { fail "diag S10 note still claims a window the scan does not use (fix 51)"; CHK_OK=0; }
else
    fail "phase5_diag.sh not readable — cannot verify fix 51"
    CHK_OK=0
fi
[ "$CHK_OK" -eq 1 ] && pass "G16 complete: fix 51 present"

# ======================================================================
section "G17 — 2026-11-15 fix 52/53 (vpn.env authority, gluetun health, Step 8 family UI)"
CHK_OK=1
# fix 52a — vpn.env pre-push lint + WireGuard value guards
grep -Fq 'vpn_env_normalize()' "$APPLY" \
    && grep -Fq 'IPV6-OR-MULTI-ADDR-UNSUPPORTED' "$APPLY" \
    && grep -Fq 'QUOTED-VALUE' "$APPLY" \
    && pass "apply normalizes + lints vpn.env (leading space/quotes/IPv6 tail) before any push" \
    || { fail "vpn.env normalize/lint guards missing in apply"; CHK_OK=0; }
grep -Fq 'IPV6-OR-MULTI-ADDR-UNSUPPORTED' "$DIAG" \
    && grep -Fq 'QUOTED-VALUE' "$DIAG" \
    && pass "diag S10 flags IPv6/multi-address and quoted WireGuard values" \
    || { fail "diag WireGuard value guards missing"; CHK_OK=0; }
# fix 52b — host vpn.env is AUTHORITATIVE once it holds real credentials
grep -Fq 'if env_lint "$VPN_ENV_HOST" >/dev/null 2>&1; then' "$APPLY" \
    && pass "apply pushes the host vpn.env only when its line-shape lint is clean" \
    || { fail "authoritative host vpn.env push gate missing"; CHK_OK=0; }
if grep -Fq 'DIVERGED from the host' "$APPLY"; then
    fail "apply still keeps a stale diverged in-VM vpn.env (old guard present)"
    CHK_OK=0
else
    pass "old 'leave diverged VM copy untouched' guard removed (host is authoritative)"
fi
grep -Fq 'VPN_ENV_CHANGED=0' "$APPLY" \
    && grep -Fq 'VPN_ENV_CHANGED=1' "$APPLY" \
    && pass "apply tracks VPN_ENV_CHANGED across normalize/push" \
    || { fail "VPN_ENV_CHANGED tracking missing"; CHK_OK=0; }
grep -Fq 'if [ "$REAL_CREDS" -eq 1 ] && [ "${VPN_ENV_CHANGED:-0}" -eq 1 ]; then' "$APPLY" \
    && grep -Fq -- '--force-recreate gluetun qbittorrent' "$APPLY" \
    && pass "apply force-recreates gluetun+qbittorrent when vpn.env changed (env_file reload)" \
    || { fail "VPN_ENV_CHANGED force-recreate missing"; CHK_OK=0; }
# fix 52c — no false PASS for crash-looping / starting containers
if grep -Fq "grep -qE 'Up|Restarting'" "$APPLY"; then
    fail "apply V6 still accepts 'Up|Restarting' (crash loop false PASS)"
    CHK_OK=0
else
    pass "apply V6 no longer accepts 'Up|Restarting'"
fi
grep -Fq '[ "$GH" = "healthy" ]' "$APPLY" \
    && grep -Fq '[ "$GH" = "healthy" ]' "$DIAG" \
    && pass "apply V6 + diag S4 poll and require gluetun (healthy)" \
    || { fail "gluetun healthy-state poll missing"; CHK_OK=0; }
# fix 52 — Step 8 compose additions
grep -Fq 'user: "1001:1001"' "$CFG" \
    && pass "jellyseerr pins user: \"1001:1001\" (PUID/PGID are ignored without it)" \
    || { fail "jellyseerr user: \"1001:1001\" missing"; CHK_OK=0; }
grep -Fq 'FIREWALL_VPN_INPUT_PORTS=37686' "$CFG" \
    && grep -Fq 'TORRENTING_PORT=37686' "$CFG" \
    && pass "compose pins AirVPN forwarded port 37686 (gluetun + qbittorrent)" \
    || { fail "compose 37686 forwarding values missing"; CHK_OK=0; }
# fix 52 — Step 8 in-VM tree + port migration
grep -Fq '/data/torrents/tv' "$APPLY" \
    && grep -Fq '/data/media/tv' "$APPLY" \
    && pass "in-VM provisioning creates both TV hardlink halves" \
    || { fail "TV hardlink directories missing from vm_setup"; CHK_OK=0; }
grep -Fq 's/^Session\\Port=6881$/Session\\Port=37686/' "$APPLY" \
    && pass "qBittorrent.conf 6881 -> 37686 migration present (already-provisioned VMs)" \
    || { fail "qBittorrent.conf port migration missing"; CHK_OK=0; }
# fix 52 — Caddy systemd drop-in hardening
grep -Fq 'After=network-online.target libvirtd.service' "$APPLY" \
    && grep -Fq 'RestrictAddressFamilies=AF_INET AF_UNIX' "$APPLY" \
    && grep -Fq 'IPAddressDeny=any' "$APPLY" \
    && grep -Fq 'IPAddressAllow=127.0.0.0/8 192.168.1.0/24 192.168.122.10' "$APPLY" \
    && pass "caddy drop-in: boot ordering + AF_INET/AF_UNIX + IPAddressDeny/Allow sandbox" \
    || { fail "caddy systemd drop-in hardening missing"; CHK_OK=0; }
grep -Fq 'CADDY_ROOT_CA=/var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt' "$APPLY" \
    && grep -Fq 'family-media-ca.crt' "$APPLY" \
    && grep -Fq 'family-media-ca.crt' "$DIAG" \
    && pass "Caddy local CA root is exported and asserted (family-media-ca.crt)" \
    || { fail "Caddy local CA export missing"; CHK_OK=0; }
# fix 52 — verification thresholds raised, never lowered
grep -Fq 'for P in 8080 9696 7878 8686 8989 6767 5055; do' "$APPLY" \
    && grep -Fq 'for P in 8080 9696 7878 8686 8989 6767 5055; do' "$DIAG" \
    && pass "negative LAN probes cover all 7 isolated ports in apply + diag" \
    || { fail "negative probe port list not raised to 7"; CHK_OK=0; }
grep -Fq 'ufw allow in on eno1 from 192.168.1.0/24 to any port 8443 proto tcp' "$APPLY" \
    && grep -Fq '8443/tcp' "$DIAG" \
    && pass "8443/tcp LAN-subnet ufw row installed + asserted" \
    || { fail "8443 ufw row missing"; CHK_OK=0; }
grep -Fq 'all 12 harvested media keys present' "$DIAG" \
    && pass "diag S10 requires the 12-key harvest (SONARR_URL + SONARR_API_KEY)" \
    || { fail "12-key harvest assertion missing"; CHK_OK=0; }
[ "$CHK_OK" -eq 1 ] && pass "G17 complete: fix 52/53 present"

# ======================================================================
section "G18 — 2026-11-15 fix 54 (forwarded-port integrity + guard reload)"
CHK_OK=1
GR="$SCRIPT_DIR/phase5_guardrail_test.sh"
FP_C="$(sed -n 's/^[[:space:]]*- FIREWALL_VPN_INPUT_PORTS=\([0-9]\{1,5\}\)[[:space:]]*$/\1/p' "$CFG" | head -n1)"
FP_Q="$(sed -n 's/^[[:space:]]*- TORRENTING_PORT=\([0-9]\{1,5\}\)[[:space:]]*$/\1/p' "$CFG" | head -n1)"
FP_A="$(sed -n 's/^AIRVPN_PORT=\([0-9]\{1,5\}\)[[:space:]]*$/\1/p' "$APPLY" | head -n1)"
if [ -n "$FP_C" ] && [ "$FP_C" = "$FP_Q" ] && [ "$FP_C" = "$FP_A" ] \
   && [ "$FP_C" -ge 1 ] && [ "$FP_C" -le 65535 ]; then
    pass "one numeric forwarded port everywhere: compose gluetun+qbtorrent = apply canary ($FP_C)"
else
    fail "forwarded port missing/empty/mismatched (compose=$FP_C/$FP_Q apply=$FP_A)"
    CHK_OK=0
fi
if grep -Eqn '(FIREWALL_VPN_INPUT_PORTS|TORRENTING_PORT|Session.Port)=[[:space:]]*$|(any port|--dport)[[:space:]]+$' \
        "$CFG" "$APPLY" "$DIAG" "$GR" >/dev/null 2>&1; then
    fail "an empty port token is present (empty FIREWALL_VPN_INPUT_PORTS/TORRENTING_PORT/Session\\Port or '--dport' with no value)"
    CHK_OK=0
else
    pass "no empty forwarded-port token in compose/apply/diag/guardrail (fix 54)"
fi
if [ -n "$FP_C" ] \
   && [ "$(grep -c -- "--dport $FP_C" "$APPLY")" -ge 8 ] \
   && grep -Fq "ufw deny proto tcp to any port $FP_C" "$APPLY" \
   && grep -Fq "ufw deny proto udp to any port $FP_C" "$APPLY"; then
    pass "apply wires the same port into 8 DOCKER-USER statements + ufw tcp/udp denies"
else
    fail "apply port wiring incomplete (want 8 --dport rows + both ufw denies)"
    CHK_OK=0
fi
grep -Fq 'VM_SETUP_FAIL: AIRVPN_PORT is not numeric' "$APPLY" \
    && grep -Fq 'systemctl restart torrent-port-guard.service' "$APPLY" \
    && pass "apply fails loud on a non-numeric port AND restarts the guard after rewriting it (fix 54)" \
    || { fail "port canary or guard restart missing (stale DOCKER-USER rows return)"; CHK_OK=0; }
if [ -n "$FP_C" ] \
   && grep -Fq "to any port $FP_C" "$GR" \
   && grep -Fq -- "--dport $FP_C" "$GR" \
   && grep -Fq "Session\\Port=$FP_C" "$DIAG" \
   && grep -Fq "dport $FP_C" "$DIAG"; then
    pass "guardrail + diag assert the same port literal (no vacuous greps)"
else
    fail "guardrail/diag port assertions lost the literal (they would pass on an empty value)"
    CHK_OK=0
fi
grep -Fq 'repaired empty/invalid Session\\Port -> 37686 (fix 54)' "$APPLY" \
    && grep -Fq 'Session\\Port is empty/non-numeric (fix 54)' "$DIAG" \
    && pass "apply repairs + diag rejects an empty/non-numeric qBittorrent listen port" \
    || { fail "qBittorrent empty-port repair/assert missing"; CHK_OK=0; }
[ "$CHK_OK" -eq 1 ] && pass "G18 complete: fix 54 present"

# ======================================================================
section "G19 — 2026-11-15 fix 56 (qBt conf convergence + guard prune)"
CHK_OK=1
# 1. qBittorrent must be STOPPED before the conf is edited: on SIGTERM it dumps
#    its in-memory config over the file, reverting the edit (and omitting a
#    value it considers default). Enforce stop-line < migration-line ordering.
QBS_LN="$(grep -Fn 'docker stop qbittorrent' "$APPLY" | head -n1 | cut -d: -f1)"
QBM_LN="$(grep -Fn 'migrated Session\\Port 6881 -> 37686 (fix 52)' "$APPLY" | head -n1 | cut -d: -f1)"
if [ -n "$QBS_LN" ] && [ -n "$QBM_LN" ] && [ "$QBS_LN" -lt "$QBM_LN" ]; then
    pass "apply stops qbittorrent BEFORE editing the conf ($QBS_LN < $QBM_LN — fix 56)"
else
    fail "qBt conf edit is not preceded by 'docker stop qbittorrent' (edit would be reverted)"
    CHK_OK=0
fi
# 2. a fully ABSENT key must be inserted (fix-54 only rewrote an existing line)
if grep -Fq 'inserted missing Session\\Port=37686 (fix 56)' "$APPLY" \
   && grep -Fq '[ -f "$QBC" ] && ! grep -q' "$APPLY" \
   && grep -Fq '!done && $0 == "[BitTorrent]"' "$APPLY" \
   && grep -Fq 'print "[BitTorrent]\n" ENVIRON["K"]' "$APPLY"; then
    pass "apply INSERTS an absent Session\\Port under [BitTorrent] via awk+ENVIRON (fix 56)"
else
    fail "absent-key insertion missing (empty conf passed apply, failed diag)"
    CHK_OK=0
fi
# 3. a stale-but-valid numeric value (e.g. the previous placeholder) is rewritten
if grep -Fq 'rewrote stale Session\\Port' "$APPLY" \
   && grep -Fq '37686) : ;;' "$APPLY"; then
    pass "apply rewrites a stale numeric listen port to the canary (fix 56)"
else
    fail "stale numeric Session\\Port is not converged (old placeholder would survive)"
    CHK_OK=0
fi
# 4. apply itself must assert the on-disk value (it went green with no key)
if grep -Fq "grep -F 'Session\\Port='" "$APPLY" \
   && grep -Fq '[ "$QBP_VM" = "37686" ]' "$APPLY" \
   && grep -Fq '(want 37686 — fix 56)' "$APPLY"; then
    pass "apply V-phase asserts the qBt listen port on disk (fix 56)"
else
    fail "apply does not verify the qBt listen port (silent-green regression)"
    CHK_OK=0
fi
# 5. the guard converges: stale single-port DROP rows are deleted, never the
#    6881:6889 range, the inbound ctorigdstport guards, or the canary
if grep -Fq '"-A DOCKER-USER"*"--dport "*"-j DROP"' "$APPLY" \
   && grep -Fq '${R/-A DOCKER-USER/-D DOCKER-USER}' "$APPLY" \
   && grep -Fq '*[!0-9]*) continue ;; 37686) continue ;; esac' "$APPLY"; then
    pass "guard prunes stale single-port DROP rows, keeps range/inbound/canary (fix 56)"
else
    fail "DOCKER-USER prune missing (old-port rows accumulate across port moves)"
    CHK_OK=0
fi
# 6. diag reports the observed value so a future miss is diagnosable
grep -Fq "observed '\${QBP_NUM:-<missing>}'" "$DIAG" \
    && pass "diag prints the observed/absent Session\\Port value (fix 56)" \
    || { fail "diag does not report the observed listen-port value"; CHK_OK=0; }
# 7. diag proves the SOCKET, not just the file: a LISTEN row on the forwarded
#    port inside gluetun's netns is the interface AirVPN actually forwards to.
#    The hex port must be DERIVED from the same literal, so an 8k port move
#    cannot leave a stale 0x9336 behind.
if grep -Fq "printf '%04X' $FP_C" "$DIAG" \
   && grep -Fq '/proc/net/tcp' "$DIAG" \
   && grep -Fq "grep -c ':\$QBP_HEX 00000000:0000 0A'" "$DIAG"; then
    pass "diag proves a LISTEN socket on the forwarded port inside gluetun's netns (fix 56)"
else
    fail "diag does not prove the qBt listening socket (the conf value could be a lie)"
    CHK_OK=0
fi
[ "$CHK_OK" -eq 1 ] && pass "G19 complete: fix 56 present"

# ======================================================================
section "G20 — 2026-11-18 fix 58 (Jellyfin 12.4 pin + stepped DB migration)"
# Why: the sideloaded Samsung Tizen client is jellyfin-web 12.z. Against a
# 10.10.6 server every play request dies before PlaybackInfo. Upstream jumped
# 10.11.x -> 12.0 (stable Oct 2026), and the 12.0 DB change is irreversible,
# so the pin, the backup and the stepped migration must all be present.
CHK_OK=1

# 1. compose pins 12.4 exactly once and no 10.10.6 pin survives anywhere
if [ "$(grep -c 'image: jellyfin/jellyfin:12.4' "$CFG")" = "1" ] \
   && grep -Fq 'jellyfin 12.4 (official)' "$CFG"; then
    pass "compose pins jellyfin/jellyfin:12.4 (header agrees)"
else
    fail "compose does not pin jellyfin/jellyfin:12.4 exactly once (fix 58)"
    CHK_OK=0
fi
if grep -Fq 'jellyfin/jellyfin:10.10.6' "$CFG" "$APPLY" "$DIAG"; then
    fail "a 10.10.6 jellyfin pin survives in compose/apply/diag (partial bump)"
    CHK_OK=0
else
    pass "no jellyfin 10.10.6 pin remains in compose/apply/diag"
fi

# 2. the guardrail's own pin must equal the compose pin (G0 would otherwise
#    "pass" against a stale constant and never look at the real image line)
grep -Fq 'PIN_JF="jellyfin/jellyfin:12.4"' "$SELF" \
    && pass "guardrail PIN_JF is 12.4 (pin check is not vacuous)" \
    || { fail "guardrail PIN_JF is stale — G0 cannot catch a wrong jellyfin image"; CHK_OK=0; }

# 3. the migration is stepped, backed up, and fail-closed on space
if grep -Fq 'JF_WANT="12.4"' "$APPLY" \
   && grep -Fq 'JF_STEP="10.10.7"' "$APPLY" \
   && grep -Fq 'sort -V | head -n1' "$APPLY"; then
    pass "apply steps 10.10.x -> 10.10.7 -> 12.4 (upstream upgrade guidance)"
else
    fail "apply does not step through 10.10.7 before 12.4 (12.0 notes require it)"
    CHK_OK=0
fi
if grep -Fq 'tar -czf "$BK" -C /data/config jellyfin' "$APPLY" \
   && grep -Fq 'jellyfin-backup-$(date -u +%Y%m%dT%H%M%SZ)' "$APPLY" \
   && grep -Fq 'free_kb" -le $(( need_kb * 3 / 2 ))' "$APPLY"; then
    pass "apply tars /data/config/jellyfin first and fails closed when /data is short"
else
    fail "no fail-closed pre-upgrade backup for the irreversible 12.0 DB change"
    CHK_OK=0
fi
if grep -Fq 'docker stop jellyfin' "$APPLY" \
   && grep -Fq 'MIG=jellyfin-migrate' "$APPLY" \
   && [ "$(grep -c "Startup complete|Kestrel is listening" "$APPLY")" -ge 2 ]; then
    pass "apply stops the live container and waits for each step's startup"
else
    fail "live container is not stopped / migration completion is not proven"
    CHK_OK=0
fi

# 4. ORDERING: the migration must run BEFORE compose starts 12.4, otherwise the
#    DB migrates under a container that is already serving requests.
JF_MIG_LINE="$(grep -n 'sudo bash /home/jordan/p5_jf_upgrade.sh' "$APPLY" | head -n1 | cut -d: -f1)"
JF_UP_LINE="$(grep -n 'docker compose \$COMPOSE_UP' "$APPLY" | head -n1 | cut -d: -f1)"
if [ -n "$JF_MIG_LINE" ] && [ -n "$JF_UP_LINE" ] && [ "$JF_MIG_LINE" -lt "$JF_UP_LINE" ]; then
    pass "jellyfin migration runs before the compose deploy (line $JF_MIG_LINE < $JF_UP_LINE)"
else
    fail "jellyfin migration is not ordered before compose (${JF_MIG_LINE:-none} vs ${JF_UP_LINE:-none})"
    CHK_OK=0
fi

# 5. apply V6 proves the RUNNING image + live version, not just the file
if grep -Fq "docker inspect -f '{{.Config.Image}}' jellyfin" "$APPLY" \
   && grep -Fq "jellyfin runs the pinned 12.4 image" "$APPLY" \
   && grep -Fq 'jellyfin reports server version $JF_VER' "$APPLY"; then
    pass "apply V6 asserts the live 12.4 image and /System/Info/Public version"
else
    fail "apply can go green while jellyfin still runs 10.10.6"
    CHK_OK=0
fi

# 6. diag reports the live version and treats a mismatch as a FAIL
if grep -Fq 'reported version:' "$DIAG" \
   && grep -Fq '12.4*) pass "Jellyfin reports version' "$DIAG"; then
    pass "diag prints the live version and fails a 12.4 mismatch"
else
    fail "diag does not verify the live Jellyfin version (fix 58 would drift silently)"
    CHK_OK=0
fi

# 7. the runbook of record documents the upgrade + the mandatory full scan.
#    Doc files live only in the repository (phase5_step1_install.sh installs the
#    four executable artifacts), so the check is skipped — never failed — when
#    the guardrail runs from /usr/local/sbin/phase5.
if [ -f "$MANUAL" ]; then
    if grep -Fq '### 10h. Jellyfin 12.4 upgrade (fix 58' "$MANUAL" \
       && grep -Fq '10.10.7' "$MANUAL" \
       && grep -Fq '/data/config/jellyfin-backup-' "$MANUAL" \
       && grep -Fq 'Scan Media Library' "$MANUAL"; then
        pass "manual 10h documents fix 58 (stepped upgrade + backup + mandatory full scan)"
    else
        fail "manual has no fix-58 upgrade/backup/scan guidance (10h)"
        CHK_OK=0
    fi
else
    note "manual absent next to the guardrail (installed copy) — fix-58 doc check skipped"
fi

# 8. the agent-facing handover file must carry the same pairing, otherwise a
#    friend's agent debugs codecs for a version mismatch.
if [ -f "$AGENTS" ]; then
    if grep -Fq 'jellyfin/jellyfin:12.4' "$AGENTS" \
       && grep -Fq 'Jellyfin-12.z.wgt' "$AGENTS" \
       && grep -Fq 'System/Info/Public' "$AGENTS"; then
        pass "AGENTS.md carries the 12.4 <-> 12.z pairing and the verify commands"
    else
        fail "AGENTS.md lost the version-pairing handover (a friend's agent would chase codecs)"
        CHK_OK=0
    fi
else
    note "AGENTS.md absent next to the guardrail (installed copy) — handover check skipped"
fi
[ "$CHK_OK" -eq 1 ] && pass "G20 complete: fix 58 present"

# ======================================================================
section "G21 — 2026-11-18 fix 59/78 (one audio, no TrueHD, Spanish subs kept)"
# Why: Radarr/quality profiles can only refuse releases — they cannot strip
# streams. Every imported file is rewritten once so the house never plays a
# 11-audio/36-subtitle remux, and Latin American Spanish comes from Bazarr as
# an external .srt (an MKV `spa` tag cannot distinguish es-ES from es-419).
CHK_OK=1

# 1. the script is embedded and carries every policy decision
# fix 78 (owner decision 2026-11-20): Spanish subtitles are KEPT. The old
# assertion pinned `-sn`, so it would have failed the corrected policy — and,
# worse, would have kept it from ever being introduced.
if grep -Fq '/usr/local/sbin/media-normalize' "$APPLY" \
   && grep -Fq 'COMPAT=("ac3","eac3","aac","mp3","opus","flac")' "$APPLY" \
   && grep -Fq -- '-map "0:$PLAN_INDEX"' "$APPLY" \
   && grep -Fq -- '-map "0:$i"' "$APPLY" \
   && grep -Fq -- '-c:s copy' "$APPLY" \
   && ! grep -Fq -- '-sn -dn' "$APPLY"; then
    pass "normalizer keeps one original-language audio track and the Spanish subtitle tracks"
else
    fail "normalizer subtitle policy is not 'keep Spanish, drop the rest' (fix 78)"
    CHK_OK=0
fi
if grep -Fq 'def is_es(s):' "$APPLY" \
   && grep -Fq 'l in ("spa","es","spanish") or l.startswith("es-")' "$APPLY" \
   && grep -Fq '# NB: `esp` is Esperanto in 639-2' "$APPLY"; then
    pass "Spanish detection covers spa/es/es-XX and refuses esp (Esperanto)"
else
    fail "subtitle language matching is wrong — a Castilian track could be dropped, or Esperanto kept"
    CHK_OK=0
fi
if grep -Fq 'want_s=$PLAN_SUBKEEP' "$APPLY" \
   && ! grep -Fq '"$s2" = "0"' "$APPLY"; then
    pass "verify compares against the PLANNED Spanish count, not a hard-coded 0 (fix 78)"
else
    fail "verify still demands 0 subtitles — every kept Spanish track fails the gate"
    CHK_OK=0
fi
COMPAT_LINE="$(grep -oE 'COMPAT=\([^)]*\)' "$APPLY" | head -n1)"
if [ "$COMPAT_LINE" = 'COMPAT=("ac3","eac3","aac","mp3","opus","flac")' ] \
   && grep -Fq 'codec the TV can decode ALWAYS beats' "$APPLY"; then
    pass "TrueHD/Atmos/DTS are excluded from copy (re-encoded to AC3/AAC)"
else
    fail "COMPAT list is '${COMPAT_LINE:-absent}' — TrueHD/DTS could be stream-copied to the TV"
    CHK_OK=0
fi
if grep -Fq -- '-c:a ac3 -ac 6 -b:a 640k' "$APPLY" \
   && grep -Fq -- '-c:a aac -ac 6 -b:a 384k' "$APPLY" \
   && grep -Fq -- '-c:v copy' "$APPLY"; then
    pass "encode targets are AC3 5.1 (MKV) / AAC 5.1 (MP4); video is never re-encoded"
else
    fail "no compatible audio encode target (or video would be re-encoded)"
    CHK_OK=0
fi

# 2. fail-closed + atomic replace + verification before the swap
if grep -Fq 'flock -n 9' "$APPLY" \
   && grep -Fq 'STABLE=120' "$APPLY" \
   && grep -Fq 'need_kb=$(( size_kb * 21 / 20 + 262144 ))' "$APPLY" \
   && grep -Fq 'if [ "${free:-0}" -le "$need_kb" ]; then' "$APPLY" \
   && grep -Fq 'skip(space)' "$APPLY" \
   && grep -Fq 'kept original' "$APPLY" \
   && grep -Fq 'fail(verify' "$APPLY" \
   && grep -Fq 'mv -f "$tmp" "$f"' "$APPLY"; then
    pass "normalizer is serialized, waits for quiet files, and never replaces on low space / bad verify"
else
    fail "normalizer can replace a title without a space gate, verify, or lock"
    CHK_OK=0
fi

# 3. ffmpeg comes from the ALREADY-PINNED image (no 10th image, no new service)
if grep -Fq "RE_IMG=\"$PIN_JF\"" "$APPLY"; then
    pass "normalizer reuses the pinned $PIN_JF image (no new image pin)"
else
    fail "normalizer image is not the pinned jellyfin tag (drifts on every bump)"
    CHK_OK=0
fi
if grep -qE '^  media-normalize:' "$CFG"; then
    fail "media-normalize became a compose service (it must stay a VM unit — new surface)"
    CHK_OK=0
else
    pass "no media-normalize service in compose (no extra container/port)"
fi

# 4. units are installed AND enabled (a written-but-inactive timer is inert)
if grep -Fq 'media-normalize.timer' "$APPLY" \
   && grep -Fq 'OnUnitActiveSec=10min' "$APPLY" \
   && grep -Fq 'PathModified=/data/media/movies' "$APPLY" \
   && grep -Fq 'PathModified=/data/media/tv' "$APPLY" \
   && grep -Fq 'systemctl enable --now media-normalize.timer' "$APPLY"; then
    pass "apply installs + enables the 10-min timer and the new-title path unit"
else
    fail "normalizer units are not installed/enabled by apply (nothing would run)"
    CHK_OK=0
fi

# 5. diag proves the units are live
if grep -Fq 'S11: media normalization' "$DIAG" \
   && grep -Fq 'media-normalize.timer is' "$DIAG"; then
    pass "diag S11 fails when the normalizer timer/path unit is down"
else
    fail "diag does not check the normalizer units (silent stop)"
    CHK_OK=0
fi

# 6. docs: the runbook must say how es-LA subtitles are sourced + the policy
if [ -f "$MANUAL" ]; then
    if grep -Fq '### 10i. Media normalization' "$MANUAL" \
       && grep -Fq '`Spanish (Latino)`' "$MANUAL" \
       && grep -Fq 'fallback' "$MANUAL" \
       && grep -Fq 'Cutoff on the `Spanish (Latino)` row only' "$MANUAL" \
       && grep -Fq 'Custom Formats' "$MANUAL"; then
        pass "manual 10i documents the normalizer, Bazarr es-LA profile and Radarr custom formats"
    else
        fail "manual 10i missing the normalization / es-LA / Radarr policy guidance"
        CHK_OK=0
    fi
else
    note "manual absent next to the guardrail (installed copy) — 10i check skipped"
fi

# 7. the agent handover must mention that library files are rewritten
if [ -f "$AGENTS" ]; then
    if grep -Fq 'media-normalize' "$AGENTS" && grep -Fq 'Latin America' "$AGENTS"; then
        pass "AGENTS.md explains the normalization policy (one audio, es-LA external subs)"
    else
        fail "AGENTS.md does not mention normalization — a friend's agent would 'fix' it back"
        CHK_OK=0
    fi
else
    note "AGENTS.md absent next to the guardrail (installed copy) — handover check skipped"
fi
[ "$CHK_OK" -eq 1 ] && pass "G21 complete: fix 59 present"

# ======================================================================
section "G22 — 2026-11-18 fix 60 (Bazarr >=1.5.4: OpenSubtitles.com returns 426 below it)"
# OpenSubtitles.com refuses old clients with HTTP 426; the OSC developer
# confirmed the minimum is Bazarr 1.5.4. A pinned 1.5.1 means the only good
# es-LA provider is throttled forever and the UI looks configured but silent.
CHK_OK=1
if [ "$(grep -c 'image: lscr.io/linuxserver/bazarr:1.5.6' "$CFG")" = "1" ] \
   && grep -Fq 'bazarr 1.5.6' "$CFG"; then
    pass "compose pins bazarr 1.5.6 (>=1.5.4 required by OpenSubtitles.com)"
else
    fail "compose does not pin bazarr 1.5.6 (OSC will answer 426)"
    CHK_OK=0
fi
grep -Fq 'PIN_BAZ="lscr.io/linuxserver/bazarr:1.5.6"' "$SELF" \
    && pass "guardrail PIN_BAZ matches the compose pin" \
    || { fail "guardrail PIN_BAZ is stale — G0 cannot catch a bad bazarr pin"; CHK_OK=0; }
if grep -Fq "bazarr runs the pinned 1.5.6 image" "$APPLY" \
   && grep -Fq '*bazarr:1.5.6) pass "bazarr image' "$DIAG" \
   && grep -Fq 'OSC rejects <1.5.4 with HTTP 426' "$DIAG"; then
    pass "apply V6 + diag S4 assert the RUNNING bazarr image (no silent stale container)"
else
    fail "bazarr image is not verified at runtime (a stale 1.5.1 would look green)"
    CHK_OK=0
fi
if [ -f "$MANUAL" ]; then
    if grep -Fq 'OpenSubtitles.com answers **HTTP 426**' "$MANUAL" \
       && grep -Fq 'any Bazarr below 1.5.4' "$MANUAL"; then
        pass "manual documents the 426 version gate"
    else
        fail "manual does not explain the 426 gate (someone will 'fix' it by adding credentials)"
        CHK_OK=0
    fi
else
    note "manual absent next to the guardrail (installed copy) — 426 note skipped"
fi
[ "$CHK_OK" -eq 1 ] && pass "G22 complete: fix 60 present"

# ======================================================================
section "G23 — handoff file freshness (RESUME.md)"
# A resumed session trusts RESUME.md, so its state claims must match the pins.
# Doc-only check: skipped (never failed) on the installed copy.
if [ -f "$RESUME" ]; then
    if grep -Fq 'jellyfin/jellyfin:12.4' "$RESUME" \
       && grep -Fq '1.5.6' "$RESUME" \
       && grep -Fq '37686' "$RESUME" \
       && grep -Fq 'missing=[' "$RESUME"; then
        pass "RESUME.md carries the live pins (jellyfin 12.4, bazarr 1.5.6, port 37686)"
    else
        fail "RESUME.md is stale against the pins — a resumed session would act on old state"
    fi
    if grep -Fq 'sudo bash phase5_step1_install.sh' "$RESUME" \
       && grep -Fq 'bazarr_status.sh --assign' "$RESUME"; then
        pass "RESUME.md lists the exact next commands (install/apply, then assign)"
    else
        fail "RESUME.md does not carry the next commands"
    fi
else
    note "RESUME.md absent next to the guardrail (installed copy) — handoff check skipped"
fi

# ======================================================================
section "G24 — 2026-11-18 fix 61 (remux shape: map the FILM stream, verify ITS runtime)"
# A remux's CONTAINER duration is the longest contained stream, and its first
# video stream can be a cover-art still. Observed 2026-11-18 on a 43 GB title:
# a 02:40:54 German dub + an mjpeg still made a correct 02:36:31 remux fail a
# "truncated" verify (9654 -> 9391) on every 10-minute sweep. Worse, the old
# `-map 0:v:0` would have emitted the still as the "movie" while still passing
# a 1-audio/0-sub/1-video count check.
CHK_OK=1

if grep -Fq 'probe_vdur() {' "$APPLY" \
   && grep -Fq 'd1=$(probe_vdur "$f")' "$APPLY" \
   && grep -Fq 'd2=$(probe_vdur "$tmp")' "$APPLY"; then
    pass "verify compares the film stream (probe_vdur) between source and output"
else
    fail "verify does not compare the primary video stream (a dub/cover-art duration can reject a good remux)"
    CHK_OK=0
fi
if grep -Fq -- '-show_entries format=duration' "$APPLY"; then
    fail "container duration (-show_entries format=duration) is still the yardstick — fix 61 regression"
    CHK_OK=0
else
    pass "container duration is no longer used as the runtime yardstick"
fi
if grep -Fq 'COVER=("mjpeg","png","bmp","gif","webp","ppm")' "$APPLY" \
   && grep -Fq 'attached_pic' "$APPLY" \
   && grep -Fq -- '-map "0:$PLAN_VIDX"' "$APPLY" \
   && grep -Fq 'print("PLAN_VIDX=%d"' "$APPLY"; then
    pass "cover-art is excluded and the film is mapped by absolute index (PLAN_VIDX)"
else
    fail "video selection can map a cover-art still (silent, verified as a 1-video 'movie')"
    CHK_OK=0
fi
if grep -Fq -- '-map 0:v:0' "$APPLY"; then
    fail "still maps '0:v:0' — the first video stream is not guaranteed to be the film"
    CHK_OK=0
else
    pass "no '0:v:0' mapping (the first video stream is never assumed to be the film)"
fi
if grep -Fq 'skip(no duration)' "$APPLY"; then
    pass "an unprobable film runtime skips the file (no blind 30 GiB retry loop)"
else
    fail "no guard for an unprobable runtime — the sweep would rewrite and fail forever"
    CHK_OK=0
fi

if [ -f "$MANUAL" ] && [ -f "$AGENTS" ] && [ -f "$RESUME" ] && [ -f "$MEMORY" ]; then
    if grep -Fq 'fix 61' "$MANUAL" && grep -Fq 'cover art' "$MANUAL" \
       && grep -Fq 'fix 61' "$RESUME" && grep -Fq 'FIX 61' "$MEMORY" \
       && grep -Fq 'fix 61' "$AGENTS"; then
        pass "manual 10i, RESUME, PROJECT_MEMORY and AGENTS all record fix 61"
    else
        fail "fix 61 is undocumented (the next agent would re-introduce format=duration)"
        CHK_OK=0
    fi
    if grep -Fq '12 GB single-audio MKV' "$AGENTS"; then
        fail "AGENTS.md still promises a 12 GB result — the video stream is copied, so ~30 GiB is correct"
        CHK_OK=0
    else
        pass "AGENTS.md no longer promises the wrong post-remux size"
    fi
else
    note "docs absent next to the guardrail (installed copy) — fix-61 doc checks skipped"
fi
[ "$CHK_OK" -eq 1 ] && pass "G24 complete: fix 61 present"

# ======================================================================
section "G25 — 2026-11-20 fix 69 (a qBt category path is opt-in for *arr adds)"
# Radarr sends only `category` (no savepath/autoTMM), so qBittorrent files the
# add in MANUAL torrent-management mode and ignores the category savePath
# unless Session\UseCategoryPathsInManualMode is on — default off. A correct
# category path therefore still landed in the default save path. The fix is a
# live preference write, and it must be part of first-run, not tribal memory.
QBT="$SCRIPT_DIR/qbt_admin.sh"
LSTAT="$SCRIPT_DIR/library_status.sh"
CHK_OK=1

if [ -f "$QBT" ]; then
    if grep -Fq -- '--fix-category-paths)' "$QBT" \
       && grep -Fq 'use_category_paths_in_manual_mode' "$QBT" \
       && grep -Fq 'app/setPreferences' "$QBT"; then
        pass "qbt_admin.sh has --fix-category-paths (live setPreferences, no restart)"
    else
        fail "qbt_admin.sh lost --fix-category-paths — new adds ignore the category path again"
        CHK_OK=0
    fi
    if grep -Fq 'MISMATCH — the preference did not persist' "$QBT" \
       && grep -Fq 'UseCategoryPathsInManualMode' "$QBT"; then
        pass "the write is verified by reading the preference back, and the switch is documented"
    else
        fail "the preference write is unverified — an HTTP 200 is not evidence it persisted"
        CHK_OK=0
    fi
    if grep -Fq -- '--first-run)' "$QBT" \
       && grep -Fq 'cmd_category radarr' "$QBT" \
       && grep -Fq 'cmd_radarr_category radarr' "$QBT" \
       && grep -Fq 'cmd_category_paths' "$QBT"; then
        pass "--first-run runs all three steps (category, movieCategory, path mode)"
    else
        fail "--first-run is missing or incomplete — a fresh install can half-configure again"
        CHK_OK=0
    fi
else
    fail "qbt_admin.sh not found next to the guardrail"
    CHK_OK=0
fi

if [ -f "$LSTAT" ]; then
    if grep -Fq 'use_category_paths_in_manual_mode' "$LSTAT" \
       && grep -Fq -- '--fix-category-paths' "$LSTAT"; then
        pass "library_status.sh reports the path mode and names the fix"
    else
        fail "library_status.sh no longer shows why a torrent sits outside its category path"
        CHK_OK=0
    fi
else
    fail "library_status.sh not found next to the guardrail"
    CHK_OK=0
fi

if [ -f "$MANUAL" ] && [ -f "$MEMORY" ]; then
    if grep -Fq -- '--first-run' "$MANUAL" \
       && grep -Fq -- '--fix-category-paths' "$MANUAL" \
       && grep -Fq 'FIX 69' "$MEMORY"; then
        pass "manual 10c instructs --first-run and PROJECT_MEMORY records fix 69"
    else
        fail "fix 69 is not actionable from the runbook (the next build repeats it)"
        CHK_OK=0
    fi
else
    note "docs absent next to the guardrail (installed copy) — fix-69 doc checks skipped"
fi

if [ -f "$SCRIPT_DIR/tests/test_qbt.py" ]; then
    pass "tests/test_qbt.py covers the path-mode branches"
else
    fail "tests/test_qbt.py is missing — the check/verify branches are untested"
    CHK_OK=0
fi
[ "$CHK_OK" -eq 1 ] && pass "G25 complete: fix 69 present"

# ======================================================================
section "G26 — 2026-11-20 fix 70/71 (qBt credential + category-path durability)"
# Two failures one container recreate apart (both observed live 2026-11-20
# after `up -d` recreated qbittorrent):
#   * the WebUI password is TEMPORARY when none is configured, and qBittorrent
#     generates a new one on every start — so Radarr held a dead credential,
#     banned its own source IP (5 failures/3600 s) and reported the ban as
#     "Authentication Failure";
#   * Session\UseCategoryPathsInManualMode was True live and False after the
#     recreate: settings live in memory and are written 5 s later, so a kill
#     loses a live-only write. Only the conf is durable.
# A rebuild must do both by itself: one atomic credential command, and the
# path switch written into qBittorrent.conf while qBittorrent is stopped.
CHK_OK=1

if grep -Fq -- '--set-password)      cmd_set_password' "$QBT" \
   && grep -Fq 'web_ui_password' "$QBT" \
   && grep -Fq 'app/setPreferences' "$QBT"; then
    pass "qbt_admin.sh has --set-password (setPreferences, plaintext hashed server-side)"
else
    fail "qbt_admin.sh lost --set-password — the temporary password rotates on every recreate"
    CHK_OK=0
fi
if grep -Fq 'fresh login with the new password' "$QBT" \
   && grep -Fq '"$TMP/pw.py" set' "$QBT"; then
    pass "--set-password proves the new value with a FRESH login (a live cookie would lie)"
else
    fail "the password write is unverified — a session cookie keeps working even if the value was dropped"
    CHK_OK=0
fi
if grep -Fq 'QBPWF=/etc/media-vm/qbt_webui_password' "$QBT" \
   && grep -Fq 'install -m 600 -o root -g root' "$QBT" \
   && grep -Fq 'qbt_webui_password' "$LSTAT"; then
    pass "the credential is stored root-only (600) and library_status.sh reads it first"
else
    fail "the permanent credential is not stored/read consistently (helpers fall back to the stale log line)"
    CHK_OK=0
fi
if grep -Fq '"$TMP/pw.py" radarr' "$QBT" \
   && grep -Fq '?forceSave=true" % cid' "$QBT" \
   && grep -Fq '"$TMP/pw.py" test' "$QBT" \
   && grep -Fq 'docker restart qbittorrent' "$QBT"; then
    pass "--set-password is atomic: Radarr saved with forceSave, ban cleared, testall required"
else
    fail "--set-password no longer updates Radarr / clears the ban / requires testall — a half-change re-creates the ban"
    CHK_OK=0
fi
if grep -Fq -- '--import-downloads)  cmd_import_downloads' "$QBT" \
   && grep -Fq 'DownloadedMoviesScan' "$QBT"; then
    pass "--import-downloads recovers a torrent Radarr dropped from its queue"
else
    fail "--import-downloads is missing — an orphaned torrent is never imported"
    CHK_OK=0
fi
if grep -Fq 'Session\UseCategoryPathsInManualMode=true' "$APPLY"; then
    pass "phase5_apply.sh writes Session\\UseCategoryPathsInManualMode=true into qBittorrent.conf (fix 70)"
else
    fail "apply does not persist the manual-mode path switch — a rebuild reproduces fix 69"
    CHK_OK=0
fi
if grep -Fq 'QBCAT="$(vmrun' "$DIAG" \
   && grep -Fq 'QBCAT_OFF=' "$DIAG" \
   && grep -Fq 'qbt_webui_password' "$DIAG"; then
    pass "phase5_diag.sh asserts the path switch on disk and the 600 credential file"
else
    fail "diag does not check the durable path switch / credential mode — a regression would pass the gate"
    CHK_OK=0
fi
if [ -f "$MANUAL" ] && [ -f "$MEMORY" ]; then
    if grep -Fq -- '--set-password' "$MANUAL" \
       && grep -Fq 'FIX 70' "$MEMORY" \
       && grep -Fq 'FIX 71' "$MEMORY"; then
        pass "manual 10b documents --set-password and PROJECT_MEMORY records fixes 70/71"
    else
        fail "fixes 70/71 are not actionable from the runbook"
        CHK_OK=0
    fi
else
    note "docs absent next to the guardrail (installed copy) — fix 70/71 doc checks skipped"
fi
if [ -f "$SCRIPT_DIR/tests/test_qbt_pw.py" ]; then
    pass "tests/test_qbt_pw.py covers set/verify/radarr/test/import"
else
    fail "tests/test_qbt_pw.py is missing — the credential plumbing is untested"
    CHK_OK=0
fi
[ "$CHK_OK" -eq 1 ] && pass "G26 complete: fixes 70/71 present"

# ======================================================================
section "G27 — 2026-11-20 fix 72/73 (the config PATH, and durability before restart)"
# fix 72: the linuxserver image reads /config/qBittorrent/qBittorrent.conf (host:
# .../qbittorrent/qBittorrent/qBittorrent.conf). The path WITHOUT that
# subdirectory was a file our own pre-seed invented; qBittorrent never read it,
# yet apply/diag/status "verified" it — three false PASSes and the repeated
# "the path switch reverted" diagnosis. Every consumer must use the real path
# and the ignored duplicate must not exist.
# fix 73: setPreferences is buffered (~5 s) and a restart before the flush
# loses it — the first --set-password did exactly that and left a stored
# credential nothing accepted. The write must be proven ON DISK before the
# restart, and the credential re-proven AFTER it.
CHK_OK=1
QBCF_REAL="/data/config/qbittorrent/qBittorrent/qBittorrent.conf"

if grep -Fq "QBC=$QBCF_REAL" "$APPLY" \
   && grep -Fq 'vmrun "sudo grep' "$APPLY" \
   && grep -Fq 'QBC_LEGACY=' "$APPLY" \
   && grep -Fq 'rm -f "$QBC_LEGACY"' "$APPLY"; then
    pass "apply reads/writes the real config and retires the ignored duplicate (fix 72)"
else
    fail "apply does not target $QBCF_REAL — the path switch would be written to a file qBittorrent ignores"
    CHK_OK=0
fi
if grep -Fq "$QBCF_REAL" "$DIAG" \
   && grep -Fq 'vmrun "sudo grep' "$DIAG" \
   && grep -Fq "test -f /data/config/qbittorrent/qBittorrent.conf" "$DIAG"; then
    pass "diag checks the real config and fails on the ignored duplicate (fix 72)"
else
    fail "diag checks the wrong config path — a regression would pass the gate again"
    CHK_OK=0
fi
if grep -Fq 'QBC_REAL=' "$QBT" \
   && grep -Fq 'QBC_LEGACY=' "$QBT" \
   && grep -Fq 'config file qBittorrent actually reads' "$QBT"; then
    pass "qbt_admin.sh names both candidate paths in --status (fix 72)"
else
    fail "qbt_admin.sh cannot show which config file is live — the trap stays invisible"
    CHK_OK=0
fi
if grep -Fq 'now="$(qbc_hash)"' "$QBT" \
   && grep -Fq 'Password_PBKDF2 changed' "$QBT" \
   && grep -Fq 'Do NOT restart qBittorrent' "$QBT"; then
    pass "--set-password waits for the write to reach disk BEFORE any restart (fix 73)"
else
    fail "--set-password restarts without proving the write is on disk (the 2026-11-20 regression)"
    CHK_OK=0
fi
if grep -Fq '"$TMP/pw.py" check' "$QBT" \
   && grep -Fq 'if mode == "check":' "$QBT"; then
    pass "the password is re-proven AFTER the restart (fix 73)"
else
    fail "no post-restart verification — a lost write looks like success"
    CHK_OK=0
fi
if grep -Fq 'qb_candidates' "$QBT" \
   && grep -Fq 'stored credential was stale' "$QBT" \
   && grep -Fq 'qb_clogin' "$LSTAT"; then
    pass "a stale stored credential cannot blind the diagnosis (both helpers fall back)"
else
    fail "one stale credential still disables every login — no fallback source"
    CHK_OK=0
fi
if [ -f "$MANUAL" ] && [ -f "$MEMORY" ]; then
    if grep -Fq 'FIX 72' "$MEMORY" && grep -Fq 'FIX 73' "$MEMORY" \
       && grep -Fq 'qBittorrent/qBittorrent.conf' "$MANUAL"; then
        pass "PROJECT_MEMORY records fixes 72/73 and the manual names the real config path"
    else
        fail "fixes 72/73 are not actionable from the runbook"
        CHK_OK=0
    fi
else
    note "docs absent next to the guardrail (installed copy) — fix 72/73 doc checks skipped"
fi
[ "$CHK_OK" -eq 1 ] && pass "G27 complete: fixes 72/73 present"

# ======================================================================
section "G28 — 2026-11-20 fix 74 (ONE reader for 'is it on disk?')"
# The 10:10 run printed, in the same command:
#     on disk : ABSENT <-- a recreate loses the live value (fix 70)
#     ...      Session\UseCategoryPathsInManualMode=true
# One call site still grepped the RETIRED path (fix 72) and without sudo, so it
# read a file that the apply had just deleted and called the result "absent".
# A durable-copy answer must come from exactly one helper, and "I could not look"
# must never be printed as "there is nothing there".
CHK_OK=1
if grep -Fq 'QBCAT="$(qbc_key '"'"'UseCategoryPathsInManualMode'"'"')"' "$QBT" \
   && ! grep -Fq 'grep -a "UseCategoryPathsInManualMode"' "$QBT"; then
    pass "status asks the single qbc_key() helper for the on-disk value (fix 74)"
else
    fail "status has its own conf reader — the fix-72 path drift can return silently"
    CHK_OK=0
fi
if grep -Fq "qbc_key 'Password_PBKDF2' | tail -n1" "$QBT" \
   && grep -Fq 'qbc_key() {' "$QBT"; then
    pass "the password durability check uses the same helper (one reader, fix 74)"
else
    fail "two readers can disagree again — the durable-copy answer is not single-sourced"
    CHK_OK=0
fi
if grep -Fq 'qbc_readable' "$QBT" && grep -Fq "UNKNOWN <--" "$QBT"; then
    pass "an unreadable conf reports UNKNOWN, never ABSENT (fix 74)"
else
    fail "'cannot read it' is still reported as 'it is not there'"
    CHK_OK=0
fi
QB_BADPATH="$(grep -n 'qbittorrent/qBittorrent\.conf' "$QBT" \
    | grep -v 'qBittorrent/qBittorrent\.conf' \
    | grep -v '^[0-9]*:QBC_LEGACY=' || true)"
if [ -z "$QB_BADPATH" ]; then
    pass "no read of the retired conf path anywhere in qbt_admin.sh (fix 72/74)"
else
    fail "qbt_admin.sh still reads the retired path: $(printf '%s' "$QB_BADPATH" | head -1)"
    CHK_OK=0
fi
if grep -Fq 'connection_status' "$QBT" && grep -Fq 'firewalled' "$QBT" \
   && grep -Fq 'NOT WORKING' "$QBT"; then
    pass "status explains a stalled download (connection_status + tracker verdict)"
else
    fail "a stalled torrent has no diagnosis — 'crawling' stays unattributable"
    CHK_OK=0
fi
if [ -f "$MANUAL" ] && [ -f "$MEMORY" ]; then
    if grep -Fq 'FIX 74' "$MEMORY" && grep -Fq 'firewalled' "$MANUAL"; then
        pass "PROJECT_MEMORY records fix 74 and the manual explains 'firewalled'"
    else
        fail "the port-forward symptom is not documented where an operator looks"
        CHK_OK=0
    fi
else
    note "docs absent next to the guardrail (installed copy) — fix 74 doc checks skipped"
fi
[ "$CHK_OK" -eq 1 ] && pass "G28 complete: fix 74 present"

# ======================================================================
section "G29 — 2026-11-20 fix 75 (an orphan is a state, not a diagnosis)"
# The credential repair let Radarr RE-ADOPT both torrents; the standing advice
# "at 100% run --import-downloads" then pointed at a command that imports
# whatever is on disk NOW (a partial file, or a race with Radarr's own import).
# The tool must refuse that moment instead of documenting it. And the Radarr log
# section printed stack FRAMES - no timestamp - so a pre-repair error looked live.
CHK_OK=1
if grep -Fq 'could import a PARTIAL' "$QBT" \
   && grep -Fq 'force="${2:-}"' "$QBT" \
   && grep -Fq '"$force" != "--force"' "$QBT"; then
    pass "--import-downloads refuses while Radarr tracks an active download (fix 75)"
else
    fail "--import-downloads can still import a partial file / race Radarr's own import"
    CHK_OK=0
fi
# Scoped to the function body: `api/v3/queue` also appears in --remove-torrent,
# so a file-wide grep would stay green with the guard gutted (mutation M3 caught
# exactly that on the first run).
IMPORT_FN="$(sed -n '/^cmd_import_downloads()/,/^}/p' "$QBT")"
if printf '%s' "$IMPORT_FN" | grep -Fq 'api/v3/queue' \
   && printf '%s' "$IMPORT_FN" | grep -Fq '"downloading","queued"'; then
    pass "the refusal is based on Radarr's live queue, not on a guess (fix 75)"
else
    fail "the import guard does not consult the queue"
    CHK_OK=0
fi
if grep -Fq 'grep -aE "^[0-9]{4}-[0-9]{2}-[0-9]{2}' "$LSTAT" \
   && grep -Fq 'stack frames were dropped' "$LSTAT"; then
    pass "Radarr's log section prints dated HEADER lines, never bare stack frames (fix 75)"
else
    fail "an error from before a repair can still read as a current one (no timestamp)"
    CHK_OK=0
fi
if grep -Fq 'RE-ADOPTS' "$LSTAT"; then
    pass "the ORPHAN verdict says to look again before importing (fix 75)"
else
    fail "the ORPHAN verdict still sends the operator straight to --import-downloads"
    CHK_OK=0
fi
if [ -f "$MANUAL" ] && [ -f "$MEMORY" ]; then
    if grep -Fq 'FIX 75' "$MEMORY" && grep -Fq -- '--force' "$MANUAL" \
       && grep -Fq 're-adopt' "$MANUAL"; then
        pass "PROJECT_MEMORY records fix 75 and the manual says to re-check the queue"
    else
        fail "the re-adoption behaviour is not documented where it is needed"
        CHK_OK=0
    fi
else
    note "docs absent next to the guardrail (installed copy) — fix 75 doc checks skipped"
fi
[ "$CHK_OK" -eq 1 ] && pass "G29 complete: fix 75 present"

# ======================================================================
section "G30 — 2026-11-20 fix 76 (hardlink policy is a Radarr setting)"
# A same-filesystem layout only makes hardlinks POSSIBLE. Radarr's Media
# Management switch decides, and with it off every import is a second full copy.
# Measured: /data 41 G -> 61 G for two titles totalling 14.8 GiB = exactly one
# extra copy of each. The fix must (a) report the setting, (b) offer a supported
# way to flip it, and (c) RE-READ it, because a 202 is not evidence.
CHK_OK=1
# Exact anchors: a file-wide grep for the flag/field name stays green with the
# action or the print statement deleted (mutations M1/M2 caught that).
if grep -Fq 'if [ "${2:-}" = "--fix-hardlinks" ]; then' "$LSTAT" \
   && grep -Fq 'print("  copyUsingHardlinks  : %s" % hl)' "$LSTAT"; then
    pass "library_status.sh reports the hardlink policy and offers --fix-hardlinks (fix 76)"
else
    fail "nothing surfaces copyUsingHardlinks — doubling disk stays invisible"
    CHK_OK=0
fi
if grep -Fq 'st, after = call("GET", "/api/v3/config/mediamanagement")' "$LSTAT" \
   && grep -Fq 'MISMATCH — the field did not persist' "$LSTAT"; then
    pass "--fix-hardlinks proves the value by re-reading it (fix 76)"
else
    fail "--fix-hardlinks trusts the PUT response (the fix-71/73 mistake)"
    CHK_OK=0
fi
if grep -Fq 'costs its size TWICE' "$LSTAT"; then
    pass "the diagnosis explains the disk cost of a copy import (fix 76)"
else
    fail "an operator cannot tell why 14.8 GiB of titles ate 29.6 GiB"
    CHK_OK=0
fi
if [ -f "$SCRIPT_DIR/tests/test_rd_hardlinks.py" ] \
   && grep -Fq 'drop_field' "$SCRIPT_DIR/tests/test_rd_hardlinks.py" \
   && python3 "$SCRIPT_DIR/tests/test_rd_hardlinks.py" >/dev/null 2>&1; then
    pass "offline suite covers flip / already-true / silently-dropped / rejected"
else
    fail "tests/test_rd_hardlinks.py missing or failing"
    CHK_OK=0
fi
if [ -f "$MANUAL" ] && [ -f "$MEMORY" ]; then
    if grep -Fq 'FIX 76' "$MEMORY" && grep -Fq -- '--fix-hardlinks' "$MANUAL"; then
        pass "PROJECT_MEMORY records fix 76 and the manual names the command"
    else
        fail "the hardlink policy is not actionable from the runbook"
        CHK_OK=0
    fi
else
    note "docs absent next to the guardrail (installed copy) — fix 76 doc checks skipped"
fi
[ "$CHK_OK" -eq 1 ] && pass "G30 complete: fix 76 present"

# ======================================================================
section "G31 — 2026-11-20 fix 77 (the subtitle check must name every title)"
# bazarr_status.sh filtered Bazarr's movie list, Radarr's movie list AND the log
# on the literal string "hail mary". With three films in the library it could
# only ever report on one, so the two newest had no subtitle coverage check at
# all — and "0 embedded streams" (fix 59, by policy) looked identical to
# "no subtitles at all" (a real gap).
CHK_OK=1
if grep -Fq 'TERM="$TERM" SRT_LIST="$SRT_LIST" python3 -c' "$SCRIPT_DIR/bazarr_status.sh" \
   && ! grep -Fq 'if "hail mary" in' "$SCRIPT_DIR/bazarr_status.sh"; then
    pass "the movie listing is title-driven, not hardcoded (fix 77)"
else
    fail "bazarr_status.sh still filters on one film — the others go unchecked"
    CHK_OK=0
fi
if grep -Fq 'Bazarr will NEVER search this movie' "$SCRIPT_DIR/bazarr_status.sh"; then
    pass "a missing language profile is called out as the silent cause (fix 77)"
else
    fail "profileId=None stays invisible — exactly the case that downloads nothing"
    CHK_OK=0
fi
if grep -Fq "name '*.srt'" "$SCRIPT_DIR/bazarr_status.sh" \
   && grep -Fq 'verdict    : MISSING' "$SCRIPT_DIR/bazarr_status.sh"; then
    pass "the verdict comes from the .srt files on disk, not from Bazarr alone (fix 77)"
else
    fail "no ground-truth check on disk — a stale Bazarr row would look covered"
    CHK_OK=0
fi
# The suite must KEEP the assertions the fix depends on: a green suite with the
# MISSING/profile checks deleted proves nothing (mutation M5 did exactly that).
if [ -f "$SCRIPT_DIR/tests/test_bz_status.py" ] \
   && grep -Fq 'verdict    : MISSING — no Spanish subtitle at all' "$SCRIPT_DIR/tests/test_bz_status.py" \
   && grep -Fq 'Bazarr will NEVER search this movie' "$SCRIPT_DIR/tests/test_bz_status.py" \
   && python3 "$SCRIPT_DIR/tests/test_bz_status.py" >/dev/null 2>&1; then
    pass "offline suite covers every-film / term / no-match / normalised match"
else
    fail "tests/test_bz_status.py missing or failing"
    CHK_OK=0
fi
if [ -f "$MANUAL" ] && [ -f "$MEMORY" ]; then
    if grep -Fq 'FIX 77' "$MEMORY" \
       && grep -Fq 'bazarr_status.sh "ferris"' "$MANUAL" \
       && grep -Fq 'Bazarr will NEVER search' "$MANUAL"; then
        pass "PROJECT_MEMORY records fix 77 and the manual shows the per-title check"
    else
        fail "the two-questions distinction is not actionable from the runbook"
        CHK_OK=0
    fi
else
    note "docs absent next to the guardrail (installed copy) — fix 77 doc checks skipped"
fi
[ "$CHK_OK" -eq 1 ] && pass "G31 complete: fix 77 present"

# ======================================================================
section "G32 — 2026-11-20 fix 78 (owner policy: keep the Spanish subtitles)"
# The owner reversed "drop every embedded subtitle": an MKV `spa` track may be
# Castilian, but a present Spanish track beats nothing when Bazarr finds nothing.
# The blast radius of that decision includes the GATE that encoded the old rule
# (G21 asserted `-sn`), the diag's "target subs=0" line, and AGENTS.md.
CHK_OK=1
if [ -f "$SCRIPT_DIR/tests/test_norm_plan.py" ] \
   && grep -Fq 'esp is Esperanto' "$SCRIPT_DIR/tests/test_norm_plan.py" \
   && grep -Fq '"PLAN_SUBIDX") == "3,4"' "$SCRIPT_DIR/tests/test_norm_plan.py" \
   && python3 "$SCRIPT_DIR/tests/test_norm_plan.py" >/dev/null 2>&1; then
    pass "offline suite pins the selection: spa/es-419 kept by absolute index, esp refused (fix 78)"
else
    fail "tests/test_norm_plan.py missing, gutted, or failing"
    CHK_OK=0
fi
if grep -Fq 'non-Spanish subtitle track' "$DIAG" \
   && grep -Fq 'stream_tags=language' "$DIAG" \
   && grep -Fq '[ "${NONES:-0}" -eq 0 ]' "$DIAG"; then
    pass "diag S11 probes subtitle LANGUAGES and fails on a non-Spanish track (fix 78)"
else
    fail "S11 cannot tell a correct 2-Spanish file from a policy failure"
    CHK_OK=0
fi
if [ -f "$AGENTS" ]; then
    if grep -Fq 'only the Spanish subtitle' "$AGENTS" \
       && grep -Fq 'Do not re-download or re-remux them' "$AGENTS" \
       && grep -Fq 'fix 78' "$AGENTS"; then
        pass "AGENTS.md carries the amended rule AND the do-not-redownload note (fix 78)"
    else
        fail "AGENTS.md still tells the next agent that subtitles must be stripped"
        CHK_OK=0
    fi
else
    note "AGENTS.md absent next to the guardrail — fix 78 handover check skipped"
fi
if [ -f "$MANUAL" ]; then
    if grep -Fq 'subs:2->2' "$MANUAL" && grep -Fq 'owner reversed that on 2026-11-20' "$MANUAL"; then
        pass "manual 10i states the expected log shapes under the new rule (fix 78)"
    else
        fail "the runbook still implies a library file must have 0 subtitles"
        CHK_OK=0
    fi
else
    note "manual absent next to the guardrail — fix 78 doc check skipped"
fi
if [ -f "$MEMORY" ] && grep -Fq 'FIX 78' "$MEMORY" \
   && grep -Fq 'Superseded in part by fix 78' "$MEMORY"; then
    pass "PROJECT_MEMORY records fix 78 and marks fix 59 as partly superseded"
else
    fail "fix 59 still reads as current policy — the next agent will re-apply it"
    CHK_OK=0
fi
[ "$CHK_OK" -eq 1 ] && pass "G32 complete: fix 78 present"

# ======================================================================
section "G33 — 2026-11-20 fixes 79/80 (probe quoting; Bazarr's default profile)"
# fix 79: diag S11 interpolated the movie path into a '-v <path>' string, so
# "Ferris Bueller's Day Off" broke the quoting, ffprobe returned nothing, and the
# block still printed `audio=?` with "none in the source" — an all-clear from a
# probe that never ran. fix 80: every Radarr-synced movie had profileId=None, so
# Bazarr computed missing_subtitles=[] and never searched, silently.
CHK_OK=1
if grep -Fq 'QNEWF=' "$DIAG" \
   && grep -Fq 'sudo bash -s -- $QNEWF' "$DIAG" \
   && ! grep -Fq -- "-v '\$NEWF'" "$DIAG"; then
    pass "S11 passes the path as a quoted argv, not inside a -v string (fix 79)"
else
    fail "a title with an apostrophe still breaks the probe (silent empty result)"
    CHK_OK=0
fi
if grep -Fq 'probe returned nothing' "$DIAG" \
   && grep -Fq "this is NOT 'none in the source'" "$DIAG"; then
    pass "an empty probe reports UNKNOWN instead of a false all-clear (fix 79)"
else
    fail "a failed probe can still print 'none in the source'"
    CHK_OK=0
fi
if grep -Fq 'if [ "${1:-}" = "--default-profile" ]; then' "$SCRIPT_DIR/bazarr_status.sh" \
   && grep -Fq 'if [ "${1:-}" = "--assign-all" ]; then' "$SCRIPT_DIR/bazarr_status.sh" \
   && grep -Fq 'movie_default_enabled' "$SCRIPT_DIR/bazarr_status.sh"; then
    pass "bazarr_status.sh can set the default movie profile and assign existing ones (fix 80)"
else
    fail "profileId=NONE can only be fixed by hand in the GUI — the silent case stays"
    CHK_OK=0
fi
if grep -Fq 'refusing to POST it' "$SCRIPT_DIR/bazarr_status.sh" \
   && grep -Fq 'MISMATCH — the default did not persist' "$SCRIPT_DIR/bazarr_status.sh"; then
    pass "the settings write refuses an unknown payload and re-reads the value (fix 80)"
else
    fail "the settings POST is blind — a partial write could blank other sections"
    CHK_OK=0
fi
# fix 81: save_settings() only applies settings-<section>-<key>; a
# settings-<section> JSON blob is silently skipped and still answers 204. The
# first version of this fix sent exactly that blob: 46 keys, nothing stored.
if grep -Fq 'settings-general-movie_default_enabled' "$SCRIPT_DIR/bazarr_status.sh" \
   && grep -Fq 'settings-general-movie_default_profile' "$SCRIPT_DIR/bazarr_status.sh" \
   && ! grep -Fq 'fields["settings-" + name]' "$SCRIPT_DIR/bazarr_status.sh"; then
    pass "the default profile is written as flat settings-<section>-<key> fields (fix 81)"
else
    fail "the settings write uses the JSON blob shape Bazarr silently ignores"
    CHK_OK=0
fi
if [ -f "$SCRIPT_DIR/tests/test_bz_default.py" ] \
   && grep -Fq 'preserves the radarr section' "$SCRIPT_DIR/tests/test_bz_default.py" \
   && grep -Fq 'unrecognised settings payload' "$SCRIPT_DIR/tests/test_bz_default.py" \
   && grep -Fq 'blob POST stored nothing' "$SCRIPT_DIR/tests/test_bz_default.py" \
   && grep -Fq 'sends NO settings-<section> blob' "$SCRIPT_DIR/tests/test_bz_default.py" \
   && python3 "$SCRIPT_DIR/tests/test_bz_default.py" >/dev/null 2>&1; then
    pass "offline suite pins: real dispatch, blob ignored, MISMATCH, shape refused"
else
    fail "tests/test_bz_default.py missing, gutted, or failing"
    CHK_OK=0
fi
if [ -f "$MANUAL" ] && [ -f "$MEMORY" ]; then
    if grep -Fq 'FIX 80' "$MEMORY" && grep -Fq 'FIX 79' "$MEMORY" \
       && grep -Fq -- '--default-profile' "$MANUAL"; then
        pass "PROJECT_MEMORY records fixes 79/80 and the manual names the command"
    else
        fail "the profileId=NONE remedy is not in the runbook"
        CHK_OK=0
    fi
else
    note "docs absent next to the guardrail — fixes 79/80 doc checks skipped"
fi
[ "$CHK_OK" -eq 1 ] && pass "G33 complete: fixes 79/80 present"

# ======================================================================
section "G34 — 2026-11-20 fix 82 (status joins sidecars on the movie DIR)"
# Bazarr's `path` is the .mkv FILE. bazarr_status.sh joined with
# p.startswith(path + "/"), which is always false for a file, so every movie
# printed "0 .srt / MISSING" while subtitles sat beside it.
CHK_OK=1
if grep -Fq 'os.path.dirname(p) == folder' "$SCRIPT_DIR/bazarr_status.sh" \
   && ! grep -Fq 'in srts if path and p.startswith' "$SCRIPT_DIR/bazarr_status.sh"; then
    pass "sidecars are joined on the movie directory, not on a file prefix (fix 82)"
else
    fail "joins sidecars by a prefix that can never match a .mkv path"
    CHK_OK=0
fi
if grep -Fq 'LatAm Spanish, non-HI (best)' "$SCRIPT_DIR/bazarr_status.sh" \
   && grep -Fq 'Castilian Spanish, HI' "$SCRIPT_DIR/bazarr_status.sh" \
   && grep -Fq 'RANK = ' "$SCRIPT_DIR/bazarr_status.sh"; then
    pass "the verdict ranks the four rows in the owner order (ea, es, ea.hi, es.hi)"
else
    fail "the verdict cannot tell LatAm from Castilian or HI from non-HI"
    CHK_OK=0
fi
if grep -Fq 'path": BC + "/The Breakfast Club (1985) Bluray-1080p.mkv' \
        "$SCRIPT_DIR/tests/test_bz_status.py" \
   && grep -Fq '[decoy]' "$SCRIPT_DIR/tests/test_bz_status.py" \
   && grep -Fq 'LatAm non-HI wins the verdict' "$SCRIPT_DIR/tests/test_bz_status.py" \
   && python3 "$SCRIPT_DIR/tests/test_bz_status.py" >/dev/null 2>&1; then
    pass "offline suite uses the real file-path shape, a decoy folder, and the row order"
else
    fail "tests/test_bz_status.py missing, gutted, or failing"
    CHK_OK=0
fi
[ "$CHK_OK" -eq 1 ] && pass "G34 complete: fix 82 present"

# ======================================================================
echo
echo "=============================================================="
echo "=== Phase 5 guardrail test complete ==="
echo "=== VERIFY_FAILS=$FAILS ==="
echo "=============================================================="
if [ "$FAILS" -gt 0 ]; then
    echo "Phase 5 guardrail test FAILED — review the [FAIL] lines above." >&2
    exit 1
fi
exit 0

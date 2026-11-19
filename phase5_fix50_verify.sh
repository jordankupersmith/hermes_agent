#!/usr/bin/env bash
#
# Phase 5 — fix 50 acceptance checks (READ-ONLY).
#
# Run as root or jordan; changes nothing. Covers:
#   1. no host socket unit is ordered after network-online.target
#   2. the live socket parses and carries no network-online ordering
#   3. FreeBind=yes is live and no daemon-reload is pending
#   4. listener + end-to-end relay + triggered service
#   5. offline guardrail green (working copy and installed copy)
#   6. installed tree mirrors the working copy
#   7. every bash artifact still parses
#   8. boot evidence: one automatic bind this boot, no ordering cycle / bind
#      failure, no manual restart, socket enabled
#
# Usage:
#   bash /home/jordan/Documents/SystemBuild/phase5_fix50_verify.sh
#
set -uo pipefail

SRC_DIR="${SRC_DIR:-/home/jordan/Documents/SystemBuild}"
DEST_DIR="${DEST_DIR:-/usr/local/sbin/phase5}"
SOCKET=/etc/systemd/system/jellyfin-lan-proxy.socket
SVC=/etc/systemd/system/jellyfin-lan-proxy.service
LAN_IP=192.168.1.133

FAILS=0
pass() { printf '  [PASS] %s\n' "$*"; }
fail() { printf '  [FAIL] %s\n' "$*"; FAILS=$((FAILS + 1)); }
note() { printf '  [note] %s\n' "$*"; }
sub()  { printf '\n----- %s -----\n' "$*"; }

echo "=============================================================="
echo " Phase 5 — fix 50 acceptance checks (read-only)"
echo "=============================================================="

# ---------------------------------------------------------------- 1. no socket
sub "1. no host socket unit ordered after network-online.target"
BAD="$(grep -rlE '^After=.*network-online' \
        /etc/systemd/system/*.socket /usr/lib/systemd/system/*.socket 2>/dev/null || true)"
if [ -z "$BAD" ]; then
    pass "no .socket unit carries After=.*network-online"
else
    fail "socket unit(s) still ordered after network-online: $BAD"
fi

# ------------------------------------------------------------- 2. socket unit
sub "2. live socket: parses + no network-online ordering"
if [ -L "$SOCKET" ]; then
    fail "$SOCKET is a symlink (must be a regular root-owned file)"
elif [ ! -f "$SOCKET" ]; then
    fail "$SOCKET missing"
else
    pass "$SOCKET present (regular file)"
fi
VERIFY_OUT="$(systemd-analyze verify "$SOCKET" 2>&1)"
VERIFY_RC=$?
if [ "$VERIFY_RC" -eq 0 ]; then
    pass "systemd-analyze verify: OK"
else
    fail "systemd-analyze verify rc=$VERIFY_RC"
    printf '%s\n' "$VERIFY_OUT" | sed 's/^/           /'
fi
AFTER_NET="$(systemctl show jellyfin-lan-proxy.socket -p After 2>/dev/null | tr ' ' '\n' | grep -c 'network-online' || true)"
if [ "${AFTER_NET:-0}" -eq 0 ]; then
    pass "systemctl show: no network-online in After"
else
    fail "systemctl show: After still contains network-online ($AFTER_NET)"
fi
if grep -qE '^(After|Wants)=.*network-online' "$SOCKET" 2>/dev/null; then
    fail "$SOCKET still carries socket-level network-online ordering"
else
    pass "socket file carries no After=/Wants= network-online"
fi
if grep -qF 'ListenStream=192.168.1.133:8096' "$SOCKET" 2>/dev/null; then
    pass "ListenStream still pinned to $LAN_IP:8096 (never a wildcard)"
else
    fail "ListenStream pin lost (wildcard or changed bind)"
fi

# ------------------------------------------------------- 3. FreeBind + reload
sub "3. FreeBind live, no pending daemon-reload"
SHOW="$(systemctl show jellyfin-lan-proxy.socket -p FreeBind -p NeedDaemonReload 2>/dev/null)"
printf '%s\n' "$SHOW" | sed 's/^/  /'
printf '%s\n' "$SHOW" | grep -q '^FreeBind=yes$' \
    && pass "FreeBind=yes live" \
    || fail "FreeBind is not yes (pre-DHCP bind race remains)"
printf '%s\n' "$SHOW" | grep -q '^NeedDaemonReload=no$' \
    && pass "NeedDaemonReload=no" \
    || fail "NeedDaemonReload=yes (run: systemctl daemon-reload)"

# --------------------------------------------------- 4. listener + relay + svc
sub "4. listener + end-to-end relay + triggered service"
systemctl is-active --quiet jellyfin-lan-proxy.socket \
    && pass "jellyfin-lan-proxy.socket active" \
    || fail "jellyfin-lan-proxy.socket not active"
LISTENER="$(ss -tlnH 'sport = :8096' 2>/dev/null | awk '{print $4}' | sort -u)"
if [ "$LISTENER" = "$LAN_IP:8096" ]; then
    pass "exactly one 8096 listener: $LISTENER"
else
    fail "unexpected 8096 listener set: '${LISTENER:-<none>}' (want $LAN_IP:8096)"
fi
CODE="$(curl -sS -m 8 -o /dev/null -w '%{http_code}' -I "http://$LAN_IP:8096" 2>/dev/null || true)"
case "$CODE" in
    200|301|302) pass "relay http://$LAN_IP:8096 -> HTTP $CODE" ;;
    *)           fail "relay probe -> HTTP '${CODE:-000}' (proxy or Jellyfin down)" ;;
esac
systemctl is-active --quiet jellyfin-lan-proxy.service \
    && pass "jellyfin-lan-proxy.service active (triggered)" \
    || note "service not active — it starts on the next connection; re-probe with curl"
if systemctl is-active --quiet jellyfin-discovery.service; then
    pass "jellyfin-discovery.service active"
else
    fail "jellyfin-discovery.service not active"
fi

# --------------------------------------------------------------- 5. guardrail
sub "5. offline guardrail (working + installed)"
GR_TMP="$(mktemp "${TMPDIR:-/tmp}/fix50-gr.XXXXXX")"
trap 'rm -f "$GR_TMP"' EXIT
if [ -f "$SRC_DIR/phase5_guardrail_test.sh" ]; then
    bash "$SRC_DIR/phase5_guardrail_test.sh" >"$GR_TMP" 2>&1
    GRC=$?
    GRV="$(grep -oE 'VERIFY_FAILS=[0-9]+' "$GR_TMP" | tail -n1)"
    GRP="$(grep -c '\[PASS\]' "$GR_TMP" || true)"
    if [ "$GRC" -eq 0 ] && [ "$GRV" = "VERIFY_FAILS=0" ]; then
        pass "working copy: $GRP PASS, $GRV, rc=0"
    else
        fail "working copy guardrail: rc=$GRC ${GRV:-<no summary>}"
        grep '\[FAIL\]' "$GR_TMP" | grep -v 'guardrail test FAILED' | sed 's/^/           /'
    fi
else
    fail "working-copy guardrail missing: $SRC_DIR/phase5_guardrail_test.sh"
fi
if [ -f "$DEST_DIR/phase5_guardrail_test.sh" ]; then
    bash "$DEST_DIR/phase5_guardrail_test.sh" >"$GR_TMP" 2>&1
    GRC=$?
    GRV="$(grep -oE 'VERIFY_FAILS=[0-9]+' "$GR_TMP" | tail -n1)"
    GRP="$(grep -c '\[PASS\]' "$GR_TMP" || true)"
    GRN="$(grep -c '\[note\]' "$GR_TMP" || true)"
    if [ "$GRC" -eq 0 ] && [ "$GRV" = "VERIFY_FAILS=0" ]; then
        pass "installed copy: $GRP PASS, $GRN note(s), $GRV, rc=0"
    else
        fail "installed-copy guardrail: rc=$GRC ${GRV:-<no summary>}"
        grep '\[FAIL\]' "$GR_TMP" | grep -v 'guardrail test FAILED' | sed 's/^/           /'
    fi
else
    fail "installed guardrail missing: $DEST_DIR/phase5_guardrail_test.sh"
fi

# ------------------------------------------------------- 6. trees are mirrored
sub "6. working copy == installed copy"
for f in phase5_apply.sh phase5_compose.yaml phase5_guardrail_test.sh phase5_diag.sh; do
    if [ ! -f "$SRC_DIR/$f" ]; then
        fail "working copy missing: $f"
    elif [ ! -f "$DEST_DIR/$f" ]; then
        fail "installed copy missing: $f"
    elif cmp -s "$SRC_DIR/$f" "$DEST_DIR/$f"; then
        pass "$f identical ($(stat -c %s "$SRC_DIR/$f") bytes)"
    else
        fail "$f differs — run phase5_step1_install.sh"
    fi
done

# ------------------------------------------------------------- 7. bash -n gates
sub "7. bash -n on every copy"
for f in phase5_apply.sh phase5_guardrail_test.sh phase5_diag.sh; do
    for tree in "$SRC_DIR" "$DEST_DIR"; do
        [ -f "$tree/$f" ] || continue
        if bash -n "$tree/$f" 2>/dev/null; then
            pass "bash -n: ${tree}/$f"
        else
            fail "bash -n failed: ${tree}/$f"
        fi
    done
done

# ------------------------------------------------------- 8. boot evidence
# fix 50 proof: the current boot must show ONE automatic bind, no ordering
# cycle, no pre-DHCP EADDRNOTAVAIL, and no manual restart of the socket.
sub "8. boot evidence (current boot)"
BOOT_S="$(uptime -s 2>/dev/null || true)"
BOOT_EPOCH=0
[ -n "$BOOT_S" ] && BOOT_EPOCH="$(date -d "$BOOT_S" +%s 2>/dev/null || echo 0)"
JOUT=""
if JOUT="$(journalctl -b -u jellyfin-lan-proxy.socket --no-pager 2>/dev/null)" && [ -n "$JOUT" ]; then
    if printf '%s\n' "$JOUT" | grep -qiE 'ordering cycle|deleted to break|Cannot assign requested address|Failed with result'; then
        fail "socket journal shows a boot ordering/bind failure this boot"
        printf '%s\n' "$JOUT" | grep -iE 'ordering cycle|deleted to break|Cannot assign requested address|Failed with result' \
            | head -5 | sed 's/^/           /'
    else
        pass "no ordering cycle and no bind failure in this boot's socket journal"
    fi
    BINDS="$(printf '%s\n' "$JOUT" | grep -c 'Listening on jellyfin-lan-proxy.socket' || true)"
    if [ "${BINDS:-0}" -eq 1 ]; then
        pass "socket bound exactly once this boot (no manual restart)"
    else
        fail "socket has ${BINDS:-0} 'Listening on' entries this boot (want 1 — restart or duplicate bind)"
    fi
    if [ "$BOOT_EPOCH" -gt 0 ]; then
        ACT_EPOCH="$(date -d "$(systemctl show jellyfin-lan-proxy.socket -p ActiveEnterTimestamp --value 2>/dev/null)" +%s 2>/dev/null || echo 0)"
        if [ "$ACT_EPOCH" -gt 0 ]; then
            DELTA=$((ACT_EPOCH - BOOT_EPOCH))
            if [ "$DELTA" -ge 0 ] && [ "$DELTA" -le 120 ]; then
                pass "socket active ${DELTA}s after boot (automatic, boot: $BOOT_S)"
            else
                fail "socket active ${DELTA}s after boot (want 0–120s — not a boot-time start?)"
            fi
        else
            note "could not parse ActiveEnterTimestamp — skipped boot-delta check"
        fi
    else
        note "could not read boot time from uptime -s — skipped boot-delta check"
    fi
else
    note "journal for this boot not readable — boot evidence not checked (run as root)"
fi
systemctl is-enabled --quiet jellyfin-lan-proxy.socket 2>/dev/null \
    && pass "jellyfin-lan-proxy.socket enabled (starts on every boot)" \
    || fail "jellyfin-lan-proxy.socket not enabled — it will not start on boot"

echo
echo "=============================================================="
echo "=== fix 50 acceptance complete ==="
echo "=== VERIFY_FAILS=$FAILS ==="
echo "=============================================================="
if [ "$FAILS" -gt 0 ]; then
    echo "Acceptance FAILED — review the [FAIL] lines above." >&2
    exit 1
fi
echo "Section 8 is the reboot proof: one automatic boot-time bind, no"
echo "ordering cycle, no manual restart. Re-run after every reboot."
exit 0

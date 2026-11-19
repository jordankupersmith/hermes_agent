#!/usr/bin/env bash
#
# Phase 3 — LiteLLM Proxy Setup, YAML Config & Guardrail Tests
# Host: clawbox (Ubuntu 26.04)   Architecture: Option A
#
# ROOT-ONLY, IDEMPOTENT, ADDITIVE.  Run with:
#
#   sudo bash /home/jordan/Documents/SystemBuild/phase3_apply.sh
#
# All apply + verification output is tee'd to
# /home/jordan/Documents/SystemBuild/phase3.out (best-effort chowned to
# jordan:jordan 644 at the very end so the agent can always read it).
#
# This script:
#   * installs LiteLLM into a PEP 668-safe venv at /opt/litellm/venv owned by
#     the 'litellm' service user. The network install is GATED: if the host is
#     offline (or python3-venv is missing) it reports clearly and continues
#     instead of hard-failing — re-run once fixed, everything else still works;
#   * installs phase3_config.yaml to /etc/litellm/config.yaml (640
#     root:litellm — the config contains NO secrets, only os.environ/ refs);
#   * writes /etc/systemd/system/litellm.service (hardened, User=litellm,
#     pinned to 127.0.0.1:4000) and runs `systemctl daemon-reload`;
#   * does NOT start/enable litellm while /etc/litellm/litellm.env is still
#     the comment-only skeleton (the proxy would fail auth). When real
#     LITELLM_MASTER_KEY / ZEN_API_KEY values ARE present, it enables --now
#     (and, if the unit is already active, restarts it so config/env
#     changes take effect on re-run — enable --now alone is a no-op there).
#
# This script does NOT: touch sshd/ssh.socket/UFW/LVM, format or mount the
# 90G media LV, modify /home/hermes or any other phase's state, run apt, add
# sudo/NOPASSWD rules, or overwrite /etc/litellm/litellm.env (it only
# re-asserts that file's ownership/mode — 600 litellm:litellm). .env contents
# are NEVER echoed to the log, so no secret can leak into the log file.

set -euo pipefail

LOG=/home/jordan/Documents/SystemBuild/phase3.out
SRC=/home/jordan/Documents/SystemBuild/phase3_config.yaml   # ABSOLUTE source path
CONF=/etc/litellm/config.yaml
ENVF=/etc/litellm/litellm.env
VENV=/opt/litellm/venv
UNIT=/etc/systemd/system/litellm.service

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Phase 3 must be run as root (e.g. 'sudo bash $0')." >&2
    exit 1
fi

exec > >(tee "$LOG") 2>&1

HOST="$(hostname)"
STAMP="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

section() { echo; echo "=============================================================="; echo " $*"; echo "=============================================================="; }
sub()    { echo; echo "----- $* -----"; }

FAILS=0
pass() { echo "  [PASS] $*"; }
fail() { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
note() { echo "  [note] $*"; }

# LITELLM_INSTALLED: 1 = venv + litellm binary present after APPLY 1.
LITELLM_INSTALLED=0

# cfg_body: config.yaml with comments stripped — safe for structural greps.
cfg_body() { sed 's/[[:space:]]*#.*$//' "$CONF" 2>/dev/null; }

# ======================================================================
section "Phase 3 — LiteLLM Proxy Setup (YAML config + systemd unit)"
echo " host   : $HOST"
echo " utc    : $STAMP"
echo " euid   : $(id -u) ($(id -un))"
echo " log    : $LOG"
echo
echo " SAFETY WARNING — read before continuing:"
echo "   * ADDITIVE + IDEMPOTENT. Installs LiteLLM into /opt/litellm/venv"
echo "     (owned by the 'litellm' user, PEP 668-safe), installs"
echo "     phase3_config.yaml to /etc/litellm/config.yaml (640 root:litellm),"
echo "     writes /etc/systemd/system/litellm.service + daemon-reload."
echo "   * NEVER overwrites /etc/litellm/litellm.env — only re-asserts"
echo "     600 litellm:litellm on it. No .env contents are ever echoed."
echo "   * Does NOT start the service while litellm.env is still the"
echo "     comment-only skeleton (it would fail auth); prints go-live"
echo "     instructions instead. Enables --now only if real keys exist"
echo "     (restarts instead if the unit is already active)."
echo "   * Does NOT touch SSH / sshd / ssh.socket / UFW / LVM, does NOT"
echo "     format or mount the 90G media LV, and runs NO apt commands."
echo "   * Network install is gated: offline hosts get a clear WARN, not"
echo "     a hard failure."
echo "=============================================================="

# ----------------------------------------------------------------------
sub "APPLY 1/4 — install LiteLLM (PEP 668-safe venv at $VENV)"
# Ubuntu 26.04 python3 is externally managed (PEP 668) -> a dedicated venv
# owned by the service user is the safe install path (no --break-system-packages).
if [ -x "$VENV/bin/litellm" ]; then
    echo "  [ok]      LiteLLM already installed: $VENV/bin/litellm"
    LITELLM_INSTALLED=1
else
    echo "  [install] creating venv: python3 -m venv $VENV (needs python3-venv)"
    if python3 -m venv "$VENV"; then
        chown -R litellm:litellm "$VENV"
        chmod 750 "$VENV"
        echo "  [created] venv $VENV (litellm:litellm, 750 top dir)"
        echo "  [install] pip install 'litellm[proxy]' as litellm (network required)"
        if runuser -u litellm -- "$VENV/bin/pip" install --no-cache-dir --quiet 'litellm[proxy]'; then
            chown -R litellm:litellm "$VENV"
            echo "  [done]    $(runuser -u litellm -- "$VENV/bin/litellm" --version 2>/dev/null || echo 'litellm[proxy]') installed"
            LITELLM_INSTALLED=1
        else
            echo "  *** WARN: pip install FAILED (host offline / PyPI unreachable?)."
            echo "  ***       LiteLLM is NOT installed; nothing else was harmed."
            echo "  ***       Fix: restore network access, then re-run this script"
            echo "  ***       (idempotent). Venv left in place at $VENV."
        fi
    else
        echo "  *** WARN: 'python3 -m venv' FAILED (python3-venv package missing?)."
        echo "  ***       Fix (as root): apt-get install -y python3-venv"
        echo "  ***       then re-run this script (idempotent)."
        echo "  ***       The partial venv dir was left at $VENV for the retry."
    fi
fi

# ----------------------------------------------------------------------
sub "APPLY 2/4 — install config.yaml + protect litellm.env"
if [ ! -f "$SRC" ]; then
    echo "  FATAL: source config $SRC missing — cannot continue." >&2
    exit 1
fi
install -m 640 -o root -g litellm "$SRC" "$CONF"
echo "  [ok]      $CONF installed (640 root:litellm) from $SRC (verbatim)"

# Re-assert the Phase 2 directory permissions (idempotent).
chown root:litellm /etc/litellm
chmod 750 /etc/litellm
chown litellm:litellm /opt/litellm
chmod 750 /opt/litellm
echo "  [ok]      /etc/litellm 750 root:litellm + /opt/litellm 750 litellm:litellm re-asserted"

# NEVER overwrite litellm.env — only re-assert ownership/mode if present.
if [ -f "$ENVF" ]; then
    chown litellm:litellm "$ENVF"
    chmod 600 "$ENVF"
    echo "  [ok]      $ENVF preserved (NOT overwritten) -> 600 litellm:litellm"
else
    echo "  *** WARN: $ENVF missing (Phase 2 should have created it) — NOT created here."
fi

# ----------------------------------------------------------------------
sub "APPLY 3/4 — write $UNIT + daemon-reload"
cat >"$UNIT" <<'UNITEOF'
[Unit]
Description=LiteLLM LLM proxy (localhost-only; OpenCode Go upstream)
Documentation=https://docs.litellm.ai/docs/proxy/configs
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=litellm
Group=litellm
EnvironmentFile=/etc/litellm/litellm.env
WorkingDirectory=/opt/litellm
# BIND pinned here: 127.0.0.1:4000 (never 0.0.0.0 — local clients only).
ExecStart=/opt/litellm/venv/bin/litellm --config /etc/litellm/config.yaml --host 127.0.0.1 --port 4000
Restart=on-failure
RestartSec=5
# Writable state dir (auto-created by systemd, owned litellm:litellm) so the
# service never needs a home under /nonexistent; strict ProtectSystem below.
StateDirectory=litellm
Environment=HOME=/var/lib/litellm
# --- hardening ---
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
ProtectClock=true
ProtectHostname=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
RestrictNamespaces=true
RestrictRealtime=true
LockPersonality=true
CapabilityBoundingSet=
AmbientCapabilities=
UMask=0027
ReadOnlyPaths=/etc/litellm

[Install]
WantedBy=multi-user.target
UNITEOF
chown root:root "$UNIT"
chmod 644 "$UNIT"
systemctl daemon-reload
echo "  [ok]      $UNIT written (644 root:root) + systemctl daemon-reload done"

# ----------------------------------------------------------------------
sub "APPLY 4/4 — enable/start litellm.service ONLY if real secrets are present"
# Detect whether litellm.env still is the comment-only skeleton.
# (Anchored, non-comment greps; values are NEVER echoed.)
SECRET_READY=0
if [ -f "$ENVF" ]; then
    if grep -qE '^[[:space:]]*LITELLM_MASTER_KEY=[^[:space:]#]+' "$ENVF" \
       && grep -qE '^[[:space:]]*ZEN_API_KEY=[^[:space:]#]+' "$ENVF"; then
        SECRET_READY=1
    fi
fi
if [ "$SECRET_READY" -eq 1 ]; then
    echo "  [ok]      real LITELLM_MASTER_KEY + ZEN_API_KEY detected (values NOT echoed)"
    if [ "$LITELLM_INSTALLED" -eq 1 ]; then
        if systemctl is-active --quiet litellm; then
            # enable --now is a NO-OP on an already-active unit: restart so
            # config.yaml / litellm.env changes take effect on re-run.
            systemctl restart litellm
            echo "  [ok]      litellm already active -> systemctl restart litellm (config/env changes applied)"
        else
            systemctl enable --now litellm
            echo "  [ok]      systemctl enable --now litellm"
        fi
        sleep 3
        if systemctl is-active --quiet litellm; then
            echo "  [ok]      litellm.service is active"
        else
            echo "  *** WARN: litellm.service NOT active. Last 20 journal lines:" >&2
            journalctl -u litellm -n 20 --no-pager >&2 || true
        fi
    else
        echo "  *** WARN: secrets present but LiteLLM venv is NOT installed — NOT starting."
        echo "  ***       Restore network access, re-run this script, then:"
        echo "  ***         systemctl enable --now litellm"
    fi
else
    echo "  [skeleton] $ENVF is still the comment-only skeleton (or missing)."
    echo "             NOT enabling/starting litellm — it would fail auth."
    echo "             To go live:"
    echo "               1. As root, add REAL values to $ENVF :"
    echo "                    LITELLM_MASTER_KEY=sk-\$(openssl rand -hex 32)"
    echo "                    ZEN_API_KEY=<your OpenCode Go API key>"
    echo "                  (sk- prefix keeps every LiteLLM version happy)"
    echo "               2. sudo systemctl enable --now litellm"
    echo "               3. Re-run this script to re-verify (idempotent)."
fi

# ======================================================================
section "VERIFICATION (echoed — this is what lands in the log file)"

sub "V1 — $CONF exists and is valid YAML"
if [ -f "$CONF" ]; then
    pass "$CONF exists"
else
    fail "$CONF MISSING"
fi
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
    if python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$CONF" 2>/dev/null; then
        pass "valid YAML (python3+PyYAML safe_load)"
    else
        fail "python3+PyYAML could NOT parse $CONF"
    fi
else
    # Structural fallback (PyYAML unavailable)
    if grep -q '^model_list:' "$CONF" \
       && grep -q '^router_settings:' "$CONF" \
       && grep -q '^general_settings:' "$CONF" \
       && [ "$(grep -cE '^[[:space:]]*- model_name: ' "$CONF")" -eq 3 ]; then
        pass "structural sanity OK (PyYAML unavailable: top-level keys + 3 model entries present)"
    else
        fail "structural sanity FAILED (and PyYAML unavailable)"
    fi
fi

sub "V2 — model_list has EXACTLY the 3 allowed models (no gpt-/claude-/gemini-)"
# NOTE: the checker sorts model_name entries alphabetically, so WANT must be
# the alphabetical (not config-order) form: beam-free < glm-5.3-flash < kimi-k2.7-code.
NAMES="$(cfg_body | grep -E '^[[:space:]]*- model_name: ' | sed -E 's/.*model_name:[[:space:]]*//' | sort | paste -sd' ' -)"
WANT="beam-free glm-5.3-flash kimi-k2.7-code"
echo "  model_name entries (sorted): ${NAMES:-<none>}"
echo "  expected              (sorted): $WANT"
if [ "$NAMES" = "$WANT" ]; then
    pass "exactly the 3 allowed models: glm-5.3-flash, kimi-k2.7-code, beam-free"
else
    fail "model set mismatch (want: '$WANT')"
fi
BADNAMES="$(printf '%s\n' "$NAMES" | grep -Ei '(^| )(gpt|claude|gemini)-' || true)"
BADBODY="$(cfg_body | grep -Ei '(gpt|claude|gemini)-' || true)"
if [ -n "$BADNAMES$BADBODY" ]; then
    fail "gpt-*/claude-*/gemini-* referenced in config body"
else
    pass "no gpt-*/claude-*/gemini-* anywhere in the config (non-comment)"
fi

sub "V3 — fallback chain order glm-5.3-flash -> kimi-k2.7-code -> beam-free"
NOCF="$(tr -d '[:space:]' <"$CONF")"
if printf '%s' "$NOCF" | grep -Fq '"glm-5.3-flash":["kimi-k2.7-code","beam-free"]' \
   && printf '%s' "$NOCF" | grep -Fq '"kimi-k2.7-code":["beam-free"]'; then
    pass "router_settings.fallbacks: glm-5.3-flash -> [kimi-k2.7-code, beam-free]; kimi-k2.7-code -> [beam-free]"
else
    fail "fallback chain not found / wrong order in router_settings.fallbacks"
fi

sub "V4 — upstream api_base + ZEN_API_KEY env reference (all 3 deployments)"
NB="$(cfg_body | grep -c 'api_base: https://opencode.ai/zen/go/v1' || true)"
NBT="$(cfg_body | grep -cE '^[[:space:]]*api_base:' || true)"
NK="$(cfg_body | grep -c 'api_key: os.environ/ZEN_API_KEY' || true)"
NKT="$(cfg_body | grep -cE '^[[:space:]]*api_key:' || true)"
echo "  api_base: $NB exact / $NBT total    api_key: $NK exact / $NKT total (want 3/3 each)"
if [ "$NB" -eq 3 ] && [ "$NBT" -eq 3 ] && [ "$NK" -eq 3 ] && [ "$NKT" -eq 3 ]; then
    pass "all 3 deployments -> https://opencode.ai/zen/go/v1 with os.environ/ZEN_API_KEY"
else
    fail "api_base/api_key mismatch (exact/total: $NB/$NBT, $NK/$NKT)"
fi

sub "V5 — required upstream headers User-Agent + X-Title + x-opencode-session"
NH="$(cfg_body | grep -c 'extra_headers:' || true)"
NUA="$(cfg_body | grep -c 'User-Agent:' || true)"
NXT="$(cfg_body | grep -c 'X-Title:' || true)"
NSX="$(cfg_body | grep -c 'x-opencode-session:' || true)"
echo "  extra_headers: $NH, User-Agent: $NUA, X-Title: $NXT, x-opencode-session: $NSX (want 3 each)"
if [ "$NH" -eq 3 ] && [ "$NUA" -eq 3 ] && [ "$NXT" -eq 3 ] && [ "$NSX" -eq 3 ]; then
    pass "every deployment sends extra_headers User-Agent + X-Title + x-opencode-session upstream"
else
    fail "extra_headers/User-Agent/X-Title/x-opencode-session count mismatch ($NH/$NUA/$NXT/$NSX)"
fi

sub "V6 — master_key refs LITELLM_MASTER_KEY + bind 127.0.0.1:4000"
if cfg_body | grep -q 'master_key: os.environ/LITELLM_MASTER_KEY'; then
    pass "general_settings.master_key = os.environ/LITELLM_MASTER_KEY"
else
    fail "master_key does not reference os.environ/LITELLM_MASTER_KEY"
fi
if grep -Fq -- '--host 127.0.0.1 --port 4000' "$UNIT"; then
    pass "bind pinned to 127.0.0.1:4000 (systemd ExecStart flags)"
else
    fail "unit does not pin --host 127.0.0.1 --port 4000"
fi

sub "V7 — systemd unit valid + runs as litellm"
for want in 'User=litellm' 'Group=litellm' 'EnvironmentFile=/etc/litellm/litellm.env' \
            'ExecStart=/opt/litellm/venv/bin/litellm --config /etc/litellm/config.yaml --host 127.0.0.1 --port 4000' \
            'Restart=on-failure' 'NoNewPrivileges=true' 'ProtectSystem=strict' \
            'PrivateTmp=true' 'ReadOnlyPaths=/etc/litellm'; do
    if grep -Fq "$want" "$UNIT"; then
        pass "unit has $want"
    else
        fail "unit missing $want"
    fi
done
if command -v systemd-analyze >/dev/null 2>&1; then
    if VA_OUT="$(systemd-analyze verify "$UNIT" 2>&1)"; then
        pass "systemd-analyze verify: clean"
    elif [ "$LITELLM_INSTALLED" -ne 1 ] && printf '%s' "$VA_OUT" | grep -q 'venv/bin/litellm'; then
        note "systemd-analyze verify failed ONLY because the LiteLLM venv is not"
        note "installed (network-gated above). Re-run after install to re-verify."
    else
        fail "systemd-analyze verify rc!=0: $VA_OUT"
    fi
else
    note "systemd-analyze unavailable — structural checks only"
fi

sub "V8 — ownership/modes; $ENVF preserved"
check_mode() {
    local f="$1" wm="$2" wo="$3" m o
    m="$(stat -c '%a' "$f" 2>/dev/null || echo MISSING)"
    o="$(stat -c '%U:%G' "$f" 2>/dev/null || echo MISSING)"
    echo "  $f -> mode=$m owner=$o  (want $wm $wo)"
    if [ "$m" = "$wm" ] && [ "$o" = "$wo" ]; then
        pass "$f is $wm $wo"
    else
        fail "$f is NOT $wm $wo"
    fi
}
check_mode /etc/litellm                 750 root:litellm
check_mode /opt/litellm                 750 litellm:litellm
check_mode "$CONF"                      640 root:litellm
check_mode "$ENVF"                      600 litellm:litellm
check_mode "$UNIT"                      644 root:root
if [ "$LITELLM_INSTALLED" -eq 1 ]; then
    check_mode "$VENV"                  750 litellm:litellm
    if [ -x "$VENV/bin/litellm" ]; then
        pass "LiteLLM binary present + executable ($VENV/bin/litellm)"
    else
        fail "$VENV/bin/litellm not executable"
    fi
else
    note "LiteLLM venv not installed (network-gated) — venv checks skipped"
fi
# litellm.env must still be the untouched skeleton unless the user edited it.
# Never print real values — only echo if still comment-only (like Phase 2).
if grep -qvE '^[[:space:]]*(#|$)' "$ENVF" 2>/dev/null; then
    echo "  $ENVF contains real (non-comment) values -> contents NOT echoed (protected)"
else
    echo "  $ENVF still comment-only skeleton (preserved, NOT overwritten):"
    sed 's/^/    | /' "$ENVF" 2>/dev/null || echo "    (unreadable)"
fi

sub "V9 — SSH / UFW / LVM / 90G media LV untouched (read-only sanity)"
echo "  (this script issued NO sshd/UFW/LVM/mount commands; it only wrote"
echo "   /etc/litellm/config.yaml, $UNIT and the LiteLLM venv)"
if findmnt -rn -S /dev/ubuntu-vg/media >/dev/null 2>&1; then
    fail "media LV is MOUNTED on host (should stay unmounted for passthrough)"
else
    pass "media LV is NOT mounted on host"
fi
echo "  lsblk (FSTYPE should be blank => unformatted):"
lsblk -no NAME,FSTYPE,UUID,MOUNTPOINT /dev/ubuntu-vg/media 2>/dev/null | sed 's/^/    /' || echo "    (lsblk unavailable)"
fst="$(lsblk -no FSTYPE /dev/ubuntu-vg/media 2>/dev/null || true)"
if [ -z "$fst" ]; then
    pass "media LV has no filesystem (unformatted)"
else
    fail "media LV has FSTYPE=$fst"
fi
if command -v ufw >/dev/null 2>&1; then
    ufws="$(ufw status 2>/dev/null | head -n1 || true)"
    echo "  ufw: $ufws"
    case "$ufws" in
        *active*) pass "UFW still active (untouched)" ;;
        *)        fail "UFW not active: $ufws" ;;
    esac
else
    note "ufw unavailable — skipped"
fi
if command -v ss >/dev/null 2>&1; then
    ssh_bad=0
    ssh_seen=""
    while read -r l; do
        [ -n "$l" ] || continue
        ssh_seen="$ssh_seen $l"
        case "$l" in
            192.168.1.133:22|127.0.0.1:22) ;;
            *) ssh_bad=1 ;;
        esac
    done < <(ss -tlnH 'sport = :22' 2>/dev/null | awk '{print $4}')
    echo "  ssh listeners (:22):${ssh_seen:- <none found>}"
    if [ -z "$ssh_seen" ]; then
        fail "no :22 listeners found — ssh.socket down?"
    elif [ "$ssh_bad" -eq 0 ]; then
        pass "SSH listeners unchanged (192.168.1.133:22 + 127.0.0.1:22 only)"
    else
        fail "unexpected :22 listener(s) present (wildcard/IPv6?)"
    fi
else
    note "ss unavailable — SSH listener check skipped"
fi

sub "V10 — $ENVF line-shape sanity (systemd-safe VAR=value)"
# systemd's EnvironmentFile keeps EVERYTHING after '=' in the VALUE (a
# trailing ' # comment' becomes part of the secret!), while bash 'source'
# strips it — that divergence poisoned the values once already (live debug
# 2026-11-07: service key md5 != bash md5, len 115/107). FAIL on any
# non-comment line whose value systemd would mis-read. Masked output only:
# line number, var name, flag — NEVER the value itself.
if [ -f "$ENVF" ]; then
    env_bad=0
    ln_no=0
    while IFS= read -r line || [ -n "$line" ]; do
        ln_no=$((ln_no + 1))
        # Skip blank / pure-comment lines (skeleton comments are fine).
        if [ -z "${line//[[:space:]]/}" ] || [[ "$line" =~ ^[[:space:]]*# ]]; then
            continue
        fi
        # Trim line-leading whitespace (both parsers accept it) for analysis.
        tline="${line#"${line%%[![:space:]]*}"}"
        var="${tline%%=*}"
        if [[ "$tline" != *=* ]] || [[ ! "$var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            fail "line $ln_no: not a clean VAR=value line (malformed) — review manually"
            env_bad=1
            continue
        fi
        value="${tline#*=}"
        vflags=""
        if [ -z "$value" ]; then
            vflags="[EMPTY]"
        else
            if [[ "$value" =~ [[:space:]]+# ]]; then vflags="$vflags [CONTAINS-HASH]"; fi
            if [[ "$value" =~ ^[[:space:]] ]];     then vflags="$vflags [LEADING-SPACE]"; fi
            if [[ "$value" =~ [[:space:]]$ ]];     then vflags="$vflags [TRAILING-SPACE]"; fi
        fi
        if [ -n "$vflags" ]; then
            fail "line $ln_no: $var len=${#value} — systemd would mis-read the value:$vflags (value NOT echoed)"
            env_bad=1
        fi
    done <"$ENVF"
    if [ "$env_bad" -eq 0 ]; then
        pass "all non-comment lines are clean VAR=value (no ' #', no edge whitespace, none empty)"
    else
        note "repair with: sudo bash /home/jordan/Documents/SystemBuild/phase3_env_fix.sh"
    fi
else
    note "$ENVF missing — V10 skipped (Phase 2 should have created it)"
fi

# ----------------------------------------------------------------------
# Best-effort: guarantee the conventional log path is readable by the agent
# (jordan), no matter which uid/umask wrote it.
if [ -f "$LOG" ]; then
    chown jordan:jordan "$LOG" 2>/dev/null || true
    chmod 644 "$LOG" 2>/dev/null || true
fi

echo
echo "=============================================================="
echo "=== Phase 3 apply complete ==="
echo "=== VERIFY_FAILS=$FAILS ==="
echo "=============================================================="
if [ "$FAILS" -gt 0 ]; then
    echo "Phase 3 finished with $FAILS verification failure(s) — review $LOG" >&2
    exit 1
fi
exit 0

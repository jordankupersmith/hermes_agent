#!/usr/bin/env bash
#
# Phase 4 — Nous Hermes Agent: pinned install, config, secrets & systemd units
# Host: clawbox (Ubuntu 26.04)   Architecture: Option A
#
# ROOT-ONLY, IDEMPOTENT, ADDITIVE.  Run with:
#
#   sudo bash /home/jordan/Documents/SystemBuild/phase4_apply.sh
#
# All apply + verification output is tee'd to
# /home/jordan/Documents/SystemBuild/phase4.out (best-effort chowned to
# jordan:jordan 644 at the very end so the agent can always read it).
#
# This script:
#   * clones Nous Hermes Agent at the PINNED release tag v0.23.0 into
#     /opt/hermes/src (git clone — the install path of record; NOT
#     `curl | bash`) and fail-closes if HEAD is not the pinned commit SHA.
#     Install applied via pinned uv==0.13.7 sync --locked (see uv note below).
#' * creates a Python 3.14 venv at /opt/hermes/venv (owned by the 'hermes'
#     service user, PEP 668-safe) and installs the checkout with the [ddgs]
#     extra (ddgs==9.16.0; web-search backend) via the project's OFFICIAL
#     installer: uv sync --locked (pinned uv==0.13.7; pip CANNOT resolve this
#     tree — see the Pillow override description below). The network install
#     is GATED: offline hosts get a clear WARN and re-running is safe;
#   * installs phase4_config.yaml to /var/lib/hermes/config.yaml (600
#     hermes:hermes — the config contains NO secret literals, only ${ENV}
#     refs). HERMES_HOME=/var/lib/hermes is pinned in both units: the repo
#     has no runtime config-path override (config lives at
#     $HERMES_HOME/config.yaml);
#   * fills MISSING real secrets into /etc/hermes/hermes.env —
#     LITELLM_API_KEY  (verbatim copy of LITELLM_MASTER_KEY from
#                      /etc/litellm/litellm.env)
#     API_SERVER_KEY   (openssl rand -hex 32, api-server auth; >=16 chars)
#     NEVER overwrites existing keys, NEVER echoes values to the log;
#   * writes TWO hardened systemd units and runs `systemctl daemon-reload`:
#       hermes-serve.service — `hermes serve` headless backend, pinned to
#                              127.0.0.1:9119 (JSON-RPC/WS per-user sessions;
#                              browser UI deliberately NOT deployed — see
#                              phase4_config.yaml header notes);
#       hermes-api.service  — `hermes gateway run` whose only platform is the
#                              api_server adapter, pinned to 127.0.0.1:8642
#                              via API_SERVER_HOST/API_SERVER_PORT env.
#   * enables --now BOTH units ONLY when LITELLM_API_KEY + API_SERVER_KEY are
#     present in hermes.env (restarts instead of enable on re-run while
#     active). Never enables on the comment-only skeleton.
#
# This script does NOT: run apt, add sudo/NOPASSWD rules, touch sshd/UFW/LVM
# or the media LV, modify Phase 3 files (read-only sanity checks only), or
# overwrite /etc/hermes/hermes.env (it only appends missing keys and
# re-asserts 600 hermes:hermes). No secret value is ever echoed or logged.

set -euo pipefail

LOG=/home/jordan/Documents/SystemBuild/phase4.out
CONF_SRC=/home/jordan/Documents/SystemBuild/phase4_config.yaml   # ABSOLUTE source path
HERMES_HOME=/var/lib/hermes
CONF=/var/lib/hermes/config.yaml
ENVF=/etc/hermes/hermes.env
LITELLM_ENV=/etc/litellm/litellm.env
VENV=/opt/hermes/venv
SRC=/opt/hermes/src

# --- Supply-chain pin (audited offline; see PROJECT_MEMORY.md Phase 4) ------
PIN_TAG=v0.23.0
PIN_COMMIT=2bd378ed1b8d6bf2192cb26e0a55ff3091e6bd19
# Release manifest SHA256 embedded in the (unsigned) tag object message by
# the release automation; the integrity reference of record for this pin.
PIN_MANIFEST=456e66358123b34c77759f453658fd5d5fa1fb07a26c7969ba7707840a9296b4
# uv installer pin. REQUIRED for the install: this tag's [tool.uv]
# override-dependencies (documented upstream for GHSA-8g5g-8vmr-9782 et al.)
# replace browser-harness's stale pillow==12.3.0 pin with the direct
# Pillow==13.0.0 — pip's resolver has no equivalent and fails with
# ResolutionImpossible ("Cannot install None, hermes-agent ..."). uv sync
# --locked installs EVERYTHING from the tag's uv.lock (hash-recorded).
UV_PIN=0.13.7

SERVE_UNIT=/etc/systemd/system/hermes-serve.service
API_UNIT=/etc/systemd/system/hermes-api.service

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Phase 4 must be run as root (e.g. 'sudo bash $0')." >&2
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

# HERMES_INSTALLED: 1 = venv + hermes entry point present after APPLY 2.
HERMES_INSTALLED=0

# cfg_body: installed config.yaml with comments stripped — safe for greps.
cfg_body() { sed 's/[[:space:]]*#.*$//' "$CONF" 2>/dev/null; }

# gitr: run git as the repository owner when we are root. After the post-clone
# chown, /opt/hermes/src belongs to 'hermes', and root reading a foreign-owned
# repo trips git's "dubious ownership" refusal. Running the read-only git
# calls as 'hermes' avoids that without adding safe.directory trust.
gitr() {
    if [ "$(id -u)" -eq 0 ] && [ "$(stat -c '%U' "$SRC/.git" 2>/dev/null || true)" = hermes ]; then
        runuser -u hermes -- env HOME=/home/hermes git "$@"
    else
        git "$@"
    fi
}

# get_var FILE KEY -> value of KEY (last one wins; comments skipped).
# NEVER echoes the value — used only in shell variables. No eval/sourcing.
get_var() {
    awk -F= -v k="$2" '
        $0 !~ /^[[:space:]]*#/ && $1 ~ "^[[:space:]]*" k "[[:space:]]*$" {
            sub(/^[^=]*=/, ""); print
        }' "$1" 2>/dev/null | tail -n 1
}

# add_secret KEY VALUE — append KEY=VALUE to hermes.env if KEY has no real
# value yet. The value exists only in shell memory / the 600 env file.
add_secret() {
    local key="$1" value="$2"
    if [ -z "$value" ]; then
        echo "  [skip]    $key: no value available — NOT written"
        return 1
    fi
    if grep -qE "^${key}=[^[:space:]]" "$ENVF" 2>/dev/null; then
        echo "  [keep]    $key already has a real value (NOT overwritten)"
        return 0
    fi
    if [ ! -s "$ENVF" ] || [ "$(tail -c 1 "$ENVF" | od -An -c | tr -d ' \n')" != "\n" ]; then
        printf '\n' >>"$ENVF"
    fi
    printf '%s=%s\n' "$key" "$value" >>"$ENVF"
    chown hermes:hermes "$ENVF"; chmod 600 "$ENVF"
    echo "  [added]   $key written to $ENVF (value NEVER echoed)"
}

# ======================================================================
section "Phase 4 — Nous Hermes Agent (pinned $PIN_TAG) — install, config, units"
echo " host   : $HOST"
echo " utc    : $STAMP"
echo " euid   : $(id -u) ($(id -un))"
echo " log    : $LOG"
echo
echo " SAFETY WARNING — read before continuing:"
echo "   * ADDITIVE + IDEMPOTENT. Clones hermes-agent at tag $PIN_TAG"
echo "     into /opt/hermes/src (fail-closed on commit mismatch), builds"
echo "     /opt/hermes/venv for the 'hermes' user, installs"
echo "     phase4_config.yaml to /var/lib/hermes/config.yaml (600"
echo "     hermes:hermes), writes two hardened systemd units + daemon-reload."
echo "   * NEVER overwrites /etc/hermes/hermes.env — only APPENDS missing"
echo "     keys (LITELLM_API_KEY, API_SERVER_KEY). Values are never echoed."
echo "   * Enables --now only when BOTH real secrets exist in hermes.env."
echo "   * Does NOT run apt, does NOT touch SSH / UFW / LVM / media LV, and"
echo "     only READS Phase 3 state (litellm config/unit) for sanity checks."
echo "   * Network operations (git clone, pip) are gated: offline hosts get"
echo "     a clear WARN and the rest of the apply still completes."
echo "   * Serving surfaces (audit decision): 127.0.0.1:8642 (api_server,"
echo "     OpenAI-compatible) + 127.0.0.1:9119 (headless serve backend)."
echo "     No browser UI (vite/bun build rejected: no lockfile at this tag)."
echo "=============================================================="

if ! id hermes >/dev/null 2>&1; then
    echo "FATAL: the 'hermes' user does not exist (Phase 2 should have created it)." >&2
    exit 1
fi
echo "  [ok]      'hermes' user present (uid $(id -u hermes))"

# Precondition: python3 must satisfy requires-python ">=3.11,<3.15" at this
# tag (host python3 IS 3.14.4, exactly what v0.23.0 targets).
if python3 -c 'import sys; sys.exit(0 if (3,11) <= sys.version_info[:2] < (3,15) else 1)' 2>/dev/null; then
    echo "  [ok]      python3 $(python3 -V 2>&1) satisfies the $PIN_TAG pin (>=3.11,<3.15)"
else
    echo "  *** WARN: python3 $(python3 -V 2>&1) does NOT satisfy '>=3.11,<3.15'."
    echo "  ***       The venv install below will be skipped."
fi

# ----------------------------------------------------------------------
sub "APPLY 1/3 — clone source at pinned tag $PIN_TAG (+ integrity gate)"
NEED_CLONE=1
if [ -d "$SRC/.git" ]; then
    HEAD_NOW="$(gitr -C "$SRC" rev-parse HEAD 2>/dev/null || echo unknown)"
    if [ "$HEAD_NOW" = "$PIN_COMMIT" ]; then
        echo "  [ok]      $SRC already at pinned commit $PIN_COMMIT — reused as-is"
        NEED_CLONE=0
    else
        echo "FATAL: $SRC exists but HEAD is $HEAD_NOW (want $PIN_COMMIT)." >&2
        echo "       Refusing to touch a mismatched tree. If this is stale," >&2
        echo "       remove it yourself (sudo rm -rf '$SRC') and re-run." >&2
        exit 1
    fi
fi
if [ "$NEED_CLONE" -eq 1 ]; then
    echo "  [install] git clone --depth 1 --branch $PIN_TAG https://github.com/NousResearch/hermes-agent.git $SRC"
    if git clone --quiet --depth 1 --branch "$PIN_TAG" \
        https://github.com/NousResearch/hermes-agent.git "$SRC"; then
        echo "  [done]    cloned (install path of record: git at a pinned tag; no curl|bash)"
        NEED_CLONE=0
    else
        echo "  *** WARN: git clone FAILED (offline / GitHub unreachable?)."
        echo "  ***       Nothing else was harmed; re-run this script when online."
        NEED_CLONE=1
    fi
fi
if [ -d "$SRC/.git" ]; then
    HEAD_NOW="$(gitr -C "$SRC" rev-parse HEAD 2>/dev/null || echo unknown)"
    if [ "$HEAD_NOW" = "$PIN_COMMIT" ]; then
        echo "  [ok]      integrity gate: HEAD == $PIN_COMMIT ($PIN_TAG)"
        echo "            release manifest SHA256: $PIN_MANIFEST"
        # Only tracked-file modifications matter (EGG-INFO/untracked droppings
        # from pip -e installs are expected and harmless).
        if [ -n "$(gitr -C "$SRC" status --porcelain 2>/dev/null | grep -v '^??' || true)" ]; then
            echo "  *** WARN: tracked files in $SRC were MODIFIED post-clone:" >&2
            gitr -C "$SRC" status --porcelain | grep -v '^??' >&2 || true
        else
            echo "  [ok]      tracked working tree is clean"
        fi
        chown -R hermes:hermes "$SRC"
    else
        echo "FATAL: freshly cloned HEAD is $HEAD_NOW — expected $PIN_COMMIT. Aborting." >&2
        echo "       Do NOT install or start anything from this tree." >&2
        exit 1
    fi
fi

# ----------------------------------------------------------------------
sub "APPLY 2/3 — venv + locked uv sync (hermes user, [ddgs]+[sms] extras)"
if [ "$NEED_CLONE" -eq 0 ] && [ -d "$SRC" ]; then
    NEED_SYNC=0
    [ -x "$VENV/bin/hermes" ] || NEED_SYNC=1
    if [ "$NEED_SYNC" -eq 0 ] && ! "$VENV/bin/python" -c 'import aiohttp' >/dev/null 2>&1; then
        NEED_SYNC=1
        echo "  [update]  hermes present but aiohttp missing — uv sync re-run needed"
        echo "            (api_server adapter requires aiohttp; the [sms] extra adds ONLY aiohttp==3.14.5)"
    fi
    if [ "$NEED_SYNC" -eq 1 ]; then
        echo "  [install] python3 -m venv $VENV (bootstrap; the real install is uv sync)"
        if python3 -m venv "$VENV"; then
            chown -R hermes:hermes "$VENV" "$SRC"
            chown hermes:hermes /opt/hermes
            chmod 750 /opt/hermes
            chmod 750 "$VENV"
            if [ ! -x "$VENV/bin/uv" ]; then
                echo "  [install] pip install 'uv==$UV_PIN' (bootstrap the pinned uv into the venv)"
                if runuser -u hermes -- env PATH="$VENV/bin:/usr/bin:/bin" HOME=/home/hermes \
                    "$VENV/bin/pip" install --no-cache-dir --quiet "uv==$UV_PIN"; then
                    echo "  [ok]      uv $UV_PIN bootstrapped"
                else
                    echo "  *** WARN: 'pip install uv' FAILED (offline / PyPI unreachable?"
                    echo "  ***       or the venv lost its pip). Hermes is NOT installed."
                    echo "  ***       If the venv exists but has no pip/uv, remove it and"
                    echo "  ***       re-run: sudo rm -rf $VENV && sudo bash $0"
                    UV_OK=0
                fi
            else
                echo "  [ok]      existing uv reused from the venv"
            fi
        else
            echo "  *** WARN: 'python3 -m venv' FAILED (python3-venv package missing?)."
            echo "  ***       Fix (as root): sudo apt-get install -y python3-venv   (note:"
            echo "  ***       this script itself never runs apt), then re-run."
        fi
        if [ -x "$VENV/bin/uv" ]; then
            chown -R hermes:hermes "$VENV" "$SRC"
            UV_LOG=/tmp/opencode/uv_sync.log
            echo "  [install] uv sync --locked --extra ddgs --extra sms as hermes (network required)"
            echo "            uv pin: $UV_PIN — [tool.uv] overrides from the tag apply"
            echo "            (Pillow==13.0.0 beats browser-harness's stale 12.3.0 pin);"
            echo "            UV_PYTHON_DOWNLOADS=never pins the interpreter to the host's."
            echo "            extras: [ddgs] = ddgs==9.16.0 (web search). [sms] = ONLY"
            echo "            aiohttp==3.14.5 — the tag linted it as a single-dep extra;"
            echo "            the api_server platform is aiohttp-based and core does NOT"
            echo "            include aiohttp (live-diagnosed 2026-11-08: 'API Server:"
            echo "            aiohttp not installed'). Pulling whole messaging extras"
            echo "            (telegram/discord/slack) for it would be worse; the SMS"
            echo "            adapter itself stays inert — platform enablement is"
            echo "            config/env-driven, not extras-driven."
            if runuser -u hermes -- env HOME=/home/hermes \
                UV_PROJECT_ENVIRONMENT="$VENV" \
                UV_PYTHON_DOWNLOADS=never \
                UV_PYTHON_PREFERENCE=only-system \
                "$VENV/bin/uv" sync --locked --extra ddgs --extra sms --project "$SRC" \
                >"$UV_LOG" 2>&1; then
                echo "  [done]    uv sync completed (full log: $UV_LOG)"
            else
                echo "  *** WARN: uv sync FAILED — tail of the uv log below:"
                tail -15 "$UV_LOG" 2>/dev/null | sed 's/^/  |uv| /'
                echo "  ***       full log: $UV_LOG"
                echo "  ***       Re-run this script (idempotent) once the cause is fixed."
            fi
            if [ -x "$VENV/bin/hermes" ]; then
                chown -R hermes:hermes "$VENV"
                echo "  [install] pre-compiling bytecode for read-only runtime dirs"
                runuser -u hermes -- "$VENV/bin/python" -m compileall -q "$SRC" >/dev/null 2>&1 || true
                echo "  [done]    hermes CLI installed: $VENV/bin/hermes (extras: [ddgs])"
                HERMES_INSTALLED=1
            else
                echo "  *** WARN: $VENV/bin/hermes missing after uv sync — Hermes is NOT installed"
                echo "  ***       (config + units were still prepared; re-run after fixing)."
            fi
        elif [ ! -x "$VENV/bin/hermes" ]; then
            echo "  [skip]    uv unavailable — uv sync skipped (see uv bootstrap warning above)"
        fi
    else
        echo "  [ok]      hermes already installed: $VENV/bin/hermes (aiohttp present)"
        HERMES_INSTALLED=1
    fi
else
    echo "  [skip]    venv build skipped — source tree missing (clone failed above)"
fi

# ----------------------------------------------------------------------
sub "APPLY 3/3 — config install + env secrets + systemd units"

if [ ! -f "$CONF_SRC" ]; then
    echo "  FATAL: source config $CONF_SRC missing — cannot continue." >&2
    exit 1
fi

# /var/lib/hermes is the pinned HERMES_HOME (all runtime state lives there).
mkdir -p "$HERMES_HOME"
chown hermes:hermes "$HERMES_HOME"
chmod 750 "$HERMES_HOME"
install -m 600 -o hermes -g hermes "$CONF_SRC" "$CONF"
echo "  [ok]      $CONF installed (600 hermes:hermes) from $CONF_SRC (verbatim)"

# /etc/hermes directory + env file hygiene (Phase 2 artifacts preserved).
chown root:hermes /etc/hermes
chmod 750 /etc/hermes
if [ ! -f "$ENVF" ]; then
    install -m 600 -o hermes -g hermes /dev/null "$ENVF"
    echo "  [created] $ENVF (600 hermes:hermes) — Phase 2 skeleton was missing"
else
    chown hermes:hermes "$ENVF"
    chmod 600 "$ENVF"
    echo "  [ok]      $ENVF preserved (NOT overwritten) -> 600 hermes:hermes"
fi

# --- Secrets: append ONLY missing keys. No value is ever echoed. ---------
# LITELLM_API_KEY must equal LiteLLM's master key so Hermes can call the
# Phase 3 proxy at http://127.0.0.1:4000/v1 with an ALLOWED key. Copy it
# from /etc/litellm/litellm.env (root-readable here) without printing it.
sub "secrets — fill MISSING values in $ENVF (values never echoed)"
HERMES_SECRET_MISSING=0
LITELLM_MASTER_KEY_VAL="$(get_var "$LITELLM_ENV" LITELLM_MASTER_KEY)"
if [ -n "$LITELLM_MASTER_KEY_VAL" ]; then
    if add_secret LITELLM_API_KEY "$LITELLM_MASTER_KEY_VAL"; then :; fi
else
    echo "  [missing] LITELLM_MASTER_KEY not found in $LITELLM_ENV —"
    echo "            LITELLM_API_KEY cannot be derived. Keep following Phase 3"
    echo "            go-live steps first, then re-run this script."
    HERMES_SECRET_MISSING=1
fi
API_SERVER_KEY_VAL="$(get_var "$ENVF" API_SERVER_KEY)"
if [ -n "$API_SERVER_KEY_VAL" ]; then
    echo "  [keep]    API_SERVER_KEY already present (NOT regenerated)"
else
    add_secret API_SERVER_KEY "$(openssl rand -hex 32)" || HERMES_SECRET_MISSING=1
fi

# --- systemd units -------------------------------------------------------
sub "writing $SERVE_UNIT (headless serve backend @ 127.0.0.1:9119)"
cat >"$SERVE_UNIT" <<'UNITEOF'
[Unit]
Description=Hermes Agent headless serve backend (loopback 127.0.0.1:9119)
Documentation=https://github.com/NousResearch/hermes-agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=hermes
Group=hermes
EnvironmentFile=/etc/hermes/hermes.env
WorkingDirectory=/var/lib/hermes
Environment="HOME=/var/lib/hermes"
# HERMES_HOME pins config + runtime state to /var/lib/hermes (config.yaml).
Environment="HERMES_HOME=/var/lib/hermes"
# Telemetry kill switch (Nous shared metrics), belt-and-braces.
Environment="HERMES_DISABLE_TELEMETRY=1"
# BIND pinned here: 127.0.0.1:9119 (headless backend; JSON-RPC/WS sessions).
ExecStart=/opt/hermes/venv/bin/hermes serve --host 127.0.0.1 --port 9119
Restart=on-failure
RestartSec=5
StateDirectory=hermes
StateDirectoryMode=0750
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
ReadOnlyPaths=/etc/hermes
ReadWritePaths=/var/lib/hermes /opt/hermes/src

[Install]
WantedBy=multi-user.target
UNITEOF
chown root:root "$SERVE_UNIT"
chmod 644 "$SERVE_UNIT"
echo "  [ok]      $SERVE_UNIT written (644 root:root)"

sub "writing $API_UNIT (gateway with api_server platform @ 127.0.0.1:8642)"
cat >"$API_UNIT" <<'UNITEOF'
[Unit]
Description=Hermes Agent gateway — api_server platform (loopback 127.0.0.1:8642)
Documentation=https://github.com/NousResearch/hermes-agent
After=network-online.target user@1001.service
Wants=network-online.target user@1001.service
StartLimitIntervalSec=0

[Service]
Type=simple
User=hermes
Group=hermes
EnvironmentFile=/etc/hermes/hermes.env
WorkingDirectory=/var/lib/hermes
Environment="HOME=/var/lib/hermes"
Environment="HERMES_HOME=/var/lib/hermes"
Environment="HERMES_DISABLE_TELEMETRY=1"
# api_server bind pin (API_SERVER_HOST/API_SERVER_PORT are read by
# gateway/config_env.py at v0.23.0; defaults are already 127.0.0.1:8642 —
# pinned explicitly so a later default change cannot open this surface).
Environment="API_SERVER_HOST=127.0.0.1"
Environment="API_SERVER_PORT=8642"
# Auth comes from API_SERVER_KEY in /etc/hermes/hermes.env (>=16 chars);
# the adapter refuses to start without a usable key (fail-closed).
ExecStart=/opt/hermes/venv/bin/hermes gateway run --replace --external-supervisor
Restart=always
RestartSec=5
RestartForceExitStatus=75
SuccessExitStatus=75
RestartPreventExitStatus=78
KillMode=mixed
KillSignal=SIGTERM
TimeoutStopSec=90
StateDirectory=hermes
StateDirectoryMode=0750
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
ReadOnlyPaths=/etc/hermes
ReadWritePaths=/var/lib/hermes /opt/hermes/src

[Install]
WantedBy=multi-user.target
UNITEOF
chown root:root "$API_UNIT"
chmod 644 "$API_UNIT"
systemctl daemon-reload
echo "  [ok]      $API_UNIT written (644 root:root) + systemctl daemon-reload done"

sub "start gating — enable --now ONLY if both real secrets exist"
SECRET_READY=1
grep -qE '^LITELLM_API_KEY=[^[:space:]#]+' "$ENVF" || SECRET_READY=0
grep -qE '^API_SERVER_KEY=[^[:space:]#]+' "$ENVF" || SECRET_READY=0
if [ "$HERMES_INSTALLED" -eq 1 ] && [ "$SECRET_READY" -eq 1 ]; then
    if [ ! -f "$LITELLM_ENV" ] || ! grep -qE '^LITELLM_MASTER_KEY=[^[:space:]#]+' "$LITELLM_ENV"; then
        echo "  *** WARN: LITELLM_MASTER_KEY is not set in $LITELLM_ENV — the Phase 3"
        echo "  ***       proxy (if running) would reject Hermes traffic. Starting"
        echo "  ***       Hermes anyway; the model calls will fail until Phase 3 keys"
        echo "  ***       are live and Hermes is restarted."
    fi
    for UNIT_NAME in hermes-serve hermes-api; do
        if systemctl is-active --quiet "$UNIT_NAME"; then
            systemctl restart "$UNIT_NAME"
            echo "  [ok]      $UNIT_NAME already active -> restarted (config/env changes applied)"
        else
            systemctl enable --now "$UNIT_NAME"
            echo "  [ok]      systemctl enable --now $UNIT_NAME"
        fi
    done
    sleep 3
    for UNIT_NAME in hermes-serve hermes-api; do
        if systemctl is-active --quiet "$UNIT_NAME"; then
            echo "  [ok]      $UNIT_NAME is active"
        else
            echo "  *** WARN: $UNIT_NAME NOT active. Last 20 journal lines:" >&2
            journalctl -u "$UNIT_NAME" -n 20 --no-pager >&2 || true
        fi
    done
else
    echo "  [skeleton] Not starting: secrets present=$SECRET_READY, installed=$HERMES_INSTALLED."
    echo "             To go live:"
    echo "               1. Make sure Phase 3 keys are real in $LITELLM_ENV (LITELLM_MASTER_KEY,"
    echo "                  ZEN_API_KEY) so LITELLM_API_KEY can be derived, then re-run this"
    echo "                  script — it fills both missing keys automatically."
    echo "               2. sudo systemctl enable --now hermes-serve hermes-api"
    echo "               3. sudo bash /home/jordan/Documents/SystemBuild/phase4_diag.sh"
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
    if grep -q '^model:' "$CONF" && grep -q '^web:' "$CONF" && grep -q '^platforms:' "$CONF"; then
        pass "structural sanity OK (PyYAML unavailable: top-level keys present)"
    else
        fail "structural sanity FAILED (and PyYAML unavailable)"
    fi
fi

sub "V2 — model block: custom provider via LiteLLM (127.0.0.1:4000/v1)"
if cfg_body | grep -Fq 'provider: custom'; then
    pass "model.provider: custom (the custom-endpoint flow shape @ v0.23.0)"
else
    fail "model.provider is not custom"
fi
if cfg_body | grep -Fq 'base_url: http://127.0.0.1:4000/v1'; then
    pass "model.base_url pinned to the loopback LiteLLM proxy"
else
    fail "model.base_url does not pin http://127.0.0.1:4000/v1"
fi
if cfg_body | grep -Fq 'api_key: ${LITELLM_API_KEY}'; then
    pass "model.api_key is the \${LITELLM_API_KEY} env reference (no literal)"
else
    fail "model.api_key is not the \${LITELLM_API_KEY} reference"
fi
if cfg_body | grep -Fq 'api_mode: chat_completions'; then
    pass "model.api_mode: chat_completions (OpenAI-compatible LiteLLM wire)"
else
    fail "api_mode missing (auto-detect could mis-negotiate the wire)"
fi
MODEL_DEFAULT="$(cfg_body | grep -E '^[[:space:]]*default: ' | head -n1 | sed -E 's/.*default:[[:space:]]*//')"
case "$MODEL_DEFAULT" in
    glm-5.3-flash|kimi-k2.7-code|beam-free)
        pass "model.default = $MODEL_DEFAULT (an allowed LiteLLM model)" ;;
    "")
        fail "model.default missing" ;;
    *)
        fail "model.default = '$MODEL_DEFAULT' is NOT in the allowed model set" ;;
esac

sub "V3 — web search pinned to ddgs; keyless ring + rescue disabled"
for want in 'search_backend: ddgs' 'extract_backend: ddgs' \
            'keyless_fallback: false' 'keyless_rescue: false'; do
    if cfg_body | grep -Fq "$want"; then
        pass "web.$want"
    else
        fail "web.$want missing/incorrect"
    fi
done

sub "V4 — platforms: api_server only (+ no other platform keys)"
PLATS="$(python3 - "$CONF" <<'EOF' 2>/dev/null || true
import sys
try:
    import yaml
    cfg = yaml.safe_load(open(sys.argv[1])) or {}
    print("|".join(sorted((cfg.get("platforms") or {}).keys())))
except Exception:
    print("")
EOF
)"
echo "  platform keys: ${PLATS:-<none>}"
if [ "$PLATS" = "api_server" ]; then
    pass "platforms contains EXACTLY api_server"
else
    fail "platforms != ['api_server'] (got: '$PLATS')"
fi
if cfg_body | grep -Eiq '^[[:space:]]*(telegram|discord|slack|whatsapp|teams|signal|wecom|feishu)[[:space:]]*:'; then
    fail "a messaging platform key was found in the config"
else
    pass "no messaging platform keys in config (adapters stay inert)"
fi
if cfg_body | grep -Fq 'auto_update_check_hours: 0'; then
    pass "plugins.auto_update_check_hours: 0 (no plugin-catalog egress)"
else
    fail "plugins.auto_update_check_hours pin missing"
fi

sub "V5 — no secret literals in the config; no fallback_providers block"
if cfg_body | grep -q 'sk-' || cfg_body | grep -Eiq '(api_key|token|password|secret): *[^$ ]'; then
    fail "possible secret literal in config body"
else
    pass "no api_key/token literals — only \${ENV} references"
fi

if cfg_body | grep -q '^fallback_providers:' \
   && [ -n "$(cfg_body | awk '/^fallback_providers:/{f=1;next} /^[^ ]/{f=0} f && NF{print}' | head -1)" ]; then
    fail "fallback_providers is non-empty (fallback belongs to LiteLLM)"
else
    pass "no fallback_providers entries (LiteLLM owns the chain)"
fi

sub "V6 — systemd units: binds, identity, hardening, environment"
for want in 'User=hermes' 'Group=hermes' \
            'EnvironmentFile=/etc/hermes/hermes.env' \
            'Environment="HERMES_HOME=/var/lib/hermes"' \
            'Environment="HERMES_DISABLE_TELEMETRY=1"' \
            'ProtectSystem=strict' 'NoNewPrivileges=true' 'PrivateTmp=true' \
            'ReadOnlyPaths=/etc/hermes' 'ReadWritePaths=/var/lib/hermes /opt/hermes/src' \
            'StateDirectory=hermes' 'StateDirectoryMode=0750'; do
    OK_UNITS=0
    grep -Fq "$want" "$SERVE_UNIT" && OK_UNITS=$((OK_UNITS+1))
    grep -Fq "$want" "$API_UNIT" && OK_UNITS=$((OK_UNITS+1))
    if [ "$OK_UNITS" -eq 2 ]; then
        pass "both units: $want"
    else
        fail "unit(s) missing '$want' ($OK_UNITS/2)"
    fi
done
if grep -Fq 'ExecStart=/opt/hermes/venv/bin/hermes serve --host 127.0.0.1 --port 9119' "$SERVE_UNIT"; then
    pass "serve unit binds 127.0.0.1:9119 (headless backend)"
else
    fail "serve unit ExecStart does not pin 127.0.0.1:9119"
fi
grep -Fq 'Environment="API_SERVER_HOST=127.0.0.1"' "$API_UNIT" && \
grep -Fq 'Environment="API_SERVER_PORT=8642"' "$API_UNIT" && \
grep -Fq 'hermes gateway run --replace --external-supervisor' "$API_UNIT" && \
pass "api unit: gateway run with API_SERVER_HOST=127.0.0.1 / API_SERVER_PORT=8642" || \
fail "api unit bind pins missing"
if ! grep -E '0\.0\.0\.0|::' "$SERVE_UNIT" "$API_UNIT" >/dev/null 2>&1; then
    pass "no wildcard bind anywhere in the units"
else
    fail "a wildcard/IPv6-any bind appears in a unit"
fi
if command -v systemd-analyze >/dev/null 2>&1; then
    VA_OK=1
    for UNIT_PATH in "$SERVE_UNIT" "$API_UNIT"; do
        if VA_OUT="$(systemd-analyze verify "$UNIT_PATH" 2>&1)"; then
            echo "  [ok]      systemd-analyze verify $(basename "$UNIT_PATH"): clean"
        elif [ "$HERMES_INSTALLED" -ne 1 ] && printf '%s' "$VA_OUT" | grep -Fq 'venv/bin/hermes'; then
            note "verify $(basename "$UNIT_PATH") failed ONLY because the hermes venv is not"
            note "installed yet (network-gated above). Re-run after install to re-verify."
        else
            fail "systemd-analyze verify $(basename "$UNIT_PATH") rc!=0: $VA_OUT"
            VA_OK=0
        fi
    done
else
    note "systemd-analyze unavailable — structural checks only"
fi

sub "V7 — ownership/modes"
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
check_mode /etc/hermes                    750 root:hermes
check_mode "$ENVF"                        600 hermes:hermes
# $HERMES_HOME: BOTH 750 and 700 are correct. This script creates it 750, but
# Hermes self-hardens $HERMES_HOME to 0700 at startup (hermes_cli/config.py
# home-mode logic @ v0.23.0) when the web server inside it runs as the owner —
# which is our exact topology (User=hermes, loopback-only binds). 700 is the
# TIGHTER state, so accept it; only fail when it is looser than 750.
H_M="$(stat -c '%a' "$HERMES_HOME" 2>/dev/null || echo MISSING)"
H_O="$(stat -c '%U:%G' "$HERMES_HOME" 2>/dev/null || echo MISSING)"
echo "  $HERMES_HOME -> mode=$H_M owner=$H_O  (want 750 hermes:hermes; 700 accepted — Hermes self-hardening)"
if [ "$H_O" = "hermes:hermes" ] && { [ "$H_M" = "750" ] || [ "$H_M" = "700" ]; }; then
    pass "$HERMES_HOME is hermes:hermes with mode $H_M (TIGHT-enough)"
else
    fail "$HERMES_HOME is NOT hermes:hermes 750/700"
fi
check_mode "$CONF"                        600 hermes:hermes
check_mode "$SERVE_UNIT"                  644 root:root
check_mode "$API_UNIT"                    644 root:root
if [ "$HERMES_INSTALLED" -eq 1 ]; then
    check_mode "$VENV"                    750 hermes:hermes
    if "$VENV/bin/python" -c 'from importlib.metadata import version; v = version("ddgs"); print(v); import sys; sys.exit(0 if v == "9.16.0" else 1)' >/dev/null 2>&1; then
        pass "ddgs==9.16.0 installed in the venv ([ddgs] extra, importlib.metadata-verified)"
    else
        fail "ddgs 9.16.0 NOT resolvable in the venv"
    fi
    if "$VENV/bin/python" -c 'from importlib.metadata import version; v = version("pillow"); import sys; sys.exit(0 if v == "13.0.0" else 1)' >/dev/null 2>&1; then
        pass "pillow==13.0.0 — [tool.uv] override applied (browser-harness's 12.3.0 pin superseded)"
    else
        fail "pillow override NOT applied (package resolution must stay uv-locked)"
    fi
    if "$VENV/bin/python" -c 'import aiohttp; import sys; sys.exit(0 if aiohttp.__version__ == "3.14.5" else 1)' >/dev/null 2>&1; then
        pass "aiohttp==3.14.5 present (api_server adapter requirement; via the single-dep [sms] extra)"
    else
        fail "aiohttp 3.14.5 missing — api_server platform cannot bind ('aiohttp not installed')"
    fi
else
    note "venv not installed (network-gated) — venv/ddgs checks skipped"
fi

sub "V8 — $ENVF line-shape sanity (systemd-safe VAR=value; masked)"
if [ -f "$ENVF" ]; then
    env_bad=0
    ln_no=0
    while IFS= read -r line || [ -n "$line" ]; do
        ln_no=$((ln_no + 1))
        if [ -z "${line//[[:space:]]/}" ] || [[ "$line" =~ ^[[:space:]]*# ]]; then
            continue
        fi
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
        REAL_COUNT="$(grep -cvE '^[[:space:]]*(#|$)' "$ENVF" || true)"
        echo "  $ENVF holds $REAL_COUNT real value line(s) — contents NOT echoed (protected)"
    fi
else
    note "$ENVF missing — V8 skipped"
fi

sub "V9 — supply-chain pin: tag, commit, tree, egress map of record"
if [ -d "$SRC/.git" ]; then
    HEAD_NOW="$(gitr -C "$SRC" rev-parse HEAD 2>/dev/null || echo unknown)"
    echo "  pinned tag     : $PIN_TAG"
    echo "  pinned commit  : $PIN_COMMIT"
    echo "  HEAD           : $HEAD_NOW"
    echo "  manifest sha256: $PIN_MANIFEST (integrity reference; raw tag object UNSIGNED)"
    if [ "$HEAD_NOW" = "$PIN_COMMIT" ]; then
        pass "source tree is at the audited pin"
    else
        fail "source tree HEAD is NOT the pinned commit"
    fi
else
    fail "$SRC missing — pin unverifiable"
fi
SELF_CODE="$(grep -v '^[[:space:]]*#' "$0")"
if printf '%s\n' "$SELF_CODE" | grep -E 'curl[^#]*\|[[:space:]]*(sudo )?bash' | grep -Fv 'no curl|bash' >/dev/null 2>&1; then
    fail "install-by-curl pipe pattern in this script (must stay git-clone)"
else
    pass "install path of record: git clone at pinned tag (no curl|bash in executable content)"
fi

sub "V10 — Phase 3 untouched (read-only sanity: litellm + host posture)"
if [ -f /etc/litellm/config.yaml ]; then
    N="$(sed 's/[[:space:]]*#.*$//' /etc/litellm/config.yaml | grep -cE '^[[:space:]]*- model_name: ' || true)"
    if [ "$N" -eq 3 ]; then
        pass "phase 3 model_list still exactly 3 models (untouched)"
    else
        fail "phase 3 model_list count changed: $N"
    fi
else
    note "/etc/litellm/config.yaml missing — phase 3 state changed unexpectedly"
fi
if grep -Fq -- '--host 127.0.0.1 --port 4000' /etc/systemd/system/litellm.service 2>/dev/null; then
    pass "litellm.service still binds 127.0.0.1:4000 (untouched)"
else
    fail "litellm.service bind flags missing/changed"
fi
if findmnt -rn -S /dev/ubuntu-vg/media >/dev/null 2>&1; then
    fail "media LV is MOUNTED on host (should stay unmounted for passthrough)"
else
    pass "media LV is NOT mounted on host"
fi
if command -v ufw >/dev/null 2>&1; then
    ufws="$(ufw status 2>/dev/null | head -n1 || true)"
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

# ----------------------------------------------------------------------
# Best-effort: guarantee the conventional log path is readable by the agent
# (jordan), no matter which uid/umask wrote it.
if [ -f "$LOG" ]; then
    chown jordan:jordan "$LOG" 2>/dev/null || true
    chmod 644 "$LOG" 2>/dev/null || true
fi

echo
echo "=============================================================="
echo "=== Phase 4 apply complete ==="
echo "=== VERIFY_FAILS=$FAILS ==="
echo "=============================================================="
if [ "$FAILS" -gt 0 ]; then
    echo "Phase 4 finished with $FAILS verification failure(s) — review $LOG" >&2
    exit 1
fi
exit 0

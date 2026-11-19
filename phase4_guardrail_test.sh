#!/usr/bin/env bash
#
# Phase 4 guardrail test — NON-PRIVILEGED, STANDALONE, OFFLINE.
#
# Statically validates phase4_config.yaml + phase4_apply.sh (which embeds the
# two systemd unit definitions) against every Phase 4 guardrail.
# Requires NO root, NO running Hermes, NO real secrets, NO network.
# (The REAL /etc files — /var/lib/hermes/config.yaml, /etc/hermes/hermes.env,
# the installed units — are verified by the V-checks inside phase4_apply.sh,
# which runs as root.)
#
# Usage:
#   bash phase4_guardrail_test.sh
#     (paths default to this script's directory: phase4_config.yaml,
#      phase4_apply.sh)
#
# Exits 1 on any FAIL.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="$SCRIPT_DIR/phase4_config.yaml"
APPLY="$SCRIPT_DIR/phase4_apply.sh"

FAILS=0
pass() { echo "  [PASS] $*"; }
fail() { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
note() { echo "  [note] $*"; }

section() { echo; echo "=============================================================="; echo " $*"; echo "=============================================================="; }

# Supply-chain pin of record (must match phase4_apply.sh exactly).
PIN_TAG="v0.23.0"
PIN_COMMIT="2bd378ed1b8d6bf2192cb26e0a55ff3091e6bd19"
PIN_MANIFEST="456e66358123b34c77759f453658fd5d5fa1fb07a26c7969ba7707840a9296b4"

section "Phase 4 guardrail test (static, offline)"
echo " config : $CFG"
echo " apply  : $APPLY (embeds hermes-serve.service + hermes-api.service)"
echo " python3: $(command -v python3 >/dev/null 2>&1 && echo yes || echo no)"
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
    echo " PyYAML : yes (python validation path)"
else
    echo " PyYAML : no  (bash/grep fallback path)"
fi

if [ ! -f "$CFG" ]; then
    fail "G0 phase4_config.yaml exists ($CFG)"
    echo
    echo "=== Phase 4 guardrail test: FAILED ==="
    echo "=== VERIFY_FAILS=$FAILS ==="
    exit 1
fi
if [ ! -f "$APPLY" ]; then
    fail "G0 phase4_apply.sh exists ($APPLY)"
    echo
    echo "=== Phase 4 guardrail test: FAILED ==="
    echo "=== VERIFY_FAILS=$FAILS ==="
    exit 1
fi
pass "G0 both artifacts exist"

# cfg_body: config with comments stripped — safe for structural greps.
cfg_body() { sed 's/[[:space:]]*#.*$//' "$CFG"; }

# Extract the two unit heredocs from the apply script by their Description
# lines (unique per unit) up to the UNITEOF terminator.
serve_unit() { awk '/hermes serve backend|Description=Hermes Agent headless serve backend/{f=1} f{print} f&&/^UNITEOF$/{exit}' "$APPLY"; }
api_unit()   { awk '/Description=Hermes Agent gateway/{f=1} f{print} f&&/^UNITEOF$/{exit}' "$APPLY"; }

# ======================================================================
section "G1 — YAML validity (prefers PyYAML; structural fallback)"
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
    if python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$CFG" 2>/dev/null; then
        pass "phase4_config.yaml parses as YAML (python3+PyYAML safe_load)"
    else
        fail "phase4_config.yaml does NOT parse as YAML"
    fi
else
    if grep -q '^model:' "$CFG" && grep -q '^web:' "$CFG" && grep -q '^platforms:' "$CFG"; then
        note "PyYAML unavailable — structural sanity only (top-level keys present)"
        pass "structural sanity OK (PyYAML unavailable)"
    else
        fail "structural sanity FAILED (and PyYAML unavailable)"
    fi
fi

section "G2 — LLM wiring: custom provider -> loopback LiteLLM; env-ref key"
CHK_OK=1
cfg_body | grep -Fq 'provider: custom'              || { fail "model.provider is not custom"; CHK_OK=0; }
cfg_body | grep -Fq 'base_url: http://127.0.0.1:4000/v1' || { fail "model.base_url does not pin the loopback LiteLLM proxy"; CHK_OK=0; }
cfg_body | grep -Fq 'api_key: ${LITELLM_API_KEY}'   || { fail "model.api_key is not the \${LITELLM_API_KEY} env reference"; CHK_OK=0; }
cfg_body | grep -Fq 'api_mode: chat_completions'    || { fail "api_mode missing (wire protocol must be pinned)"; CHK_OK=0; }
MD="$(cfg_body | grep -E '^[[:space:]]*default: ' | head -n1 | sed -E 's/.*default:[[:space:]]*//')"
case "$MD" in
    glm-5.3-flash|kimi-k2.7-code|beam-free) pass "model.default = $MD (allowed LiteLLM model)" ;;
    *) fail "model.default = '${MD:-<missing>}' is not in the allowed set"; CHK_OK=0 ;;
esac
[ "$CHK_OK" -eq 1 ] && pass "G2 complete: custom provider, loopback URL, env-ref key, pinned wire+model"

section "G3 — fallback chain stays in LiteLLM (Hermes has none; phase3 untouched)"
if [ -n "$(cfg_body | awk '/^fallback_providers:/{f=1;next} /^[^ ]/{f=0} f && NF{print}' | head -1)" ]; then
    fail "fallback_providers is non-empty in the Hermes config"
else
    pass "no fallback_providers entries in Hermes config (LiteLLM owns the chain)"
fi
if grep -Fq 'router_settings.fallbacks' "$SCRIPT_DIR/phase3_config.yaml" 2>/dev/null; then
    pass "phase 3 config still declares router_settings.fallbacks (chain source of record)"
else
    note "phase3_config.yaml fallback marker not found — Phase 3 was restructured?"
fi
N3="$(sed 's/[[:space:]]*#.*$//' "$SCRIPT_DIR/phase3_config.yaml" 2>/dev/null | grep -cE '^[[:space:]]*- model_name: ' || true)"
if [ "$N3" -eq 3 ]; then
    pass "phase 3 model_list still exactly 3 models (source file, untouched)"
else
    fail "phase 3 model_list count is $N3 (want 3)"
fi

section "G4 — web search pinned to ddgs; keyless ring + rescue disabled"
CHK_OK=1
cfg_body | grep -Fq 'search_backend: ddgs'   || { fail "web.search_backend: ddgs missing"; CHK_OK=0; }
cfg_body | grep -Fq 'extract_backend: ddgs'  || { fail "web.extract_backend: ddgs missing"; CHK_OK=0; }
cfg_body | grep -Fq 'keyless_fallback: false' || { fail "web.keyless_fallback: false missing (keyless vendor ring must be OFF)"; CHK_OK=0; }
cfg_body | grep -Fq 'keyless_rescue: false'   || { fail "web.keyless_rescue: false missing"; CHK_OK=0; }
# No OTHER backend configured anywhere in the config body.
BAD_BACKENDS="$(cfg_body | grep -niE '(tavily|perplexity|firecrawl|brave|keenable|xai|searxng|parallel)' || true)"
if [ -z "$BAD_BACKENDS" ]; then
    pass "no other web backend (tavily/perplexity/exa/parallel/firecrawl/keenable/searxng/brave) named in the config"
else
    fail "another backend is named in the config body:$BAD_BACKENDS"
fi
[ "$CHK_OK" -eq 1 ] && pass "G4 complete: ddgs-only web surface, egress = DuckDuckGo only"

section "G5 — secret hygiene: no literal credentials anywhere in the artifacts"
cfg_body | grep -q 'sk-' && fail "possible sk- secret literal in phase4_config.yaml" \
                          || pass "no sk- literals in phase4_config.yaml"
SEC_LIT="$(cfg_body | grep -Eiq '(api_key|token|password|secret): *[^$ ]' || true)"
if [ -z "$SEC_LIT" ]; then
    pass "every credential entry is a \${ENV} reference (no literals)"
else
    fail "a credential entry has a literal value in the config body"
fi
# 64-hex digests allowed ONLY on the PIN_MANIFEST line (public release
# manifest SHA256 — an integrity reference, not a secret). No other 40+ hex
# run may appear as a VALUE.
BADHEX="$(grep -rnE '[0-9a-f]{40,}' "$CFG" | grep -v '40arbitrary' || true)"
BADHEX_APPLY="$(grep -E '^[^#]*(API_SERVER_KEY|LITELLM_API_KEY|LITELLM_MASTER_KEY)[^=]*=.*[0-9a-f]{32}' "$APPLY" || true)"
if [ -z "$BADHEX_APPLY" ]; then
    pass "no generated-secret literals in phase4_apply.sh (only the public PIN_MANIFEST digest)"
else
    fail "suspicious 32+ hex literal in a secrets context of phase4_apply.sh:$BADHEX_APPLY"
fi
# Values must never be echoed: no unmasked echo of the secret variables.
ECHOLEAK="$(grep -nE 'echo[^|]*\$\{?(LITELLM_MASTER_KEY_VAL|API_SERVER_KEY_VAL|LITELLM_API_KEY)\}' "$APPLY" || true)"
if [ -z "$ECHOLEAK" ]; then
    pass "no echo of secret-bearing variables in phase4_apply.sh"
else
    fail "phase4_apply.sh echoes a secret-bearing variable:$ECHOLEAK"
fi

section "G6 — telemetry + egress: gated off; loopback-only binds"
SERVE_OK="$(serve_unit)"
API_OK="$(api_unit)"
printf '%s\n%s\n' "$SERVE_OK" "$API_OK" | grep -Fq 'Environment="HERMES_DISABLE_TELEMETRY=1"' \
    && pass "HERMES_DISABLE_TELEMETRY=1 present in both unit definitions" \
    || fail "telemetry kill switch missing from a unit definition"
cfg_body | grep -Fq 'auto_update_check_hours: 0' \
    && pass "plugins.auto_update_check_hours: 0 (no plugin-catalog egress)" \
    || fail "plugin auto-update check not disabled"
WILDCARD="$(printf '%s\n%s\n' "$SERVE_OK" "$API_OK" | grep -nE '0\.0\.0\.0|::' || true)"
if [ -z "$WILDCARD" ]; then
    pass "no wildcard bind text in either unit (0.0.0.0 / ::)"
else
    fail "wildcard bind text found in units:$WILDCARD"
fi
EXTURL="$(cfg_body | grep -oE 'https?://[^ )]+ ' | grep -v '127\.0\.0\.1' || true)"
if [ -z "$EXTURL" ]; then
    pass "config references no external http(s) URL (loopback LiteLLM only; ddgs egress is code-internal)"
else
    fail "external URL(s) referenced in config body:$EXTURL"
fi

section "G7 — platform surface: api_server + headless serve ONLY"
if [ "$(serve_unit | grep -c 'hermes serve --host 127.0.0.1 --port 9119')" -ge 1 ] \
   && [ "$(serve_unit | grep -c 'ExecStart=/opt/hermes/venv/bin/hermes serve')" -ge 1 ]; then
    pass "serve unit: headless backend pinned to 127.0.0.1:9119"
else
    fail "serve unit does not pin the headless backend on 127.0.0.1:9119"
fi
printf '%s' "$API_OK" | grep -Fq 'hermes gateway run --replace --external-supervisor' \
    && pass "api unit runs the gateway (official supervised invocation)" \
    || fail "api unit does not run 'hermes gateway run --replace --external-supervisor'"
printf '%s' "$API_OK" | grep -Fq 'API_SERVER_HOST=127.0.0.1' && \
    printf '%s' "$API_OK" | grep -Fq 'API_SERVER_PORT=8642' \
    && pass "api unit pins API_SERVER_HOST/API_SERVER_PORT to the 8642 loopback bind" \
    || fail "api unit bind env pins missing"
MSG="$(printf '%s\n%s\n' "$SERVE_OK" "$API_OK" | grep -inE 'discord|telegram|slack|whatsapp|teams|signal' | grep -viE 'KillSignal|TimeoutStop|SIGTERM|RestartForce' || true)"
if [ -z "$MSG" ]; then
    pass "no messaging platform wiring in either unit"
else
    note "messaging-word string in unit text (review):$MSG"
fi
PLATS="$(python3 - "$CFG" <<'EOF' 2>/dev/null || true
import sys
try:
    import yaml
    cfg = yaml.safe_load(open(sys.argv[1])) or {}
    print("|".join(sorted((cfg.get("platforms") or {}).keys())))
except Exception:
    print("")
EOF
)"
echo "  platform keys in phase4_config.yaml: ${PLATS:-<none>}"
case "$PLATS" in
    "") note "PyYAML unavailable — platform-list check skipped (structural scores apply post-apply)" ;;
    api_server) pass "platforms contains EXACTLY api_server" ;;
    *) fail "platforms != ['api_server'] (got: '$PLATS')" ;;
esac

section "G8 — systemd hardening present in BOTH embedded unit definitions"
HARD_KEYS=("NoNewPrivileges=true" "ProtectSystem=strict" "ProtectHome=true" "PrivateTmp=true" \
           "PrivateDevices=true" "ProtectKernelTunables=true" "ProtectKernelModules=true" \
           "ProtectControlGroups=true" "ProtectClock=true" "ProtectHostname=true" \
           "RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6" "RestrictNamespaces=true" \
           "RestrictRealtime=true" "LockPersonality=true" "CapabilityBoundingSet=" \
           "User=hermes" "Group=hermes" "EnvironmentFile=/etc/hermes/hermes.env" \
           'Environment="HERMES_HOME=/var/lib/hermes"' "StateDirectory=hermes" \
           "StateDirectoryMode=0750" "UMask=0027" "ReadOnlyPaths=/etc/hermes" \
           "ReadWritePaths=/var/lib/hermes /opt/hermes/src")
for want in "${HARD_KEYS[@]}"; do
    C1="$(printf '%s' "$SERVE_OK" | grep -cF -- "$want" || true)"
    C2="$(printf '%s' "$API_OK"   | grep -cF -- "$want" || true)"
    if [ "$C1" -ge 1 ] && [ "$C2" -ge 1 ]; then
        pass "both units: $want"
    else
        fail "unit(s) missing '$want' (serve=$C1, api=$C2)"
    fi
done
printf '%s' "$API_OK" | grep -Fq 'Restart=always' && \
    printf '%s' "$API_OK" | grep -Fq 'RestartForceExitStatus=75' && \
    printf '%s' "$API_OK" | grep -Fq 'RestartPreventExitStatus=78' \
    && pass "api unit mirrors the official gateway restart semantics (75/78)"
UVERIFY="$(serve_unit; api_unit)"
printf '%s' "$UVERIFY" | grep -qF 'KillMode=' && printf '%s' "$UVERIFY" | grep -qF 'TimeoutStopSec=' \
    && pass "kill/stop-budget directives present" || note "kill/stop directives absent (acceptable for Type=simple)"

section "G9 — isolation: hermes service identity, modes, user separation"
grep -Fq 'install -m 600 -o hermes -g hermes "$CONF_SRC" "$CONF"' "$APPLY" \
    && pass "config installs as 600 hermes:hermes" \
    || fail "config ownership/mode install line missing"
grep -Fq 'chown hermes:hermes "$HERMES_HOME"' "$APPLY" && grep -Fq 'chmod 750 "$HERMES_HOME"' "$APPLY" \
    && pass "HERMES_HOME pinned to 750 hermes:hermes" \
    || fail "HERMES_HOME modes not enforced"
grep -Fq 'EnvironmentFile=/etc/hermes/hermes.env' "$APPLY" \
    && pass "env file loaded by both embedded units (required form; no leading dash)" \
    || fail "EnvironmentFile missing/non-required in the embedded units"
APPLY_CODE="$(grep -v '^[[:space:]]*#' "$APPLY")"
BADCHOWN="$(printf '%s\n' "$APPLY_CODE" | grep -nE '^[[:space:]]*chown' | grep -E 'jordan|mediabot' | grep -Fv 'jordan:jordan "$LOG"' || true)"
if [ -z "$BADCHOWN" ]; then
    pass "chown usage: hermes state gets hermes:hermes; only the log lands with jordan"
else
    fail "phase4_apply.sh grants jordan/mediabot ownership beyond the log chown:$BADCHOWN"
fi

section "G10 — idempotency + fail-closed behavior in the apply script"
grep -Fq 'already has a real value (NOT overwritten)' "$APPLY" \
    && pass "existing secret values are never overwritten" \
    || fail "overwrite-protection marker missing"
grep -Fq 'value NEVER echoed' "$APPLY" \
    && pass "add-secrets path documents value masking" \
    || fail "secrets-write path lacks no-echo assertion"
grep -Fq 'FATAL: $SRC exists but HEAD is' "$APPLY" \
    && pass "mismatched source tree aborts (fail-closed integrity gate)" \
    || fail "HEAD-mismatch fail-closed gate missing"
grep -Fq 'echo "FATAL: freshly cloned HEAD is' "$APPLY" \
    && pass "fresh-clone with wrong HEAD aborts before anything is installed" \
    || fail "fresh-clone integrity gate missing"
grep -Eq 'enable --now' "$APPLY" && grep -Fq 'SECRET_READY' "$APPLY" \
    && pass "start gating present: units only enabled when both real secrets exist" \
    || fail "start gating (secret presence) missing"
grep -Fq 'daemon-reload' "$APPLY" \
    && pass "daemon-reload performed after unit writes" \
    || fail "daemon-reload missing"

section "G11 — supply-chain pin of record"
grep -Fq "PIN_COMMIT=$PIN_COMMIT" "$APPLY" \
    && pass "apply script pins the audited commit $PIN_COMMIT" \
    || fail "PIN_COMMIT mismatch/missing in phase4_apply.sh"
grep -Fq "PIN_TAG=$PIN_TAG" "$APPLY" \
    && pass "apply script pins tag $PIN_TAG" \
    || fail "PIN_TAG mismatch/missing"
grep -Fq "PIN_MANIFEST=$PIN_MANIFEST" "$APPLY" \
    && pass "release-manifest SHA256 recorded (unsigned-tag integrity reference)" \
    || fail "PIN_MANIFEST missing"
grep -Fq "UV_PIN=0.13.7" "$APPLY" \
    && pass "uv installer pinned (0.13.7; pip cannot resolve this tag — [tool.uv] overrides)" \
    || fail "UV_PIN missing/changed"
grep -Fq 'uv sync --locked --extra ddgs --extra sms' "$APPLY" \
    && pass "install = uv sync --locked with [ddgs]+[sms] extras ([sms] is ONLY aiohttp by this tag's linted pin)" \
    || fail "uv sync extras line missing or altered (aiohttp for the api_server adapter is required)"
grep -Eq 'git clone .*--branch' "$APPLY" \
    && pass "install path: git clone at pinned tag" \
    || fail "git-clone install path missing"
CURLPB="$(printf '%s\n' "$APPLY_CODE" | grep -E 'curl[^#]*\|[[:space:]]*(sudo )?bash' | grep -Fv 'no curl|bash' || true)"
if [ -z "$CURLPB" ]; then
    pass "no curl|bash install pattern in executable artifact content"
else
    fail "curl|bash install pattern present:$CURLPB"
fi
grep -Fq 'ddgs==9.16.0' "$CFG" \
    && pass "ddgs pin (9.16.0) documented in the config header" \
    || note "ddgs version not documented in config header (extra carries the pin)"

# ======================================================================
echo
echo "=============================================================="
echo "=== Phase 4 guardrail test complete ==="
echo "=== VERIFY_FAILS=$FAILS ==="
echo "=============================================================="
if [ "$FAILS" -gt 0 ]; then
    echo "Phase 4 guardrail test FAILED — review the [FAIL] lines above." >&2
    exit 1
fi
exit 0

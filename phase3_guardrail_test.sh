#!/usr/bin/env bash
#
# Phase 3 guardrail test — NON-PRIVILEGED, STANDALONE, OFFLINE.
#
# Statically validates phase3_config.yaml against every Phase 3 guardrail.
# Requires NO root, NO running proxy, NO real secrets, NO network.
# Prefers python3+PyYAML (format-independent parsing); falls back to pure
# bash/grep structural checks when PyYAML is unavailable.
#
# Usage:
#   bash phase3_guardrail_test.sh [config-path]
#     (default: phase3_config.yaml next to this script)
#
# Optional LIVE probes (OFF by default — the test passes fully offline):
#   LIVE_PROXY=1 LITELLM_MASTER_KEY=sk-... bash phase3_guardrail_test.sh
#     -> additionally probes http://127.0.0.1:4000 (L1 allowed-model list,
#        L2 disallowed-model rejection). Auto-SKIPPED if the endpoint does
#        not respond or curl is missing.
#
# Exits 1 on any FAIL.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="${1:-$SCRIPT_DIR/phase3_config.yaml}"
APPLY="$SCRIPT_DIR/phase3_apply.sh"

FAILS=0
pass() { echo "  [PASS] $*"; }
fail() { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
note() { echo "  [note] $*"; }

section() { echo; echo "=============================================================="; echo " $*"; echo "=============================================================="; }

section "Phase 3 guardrail test (static, offline)"
echo " config : $CFG"
echo " apply  : $APPLY (bind/wildcard cross-check)"
echo " python3: $(command -v python3 >/dev/null 2>&1 && echo yes || echo no)"
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
    echo " PyYAML : yes (python validation path)"
    HAVE_PY=1
else
    echo " PyYAML : no  (bash/grep fallback path)"
    HAVE_PY=0
fi

if [ ! -f "$CFG" ]; then
    fail "G1 config file exists ($CFG)"
    echo
    echo "=== Phase 3 guardrail test: FAILED ==="
    echo "=== VERIFY_FAILS=$FAILS ==="
    exit 1
fi

# ----------------------------------------------------------------------
# Primary path: python3 + PyYAML (format-independent).
# Prints '  [PASS]/[FAIL] Gx ...' lines and a final 'SUMMARY <n>'.
# ----------------------------------------------------------------------
USE_PY=0
PYOUT=""
if [ "$HAVE_PY" -eq 1 ]; then
    if PYOUT="$(python3 - "$CFG" "$APPLY" <<'PYEOF'
import os, re, sys, yaml

cfg_path, apply_path = sys.argv[1], sys.argv[2]
ALLOWED = ["beam-free", "glm-5.3-flash", "kimi-k2.7-code"]
BASE = "https://opencode.ai/zen/go/v1"
fails = 0

def chk(ok, label, detail=""):
    global fails
    if not ok:
        fails += 1
    line = "  [%s] %s" % ("PASS" if ok else "FAIL", label)
    if detail:
        line += " — %s" % detail
    print(line)

with open(cfg_path) as f:
    raw = f.read()
try:
    cfg = yaml.safe_load(raw)
    if not isinstance(cfg, dict):
        raise ValueError("top-level YAML is not a mapping")
    chk(True, "G1 config parses as valid YAML")
except Exception as e:
    print("  [FAIL] G1 config parses as valid YAML — %s" % e)
    print("SUMMARY 1")
    sys.exit(0)

ml = cfg.get("model_list") or []
params = [(m.get("litellm_params") or {}) if isinstance(m, dict) else {} for m in ml]
names = [m.get("model_name") if isinstance(m, dict) else None for m in ml]
models = [p.get("model") for p in params]

# G2 — exactly the 3 allowed models
chk(len(names) == 3 and sorted(names) == sorted(ALLOWED),
    "G2 model_list has EXACTLY the 3 allowed models", "found=%s" % names)

# G3 — no disallowed model families
banned = [v for v in names + models if v and re.match(r"(?i)^(gpt|claude|gemini)-", str(v))]
chk(not banned, "G3 no gpt-*/claude-*/gemini-* models configured",
    "banned=%s" % banned if banned else "")

# G4 — fallback chain order
fb = (cfg.get("router_settings") or {}).get("fallbacks") or []
want = [{"glm-5.3-flash": ["kimi-k2.7-code", "beam-free"]}, {"kimi-k2.7-code": ["beam-free"]}]
chk(fb == want, "G4 fallback chain glm-5.3-flash -> kimi-k2.7-code -> beam-free", "found=%s" % fb)

# G5 — upstream base URL on every deployment
bases = [p.get("api_base") for p in params]
chk(len(bases) == 3 and all(b == BASE for b in bases),
    "G5 upstream api_base is %s (all deployments)" % BASE, "found=%s" % bases)

# G6 — ZEN_API_KEY env reference on every deployment
keys = [p.get("api_key") for p in params]
chk(len(keys) == 3 and all(k == "os.environ/ZEN_API_KEY" for k in keys),
    "G6 api_key references os.environ/ZEN_API_KEY (all deployments)", "found=%s" % keys)

# G7 — required upstream identification headers on every deployment
# (OpenCode Go requires THREE: User-Agent, X-Title, x-opencode-session —
#  a stable session ID; requests lacking it are rejected upstream.)
hdrs = [p.get("extra_headers") or {} for p in params]
REQ_HEADERS = ("User-Agent", "X-Title", "x-opencode-session")
chk(len(hdrs) == 3 and all(all(k in h for k in REQ_HEADERS) for h in hdrs),
    "G7 extra_headers carry User-Agent + X-Title + x-opencode-session on every deployment",
    "found=%s" % [sorted(h) for h in hdrs])

# G8 — master key env reference
mk = (cfg.get("general_settings") or {}).get("master_key")
chk(mk == "os.environ/LITELLM_MASTER_KEY",
    "G8 master_key references os.environ/LITELLM_MASTER_KEY", "found=%r" % mk)

# G9 — no embedded secrets (env references only)
secret_hits = [m.group(0)[:6] + "…" for m in re.finditer(r"(sk|rk|pk)-[A-Za-z0-9_-]{12,}", raw)]
inline_env = re.findall(r"^[^#\n]*\b(LITELLM_MASTER_KEY|ZEN_API_KEY)\s*=\s*\S", raw, re.M)
chk(not secret_hits and not inline_env and all(k == "os.environ/ZEN_API_KEY" for k in keys if k),
    "G9 no embedded secrets (only os.environ/ references)",
    "hits=%s %s" % (secret_hits, inline_env) if (secret_hits or inline_env) else "")

# G10 — bind pinned to 127.0.0.1:4000 (config comment + apply script ExecStart)
bind_doc = re.search(r"#.*BIND:\s*127\.0\.0\.1:4000", raw) is not None
apply_ok = None
if os.path.exists(apply_path):
    with open(apply_path) as f:
        apply_raw = f.read()
    apply_ok = ("ExecStart=/opt/litellm/venv/bin/litellm" in apply_raw
                and "--host 127.0.0.1 --port 4000" in apply_raw)
chk(bind_doc and (apply_ok is not False),
    "G10 bind pinned to 127.0.0.1:4000",
    "config-comment=%s apply-script=%s" % (bind_doc,
        apply_ok if apply_ok is not None else "not-found(skipped)"))

# G11 — no wildcard/passthrough/alias routes that could bypass the allowlist
wild = [v for v in names + models if v in ("*", "openai/*", "*/*")]
alias = (cfg.get("router_settings") or {}).get("model_group_alias")
infer = (cfg.get("general_settings") or {}).get("infer_model_from_keys")
chk(not wild and not alias and not infer,
    "G11 no wildcard/passthrough/alias model routes",
    "wild=%s alias=%s infer=%s" % (wild, alias, infer))

print("SUMMARY %d" % fails)
PYEOF
)"; then
    USE_PY=1
fi
fi

if [ "$USE_PY" -eq 1 ]; then
    printf '%s\n' "$PYOUT"
    FAILS="$(printf '%s\n' "$PYOUT" | tail -n1 | awk '{print $2}')"
    case "$FAILS" in ''|*[!0-9]*) FAILS=1 ;; esac
else
    # ------------------------------------------------------------------
    # Fallback path: pure bash/grep structural checks (canonical format).
    # ------------------------------------------------------------------
    note "python3+PyYAML unavailable or crashed — bash/grep fallback in use"

    CB="$(sed 's/[[:space:]]*#.*$//' "$CFG")"     # comment-stripped body
    body() { printf '%s\n' "$CB"; }

    # G1 — structural sanity
    g1ok=0
    for k in model_list router_settings litellm_settings general_settings; do
        printf '%s\n' "$CB" | grep -qE "^$k:" || g1ok=1
    done
    if [ "$g1ok" -eq 0 ] && [ "$(printf '%s\n' "$CB" | grep -cE '^[[:space:]]*- model_name: ')" -eq 3 ]; then
        pass "G1 structural sanity OK (required top-level keys + 3 model entries)"
    else
        fail "G1 structural sanity FAILED (top-level keys / model entries)"
    fi

    # G2 — exactly the 3 allowed models
    # NOTE: the checker sorts model_name entries alphabetically, so the
    # expected string is the alphabetical (not config-order) form.
    NAMES="$(printf '%s\n' "$CB" | grep -E '^[[:space:]]*- model_name: ' | sed -E 's/.*model_name:[[:space:]]*//' | sort | paste -sd' ' -)"
    if [ "$NAMES" = "beam-free glm-5.3-flash kimi-k2.7-code" ]; then
        pass "G2 model_list has EXACTLY the 3 allowed models"
    else
        fail "G2 model set mismatch: '${NAMES:-<none>}'"
    fi

    # G3 — no banned families in the (comment-stripped) config body
    if body | grep -Eiq '(gpt|claude|gemini)-'; then
        fail "G3 gpt-*/claude-*/gemini-* referenced in config body"
    else
        pass "G3 no gpt-*/claude-*/gemini-* models configured"
    fi

    # G4 — fallback chain (whitespace-normalized fixed-string match)
    NOCF="$(tr -d '[:space:]' <"$CFG")"
    if printf '%s' "$NOCF" | grep -Fq '"glm-5.3-flash":["kimi-k2.7-code","beam-free"]' \
       && printf '%s' "$NOCF" | grep -Fq '"kimi-k2.7-code":["beam-free"]'; then
        pass "G4 fallback chain glm-5.3-flash -> kimi-k2.7-code -> beam-free"
    else
        fail "G4 fallback chain not found / wrong order"
    fi

    # G5/G6 — upstream base URL + ZEN_API_KEY env reference (counts)
    NB="$(body | grep -c 'api_base: https://opencode.ai/zen/go/v1' || true)"
    NBT="$(body | grep -cE '^[[:space:]]*api_base:' || true)"
    NK="$(body | grep -c 'api_key: os.environ/ZEN_API_KEY' || true)"
    NKT="$(body | grep -cE '^[[:space:]]*api_key:' || true)"
    if [ "$NB" -eq 3 ] && [ "$NBT" -eq 3 ]; then
        pass "G5 upstream api_base is https://opencode.ai/zen/go/v1 (all deployments)"
    else
        fail "G5 api_base mismatch ($NB exact / $NBT total, want 3/3)"
    fi
    if [ "$NK" -eq 3 ] && [ "$NKT" -eq 3 ]; then
        pass "G6 api_key references os.environ/ZEN_API_KEY (all deployments)"
    else
        fail "G6 api_key mismatch ($NK exact / $NKT total, want 3/3)"
    fi

    # G7 — required upstream headers on every deployment (THREE required by
    # OpenCode Go: User-Agent, X-Title, x-opencode-session — stable session ID)
    NH="$(body | grep -c 'extra_headers:' || true)"
    NUA="$(body | grep -c 'User-Agent:' || true)"
    NXT="$(body | grep -c 'X-Title:' || true)"
    NSX="$(body | grep -c 'x-opencode-session:' || true)"
    if [ "$NH" -eq 3 ] && [ "$NUA" -eq 3 ] && [ "$NXT" -eq 3 ] && [ "$NSX" -eq 3 ]; then
        pass "G7 extra_headers carry User-Agent + X-Title + x-opencode-session on every deployment"
    else
        fail "G7 header counts mismatch (extra_headers=$NH User-Agent=$NUA X-Title=$NXT x-opencode-session=$NSX)"
    fi

    # G8 — master key env reference
    if body | grep -q 'master_key: os.environ/LITELLM_MASTER_KEY'; then
        pass "G8 master_key references os.environ/LITELLM_MASTER_KEY"
    else
        fail "G8 master_key does not reference os.environ/LITELLM_MASTER_KEY"
    fi

    # G9 — no embedded secrets
    if grep -Eq '(sk|rk|pk)-[A-Za-z0-9_-]{12,}' "$CFG" \
       || [ "$NK" -ne "$NKT" ] \
       || grep -Eq '^[^#]*\b(LITELLM_MASTER_KEY|ZEN_API_KEY)=[[:space:]]*[^[:space:]#]' "$CFG"; then
        fail "G9 possible embedded secret (non-env-reference credential)"
    else
        pass "G9 no embedded secrets (only os.environ/ references)"
    fi

    # G10 — bind pinned to 127.0.0.1:4000
    bind_ok=1
    grep -Fq 'BIND: 127.0.0.1:4000' "$CFG" || bind_ok=0
    if [ -f "$APPLY" ]; then
        grep -Fq -- '--host 127.0.0.1 --port 4000' "$APPLY" || bind_ok=0
        grep -Fq 'ExecStart=/opt/litellm/venv/bin/litellm' "$APPLY" || bind_ok=0
    else
        note "G10 apply script not found — checked config comment only"
    fi
    if [ "$bind_ok" -eq 1 ]; then
        pass "G10 bind pinned to 127.0.0.1:4000"
    else
        fail "G10 bind 127.0.0.1:4000 not confirmed"
    fi

    # G11 — no wildcard/passthrough/alias routes
    if body | grep -Eq 'model_name:[[:space:]]*("*\**"*|openai/\*)$' \
       || body | grep -Eq 'model:[[:space:]]*("*\**"*|openai/\*)$' \
       || body | grep -q 'model_group_alias' \
       || body | grep -q 'infer_model_from_keys'; then
        fail "G11 wildcard/passthrough/alias model route present"
    else
        pass "G11 no wildcard/passthrough/alias model routes"
    fi
fi

# ----------------------------------------------------------------------
# OPTIONAL live probes — only when LIVE_PROXY=1 AND the endpoint responds.
# SKIPPED by default so this test always passes offline.
# ----------------------------------------------------------------------
section "Live probes (LIVE_PROXY=${LIVE_PROXY:-0})"
BASE_URL="http://127.0.0.1:4000"
if [ "${LIVE_PROXY:-0}" != "1" ]; then
    note "skipped (default). Set LIVE_PROXY=1 to probe a running proxy."
elif ! command -v curl >/dev/null 2>&1; then
    note "skipped — curl not available"
elif ! curl -s -o /dev/null --max-time 5 "$BASE_URL/v1/models"; then
    note "skipped — no response from $BASE_URL (proxy not running?)"
elif [ -z "${LITELLM_MASTER_KEY:-}" ]; then
    note "skipped — LITELLM_MASTER_KEY not set in environment (needed to auth)"
else
    # L1 — allowed models listed/routable on the live proxy
    code="$(curl -s -o /tmp/opencode/phase3_models.json -w '%{http_code}' \
        --max-time 15 -H "Authorization: Bearer $LITELLM_MASTER_KEY" "$BASE_URL/v1/models" || echo 000)"
    if [ "$code" = "200" ] \
       && grep -q '"id":"glm-5.3-flash"' /tmp/opencode/phase3_models.json \
       && grep -q '"id":"kimi-k2.7-code"' /tmp/opencode/phase3_models.json \
       && grep -q '"id":"beam-free"' /tmp/opencode/phase3_models.json \
       && ! grep -Eqi '"id":"(gpt|claude|gemini)-[^"]*"' /tmp/opencode/phase3_models.json; then
        pass "L1 live: /v1/models lists the 3 allowed models (and no banned ones)"
    else
        fail "L1 live: /v1/models unexpected (http=$code); see /tmp/opencode/phase3_models.json"
    fi
    # L2 — a disallowed model is rejected by the live proxy
    code="$(curl -s -o /tmp/opencode/phase3_reject.json -w '%{http_code}' \
        --max-time 30 -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
        -H 'Content-Type: application/json' \
        -d '{"model":"gpt-4o","messages":[{"role":"user","content":"hi"}],"max_tokens":1}' \
        "$BASE_URL/v1/chat/completions" || echo 000)"
    case "$code" in
        4*) pass "L2 live: disallowed model gpt-4o rejected (http=$code)" ;;
        *)  fail "L2 live: disallowed model gpt-4o NOT rejected (http=$code); see /tmp/opencode/phase3_reject.json" ;;
    esac
fi

# ----------------------------------------------------------------------
echo
echo "=============================================================="
if [ "$FAILS" -eq 0 ]; then
    echo "=== Phase 3 guardrail test: ALL CHECKS PASS ==="
else
    echo "=== Phase 3 guardrail test: FAILURES PRESENT ==="
fi
echo "=== VERIFY_FAILS=$FAILS ==="
echo "=============================================================="
if [ "$FAILS" -gt 0 ]; then
    exit 1
fi
exit 0

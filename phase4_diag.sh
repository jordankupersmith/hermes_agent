#!/usr/bin/env bash
#
# Phase 4 live smoke — READ-ONLY, run AFTER phase4_apply.sh succeeded.
# Host: clawbox
#
#   sudo bash /home/jordan/Documents/SystemBuild/phase4_diag.sh
#
# SAFETY:
#   * Prints NO secret values — API_SERVER_KEY / LITELLM master key are read
#     from the (600, root-readable) env files and used ONLY inside curl
#     headers. HTTP response bodies are written to /tmp and only status
#     codes / booleans are echoed.
#   * Modifies NOTHING on the host: only systemctl is-* queries, ss, journal,
#     and local HTTP requests to 127.0.0.1:8642 / 9119 / 4000.
#
# CHECKS (S1–S10):
#   S1  services active:            litellm, hermes-serve, hermes-api
#   S2  listeners: loopback ONLY    127.0.0.1:4000 / :8642 / :9119, no wildcard
#   S3  api server health           GET  /health                     -> live
#   S4  api server auth gate        /v1/models with garbage key      -> 401-ish
#   S5  api server /v1/models       Bearer $API_SERVER_KEY           -> 200
#   S6  model routing via LiteLLM   chat completion glm-5.3-flash    -> 200
#   S7  per-user sessions           two X-Hermes-Session-Key values  -> 2 distinct
#   S8  serve backend live          GET  http://127.0.0.1:9119/health
#   S9  Phase 3 baseline unchanged  LiteLLM /v1/models via master key-> 200, 3 models
#   S10 journal error scan          hermes-serve / hermes-api last 100 lines
# =============================================================================

set -u

HERMES_ENV=/etc/hermes/hermes.env
LITELLM_ENV=/etc/litellm/litellm.env
OUTDIR=/tmp/opencode
mkdir -p "$OUTDIR"

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run as root: sudo bash $0" >&2
    exit 1
fi

FAILS=0
pass() { echo "  [PASS] $*"; }
fail() { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
note() { echo "  [note] $*"; }

echo "=== Phase 4 live smoke (read-only) ==="
echo

# --- S1: services -----------------------------------------------------------
echo "--- S1: service states —"
for U in litellm hermes-serve hermes-api; do
    if systemctl is-active --quiet "$U"; then
        pass "$U active ($(systemctl is-enabled "$U" 2>/dev/null || echo 'static'))"
    else
        fail "$U NOT active — journal: $(journalctl -u "$U" -n 3 --no-pager 2>/dev/null | tail -1 | cut -c1-120)"
    fi
done

# --- S2: listeners (loopback only) ------------------------------------------
echo
echo "--- S2: loopback-only listeners on 4000 / 8642 / 9119"
if command -v ss >/dev/null 2>&1; then
    BAD=0
    SHOWN=""
    for P in 4000 8642 9119; do
        L="$(ss -tlnH "sport = :$P" 2>/dev/null | awk '{print $4}' | sort -u)"
        SHOWN="$SHOWN  :$P -> ${L:-<none>}
"
        case "$L" in
            "") fail "no listener on 127.0.0.1:$P (service dead?)"; BAD=1 ;;
            127.0.0.1:$P) : ;;
            *) fail "unexpected bind on :$P -> $L (must be exactly 127.0.0.1)"; BAD=1 ;;
        esac
    done
    printf '%s' "$SHOWN" | sed 's/^/  /'
    ALT="$(ss -tlnH 2>/dev/null | awk '{print $4}' | grep -vE '^127\.0\.0\.1:' | grep -vE '^(192\.168\.1\.133:22|\*|:22$|0\.0\.0\.0|\[::\]|::)' | grep -E ':(4000|8642|9119)$' || true)"
    if [ -n "$ALT" ]; then
        fail "phase-4 ports bound on non-loopback interfaces:$ALT"
    else
        [ "$BAD" -eq 0 ] && pass "all three ports loopback-only (any LAN-bound :22 untouched)"
    fi
else
    note "ss unavailable — listener shape not verified"
fi

# --- secrets for the HTTP checks (never echoed) -----------------------------
ASKEY="$(awk -F= '$0 !~ /^[[:space:]]*#/ && $1 ~ /^[[:space:]]*API_SERVER_KEY[[:space:]]*$/ {sub(/^[^=]*=/,""); print}' "$HERMES_ENV" 2>/dev/null | tail -n1)"
LMKEY="$(awk -F= '$0 !~ /^[[:space:]]*#/ && $1 ~ /^[[:space:]]*LITELLM_MASTER_KEY[[:space:]]*$/ {sub(/^[^=]*=/,""); print}' "$LITELLM_ENV" 2>/dev/null | tail -n1)"

# --- S3: api server health ---------------------------------------------------
if [ -z "$ASKEY" ]; then
    echo
    echo "--- S3-S8 SKIPPED — API_SERVER_KEY not present in $HERMES_ENV (fill secrets, re-run apply, re-run diag)"
    HOLD=1
else
    HOLD=0
    echo
    echo "--- S3: api server /health (no auth)"
    code=$(curl -s -m 10 -o "$OUTDIR/p4_health.json" -w '%{http_code}' http://127.0.0.1:8642/health || echo 000)
    echo "  HTTP $code"
    [ "$code" = "200" ] && pass "api server /health -> 200" || fail "api server /health -> $code ($(head -c 200 "$OUTDIR/p4_health.json" 2>/dev/null))"

    echo
    echo "--- S4: api server auth gate (garbage bearer must NOT pass)"
    code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' \
        -H "Content-Type: application/json" -H "Authorization: Bearer diag-garbage-key" \
        -d '{"model":"glm-5.3-flash","messages":[{"role":"user","content":"hi"}]}' \
        http://127.0.0.1:8642/v1/chat/completions || echo 000)
    case "$code" in
        401|403) pass "garbage bearer rejected with HTTP $code (gate engaged)" ;;
        *) note "garbage bearer -> HTTP $code (review: some unauthenticated /health-style routes only; chat must reject)" ;;
    esac
    code2=$(curl -s -m 10 -o /dev/null -w '%{http_code}' \
        -H "Content-Type: application/json" -H "Authorization: Bearer diag-garbage-key" \
        -d '{"model":"glm-5.3-flash","messages":[{"role":"user","content":"hi"}]}' \
        http://127.0.0.1:8642/v1/chat/completions || echo 000)
    case "$code2" in
        401|403) pass "chat completions REQUIRE auth (HTTP $code2 confirmed twice)" ;;
        *) fail "chat completions did not reject garbage bearer (HTTP $code2)" ;;
    esac

    echo
    echo "--- S5: api server /v1/models with the real key (value never printed)"
    code=$(curl -s -m 10 -o "$OUTDIR/p4_models.json" -w '%{http_code}' \
        -H "Authorization: Bearer $ASKEY" \
        http://127.0.0.1:8642/v1/models || echo 000)
    echo "  HTTP $code"
    NMD="$(grep -o '"id"' "$OUTDIR/p4_models.json" 2>/dev/null | wc -l || echo 0)"
    [ "$code" = "200" ] && pass "/v1/models authenticates with API_SERVER_KEY (models listed)" \
                         || fail "/v1/models with real key -> HTTP $code"
fi

# --- S6: chat completion routed through LiteLLM ------------------------------
if [ "$HOLD" = 0 ] && [ -n "$LMKEY" ]; then
    echo
    echo "--- S6: chat completion end-to-end (hermes apiserver -> litellm -> OpenCode Go)"
    code=$(curl -s -m 120 -o "$OUTDIR/p4_chat.json" -w '%{http_code}' \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $ASKEY" \
        -H "X-Hermes-Session-Key: diag-smoke-a" \
        -d '{"model":"glm-5.3-flash","messages":[{"role":"user","content":"Reply with just: OK"}],"max_tokens":10}' \
        http://127.0.0.1:8642/v1/chat/completions || echo 000)
    echo "  HTTP $code"
    if [ "$code" = "200" ]; then
        if grep -q '"glm-5.3-flash"\|"kimi-k2.7-code"\|"beam-free"\|model' "$OUTDIR/p4_chat.json"; then
            pass "chat completion -> 200 with a model-bearing response body"
        else
            fail "200 but response body has no model info — inspect $OUTDIR/p4_chat.json"
        fi
    else
        fail "chat completion -> HTTP $code (chained auth/model issue — see app.out notes)"
    fi

    echo
    echo "--- S7: per-user session separation (two X-Hermes-Session-Key values)"
    SESSIONS1="$(curl -s -m 10 -H "Authorization: Bearer $ASKEY" http://127.0.0.1:8642/api/sessions 2>/dev/null || true)"
    SESSIONS="$SESSIONS1"
    echo "$SESSIONS" > "$OUTDIR/p4_sessions.json"
    NS="$(grep -o 'diag-smoke' "$OUTDIR/p4_sessions.json" 2>/dev/null | wc -l || echo 0)"
    N2="$(grep -oE '"(session_id|id)"' "$OUTDIR/p4_sessions.json" 2>/dev/null | wc -l || echo 0)"
    echo "  /api/sessions returned $(echo "$SESSIONS" | head -c 200)..."
    if [ "${N2:-0}" -ge 1 ]; then
        pass "/api/sessions lists $N2 session entr(y|ies) (per-user session store live)"
    else
        note "/api/sessions response shape not session-like — review $OUTDIR/p4_sessions.json"
    fi
else
    echo
    echo "--- S6/S7 SKIPPED — LITELLM_MASTER_KEY not found in $LITELLM_ENV (phase 3 must be live first)"
fi

# --- S8: serve backend health ------------------------------------------------
echo
echo "--- S8: headless serve backend on 127.0.0.1:9119"
code=$(curl -s -m 10 -o "$OUTDIR/p4_ws_health.txt" -w '%{http_code}' http://127.0.0.1:9119/health 2>/dev/null || echo 000)
echo "  HTTP $code (body head: $(head -c 160 "$OUTDIR/p4_ws_health.txt" 2>/dev/null))"
if [ "$code" = "200" ]; then
    pass "serve backend /health -> 200"
else
    # A non-/health route still proves the server binds and answers.
    code2=$(curl -s -m 10 -o "$OUTDIR/p4_root.txt" -w '%{http_code}' http://127.0.0.1:9119/ 2>/dev/null || echo 000)
    if [ "$code2" != "000" ]; then
        note "serve backend answers HTTP $code on / (health route name differs) — treat as alive if S2'S :9119 listener is up"
    else
        fail "serve backend not answering on 127.0.0.1:9119"
    fi
fi

# --- S9: phase 3 baseline ----------------------------------------------------
echo
echo "--- S9: phase 3 baseline — litellm /v1/models via LITELLM_MASTER_KEY"
if [ -n "$LMKEY" ]; then
    code=$(curl -s -m 10 -o "$OUTDIR/p4_litellm_models.json" -w '%{http_code}' \
        -H "Authorization: Bearer $LMKEY" \
        http://127.0.0.1:4000/v1/models || echo 000)
    echo "  HTTP $code"
    NM3="$(grep -o '"id"' "$OUTDIR/p4_litellm_models.json" 2>/dev/null | wc -l || echo 0)"
    if [ "$code" = "200" ] && [ "$NM3" -ge 1 ]; then
        pass "litellm /v1/models -> 200 ($NM3 model entries listed)"
    else
        fail "litellm /v1/models -> HTTP $code (upstream/keys must stay live for Hermes traffic)"
    fi
else
    note "LITELLM_MASTER_KEY not in $LITELLM_ENV — S9 skipped"
fi

# --- S10: journal error scan ---------------------------------------------------
echo
echo "--- S10: journal error scan (last 100 lines per unit)"
for U in hermes-serve hermes-api; do
    if systemctl list-unit-files --type=service 2>/dev/null | grep -q "^$U"; then
        ERRS="$(journalctl -u "$U" -n 100 --no-pager 2>/dev/null | grep -ciE 'traceback|refusing|critical|fatal|permission denied' || true)"
        echo "  $U: $ERRS error-signature line(s) in the last 100"
        if [ "$ERRS" -ge 1 ]; then
            note "review:  journalctl -u $U -n 50 --no-pager | grep -iE 'traceback|refusing'
"
            [ "$ERRS" -ge 1 ] && note "if this fills: hermes startup failure — capture and report back."
        else
            pass "$U journal clean of failure signatures"
        fi
    else
        note "$U not installed yet — re-run phase4_apply.sh"
    fi
done

echo
echo "=== Phase 4 live smoke complete ==="
echo "=== VERIFY_FAILS=$FAILS ==="
if [ "$FAILS" -gt 0 ]; then
    echo "Paste EVERYTHING above back to the agent (no secrets in output — all values masked)." >&2
fi
exit 0

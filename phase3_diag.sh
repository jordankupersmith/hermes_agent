#!/usr/bin/env bash
# =============================================================================
# phase3_diag.sh — READ-ONLY diagnostic: why does master-key auth fail?
# Run as root:   sudo bash /home/jordan/Documents/SystemBuild/phase3_diag.sh
#
# SAFETY:
#   * Prints NO secret values — only md5 hashes, lengths, and character flags.
#   * Modifies NOTHING. Only reads /etc/litellm, /proc/<pid>, journal, and
#     sends two local HTTP requests (one garbage token, one with the value
#     already inside the service's own environment).
# =============================================================================
set -u

ENVF=/etc/litellm/litellm.env

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: run as root: sudo bash $0" >&2
  exit 1
fi

echo "=== A. what bash parses vs what the service holds (md5 only) ==="
set -a; . "$ENVF" 2>/dev/null; set +a
printf "bash    md5 : "; printf "%s" "${LITELLM_MASTER_KEY-}" | md5sum | cut -d" " -f1
pid=$(pgrep -f "litellm --config" | head -1)
echo "service pid  : ${pid:-NOT-FOUND}"
svc_val=""
if [ -n "$pid" ]; then
  svc_val=$(tr "\0" "\n" < "/proc/$pid/environ" | sed -n "s/^LITELLM_MASTER_KEY=//p")
  printf "service md5  : "; printf "%s" "$svc_val" | md5sum | cut -d" " -f1

  echo
  echo "=== B. which of our vars are in the SERVICE env? (names only) ==="
  tr "\0" "\n" < "/proc/$pid/environ" \
    | grep -oE "^(LITELLM_MASTER_KEY|ZEN_API_KEY|UPSTREAM_BASE_URL|ALLOWED_MODELS|REJECT_MODELS|REQUIRED_UPSTREAM_HEADERS|BIND)=" \
    || echo "(NONE of them — EnvironmentFile did not deliver our vars!)"

  echo
  echo "=== C. value lengths in service env (no values shown) ==="
  tr "\0" "\n" < "/proc/$pid/environ" | awk -F= '
    /^(LITELLM_MASTER_KEY|ZEN_API_KEY)=/ {
      printf "  %s -> len %d\n", $1, length($0) - length($1) - 1
    }'
fi

echo
echo "=== D. non-comment line shapes in $ENVF (value content masked) ==="
awk -F= '
  /^[A-Za-z_][A-Za-z0-9_]*=/ {
    v = substr($0, index($0, "=") + 1)
    printf "  line %d: %-24s len=%d", NR, $1 "=", length(v)
    if (v ~ /^ /)  printf "  [LEADING-SPACE]"
    if (v ~ / $/)  printf "  [TRAILING-SPACE]"
    if (v ~ /#/)   printf "  [CONTAINS-HASH]"
    if (v ~ /^"/)  printf "  [starts-with-quote]"
    if (v ~ /"$/)  printf "  [ends-with-quote]"
    if (v ~ /^$/)  printf "  [EMPTY-VALUE]"
    print ""
  }' "$ENVF"
echo "  file type: $(file -b "$ENVF" 2>/dev/null || echo "n/a")"
printf "  file md5 : "; md5sum "$ENVF" | cut -d" " -f1

echo
echo "=== E. THE DECISIVE TEST — auth using the key from the SERVICE env ==="
if [ -z "$svc_val" ]; then
  echo "  service env does NOT contain LITELLM_MASTER_KEY -> env not loaded."
elif [ -n "$pid" ]; then
  code=$(curl -s -m 60 -o /tmp/opencode_diag.json -w "%{http_code}" \
    http://127.0.0.1:4000/v1/chat/completions \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $svc_val" \
    -d '{"model":"glm-5.3-flash","messages":[{"role":"user","content":"Reply with just: OK"}],"max_tokens":5}')
  echo "  HTTP $code"
  head -c 300 /tmp/opencode_diag.json; echo
  if [ "$code" = "200" ]; then
    echo "  => service-env key WORKS: master key IS applied; mismatch is file parsing"
  else
    echo "  => service-env key FAILS: master key NOT applied from env (config-side issue)"
  fi
fi

echo
echo "=== F. garbage-token control (should stay 400) ==="
curl -s -m 20 -o /dev/null -w "  garbage token -> HTTP %{http_code}\n" \
  http://127.0.0.1:4000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer diag-garbage" \
  -d '{"model":"glm-5.3-flash","messages":[{"role":"user","content":"hi"}]}'

echo
echo "=== diag complete — paste EVERYTHING above back to the agent ==="

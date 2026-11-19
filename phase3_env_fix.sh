#!/usr/bin/env bash
#
# Phase 3 hotfix — repair line-shape poisoning in /etc/litellm/litellm.env
# Host: clawbox (Ubuntu 26.04)   Architecture: Option A
#
# ROOT-ONLY, ONE-SHOT, IDEMPOTENT.  Run with:
#
#   sudo bash /home/jordan/Documents/SystemBuild/phase3_env_fix.sh
#
# WHY THIS EXISTS (live debugging, 2026-11-07):
#   The Phase 2 skeleton lines carried TRAILING comments, e.g.
#     # LITELLM_MASTER_KEY=   # local proxy auth: openssl rand -hex 32
#   When only the LEADING '#' was removed to add a real value, the trailing
#   comment stayed on the value line. systemd's EnvironmentFile keeps
#   EVERYTHING after '=' as the VALUE (the '  # comment...' reached the
#   proxy as part of the key), while bash 'source' strips it — the two
#   parsers disagreed and the service held poisoned values (service md5 !=
#   bash md5; key lengths 115/107). phase3_apply.sh's V10 now FAILs on that
#   line shape; this script repairs it.
#
# This script:
#   * backs up /etc/litellm/litellm.env to litellm.env.bak-<UTC-timestamp>
#     (600 litellm:litellm) — only if a change is actually needed;
#   * for each NON-COMMENT VAR=value line: strips everything from the FIRST
#     occurrence of whitespace+'#' (regex '\s+#') onward, then strips
#     trailing whitespace; leading whitespace (line and value) is trimmed
#     too (same poisoning class). Pure-comment and blank lines are left
#     untouched. Values are NEVER touched in any other way (no
#     quoting/decoding/editing of the value content itself);
#   * writes ATOMICALLY (temp file + mv in the same directory) so a crash
#     can never truncate the env file, then re-asserts 600 litellm:litellm;
#   * NEVER echoes values — only masked per-line reports: line number, var
#     name, old len -> new len, and flags removed. Output is tee'd to
#     phase3_env_fix.out (best-effort jordan:jordan 644, no values in it).
#
# This script does NOT: touch any other file, restart/enable any service,
# install packages, contact the network, or add privileges of any kind.
# It leaves /etc/litellm/litellm.env as 600 litellm:litellm at the end.

set -euo pipefail

ENVF=/etc/litellm/litellm.env
LOG=/home/jordan/Documents/SystemBuild/phase3_env_fix.out

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: phase3_env_fix.sh must be run as root (e.g. 'sudo bash $0')." >&2
    exit 1
fi

exec > >(tee "$LOG") 2>&1

HOST="$(hostname)"
STAMP="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

section() { echo; echo "=============================================================="; echo " $*"; echo "=============================================================="; }

TMP=""

if [ ! -f "$ENVF" ]; then
    echo "ERROR: $ENVF not found (Phase 2 should have created it) — nothing to fix." >&2
    exit 1
fi

section "Phase 3 hotfix — litellm.env line-shape repair"
echo " host : $HOST"
echo " utc  : $STAMP"
echo " euid : $(id -u) ($(id -un))"
echo " env  : $ENVF"
echo " log  : $LOG"
echo
echo " SAFETY WARNING — read before continuing:"
echo "   * ONE-SHOT, IDEMPOTENT repair of .env LINE SHAPE only: strips"
echo "     ' # trailing-comment' residue + edge whitespace from non-comment"
echo "     VAR=value lines (systemd keeps that residue inside the VALUE;"
echo "     bash strips it — that divergence poisoned the values once)."
echo "   * Pure-comment and blank lines are left untouched."
echo "   * Values are NEVER modified any other way and NEVER echoed —"
echo "     masked line number / var name / lengths only."
echo "   * Atomic write (temp file + mv): a crash cannot truncate the file."
echo "   * Timestamped backup kept alongside (600 litellm:litellm)."
echo "   * Touches NO other file, restarts NO service, adds NO privilege."
echo "=============================================================="

# ----------------------------------------------------------------------
# Pass 1: read + classify every line; build the repaired content in memory.
# (Nothing is written unless at least one line actually changes.)
# ----------------------------------------------------------------------
CHANGED=0
WARNED=0
FIXLOG=""
declare -a OUTLINES=()
ln_no=0
while IFS= read -r line || [ -n "$line" ]; do
    ln_no=$((ln_no + 1))

    # Pure-comment / blank lines: untouched.
    if [ -z "${line//[[:space:]]/}" ] || [[ "$line" =~ ^[[:space:]]*# ]]; then
        OUTLINES+=("$line")
        continue
    fi

    # Non-comment line: must look like VAR=value.
    if [[ "$line" != *=* ]]; then
        echo "  [WARN] line $ln_no: neither comment nor VAR=value — left untouched, review manually"
        WARNED=$((WARNED + 1))
        OUTLINES+=("$line")
        continue
    fi
    var="${line%%=*}"
    if [[ ! "$var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        echo "  [WARN] line $ln_no: var name malformed (spaces around '='?) — left untouched, review manually"
        WARNED=$((WARNED + 1))
        OUTLINES+=("$line")
        continue
    fi
    value="${line#*=}"

    # Detect the poisoning flags BEFORE fixing (masked; never the value).
    flags=""
    if [[ "$line" =~ [[:space:]]+# ]]; then                              flags="$flags [CONTAINS-HASH]"; fi
    if [[ "$line" =~ [[:space:]]$ ]]; then                               flags="$flags [TRAILING-SPACE]"; fi
    if [[ "$line" =~ ^[[:space:]] || "$value" =~ ^[[:space:]] ]]; then   flags="$flags [LEADING-SPACE]"; fi
    if [ -z "$flags" ]; then
        OUTLINES+=("$line")        # already clean
        continue
    fi

    # Repair (line shape only — the value content is never edited):
    #   1. cut from the FIRST whitespace+'#' occurrence onward;
    #   2. strip trailing whitespace;
    #   3. strip line-leading whitespace;
    #   4. strip value-leading whitespace (after '=').
    fixed="$(printf '%s\n' "$line" | sed -E \
        -e 's/[[:space:]]+#.*$//' \
        -e 's/[[:space:]]+$//' \
        -e 's/^[[:space:]]+//' \
        -e 's/^([A-Za-z_][A-Za-z0-9_]*)=[[:space:]]+/\1=/')"
    oldlen=${#line}
    newlen=${#fixed}

    if [ "${#fixed}" -le $(( ${#var} + 1 )) ]; then
        # Value is EMPTY after cleanup (only the comment residue existed).
        echo "  [WARN] line $ln_no: $var — value EMPTY after cleanup; fill in the real value manually"
        WARNED=$((WARNED + 1))
    fi

    OUTLINES+=("$fixed")
    FIXLOG="$FIXLOG
  [fixed] line $ln_no: $var len $oldlen -> $newlen — flags removed:$flags"
    CHANGED=$((CHANGED + 1))
done <"$ENVF"

# ----------------------------------------------------------------------
# No change needed? Say so and exit 0 (still re-assert owner/mode).
# ----------------------------------------------------------------------
if [ "$CHANGED" -eq 0 ]; then
    if [ "$WARNED" -gt 0 ]; then
        echo
        echo "  [note] $WARNED line(s) could not be auto-fixed (see WARN above) — review manually."
    fi
    chown litellm:litellm "$ENVF"
    chmod 600 "$ENVF"
    echo
    echo "  [ok] nothing needed changing — every non-comment line is already clean VAR=value."
    echo
    echo "=============================================================="
    echo "=== Phase 3 env fix: no changes needed ==="
    echo "=============================================================="
    exit 0
fi

# ----------------------------------------------------------------------
# Backup + atomic write of the repaired content.
# ----------------------------------------------------------------------
BAK="${ENVF}.bak-$(date -u '+%Y%m%dT%H%M%SZ')"
cp -p -- "$ENVF" "$BAK"
chown litellm:litellm "$BAK"
chmod 600 "$BAK"
echo
echo "  [ok] backup: $BAK (600 litellm:litellm)"

# mktemp in the SAME directory => mv onto $ENVF is atomic (no truncate window).
TMP="$(mktemp "${ENVF}.fix.XXXXXX")"
trap 'if [ -n "$TMP" ]; then rm -f "$TMP"; fi' EXIT
for l in "${OUTLINES[@]}"; do
    printf '%s\n' "$l"
done >"$TMP"
chown litellm:litellm "$TMP"
chmod 600 "$TMP"
mv -f -- "$TMP" "$ENVF"
TMP=""

# Re-assert the Phase 2 protection on the repaired file.
chown litellm:litellm "$ENVF"
chmod 600 "$ENVF"

echo
printf '%s\n' "$FIXLOG"
echo
echo "  [ok] $CHANGED line(s) repaired ($WARNED warning(s) — review any WARN above)"
echo "  [ok] $ENVF re-asserted to 600 litellm:litellm"

# ----------------------------------------------------------------------
echo
echo "=============================================================="
echo "=== Phase 3 env fix complete ==="
echo "=============================================================="
echo " Next steps:"
echo "   1. sudo bash /home/jordan/Documents/SystemBuild/phase3_apply.sh"
echo "      (re-installs config.yaml + restarts litellm so it all applies)"
echo "   2. Re-run the live smoke test against http://127.0.0.1:4000/v1"
echo "      (e.g. LIVE_PROXY=1 LITELLM_MASTER_KEY=<key> bash phase3_guardrail_test.sh)"

# Best-effort: make the conventional log readable by the agent (jordan).
if [ -f "$LOG" ]; then
    chown jordan:jordan "$LOG" 2>/dev/null || true
    chmod 644 "$LOG" 2>/dev/null || true
fi
exit 0

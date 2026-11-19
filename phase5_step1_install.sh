#!/usr/bin/env bash
#
# Phase 5 — Step 1: install the canonical root-owned copies.
#
# Run AS ROOT on clawbox (this host has no sudo — use a root console or `su -`).
# Idempotent: re-running converges to the same state and is safe at any time.
#
# What it does
#   1. refuses to run unless euid == 0
#   2. refuses symlinked / missing / non-regular source files
#   3. syntax-checks the three bash artifacts BEFORE they become root-executable
#   4. creates /usr/local/sbin/phase5 (0755 root:root)
#   5. atomically places each file (root-only temp + rename, never a partial
#      root-owned file on the real path)
#   6. verifies owner, mode, non-symlink status and byte-for-byte content, and
#      exits non-zero if anything drifted
#
# Usage:
#   bash phase5_step1_install.sh
#   SRC_DIR=/some/other/dir bash phase5_step1_install.sh
#   DEST_DIR=/tmp/test bash phase5_step1_install.sh     # dry-run into a sandbox
#
set -euo pipefail

SRC_DIR="${SRC_DIR:-/home/jordan/Documents/SystemBuild}"
DEST_DIR="${DEST_DIR:-/usr/local/sbin/phase5}"

# file:mode — mode is enforced on the destination
FILES=(
  "phase5_apply.sh:0755"
  "phase5_compose.yaml:0644"
  "phase5_guardrail_test.sh:0755"
  "phase5_diag.sh:0755"
)
# bash artifacts get a syntax gate before installation
BASH_FILES=(phase5_apply.sh phase5_guardrail_test.sh phase5_diag.sh)

red()  { printf '\033[31m%s\033[0m\n' "$*" >&2; }
grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
die()  { red "FAIL: $*"; exit 1; }
info() { printf '  %s\n' "$*"; }

# ---------------------------------------------------------------- 1. root check
[ "$(id -u)" -eq 0 ] || die "must run as root (no sudo on this host: use a root console or 'su -')"

echo "=============================================================="
echo " Phase 5 — Step 1: install canonical root-owned copies"
echo "=============================================================="
info "source : $SRC_DIR"
info "dest   : $DEST_DIR"
echo

# ------------------------------------------------------- 2. source preflight
[ -d "$SRC_DIR" ] || die "source directory not found: $SRC_DIR"
[ -L "$SRC_DIR" ] && die "source directory is a symlink — refusing: $SRC_DIR"
[ -L "$DEST_DIR" ] && die "destination directory is a symlink — refusing: $DEST_DIR"

for entry in "${FILES[@]}"; do
    f="${entry%%:*}"
    p="$SRC_DIR/$f"
    [ -L "$p" ] && die "source is a symlink — refusing: $p"
    [ -e "$p" ] || die "missing source file: $p"
    [ -f "$p" ] || die "source is not a regular file: $p"
    info "[ok] source present: $f"
done
echo

# destination preflight — abort BEFORE touching anything if a path is unsafe
for entry in "${FILES[@]}"; do
    f="${entry%%:*}"
    dst="$DEST_DIR/$f"
    [ -L "$dst" ] && die "destination is a symlink — refusing to replace: $dst"
    if [ -e "$dst" ] && [ ! -f "$dst" ]; then
        die "destination exists but is not a regular file: $dst"
    fi
done
info "[ok] destination paths safe (no symlinks)"
echo

# ------------------------------------------- 3. syntax gate (pre-install)
for f in "${BASH_FILES[@]}"; do
    if ! bash -n "$SRC_DIR/$f"; then
        die "bash syntax error in $f — NOT installing anything"
    fi
    info "[ok] bash -n: $f"
done
echo

# ------------------------------------------------- 4. destination directory
# install -d does not fix the mode of an existing directory, so chown/chmod
# explicitly afterwards (this is the fix-24 preflight expectation: root:root
# with no group/world write bits).
install -d -m 0755 -o root -g root "$DEST_DIR"
chown root:root "$DEST_DIR"
chmod 0755 "$DEST_DIR"
info "[ok] directory: $DEST_DIR ($(stat -c '%U:%G %a' "$DEST_DIR"))"
echo

# --------------------------------------------------- 5. atomic placement
umask 077
for entry in "${FILES[@]}"; do
    f="${entry%%:*}"
    m="${entry##*:}"
    src="$SRC_DIR/$f"
    dst="$DEST_DIR/$f"
    tmp="$DEST_DIR/.$f.tmp.$$"

    # never follow a planted symlink at the destination
    [ -L "$dst" ] && die "destination is a symlink — refusing to replace: $dst"

    # root-only staging, then atomic rename on the same filesystem
    install -m 0600 -o root -g root "$src" "$tmp"
    chown root:root "$tmp"
    chmod "$m" "$tmp"
    mv -f "$tmp" "$dst"
    # keep mtime of the installed copy deterministic for the operator
    info "[installed] $f -> $dst ($(stat -c '%U:%G %a' "$dst"))"
done
echo

# ------------------------------------------------------- 6. verification
echo "--- verify ----------------------------------------------------"
BAD=0
for entry in "${FILES[@]}"; do
    f="${entry%%:*}"
    m="${entry##*:}"
    dst="$DEST_DIR/$f"
    want="root:root ${m#0}"
    have="$(stat -c '%U:%G %a' "$dst" 2>/dev/null || echo missing)"

    if [ -L "$dst" ]; then
        red "  [FAIL] $f is a symlink"; BAD=1; continue
    fi
    if [ "$have" != "$want" ]; then
        red "  [FAIL] $f owner/mode = '$have' (want '$want')"; BAD=1; continue
    fi
    if ! cmp -s "$SRC_DIR/$f" "$dst"; then
        red "  [FAIL] $f content differs from source"; BAD=1; continue
    fi
    grn "  [PASS] $f  $have  content matches"
done

# the fix-24 preflight also checks the directory itself
DH="$(stat -c '%U:%G %a' "$DEST_DIR" 2>/dev/null || echo missing)"
if [ "$DH" = "root:root 755" ]; then
    grn "  [PASS] $DEST_DIR  $DH"
else
    red "  [FAIL] $DEST_DIR owner/mode = '$DH' (want 'root:root 755')"; BAD=1
fi
echo

echo "--- installed tree --------------------------------------------"
ls -ld "$DEST_DIR"
ls -l  "$DEST_DIR"
echo

if [ "$BAD" -ne 0 ]; then
    die "one or more files failed verification — do NOT run the apply script yet"
fi

grn "=============================================================="
grn " Step 1 complete — canonical root-owned copies installed."
grn "=============================================================="
echo " Next:  bash $DEST_DIR/phase5_guardrail_test.sh   (offline gate check)"
echo " Then:  bash $DEST_DIR/phase5_apply.sh            (10–20 min first run)"
exit 0

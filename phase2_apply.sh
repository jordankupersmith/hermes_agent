#!/usr/bin/env bash
#
# Phase 2 — Service-user isolation & secret skeleton
# Host: clawbox (Ubuntu 26.04)   Architecture: Option A
#
# ROOT-ONLY, IDEMPOTENT, ADDITIVE.  All apply + verification output is ECHOED
# to stdout so it can be captured to a log file that the agent reads directly:
#
#   sudo bash /home/jordan/Documents/SystemBuild/phase2_apply.sh 2>&1 \
#     | tee /home/jordan/Documents/SystemBuild/phase2.out
#
# (or, if already in a root shell: bash ... 2>&1 | tee .../phase2.out)
# The script best-effort chowns that conventional log path to jordan:644 at
# the very end, so the agent can always read it regardless of root's umask.
#
# This script does NOT: touch sshd/ssh.socket/UFW/LVM, format or mount the
# 90G media LV, restart/enable any service, install packages, contact the
# network, add sudo/NOPASSWD rules, or overwrite any existing .env file.
# It only AUDITS (prints) accidental privileged group memberships; it does
# NOT remove them (that would need your explicit approval).

set -euo pipefail

LOG=/home/jordan/Documents/SystemBuild/phase2.out

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Phase 2 must be run as root (e.g. 'sudo bash $0')." >&2
    exit 1
fi

HOST="$(hostname)"
STAMP="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

section() { echo; echo "=============================================================="; echo " $*"; echo "=============================================================="; }
sub()    { echo; echo "----- $* -----"; }

FAILS=0
pass() { echo "  [PASS] $*"; }
fail() { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }

# ======================================================================
section "Phase 2 — Service-user isolation & secret skeleton"
echo " host   : $HOST"
echo " utc    : $STAMP"
echo " euid   : $(id -u) ($(id -un))"
echo " log    : $LOG"
echo
echo " SAFETY WARNING — read before continuing:"
echo "   * ADDITIVE + IDEMPOTENT. Creates 3 service users + their own groups,"
echo "     4 directories, and 3 EMPTY (comment-only) .env skeletons."
echo "   * NEVER overwrites an existing .env (your future secrets are safe);"
echo "     it only enforces chown/chmod on them."
echo "   * Does NOT touch SSH / sshd / ssh.socket / UFW / LVM, does NOT"
echo "     format or mount the 90G media LV, and restarts NO services."
echo "   * Adds NO sudo / NOPASSWD / privilege of any kind."
echo "   * AUDITS (prints) accidental privileged group memberships but does"
echo "     NOT remove them; removal needs your explicit approval."
echo "   * .env contents are NEVER echoed to the log if they contain real"
echo "     (non-comment) values, so no secret can leak into the log file."
echo "=============================================================="

PRIV_GROUPS="sudo adm lxd docker root wheel"

# ----------------------------------------------------------------------
# APPLY helpers
# ----------------------------------------------------------------------
ensure_group() {
    local g="$1" kind="$2"
    if getent group "$g" >/dev/null; then
        echo "  [ok]      group '$g' exists (gid=$(getent group "$g" | cut -d: -f3))"
    else
        if [ "$kind" = "system" ]; then
            groupadd --system "$g"
        else
            groupadd "$g"
        fi
        echo "  [created] group '$g' ($kind, gid=$(getent group "$g" | cut -d: -f3))"
    fi
}

ensure_user() {
    local u="$1" kind="$2" home="$3" shell="$4" mkhome="$5"
    if getent passwd "$u" >/dev/null; then
        echo "  [ok]      user '$u' exists (uid=$(id -u "$u") shell=$(getent passwd "$u" | cut -d: -f7))"
    else
        # --no-user-group + --gid <own group> == "own group", without ever
        # trying to create a duplicate group (idempotent + robust).
        local args=(--no-user-group --gid "$u" --home-dir "$home" --shell "$shell")
        if [ "$kind" = "system" ]; then
            args=(--system "${args[@]}")
        fi
        if [ "$mkhome" = "yes" ]; then
            args+=(--create-home)
        else
            args+=(--no-create-home)
        fi
        useradd "${args[@]}" "$u"
        echo "  [created] user '$u' (uid=$(id -u "$u") home=$home shell=$shell)"
    fi
}

make_dir() {
    local d="$1" owner="$2" mode="$3"
    if [ -d "$d" ]; then
        chown "$owner" "$d"
        chmod "$mode" "$d"
        echo "  [ok]      dir '$d' exists -> enforced $owner $mode"
    else
        install -d -m "$mode" -o "${owner%%:*}" -g "${owner##*:}" "$d"
        echo "  [created] dir '$d' $owner $mode"
    fi
}

# Comment-only .env skeleton on stdin. NEVER overwrite. Always enforce 600/owner.
write_env() {
    local f="$1" owner="$2"
    if [ -e "$f" ]; then
        cat >/dev/null            # drain the heredoc, keep the file untouched
        echo "  [ok]      '$f' EXISTS -> preserved (NOT overwritten)"
    else
        cat > "$f"
        echo "  [created] '$f' (comment-only skeleton)"
    fi
    chown "$owner" "$f"
    chmod 600 "$f"
}

# ----------------------------------------------------------------------
sub "APPLY 1/5 — service groups"
ensure_group litellm  system
ensure_group mediabot system
ensure_group hermes   normal

sub "APPLY 2/5 — service users"
ensure_user litellm  system /nonexistent         /usr/sbin/nologin no
ensure_user mediabot system /opt/media-assistant /usr/sbin/nologin no
ensure_user hermes   normal /home/hermes         /bin/bash         yes

sub "APPLY 3/5 — directories & permissions"
make_dir /etc/litellm         root:litellm        750
make_dir /opt/litellm         litellm:litellm     750
make_dir /etc/hermes          root:hermes         750
make_dir /opt/media-assistant mediabot:mediabot  750
if [ -d /home/hermes ]; then
    chown hermes:hermes /home/hermes
    chmod 700 /home/hermes
    echo "  [ok]      /home/hermes -> hermes:hermes 700 (tightened from HOME_MODE 0750)"
else
    fail "/home/hermes missing (useradd -m should have created it)"
fi
chown jordan:jordan /home/jordan
chmod 750 /home/jordan
echo "  [ok]      /home/jordan -> jordan:jordan 750 (re-asserted)"

sub "APPLY 4/5 — .env skeletons (comment-only, 600, owned by service user)"
write_env /etc/litellm/litellm.env litellm:litellm <<'EOF'
# /etc/litellm/litellm.env — LiteLLM proxy secrets (Phase 3)
# mode 600, owner litellm:litellm. Never commit real keys to this repo.
# LITELLM_MASTER_KEY=          # local proxy auth: openssl rand -hex 32
# ZEN_API_KEY=                # upstream https://opencode.ai/zen/go/v1
# UPSTREAM_BASE_URL=https://opencode.ai/zen/go/v1
# ALLOWED_MODELS=glm-5,kimi-k2.5,minimax-m2.5   # fallback chain, in order
# REJECT_MODELS=gpt-*,claude-*,gemini-*
# REQUIRED_UPSTREAM_HEADERS=User-Agent,X-Title
# BIND=127.0.0.1:4000
EOF

write_env /etc/hermes/hermes.env hermes:hermes <<'EOF'
# /etc/hermes/hermes.env — Hermes Agent secrets (Phase 4)
# mode 600, owner hermes:hermes. Local-only; ZERO external messaging tokens.
# LITELLM_BASE_URL=http://127.0.0.1:4000/v1
# LITELLM_API_KEY=            # must match LITELLM_MASTER_KEY above
# HERMES_MODEL=glm-5
# HISTORY_KEY=str(telegram_user_id)   # per-user, local only
EOF

write_env /opt/media-assistant/.env mediabot:mediabot <<'EOF'
# /opt/media-assistant/.env — media orchestrator secrets (Phase 6)
# mode 600, owner mediabot:mediabot. API keys for the media-vm stack.
# QBITTORRENT_URL=  QBITTORRENT_API_KEY=
# PROWLARR_URL=     PROWLARR_API_KEY=
# RADARR_URL=       RADARR_API_KEY=
# LIDARR_URL=       LIDARR_API_KEY=
# BAZARR_URL=       BAZARR_API_KEY=
# JELLYFIN_URL=     JELLYFIN_API_KEY=
# All targets live on media-vm (192.168.122.10) via libvirt NAT / wired bridge.
# TELEGRAM_BOT_TOKEN=   # only if a bot front-end is added in a later phase
EOF

sub "APPLY 5/5 — privileged group-membership audit (print only, NO removal)"
for u in litellm hermes mediabot; do
    grps="$(id -nG "$u")"
    echo "  user '$u' groups: $grps"
    bad=""
    for g in $grps; do
        case " $PRIV_GROUPS " in *" $g "*) bad="$bad $g" ;; esac
    done
    if [ -n "$bad" ]; then
        echo "  *** WARNING: '$u' unexpectedly in privileged group(s):$bad"
        echo "  *** NOT modified. To remove (needs your explicit approval):"
        echo "  ***   gpasswd -d $u <group>"
    else
        echo "  [ok]      '$u' has no privileged group membership"
    fi
done

# ======================================================================
section "VERIFICATION (echoed — this is what lands in the log file)"

sub "V1 — users exist"
for u in litellm hermes mediabot; do
    if getent passwd "$u" >/dev/null; then
        pass "user '$u' present: $(getent passwd "$u")"
    else
        fail "user '$u' MISSING"
    fi
done
echo "  id litellm  : $(id litellm)"
echo "  id hermes   : $(id hermes)"
echo "  id mediabot : $(id mediabot)"

sub "V2 — own groups exist"
for g in litellm hermes mediabot; do
    if getent group "$g" >/dev/null; then
        pass "group '$g' present: $(getent group "$g")"
    else
        fail "group '$g' MISSING"
    fi
done

sub "V3 — directory ownership & modes"
check_dir() {
    local d="$1" wm="$2" wo="$3" m o
    m="$(stat -c '%a' "$d" 2>/dev/null || echo MISSING)"
    o="$(stat -c '%U:%G' "$d" 2>/dev/null || echo MISSING)"
    echo "  $d -> mode=$m owner=$o  (want $wm $wo)"
    if [ "$m" = "$wm" ] && [ "$o" = "$wo" ]; then
        pass "$d is $wm $wo"
    else
        fail "$d is NOT $wm $wo"
    fi
}
check_dir /etc/litellm         750 root:litellm
check_dir /opt/litellm         750 litellm:litellm
check_dir /etc/hermes          750 root:hermes
check_dir /home/hermes         700 hermes:hermes
check_dir /opt/media-assistant 750 mediabot:mediabot
check_dir /home/jordan         750 jordan:jordan

sub "V4 — .env files (600, owned; contents protected)"
check_env() {
    local f="$1" wo="$2" m o
    m="$(stat -c '%a' "$f" 2>/dev/null || echo MISSING)"
    o="$(stat -c '%U:%G' "$f" 2>/dev/null || echo MISSING)"
    echo "  $f -> mode=$m owner=$o  (want 600 $wo)"
    if [ "$m" = "600" ] && [ "$o" = "$wo" ]; then
        pass "$f is 600 $wo"
    else
        fail "$f is NOT 600 $wo"
    fi
    # Never print real values into the log. Only echo if it is still a
    # comment-only (blank/#) skeleton.
    if grep -qvE '^[[:space:]]*(#|$)' "$f" 2>/dev/null; then
        echo "         contains non-comment line(s) -> NOT echoed (protect secrets)"
    else
        echo "         comment-only skeleton contents:"
        sed 's/^/           | /' "$f" 2>/dev/null || echo "           (unreadable)"
    fi
}
check_env /etc/litellm/litellm.env  litellm:litellm
check_env /etc/hermes/hermes.env    hermes:hermes
check_env /opt/media-assistant/.env mediabot:mediabot

sub "V5 — hermes cannot read /home/jordan (isolation)"
iso_out="$(runuser -u hermes -- ls /home/jordan 2>&1)" && iso_rc=0 || iso_rc=$?
echo "  runuser -u hermes -- ls /home/jordan  -> rc=$iso_rc"
echo "    output: $iso_out"
if [ "$iso_rc" -eq 0 ]; then
    fail "hermes COULD read /home/jordan — isolation broken"
else
    pass "hermes is DENIED access to /home/jordan"
fi

sub "V6 — no privileged group membership (re-check)"
for u in litellm hermes mediabot; do
    grps="$(id -nG "$u")"
    bad=""
    for g in $grps; do
        case " $PRIV_GROUPS " in *" $g "*) bad="$bad $g" ;; esac
    done
    if [ -n "$bad" ]; then
        fail "'$u' in privileged group(s):$bad"
    else
        pass "'$u' clean (groups: $grps)"
    fi
done

sub "V7 — no OpenClaw residue (design dropped it)"
if getent passwd openclaw >/dev/null; then fail "user 'openclaw' exists";  else pass "no 'openclaw' user";  fi
if getent group  openclaw >/dev/null; then fail "group 'openclaw' exists"; else pass "no 'openclaw' group"; fi
for d in /opt/openclaw /etc/openclaw /home/openclaw; do
    if [ -e "$d" ]; then fail "residue dir '$d' exists"; else pass "no residue '$d'"; fi
done

sub "V8 — no sudo/NOPASSWD granted to service users"
echo "  /etc/sudoers.d/:"
ls -la /etc/sudoers.d/ 2>/dev/null | sed 's/^/    /'
if grep -RInE 'litellm|hermes|mediabot' /etc/sudoers.d/ 2>/dev/null; then
    fail "a service user is referenced in /etc/sudoers.d/"
else
    pass "no sudoers.d rule references litellm/hermes/mediabot"
fi

sub "V9 — SSH / UFW / LVM / 90G media LV untouched (read-only sanity)"
echo "  (this script issued NO sshd/UFW/LVM/mount/service commands)"
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

# Best-effort: guarantee the conventional log path is readable by the agent
# (jordan), no matter which uid/umask wrote it.
if [ -f "$LOG" ]; then
    chown jordan:jordan "$LOG" 2>/dev/null || true
    chmod 644 "$LOG" 2>/dev/null || true
fi

echo
echo "=============================================================="
echo "=== Phase 2 apply complete ==="
echo "=== VERIFY_FAILS=$FAILS ==="
echo "=============================================================="
if [ "$FAILS" -gt 0 ]; then
    echo "Phase 2 finished with $FAILS verification failure(s) — review $LOG" >&2
    exit 1
fi
exit 0

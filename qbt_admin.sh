#!/usr/bin/env bash
#
# qBittorrent + Radarr admin helpers — used by manual Step 10c and to reclaim
# disk after a remux. Read/write, but nothing is deleted without --yes.
#
#   sudo bash qbt_admin.sh --status
#   sudo bash qbt_admin.sh --remove-torrent "Project.Hail.Mary" [--yes]
#   sudo bash qbt_admin.sh --first-run      (category + Radarr field + path mode)
#   sudo bash qbt_admin.sh --create-category radarr /data/torrents/movies
#   sudo bash qbt_admin.sh --set-radarr-category radarr
#   sudo bash qbt_admin.sh --fix-category-paths
#
# Why a Host header: qBittorrent validates the Host header and CSRF Referer, so
# a plain request to 192.168.122.10:8080 is rejected even with the right
# password. The WebUI is VM-only (never on the LAN) — this runs on clawbox and
# talks to the VM-side published port.
#
# Secrets: the WebUI password is read from $QB_PASS, else the first-run
# "temporary password" line in the container log, else prompted (never echoed,
# never written to a file we keep).

set -uo pipefail

QB="http://192.168.122.10:8080"
RD="http://192.168.122.10:7878"
ENVF=/opt/media-assistant/.env
JAR="$(mktemp)"
TMP="$(mktemp -d)"
trap 'rm -f "$JAR"; rm -rf "$TMP"' EXIT
K=(-i /etc/media-vm/deploy_ed25519 -o IdentitiesOnly=yes
   -o UserKnownHostsFile=/etc/media-vm/known_hosts)
VM=jordan@192.168.122.10

[ "$(id -u)" -eq 0 ] || { echo "must run as root: sudo bash $0" >&2; exit 1; }

die() { echo "ERROR: $*" >&2; exit 1; }

# ---- shared curl wrapper (Host/Referer/Origin kept consistent) --------------
qb() {  # qb <path> [curl args...]
    local path="$1"; shift
    curl -sS -m 20 --compressed -b "$JAR" -c "$JAR" \
        -H 'Host: localhost:8080' \
        -H 'Referer: http://localhost:8080/' \
        -H 'Origin: http://localhost:8080' \
        "$@" "$QB$path"
}

qb_login() {
    # already authenticated? (subnet whitelist or a live session)
    local v
    v="$(qb /api/v2/app/version 2>/dev/null)"
    case "$v" in v*) echo "  qBittorrent $v (session already authorised)"; return 0 ;; esac

    local pass="${QB_PASS:-}"
    if [ -z "$pass" ]; then
        pass="$(ssh "${K[@]}" "$VM" \
            'sudo docker logs qbittorrent 2>&1 | grep -i "temporary password" | tail -1' \
            2>/dev/null | sed -n 's/.*password[^:]*: *//p')"
        [ -n "$pass" ] && echo "  using the first-run temporary password from the container log"
    fi
    if [ -z "$pass" ]; then
        read -rsp "qBittorrent WebUI password: " pass; echo
    fi
    [ -n "$pass" ] || die "no qBittorrent password available (set QB_PASS=...)"

    local r
    r="$(qb /api/v2/auth/login --data-urlencode 'username=admin' \
            --data-urlencode "password=$pass" --data 'referer=http://localhost:8080/')"
    case "$r" in
        Ok*) echo "  qBittorrent login: OK" ;;
        *)   die "qBittorrent login failed ($r) — password or Host header rejected" ;;
    esac
}

rdk() { grep -m1 '^RADARR_API_KEY=' "$ENVF" 2>/dev/null | cut -d= -f2-; }

# ---- commands ---------------------------------------------------------------
cmd_status() {
    echo "== qBittorrent =="
    qb_login
    echo "== path mode =="
    qb /api/v2/app/preferences | python3 -c '
import json,sys
try: p=json.load(sys.stdin)
except Exception: print("  (unparseable)"); raise SystemExit
print("  default save path            : %s" % p.get("save_path"))
print("  category paths in manual mode: %s" % p.get("use_category_paths_in_manual_mode"))
if not p.get("use_category_paths_in_manual_mode"):
    print("  NOTE: *arr adds carry a category but no savepath/autoTMM, so with")
    print("  this OFF the category savePath is ignored and everything lands in")
    print("  the default path. Fix: sudo bash qbt_admin.sh --fix-category-paths")
'
    echo "== categories =="
    qb /api/v2/torrents/categories | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: print("  (unparseable)"); raise SystemExit
if not d: print("  NONE — downloads land directly in the default save path")
for name,c in sorted(d.items()):
    sp=(c.get("savePath") or "")
    note=""
    if not sp:
        note="   <-- EMPTY: falls back to the default save path"
    print("  %-12s savePath=%s%s" % (name, sp or "(empty)", note))
'
    echo "== torrents =="
    qb /api/v2/torrents/info | python3 -c '
import json,sys
d=json.load(sys.stdin)
if not d: print("  none"); raise SystemExit
for t in d:
    print("  %-46s %-9s %6.1f GiB  cat=%s  path=%s" % (
        t.get("name","")[:46], t.get("state",""),
        (t.get("size") or 0)/2**30, t.get("category") or "-", t.get("save_path","")))
'
    echo "== /data =="
    ssh "${K[@]}" "$VM" 'df -h /data | tail -1' 2>/dev/null | sed 's/^/  /'
}

cmd_remove() {
    local pattern="$1" yes="$2"
    qb_login
    local hits
    hits="$(qb /api/v2/torrents/info | PAT="$pattern" python3 -c '
import json,sys,os,re
d=json.load(sys.stdin)
def norm(s): return re.sub(r"[^a-z0-9]+","",s.lower())
p=norm(os.environ["PAT"])
if not p: sys.exit(0)
for t in d:
    if p in norm(t.get("name") or ""):
        print("%s\t%s\t%s\t%s" % (t.get("hash"), t.get("name"), t.get("size") or 0,
                                  t.get("save_path") or ""))
')"
    [ -n "$hits" ] || die "no torrent matching '$pattern'"
    local n; n="$(printf '%s\n' "$hits" | wc -l)"
    [ "$n" -eq 1 ] || { printf '%s\n' "$hits"; die "$n torrents match '$pattern' — be more specific"; }

    local hash name size path
    IFS=$'\t' read -r hash name size path <<<"$hits"

    # Safety: only ever delete a torrent's own directory. /data/media is the
    # library and is never touched. A hardlinked library file survives the
    # unlink either way (the inode keeps its other name), so the real risk is
    # deleting outside /data/torrents, not "the last copy".
    # The save_path may be /data/torrents itself (default path, no category
    # subdir) or a category subdir. Both are safe: qBt only unlinks the
    # torrent's own content, never the parent directory.
    case "$path" in
        /data/torrents|/data/torrents/*) : ;;
        *) die "save_path '$path' is outside /data/torrents — refusing" ;;
    esac

    echo "  torrent  : $name"
    echo "  hash     : $hash"
    echo "  size     : $(awk -v b="$size" 'BEGIN{printf "%.1f GiB", b/2**30}')"
    echo "  save_path: $path"

    # Radarr safety net: a queue entry would interpret deleting the torrent as
    # "download failed" -> blocklist + re-search -> re-download the same remux.
    local rdk_ q
    rdk_="$(rdk)"
    if [ -n "${rdk_:-}" ]; then
        q="$(curl -sS -m 20 -H "X-Api-Key: $rdk_" \
            "$RD/api/v3/queue?pageSize=100&includeUnknownMovieItems=true" 2>/dev/null \
            | PAT="$pattern" python3 -c '
import json,sys,os,re
def norm(s): return re.sub(r"[^a-z0-9]+","",s.lower())
p=norm(os.environ["PAT"])
try: d=json.load(sys.stdin)
except Exception: raise SystemExit
for r in d.get("records") or []:
    if p and p in norm(r.get("title") or ""):
        print("%s [%s/%s]" % (r.get("title"), r.get("status"), r.get("trackedDownloadStatus")))
' 2>/dev/null)"
        if [ -n "$q" ]; then
            echo
            echo "  WARNING: still in Radarr's queue:"
            printf '%s\n' "$q" | sed 's/^/    /'
            echo "  Remove it in Radarr (Activity -> Queue -> Remove, do NOT blocklist)"
            echo "  BEFORE deleting here, otherwise Radarr may re-grab the release."
        fi
    fi

    if [ "$yes" != "--yes" ]; then
        echo
        echo "DRY RUN — re-run with --yes to delete this torrent AND its files."
        return 0
    fi
    local before after
    before="$(ssh "${K[@]}" "$VM" "df -Pk /data | awk 'NR==2{print \$4}'" 2>/dev/null)"
    echo "  deleting (torrent + files)…"
    qb /api/v2/torrents/delete --data-urlencode "hashes=$hash" --data 'deleteFiles=true' \
        -o /dev/null -w '  HTTP %{http_code}\n' || die "delete call failed"
    sleep 3
    after="$(ssh "${K[@]}" "$VM" "df -Pk /data | awk 'NR==2{print \$4}'" 2>/dev/null)"
    echo "  free: ${before:-?} KiB -> ${after:-?} KiB"
    if [ -n "$before" ] && [ -n "$after" ] && [ "$after" -gt "$before" ]; then
        echo "  reclaimed $(awk -v a="$after" -v b="$before" 'BEGIN{printf "%.1f GiB", (a-b)/1048576}')"
    else
        echo "  WARNING: no space returned. The library file may still be a hardlink"
        echo "           to the torrent (nlink > 1) — check with: stat -c %h <media.mkv>"
    fi
    ssh "${K[@]}" "$VM" 'df -h /data | tail -1' 2>/dev/null | sed 's/^/  now: /'
}

cmd_category() {
    local cat="$1" path="$2" code
    qb_login
    # createCategory returns 409 when the category already exists, and does NOT
    # update the path. Create first, then always edit so an existing category
    # with an empty savePath (the state that sends downloads to the default
    # dir) actually gets fixed. editCategory exists from qBittorrent 4.5.0.
    code="$(qb /api/v2/torrents/createCategory --data-urlencode "category=$cat" \
        --data-urlencode "savePath=$path" -o /dev/null -w '%{http_code}')"
    echo "  createCategory HTTP $code"
    code="$(qb /api/v2/torrents/editCategory --data-urlencode "category=$cat" \
        --data-urlencode "savePath=$path" -o /dev/null -w '%{http_code}')"
    echo "  editCategory   HTTP $code"
    qb /api/v2/torrents/categories | CAT="$cat" WANT="$path" python3 -c '
import json,sys,os
d=json.load(sys.stdin); n=os.environ["CAT"]; want=os.environ["WANT"]
c=d.get(n)
if not c:
    print("  MISSING: category %r does not exist" % n); raise SystemExit(1)
got=(c.get("savePath") or "").rstrip("/")
print("  %s -> %r" % (n, got or "(empty)"))
if got != want.rstrip("/"):
    print("  NOT SET: expected %r. If editCategory returned 404 the qBt build" % want)
    print("  predates 4.5.0 — set it in the GUI (qBt -> Categories).")
    raise SystemExit(1)
print("  verify: OK — new grabs land in %s" % want)
'
}

cmd_category_paths() {
    # qBittorrent 5 finishes an API add in MANUAL torrent-management mode:
    # Radarr sends `category` but neither `savepath` nor `autoTMM`
    # (QBittorrentProxyV2.AddTorrentDownloadFormParameters), so sessionimpl.cpp
    # computes useAutoTMM=false and takes the SESSION save path. The category
    # savePath is only consulted when Session\UseCategoryPathsInManualMode is
    # true — default false. Observed live 2026-11-20: cat=radarr, torrent at
    # /data/torrents instead of the category's /data/torrents/movies (fix 69).
    #
    # The preference is applied LIVE by /api/v2/app/setPreferences
    # (appcontroller.cpp -> Session::setUseCategoryPathsInManualMode); no
    # restart, and existing torrents keep their current location.
    qb_login
    qb /api/v2/app/preferences      > "$TMP/prefs.json" 2>/dev/null || echo '{}' > "$TMP/prefs.json"
    qb /api/v2/torrents/categories  > "$TMP/cats.json"  2>/dev/null || echo '{}' > "$TMP/cats.json"

    cat > "$TMP/catpaths.py" <<'PY'
import json, sys

mode = sys.argv[1]

def load(p, default):
    try:
        return json.load(open(p))
    except Exception:
        return default

prefs = load(sys.argv[2], {})
cats  = load(sys.argv[3], {})
on    = bool(prefs.get("use_category_paths_in_manual_mode"))
base  = (prefs.get("save_path") or "?").rstrip("/")

print("  default save path             : %s" % base)
print("  category paths in manual mode : %s" % on)
missing = []
for name, c in sorted((cats or {}).items()):
    sp = ((c or {}).get("savePath") or "").rstrip("/")
    if sp:
        print("  %-10s -> %s" % (name, sp))
    else:
        missing.append(name)
        print("  %-10s -> (empty: implicit %s/%s)" % (name, base, name))

if mode == "check":
    if on:
        print("  nothing to do — new *arr adds already use their category path")
        if missing:
            print("  but these categories have no savePath: %s" % ", ".join(missing))
            raise SystemExit(2)
        raise SystemExit(0)
    print("  Radarr/Sonarr send a category but no savepath/autoTMM, so with this")
    print("  OFF every *arr download lands in %s, ignoring the category path." % base)
    raise SystemExit(10)

if not on:
    print("  MISMATCH — the preference did not persist"); raise SystemExit(3)
if not cats:
    print("  NOTE: no categories defined yet, so nothing will use a path")
    raise SystemExit(0)
if missing:
    print("  WARNING: no savePath for %s — set one with"
          " --create-category <name> <path>" % ", ".join(missing))
    raise SystemExit(2)
print("  verify: OK — the next add lands in its category path")
PY

    echo "== current =="
    python3 "$TMP/catpaths.py" check "$TMP/prefs.json" "$TMP/cats.json"
    local rc=$?
    [ "$rc" -eq 0 ] && return 0
    [ "$rc" -eq 10 ] || return "$rc"

    echo "== enabling category paths in manual mode =="
    local code
    code="$(qb /api/v2/app/setPreferences \
        --data-urlencode 'json={"use_category_paths_in_manual_mode":true}' \
        -o /dev/null -w '%{http_code}')"
    echo "  POST app/setPreferences -> HTTP $code (200 = applied live)"
    [ "$code" = "200" ] || { echo "  rejected — nothing changed"; return 5; }

    qb /api/v2/app/preferences > "$TMP/prefs.json" 2>/dev/null
    echo "== after =="
    python3 "$TMP/catpaths.py" verify "$TMP/prefs.json" "$TMP/cats.json"
}

cmd_first_run() {
    # One idempotent command for a fresh install (manual 10c). Each step is
    # individually idempotent, but they are easy to half-do: the category path
    # is ignored without the manual-mode switch (fix 69), and Radarr's field is
    # `movieCategory`, not `category` (a wrong name is accepted and dropped).
    local rc=0
    echo "== 1/3 qBittorrent category 'radarr' -> /data/torrents/movies =="
    cmd_category radarr /data/torrents/movies || rc=$?
    [ "$rc" -eq 0 ] || die "step 1 failed (rc=$rc) — fix it before continuing"

    echo
    echo "== 2/3 Radarr download client: movieCategory = 'radarr' =="
    cmd_radarr_category radarr || rc=$?
    [ "$rc" -eq 0 ] || die "step 2 failed (rc=$rc) — fix it before continuing"

    echo
    echo "== 3/3 qBittorrent: use category paths in manual mode =="
    cmd_category_paths || rc=$?
    [ "$rc" -eq 0 ] || die "step 3 failed (rc=$rc) — see the warnings above"

    echo
    echo "== first-run complete =="
    echo "  The next Radarr grab is filed with cat=radarr and lands in"
    echo "  /data/torrents/movies. Verify the OUTCOME after one download with:"
    echo "    sudo bash library_status.sh \"<title>\""
    echo "  (a torrent added before this run keeps /data/torrents — same"
    echo "   filesystem, so imports and hardlinks are unaffected)"
}

cmd_radarr_category() {
    local cat="$1" key
    key="$(rdk)"; [ -n "$key" ] || die "no RADARR_API_KEY in $ENVF"
    KEY="$key" CAT="$cat" python3 - "$RD" <<'PY'
import json, os, sys, urllib.request

base = sys.argv[1].rstrip("/")
key  = os.environ["KEY"]
cat  = os.environ["CAT"]

def call(path, method="GET", body=None):
    h = {"X-Api-Key": key}
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        h["Content-Type"] = "application/json"
    req = urllib.request.Request(base + path, data=data, method=method, headers=h)
    with urllib.request.urlopen(req, timeout=30) as r:
        raw = r.read()
        return r.status, (json.loads(raw) if raw else None)

st, clients = call("/api/v3/downloadclient")
qb = [c for c in clients or []
      if (c.get("implementation") or "").lower().startswith("qbittorrent")]
if not qb:
    print("  no qBittorrent download client configured"); sys.exit(1)
c   = qb[0]
cid = c["id"]

# Radarr's qBittorrent client stores the category in `movieCategory`
# (Sonarr uses `tvCategory`). A field literally named `category` is NOT read
# by Radarr: a PUT carrying it returns 202 and is silently ignored, which is
# why an earlier version of this helper appeared to succeed and verified empty.
# So the target is always a schema field, never `category`.
NAMES  = ("movieCategory", "tvCategory")
fields = c.get("fields") or []
target = next((n for n in NAMES
               if any(f.get("name") == n for f in fields)), None)
if target is None:
    target = "movieCategory"
    fields.append({"name": target, "value": cat})
    print("  no category field present — adding %r" % target)
if any(f.get("name") == "category" for f in fields):
    print("  NOTE: a field named 'category' exists but Radarr ignores it;")
    print("        writing %r instead" % target)

before = next((f.get("value") for f in fields if f.get("name") == target), "")
for f in fields:
    if f.get("name") == target:
        f["value"] = cat
c["fields"] = fields

st, _ = call("/api/v3/downloadclient/%d" % cid, "PUT", c)
print("  download client #%d %s: %r -> %r (HTTP %s)" % (cid, target, before, cat, st))

st, after = call("/api/v3/downloadclient/%d" % cid)
af  = after.get("fields") or []
got = next((f.get("value") for f in af if f.get("name") == target), None)
host = next((f.get("value") for f in af if f.get("name") == "host"), "?")
print("  verify: %s = %r" % (target, got))
print("  client unchanged otherwise: enable=%s host=%s" % (after.get("enable"), host))
if got != cat:
    print("  MISMATCH — the new value did not persist"); sys.exit(3)
if any(f.get("name") == "category" for f in af):
    print("  WARNING: a stray 'category' field is present and ignored by Radarr")
print("  verify: OK")
PY
}

# ---- dispatch ---------------------------------------------------------------
case "${1:-}" in
    --status)            cmd_status ;;
    --remove-torrent)    [ $# -ge 2 ] || die "usage: --remove-torrent <name> [--yes]"
                         cmd_remove "$2" "${3:-}" ;;
    --create-category)   [ $# -ge 3 ] || die "usage: --create-category <name> <savePath>"
                         cmd_category "$2" "$3" ;;
    --set-radarr-category) [ $# -ge 2 ] || die "usage: --set-radarr-category <name>"
                         cmd_radarr_category "$2" ;;
    --first-run)         cmd_first_run ;;
    --fix-category-paths) cmd_category_paths ;;
    *) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac

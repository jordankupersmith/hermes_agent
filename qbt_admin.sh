#!/usr/bin/env bash
#
# qBittorrent + Radarr admin helpers — used by manual Step 10c and to reclaim
# disk after a remux. Read/write, but nothing is deleted without --yes.
#
#   sudo bash qbt_admin.sh --status
#   sudo bash qbt_admin.sh --remove-torrent "Project.Hail.Mary" [--yes]
#   sudo bash qbt_admin.sh --first-run       (category + Radarr field + path mode)
#   sudo bash qbt_admin.sh --set-password    (one atomic qBt + Radarr credential)
#   sudo bash qbt_admin.sh --import-downloads [path]
#   sudo bash qbt_admin.sh --create-category radarr /data/torrents/movies
#   sudo bash qbt_admin.sh --set-radarr-category radarr
#   sudo bash qbt_admin.sh --fix-category-paths
#
# Why a Host header: qBittorrent validates the Host header and CSRF Referer, so
# a plain request to 192.168.122.10:8080 is rejected even with the right
# password. The WebUI is VM-only (never on the LAN) — this runs on clawbox and
# talks to the VM-side published port.
#
# Secrets: the WebUI password is read from $QB_PASS, else
# /etc/media-vm/qbt_webui_password (600 root:root — written by --set-password),
# else the first-run "temporary password" line in the container log, else
# prompted. It is never echoed and never appears in argv.

set -uo pipefail

QB="http://192.168.122.10:8080"
RD="http://192.168.122.10:7878"
ENVF=/opt/media-assistant/.env
# fix 71 — the permanent WebUI credential. qBittorrent generates a NEW temporary
# password every time it starts with no password configured, so a container
# recreate (any apply run) invalidates what Radarr stored: Radarr then keeps
# retrying the old one, bans itself (5 failures / 3600 s, per source IP), and
# reports the ban as "Authentication Failure". One stored credential removes the
# whole class. Root-only, same directory and mode as vpn.env.
QBPWF=/etc/media-vm/qbt_webui_password
JAR="$(mktemp)"
TMP="$(mktemp -d)"
trap 'rm -f "$JAR"; rm -rf "$TMP"' EXIT
K=(-i /etc/media-vm/deploy_ed25519 -o IdentitiesOnly=yes
   -o UserKnownHostsFile=/etc/media-vm/known_hosts)
VM=jordan@192.168.122.10

[ "$(id -u)" -eq 0 ] || { echo "must run as root: sudo bash $0" >&2; exit 1; }

die() { echo "ERROR: $*" >&2; exit 1; }

# ---- shared credential plumbing (fix 71) ------------------------------------
# One block, four modes, so the same code can be driven against a fake server by
# tests/test_qbt_pw.py. Secrets travel in 0600 files, never in argv.
cat > "$TMP/pw.py" <<'PY'
"""qBittorrent <-> Radarr WebUI credential plumbing (fix 71).

  set    <qb_base> <user> <curpw_file> <newpw_file>
  radarr <rd_base> <api_key_file> <newpw_file>
  test   <rd_base> <api_key_file>
  import <rd_base> <api_key_file> <path>

Exit codes are a contract with the shell wrapper:
  4  the CURRENT qBt password was rejected
  5  the source IP is banned (qBt answers 403) — restart qBittorrent
  6  setPreferences was rejected
  7  the NEW password did not take (a fresh login still fails)
  8  Radarr refused the update, or has no qBittorrent client
  9  Radarr's own testall is not valid
 10  the import command was rejected
"""
import http.cookiejar
import json
import sys
import urllib.error
import urllib.parse
import urllib.request

# qBittorrent rejects a foreign Host header (HostHeaderValidation) and requires
# Referer/Origin to match it for POSTs, exactly like the curl wrapper does.
QH = {"Host": "localhost:8080",
      "Referer": "http://localhost:8080/",
      "Origin": "http://localhost:8080/"}


def opener():
    return urllib.request.build_opener(
        urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))


def form(op, url, data):
    body = urllib.parse.urlencode(data).encode()
    req = urllib.request.Request(
        url, data=body,
        headers=dict(QH, **{"Content-Type": "application/x-www-form-urlencoded"}))
    try:
        with op.open(req, timeout=30) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")


def login(base, user, password):
    op = opener()
    st, body = form(op, base + "/api/v2/auth/login",
                    {"username": user, "password": password,
                     "referer": "http://localhost:8080/"})
    return op, st, body.strip()


def rejected(st, body):
    if st == 403 or "banned" in body.lower():
        print("  qBittorrent answered HTTP %s: the source IP is BANNED" % st)
        print("  (5 failed logins -> BanDuration 3600 s, and the list is in")
        print("   memory only — a qBittorrent restart clears it)")
        return 5
    print("  qBittorrent rejected the CURRENT password (HTTP %s, %r)"
          % (st, body[:120]))
    return 4


def secret(path):
    return open(path, "r", encoding="utf-8").read().strip()


def rd(base, key, path, method="GET", body=None):
    h = {"X-Api-Key": key}
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        h["Content-Type"] = "application/json"
    req = urllib.request.Request(base + path, data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read()
            try:
                return r.status, (json.loads(raw) if raw else None)
            except Exception:
                return r.status, raw.decode("utf-8", "replace")[:600]
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, raw.decode("utf-8", "replace")[:600]


mode = sys.argv[1]

if mode == "set":
    base, user = sys.argv[2].rstrip("/"), sys.argv[3]
    cur, new = secret(sys.argv[4]), secret(sys.argv[5])
    if not new:
        print("  no new password supplied"); raise SystemExit(6)

    op, st, body = login(base, user, cur)
    if body != "Ok.":
        raise SystemExit(rejected(st, body))
    print("  current password: accepted")

    st, body = form(op, base + "/api/v2/app/setPreferences",
                    {"json": json.dumps({"web_ui_username": user,
                                         "web_ui_password": new})})
    if st == 403:
        raise SystemExit(rejected(st, body))
    if st != 200:
        print("  POST app/setPreferences -> HTTP %s (want 200): %r"
              % (st, body[:200]))
        raise SystemExit(6)
    print("  POST app/setPreferences -> HTTP 200 (qBt hashes it server-side)")

    # The live cookie keeps working even if the value was dropped, so the only
    # proof is a brand-new session.
    _, st2, body2 = login(base, user, new)
    if body2 != "Ok.":
        print("  the NEW password did not take (fresh login: HTTP %s, %r)"
              % (st2, body2[:120]))
        raise SystemExit(7)
    print("  fresh login with the new password: OK")
    raise SystemExit(0)

if mode == "radarr":
    base = sys.argv[2].rstrip("/")
    key, new = secret(sys.argv[3]), secret(sys.argv[4])

    st, clients = rd(base, key, "/api/v3/downloadclient")
    qb = [c for c in (clients or [])
          if (c.get("implementation") or "").lower().startswith("qbittorrent")]
    if not qb:
        print("  no qBittorrent download client configured"); raise SystemExit(8)
    c, cid = qb[0], qb[0]["id"]
    fields = c.get("fields") or []
    if not any(f.get("name") == "password" for f in fields):
        print("  the client has no 'password' field — Radarr schema change?")
        raise SystemExit(8)
    for f in fields:
        if f.get("name") == "password":
            f["value"] = new
    c["fields"] = fields

    st, body = rd(base, key, "/api/v3/downloadclient/%d" % cid, "PUT", c)
    print("  PUT downloadclient/%d -> HTTP %s%s"
          % (cid, st, " (202 = saved)" if 200 <= int(st) < 300 else ""))
    if not (200 <= int(st) < 300):
        print("  Radarr rejected it (it tests the client on save):")
        print("   ", json.dumps(body)[:700] if isinstance(body, (dict, list)) else body)
        raise SystemExit(8)

    st, after = rd(base, key, "/api/v3/downloadclient/%d" % cid)
    got = next((f.get("value") for f in (after.get("fields") or [])
                if f.get("name") == "password"), None)
    # Informational only: a build that does not echo the secret must not be
    # treated as a failure — the saved-client test below is the real proof.
    print("  read-back: password field %s"
          % ("matches" if got == new else "not echoed (testall decides)"))
    raise SystemExit(0)

if mode == "test":
    base = sys.argv[2].rstrip("/")
    key = secret(sys.argv[3])
    st, rows = rd(base, key, "/api/v3/downloadclient/testall", "POST")
    rows = rows if isinstance(rows, list) else [rows]
    ok = True
    for r in rows:
        if not isinstance(r, dict):
            print("    (unexpected row: %r)" % (r,)); ok = False; continue
        print("    #%s %-18s isValid=%s" % (r.get("id"), r.get("name"), r.get("isValid")))
        for f in r.get("validationFailures") or []:
            print("      failure:", f.get("errorMessage") or f)
        ok = ok and bool(r.get("isValid"))
    if not rows or not any(isinstance(r, dict) for r in rows):
        print("  no client returned a verdict"); raise SystemExit(9)
    raise SystemExit(0 if ok else 9)

if mode == "import":
    base = sys.argv[2].rstrip("/")
    key, path = secret(sys.argv[3]), sys.argv[4]
    st, body = rd(base, key, "/api/v3/command", "POST",
                  {"name": "DownloadedMoviesScan", "path": path})
    print("  POST command DownloadedMoviesScan path=%s -> HTTP %s%s"
          % (path, st, " (201 = queued)" if 200 <= int(st) < 300 else ""))
    if not (200 <= int(st) < 300):
        print("   ", json.dumps(body)[:600] if isinstance(body, (dict, list)) else body)
        raise SystemExit(10)
    print("  command id: %s (Radarr scans that folder and imports what it"
          " recognises)" % (body or {}).get("id"))
    print("  NOTE: this is a manual import, so Radarr runs ImportMode Auto ->")
    print("  Move: with hardlinks on it hardlinks into the library and unlinks")
    print("  the torrent's copy (no duplicated data; the torrent then shows")
    print("  missing files). Delete the torrent entry afterwards instead of")
    print("  expecting disk space back.")
    raise SystemExit(0)

print("unknown mode %r" % mode); raise SystemExit(2)
PY

# ---- shared curl wrapper (Host/Referer/Origin kept consistent) --------------
qb() {  # qb <path> [curl args...]
    local path="$1"; shift
    curl -sS -m 20 --compressed -b "$JAR" -c "$JAR" \
        -H 'Host: localhost:8080' \
        -H 'Referer: http://localhost:8080/' \
        -H 'Origin: http://localhost:8080' \
        "$@" "$QB$path"
}

qb_pass() {
    # Prints the CURRENT WebUI password on stdout; the provenance line goes to
    # stderr, so the secret never lands in captured output.
    if [ -n "${QB_PASS:-}" ]; then
        echo "  using \$QB_PASS" >&2
        printf '%s' "$QB_PASS"; return 0
    fi
    if [ -r "$QBPWF" ]; then
        local p; p="$(head -n1 "$QBPWF" 2>/dev/null)"
        if [ -n "$p" ]; then
            echo "  using the stored WebUI password ($QBPWF, 600 root-only)" >&2
            printf '%s' "$p"; return 0
        fi
    fi
    local t
    t="$(ssh "${K[@]}" "$VM" \
        'sudo docker logs qbittorrent 2>&1 | grep -i "temporary password" | tail -1' \
        2>/dev/null | sed -n 's/.*password[^:]*: *//p')"
    if [ -n "$t" ]; then
        echo "  using the first-run temporary password from the container log" >&2
        printf '%s' "$t"; return 0
    fi
    if [ -t 0 ]; then
        local p; read -rsp "qBittorrent WebUI password: " p; echo >&2
        printf '%s' "$p"; return 0
    fi
    return 0
}

qb_login() {
    # already authenticated? (subnet whitelist or a live session)
    local v
    v="$(qb /api/v2/app/version 2>/dev/null)"
    case "$v" in v*) echo "  qBittorrent $v (session already authorised)"; return 0 ;; esac

    local pass
    pass="$(qb_pass)"
    [ -n "$pass" ] || die "no qBittorrent password available (set QB_PASS=..., or run --set-password)"

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
    # fix 70 — is the LIVE value also ON DISK? qBittorrent holds settings in
    # memory (SettingsStorage writes 5 s later, plus once on a clean shutdown),
    # so a container recreate can lose a live-only write: observed 2026-11-20,
    # live True before `up -d` recreated the container and False after. The conf
    # is the durable copy, and phase5_apply.sh now writes it while qBt is
    # stopped.
    QBCAT="$(ssh "${K[@]}" "$VM" \
        'grep -a "UseCategoryPathsInManualMode" /data/config/qbittorrent/qBittorrent.conf' 2>/dev/null)"
    case "$QBCAT" in
        *"=true") echo "  on disk                      : ${QBCAT##*\\} (survives a restart)" ;;
        "")       echo "  on disk                      : ABSENT <-- a recreate loses the live value (fix 70)" ;;
        *)        echo "  on disk                      : ${QBCAT##*\\} <-- not true (fix 70)" ;;
    esac
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

cmd_set_password() {
    # fix 71 — ONE operation, because the two halves are useless apart and the
    # ordering is what makes it safe:
    #   1. prove the current credential from here (host IP - a different source
    #      from Radarr, so a Radarr ban does not block the repair);
    #   2. set the new one and PROVE it with a fresh login;
    #   3. store it root-only BEFORE touching Radarr, so a later failure is
    #      recoverable (every helper reads that file first);
    #   4. rewrite Radarr's download client with it;
    #   5. restart qBittorrent — the ban list is in memory, and Radarr's retries
    #      created one while the two disagreed;
    #   6. require Radarr's own saved-client test to pass before claiming done.
    # Skipping 4 while doing 2 is exactly how the ban comes back: Radarr polls
    # every ~60 s and bans its own source IP after 5 failures.
    local restart=1
    [ "${1:-}" = "--no-restart" ] && restart=0

    qb_login

    local new="${QB_NEW_PASS:-}"
    if [ -z "$new" ]; then
        new="$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')"
        echo "  new password: generated (24 chars, [A-Za-z0-9_-])"
    else
        echo "  new password: from \$QB_NEW_PASS"
    fi
    [ "${#new}" -ge 12 ] || die "the new password must be at least 12 characters"

    local pass; pass="$(qb_pass)"
    [ -n "$pass" ] || die "no current qBittorrent password to replace"
    printf '%s' "$pass" > "$TMP/curpw"; chmod 600 "$TMP/curpw"
    printf '%s' "$new"  > "$TMP/newpw"; chmod 600 "$TMP/newpw"
    local key; key="$(rdk)"; [ -n "$key" ] || die "no RADARR_API_KEY in $ENVF"
    printf '%s' "$key" > "$TMP/rd.key"; chmod 600 "$TMP/rd.key"

    echo "== 1/4 qBittorrent: set the WebUI password =="
    python3 "$TMP/pw.py" set "$QB" admin "$TMP/curpw" "$TMP/newpw" || exit $?
    rm -f "$TMP/curpw"

    install -m 600 -o root -g root "$TMP/newpw" "$QBPWF" \
        || die "could not write $QBPWF (the password IS changed - fix that file)"
    echo "  stored: $QBPWF (600 root:root) - read first by this script and library_status.sh"

    echo "== 2/4 Radarr: the same password in the download client =="
    python3 "$TMP/pw.py" radarr "$RD" "$TMP/rd.key" "$TMP/newpw"
    local rc=$?
    if [ "$rc" -ne 0 ]; then
        echo
        echo "  the qBittorrent password IS changed and stored, but Radarr still has"
        echo "  the old one (rc=$rc). Recover with the SAME command - it is idempotent:"
        echo "    sudo bash $0 --set-password"
        echo "  (it reads the stored password and rewrites Radarr)"
        exit "$rc"
    fi

    if [ "$restart" -eq 1 ]; then
        echo "== 3/4 restart qBittorrent to clear the in-memory login-ban list =="
        ssh "${K[@]}" "$VM" 'sudo docker restart qbittorrent >/dev/null && echo "  container restarted"' \
            || echo "  restart FAILED - Radarr may stay banned for up to an hour"
        local C=""
        for _ in $(seq 1 90); do
            C="$(curl -s -o /dev/null -w '%{http_code}' -m 3 http://192.168.122.10:8080/ 2>/dev/null)"
            [ "$C" = "200" ] && break
            sleep 1
        done
        echo "  WebUI after restart: HTTP ${C:-(no answer)}"
        [ "$C" = "200" ] || die "qBittorrent did not come back - check: docker logs qbittorrent"
    else
        echo "== 3/4 restart skipped (--no-restart) - a ban, if any, stays =="
    fi

    echo "== 4/4 Radarr's own saved-client test =="
    python3 "$TMP/pw.py" test "$RD" "$TMP/rd.key"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo
        echo "  testall is still invalid. A ban created between the write and the"
        echo "  restart is the remaining explanation - clear it, then re-sync:"
        echo "    sudo bash library_status.sh \"<title>\" --fix-qbt-auth"
        echo "    sudo bash $0 --set-password --no-restart"
        exit "$rc"
    fi
    rm -f "$TMP/newpw"

    echo
    echo "== done - qBittorrent and Radarr share one permanent credential =="
    echo "  the WebUI password is in $QBPWF (600 root:root); read it with"
    echo "    sudo cat $QBPWF"
    echo "  the container log no longer contains a usable password. Never change"
    echo "  it in the UI without this script: a half-done change re-creates the"
    echo "  ban (manual 10b)."
}

cmd_import_downloads() {
    # Radarr drops a tracked download when its download client is unreachable
    # ("download was not found in the client"), so a torrent that keeps
    # downloading afterwards is an ORPHAN: nobody imports it when it finishes.
    # DownloadedMoviesScan is the manual-import scanner and needs no queue row.
    local path="${1:-/data/torrents}"
    case "$path" in
        /data/torrents|/data/torrents/*) : ;;
        *) die "refusing to scan '$path' - only under /data/torrents" ;;
    esac
    local key; key="$(rdk)"; [ -n "$key" ] || die "no RADARR_API_KEY in $ENVF"
    printf '%s' "$key" > "$TMP/rd.key"; chmod 600 "$TMP/rd.key"
    python3 "$TMP/pw.py" import "$RD" "$TMP/rd.key" "$path"
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
    --set-password)      cmd_set_password "${2:-}" ;;
    --import-downloads)  cmd_import_downloads "${2:-}" ;;
    --fix-category-paths) cmd_category_paths ;;
    *) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac

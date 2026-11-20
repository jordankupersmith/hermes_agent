#!/usr/bin/env bash
#
# "Do I actually have this title?" — one read-only pass down the whole chain:
#
#   Jellyseerr request -> Radarr movie -> Radarr queue -> qBittorrent torrent
#   -> file in /data/media/movies -> Jellyfin library item
#
#   sudo bash library_status.sh "breakfast club"
#   sudo bash library_status.sh "breakfast club" --fix-client-host
#        (writes ONE field: Radarr's qBittorrent host -> "gluetun")
#   sudo bash library_status.sh "breakfast club" --fix-client-password
#        (copies qBt's CURRENT WebUI password into Radarr's client entry; the
#         secret is never printed and the run re-tests with /testall)
#   sudo bash library_status.sh "breakfast club" --fix-qbt-auth
#        (restarts qBittorrent to clear its in-memory login-ban list)
#   sudo bash library_status.sh "breakfast club" --retry
#        (drops a parked downloadClientUnavailable queue entry, then searches;
#         refuses unless every download client passes Radarr's own test)
#
# Every section is evidence from the component itself (Radarr API, qBittorrent
# API, the filesystem inside media-vm, Jellyfin API), and the last block is a
# plain-language verdict. Nothing is written, deleted or re-scanned.
#
# Secrets: RADARR_API_KEY is read from /opt/media-assistant/.env, the qBt
# password from $QB_PASS or the first-run temporary password in the container
# log, and the Jellyfin token from jellyfin.db *inside the VM*. None is printed.

set -uo pipefail

TERM_IN="${1:-}"
[ -n "$TERM_IN" ] || { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "must run as root: sudo bash $0" >&2; exit 1; }

RD="http://192.168.122.10:7878"
QB="http://192.168.122.10:8080"
ENVF=/opt/media-assistant/.env
K=(-i /etc/media-vm/deploy_ed25519 -o IdentitiesOnly=yes
   -o UserKnownHostsFile=/etc/media-vm/known_hosts)
VM=jordan@192.168.122.10

TMP="$(mktemp -d)"
JAR="$TMP/qb.cookies"
trap 'rm -rf "$TMP"' EXIT

die() { echo "ERROR: $*" >&2; exit 1; }

RDK="$(grep -m1 '^RADARR_API_KEY=' "$ENVF" 2>/dev/null | cut -d= -f2-)"
[ -n "${RDK:-}" ] || die "no RADARR_API_KEY in $ENVF — re-run phase5_apply.sh first"
rd() { curl -sS -m 25 -H "X-Api-Key: $RDK" "$RD$1"; }

test_all() {  # test_all [clientId] — POST /testall, prints validity per saved client
    curl -sS -m 60 -X POST -H "X-Api-Key: $RDK" \
         "$RD/api/v3/downloadclient/testall" \
      | FILTER="${1:-}" python3 -c '
import json, os, sys
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except Exception:
    print("    (no JSON from testall; body: %r)" % raw[:300]); raise SystemExit
rows = d if isinstance(d, list) else [d]
want = os.environ.get("FILTER") or ""
shown = 0
for r in rows:
    if want and str(r.get("id")) != want:
        continue
    shown += 1
    print("    #%s isValid=%s" % (r.get("id"), r.get("isValid")))
    for f in r.get("validationFailures") or []:
        print("      failure:", f.get("errorMessage") or f)
if not shown:
    print("    (no client returned a verdict)")
' 2>/dev/null
}

clients_valid() {  # prints 1 only if every enabled client reports isValid
    curl -sS -m 60 -X POST -H "X-Api-Key: $RDK" \
         "$RD/api/v3/downloadclient/testall" \
      | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: print("0"); raise SystemExit
rows = d if isinstance(d, list) else [d]
print("1" if rows and all(bool(r.get("isValid")) for r in rows) else "0")
' 2>/dev/null
}

qb() {  # qb <path> [curl args...] — Host/Referer/Origin must stay consistent
    local path="$1"; shift
    curl -sS -m 25 --compressed -b "$JAR" -c "$JAR" \
        -H 'Host: localhost:8080' \
        -H 'Referer: http://localhost:8080/' \
        -H 'Origin: http://localhost:8080' \
        "$@" "$QB$path"
}

qbt_temp_password() {
    ssh "${K[@]}" -o ConnectTimeout=15 "$VM" \
        'sudo docker logs qbittorrent 2>&1 | grep -i "temporary password" | tail -1' \
        2>/dev/null | sed -n 's/.*password[^:]*: *//p'
}

qb_login() {
    local v
    v="$(qb /api/v2/app/version 2>/dev/null)"
    case "$v" in v*) echo "  qBittorrent $v (session already authorised)"; return 0 ;; esac
    local pass="${QB_PASS:-}"
    if [ -z "$pass" ]; then
        pass="$(qbt_temp_password)"
        [ -n "$pass" ] && echo "  using the first-run temporary password from the container log"
    fi
    [ -n "$pass" ] || die "no qBittorrent password (set QB_PASS=...)"
    local r
    r="$(qb /api/v2/auth/login --data-urlencode 'username=admin' \
            --data-urlencode "password=$pass" --data 'referer=http://localhost:8080/')"
    case "$r" in
        Ok*) echo "  qBittorrent login: OK" ;;
        *)   die "qBittorrent login failed ($r) — password or Host header rejected" ;;
    esac
}

# ---- 1. Radarr: does it know the title, and does it think it has a file? ----
echo "== Radarr =="
rd /api/v3/movie > "$TMP/movies.json" || die "cannot read Radarr /api/v3/movie"
rd '/api/v3/queue?page=1&pageSize=250&includeMovie=true' > "$TMP/queue.json" 2>/dev/null \
    || echo '{"records":[]}' > "$TMP/queue.json"

TERM_IN="$TERM_IN" python3 - "$TMP/movies.json" "$TMP/queue.json" "$TMP/mids.txt" <<'PY'
import json, os, re, sys

def norm(s): return re.sub(r"[^a-z0-9]+", "", (s or "").lower())
term = norm(os.environ["TERM_IN"])

movies = json.load(open(sys.argv[1]))
try:
    queue = json.load(open(sys.argv[2]))
    queue = queue.get("records", queue if isinstance(queue, list) else [])
except Exception:
    queue = []

hits = [m for m in movies if term and term in norm(m.get("title"))]
ids = [str(m.get("id")) for m in hits]
open(sys.argv[3], "w").write("\n".join(ids) + ("\n" if ids else ""))

if not hits:
    print("  no movie matching %r (%d movies in Radarr)"
          % (os.environ["TERM_IN"], len(movies)))
    sys.exit(0)

for m in hits:
    mf = m.get("movieFile") or {}
    q = m.get("quality") or {}
    qn = (q.get("quality") or {}).get("name") or "?"
    print("  %s (%s)  radarrId=%s" % (m.get("title"), m.get("year"), m.get("id")))
    print("    monitored : %s   status: %s" % (m.get("monitored"), m.get("status")))
    print("    hasFile   : %s   sizeOnDisk: %.2f GiB"
          % (m.get("hasFile"), (m.get("sizeOnDisk") or 0) / 2**30))
    print("    quality   : %s" % qn)
    print("    path      : %s" % m.get("path"))
    if mf:
        print("    file      : %s  (%.2f GiB)"
              % (mf.get("relativePath"), (mf.get("size") or 0) / 2**30))
    if not m.get("hasFile"):
        print("    (no movie file — Radarr has metadata only)")

    qq = [x for x in queue if x.get("movieId") == m.get("id")]
    for x in qq:
        left = x.get("sizeleft") or 0
        size = x.get("size") or 1
        pct = max(0.0, min(100.0, 100.0 * (1 - left / size))) if size else 0
        print("    queue     : %s / %s  %.1f%%  left=%.2f GiB  eta=%s"
              % (x.get("status"), x.get("trackedDownloadState") or "-", pct,
                 left / 2**30, x.get("timeleft") or "-"))
        if x.get("errorMessage"):
            print("    queue err : %s" % x.get("errorMessage"))
    if not qq and not m.get("hasFile"):
        print("    queue     : (nothing — Radarr is not downloading this)")
PY

# ---- 2. Radarr history, only when there is no file (why did it fail?) ------
if [ -s "$TMP/mids.txt" ]; then
    while IFS= read -r MID || [ -n "${MID:-}" ]; do
        [ -n "$MID" ] || continue
        echo "  -- Radarr history for movieId $MID --"
        rd "/api/v3/history/movie?movieId=$MID&page=1&pageSize=6&sortKey=date&sortDirection=descending" \
          | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: print("    (unreadable)"); raise SystemExit
for h in (d if isinstance(d, list) else d.get("records", []))[:6]:
    print("    %-22s %s" % (h.get("eventType"), h.get("date")))
' 2>/dev/null
    done < "$TMP/mids.txt"
fi

# ---- 3. qBittorrent: is there a live torrent for it? ----------------------
echo "== qBittorrent =="
qb_login
qb /api/v2/torrents/info > "$TMP/torrents.json" 2>/dev/null || echo '[]' > "$TMP/torrents.json"
TERM_IN="$TERM_IN" python3 - "$TMP/torrents.json" <<'PY'
import json, os, re, sys

def norm(s): return re.sub(r"[^a-z0-9]+", "", (s or "").lower())
term = norm(os.environ["TERM_IN"])
try:
    ts = json.load(open(sys.argv[1]))
except Exception:
    ts = []
hits = [t for t in ts if term and term in norm(t.get("name"))]
if not hits:
    print("  no torrent matching %r (%d torrents)" % (os.environ["TERM_IN"], len(ts)))
for t in hits:
    print("  %s" % t.get("name"))
    print("    state=%s  %.1f%%  %.2f GiB  cat=%s  eta=%s"
          % (t.get("state"), 100 * (t.get("progress") or 0),
             (t.get("size") or 0) / 2**30, t.get("category") or "-",
             t.get("eta") if t.get("eta") not in (None, 8640000) else "-"))
    print("    save_path=%s" % (t.get("save_path") or "-"))
PY

# ---- 3b. Radarr -> download client: why is a queued grab stuck? -----------
echo "== Radarr -> download client =="
rd /api/v3/downloadclient > "$TMP/clients.json" 2>/dev/null || echo '[]' > "$TMP/clients.json"
python3 - "$TMP/clients.json" "$TMP/client_ids.txt" <<'PY'
import json, re, sys

try:
    cs = json.load(open(sys.argv[1]))
except Exception:
    print("  (unreadable download client list)"); raise SystemExit

ids = []
for c in cs:
    impl = (c.get("implementation") or "")
    if impl.lower() != "qbittorrent" and "qbit" not in impl.lower():
        continue
    f = {x.get("name"): x.get("value") for x in (c.get("fields") or [])}
    host = str(f.get("host") or "")
    ids.append(str(c.get("id")))
    print("  #%s %-20s enable=%s  host=%s port=%s ssl=%s urlBase=%r"
          % (c.get("id"), c.get("name"), c.get("enable"), host,
             f.get("port"), f.get("useSsl"), f.get("urlBase")))
    print("    username=%r password=%s movieCategory=%r"
          % (f.get("username"), "(set)" if f.get("password") else "(empty)",
             f.get("movieCategory")))
    if re.match(r"^\d+\.\d+\.\d+\.\d+$", host):
        print("    NOTE: an IP host hangs from inside a container (ufw does not")
        print("    allow the 172.18.0.x source) — the compose name 'gluetun' is")
        print("    the documented value (manual 10a / §8c).")
    with open(sys.argv[2] + "." + str(c.get("id")), "w") as fh:
        json.dump(c, fh)
open(sys.argv[2], "w").write("\n".join(ids) + ("\n" if ids else ""))
if not ids:
    print("  no qBittorrent download client configured at all")
PY

if [ -s "$TMP/client_ids.txt" ]; then
    echo "  saved-client test (POST /api/v3/downloadclient/testall):"
    test_all
fi

# opt-in write: point the qBittorrent client at the compose service name. This
# is the documented value for every app-to-app field (manual 10a / §8c): an IP
# host (192.168.122.10) hangs from inside a container because the packet enters
# the VM INPUT chain from 172.18.0.x, which ufw does not allow.
if [ "${2:-}" = "--fix-client-host" ]; then
    echo "== fix: Radarr's qBittorrent host -> 'gluetun' =="
    if [ ! -s "$TMP/client_ids.txt" ]; then
        echo "  no qBittorrent download client to fix"
    else
        while IFS= read -r CID || [ -n "${CID:-}" ]; do
            [ -n "$CID" ] || continue
            python3 - "$TMP/client_ids.txt.$CID" "$TMP/fixed.$CID.json" "$TMP/changed.$CID" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
changed = False
for f in c.get("fields") or []:
    if f.get("name") == "host" and f.get("value") != "gluetun":
        print("  #%s host %r -> 'gluetun'" % (c.get("id"), f.get("value")))
        f["value"] = "gluetun"
        changed = True
json.dump(c, open(sys.argv[2], "w"))
open(sys.argv[3], "w").write("changed" if changed else "")
PY
            if [ -s "$TMP/changed.$CID" ]; then
                CODE="$(curl -sS -o "$TMP/put.$CID.json" -w '%{http_code}' -m 30 -X PUT \
                    -H "X-Api-Key: $RDK" -H 'Content-Type: application/json' \
                    --data @"$TMP/fixed.$CID.json" \
                    "$RD/api/v3/downloadclient/$CID")"
                echo "  PUT downloadclient/$CID -> HTTP $CODE (202 = saved)"
                if [ "$CODE" != "202" ]; then
                    echo "  rejected; Radarr's body:"
                    head -c 600 "$TMP/put.$CID.json" | sed 's/^/    /'; echo
                fi
                echo "  re-test after the change:"
                test_all "$CID"
            else
                echo "  #$CID host is already 'gluetun' — not changing anything"
            fi
        done < "$TMP/client_ids.txt"
    fi
fi

for U in "http://gluetun:8080" "http://192.168.122.10:8080"; do
    C="$(ssh "${K[@]}" -o ConnectTimeout=15 "$VM" \
        "sudo docker exec radarr curl -s -o /dev/null -w '%{http_code}' --max-time 8 '$U'" \
        2>/dev/null)"
    echo "  from inside the radarr container: $U -> ${C:-(no answer / curl missing)}"
done

echo "== qBittorrent WebUI auth settings (read-only) =="
QS="$(ssh "${K[@]}" -o ConnectTimeout=15 "$VM" \
    'sudo grep -aE "HostHeaderValidation|ServerDomains|CSRFProtection|LocalHostAuth" /data/config/qbittorrent/qBittorrent.conf' \
    2>/dev/null)"
if [ -n "${QS:-}" ]; then
    printf '%s\n' "$QS" | sed 's/^/  /'
else
    echo "  (no explicit WebUI auth keys — qBittorrent defaults apply:"
    echo "   HostHeaderValidation=on, ServerDomains='*', CSRFProtection=on,"
    echo "   MaxAuthenticationFailCount=5, BanDuration=3600s)"
fi

echo "== qBittorrent login failures / bans (last 5) =="
QL="$(ssh "${K[@]}" -o ConnectTimeout=15 "$VM" \
    'sudo docker logs --tail 400 qbittorrent 2>&1 | grep -aiE "login failure|banned" | tail -5' \
    2>/dev/null)"
if [ -n "${QL:-}" ]; then
    printf '%s\n' "$QL" | cut -c1-260 | sed 's/^/  /'
    echo "  (a ban is per source IP and IN MEMORY only: 5 failures -> 1h,"
    echo "   cleared by restarting the container — see --fix-qbt-auth)"
else
    echo "  none in the recent container log"
fi

echo "== Radarr log about the download client (last 5) =="
RL="$(ssh "${K[@]}" -o ConnectTimeout=15 "$VM" \
    'sudo docker logs --tail 300 radarr 2>&1 | grep -aiE "qBittorrent|download client" | tail -5' \
    2>/dev/null)"
if [ -n "${RL:-}" ]; then
    printf '%s\n' "$RL" | cut -c1-260 | sed 's/^/  /'
else
    echo "  none in the recent container log"
fi

# opt-in write: sync Radarr's client password with qBittorrent's CURRENT WebUI
# credential (the temp one from the log unless QB_PASS is set). The secret is
# written to a 0600 file inside the private mktemp dir and never printed or put
# on a command line (argv is readable in /proc). Observed live: testall said
# "Authentication Failure" while host/reachability were both correct.
#
# A PUT that answers 400 is NOT a malformed body: ProviderControllerBase tests
# the client on save (unless ?forceSave=true) and returns the validation
# failure in the body. The body is printed here for exactly that reason.
if [ "${2:-}" = "--fix-client-password" ]; then
    echo "== fix: Radarr's qBittorrent password -> qBt's current WebUI credential =="
    PASS="${QB_PASS:-$(qbt_temp_password)}"
    if [ -z "${PASS:-}" ]; then
        echo "  no current qBt password available (temp line gone and QB_PASS unset)."
        echo "  Set a permanent one in the UI (manual 10b), then export QB_PASS=..."
        echo "  for this flag, or update Radarr's client entry by hand."
        exit 4
    fi
    printf '%s' "$PASS" > "$TMP/secret"; chmod 600 "$TMP/secret"
    if [ ! -s "$TMP/client_ids.txt" ]; then
        echo "  no qBittorrent download client to fix"
    else
        while IFS= read -r CID || [ -n "${CID:-}" ]; do
            [ -n "$CID" ] || continue
            python3 - "$TMP/client_ids.txt.$CID" "$TMP/secret" "$TMP/pwfix.$CID.json" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
pw = open(sys.argv[2]).read()
hit = False
for f in c.get("fields") or []:
    if f.get("name") == "password":
        f["value"] = pw
        hit = True
json.dump(c, open(sys.argv[3], "w"))
print("  #%s password field %s" % (c.get("id"), "set" if hit else "MISSING"))
PY
            CODE="$(curl -sS -o "$TMP/put.$CID.json" -w '%{http_code}' -m 30 -X PUT \
                -H "X-Api-Key: $RDK" -H 'Content-Type: application/json' \
                --data @"$TMP/pwfix.$CID.json" \
                "$RD/api/v3/downloadclient/$CID")"
            echo "  PUT downloadclient/$CID -> HTTP $CODE (202 = saved)"
            if [ "$CODE" != "202" ]; then
                echo "  rejected; Radarr's body:"
                head -c 600 "$TMP/put.$CID.json" | sed 's/^/    /'; echo
            fi
            echo "  re-test after the change:"
            test_all "$CID"
        done < "$TMP/client_ids.txt"
    fi
    rm -f "$TMP/secret"
fi

# opt-in action: restart qBittorrent to clear its IN-MEMORY login-ban list.
# qBittorrent bans a source IP for BanDuration (default 3600 s) after
# MaxAuthenticationFailCount (default 5) failures. The ban map lives only in
# memory (src/webui/api/authcontroller.cpp -> AuthController::isBanned), so a
# restart clears it. Radarr is the source of the repeated failures, and every
# login during a ban answers 403 "Your IP address has been banned…", which
# Radarr reports as a plain "Authentication Failure" — indistinguishable from a
# wrong password until the qBittorrent log line is read (printed above).
if [ "${2:-}" = "--fix-qbt-auth" ]; then
    echo "== restarting qBittorrent to clear the login-ban list =="
    if ssh "${K[@]}" -o ConnectTimeout=15 "$VM" \
        'sudo docker restart qbittorrent >/dev/null && echo "  container restarted"' 2>/dev/null; then
        :
    else
        echo "  restart failed — check the container"; exit 5
    fi
    C=""
    for _ in $(seq 1 60); do
        C="$(curl -s -o /dev/null -w '%{http_code}' -m 3 http://192.168.122.10:8080/ 2>/dev/null)"
        [ "$C" = "200" ] && break
        sleep 1
    done
    echo "  WebUI after restart: HTTP ${C:-(no answer)}"
    echo "  saved-client test after the restart:"
    test_all
    echo "  if it is still invalid: --fix-client-password, then --retry"
fi

# opt-in write: clear the parked queue entry and ask Radarr to search again.
# Refuses unless every download client currently passes its own test, so it can
# never paper over a broken client. Nothing is blocklisted (the release was
# never downloaded, so there is no bad file to blame).
if [ "${2:-}" = "--retry" ]; then
    echo "== retry: drop the stuck queue entry and search again =="
    MID="$(head -n 1 "$TMP/mids.txt" 2>/dev/null)"
    if [ -z "$MID" ]; then
        echo "  no Radarr movie matched — nothing to retry"; exit 1
    fi
    if [ "$(clients_valid)" != "1" ]; then
        echo "  REFUSING: the download-client test is not valid. Fix that first —"
        echo "  the block above prints Radarr's own failure message."
        exit 3
    fi
    QIDS="$(python3 - "$TMP/queue.json" "$MID" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit(0)
rows = d.get("records", d) if isinstance(d, dict) else d
for r in rows:
    if str(r.get("movieId")) == sys.argv[2] and (
            r.get("status") == "downloadClientUnavailable" or r.get("errorMessage")):
        print(r.get("id"))
PY
)"
    if [ -z "${QIDS:-}" ]; then
        echo "  no parked queue entry for movieId $MID — searching anyway"
    fi
    for QID in ${QIDS:-}; do
        CODE="$(curl -sS -o /dev/null -w '%{http_code}' -m 30 -X DELETE \
            -H "X-Api-Key: $RDK" \
            "$RD/api/v3/queue/$QID?removeFromClient=false&blocklist=false")"
        echo "  DELETE queue/$QID -> HTTP $CODE (200/202 = removed, not blocklisted)"
    done
    CODE="$(curl -sS -o "$TMP/search.json" -w '%{http_code}' -m 30 -X POST \
        -H "X-Api-Key: $RDK" -H 'Content-Type: application/json' \
        -d "{\"name\":\"MoviesSearch\",\"movieIds\":[$MID]}" \
        "$RD/api/v3/command")"
    echo "  POST command MoviesSearch movieIds=[$MID] -> HTTP $CODE (201 = queued)"
    echo "  re-run the plain command in a minute: the queue should move to a"
    echo "  real download client state and qBittorrent should list the torrent."
fi

# ---- 4. Inside media-vm: the file on disk + the Jellyfin library item -----
echo "== media-vm (files + Jellyfin) =="
ssh "${K[@]}" -o ConnectTimeout=15 "$VM" \
    "sudo env LS_TERM=$(printf %q "$TERM_IN") python3 -" > "$TMP/vm.json" <<'PY'
import json, os, re, sqlite3, subprocess, sys, tempfile, time, urllib.error, urllib.parse, urllib.request

term = os.environ.get("LS_TERM", "")
def norm(s): return re.sub(r"[^a-z0-9]+", "", (s or "").lower())
want = norm(term)

files = []
root = "/data/media/movies"
try:
    for dirpath, dirnames, filenames in os.walk(root):
        if dirpath.count(os.sep) - root.count(os.sep) > 1:
            dirnames[:] = []
            continue
        for f in filenames:
            if not f.lower().endswith((".mkv", ".mp4", ".avi", ".m4v", ".ts", ".srt", ".sub")):
                continue
            if want and want in norm(f):
                p = os.path.join(dirpath, f)
                try: st = os.stat(p)
                except OSError: continue
                files.append({"path": p, "size": st.st_size,
                              "mtime": time.strftime("%Y-%m-%d %H:%M", time.localtime(st.st_mtime))})
except OSError as e:
    files.append({"path": "(cannot walk %s: %s)" % (root, e), "size": 0, "mtime": ""})

BASE = None
for cand in ("http://192.168.122.10:8096", "http://127.0.0.1:8096"):
    try:
        with urllib.request.urlopen(cand + "/System/Info/Public", timeout=8) as r:
            r.read()
        BASE = cand
        break
    except Exception:
        continue

items = []
if BASE:
    DB = "/data/config/jellyfin/data/jellyfin.db"
    def find_token():
        tmp = tempfile.mktemp(suffix=".db")
        try:
            subprocess.run(["cp", DB, tmp], check=True,
                           stderr=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
            for ext in ("-wal", "-shm"):
                subprocess.run(["cp", DB + ext, tmp + ext], check=False,
                               stderr=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
            con = sqlite3.connect(tmp)
            tables = [r[0] for r in con.execute(
                "select name from sqlite_master where type='table'")]
            for t in [x for x in tables if "apikey" in x.lower()]:
                cols = [r[1] for r in con.execute('pragma table_info("%s")' % t)]
                tok = next((c for c in cols
                            if c.lower() in ("accesstoken", "token", "key")), None)
                if not tok:
                    continue
                row = con.execute('select "%s" from "%s" where "%s" is not null '
                                  'and length("%s")>10 limit 1' % (tok, t, tok, tok)).fetchone()
                if row:
                    return row[0]
            return None
        except Exception:
            return None
        finally:
            for p in (tmp, tmp + "-wal", tmp + "-shm"):
                try: os.unlink(p)
                except OSError: pass

    tok = find_token()
    if tok:
        url = (BASE + "/Items?Recursive=true&IncludeItemTypes=Movie"
               "&Fields=Path,RunTimeTicks,MediaSources&Limit=40&SearchTerm="
               + urllib.parse.quote(term))
        req = urllib.request.Request(url, headers={
            "X-Emby-Token": tok,
            "Authorization": 'MediaBrowser Token="%s"' % tok})
        try:
            with urllib.request.urlopen(req, timeout=25) as r:
                data = json.loads(r.read())
            for it in data.get("Items", []):
                if want and want not in norm(it.get("Name")):
                    continue
                ticks = it.get("RunTimeTicks") or 0
                items.append({
                    "name": it.get("Name"),
                    "year": it.get("ProductionYear"),
                    "path": it.get("Path"),
                    "runtime_min": round(ticks / 600000000) if ticks else None,
                    "sources": len(it.get("MediaSources") or []),
                })
        except Exception as e:
            items.append({"error": "Jellyfin search failed: %s" % e})
    else:
        items.append({"error": "no API key found in jellyfin.db"})

print(json.dumps({"files": files, "items": items, "base": BASE}, ensure_ascii=False))
PY

TERM_IN="$TERM_IN" python3 - "$TMP/vm.json" <<'PY'
import json, os, sys
try:
    vm = json.load(open(sys.argv[1]))
except Exception:
    print("  (could not read the VM result)"); raise SystemExit
if vm.get("base") is None:
    print("  Jellyfin is not answering on 192.168.122.10:8096 — check the container")
files = vm.get("files") or []
items = vm.get("items") or []
# the junk .srt/.sub files should never be mistaken for the feature
video = [f for f in files if f["path"].lower().endswith((".mkv", ".mp4", ".avi", ".m4v", ".ts"))]
subs  = [f for f in files if f not in video]
for f in video:
    print("  file  %-72s %6.2f GiB  %s" % (f["path"], f["size"] / 2**30, f["mtime"]))
for f in subs:
    print("  sub   %-72s %6.2f MiB" % (f["path"], f["size"] / 2**20))
if not files:
    print("  no matching file in /data/media/movies")
for it in items:
    if "error" in it:
        print("  Jellyfin: %s" % it["error"]); continue
    print("  jelly %s (%s)  %s min  sources=%s" %
          (it.get("name"), it.get("year"), it.get("runtime_min"), it.get("sources")))
    print("         %s" % it.get("path"))
if not items:
    print("  Jellyfin: no matching movie item")
PY

# ---- 5. verdict ------------------------------------------------------------
echo "== VERDICT =="
TERM_IN="$TERM_IN" python3 - "$TMP/movies.json" "$TMP/queue.json" "$TMP/torrents.json" "$TMP/vm.json" <<'PY'
import json, os, re, sys

def norm(s): return re.sub(r"[^a-z0-9]+", "", (s or "").lower())
term = norm(os.environ["TERM_IN"])

def load(p, default):
    try: return json.load(open(p))
    except Exception: return default

movies = load(sys.argv[1], [])
queue  = load(sys.argv[2], {})
queue  = queue.get("records", []) if isinstance(queue, dict) else queue
tors   = load(sys.argv[3], [])
vm     = load(sys.argv[4], {})

files = [f for f in (vm.get("files") or [])
         if f["path"].lower().endswith((".mkv", ".mp4", ".avi", ".m4v", ".ts"))]
items = [i for i in (vm.get("items") or []) if "error" not in i]

hits = [m for m in movies if term and term in norm(m.get("title"))]
if not hits:
    print("  Radarr does not know this title, so it was never downloaded here.")
    print("  Check the Jellyseerr request (it may not have been approved/sent).")
    raise SystemExit
if len(hits) > 1:
    print("  %d Radarr movies match; the verdict covers the first one: %s"
          % (len(hits), hits[0].get("title")))
m = hits[0]
title = "%s (%s)" % (m.get("title"), m.get("year"))
has_file = bool(m.get("hasFile"))
qq = [x for x in queue if x.get("movieId") == m.get("id")]
qt = [t for t in tors if term and term in norm(t.get("name"))]

if has_file and files and items:
    f = files[0]
    print("  YES — you have %s." % title)
    print("  on disk: %s (%.2f GiB)" % (f["path"], f["size"] / 2**30))
    print("  Jellyfin sees it as %r (%s min), so the TV should list it."
          % (items[0].get("name"), items[0].get("runtime_min")))
    print("  If the TV still does not show it: log out/in or refresh the home screen.")
elif has_file and files and not items:
    print("  PARTLY — the file is on disk but Jellyfin has no item for it.")
    print("  run: sudo bash jellyfin_admin.sh --scan   (then recheck)")
    print("  if it still does not appear, Jellyfin's library path does not cover")
    print("  %s" % os.path.dirname(files[0]["path"]))
elif has_file and not files:
    print("  Radarr says it HAS the file, but nothing matching is under")
    print("  /data/media/movies — path mapping/import problem:")
    print("    Radarr path: %s" % m.get("path"))
    mf = m.get("movieFile") or {}
    if mf.get("relativePath"):
        print("    expected   : %s/%s" % (m.get("path"), mf.get("relativePath")))
elif qq:
    x = qq[0]
    left = x.get("sizeleft") or 0; size = x.get("size") or 1
    pct = max(0.0, min(100.0, 100.0 * (1 - left / size))) if size else 0
    stuck = (x.get("status") == "downloadClientUnavailable"
             or bool(x.get("errorMessage")) or not qt)
    if stuck:
        print("  STUCK — Radarr queued %s but it never reached a working" % title)
        print("  download client (%s, %.1f%%, no matching qBittorrent torrent)."
              % (x.get("status"), pct))
        if x.get("errorMessage"):
            print("  Radarr says: %s" % x.get("errorMessage"))
        print("  Read the diagnosis above: the download-client host/port,")
        print("  Radarr's own testall verdict, and qBittorrent's login-failure")
        print("  lines. A source IP banned after repeated failures answers 403")
        print("  and Radarr reports it as 'Authentication Failure' — restart")
        print("  qBt with --fix-qbt-auth; a real mismatch needs")
        print("  --fix-client-password. Either way finish with --retry.")
    else:
        print("  NOT YET — Radarr is still working on %s: %s / %s, %.1f%%, eta %s"
              % (title, x.get("status"), x.get("trackedDownloadState") or "-",
                 pct, x.get("timeleft") or "-"))
elif qt:
    t = qt[0]
    print("  NOT YET — a torrent exists (%s, %.1f%%) but Radarr has no queue"
          % (t.get("state"), 100 * (t.get("progress") or 0)))
    print("  entry for it. That usually means a category/import mismatch;")
    print("  check Radarr Activity and the qBt category (TODO 10c).")
else:
    print("  NO — Radarr has metadata for %s but no file and no active" % title)
    print("  download. Look at Radarr Activity/History for a failed grab,")
    print("  then trigger a search from the Radarr UI or via Jellyseerr.")
PY

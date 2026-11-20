#!/usr/bin/env bash
#
# Jellyfin admin actions that need no GUI: trigger the mandatory library scan
# after a media change, and set the server name (S5 shows a container id).
#
#   sudo bash jellyfin_admin.sh --show
#   sudo bash jellyfin_admin.sh --scan
#   sudo bash jellyfin_admin.sh --subs          (# what the TV will offer)
#   sudo bash jellyfin_admin.sh --server-name "Family Media"
#
# How it authenticates without a key in .env: it reads an EXISTING API key out
# of Jellyfin's own database *inside the VM* and uses it there. The token never
# leaves the VM and is never printed. If no key exists, it says so and prints
# the two GUI clicks instead of inventing credentials.
#
# Why not the public API: /System/Info/Public needs no auth but cannot trigger a
# scan; /Library/Refresh and /System/Configuration require an admin token.

set -uo pipefail

K=(-i /etc/media-vm/deploy_ed25519 -o IdentitiesOnly=yes
   -o UserKnownHostsFile=/etc/media-vm/known_hosts)
VM=jordan@192.168.122.10
ACTION="${1:-}"

[ "$(id -u)" -eq 0 ] || { echo "must run as root: sudo bash $0" >&2; exit 1; }

case "$ACTION" in
    --show|--scan|--subs|--server-name) : ;;
    *) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac

NEWNAME="${2:-}"
[ "$ACTION" = "--server-name" ] && [ -n "$NEWNAME" ] \
    || { [ "$ACTION" = "--server-name" ] && { echo "need a name" >&2; exit 1; }; }

ssh "${K[@]}" -o ConnectTimeout=15 "$VM" \
    "sudo env JF_ACTION='$ACTION' JF_NEWNAME='$NEWNAME' python3 -" <<'PY'
import json, os, sqlite3, subprocess, sys, tempfile, time, urllib.error, urllib.request

BASE = None
DB   = "/data/config/jellyfin/data/jellyfin.db"
act  = os.environ.get("JF_ACTION", "--show")
name = os.environ.get("JF_NEWNAME", "")

def out(*a): print(*a, flush=True)

# The compose file publishes "192.168.122.10:8096:8096/tcp", so Docker binds
# ONLY the VM's LAN address: 127.0.0.1:8096 refuses inside the VM by design
# (and diag S6 relies on the same binding to stay off the physical LAN).
# Probe the VM IP first, then loopback for a differently-bound deployment.
def pick_base():
    for cand in ("http://192.168.122.10:8096", "http://127.0.0.1:8096"):
        try:
            with urllib.request.urlopen(cand + "/System/Info/Public", timeout=10) as r:
                r.read()
            return cand
        except Exception:
            continue
    return None

BASE = pick_base()
if BASE is None:
    out("  Jellyfin is not answering on 192.168.122.10:8096 or 127.0.0.1:8096.")
    out("  Check the container before anything else:")
    out("    ssh <vm> 'sudo docker ps --filter name=jellyfin --format \"{{.Status}}\"'")
    sys.exit(5)
out("  endpoint: %s" % BASE)

def api(path, token=None, method="GET", body=None):
    req = urllib.request.Request(BASE + path, method=method)
    if token:
        req.add_header("X-Emby-Token", token)
        req.add_header("Authorization", 'MediaBrowser Token="%s"' % token)
    if body is not None:
        req.add_header("Content-Type", "application/json")
        req.data = json.dumps(body).encode()
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        out("  HTTP %s from %s" % (e.code, path))
        if e.code in (401, 403):
            out("  the API key read from jellyfin.db was rejected (revoked or scoped).")
            out("  GUI fallback: Dashboard -> API Keys -> create one, or use the")
            out("  Dashboard -> Scheduled Tasks -> 'Scan Media Library' -> RUN button.")
        sys.exit(7)
    except urllib.error.URLError as e:
        out("  cannot reach %s (%s)" % (BASE, e.reason))
        sys.exit(5)

# --- find an existing API key without printing it ---------------------------
def find_token():
    tmp = tempfile.mktemp(suffix=".db")
    try:
        subprocess.run(["cp", DB, tmp], check=True)
        # WAL sidecar so a busy DB still reads consistently
        for ext in ("-wal", "-shm"):
            subprocess.run(["cp", DB + ext, tmp + ext],
                           check=False, stderr=subprocess.DEVNULL)
        con = sqlite3.connect(tmp)
        tables = [r[0] for r in con.execute(
            "select name from sqlite_master where type='table'")]
        cand = [t for t in tables if "apikey" in t.lower()]
        for t in cand:
            cols = [r[1] for r in con.execute('pragma table_info("%s")' % t)]
            tok = next((c for c in cols
                        if c.lower() in ("accesstoken", "token", "key")), None)
            if not tok:
                continue
            row = con.execute('select "%s" from "%s" where "%s" is not null '
                              'and length("%s")>10 limit 1' % (tok, t, tok, tok)).fetchone()
            if row:
                return row[0], t
        return None, ",".join(cand) or "no *apikey* table"
    finally:
        for p in (tmp, tmp + "-wal", tmp + "-shm"):
            try: os.unlink(p)
            except OSError: pass

token, where = find_token()
if not token:
    out("  no usable API key found in the Jellyfin DB (%s)." % where)
    out("  GUI fallback:")
    out("    scan       : Dashboard -> Scheduled Tasks -> 'Scan Media Library' -> ▶")
    out("    server name: Dashboard -> General -> Server Name -> Family Media -> Save")
    sys.exit(2)

# --- actions ----------------------------------------------------------------
if act == "--show":
    st, cfg = api("/System/Configuration", token)
    out("  ServerName : %r" % (cfg or {}).get("ServerName"))
    st, tasks = api("/ScheduledTasks", token)
    for t in tasks or []:
        if t.get("Key") == "RefreshLibrary":
            out("  scan task  : %s  (last run %s)" %
                (t.get("State"), (t.get("LastExecutionResult") or {}).get("EndTimeUtc")))
    sys.exit(0)

if act == "--server-name":
    st, cfg = api("/System/Configuration", token)
    if not isinstance(cfg, dict) or "ServerName" not in cfg:
        out("  /System/Configuration has no ServerName field — use Dashboard -> General")
        sys.exit(3)
    before = cfg.get("ServerName")
    cfg["ServerName"] = name
    st, _ = api("/System/Configuration", token, "POST", cfg)
    st2, cfg2 = api("/System/Configuration", token)
    out("  ServerName %r -> %r (HTTP %s)" % (before, (cfg2 or {}).get("ServerName"), st))
    sys.exit(0)

if act == "--subs":
    # What the TV is actually offered: the sidecars exist on disk (Bazarr's job)
    # but Jellyfin must index them and parse the language out of the filename
    # suffix. ".es-MX.srt" is not an ISO code, so this is the one place that can
    # tell us whether the family will see "Spanish" or an undefined track.
    q = ("?Recursive=true&IncludeItemTypes=Movie"
         "&Fields=MediaSources,Path&Limit=200")
    st, data = api("/Items" + q, token)
    items = (data or {}).get("Items") or []
    # An API key has no user attached on some builds, and /Items then returns an
    # empty set (not an error). Retry through the first user before concluding
    # the library is empty — a false "no movies" would look like a scan problem.
    via = "/Items"
    if not items:
        st, users = api("/Users", token)
        for u in users or []:
            if not u.get("Id"):
                continue
            st, data = api("/Users/%s/Items%s" % (u["Id"], q), token)
            items = (data or {}).get("Items") or []
            via = "/Users/%s/Items" % u["Id"]
            if items:
                break
    if not items:
        out("  Jellyfin returned no movies (%s and /Users/*/Items) — has the"
            % via)
        out("  library ever scanned? Nothing can be verified until it has.")
        sys.exit(6)
    out("  source: %s" % via)
    SPANISH = {"spa", "es", "es-mx", "es-419", "ea", "spl", "es-la"}
    missing = 0
    for it in items:
        streams = []
        for ms in it.get("MediaSources") or []:
            streams += [x for x in (ms.get("MediaStreams") or [])
                        if (x.get("Type") or "") == "Subtitle"]
        out("")
        out("  %s" % (it.get("Name") or "?"))
        if not streams:
            out("    NO subtitle stream indexed")
            missing += 1
            continue
        spanish = 0
        for x in streams:
            lang = (x.get("Language") or "")
            label = (x.get("DisplayTitle") or x.get("Title") or "")
            bits = [lang or "?", "external" if x.get("IsExternal") else "embedded"]
            if x.get("IsHearingImpaired"):
                bits.append("HI")
            note = ""
            if not lang:
                note = "  <-- language NOT parsed from the filename"
            elif lang.lower() in SPANISH:
                spanish += 1
            else:
                note = "  <-- not Spanish"
            out("    %-14s %s%s" % (" ".join(bits), label, note))
        if not spanish:
            out("    no Spanish subtitle indexed")
            missing += 1
        else:
            out("    verdict: %d Spanish subtitle stream(s) indexed" % spanish)
    sys.exit(1 if missing else 0)

if act == "--scan":
    st, _ = api("/Library/Refresh", token, "POST")
    out("  POST /Library/Refresh -> HTTP %s" % st)
    deadline = time.time() + 900
    seen = False
    while time.time() < deadline:
        st, tasks = api("/ScheduledTasks", token)
        state = None
        for t in tasks or []:
            if t.get("Key") == "RefreshLibrary":
                state = t.get("State")
        if state == "Running":
            seen = True
            out("  scan running…")
        elif seen and state in ("Idle", None):
            out("  scan finished (state=%s)" % state)
            sys.exit(0)
        time.sleep(10)
    out("  scan did not start/finish within 15 min (state=%s)" % state)
    sys.exit(4)
PY

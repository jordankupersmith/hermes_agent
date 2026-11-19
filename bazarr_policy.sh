#!/usr/bin/env bash
#
# Set the household subtitle policy in Bazarr (decision 2026-11-19):
#
#   prefer  Spanish (Latino) (non-HI)  ->  Spanish (non-HI)
#   accept  Spanish (Latino) (HI)      ->  Spanish (HI)      <- e.g. es-MX.hi
#
# Bazarr's profile "items" are (language, forced, hi) triples, and an HI file
# does NOT satisfy a non-HI item — which is why `es-MX.hi.srt` sits on disk
# while the movie still reports missing=['ea']. Adding the HI variants makes
# that file count, while keeping the non-HI LatAm row first in preference order.
#
#   sudo bash bazarr_policy.sh                 # dry run: show what would change
#   sudo bash bazarr_policy.sh --apply         # change, verify, re-search
#   sudo bash bazarr_policy.sh --apply --profile 1 --movie 1
#
# Safety: the current profile JSON is backed up to /var/backups (root 600) and a
# copy of bazarr.db is taken first. If the POST does not verify, the previous
# profile is POSTed back automatically.

set -uo pipefail

BASE="http://192.168.122.10:6767"
ENVF=/opt/media-assistant/.env
K=(-i /etc/media-vm/deploy_ed25519 -o IdentitiesOnly=yes
   -o UserKnownHostsFile=/etc/media-vm/known_hosts)
VM=jordan@192.168.122.10
APPLY=0; PID=1; MID=""

while [ $# -gt 0 ]; do
    case "$1" in
        --apply) APPLY=1 ;;
        --profile) PID="$2"; shift ;;
        --movie) MID="$2"; shift ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
    shift
done

[ "$(id -u)" -eq 0 ] || { echo "must run as root: sudo bash $0" >&2; exit 1; }
KEY="$(grep -m1 '^BAZARR_API_KEY=' "$ENVF" 2>/dev/null | cut -d= -f2-)"
[ -n "$KEY" ] || { echo "no BAZARR_API_KEY in $ENVF — re-run phase5_apply.sh" >&2; exit 1; }

api() { curl -sS -m 30 -H "X-API-KEY: $KEY" "$@"; }

# ---- 1. back up -------------------------------------------------------------
ts="$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p /var/backups/bazarr
chmod 700 /var/backups/bazarr
api "$BASE/api/system/languages/profiles" > "/var/backups/bazarr/profiles-$ts.json"
chmod 600 "/var/backups/bazarr/profiles-$ts.json"

# A 401/500 writes an error body here, not a profile list. Fail before the
# Python step so a bad key never looks like "profile not found".
if ! python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
assert isinstance(d,list) and d and "profileId" in d[0]' \
        "/var/backups/bazarr/profiles-$ts.json" 2>/dev/null; then
    echo "  ERROR: Bazarr did not return a profile list — nothing was changed." >&2
    echo "  response: $(head -c 200 "/var/backups/bazarr/profiles-$ts.json")" >&2
    echo "  check BAZARR_API_KEY in $ENVF, or use: sudo bash bazarr_status.sh" >&2
    exit 2
fi
echo "  profile backup: /var/backups/bazarr/profiles-$ts.json"
ssh "${K[@]}" -o ConnectTimeout=15 "$VM" \
    "sudo cp /data/config/bazarr/db/bazarr.db /data/config/bazarr-backup-$ts.db && \
     sudo chmod 600 /data/config/bazarr-backup-$ts.db && echo '  db backup: /data/config/bazarr-backup-$ts.db'" \
    2>/dev/null || echo "  (db backup skipped — API rollback still applies)"

# ---- 2. build + (optionally) post ------------------------------------------
PROFILES="/var/backups/bazarr/profiles-$ts.json"
APPLY="$APPLY" PID="$PID" PROFILES="$PROFILES" python3 - "$BASE" "$KEY" <<'PY'
import json, os, sys, urllib.error, urllib.parse, urllib.request

base, key = sys.argv[1], sys.argv[2]
apply_ = os.environ.get("APPLY") == "1"
pid    = int(os.environ.get("PID") or 1)
all_profiles = json.load(open(os.environ["PROFILES"]))

old = next((p for p in all_profiles if p.get("profileId") == pid), None)
if not old:
    print("  profile id=%d not found (have: %s)" %
          (pid, [p.get("profileId") for p in all_profiles]))
    sys.exit(1)

# Bazarr stores profile item flags as the strings "True"/"False", and the
# cutoff as an ITEM id (65535 = "Any") — see bazarr/app/database.py
# get_profile_cutoff(), which compares `item['id'] == cutoff`. A row index is
# meaningless to it, so the last row's id is what goes in `cutoff`.
def as_bool(v):
    if isinstance(v, str):
        return v.strip().lower() == "true"
    return bool(v)

def flag(v):
    return "True" if v else "False"

items = old.get("items") or []
used = [int(i["id"]) for i in items if str(i.get("id", "")).isdigit()]
next_id = (max(used) + 1) if used else 1

def exact(lang, hi):
    for i in items:
        if (i.get("language") == lang and as_bool(i.get("hi")) == hi
                and not as_bool(i.get("forced"))):
            return i
    return None

def proto(lang):
    # copy the same-language non-HI row so audio_exclude / audio_only_include
    # (the "search only when..." behaviour) survives on the new HI row
    for i in items:
        if i.get("language") == lang and not as_bool(i.get("hi")):
            return i
    for i in items:
        if i.get("language") == lang:
            return i
    return items[0] if items else {}

def mk(lang, hi):
    global next_id
    hit = exact(lang, hi)
    if hit is not None:
        it = dict(hit)
        it["id"] = int(it.get("id") or next_id)
        if it["id"] >= next_id:
            next_id = it["id"] + 1
    else:
        it = dict(proto(lang))
        it["id"] = next_id
        next_id += 1
    it["language"] = lang
    it["hi"] = flag(hi)
    it["forced"] = flag(False)
    for k in ("audio_exclude", "audio_only_include"):
        it.setdefault(k, flag(False))
    return it

want = [mk("ea", False), mk("es", False), mk("ea", True), mk("es", True)]
cutoff = int(want[-1]["id"])

new = dict(old)
new["items"] = want
new["cutoff"] = cutoff
new["mustContain"] = old.get("mustContain") or []
new["mustNotContain"] = old.get("mustNotContain") or []

def show(tag, p):
    print("  %s profile id=%s %r cutoff=%s" %
          (tag, p["profileId"], p.get("name"), p.get("cutoff")))
    for n, i in enumerate(p.get("items") or [], 1):
        print("     %d. %-20s hi=%-5s forced=%-5s id=%s" %
              (n, i.get("language"), i.get("hi"), i.get("forced"), i.get("id")))
    print("     cutoff points at item id %s (65535 = any)" % p.get("cutoff"))

show("current", old)
show("wanted ", new)

if not apply_:
    print("\n  DRY RUN — re-run with --apply to save this profile.")
    sys.exit(0)

# The profiles API is READ-ONLY in Bazarr 1.5.x (only GET; everything else is
# 405). Profiles are written through POST /api/system/settings with a form
# field `languages-profiles` holding the COMPLETE list as JSON. The handler
# deletes any profile absent from that list, so sending only the edited profile
# would erase every other profile.
def push(profiles, strict=True):
    body = urllib.parse.urlencode(
        {"languages-profiles": json.dumps(profiles)}).encode()
    req = urllib.request.Request(
        base + "/api/system/settings", data=body, method="POST",
        headers={"X-API-KEY": key,
                 "Content-Type": "application/x-www-form-urlencoded"})
    try:
        with urllib.request.urlopen(req, timeout=90) as r:
            return r.status
    except urllib.error.HTTPError as e:
        text = e.read().decode("utf-8", "replace")[:400]
        print("\n  save rejected: HTTP %s" % e.code)
        print("  body: %s" % text)
        if strict:
            print("  nothing was saved; the previous profile is still active.")
            sys.exit(4)
        return None
    except urllib.error.URLError as e:
        print("\n  cannot reach Bazarr at %s (%s)" % (base, e.reason))
        if strict:
            sys.exit(5)
        return None

payload = [new if p.get("profileId") == pid else p for p in all_profiles]
st = push(payload)
print("\n  save -> HTTP %s (%d profile(s) sent)" % (st, len(payload)))

def fetch():
    req = urllib.request.Request(base + "/api/system/languages/profiles",
                                 headers={"X-API-KEY": key})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read())

got = next((p for p in fetch() if p.get("profileId") == pid), {})
items = got.get("items") or []
langs = [i.get("language") for i in items]
his   = [as_bool(i.get("hi")) for i in items]

ok = (len(items) == 4
      and langs == ["ea", "es", "ea", "es"]
      and his == [False, False, True, True]
      and str(got.get("cutoff")) == str(cutoff))
if ok:
    show("saved  ", got)
    print("  verify: OK — order, HI flags and cutoff item id round-tripped")
else:
    print("  verify: MISMATCH — rolling the previous profile back")
    print("    languages: %r  (wanted ['ea','es','ea','es'])" % langs)
    print("    hi flags : %r  (wanted [False,False,True,True])" % his)
    print("    cutoff   : %r  (wanted item id %r)" % (got.get("cutoff"), cutoff))
    if push(all_profiles, strict=False) is None:
        print("  ROLLBACK FAILED — restore by hand from:")
        print("    profile JSON: /var/backups/bazarr/profiles-*.json")
        print("    database    : /data/config/bazarr-backup-*.db")
    else:
        show("restored", old)
    sys.exit(3)
PY
rc=$?
[ "$rc" -eq 0 ] || [ "$rc" -eq 3 ] || exit "$rc"
[ "$APPLY" -eq 1 ] || exit 0
[ "$rc" -eq 0 ] || exit 3

# ---- 3. apply the profile to the movie, then re-search ----------------------
if [ -z "$MID" ]; then
    MID="$(api "$BASE/api/movies" | python3 -c '
import json,sys
d=json.load(sys.stdin); d=d.get("data",[]) if isinstance(d,dict) else d
ids=[m.get("radarrId") for m in d if m.get("radarrId")]
print(ids[0] if len(ids)==1 else "")' 2>/dev/null)"
fi
[ -n "$MID" ] || { echo "  cannot pick a single movie — pass --movie <radarrId>" >&2; exit 1; }

echo "  assigning profile $PID to radarrId $MID"
# POST /api/movies updates a movie's language profile; PATCH only runs actions
# (scan-disk / search-missing / sync). Verified in bazarr/api/movies/movies.py.
api -o /dev/null -w '    POST profile  -> HTTP %{http_code}\n' -X POST \
    "$BASE/api/movies?radarrid=$MID&profileid=$PID"
sleep 2
api -o /dev/null -w '    PATCH search  -> HTTP %{http_code}\n' -X PATCH \
    "$BASE/api/movies?radarrid=$MID&action=search-missing"

echo "  movie state now:"
api "$BASE/api/movies" | MID="$MID" python3 -c '
import json,sys,os
d=json.load(sys.stdin); d=d.get("data",[]) if isinstance(d,dict) else d
for m in d:
    if str(m.get("radarrId"))==os.environ["MID"]:
        print("    missing:", [(x.get("name"), "hi" if x.get("hi") else "no-hi")
                               for x in (m.get("missing_subtitles") or [])])
        print("    have   :", [(s.get("name"), s.get("path")) for s in (m.get("subtitles") or [])])
' 2>/dev/null

echo
echo "  Note: the *Upgrade Previously Downloaded Subtitles* task does NOT swap"
echo "  an HI file for a non-HI one.  Once the profile has an HI row for that"
echo "  language, upgrade.py forces the search to HI (is_hi stays 'True'), and"
echo "  it only accepts a subtitle scoring 2+ points above the stored one."
echo "  A non-HI file can only come from a fresh search (delete + scan + search)."
echo "  See bazarr_status.sh --upgrade for the task + its job record."

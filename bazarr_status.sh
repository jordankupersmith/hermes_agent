#!/usr/bin/env bash
#
# Why is there no es-LA .srt next to the film? Read-only.
# Asks Bazarr itself (API + log) AND the disk. Never echoes the API key.
#
#   sudo bash bazarr_status.sh                    # every movie in Bazarr
#   sudo bash bazarr_status.sh "ferris"           # one title (substring)
#   sudo bash bazarr_status.sh --assign <radarrId|title>
#   sudo bash bazarr_status.sh --search <radarrId|title>
#   sudo bash bazarr_status.sh --upgrade          (# "Upgrade Previously
#                                                  Downloaded Subtitles" task)
#
# fix 77 — this script used to filter on the literal string "hail mary" in the
# Bazarr list, the Radarr list and the log, so with three films in the library it
# could only ever report on one of them: the two newest had no subtitle check at
# all. The household policy (fix 59) drops embedded subtitle tracks on purpose
# and relies on Bazarr for an external es-LA .srt, so "the mkv has 0 subtitle
# streams" is expected while "there is no .srt beside it" is a real gap.

set -uo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "must run as root: sudo bash $0" >&2
    exit 1
fi

KEY="$(grep -m1 '^BAZARR_API_KEY=' /opt/media-assistant/.env 2>/dev/null | cut -d= -f2-)"
BASE="http://192.168.122.10:6767"
K=(-i /etc/media-vm/deploy_ed25519 -o IdentitiesOnly=yes -o UserKnownHostsFile=/etc/media-vm/known_hosts)
VM=jordan@192.168.122.10

# A title term (any non-flag first argument) narrows every list below.
TERM=""
case "${1:-}" in
    --assign|--search|--upgrade) : ;;
    "") : ;;
    *) TERM="$1" ;;
esac

if [ -z "${KEY:-}" ]; then
    echo "no BAZARR_API_KEY in /opt/media-assistant/.env — re-run phase5_apply.sh first" >&2
    exit 1
fi

api() { curl -s -m 10 -H "X-API-KEY: $KEY" "$BASE$1"; }

# The ground truth for "does the family get subtitles": the sidecar files on
# disk. Bazarr's own view can say "have" for a file it did not write here (a
# moved path, a stale DB row), and the mkv itself never carries one (fix 59).
SRT_LIST="$(ssh "${K[@]}" -o ConnectTimeout=15 "$VM" \
    "sudo find /data/media/movies -maxdepth 3 -type f -name '*.srt' -printf '%p\n' 2>/dev/null | head -200" \
    2>/dev/null)"

# resolve <radarrId|title> -> radarrId, using Bazarr's own movie list.
resolve_rid() {
    local a="${1:-}"
    case "$a" in
        ''|*[!0-9]*) : ;;
        *) printf '%s' "$a"; return 0 ;;
    esac
    api /api/movies | A="$a" python3 -c '
import json,os,re,sys
d=json.load(sys.stdin); d=d.get("data",[]) if isinstance(d,dict) else d
def norm(s): return re.sub(r"[^a-z0-9]+","",str(s).lower())
a=norm(os.environ["A"])
for m in d:
    if a and a in norm(m.get("title")):
        print(m.get("radarrId")); break
' 2>/dev/null
}


echo "== enabled languages (the list that unlocks Add New Profile) =="
api /api/system/languages | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: print("  (unparseable response)"); raise SystemExit
on=[(x.get("name"),x.get("code2"),x.get("code3")) for x in d if x.get("enabled")]
print("  ", on if on else "NONE ENABLED")
' 2>/dev/null

echo "== language profiles =="
api /api/system/languages/profiles | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: print("  (unparseable response)"); raise SystemExit
if not d: print("  NONE")
for p in d:
    items=[i.get("language") for i in (p.get("items") or [])]
    print("  id=%s name=%r cutoff=%r languages=%s must_not=%s" %
          (p.get("profileId"), p.get("name"), p.get("cutoff"), items, p.get("mustNotContain")))
    for n, i in enumerate(p.get("items") or [], 1):
        print("      %d. %-20s hi=%-5s forced=%-5s audio_exclude=%-5s audio_only_include=%s" %
              (n, i.get("language"), i.get("hi"), i.get("forced"),
               i.get("audio_exclude"), i.get("audio_only_include")))
' 2>/dev/null

echo "== enabled providers =="
api /api/providers | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: print("  (unparseable response)"); raise SystemExit
if isinstance(d, dict): d=d.get("data") or []
if not d:
    print("  (none used yet — Bazarr only lists providers it has actually tried)")
    raise SystemExit
for p in d:
    print("  %-24s status=%-18s retry=%s" % (p.get("name"), p.get("status"), p.get("retry")))
' 2>/dev/null

echo "== the movie(s), as Bazarr sees it =="
# fix 77 — filtered by TERM, not by a hardcoded title, and joined against the
# .srt files actually on disk. `profileId: None` is the silent killer: with no
# language profile Bazarr computes missing_subtitles as [] and never searches,
# so the movie simply sits there with nothing to download and no error.
api /api/movies | TERM="$TERM" SRT_LIST="$SRT_LIST" python3 -c '
import json, os, re, sys

def norm(s):
    return re.sub(r"[^a-z0-9]+", "", str(s).lower())

try:
    d = json.load(sys.stdin)
except Exception:
    print("  (unparseable response)"); raise SystemExit
d = d.get("data", []) if isinstance(d, dict) else d
if not d:
    print("  Bazarr has NO movies — the Radarr connection is not synced"); raise SystemExit

term = norm(os.environ.get("TERM") or "")
srts = [p for p in (os.environ.get("SRT_LIST") or "").splitlines() if p]
shown = 0
for m in d:
    title = m.get("title") or ""
    if term and term not in norm(title):
        continue
    shown += 1
    path = (m.get("path") or "").rstrip("/")
    mine = [p for p in srts if path and p.startswith(path + "/")]
    prof = m.get("profileId")
    print()
    print("  title      : %s" % title)
    print("  radarrId   : %s   monitored=%s" % (m.get("radarrId"), m.get("monitored")))
    if prof in (None, 0, ""):
        print("  profileId  : NONE  <-- Bazarr will NEVER search this movie")
        print("               (no language profile => missing_subtitles is empty)")
    else:
        print("  profileId  : %s" % prof)
    print("  missing    : %s" % (m.get("missing_subtitles") or []))
    for f in (m.get("files") or []):
        print("  bazarr file: %s" % f.get("path"))
        print("  bazarr subs: %s" % (f.get("subtitles") or []))
    if mine:
        print("  on disk    : %d .srt" % len(mine))
        for p in mine:
            print("               %s" % os.path.basename(p))
        hi = [p for p in mine if re.search(r"\.hi\.srt$", p, re.I)]
        if hi:
            print("  verdict    : es-LA subtitle present (%s)" % os.path.basename(hi[0]))
        else:
            print("  verdict    : subtitle present, but no .hi. variant")
    else:
        print("  on disk    : 0 .srt  <-- the mkv carries none (fix 59), so this")
        print("               title currently has NO subtitles at all")
        print("  verdict    : MISSING")
if not shown:
    print("  no movie matches %r. Bazarr sees %d:" % (os.environ.get("TERM"), len(d)))
    for m in d:
        print("    - %s (radarrId=%s, profileId=%s)" % (
            m.get("title"), m.get("radarrId"), m.get("profileId")))
' 2>/dev/null

# A title term with nothing in Bazarr is usually a sync gap, not a subtitle gap.
echo "== Radarr's side (the film half) =="
RDK="$(grep -m1 '^RADARR_API_KEY=' /opt/media-assistant/.env 2>/dev/null | cut -d= -f2-)"
if [ -n "${RDK:-}" ]; then
    curl -s -m 10 -H "X-Api-Key: $RDK" "http://192.168.122.10:7878/api/v3/movie" 2>/dev/null \
      | TERM="$TERM" python3 -c '
import json, os, re, sys

def norm(s):
    return re.sub(r"[^a-z0-9]+", "", str(s).lower())

term = norm(os.environ.get("TERM") or "")
try:
    d = json.load(sys.stdin)
except Exception:
    print("  (unparseable response)"); raise SystemExit
for m in d:
    if term and term not in norm(m.get("title")):
        continue
    print("  %s (%s) radarrId=%s hasFile=%s" % (
        m.get("title"), m.get("year"), m.get("id"), m.get("hasFile")))
    print("    path: %s" % m.get("path"))
' 2>/dev/null
fi

# opt-in: assign the (first) language profile to one movie, then search.
# Uses the documented API: POST /api/movies?radarrid=&profileid= (which also
# recomputes missing_subtitles) then PATCH ...&action=search-missing.
first_radarrid() {
    api /api/movies | TERM="$TERM" python3 -c '
import json,os,re,sys
d=json.load(sys.stdin); d=d.get("data",[]) if isinstance(d,dict) else d
def norm(s): return re.sub(r"[^a-z0-9]+","",str(s).lower())
t=norm(os.environ.get("TERM") or "")
ids=[m.get("radarrId") for m in d
     if m.get("radarrId") and (not t or t in norm(m.get("title")))]
print(ids[0] if len(ids)==1 else "")' 2>/dev/null
}

if [ "${1:-}" = "--assign" ]; then
    RID="$(resolve_rid "${2:-}")"
    if [ -z "$RID" ]; then
        RID="$(first_radarrid)"
        if [ -z "$RID" ]; then
            echo "--assign: Bazarr has 0 or >1 movies — pass the id explicitly: --assign <id>" >&2
            exit 1
        fi
        echo "(--assign: auto-selected the only movie, radarrId=$RID)"
    fi
    PID="$(api /api/system/languages/profiles | python3 -c '
import json,sys
d=json.load(sys.stdin)
print(d[0]["profileId"] if d else "")' 2>/dev/null)"
    if [ -z "${PID:-}" ]; then
        echo "no language profile exists — create one first" >&2
    else
        echo "== assigning profile $PID to radarrId $RID =="
        C1="$(curl -s -o /dev/null -w '%{http_code}' -m 30 -X POST \
             -H "X-API-KEY: $KEY" "$BASE/api/movies?radarrid=$RID&profileid=$PID")"
        echo "  POST profile -> HTTP $C1 (204 = accepted)"
        sleep 2
        C2="$(curl -s -o /dev/null -w '%{http_code}' -m 60 -X PATCH \
             -H "X-API-KEY: $KEY" "$BASE/api/movies?radarrid=$RID&action=search-missing")"
        echo "  PATCH search -> HTTP $C2 (204 = search ran)"
    fi
fi

# opt-in action: force a search for one movie (writes nothing but the .srt)
if [ "${1:-}" = "--search" ]; then
    SID="$(resolve_rid "${2:-}")"
    [ -n "$SID" ] || SID="$(first_radarrid)"
    echo "== forcing search-missing for radarrId ${SID:-?} =="
    CODE="$(curl -s -o /dev/null -w '%{http_code}' -m 60 -X PATCH \
        -H "X-API-KEY: $KEY" "$BASE/api/movies?radarrid=$SID&action=search-missing")"
    echo "  HTTP $CODE (204 = search ran; check the log + the folder for a .srt)"
fi

# opt-in action: run the "Upgrade Previously Downloaded Subtitles" task once.
# Variant-preserving: upgrade.py searches with the SUBTITLE's own hi flag
# (is_hi, kept 'True' because the profile now has an HI row for that language)
# and needs score+2, so it can improve an HI file but will not replace it with
# a non-HI one. The task is always registered; general.upgrade_subs decides
# whether it has any candidates at all (score < 117, inside days_to_upgrade_subs).
if [ "${1:-}" = "--upgrade" ]; then
    echo "== running the upgrade-subtitles task (HI-preserving) =="
    CODE="$(curl -s -o /dev/null -w '%{http_code}' -m 30 -X POST \
        -H "X-API-KEY: $KEY" "$BASE/api/system/tasks?taskid=upgrade_subtitles")"
    echo "  POST tasks?taskid=upgrade_subtitles -> HTTP $CODE (204 = queued)"
    echo "  it runs in the background; re-run this script in a minute to see"
    echo "  the result (recent jobs, missing/have above, upgrade log lines below)."
fi

echo "== relevant general settings =="
api /api/system/settings | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: print("  (unparseable response)"); raise SystemExit
g=d.get("general", d)
for k,v in sorted(g.items()):
    kl=k.lower()
    if any(s in kl for s in ("embed","subtitle","subfolder","path","upgrade")):
        print("  %-32s %s" % (k, v))
' 2>/dev/null

echo "== recent jobs (did the upgrade task run?) =="
api /api/system/jobs | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: print("  (unparseable response)"); raise SystemExit
if isinstance(d, dict): d=d.get("data") or []
if not d:
    print("  (jobs queue empty)"); raise SystemExit
rows=sorted(d, key=lambda j: j.get("job_id") or 0, reverse=True)[:10]
for j in rows:
    print("  #%-4s %-9s %-42s %s" % (j.get("job_id"), j.get("status"),
          (j.get("job_name") or "")[:42], j.get("last_run_time") or ""))
    pm=j.get("progress_message")
    if pm:
        print("        progress: %s" % str(pm)[:120])
' 2>/dev/null

echo "== bazarr log: upgrade run + this title (entry lines only) =="
ssh "${K[@]}" "$VM" 'sudo docker exec bazarr sh -c "grep -aiE \"upgrade|finished searching|no subtitles found|no subtitles to download\" /config/log/bazarr.log 2>/dev/null | grep -aE \"^[0-9]{4}-[0-9]{2}-[0-9]{2}\" | tail -n 8 | cut -c1-300"' 2>/dev/null | sed 's/^/  /'

echo "== bazarr log: last 5 errors/warnings (entry lines only) =="
ssh "${K[@]}" "$VM" 'sudo docker exec bazarr sh -c "grep -aE \"^[0-9]{4}-[0-9]{2}-[0-9]{2}.*\\|(ERROR|WARNING)\" /config/log/bazarr.log 2>/dev/null | tail -n 5 | cut -c1-240"' 2>/dev/null | sed 's/^/  /'

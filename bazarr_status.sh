#!/usr/bin/env bash
#
# Why is there no es-LA .srt next to the film? Read-only.
# Asks Bazarr itself (API + log). Never echoes the API key or any secret value.
#
# Run as root on clawbox:   sudo bash bazarr_status.sh
#                            sudo bash bazarr_status.sh --assign [radarrId]
#                            sudo bash bazarr_status.sh --search [radarrId]
#                            sudo bash bazarr_status.sh --upgrade   (run the
#                              "Upgrade Previously Downloaded Subtitles" task)

set -uo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "must run as root: sudo bash $0" >&2
    exit 1
fi

KEY="$(grep -m1 '^BAZARR_API_KEY=' /opt/media-assistant/.env 2>/dev/null | cut -d= -f2-)"
BASE="http://192.168.122.10:6767"
K=(-i /etc/media-vm/deploy_ed25519 -o IdentitiesOnly=yes -o UserKnownHostsFile=/etc/media-vm/known_hosts)
VM=jordan@192.168.122.10

if [ -z "${KEY:-}" ]; then
    echo "no BAZARR_API_KEY in /opt/media-assistant/.env — re-run phase5_apply.sh first" >&2
    exit 1
fi

api() { curl -s -m 10 -H "X-API-KEY: $KEY" "$BASE$1"; }

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

echo "== the movie, as Bazarr sees it =="
api /api/movies | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: print("  (unparseable response)"); raise SystemExit
if isinstance(d, dict): d=d.get("data") or []
if not d:
    print("  Bazarr has NO movies — the Radarr connection is not synced"); raise SystemExit
hit=[m for m in d if "hail mary" in str(m.get("title","")).lower()]
if not hit:
    print("  %d movies in Bazarr but not this one:" % len(d))
    for m in d[:10]: print("    -", m.get("title"))
    raise SystemExit
for m in hit:
    print("  title      :", m.get("title"))
    print("  radarrId   :", m.get("radarrId"))
    print("  profileId  :", m.get("profileId"))
    print("  monitored  :", m.get("monitored"))
    print("  path       :", m.get("path"))
    print("  missing    :", m.get("missing_subtitles"))
    print("  have       :", [(s.get("name"), s.get("path")) for s in (m.get("subtitles") or [])])
    for f in (m.get("files") or []):
        print("  file       :", f.get("path"), "| subtitles:", f.get("subtitles"))
' 2>/dev/null

# opt-in: assign the (first) language profile to one movie, then search.
# Uses the documented API: POST /api/movies?radarrid=&profileid= (which also
# recomputes missing_subtitles) then PATCH ...&action=search-missing.
first_radarrid() {
    api /api/movies | python3 -c '
import json,sys
d=json.load(sys.stdin)
d=d.get("data",[]) if isinstance(d,dict) else d
ids=[m.get("radarrId") for m in d if m.get("radarrId")]
print(ids[0] if len(ids)==1 else "")' 2>/dev/null
}

if [ "${1:-}" = "--assign" ]; then
    RID="${2:-}"
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
    SID="${2:-$(first_radarrid)}"
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
ssh "${K[@]}" "$VM" 'sudo docker exec bazarr sh -c "grep -aiE \"upgrade|finished searching|hail mary|no subtitles found\" /config/log/bazarr.log 2>/dev/null | grep -aE \"^[0-9]{4}-[0-9]{2}-[0-9]{2}\" | tail -n 8 | cut -c1-300"' 2>/dev/null | sed 's/^/  /'

echo "== bazarr log: last 5 errors/warnings (entry lines only) =="
ssh "${K[@]}" "$VM" 'sudo docker exec bazarr sh -c "grep -aE \"^[0-9]{4}-[0-9]{2}-[0-9]{2}.*\\|(ERROR|WARNING)\" /config/log/bazarr.log 2>/dev/null | tail -n 5 | cut -c1-240"' 2>/dev/null | sed 's/^/  /'

echo "== what Radarr serves Bazarr (first movie entry) =="
RDK="$(grep -m1 '^RADARR_API_KEY=' /opt/media-assistant/.env 2>/dev/null | cut -d= -f2-)"
if [ -n "${RDK:-}" ]; then
    curl -s -m 10 -H "X-Api-Key: $RDK" "http://192.168.122.10:7878/api/v3/movie" 2>/dev/null \
      | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: print("  (unparseable response)"); raise SystemExit
for m in d:
    if "hail mary" in str(m.get("title","")).lower():
        print("  %s (%s) | path=%s | hasFile=%s" % (m.get("title"), m.get("year"), m.get("path"), m.get("hasFile")))
        for f in (m.get("movieFile") and [m["movieFile"]] or []):
            print("  file:", f.get("relativePath"), "| size:", f.get("size"))
' 2>/dev/null
fi

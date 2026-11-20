#!/usr/bin/env bash
#
# Why is there no es-LA .srt next to the film? Read-only.
# Asks Bazarr itself (API + log) AND the disk. Never echoes the API key.
#
#   sudo bash bazarr_status.sh                    # every movie in Bazarr
#   sudo bash bazarr_status.sh "ferris"           # one title (substring)
#   sudo bash bazarr_status.sh --assign <radarrId|title>
#   sudo bash bazarr_status.sh --assign-all       (# every movie with no profile)
#   sudo bash bazarr_status.sh --default-profile  (# future Radarr syncs)
#   sudo bash bazarr_status.sh --search <radarrId|title>
#   sudo bash bazarr_status.sh --upgrade          (# "Upgrade Previously
#                                                  Downloaded Subtitles" task)
#
# fix 80/81 — a movie synced from Radarr with no language profile has an empty
# missing_subtitles, so Bazarr never searches it and never errors. Future syncs
# get the default profile; existing ones are repaired with --assign-all. The
# settings write must use flat `settings-<section>-<key>` fields: Bazarr's
# save_settings() skips any other shape and still answers 204 (see fix 81).
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
    --assign|--assign-all|--search|--upgrade|--default-profile) : ;;
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
    # fix 82 — the path Bazarr returns is the .mkv FILE, not the folder. This
    # block tested `p.startswith(path + "/")`, which can never be true for a
    # file path, so EVERY movie printed "0 .srt" and "MISSING" no matter what
    # was on disk. It is fix 79 in the opposite direction: a confident wrong
    # answer instead of a confident empty one. Join on the directory.
    path = (m.get("path") or "").rstrip("/")
    folder = os.path.dirname(path) if os.path.splitext(path)[1] else path
    mine = sorted(p for p in srts if folder and os.path.dirname(p) == folder)

    def classify(p):
        b = os.path.basename(p).lower()
        if b.endswith(".srt"):
            b = b[:-4]
        hi = b.endswith(".hi")
        if hi:
            b = b[:-3]
        if b.endswith((".es-mx", ".es-419", ".ea", ".spl")):
            return "ea", hi
        if b.endswith((".es", ".spa")):
            return "es", hi
        return "?", hi

    # the owner order: ea < es < ea:hi < es:hi (row 1 is the best outcome)
    RANK = {("ea", False): 1, ("es", False): 2, ("ea", True): 3, ("es", True): 4}
    LABEL = {1: "LatAm Spanish, non-HI (best)",
             2: "Castilian Spanish, non-HI",
             3: "LatAm Spanish, HI",
             4: "Castilian Spanish, HI"}
    ranked = sorted(((RANK.get(classify(p), 9), p) for p in mine),
                    key=lambda x: x[0])
    miss = [(x.get("code2") or "?") + (".hi" if x.get("hi") else "")
            for x in (m.get("missing_subtitles") or [])]
    prof = m.get("profileId")

    print()
    print("  title      : %s" % title)
    print("  radarrId   : %s   monitored=%s" % (m.get("radarrId"), m.get("monitored")))
    if prof in (None, 0, ""):
        print("  profileId  : NONE  <-- Bazarr will NEVER search this movie")
        print("               (no language profile => missing_subtitles is empty)")
    else:
        print("  profileId  : %s" % prof)
    print("  missing    : %s" % (", ".join(miss) if miss else "none"))
    if mine:
        print("  on disk    : %d .srt" % len(mine))
        for rank, p in ranked:
            print("               %-56s %s" % (os.path.basename(p),
                  LABEL.get(rank, "unclassified")))
        best = ranked[0][0]
        if best == 9:
            print("  verdict    : subtitle present but the language is unclassified")
        else:
            print("  verdict    : %s" % LABEL[best])
    else:
        print("  on disk    : 0 .srt — no sidecar beside the .mkv")
        print("  verdict    : MISSING — no Spanish subtitle at all")
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

# fix 80 — the DEFAULT movie profile. Every movie synced from Radarr arrived
# with profileId=None, so Bazarr computed missing_subtitles as empty and never
# searched: the scheduled "Searched for missing movies subtitles" job ran every
# 6 h and skipped them, with no error anywhere. Setting the default fixes every
# FUTURE sync; `--assign-all` fixes what is already in the library.
if [ "${1:-}" = "--default-profile" ]; then
    echo "== fix: give new movies a default language profile =="
    BASE="$BASE" KEY="$KEY" PID_OVERRIDE="${2:-}" python3 - <<'PY'
import json, os, sys, urllib.error, urllib.parse, urllib.request

base, key = os.environ["BASE"].rstrip("/"), os.environ["KEY"]


def get(path):
    req = urllib.request.Request(base + path, headers={"X-API-KEY": key})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read() or b"{}")


def post(pairs):
    body = urllib.parse.urlencode(pairs).encode()
    req = urllib.request.Request(
        base + "/api/system/settings", data=body, method="POST",
        headers={"X-API-KEY": key,
                 "Content-Type": "application/x-www-form-urlencoded"})
    try:
        with urllib.request.urlopen(req, timeout=90) as r:
            return r.status
    except urllib.error.HTTPError as e:
        print("  save rejected: HTTP %s" % e.code)
        print("  body: %s" % e.read().decode("utf-8", "replace")[:300])
        raise SystemExit(4)


profiles = get("/api/system/languages/profiles")
if not profiles:
    print("  no language profile exists — create one first (bazarr_policy.sh)")
    raise SystemExit(5)
want = os.environ.get("PID_OVERRIDE") or str(profiles[0]["profileId"])
if not any(str(p.get("profileId")) == want for p in profiles):
    print("  profileId %s does not exist (have: %s)" %
          (want, [p.get("profileId") for p in profiles]))
    raise SystemExit(5)
cfg = get("/api/system/settings")
if not isinstance(cfg, dict) or "general" not in cfg:
    print("  unexpected /api/system/settings shape (keys: %s) — refusing to POST it"
          % (sorted(cfg)[:8] if isinstance(cfg, dict) else type(cfg).__name__))
    raise SystemExit(6)
gen = dict(cfg.get("general") or {})
print("  before: movie_default_enabled=%s movie_default_profile=%s" % (
    gen.get("movie_default_enabled"), gen.get("movie_default_profile")))
if gen.get("movie_default_enabled") and str(gen.get("movie_default_profile")) == want:
    print("  nothing to do — new movies already get profile %s" % want)
    raise SystemExit(0)

# fix 81 — the wire format. Bazarr's save_settings() (app/config.py) splits
# every form key on '-' and applies it ONLY when the shape is
# settings-<section>-<key> (len == 3) or settings-<section>-<key>-<sub> (len 4).
# This block first sent `settings-general=<whole section as JSON>` — 46 keys that
# split into TWO parts, so every one fell straight through the if-chain and the
# handler returned 204 having stored nothing. A JSON blob is not a partial
# write, it is no write at all, and the API says 204 either way.
#
# So: one flat field per setting. Nothing else is resent, and nothing else can be
# blanked, because save_settings() only touches the keys present in the form.
fields = [
    ("settings-general-movie_default_enabled", "true"),
    ("settings-general-movie_default_profile", want),
]
st = post(fields)
print("  save -> HTTP %s (%d field(s): %s)" % (
    st, len(fields), ", ".join(k for k, _ in fields)))

gen2 = dict(get("/api/system/settings").get("general") or {})
ok = bool(gen2.get("movie_default_enabled")) and \
    str(gen2.get("movie_default_profile")) == want
print("  after : movie_default_enabled=%s movie_default_profile=%s" % (
    gen2.get("movie_default_enabled"), gen2.get("movie_default_profile")))
if not ok:
    print("  MISMATCH — the default did not persist; nothing else was changed")
    raise SystemExit(3)
print("  verify: OK — movies synced from Radarr from now on get profile %s" % want)
PY
    RC=$?
    [ "$RC" -eq 0 ] || { echo "  --default-profile failed (rc=$RC)"; exit "$RC"; }
fi

# fix 80 — assign the profile to every movie that has none, then search.
# Idempotent: a movie that already has a profile is left alone.
if [ "${1:-}" = "--assign-all" ]; then
    echo "== assign the language profile to every movie with profileId NONE =="
    PID="$(api /api/system/languages/profiles | python3 -c '
import json,sys
d=json.load(sys.stdin)
print(d[0]["profileId"] if d else "")' 2>/dev/null)"
    [ -n "${PID:-}" ] || { echo "  no language profile exists — run bazarr_policy.sh" >&2; exit 5; }
    RIDS="$(api /api/movies | python3 -c '
import json,sys
d=json.load(sys.stdin); d=d.get("data",[]) if isinstance(d,dict) else d
for m in d:
    if m.get("radarrId") and not m.get("profileId"):
        print(m.get("radarrId"))' 2>/dev/null)"
    if [ -z "${RIDS:-}" ]; then
        echo "  nothing to do — every movie already has a profile"
    else
        echo "  profile $PID -> radarrId $(printf '%s' "$RIDS" | paste -sd' ' -)"
        for RID in $RIDS; do
            C1="$(curl -s -o /dev/null -w '%{http_code}' -m 30 -X POST \
                 -H "X-API-KEY: $KEY" "$BASE/api/movies?radarrid=$RID&profileid=$PID")"
            C2="$(curl -s -o /dev/null -w '%{http_code}' -m 60 -X PATCH \
                 -H "X-API-KEY: $KEY" "$BASE/api/movies?radarrid=$RID&action=search-missing")"
            echo "    radarrId=$RID  POST profile -> $C1   PATCH search -> $C2"
        done
    fi
    # verify by re-reading: a 204 means "accepted", not "stored" (fixes 71/73)
    sleep 3
    api /api/movies | python3 -c '
import json,sys
d=json.load(sys.stdin); d=d.get("data",[]) if isinstance(d,dict) else d
bad=[m for m in d if m.get("radarrId") and not m.get("profileId")]
print("  verify: %d movie(s), %d still without a profile" % (len(d), len(bad)))
for m in d:
    print("    %-38s profileId=%s missing=%s" % (
        (m.get("title") or "")[:38], m.get("profileId"), m.get("missing_subtitles")))
if bad:
    print("  MISMATCH — the profile did not persist for: %s" %
          ", ".join(str(m.get("title")) for m in bad))
    raise SystemExit(3)
'
    RC=$?
    [ "$RC" -eq 0 ] || { echo "  --assign-all failed (rc=$RC)"; exit "$RC"; }
fi

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

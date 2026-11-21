#!/usr/bin/env bash
#
# Radarr: refuse the releases that media-normalize would have to fix (fix 87).
#
# Why: the normalizer is the safety net, not the first line of defence. An
# 11-audio TrueHD/Atmos remux costs 30-45 GB of download and then gets rewritten
# down to one AC3 track, so the point is to never grab it. That is a Custom
# Format score, and it has to be a **release-title** condition: at grab time
# Radarr has not downloaded the file yet, so every MediaInfo condition (audio
# codec, video codec, channels) is UNKNOWN and matches nothing. A CF built from
# MediaInfo therefore cannot block a download - it can only score a file that
# already exists. Title regexes work at grab time, which is the only moment the
# decision matters.
#
#   sudo bash radarr_admin.sh                     # status (read-only)
#   sudo bash radarr_admin.sh --custom-formats    # show the plan, write nothing
#   sudo bash radarr_admin.sh --custom-formats --apply
#   sudo bash radarr_admin.sh --quality-profile   # show the plan, write nothing
#   sudo bash radarr_admin.sh --quality-profile --apply
#   sudo bash radarr_admin.sh --restore <backup.json> --apply
#
# The quality profile keeps `Bluray-1080p Remux` ALLOWED on purpose. The three
# films already in the library are remuxes; removing the quality would make
# Radarr treat those files as "not wanted" and start searching for replacements
# it can never beat. Future remuxes are blocked by the -10000 title score
# instead, which leaves the existing files valid and the library quiet.
#
# Every write is planned first, backed up to /var/backups/phase5 (0600), and
# read back - a 202 is not proof (fix 84). Nothing is written without --apply.
set -uo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "must run as root: sudo bash $0" >&2
    exit 1
fi

ENVF="${ENVF:-/opt/media-assistant/.env}"
KEY="$(grep -m1 '^RADARR_API_KEY=' "$ENVF" 2>/dev/null | cut -d= -f2-)"
BASE="${BASE:-http://192.168.122.10:7878}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/phase5}"

MODE=status
APPLY=0
PROFILE=""
QUALITIES="${QUALITIES:-WEBDL-1080p,Bluray-1080p,Remux-1080p}"
CUTOFF="${CUTOFF:-Bluray-1080p}"
RESTORE=""

usage() {
    cat >&2 <<'USAGE'
usage: sudo bash radarr_admin.sh [--status]
       sudo bash radarr_admin.sh --custom-formats [--apply] [--profile <id|name>]
       sudo bash radarr_admin.sh --quality-profile [--apply] [--profile <id|name>]
                                  [--qualities a,b,c] [--cutoff <name>]
       sudo bash radarr_admin.sh --restore <backup.json> --apply

  --apply     write. Without it every command only prints the plan.
  --profile   default: the quality profile the library's movies use, or an error
              if they disagree (so the scores land where the films actually are).
  --qualities default: WEBDL-1080p,Bluray-1080p,Remux-1080p
  --cutoff    default: Bluray-1080p
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --status)          MODE=status ;;
        --custom-formats)  MODE=custom-formats ;;
        --quality-profile) MODE=quality-profile ;;
        --apply)           APPLY=1 ;;
        --dry-run)         APPLY=0 ;;
        --profile)         PROFILE="${2:-}"; shift ;;
        --qualities)       QUALITIES="${2:-}"; shift ;;
        --cutoff)          CUTOFF="${2:-}"; shift ;;
        --restore)         RESTORE="${2:-}"; MODE=restore; shift ;;
        -h|--help)         usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
    esac
    shift
done

if [ -z "${KEY:-}" ]; then
    echo "no RADARR_API_KEY in $ENVF — re-run phase5_apply.sh first" >&2
    exit 1
fi

MODE="$MODE" APPLY="$APPLY" PROFILE="$PROFILE" QUALITIES="$QUALITIES" \
CUTOFF="$CUTOFF" RESTORE="$RESTORE" BACKUP_DIR="$BACKUP_DIR" \
BASE="$BASE" KEY="$KEY" python3 - <<'PY'
import json
import os
import sys
import time
import urllib.error
import urllib.request

BASE = os.environ["BASE"].rstrip("/")
KEY = os.environ["KEY"]
MODE = os.environ.get("MODE", "status")
APPLY = os.environ.get("APPLY") == "1"
WANT_PROFILE = os.environ.get("PROFILE", "")
QUALITIES = [q.strip() for q in os.environ.get("QUALITIES", "").split(",") if q.strip()]
CUTOFF = os.environ.get("CUTOFF", "").strip()
RESTORE = os.environ.get("RESTORE", "")
BACKUP_DIR = os.environ.get("BACKUP_DIR", "/var/backups/phase5")

# Fix 87. `-10000` is below the default minFormatScore of 0, so a release that
# matches is rejected outright; +50/+25 only break ties. Every condition is a
# release-title regex because MediaInfo does not exist at grab time.
CFS = [
    {"name": "NO TrueHD / Atmos", "regex": r"(?i)(truehd|atmos)", "score": -10000},
    {"name": "NO DTS-HD / DTS-X", "regex": r"(?i)(dts[-. ]?hd|dts[-. ]?x)", "score": -10000},
    {"name": "NO Remux", "regex": r"(?i)remux", "score": -10000},
    {"name": "NO MULTi / DUAL", "regex": r"(?i)\b(multi|dual)\b", "score": -10000},
    {"name": "PREF H.264", "regex": r"(?i)(x264|h[. ]?264)", "score": 50},
    {"name": "PREF AC3", "regex": r"(?i)(\bac3\b|\bdd5[. ]?1\b)", "score": 25},
]
CF_BY_NAME = {c["name"].lower(): c for c in CFS}


def die(msg, code=1):
    print("FAIL: %s" % msg, file=sys.stderr)
    sys.exit(code)


def call(path, method="GET", body=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(
        BASE + path, data=data, method=method,
        headers={"X-Api-Key": KEY, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")[:500]
    except Exception as e:                                   # noqa: BLE001
        die("cannot reach Radarr at %s: %r" % (BASE, e), 2)


def get(path):
    code, body = call(path)
    if code != 200:
        die("GET %s -> HTTP %s %s" % (path, code, body), 2)
    return body


def put(path, body):
    code, out = call(path, "PUT", body)
    if code not in (200, 201, 202):
        die("PUT %s -> HTTP %s %s" % (path, code, out), 5)
    return out


def post(path, body):
    code, out = call(path, "POST", body)
    if code not in (200, 201, 202):
        die("POST %s -> HTTP %s %s" % (path, code, out), 5)
    return out


def profiles():
    p = get("/api/v3/qualityprofile")
    if not isinstance(p, list) or not p:
        die("Radarr returned no quality profiles", 2)
    return p


def movie_profile_counts():
    """Which profile the films are actually on. Radarr ships six defaults, so
    this is the only reliable way to know where the scores have to land."""
    code, ms = call("/api/v3/movie")
    if code != 200 or not isinstance(ms, list):
        return {}
    counts = {}
    for m in ms:
        pid = m.get("qualityProfileId")
        if pid is not None:
            counts[str(pid)] = counts.get(str(pid), 0) + 1
    return counts


def profile_by_id(pid):
    for p in profiles():
        if str(p.get("id")) == str(pid):
            return p
    die("profile id=%s disappeared after the write" % pid, 5)


def pick(ps, used):
    """The profile that matters is the one the films are on — Radarr ships six
    default profiles, so "the only profile" is never true on a fresh install."""
    if WANT_PROFILE:
        for p in ps:
            if str(p.get("id")) == WANT_PROFILE or \
                    str(p.get("name", "")).lower() == WANT_PROFILE.lower():
                return p
        die("no quality profile matching %r — available: %s"
            % (WANT_PROFILE, ", ".join("%s(id=%s)" % (p.get("name"), p.get("id"))
                                       for p in ps)), 2)
    if len(used) == 1:
        pid = next(iter(used))
        for p in ps:
            if str(p.get("id")) == str(pid):
                return p
        die("the movies point at quality profile id=%s, which Radarr does not return"
            % pid, 2)
    if not used:
        if len(ps) == 1:
            return ps[0]
        die("no movies yet and %d quality profiles; choose one with --profile <id|name>: %s"
            % (len(ps), ", ".join("%s(id=%s)" % (p.get("name"), p.get("id")) for p in ps)), 2)
    die("the library uses %d quality profiles (%s); choose one with --profile <id|name>"
        % (len(used), ", ".join("id=%s x%d" % (i, n) for i, n in sorted(used.items()))), 2)


def walk(items):
    """Yield every quality node, including nested group children."""
    for it in items or []:
        if isinstance(it, dict):
            yield it
            for sub in walk(it.get("items") or []):
                yield sub


def quality_nodes(prof):
    for it in walk(prof.get("items")):
        q = it.get("quality") or {}
        if q.get("name"):
            yield it, q


def allowed_names(prof):
    return [q.get("name") for it, q in quality_nodes(prof) if it.get("allowed")]


def all_quality_names(prof):
    return [q.get("name") for _, q in quality_nodes(prof)]


# Radarr renamed the remux quality: 5.20 calls it `Remux-1080p`, older builds
# `Bluray-1080p Remux`. Both mean the same tier, and the *reason* we keep it
# allowed is unchanged, so resolve the slot instead of demanding one spelling.
QUALITY_ALIASES = {
    "remux-1080p": {"remux-1080p", "bluray-1080p remux"},
    "bluray-1080p remux": {"remux-1080p", "bluray-1080p remux"},
    "webdl-1080p": {"webdl-1080p", "webl-1080p"},
    "webl-1080p": {"webdl-1080p", "webl-1080p"},
}


def resolve_quality(have, want):
    group = QUALITY_ALIASES.get(want.lower(), {want.lower()})
    for name_lc, q in have.items():
        if name_lc in group:
            return q
    return None


def want_quality_ids(prof):
    have = {str(q["name"]).lower(): q for _, q in quality_nodes(prof)}
    out = {}
    missing = []
    for want in QUALITIES:
        q = resolve_quality(have, want)
        if q is None:
            missing.append(want)
        else:
            out[str(q["name"]).lower()] = q
    if missing:
        die("this Radarr has no quality named %s — it offers: %s"
            % (", ".join(repr(m) for m in missing),
               ", ".join(all_quality_names(prof))), 4)
    return out


def spec_body(item):
    return {
        "name": item["name"],
        "includeCustomFormatWhenRenaming": False,
        "specifications": [{
            "name": "Release Title",
            "implementation": "ReleaseTitleSpecification",
            "negate": False,
            "required": True,
            "fields": [{"name": "value", "value": item["regex"]}],
        }],
    }


def reduced(cf):
    """Only what we control, so an extra server-side field cannot cause a
    rewrite on every run (idempotence has to be real, not cosmetic)."""
    specs = []
    for s in cf.get("specifications") or []:
        value = next((f.get("value") for f in s.get("fields") or []
                      if str(f.get("name")) == "value"), None)
        specs.append((str(s.get("implementation")),
                      bool(s.get("negate")), bool(s.get("required")), str(value)))
    return (str(cf.get("name")), bool(cf.get("includeCustomFormatWhenRenaming")),
            tuple(sorted(specs)))


def score_map(prof):
    return {str(fi.get("name")): fi.get("score") for fi in prof.get("formatItems") or []}


def backup(prof):
    try:
        os.makedirs(BACKUP_DIR, exist_ok=True)
        path = os.path.join(BACKUP_DIR, "radarr-qualityprofile-%s-%s.json"
                            % (prof.get("id"), time.strftime("%Y%m%dT%H%M%SZ")))
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as fh:
            json.dump(prof, fh, indent=1, sort_keys=True)
        return path
    except Exception as e:                                   # noqa: BLE001
        die("cannot write the profile backup in %s (%r) — refusing to PUT"
            % (BACKUP_DIR, e), 6)


status = get("/api/v3/system/status")
print("== Radarr %s ==" % status.get("version", "?"))

ps = profiles()
print("== quality profiles (%d) ==" % len(ps))
for p in ps:
    print("  id=%-2s %-24r allowed=%s" % (p.get("id"), p.get("name"),
                                          ", ".join(allowed_names(p)) or "(none)"))
    print("       cutoff=%s  minFormatScore=%s  cutoffFormatScore=%s  upgradeAllowed=%s"
          % (p.get("cutoff"), p.get("minFormatScore"), p.get("cutoffFormatScore"),
             p.get("upgradeAllowed")))

cfs = get("/api/v3/customformat")
byname = {str(c.get("name", "")).lower(): c for c in cfs}
print("== custom formats (%d in Radarr, %d managed) ==" % (len(cfs), len(CFS)))
for item in CFS:
    have = byname.get(item["name"].lower())
    print("  %-18s %-9s %s" % (item["name"], "present" if have else "MISSING",
                               "score %+d" % item["score"]))

used = movie_profile_counts()
names_by_id = {str(p.get("id")): p.get("name") for p in ps}
print("== library ==")
if used:
    for pid, n in sorted(used.items()):
        print("  %d movie(s) on profile id=%s %r" % (n, pid, names_by_id.get(pid, "?")))
else:
    print("  no movies yet — the profile cannot be inferred from the library")

if MODE == "status":
    sys.exit(0)

prof = pick(ps, used)
print("== profile %r (id=%s) ==" % (prof.get("name"), prof.get("id")))

# ------------------------------------------------------------------- restore
if MODE == "restore":
    if not RESTORE:
        die("--restore needs a backup file", 2)
    if not APPLY:
        die("--restore writes; re-run with --apply", 2)
    body = json.load(open(RESTORE))
    if str(body.get("id")) != str(prof.get("id")):
        die("%s is profile id=%s but %s is id=%s — refusing to cross-apply"
            % (RESTORE, body.get("id"), prof.get("name"), prof.get("id")), 2)
    put("/api/v3/qualityprofile/%s" % prof.get("id"), body)
    after = profile_by_id(prof.get("id"))
    print("  restored: allowed=%s cutoff=%s"
          % (", ".join(allowed_names(after)) or "(none)", after.get("cutoff")))
    sys.exit(0)

# ---------------------------------------------------------------- custom formats
if MODE == "custom-formats":
    schema = get("/api/v3/customformat/schema")
    impls = {}
    if isinstance(schema, dict):
        for k, v in schema.items():
            if isinstance(v, dict):
                impls[str(v.get("implementation") or k).lower()] = v
    elif isinstance(schema, list):
        for v in schema:
            if isinstance(v, dict):
                impls[str(v.get("implementation", "")).lower()] = v
    if "releasetitlespecification" not in impls:
        die("this Radarr offers no ReleaseTitleSpecification; it offers: %s"
            % (", ".join(sorted(str(v.get("implementation") or k)
                                 for k, v in impls.items())) or "(nothing)"), 4)

    ids = {}
    plan = []
    for item in CFS:
        want = spec_body(item)
        have = byname.get(item["name"].lower())
        if have is None:
            plan.append(("create", item, None))
        elif reduced(have) != reduced(want):
            plan.append(("update", item, have.get("id")))
        else:
            plan.append(("ok", item, have.get("id")))
            ids[item["name"]] = have.get("id")

    for action, item, cid in plan:
        print("  %-6s %-18s %+d  %s" % (action, item["name"], item["score"], item["regex"]))

    want_scores = {item["name"]: item["score"] for item in CFS}
    current = score_map(prof)
    desired_scores = {n: s for n, s in current.items() if n not in want_scores}
    desired_scores.update(want_scores)
    profile_change = current != desired_scores

    if not APPLY:
        print("\n  plan: profile %r format scores %s"
              % (prof.get("name"),
                 ", ".join("%s=%+d" % (i["name"], i["score"]) for i in CFS)))
        print("  nothing written — re-run with --apply")
        sys.exit(0)

    for action, item, cid in plan:
        if action == "ok":
            continue
        want = spec_body(item)
        if action == "create":
            out = post("/api/v3/customformat", want)
            cid = (out or {}).get("id")
            if cid is None:
                cid = next((c.get("id") for c in get("/api/v3/customformat")
                            if str(c.get("name", "")).lower() == item["name"].lower()), None)
            if cid is None:
                die("created %r but cannot find its id" % item["name"], 5)
        else:
            body = dict(want)
            body["id"] = cid
            put("/api/v3/customformat/%s" % cid, body)
        ids[item["name"]] = cid

    if any(ids.get(i["name"]) is None for i in CFS):
        die("not every custom format resolved to an id: %r" % ids, 5)

    if profile_change:
        keep = [fi for fi in prof.get("formatItems") or []
                if str(fi.get("name")) not in want_scores]
        body = dict(prof)
        body["formatItems"] = keep + [
            {"format": ids[n], "name": n, "score": s} for n, s in want_scores.items()]
        path = backup(prof)
        print("  backup: %s" % path)
        put("/api/v3/qualityprofile/%s" % prof.get("id"), body)
        print("  -> profile %r updated with %d format score(s)"
              % (prof.get("name"), len(want_scores)))
    else:
        print("  ok     profile already carries every score")

    # fix 84: a 202 is not proof. Read both back.
    after_cf = {str(c.get("name", "")).lower(): c for c in get("/api/v3/customformat")}
    after_p = profile_by_id(prof.get("id"))
    got = score_map(after_p)
    bad = [n for n, s in want_scores.items() if got.get(n) != s]
    bad += [i["name"] for i in CFS
            if not (after_cf.get(i["name"].lower()) or {}).get("specifications")]
    if bad:
        die("read-back does not match the plan: %s" % ", ".join(bad), 3)
    print("  verify: OK — %d score(s) and %d custom format(s) read back as planned"
          % (len(want_scores), len(CFS)))
    sys.exit(0)

# -------------------------------------------------------------- quality profile
if MODE == "quality-profile":
    want = want_quality_ids(prof)
    cutoff_group = QUALITY_ALIASES.get(CUTOFF.lower(), {CUTOFF.lower()})
    cutoff_hit = [q for q in want.values()
                  if str(q.get("name")).lower() in cutoff_group]
    if not cutoff_hit:
        die("cutoff %r is not in --qualities %s" % (CUTOFF, ", ".join(QUALITIES)), 4)

    before = allowed_names(prof)
    after_plan = [q.get("name") for q in want.values()]
    print("  allowed: %s" % (", ".join(before) or "(none)"))
    print("  ->       %s" % ", ".join(after_plan))
    print("  cutoff : %s -> %s" % (prof.get("cutoff"), cutoff_hit[0].get("id")))
    if set(before) != set(after_plan):
        print("  note: files already on disk keep their quality. `Bluray-1080p Remux`")
        print("        stays allowed so the existing remuxes are not marked unwanted;")
        print("        new remuxes are blocked by the -10000 title score instead.")

    changed = (set(before) != set(after_plan)
               or str(prof.get("cutoff")) != str(cutoff_hit[0].get("id")))
    if not APPLY:
        print("  nothing written — re-run with --apply"
              if changed else "  already in the planned state")
        sys.exit(0)

    if changed:
        body = json.loads(json.dumps(prof))
        allowed_lc = {str(q["name"]).lower() for q in want.values()}
        for it, q in quality_nodes(body):
            it["allowed"] = str(q["name"]).lower() in allowed_lc
        body["cutoff"] = cutoff_hit[0].get("id")
        path = backup(prof)
        print("  backup: %s" % path)
        put("/api/v3/qualityprofile/%s" % prof.get("id"), body)

    after = profile_by_id(prof.get("id"))
    got_allowed = set(allowed_names(after))
    if got_allowed != set(after_plan):
        die("read-back allowed set is %s, not %s"
            % (", ".join(sorted(got_allowed)), ", ".join(after_plan)), 3)
    if str(after.get("cutoff")) != str(cutoff_hit[0].get("id")):
        die("read-back cutoff is %s, not %s"
            % (after.get("cutoff"), cutoff_hit[0].get("id")), 3)
    print("  verify: OK — allowed=%s cutoff=%s"
          % (", ".join(sorted(got_allowed)), after.get("cutoff")))
PY

RC=$?
if [ "$RC" -ne 0 ]; then
    exit "$RC"
fi

# ---------------------------------------------------------------- normalizer
# The point of the CFs is that the normalizer has less to fix. Show the last
# few decisions after an apply so a title that still needed a rewrite is seen.
if [ "${APPLY:-0}" -eq 1 ] && [ -r /var/log/media-normalize.log ]; then
    echo "== normalizer, recent decisions =="
    grep -E "^(done|remux|skip|fail)" /var/log/media-normalize.log 2>/dev/null \
        | tail -5 | sed 's/^/  /'
fi

#!/usr/bin/env python3
"""Offline test for bazarr_status.sh's movie listing (fixes 77/82).

fix 77: the section used to filter on the literal string "hail mary", so with
three films in the library it could only report on one of them.

fix 82: it joined sidecar files with `p.startswith(path + "/")`, but Bazarr's
`path` is the .mkv FILE. That prefix can never match, so every movie printed
`0 .srt` and `verdict: MISSING` even when subtitles were sitting right there.
This fixture therefore uses the REAL shape (path = .../Title.mkv), which is
what the previous fixture got wrong: it used a directory, so the test agreed
with the bug. The verdict must also follow the owner's order:
ea (non-HI) > es (non-HI) > ea.hi > es.hi.
"""
import json
import os
import re
import subprocess
import sys
import tempfile

SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   "..", "bazarr_status.sh")

BASE = "/data/media/movies"
BC = BASE + "/The Breakfast Club (1985)"
FB = BASE + "/Ferris Bueller's Day Off (1986)"
PHM = BASE + "/Project Hail Mary (2026)"

MOVIES = {"data": [
    # file path (the real API shape) + one LatAm HI sidecar -> row 3
    {"title": "The Breakfast Club", "radarrId": 3, "profileId": 1,
     "monitored": True, "path": BC + "/The Breakfast Club (1985) Bluray-1080p.mkv",
     "missing_subtitles": [{"code2": "ea", "hi": False},
                           {"code2": "es", "hi": False},
                           {"code2": "ea", "hi": True},
                           {"code2": "es", "hi": True}],
     "files": [{"path": BC + "/The Breakfast Club (1985) Bluray-1080p.mkv",
                "subtitles": []}]},
    # two sidecars: LatAm non-HI must win over Castilian non-HI; no profile
    {"title": "Ferris Bueller's Day Off", "radarrId": 2, "profileId": None,
     "monitored": True,
     "path": FB + "/Ferris Bueller's Day Off (1986) Bluray-1080p.mkv",
     "missing_subtitles": [], "files": []},
    # nothing on disk
    {"title": "Project Hail Mary", "radarrId": 1, "profileId": 1,
     "monitored": True,
     "path": PHM + "/Project Hail Mary (2026) Remux-1080p.mkv",
     "missing_subtitles": [], "files": []},
]}

SRTS = "\n".join([
    BC + "/The Breakfast Club (1985) Bluray-1080p.es-MX.hi.srt",
    FB + "/Ferris Bueller's Day Off (1986) Bluray-1080p.es.srt",
    FB + "/Ferris Bueller's Day Off (1986) Bluray-1080p.es-MX.srt",
    # decoy: same title prefix, different folder - must NOT be counted
    FB + " [decoy]/Ferris Bueller's Day Off (1986) es-MX.srt",
])


def block():
    src = open(SRC).read()
    m = re.search(r"api /api/movies \| TERM=\"\$TERM\" SRT_LIST=\"\$SRT_LIST\" "
                  r"python3 -c '(.*?)' 2>/dev/null", src, re.S)
    if not m:
        sys.exit("could not extract the movie section from bazarr_status.sh")
    return m.group(1)


fails = 0


def check(label, cond, detail=""):
    global fails
    print("  %s  %s %s" % ("PASS" if cond else "FAIL", label, "" if cond else detail))
    if not cond:
        fails += 1


def run(term=""):
    d = tempfile.mkdtemp()
    script = os.path.join(d, "show.py")
    open(script, "w").write(block())
    env = dict(os.environ, TERM=term, SRT_LIST=SRTS)
    r = subprocess.run([sys.executable, script], input=json.dumps(MOVIES),
                       capture_output=True, text=True, env=env)
    return r


print("== no term: every movie, sidecars joined from the movie DIR ==")
r = run("")
print(r.stdout.rstrip())
check("found all three films", all(t in r.stdout for t in
      ("The Breakfast Club", "Ferris Bueller", "Project Hail Mary")))
check("sees the sidecar next to a .mkv path (fix 82)",
      "on disk    : 1 .srt" in r.stdout
      and "Bluray-1080p.es-MX.hi.srt" in r.stdout)
check("classifies a LatAm HI file as row 3",
      "verdict    : LatAm Spanish, HI" in r.stdout)
check("two sidecars are both listed", "on disk    : 2 .srt" in r.stdout
      and "(1986) Bluray-1080p.es.srt" in r.stdout
      and "(1986) Bluray-1080p.es-MX.srt" in r.stdout)
check("LatAm non-HI wins the verdict over Castilian non-HI",
      "verdict    : LatAm Spanish, non-HI (best)" in r.stdout)
check("does NOT count a same-prefix file in another folder",
      "[decoy]" not in r.stdout)
check("flags a movie with no sidecar as MISSING",
      "verdict    : MISSING — no Spanish subtitle at all" in r.stdout)
check("shouts about a missing profile",
      "NONE  <-- Bazarr will NEVER search this movie" in r.stdout)
check("missing languages read as codes, not JSON dumps",
      "missing    : ea, es, ea.hi, es.hi" in r.stdout)

print("\n== term=ferris: only that film ==")
r = run("ferris")
print(r.stdout.rstrip())
check("only Ferris", "Ferris Bueller" in r.stdout
      and "The Breakfast Club" not in r.stdout)

print("\n== term matches nothing: list what Bazarr has ==")
r = run("bladerunner")
print(r.stdout.rstrip())
check("says nothing matches", "no movie matches" in r.stdout)
check("lists the ids so the next step is possible",
      "radarrId=3" in r.stdout and "radarrId=2" in r.stdout)

print("\n== punctuation/case in the term does not matter ==")
r = run("FERRIS-bueller's")
check("normalised match", "Ferris Bueller" in r.stdout)

print("\n%s" % ("ALL PASS" if not fails else "%d FAILED" % fails))
sys.exit(1 if fails else 0)

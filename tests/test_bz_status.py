#!/usr/bin/env python3
"""Offline test for bazarr_status.sh's movie listing (fix 77).

The section used to filter on the literal string "hail mary", so with three films
in the library it could only report on one of them. It is now driven by a title
term and joined against the .srt files actually on disk — and it must call out
`profileId: NONE`, which is the silent reason Bazarr never searches a movie.
"""
import json
import os
import re
import subprocess
import sys
import tempfile

SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   "..", "bazarr_status.sh")

MOVIES = {"data": [
    {"title": "The Breakfast Club", "radarrId": 3, "profileId": 1,
     "monitored": True, "path": "/data/media/movies/The Breakfast Club (1985)",
     "missing_subtitles": [],
     "files": [{"path": "/data/media/movies/The Breakfast Club (1985)/x.mkv",
                "subtitles": [{"name": "es-MX", "path": "x.es-MX.hi.srt"}]}]},
    {"title": "Ferris Bueller's Day Off", "radarrId": 2, "profileId": None,
     "monitored": True,
     "path": "/data/media/movies/Ferris Bueller's Day Off (1986)",
     "missing_subtitles": [], "files": []},
]}

SRTS = "\n".join([
    "/data/media/movies/The Breakfast Club (1985)/x.es-MX.hi.srt",
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


print("== no term: every movie, sidecars joined from disk ==")
r = run("")
print(r.stdout.rstrip())
check("found both films", "The Breakfast Club" in r.stdout
      and "Ferris Bueller" in r.stdout)
check("reports the sidecar it can see",
      "on disk    : 1 .srt" in r.stdout and "x.es-MX.hi.srt" in r.stdout)
check("calls a present es-LA file that",
      "es-LA subtitle present" in r.stdout)
check("flags a missing .srt as MISSING", "verdict    : MISSING" in r.stdout)
check("shouts about a missing profile",
      "NONE  <-- Bazarr will NEVER search this movie" in r.stdout)
check("says the mkv carries none by policy", "fix 59" in r.stdout)

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

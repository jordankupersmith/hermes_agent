#!/usr/bin/env python3
"""Offline tests for library_status.sh — no VM, no containers, no network.

The script embeds Python blocks inside bash heredocs. This test extracts each
block by a content marker (so it survives reordering), feeds it fixtures, and
checks both the printed evidence and the final verdict.

Why fixtures and not the live stack: every verdict branch must be provable
without a download in flight. The branch that matters most is STUCK (Radarr
queued a release, the download client never took it) — that is the state that
cost a live debugging session on 2026-11-19.

Run:  python3 tests/test_library_status.py
"""
import json
import os
import re
import subprocess
import sys
import tempfile

SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   "..", "library_status.sh")

fails = 0


def check(label, cond, detail=""):
    global fails
    if cond:
        print("  PASS  %s" % label)
    else:
        fails += 1
        print("  FAIL  %s %s" % (label, detail))


def blocks():
    src = open(SRC).read()
    return re.findall(r"<<'PY'\n(.*?)\nPY", src, re.S)


def block(marker):
    for b in blocks():
        if marker in b:
            return b
    sys.exit("no embedded block matches marker %r" % marker)


def run(block_text, args, env_extra=None, stdin_text=None):
    d = tempfile.mkdtemp()
    script = os.path.join(d, "block.py")
    open(script, "w").write(block_text)
    env = dict(os.environ)
    env.update(env_extra or {})
    return subprocess.run([sys.executable, script] + args, input=stdin_text,
                          capture_output=True, text=True, env=env)


def write_json(d, name, obj):
    p = os.path.join(d, name)
    json.dump(obj, open(p, "w"))
    return p


# ---------------------------------------------------------------- fixtures --
MOVIE = {
    "id": 3, "title": "The Breakfast Club", "year": 1985, "monitored": True,
    "status": "released", "hasFile": False, "sizeOnDisk": 0,
    "path": "/data/media/movies/The Breakfast Club (1985)",
    "quality": {"quality": {"name": "Bluray-1080p"}},
    "movieFile": None,
}
MOVIE_FILE = dict(MOVIE, hasFile=True, sizeOnDisk=15_000_000_000,
                  movieFile={"relativePath": "The Breakfast Club (1985) Bluray-1080p.mkv",
                             "size": 15_000_000_000})
QUEUE_STUCK = {"records": [{
    "id": 55, "movieId": 3, "status": "downloadClientUnavailable",
    "trackedDownloadState": "-", "size": 7_170_000_000,
    "sizeleft": 7_170_000_000, "timeleft": "00:29:08", "errorMessage": None}]}
QUEUE_DL = {"records": [{
    "id": 56, "movieId": 3, "status": "downloading",
    "trackedDownloadState": "downloading", "size": 15_000_000_000,
    "sizeleft": 6_000_000_000, "timeleft": "00:21:33", "errorMessage": None}]}
TORRENT = [{"name": "The.Breakfast.Club.1985.1080p.BluRay", "state": "downloading",
            "progress": 0.6, "size": 15_000_000_000, "category": "radarr",
            "save_path": "/data/torrents/movies", "eta": 1293}]
VM_FILE = {"base": "http://192.168.122.10:8096",
           "files": [{"path": "/data/media/movies/The Breakfast Club (1985)/"
                              "The Breakfast Club (1985) Bluray-1080p.mkv",
                      "size": 15_000_000_000, "mtime": "2026-11-19 22:10"},
                     {"path": "/data/media/movies/The Breakfast Club (1985)/"
                              "The Breakfast Club (1985) Bluray-1080p.en.srt",
                      "size": 120_000, "mtime": "2026-11-19 22:10"}],
           "items": []}
VM_ITEM = {"name": "The Breakfast Club", "year": 1985,
           "path": "/data/media/movies/The Breakfast Club (1985)/"
                   "The Breakfast Club (1985) Bluray-1080p.mkv",
           "runtime_min": 97, "sources": 1}
CLIENT = {"id": 1, "name": "qBittorrent", "implementation": "QBittorrent",
          "enable": True,
          "fields": [{"name": "host", "value": "192.168.122.10"},
                     {"name": "port", "value": 8080},
                     {"name": "useSsl", "value": False},
                     {"name": "urlBase", "value": None},
                     {"name": "username", "value": "admin"},
                     {"name": "password", "value": "********"},
                     {"name": "movieCategory", "value": "radarr"}]}

# ------------------------------------------------------------------- tests --
print("== radarr block ==")
d = tempfile.mkdtemp()
m = write_json(d, "movies.json", [MOVIE])
q = write_json(d, "queue.json", QUEUE_STUCK)
mids = os.path.join(d, "mids.txt")
r = run(block("movies = json.load"), [m, q, mids], {"TERM_IN": "breakfast club"})
check("prints the movie", "The Breakfast Club (1985)" in r.stdout, r.stderr[-300:])
check("prints hasFile", "hasFile   : False" in r.stdout)
check("prints queue status", "downloadClientUnavailable" in r.stdout)
check("ids file gets a trailing newline", open(mids).read() == "3\n",
      repr(open(mids).read()))

print("\n== verdict: STUCK ==")
d = tempfile.mkdtemp()
r = run(block("has_file = bool"),
        [write_json(d, "m.json", [MOVIE]),
         write_json(d, "q.json", QUEUE_STUCK),
         write_json(d, "t.json", []),
         write_json(d, "v.json", {"files": [], "items": []})],
        {"TERM_IN": "breakfast club"})
check("says STUCK", "STUCK" in r.stdout, r.stdout + r.stderr[-200:])
check("names the client status", "downloadClientUnavailable" in r.stdout)
check("points at host/password", "password must match" in r.stdout)

print("\n== verdict: downloading ==")
d = tempfile.mkdtemp()
r = run(block("has_file = bool"),
        [write_json(d, "m.json", [MOVIE]),
         write_json(d, "q.json", QUEUE_DL),
         write_json(d, "t.json", TORRENT),
         write_json(d, "v.json", {"files": [], "items": []})],
        {"TERM_IN": "breakfast club"})
check("says NOT YET", "NOT YET" in r.stdout)
check("shows percent", "60.0%" in r.stdout)

print("\n== verdict: YES / PARTLY ==")
d = tempfile.mkdtemp()
r = run(block("has_file = bool"),
        [write_json(d, "m.json", [MOVIE_FILE]),
         write_json(d, "q.json", {"records": []}),
         write_json(d, "t.json", []),
         write_json(d, "v.json", dict(VM_FILE, items=[VM_ITEM]))],
        {"TERM_IN": "breakfast club"})
check("says YES", "YES" in r.stdout)
check("names the Jellyfin item", "Jellyfin sees it" in r.stdout)
d = tempfile.mkdtemp()
r = run(block("has_file = bool"),
        [write_json(d, "m.json", [MOVIE_FILE]),
         write_json(d, "q.json", {"records": []}),
         write_json(d, "t.json", []),
         write_json(d, "v.json", VM_FILE)],
        {"TERM_IN": "breakfast club"})
check("says PARTLY", "PARTLY" in r.stdout)
check("suggests the scan", "jellyfin_admin.sh --scan" in r.stdout)

print("\n== verdict: NO / UNKNOWN ==")
d = tempfile.mkdtemp()
r = run(block("has_file = bool"),
        [write_json(d, "m.json", [MOVIE]),
         write_json(d, "q.json", {"records": []}),
         write_json(d, "t.json", []),
         write_json(d, "v.json", {"files": [], "items": []})],
        {"TERM_IN": "breakfast club"})
check("says NO", "NO —" in r.stdout, r.stdout)
d = tempfile.mkdtemp()
r = run(block("has_file = bool"),
        [write_json(d, "m.json", []),
         write_json(d, "q.json", {"records": []}),
         write_json(d, "t.json", []),
         write_json(d, "v.json", {"files": [], "items": []})],
        {"TERM_IN": "breakfast club"})
check("says Radarr does not know it", "does not know this title" in r.stdout)

print("\n== download-client block ==")
d = tempfile.mkdtemp()
ids = os.path.join(d, "client_ids.txt")
r = run(block("impl.lower()"), [write_json(d, "c.json", [CLIENT]), ids])
check("prints host", "host=192.168.122.10" in r.stdout, r.stderr[-300:])
check("warns about the IP", "compose name 'gluetun'" in r.stdout)
check("never prints the password", "********" not in r.stdout)
check("ids file gets a trailing newline", open(ids).read() == "1\n",
      repr(open(ids).read()))

print("\n== password injection ==")
d = tempfile.mkdtemp()
pw = os.path.join(d, "secret")
open(pw, "w").write("TEMP-PW")
out = os.path.join(d, "fixed.json")
r = run(block('f["value"] = pw'), [write_json(d, "c.json", CLIENT), pw, out])
fixed = json.load(open(out))
check("sets the password", [f["value"] for f in fixed["fields"]
                            if f["name"] == "password"] == ["TEMP-PW"])
check("leaves the host alone", [f["value"] for f in fixed["fields"]
                                if f["name"] == "host"] == ["192.168.122.10"])
check("does not echo the secret", "TEMP-PW" not in r.stdout + r.stderr)

print("\n== retry: only parked rows ==")
d = tempfile.mkdtemp()
qq = write_json(d, "q.json", {"records": [
    {"id": 55, "movieId": 3, "status": "downloadClientUnavailable"},
    {"id": 56, "movieId": 3, "status": "downloading"},
    {"id": 57, "movieId": 9, "status": "downloadClientUnavailable"}]})
r = run(block("downloadClientUnavailable"), [qq, "3"])
check("selects the parked row", r.stdout.strip() == "55", repr(r.stdout))
r = run(block("downloadClientUnavailable"), [qq, "9"])
check("selects the other movie's row", r.stdout.strip() == "57", repr(r.stdout))

print("\n%s" % ("ALL PASS" if not fails else "%d FAILURE(S)" % fails))
sys.exit(1 if fails else 0)

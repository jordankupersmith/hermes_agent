#!/usr/bin/env python3
"""Offline test for bazarr_status.sh's --fix-audio-source (fix 85).

Why this exists: Bazarr's audio_language is copied from Radarr's
`movieFile.languages`, which is the language set of the release AT IMPORT TIME
(a MULTi remux says "Spanish" even after the normalizer rewrote the file down
to one English track). Every profile row is audio_exclude=True, so a stale
Spanish entry drops every Spanish row and `missing_subtitles` stays [] —
searched, nothing to do, exit 0, no error.

The cure is `general.parse_embedded_audio_track`, i.e. ffprobe the file's own
audio streams. That is a settings write, and fix 81 says the wire shape must be
one flat `settings-<section>-<key>` field: a section blob answers 204 and
stores nothing. These checks run the REAL python block extracted from the
script against a mock Bazarr, so both the shape and the read-back are pinned.
"""
import json
import os
import re
import sys
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   "..", "bazarr_status.sh")

src = open(SRC).read()


def extract_block():
    """The python heredoc inside the --fix-audio-source branch."""
    start = src.index('if [ "${1:-}" = "--fix-audio-source" ]; then')
    head = src.index("python3 - <<'PY'", start)
    body = src[head:].split("<<'PY'", 1)[1]
    return body.split("\nPY\n", 1)[0]


fails = 0


def check(label, cond, detail=""):
    global fails
    print("  %s  %s %s" % ("PASS" if cond else "FAIL", label,
                           "" if cond else detail))
    if not cond:
        fails += 1


MOVIES = {"data": [
    {"title": "Project Hail Mary", "radarrId": 1, "profileId": 1,
     "missing_subtitles": [{"code2": "ea", "hi": False},
                           {"code2": "es", "hi": False},
                           {"code2": "es", "hi": True}]},
    {"title": "Ferris Bueller's Day Off", "radarrId": 2, "profileId": 1,
     "missing_subtitles": [{"code2": "es", "hi": True}]},
]}


class State:
    def __init__(self, flag=False, store=True):
        self.flag = flag          # value the mock "database" holds
        self.store = store        # False = accept 204 but store nothing (fix 81)
        self.posts = []
        self.keys = []


def serve(state):
    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def _json(self, obj, code=200):
            body = json.dumps(obj).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            state.keys.append(self.headers.get("X-API-KEY"))
            if self.path == "/api/system/settings":
                self._json({"general": {
                    "parse_embedded_audio_track": state.flag,
                    "use_embedded_subs": True,
                }})
            elif self.path == "/api/movies":
                self._json(MOVIES)
            else:
                self._json({}, 404)

        def do_POST(self):
            state.keys.append(self.headers.get("X-API-KEY"))
            n = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(n).decode()
            pairs = urllib.parse.parse_qsl(raw, keep_blank_values=True)
            state.posts.append(pairs)
            if state.store:
                for k, v in pairs:
                    if k == "settings-general-parse_embedded_audio_track":
                        state.flag = v == "true"
            self.send_response(204)
            self.end_headers()

    srv = HTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


def run(flag=False, store=True):
    state = State(flag=flag, store=store)
    srv = serve(state)
    base = "http://127.0.0.1:%d" % srv.server_address[1]
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    env = dict(os.environ, BASE=base, KEY="test-key")
    import subprocess
    r = subprocess.run([sys.executable, "-c", extract_block()],
                       capture_output=True, text=True, env=env)
    srv.shutdown()
    return r, state


print("== the flip is one flat settings field (fix 81), read back (fix 85) ==")
r, st = run(flag=False, store=True)
print(r.stdout.rstrip())
check("exits 0 when the flag persists", r.returncode == 0, "rc=%d %s" %
      (r.returncode, r.stderr[:200]))
check("one POST, exactly one field", len(st.posts) == 1 and len(st.posts[0]) == 1,
      repr(st.posts))
check("the field is settings-general-parse_embedded_audio_track=true",
      st.posts and st.posts[0][0] ==
      ("settings-general-parse_embedded_audio_track", "true"), repr(st.posts))
check("no section blob is ever sent",
      not any(k == "settings-general" for k, _ in (st.posts[0] if st.posts else [])))
check("the API key travels with both reads and the write",
      st.keys and all(k == "test-key" for k in st.keys), repr(st.keys))
check("says what it verified", "verify: OK" in r.stdout)
check("prints every movie's recomputed missing list",
      "Project Hail Mary" in r.stdout and "ea, es, es.hi" in r.stdout
      and "Ferris Bueller's Day Off" in r.stdout)

print("\n== already on: no write at all ==")
r, st = run(flag=True, store=True)
print(r.stdout.rstrip())
check("exits 0", r.returncode == 0)
check("nothing to do", "nothing to do" in r.stdout)
check("no POST", st.posts == [], repr(st.posts))

print("\n== 204 that stores nothing must FAIL, not claim success (fix 81) ==")
r, st = run(flag=False, store=False)
print(r.stdout.rstrip())
check("non-zero exit", r.returncode == 3, "rc=%d" % r.returncode)
check("names the mismatch", "MISMATCH" in r.stdout)
check("never prints the success line", "verify: OK" not in r.stdout)

print("\n== --rescan must re-read Radarr BEFORE it reads the folder (fix 85) ==")
start = src.index('if [ "${1:-}" = "--rescan" ]; then')
end = src.index('if [ "${1:-}" = "--search" ]; then', start)
block = src[start:end]
# match the CALL URL, not the word: a comment that says "action=sync" must not
# be able to satisfy this (that is how the first version of the check passed
# while the rescan had stopped syncing).
i_sync = block.find('&action=sync"')
i_scan = block.find('&action=scan-disk"')
check("rescan calls PATCH action=sync", i_sync >= 0)
check("sync comes before scan-disk", 0 <= i_sync < i_scan,
      "sync=%d scan=%d" % (i_sync, i_scan))
check("and the profile POST that recomputes missing still follows",
      block.find("profileid=$PID") > i_scan)

print("\n== the script says why, in the code, so nobody 'simplifies' it back ==")
start = src.index('if [ "${1:-}" = "--fix-audio-source" ]; then')
comment = src[max(0, start - 2000):start]
check("names the frozen field", "movieFile" in comment and "languages" in comment)
check("names the silent outcome", "missing: []" in comment or "missing_subtitles" in comment)

print("\n%s" % ("ALL PASS" if not fails else "%d FAILED" % fails))
sys.exit(1 if fails else 0)

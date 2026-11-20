#!/usr/bin/env python3
"""Offline test for bazarr_status.sh --default-profile (fix 80).

Every movie synced from Radarr arrived with profileId=None, so Bazarr computed
missing_subtitles as [] and never searched — silently, forever. The default
profile is the durable fix, and it goes through POST /api/system/settings with a
form field per section, so the test checks three things the live run cannot:

  * the OTHER sections are preserved (a partial POST must not blank them),
  * a 202/204 is not treated as success (the value is re-read),
  * an unrecognised settings payload is refused instead of POSTed blind.
"""
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   "..", "bazarr_status.sh")
KEY = "not-a-real-key"

PROFILES = [{"profileId": 1, "name": "Latin American Spanish", "cutoff": 4,
             "items": []}]


class State:
    def __init__(self, general, drop=False, shape="normal"):
        self.general = dict(general)
        self.drop = drop
        self.shape = shape
        self.posts = []

    def settings(self):
        if self.shape == "weird":
            return {"data": {"nope": True}}
        return {"general": self.general,
                "radarr": {"ip": "127.0.0.1", "port": 7878},
                "sonarr": {"ip": "127.0.0.1", "port": 8989},
                "languages-profiles": PROFILES}


def serve(state):
    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def _send(self, code, payload):
            body = json.dumps(payload).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.headers.get("X-API-KEY") != KEY:
                return self._send(401, {})
            if self.path.rstrip("/") == "/api/system/settings":
                return self._send(200, state.settings())
            if self.path.rstrip("/") == "/api/system/languages/profiles":
                return self._send(200, PROFILES)
            return self._send(404, {})

        def do_POST(self):
            if self.headers.get("X-API-KEY") != KEY:
                return self._send(401, {})
            n = int(self.headers.get("Content-Length") or 0)
            fields = urllib.parse.parse_qs(self.rfile.read(n).decode())
            state.posts.append({k: v[0] for k, v in fields.items()})
            if state.drop:
                return self._send(204, {})
            gen = json.loads(fields["settings-general"][0])
            state.general.update(gen)
            return self._send(204, {})

    srv = HTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


def block():
    src = open(SRC).read()
    m = re.search(r'python3 - <<\'PY\'\n(.*?)\nPY\n', src, re.S)
    if not m:
        sys.exit("could not extract the --default-profile block")
    return m.group(1)


fails = 0


def check(label, cond, detail=""):
    global fails
    print("  %s  %s %s" % ("PASS" if cond else "FAIL", label, "" if cond else detail))
    if not cond:
        fails += 1


def run(state, override=""):
    srv = serve(state)
    d = tempfile.mkdtemp()
    script = os.path.join(d, "dp.py")
    open(script, "w").write(block())
    env = dict(os.environ, BASE="http://127.0.0.1:%d" % srv.server_address[1],
               KEY=KEY, PID_OVERRIDE=override)
    try:
        r = subprocess.run([sys.executable, script], capture_output=True,
                           text=True, env=env)
    finally:
        srv.shutdown()
    return r


OFF = {"movie_default_enabled": False, "movie_default_profile": None,
       "serie_default_enabled": False, "serie_default_profile": None,
       "embedded_subs_show_desired": True}

print("== unset -> set profile 1, re-read, exit 0 ==")
st = State(OFF)
r = run(st)
print(r.stdout.rstrip())
check("exit 0", r.returncode == 0, r.returncode)
check("says nothing about a mismatch", "MISMATCH" not in r.stdout)
check("the default is now on", st.general.get("movie_default_enabled") is True)
check("the default points at profile 1", st.general.get("movie_default_profile") == 1)
check("exactly one POST", len(st.posts) == 1, len(st.posts))
sent = st.posts[0]
check("sends the general section", "settings-general" in sent)
check("preserves the radarr section (partial POST would blank it)",
      "settings-radarr" in sent and "settings-sonarr" in sent)
check("never prints the API key", KEY not in r.stdout and KEY not in r.stderr)

print("\n== already set -> nothing to do, no POST ==")
st = State(dict(OFF, movie_default_enabled=True, movie_default_profile=1))
r = run(st)
print(r.stdout.rstrip())
check("exit 0", r.returncode == 0, r.returncode)
check("no POST", len(st.posts) == 0, len(st.posts))
check("says nothing to do", "nothing to do" in r.stdout)

print("\n== POST accepted but dropped -> MISMATCH, exit 3 ==")
st = State(OFF, drop=True)
r = run(st)
print(r.stdout.rstrip())
check("exit 3", r.returncode == 3, r.returncode)
check("calls it a mismatch", "MISMATCH" in r.stdout)

print("\n== unrecognised settings payload -> refuse, exit 6, no POST ==")
st = State(OFF, shape="weird")
r = run(st)
print(r.stdout.rstrip())
check("exit 6", r.returncode == 6, r.returncode)
check("no POST sent", len(st.posts) == 0, len(st.posts))
check("names the shape problem", "unexpected" in r.stdout)

print("\n== explicit profileId override ==")
st = State(OFF)
r = run(st, override="1")
check("exit 0", r.returncode == 0, r.returncode)
check("uses the override", st.general.get("movie_default_profile") == 1)

print("\n%s" % ("ALL PASS" if not fails else "%d FAILED" % fails))
sys.exit(1 if fails else 0)

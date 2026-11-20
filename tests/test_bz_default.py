#!/usr/bin/env python3
"""Offline test for bazarr_status.sh --default-profile (fixes 80/81).

Every movie synced from Radarr arrived with profileId=None, so Bazarr computed
missing_subtitles as [] and never searched -- silently, forever. The default
profile is the durable fix.

The first version of this test passed while the live run failed, because its
fake server accepted ANY form key starting with "settings-". The real handler
does not: bazarr/app/config.py::save_settings() splits each key on '-' and only
applies it when the shape is settings-<section>-<key> (len 3) or
settings-<section>-<key>-<sub> (len 4). A `settings-general=<json blob>` key
splits into two parts, falls through, and the endpoint still answers 204.

So this server implements the real dispatch, not a permissive stand-in:
  * a JSON blob must change nothing (that is the bug that shipped),
  * flat settings-<section>-<key> fields must persist,
  * a 202/204 must not be treated as success (the value is re-read),
  * other sections must survive untouched,
  * an unrecognised settings payload must be refused, never POSTed blind.
"""
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   "..", "bazarr_status.sh")
KEY = "not-a-real-key"

PROFILES = [{"profileId": 1, "name": "Latin American Spanish", "cutoff": 4,
             "items": []}]


def cast(value):
    """The subset of save_settings() casting that matters here."""
    if value == "true":
        return True
    if value == "false":
        return False
    try:
        return int(value)
    except ValueError:
        return value


class State:
    def __init__(self, general, drop=False, shape="normal"):
        self.sections = {"general": dict(general),
                         "radarr": {"ip": "127.0.0.1", "port": 7878,
                                    "apikey": "radarr-secret"},
                         "sonarr": {"ip": "127.0.0.1", "port": 8989}}
        self.drop = drop
        self.shape = shape
        self.posts = []

    @property
    def general(self):
        return self.sections["general"]

    def settings(self):
        if self.shape == "weird":
            return {"data": {"nope": True}}
        return dict(self.sections)

    def apply(self, fields):
        """Mirror save_settings(): only settings-<section>-<key> is applied."""
        for key, values in fields.items():
            value = values[0] if isinstance(values, list) and len(values) == 1 \
                else values
            parts = key.split("-")
            if parts[0] != "settings" or len(parts) not in (3, 4):
                continue  # exactly what the real handler does: silently skip
            section, name = parts[1], parts[2]
            if section not in self.sections:
                continue
            if len(parts) == 4:
                sub = self.sections[section].setdefault(name, {})
                sub[parts[3]] = cast(value)
            else:
                self.sections[section][name] = cast(value)


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
            raw = urllib.parse.parse_qs(self.rfile.read(n).decode(),
                                        keep_blank_values=True)
            state.posts.append({k: v for k, v in raw.items()})
            if not state.drop:
                state.apply(raw)
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
    print("  %s  %s %s" % ("PASS" if cond else "FAIL", label,
                           "" if cond else detail))
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


OFF = {"movie_default_enabled": False, "movie_default_profile": "",
       "serie_default_enabled": False, "serie_default_profile": "",
       "embedded_subs_show_desired": True}

print("== the fake server matches the real dispatch: a JSON blob changes nothing ==")
st = State(OFF)
srv = serve(st)
url = "http://127.0.0.1:%d/api/system/settings" % srv.server_address[1]
r = urllib.request.urlopen(urllib.request.Request(
    url, data=urllib.parse.urlencode({"settings-general": json.dumps(
        {"movie_default_enabled": True, "movie_default_profile": 1})}).encode(),
    method="POST", headers={"X-API-KEY": KEY}), timeout=10)
srv.shutdown()
check("blob POST answered 204", r.status == 204, r.status)
check("blob POST stored nothing (this is fix 81)", st.general == OFF, st.general)

print("\n== unset -> flat fields set profile 1, re-read, exit 0 ==")
st = State(OFF)
r = run(st)
print(r.stdout.rstrip())
check("exit 0", r.returncode == 0, r.returncode)
check("says nothing about a mismatch", "MISMATCH" not in r.stdout)
check("the default is now on", st.general.get("movie_default_enabled") is True)
check("the default points at profile 1", st.general.get("movie_default_profile") == 1)
check("exactly one POST", len(st.posts) == 1, len(st.posts))
sent = st.posts[0]
check("sends the flat enabled field",
      "settings-general-movie_default_enabled" in sent)
check("sends the flat profile field",
      "settings-general-movie_default_profile" in sent)
check("sends NO settings-<section> blob (the shape Bazarr ignores)",
      not any(len(k.split("-")) == 2 for k in sent))
check("preserves the radarr section (only the posted keys are touched)",
      st.sections["radarr"].get("apikey") == "radarr-secret",
      st.sections["radarr"])
check("never prints the API key", KEY not in r.stdout and KEY not in r.stderr)

print("\n== already set -> nothing to do, no POST ==")
st = State(dict(OFF, movie_default_enabled=True, movie_default_profile=1))
r = run(st)
print(r.stdout.rstrip())
check("exit 0", r.returncode == 0, r.returncode)
check("no POST", len(st.posts) == 0, len(st.posts))
check("says nothing to do", "nothing to do" in r.stdout)

print("\n== POST accepted but dropped -> MISMATCH, exit 3 ==\n")
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

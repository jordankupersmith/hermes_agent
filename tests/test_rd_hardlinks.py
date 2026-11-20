#!/usr/bin/env python3
"""Offline test for library_status.sh --fix-hardlinks (fix 76).

Serves a fake Radarr v3 mediamanagement config. The whole point of the action is
that a 200/202 is NOT proof: the value must be re-read, and a server that accepts
the PUT while dropping the field must produce a mismatch (exit 3), exactly like
the downloadclient `category` trap in tests/test_rd.py.
"""
import json
import os
import re
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   "..", "library_status.sh")
KEY = "test-api-key-not-a-real-one"

# Radarr v3 Config/MediaManagement, trimmed to the fields the action touches.
CFG = {"id": 1, "autoUnmountEnabled": False, "recycleBin": "",
       "recycleBinCleanupDays": 7, "downloadPropersAndRepacks": "preferAndUpgrade",
       "createEmptyMovieFolders": False, "deleteEmptyFolders": True,
       "fileDate": "none", "rescanAfterRefresh": "always",
       "movieInfoLanguage": 1, "importExtraFiles": False,
       "extraFileExtensions": "srt", "enableMediaInfo": True,
       "setPermissionsLinux": False, "chmodFolder": "755",
       "chownGroup": "", "copyUsingHardlinks": False}


class State:
    def __init__(self, cfg, drop_field=False):
        self.cfg = dict(cfg)
        self.drop_field = drop_field
        self.puts = 0


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
            if self.headers.get("X-Api-Key") != KEY:
                return self._send(401, {"message": "Unauthorized"})
            if self.path.rstrip("/") == "/api/v3/config/mediamanagement":
                return self._send(200, state.cfg)
            return self._send(404, {})

        def do_PUT(self):
            if self.headers.get("X-Api-Key") != KEY:
                return self._send(401, {"message": "Unauthorized"})
            n = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(n) or b"{}")
            state.puts += 1
            if state.drop_field:
                # The failure mode this test exists for: accepted, not stored.
                return self._send(202, {})
            state.cfg.update(body)
            return self._send(202, state.cfg)

    srv = HTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


def block():
    src = open(SRC).read()
    m = re.search(r"python3 - \"\$RD\" <<'PY'\n(.*?)\nPY\n", src, re.S)
    if not m:
        sys.exit("could not extract the --fix-hardlinks block from library_status.sh")
    return m.group(1)


fails = 0


def check(label, cond, detail=""):
    global fails
    print("  %s  %s %s" % ("PASS" if cond else "FAIL", label,
                            "" if cond else detail))
    if not cond:
        fails += 1


def run(cfg, drop_field=False):
    state = State(cfg, drop_field)
    srv = serve(state)
    script = os.path.join(os.path.dirname(SRC), "tests", ".tmp_fixhardlinks.py")
    open(script, "w").write(block())
    env = dict(os.environ, RDK=KEY)
    try:
        r = subprocess.run(
            [sys.executable, script,
             "http://127.0.0.1:%d" % srv.server_address[1]],
            capture_output=True, text=True, env=env)
    finally:
        srv.shutdown()
        os.unlink(script)
    return r, state


print("== copyUsingHardlinks=false -> flip it, re-read, exit 0 ==")
r, st = run(CFG)
print(r.stdout.rstrip())
check("exit 0", r.returncode == 0, r.returncode)
check("reports the before value", "before: copyUsingHardlinks = False" in r.stdout)
check("PUTs exactly one config object", st.puts == 1, st.puts)
check("the server now holds the new value", st.cfg.get("copyUsingHardlinks") is True)
check("proves it by re-reading", "verify: OK" in r.stdout)
check("does not disturb other fields",
      st.cfg.get("deleteEmptyFolders") is True
      and st.cfg.get("extraFileExtensions") == "srt")
check("never prints the API key", KEY not in r.stdout and KEY not in r.stderr)

print("\n== already true -> nothing to do, no PUT ==")
r, st = run(dict(CFG, copyUsingHardlinks=True))
print(r.stdout.rstrip())
check("exit 0", r.returncode == 0, r.returncode)
check("says nothing to do", "nothing to do" in r.stdout)
check("no PUT sent", st.puts == 0, st.puts)

print("\n== PUT accepted but field dropped -> mismatch, exit 3 ==")
r, st = run(CFG, drop_field=True)
print(r.stdout.rstrip())
check("exit 3", r.returncode == 3, r.returncode)
check("calls it a mismatch", "MISMATCH" in r.stdout)
check("did try the PUT", st.puts == 1, st.puts)

print("\n== server rejects the PUT -> exit 5, no false success ==")


class State401(State):
    pass


def run_reject():
    state = State(CFG)

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
            self._send(200, state.cfg)

        def do_PUT(self):
            self._send(400, {"message": "Invalid request"})

    srv = HTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    script = os.path.join(os.path.dirname(SRC), "tests", ".tmp_fixhardlinks.py")
    open(script, "w").write(block())
    env = dict(os.environ, RDK=KEY)
    try:
        r = subprocess.run(
            [sys.executable, script,
             "http://127.0.0.1:%d" % srv.server_address[1]],
            capture_output=True, text=True, env=env)
    finally:
        srv.shutdown()
        os.unlink(script)
    return r


r = run_reject()
print(r.stdout.rstrip())
check("exit 5", r.returncode == 5, r.returncode)
check("prints Radarr's rejection", "Invalid request" in r.stdout)

print("\n%s" % ("ALL PASS" if not fails else "%d FAILED" % fails))
sys.exit(1 if fails else 0)

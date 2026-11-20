#!/usr/bin/env python3
"""Offline test for qbt_admin.sh --set-password / --import-downloads.

The failure this covers (fix 71): qBittorrent generates a *new* temporary WebUI
password every time it starts with no password configured, so any container
recreate (every apply run) invalidates what Radarr stored. Radarr keeps polling
with the old credential, bans its own source IP after 5 failures (1 h), and
reports the ban as a plain "Authentication Failure". One permanent credential,
written in one atomic operation, removes the class.

The script's decision logic lives in one python block (`pw.py`, four modes).
Two fake servers mirror the real ones:

  * qBittorrent: login ("Ok."/"Fails.", 403 when banned), a session cookie that
    setPreferences requires, and app/setPreferences with JSON in a form field.
  * Radarr: downloadclient GET/PUT (202 on save, 400 with validation failures
    when the client test fails), downloadclient/testall (which itself checks the
    stored password against the fake qBt), and POST command.
"""
import http.cookiejar
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "qbt_admin.sh")
fails = 0


def check(label, cond, detail=""):
    global fails
    if cond:
        print("  PASS  %s" % label)
    else:
        fails += 1
        print("  FAIL  %s %s" % (label, detail))


def block():
    src = open(SRC).read()
    m = re.search(r'cat > "\$TMP/pw\.py" <<\'PY\'\n(.*?)\nPY\n', src, re.S)
    if not m:
        sys.exit("could not extract the pw.py block from qbt_admin.sh")
    return m.group(1)


# ---- fake qBittorrent ------------------------------------------------------
class Qbt:
    def __init__(self, password="temp-one", user="admin"):
        self.password = password
        self.user = user
        self.banned = False
        self.set_mode = "ok"        # ok | reject | ignore | forbidden
        self.sessions = set()
        self.logins = 0


def serve_qbt(s):
    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def _send(self, code, text, cookie=None):
            body = text.encode()
            self.send_response(code)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            if cookie:
                self.send_header("Set-Cookie", cookie)
            self.end_headers()
            self.wfile.write(body)

        def _form(self):
            n = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(n).decode()
            return {k: v[0] for k, v in urllib.parse.parse_qs(raw).items()}

        def do_GET(self):
            if self.path == "/api/v2/app/version":
                self._send(200, "v5.0.4")
            else:
                self._send(404, "")

        def do_POST(self):
            f = self._form()
            if self.path == "/api/v2/auth/login":
                s.logins += 1
                if s.banned:
                    self._send(403, "Your IP address has been banned.")
                elif f.get("password") == s.password and f.get("username") == s.user:
                    tok = "sid%d" % s.logins
                    s.sessions.add(tok)
                    self._send(200, "Ok.", cookie="SID=%s; path=/" % tok)
                else:
                    self._send(200, "Fails.")
                return
            if self.path == "/api/v2/app/setPreferences":
                if s.banned or not any(
                        "SID=" + t in (self.headers.get("Cookie") or "")
                        for t in s.sessions):
                    self._send(403, "Forbidden")
                    return
                if s.set_mode == "forbidden":
                    self._send(403, "Forbidden")
                    return
                if s.set_mode == "reject":
                    self._send(500, "boom")
                    return
                new = json.loads(f.get("json") or "{}").get("web_ui_password")
                if s.set_mode != "ignore" and new:
                    s.password = new
                self._send(200, "")
                return
            self._send(404, "")
    srv = HTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


# ---- fake Radarr -----------------------------------------------------------
def client(password="temp-one"):
    return {"id": 1, "name": "qBittorrent", "implementation": "QBittorrent",
            "enable": True, "protocol": "torrent", "priority": 1,
            "fields": [{"name": "host", "value": "gluetun"},
                       {"name": "port", "value": 8080},
                       {"name": "username", "value": "admin"},
                       {"name": "password", "value": password},
                       {"name": "movieCategory", "value": "radarr"}]}


class Rd:
    def __init__(self, qbt, password="temp-one"):
        self.qbt = qbt
        self.client = client(password)
        self.puts = []
        self.accept_put = True
        self.test_ok = None          # None = derive from the qBt password
        self.commands = []
        self.command_status = 201


def serve_rd(s):
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
            if self.path == "/api/v3/downloadclient":
                self._send(200, [s.client])
            elif self.path == "/api/v3/downloadclient/1":
                self._send(200, s.client)
            else:
                self._send(404, {})

        def do_PUT(self):
            n = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(n) or b"{}")
            s.puts.append(body)
            if not s.accept_put:
                self._send(400, {"message": "Invalid request",
                                 "errors": [{"errorMessage": "Unable to connect"}]})
                return
            s.client = body
            self._send(202, s.client)

        def do_POST(self):
            n = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(n) or b"{}")
            if self.path == "/api/v3/downloadclient/testall":
                pw = next((f.get("value") for f in s.client["fields"]
                           if f.get("name") == "password"), "")
                ok = (pw == s.qbt.password) if s.test_ok is None else s.test_ok
                self._send(200, [{"id": 1, "name": "qBittorrent", "isValid": ok,
                                  "validationFailures": [] if ok else
                                  [{"errorMessage": "Authentication Failure"}]}])
                return
            if self.path == "/api/v3/command":
                s.commands.append(body)
                if not (200 <= s.command_status < 300):
                    self._send(s.command_status, {"message": "bad command"})
                    return
                self._send(201, {"id": 42, "name": body.get("name"),
                                 "status": "queued"})
                return
            self._send(404, {})
    srv = HTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


# ---- harness ---------------------------------------------------------------
D = tempfile.mkdtemp(prefix="qb-pw-")
SCRIPT = os.path.join(D, "pw.py")
open(SCRIPT, "w").write(block())


def secret(name, value):
    p = os.path.join(D, name)
    open(p, "w").write(value)
    os.chmod(p, 0o600)
    return p


def run_set(qbt, cur="temp-one", new="new-pass-0123456789"):
    srv = serve_qbt(qbt)
    r = subprocess.run(
        [sys.executable, SCRIPT, "set", "http://127.0.0.1:%d" % srv.server_address[1],
         "admin", secret("cur", cur), secret("new", new)],
        capture_output=True, text=True)
    srv.shutdown()
    return r


def run_rd(mode, qbt, rdstate=None, new="new-pass-0123456789", path=None):
    q = serve_qbt(qbt)
    st = rdstate or Rd(qbt)
    srv = serve_rd(st)
    url = "http://127.0.0.1:%d" % srv.server_address[1]
    key = secret("key", "testkey")
    argv = [sys.executable, SCRIPT, mode, url, key]
    if mode == "radarr":
        argv.append(secret("new2", new))
    if mode == "import":
        argv.append(path)
    r = subprocess.run(argv, capture_output=True, text=True)
    srv.shutdown()
    q.shutdown()
    return r, st


print("== set: current accepted, new password verified with a FRESH session ==")
qbt = Qbt()
r = run_set(qbt)
print(r.stdout.rstrip())
check("exit 0", r.returncode == 0, r.stderr[-300:])
check("qBt now holds the new password", qbt.password == "new-pass-0123456789",
      qbt.password)
check("prints the fresh-login proof", "fresh login with the new password: OK"
      in r.stdout)
check("never prints the secret", "new-pass-0123456789" not in r.stdout + r.stderr)

print("\n== set: wrong current password -> 4, nothing changed ==")
qbt = Qbt()
r = run_set(qbt, cur="wrong")
print(r.stdout.rstrip())
check("exit 4", r.returncode == 4, r.returncode)
check("says it rejected the CURRENT password", "CURRENT password" in r.stdout)
check("password untouched", qbt.password == "temp-one", qbt.password)

print("\n== set: source IP banned -> 5, with the restart hint ==")
qbt = Qbt()
qbt.banned = True
r = run_set(qbt)
print(r.stdout.rstrip())
check("exit 5", r.returncode == 5, r.returncode)
check("says BANNED", "BANNED" in r.stdout)
check("says a restart clears it", "restart clears it" in r.stdout)

print("\n== set: setPreferences 403 (ban appeared after login) -> 5 ==")
qbt = Qbt()
qbt.set_mode = "forbidden"
r = run_set(qbt)
print(r.stdout.rstrip())
check("exit 5", r.returncode == 5, r.returncode)

print("\n== set: setPreferences rejected -> 6 ==")
qbt = Qbt()
qbt.set_mode = "reject"
r = run_set(qbt)
print(r.stdout.rstrip())
check("exit 6", r.returncode == 6, r.returncode)
check("reports the HTTP status", "HTTP 500" in r.stdout)

print("\n== set: accepted but ignored (live cookie would lie) -> 7 ==")
qbt = Qbt()
qbt.set_mode = "ignore"
r = run_set(qbt)
print(r.stdout.rstrip())
check("exit 7", r.returncode == 7, r.returncode)
check("says it did not take", "did not take" in r.stdout)

def run_check(qbt, pw):
    srv = serve_qbt(qbt)
    r = subprocess.run(
        [sys.executable, SCRIPT, "check",
         "http://127.0.0.1:%d" % srv.server_address[1], "admin",
         secret("chk", pw)], capture_output=True, text=True)
    srv.shutdown()
    return r


print("\n== check: login after the restart with the stored password ==")
qbt = Qbt(password="new-pass-0123456789")
r = run_check(qbt, "new-pass-0123456789")
print(r.stdout.rstrip())
check("exit 0", r.returncode == 0, r.returncode)
check("says it survived the restart", "after the restart: OK" in r.stdout)

qbt = Qbt(password="rotated-temp")          # the write did NOT survive
r = run_check(qbt, "new-pass-0123456789")
print(r.stdout.rstrip())
check("exit 7 on a lost write", r.returncode == 7, r.returncode)
check("names the failure", "did not survive the restart" in r.stdout)

print("\n== radarr: the new password is written and read back ==")
qbt = Qbt(password="new-pass-0123456789")
r, st = run_rd("radarr", qbt)
print(r.stdout.rstrip())
check("exit 0", r.returncode == 0, r.stderr[-300:])
pw = next((f.get("value") for f in st.client["fields"]
           if f.get("name") == "password"), None)
check("fake Radarr stored the new password", pw == "new-pass-0123456789", pw)
check("PUT went to downloadclient/1", bool(st.puts))
check("forceSave is requested (the live ban would fail the save-time test)",
      "forceSave=true" in r.stdout)
check("does not disturb the other fields",
      next((f.get("value") for f in st.client["fields"]
            if f.get("name") == "movieCategory"), None) == "radarr")
check("never prints the secret", "new-pass-0123456789" not in r.stdout + r.stderr)

print("\n== radarr: a 400 is reported, not hidden ==")
qbt = Qbt()
st = Rd(qbt)
st.accept_put = False
r, st = run_rd("radarr", qbt, st)
print(r.stdout.rstrip())
check("exit 8", r.returncode == 8, r.returncode)
check("prints Radarr's validation failure", "Unable to connect" in r.stdout)

print("\n== test: valid -> 0 ==")
qbt = Qbt(password="new-pass-0123456789")
r, _ = run_rd("test", qbt, Rd(qbt, password="new-pass-0123456789"))
print(r.stdout.rstrip())
check("exit 0", r.returncode == 0, r.stderr[-300:])
check("prints isValid=True", "isValid=True" in r.stdout)

print("\n== test: stale password -> 9 and Radarr's message ==")
qbt = Qbt(password="moved-on")
r, _ = run_rd("test", qbt)
print(r.stdout.rstrip())
check("exit 9", r.returncode == 9, r.returncode)
check("prints isValid=False", "isValid=False" in r.stdout)
check("prints the failure", "Authentication Failure" in r.stdout)

print("\n== import: DownloadedMoviesScan is queued for the folder ==")
qbt = Qbt()
r, st = run_rd("import", qbt, path="/data/torrents/The Breakfast Club (1985)")
print(r.stdout.rstrip())
check("exit 0", r.returncode == 0, r.stderr[-300:])
check("command name", (st.commands or [{}])[0].get("name") == "DownloadedMoviesScan",
      st.commands)
check("path passed through",
      (st.commands or [{}])[0].get("path") == "/data/torrents/The Breakfast Club (1985)",
      st.commands)
check("prints the command id", "command id: 42" in r.stdout)

print("\n== import: rejected -> 10 ==")
qbt = Qbt()
st = Rd(qbt)
st.command_status = 400
r, st = run_rd("import", qbt, st, path="/data/torrents")
print(r.stdout.rstrip())
check("exit 10", r.returncode == 10, r.returncode)

print("\n%s" % ("ALL PASS" if not fails else "%d FAILURE(S)" % fails))
sys.exit(1 if fails else 0)

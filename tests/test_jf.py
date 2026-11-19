#!/usr/bin/env python3
"""Offline test for jellyfin_admin.sh.

Extracts the embedded Python, then test-only substitutes (never touching the
real script): the base-URL candidates -> a local mock, the DB path -> a temp
sqlite file, and time.sleep(10) -> 0.05 so the scan poll finishes quickly.
"""
import json, os, re, sqlite3, subprocess, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, HTTPServer

SRC = "/home/jordan/Documents/SystemBuild/jellyfin_admin.sh"
TOKEN = "deadbeefcafe1234567890"

def extract():
    src = open(SRC).read()
    m = re.search(r"python3 -\" <<'PY'\n(.*?)\nPY\n", src, re.S) or \
        re.search(r"python3 -\"\s*<<'PY'\n(.*?)\nPY\n", src, re.S)
    if not m:
        sys.exit("could not extract heredoc")
    return m.group(1)

class State:
    def __init__(self):
        self.server_name = "a45dba6c517e"
        self.cfg_posts = 0
        self.scan_polls = 0
        self.scans_started = 0
        self.valid_token = TOKEN

def serve(state, port=0):
    class H(BaseHTTPRequestHandler):
        def log_message(self, *a): pass
        def _json(self, code, payload):
            b = json.dumps(payload).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(b)))
            self.end_headers()
            self.wfile.write(b)
        def _auth(self):
            t = self.headers.get("X-Emby-Token")
            return t == state.valid_token
        def do_GET(self):
            if self.path == "/System/Info/Public":
                return self._json(200, {"Version": "12.4.0"})
            if not self._auth():
                return self._json(401, {"error": "unauthorized"})
            if self.path == "/System/Configuration":
                return self._json(200, {"ServerName": state.server_name,
                                        "UICulture": "en-US"})
            if self.path == "/ScheduledTasks":
                state.scan_polls += 1
                # running for the first two polls, then idle
                running = state.scans_started and state.scan_polls <= 2
                return self._json(200, [{
                    "Key": "RefreshLibrary",
                    "State": "Running" if running else "Idle",
                    "LastExecutionResult": {"EndTimeUtc": "2026-11-19T00:00:00Z"}}])
            return self._json(404, {})
        def do_POST(self):
            n = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(n)
            if self.path == "/Library/Refresh":
                state.scans_started += 1
                self.send_response(204); self.end_headers(); return
            if not self._auth():
                return self._json(401, {})
            if self.path == "/System/Configuration":
                state.cfg_posts += 1
                state.server_name = json.loads(body or b"{}").get("ServerName")
                self.send_response(204); self.end_headers(); return
            return self._json(404, {})

    srv = HTTPServer(("127.0.0.1", port), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv

def run(block, port, action, name=""):
    env = dict(os.environ, JF_ACTION=action, JF_NEWNAME=name)
    return subprocess.run([sys.executable, "-"], input=block,
                          capture_output=True, text=True, env=env)

def make_db(path):
    con = sqlite3.connect(path)
    con.execute("create table ApiKeys (Id text, AccessToken text, Name text)")
    con.execute("insert into ApiKeys values (?,?,?)", ("1", TOKEN, "helper"))
    con.commit(); con.close()

fails = 0
def check(label, cond, detail=""):
    global fails
    if cond:
        print("  PASS  %s" % label)
    else:
        fails += 1
        print("  FAIL  %s %s" % (label, detail))

raw = extract()
dbpath = os.path.join(tempfile.mkdtemp(), "jellyfin.db")
make_db(dbpath)

print("== 0. base-URL probe picks a reachable endpoint ==")
srv = serve(State())
port = srv.server_address[1]
block = (raw.replace('("http://192.168.122.10:8096", "http://127.0.0.1:8096")',
                     '("http://127.0.0.1:%d",)' % port)
            .replace('DB   = "/data/config/jellyfin/data/jellyfin.db"',
                     'DB   = %r' % dbpath)
            .replace("time.sleep(10)", "time.sleep(0.05)"))
r = run(block, port, "--show")
print(r.stdout.rstrip())
check("exit 0", r.returncode == 0, r.stderr[-400:])
check("printed endpoint", "endpoint: http://127.0.0.1:%d" % port in r.stdout)
check("printed ServerName", "a45dba6c517e" in r.stdout)
srv.shutdown()

print("\n== 1. --show reports the scan task ==")
st = State(); srv = serve(st); port = srv.server_address[1]
block = block.replace("http://127.0.0.1:%d" % 0, "")  # no-op
block_port = (raw.replace('("http://192.168.122.10:8096", "http://127.0.0.1:8096")',
                          '("http://127.0.0.1:%d",)' % port)
                 .replace('DB   = "/data/config/jellyfin/data/jellyfin.db"',
                          'DB   = %r' % dbpath)
                 .replace("time.sleep(10)", "time.sleep(0.05)"))
r = run(block_port, port, "--show")
print(r.stdout.rstrip())
check("exit 0", r.returncode == 0, r.stderr[-300:])
check("shows scan task line", "scan task" in r.stdout)
srv.shutdown()

print("\n== 2. --scan triggers refresh and sees Running -> finished ==")
st = State(); srv = serve(st); port = srv.server_address[1]
blk = (raw.replace('("http://192.168.122.10:8096", "http://127.0.0.1:8096")',
                   '("http://127.0.0.1:%d",)' % port)
          .replace('DB   = "/data/config/jellyfin/data/jellyfin.db"',
                   'DB   = %r' % dbpath)
          .replace("time.sleep(10)", "time.sleep(0.05)"))
r = run(blk, port, "--scan")
print(r.stdout.rstrip())
check("exit 0", r.returncode == 0, r.stderr[-300:])
check("POSTed /Library/Refresh", st.scans_started == 1, st.scans_started)
check("saw running", "scan running" in r.stdout)
check("saw finished", "scan finished" in r.stdout)
srv.shutdown()

print("\n== 3. --server-name writes and reads back ==")
st = State(); srv = serve(st); port = srv.server_address[1]
blk = (raw.replace('("http://192.168.122.10:8096", "http://127.0.0.1:8096")',
                   '("http://127.0.0.1:%d",)' % port)
          .replace('DB   = "/data/config/jellyfin/data/jellyfin.db"',
                   'DB   = %r' % dbpath)
          .replace("time.sleep(10)", "time.sleep(0.05)"))
r = run(blk, port, "--server-name", "Family Media")
print(r.stdout.rstrip())
check("exit 0", r.returncode == 0, r.stderr[-300:])
check("posted config", st.cfg_posts >= 1, st.cfg_posts)
check("stored new name", st.server_name == "Family Media", st.server_name)
check("printed transition", "'a45dba6c517e' -> 'Family Media'" in r.stdout)
srv.shutdown()

print("\n== 4. rejected key -> clear message, exit 7 ==")
st = State(); st.valid_token = "different-token"; srv = serve(st)
port = srv.server_address[1]
blk = (raw.replace('("http://192.168.122.10:8096", "http://127.0.0.1:8096")',
                   '("http://127.0.0.1:%d",)' % port)
          .replace('DB   = "/data/config/jellyfin/data/jellyfin.db"',
                   'DB   = %r' % dbpath)
          .replace("time.sleep(10)", "time.sleep(0.05)"))
r = run(blk, port, "--show")
print(r.stdout.rstrip())
check("exit 7", r.returncode == 7, r.returncode)
check("names the HTTP status", "HTTP 401" in r.stdout)
check("no traceback", "Traceback" not in r.stderr, r.stderr[-200:])
srv.shutdown()

print("\n== 5. nothing listening -> exit 5, no traceback ==")
blk = (raw.replace('("http://192.168.122.10:8096", "http://127.0.0.1:8096")',
                   '("http://127.0.0.1:9",)')
          .replace('DB   = "/data/config/jellyfin/data/jellyfin.db"',
                   'DB   = %r' % dbpath)
          .replace("time.sleep(10)", "time.sleep(0.05)"))
r = run(blk, 9, "--show")
print(r.stdout.rstrip())
check("exit 5", r.returncode == 5, r.returncode)
check("no traceback", "Traceback" not in r.stderr, r.stderr[-200:])

print("\n%s" % ("ALL PASS" if not fails else "%d FAILURE(S)" % fails))
sys.exit(1 if fails else 0)

#!/usr/bin/env python3
"""Offline test for qbt_admin.sh --set-radarr-category.

Serves a fake Radarr v3 downloadclient API that mirrors the real schema
behaviour: unknown field names are silently dropped on PUT and the call still
returns 202. That is exactly the trap that made the old `category` field look
successful, so the verify step must catch a wrong name.
"""
import json, os, subprocess, sys, threading, re
from http.server import BaseHTTPRequestHandler, HTTPServer

# Radarr's real qBittorrent field names (movieCategory is the one that matters)
KNOWN = {"host", "port", "useSsl", "urlBase", "username", "password",
         "movieCategory", "movieImportedCategory", "tvCategory",
         "recentMoviePriority", "olderMoviePriority", "initialState",
         "sequentialOrder", "firstAndLast", "enable"}

def make_client(extra_fields):
    return {"id": 1, "name": "qBittorrent", "implementation": "QBittorrent",
            "implementationName": "qBittorrent", "enable": True,
            "protocol": "torrent", "priority": 1,
            "fields": [{"name": "host", "value": "gluetun"},
                       {"name": "port", "value": 8080},
                       {"name": "username", "value": "admin"}] + extra_fields}

class State:
    def __init__(self, client):
        self.client = client
        self.puts = []

def serve(state):
    class H(BaseHTTPRequestHandler):
        def log_message(self, *a): pass
        def _send(self, code, payload=None):
            body = b"" if payload is None else json.dumps(payload).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        def do_GET(self):
            if self.path == "/api/v3/downloadclient":
                self._send(200, [state.client])
            elif self.path.rstrip("/").endswith("/downloadclient/1"):
                self._send(200, state.client)
            else:
                self._send(404, {})
        def do_PUT(self):
            n = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(n) or b"{}")
            state.puts.append(body)
            # Radarr behaviour: deserialize only known fields, drop the rest.
            kept = [f for f in body.get("fields", []) if f.get("name") in KNOWN]
            for k in ("enable", "name", "implementation"):
                if k in body:
                    state.client[k] = body[k]
            state.client["fields"] = kept
            self._send(202, state.client)
    srv = HTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv

def extract_block(path):
    src = open(path).read()
    m = re.search(r'python3 - "\$RD" <<\'PY\'\n(.*?)\nPY\n\}', src, re.S)
    if not m:
        sys.exit("could not extract the python block from qbt_admin.sh")
    return m.group(1)

block = extract_block("/home/jordan/Documents/SystemBuild/qbt_admin.sh")
open("/tmp/opencode/f61/rd_block.py", "w").write(block)

def run(client, cat="radarr"):
    state = State(client)
    srv = serve(state)
    port = srv.server_address[1]
    env = dict(os.environ, KEY="testkey", CAT=cat)
    r = subprocess.run([sys.executable, "/tmp/opencode/f61/rd_block.py",
                        "http://127.0.0.1:%d" % port],
                       capture_output=True, text=True, env=env)
    srv.shutdown()
    return r, state

def field(client, name):
    return next((f.get("value") for f in client["fields"]
                 if f.get("name") == name), "<absent>")

fails = 0
def check(label, cond, detail=""):
    global fails
    if cond:
        print("  PASS  %s" % label)
    else:
        fails += 1
        print("  FAIL  %s %s" % (label, detail))

print("== 1. empty movieCategory gets set ==")
r, st = run(make_client([{"name": "movieCategory", "value": ""}]))
print(r.stdout.rstrip())
check("exit 0", r.returncode == 0, r.stderr[-300:])
check("stored movieCategory=radarr", field(st.client, "movieCategory") == "radarr",
      field(st.client, "movieCategory"))
check("printed verify OK", "verify: OK" in r.stdout)

print("\n== 2. already correct -> no change reported ==")
r, st = run(make_client([{"name": "movieCategory", "value": "radarr"}]))
print(r.stdout.rstrip())
check("exit 0", r.returncode == 0, r.stderr[-300:])
check("value still radarr", field(st.client, "movieCategory") == "radarr")

print("\n== 3. custom value persists (tvCategory-shaped client) ==")
r, st = run(make_client([{"name": "tvCategory", "value": ""}]), cat="sonarr-x")
print(r.stdout.rstrip())
check("exit 0", r.returncode == 0, r.stderr[-300:])
check("stored tvCategory=sonarr-x", field(st.client, "tvCategory") == "sonarr-x",
      field(st.client, "tvCategory"))

print("\n== 4. no category field -> adds movieCategory ==")
r, st = run(make_client([]))
print(r.stdout.rstrip())
check("exit 0", r.returncode == 0, r.stderr[-300:])
check("stored movieCategory=radarr", field(st.client, "movieCategory") == "radarr")

print("\n== 5. regression proof: field named 'category' is dropped by Radarr ==")
# This is the old script's behaviour. The mock keeps schema fidelity, so the
# value must vanish -- demonstrating why verification (and the right name)
# matters, and that this script no longer does it.
r, st = run(make_client([{"name": "category", "value": "", "label": "x"}]))
print(r.stdout.rstrip())
check("stray category NOT kept by schema",
      field(st.client, "category") == "<absent>", field(st.client, "category"))
check("script still stored the real field",
      field(st.client, "movieCategory") == "radarr",
      field(st.client, "movieCategory"))
check("notices the stray field", "Radarr ignores it" in r.stdout)

print("\n%s" % ("ALL PASS" if not fails else "%d FAILURE(S)" % fails))
sys.exit(1 if fails else 0)

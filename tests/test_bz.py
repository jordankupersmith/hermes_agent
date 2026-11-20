#!/usr/bin/env python3
"""Offline test for bazarr_policy.sh against the REAL Bazarr 1.5.6 contract:

- GET  /api/system/languages/profiles   -> read-only list
- POST /api/system/settings             -> form field `languages-profiles`
                                           (JSON list; profiles absent are deleted)
- cutoff is an ITEM id (65535 = any)
"""
import json, os, re, subprocess, sys, tempfile, threading, urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

SRC = "/home/jordan/Documents/SystemBuild/bazarr_policy.sh"
KEY = "testkey"

def extract():
    src = open(SRC).read()
    m = re.search(r'python3 - "\$BASE" "\$KEY" <<\'PY\'\n(.*?)\nPY\n', src, re.S)
    if not m:
        sys.exit("could not extract the profile block")
    return m.group(1)

P1 = {
    "profileId": 1, "name": "Latin American Spanish", "cutoff": 1,
    "mustContain": [], "mustNotContain": [], "originalFormat": False, "tag": None,
    "items": [
        {"id": 1, "language": "ea", "hi": "False", "forced": "False",
         "audio_exclude": "False", "audio_only_include": "True"},
        {"id": 2, "language": "es", "hi": "False", "forced": "False",
         "audio_exclude": "False", "audio_only_include": "True"},
    ],
}
P2 = {
    "profileId": 2, "name": "Other", "cutoff": 3,
    "mustContain": [], "mustNotContain": [], "originalFormat": False, "tag": "keepme",
    "items": [{"id": 3, "language": "en", "hi": "False", "forced": "False",
               "audio_exclude": "False", "audio_only_include": "False"}],
}

class State:
    def __init__(self, reject=False, reorder=False):
        self.profiles = {1: json.loads(json.dumps(P1)), 2: json.loads(json.dumps(P2))}
        self.saves = []
        self.reject = reject
        self.reorder = reorder

def serve(state):
    class H(BaseHTTPRequestHandler):
        def log_message(self, *a): pass
        def _json(self, code, payload=None):
            b = b"" if payload is None else json.dumps(payload).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(b)))
            self.end_headers()
            self.wfile.write(b)
        def _text(self, code, text):
            b = text.encode()
            self.send_response(code)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(b)))
            self.end_headers()
            self.wfile.write(b)
        def do_GET(self):
            if self.path == "/api/system/languages/profiles":
                return self._json(200, list(state.profiles.values()))
            return self._json(404, {})
        def do_POST(self):
            n = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(n).decode()
            ctype = self.headers.get("Content-Type", "")
            if self.path != "/api/system/settings":
                return self._text(405, "method not allowed")
            if "application/x-www-form-urlencoded" not in ctype:
                return self._text(400, "expected form encoding")
            form = urllib.parse.parse_qs(raw)
            if "languages-profiles" not in form:
                return self._text(400, "missing languages-profiles")
            payload = json.loads(form["languages-profiles"][0])
            state.saves.append(payload)
            if state.reject:
                return self._text(406, "Validation error: Name: Must have a name")
            # handler semantics: replace the whole table, deleting absent ids
            kept = {}
            for p in payload:
                p = json.loads(json.dumps(p))
                if state.reorder:
                    p["items"] = list(reversed(p["items"]))
                kept[p["profileId"]] = p
            state.profiles = kept
            return self._text(204, "")

    srv = HTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv

def run(block, port, apply_flag):
    d = tempfile.mkdtemp()
    prof = os.path.join(d, "profiles.json")
    json.dump([json.loads(json.dumps(P1)), json.loads(json.dumps(P2))], open(prof, "w"))
    env = dict(os.environ, APPLY="1" if apply_flag else "0", PID="1", PROFILES=prof)
    return subprocess.run([sys.executable, "-", "http://127.0.0.1:%d" % port, KEY],
                          input=block, capture_output=True, text=True, env=env)

fails = 0
def check(label, cond, detail=""):
    global fails
    if cond:
        print("  PASS  %s" % label)
    else:
        fails += 1
        print("  FAIL  %s %s" % (label, detail))

block = extract()

print("== 1. dry run: shows ids, saves nothing ==")
st = State(); srv = serve(st); port = srv.server_address[1]
r = run(block, port, False)
check("exit 0", r.returncode == 0, r.stderr[-400:])
check("no saves", st.saves == [], st.saves)
check("prints item ids", "id=1" in r.stdout and "id=3" in r.stdout)
check("explains cutoff", "cutoff points at item id" in r.stdout)
srv.shutdown()

print("\n== 2. apply: POST /api/system/settings, correct rows and cutoff id ==")
st = State(); srv = serve(st); port = srv.server_address[1]
r = run(block, port, True)
print(r.stdout.rstrip())
check("exit 0", r.returncode == 0, r.stderr[-400:])
check("one save", len(st.saves) == 1, len(st.saves))
sent = st.saves[0] if st.saves else []
p1 = next((p for p in sent if p["profileId"] == 1), {})
items = p1.get("items") or []
check("order ea,es,es.hi (fix 83: no LatAm-HI row)",
      [i["language"] for i in items] == ["ea", "es", "es"],
      [i["language"] for i in items])
check("hi strings False,False,True", [i["hi"] for i in items]
      == ["False", "False", "True"], [i["hi"] for i in items])
check("ids 1,2,3", [i["id"] for i in items] == [1, 2, 3], [i["id"] for i in items])
check("cutoff = last item id (3)", p1.get("cutoff") == 3, p1.get("cutoff"))
check("no LatAm HI row is created", not any(
    i["language"] == "ea" and i["hi"] == "True" for i in items), items)
check("audio_only_include copied", all(i.get("audio_only_include") == "True"
                                       for i in items))
check("verify OK", "verify: OK" in r.stdout)
check("reports 2 profiles sent", "(2 profile(s) sent)" in r.stdout, r.stdout[-200:])
srv.shutdown()

print("\n== 3. OTHER PROFILES SURVIVE (the handler deletes absent ones) ==")
st = State(); srv = serve(st); port = srv.server_address[1]
r = run(block, port, True)
check("exit 0", r.returncode == 0, r.stderr[-300:])
check("profile 2 still stored", 2 in st.profiles, list(st.profiles))
check("profile 2 name intact", st.profiles.get(2, {}).get("name") == "Other",
      st.profiles.get(2, {}).get("name"))
check("profile 2 items intact",
      [i["language"] for i in st.profiles.get(2, {}).get("items", [])] == ["en"])
srv.shutdown()

print("\n== 4. rejection 406 -> exit 4, nothing saved, no traceback ==")
st = State(reject=True); srv = serve(st); port = srv.server_address[1]
r = run(block, port, True)
print(r.stdout.rstrip())
check("exit 4", r.returncode == 4, r.returncode)
check("shows 406", "HTTP 406" in r.stdout)
check("shows body", "Validation error" in r.stdout)
check("says nothing saved", "nothing was saved" in r.stdout)
check("no traceback", "Traceback" not in r.stderr, r.stderr[-200:])
srv.shutdown()

print("\n== 5. reordered read-back -> rollback restores original, exit 3 ==")
st = State(reorder=True); srv = serve(st); port = srv.server_address[1]
r = run(block, port, True)
print(r.stdout.rstrip())
check("exit 3", r.returncode == 3, r.returncode)
check("two saves (new + rollback)", len(st.saves) == 2, len(st.saves))
check("MISMATCH reported", "MISMATCH" in r.stdout)
restored = (st.saves[1] if len(st.saves) > 1 else [])
rp = next((p for p in restored if p["profileId"] == 1), {})
check("rollback sent original rows",
      [i["language"] for i in rp.get("items", [])] == ["ea", "es"],
      [i["language"] for i in rp.get("items", [])])
check("rollback cut back to id 1", rp.get("cutoff") == 1, rp.get("cutoff"))
srv.shutdown()

print("\n%s" % ("ALL PASS" if not fails else "%d FAILURE(S)" % fails))
sys.exit(1 if fails else 0)

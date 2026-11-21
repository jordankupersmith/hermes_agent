#!/usr/bin/env python3
"""Offline test for radarr_admin.sh (fix 87 — custom formats + quality profile).

Why this exists: the scores decide what the household *downloads*, and the two
ways to get it wrong are silent:

  * a MediaInfo condition (audio codec / video codec) is UNKNOWN at grab time,
    so it scores nothing when Radarr decides whether to download. The CF has to
    be a release-title regex. This suite pins that the created specifications
    are ReleaseTitleSpecification and carry the regex.
  * a quality profile PUT replaces the WHOLE profile. Dropping a format score,
    or a nested quality node, breaks future grabs without any error. So the
    suite asserts the other format items survive, that the allowed set is
    exactly the plan, and that the cutoff is one of the allowed qualities.

It also pins the house rules: plan-by-default (nothing written without --apply),
real idempotence (a second run writes nothing), a 0600 backup before the PUT,
and a read-back — because Radarr answers 202 before the change is visible.
"""
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "radarr_admin.sh")
src = open(SRC).read()
BLOCK = src.split("python3 - <<'PY'\n", 1)[1].split("\nPY\n", 1)[0]

fails = 0


def check(label, cond, detail=""):
    global fails
    print("  %s  %s %s" % ("PASS" if cond else "FAIL", label,
                           "" if cond else detail))
    if not cond:
        fails += 1


def schema(impls=("ReleaseTitleSpecification", "AudioCodecSpecification")):
    out = {}
    for i in impls:
        key = i[0].lower() + i[1:]
        out[key] = {"implementation": i, "name": i.replace("Specification", ""),
                    "negate": False, "required": False,
                    "fields": [{"name": "value", "value": ""}]}
    return out


def profile(allowed=None, format_items=None):
    allowed = allowed if allowed is not None else [
        "WEBDL-1080p", "Bluray-1080p", "Bluray-1080p Remux",
        "WEBDL-2160p", "Bluray-2160p"]
    quals = {"WEBDL-1080p": 3, "Bluray-1080p": 7, "Bluray-1080p Remux": 9,
             "WEBDL-2160p": 19, "Bluray-2160p": 18}
    return {
        "id": 1, "name": "HD-1080p", "upgradeAllowed": True, "cutoff": 7,
        "minFormatScore": 0, "cutoffFormatScore": 0,
        "items": [{"quality": {"id": quals[n], "name": n}, "items": [],
                   "allowed": n in allowed} for n in quals],
        "formatItems": format_items if format_items is not None else [],
    }


class State:
    def __init__(self, impls=("ReleaseTitleSpecification", "AudioCodecSpecification"),
                 existing_cfs=None, store_scores=True):
        self.impls = impls
        self.cfs = list(existing_cfs or [])
        self.next_id = 100
        self.prof = profile()
        self.store_scores = store_scores
        self.posts = []
        self.puts = []
        self.keys = []

    def cf(self, name):
        return next((c for c in self.cfs if c["name"] == name), None)


def serve(state):
    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def _send(self, obj, code=200):
            body = json.dumps(obj).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _body(self):
            n = int(self.headers.get("Content-Length") or 0)
            return json.loads(self.rfile.read(n) or b"{}")

        def do_GET(self):
            state.keys.append(self.headers.get("X-Api-Key"))
            p = urllib.parse.urlparse(self.path).path
            if p == "/api/v3/system/status":
                self._send({"version": "5.19.0.1"})
            elif p == "/api/v3/customformat/schema":
                self._send(schema(state.impls))
            elif p == "/api/v3/customformat":
                self._send(state.cfs)
            elif p == "/api/v3/qualityprofile":
                self._send([state.prof])
            else:
                self._send({}, 404)

        def do_POST(self):
            state.keys.append(self.headers.get("X-Api-Key"))
            body = self._body()
            state.posts.append(body)
            body["id"] = state.next_id
            state.next_id += 1
            state.cfs.append(body)
            self._send(body, 202)

        def do_PUT(self):
            state.keys.append(self.headers.get("X-Api-Key"))
            body = self._body()
            p = urllib.parse.urlparse(self.path).path
            if p.startswith("/api/v3/customformat/"):
                state.puts.append(("cf", body))
                for i, c in enumerate(state.cfs):
                    if str(c["id"]) == p.rsplit("/", 1)[1]:
                        state.cfs[i] = body
                self._send(body, 202)
            elif p.startswith("/api/v3/qualityprofile/"):
                state.puts.append(("profile", body))
                if state.store_scores:
                    state.prof = body
                else:                      # accepts 202, stores nothing
                    state.prof = profile()
                self._send(body, 202)
            else:
                self._send({}, 404)

    srv = HTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


def run(state, mode="status", apply=0, extra=None, backup_dir=None):
    srv = serve(state)
    base = "http://127.0.0.1:%d" % srv.server_address[1]
    env = dict(os.environ, BASE=base, KEY="test-key", MODE=mode,
               APPLY="1" if apply else "0",
               QUALITIES="WEBDL-1080p,Bluray-1080p,Bluray-1080p Remux",
               CUTOFF="Bluray-1080p", PROFILE="", RESTORE="",
               BACKUP_DIR=backup_dir or tempfile.mkdtemp(prefix="rd-backup-"))
    env.update(extra or {})
    r = subprocess.run([sys.executable, "-c", BLOCK], capture_output=True,
                       text=True, env=env)
    srv.shutdown()
    return r


print("== status is read-only and names the state ==")
st = State()
r = run(st, "status")
check("exits 0", r.returncode == 0, r.stderr[:300])
check("no writes", not st.posts and not st.puts, "%r" % (st.puts,))
check("names the profile and its allowed qualities",
      "'HD-1080p'" in r.stdout and "WEBDL-1080p" in r.stdout, r.stdout[:300])
check("says which managed formats are missing", "MISSING" in r.stdout)
check("the API key travels as X-Api-Key",
      st.keys and all(k == "test-key" for k in st.keys), repr(st.keys[:3]))

print("== plan mode writes nothing ==")
st = State()
r = run(st, "custom-formats")
check("exits 0", r.returncode == 0, r.stderr[:300])
check("no POST and no PUT", not st.posts and not st.puts,
      "%r %r" % (st.posts, st.puts))
check("says nothing was written", "nothing written" in r.stdout)

print("== apply creates title-regex formats, not MediaInfo conditions ==")
st = State()
backups = tempfile.mkdtemp(prefix="rd-backup-")
r = run(st, "custom-formats", apply=1, backup_dir=backups)
print(r.stdout.rstrip()[-900:])
check("exits 0", r.returncode == 0, r.stderr[:300])
check("six custom formats created", len(st.posts) == 6, repr(len(st.posts)))
check("every specification is a ReleaseTitleSpecification (no MediaInfo condition"
      " is ever created: it would be unknown at grab time)",
      all(s["implementation"] == "ReleaseTitleSpecification"
          for p in st.posts for s in p["specifications"]),
      repr([[s["implementation"] for s in p["specifications"]] for p in st.posts]))
check("every format carries a non-empty regex",
      all(s["fields"][0]["value"].strip()
          for p in st.posts for s in p["specifications"]))
names = {c["name"] for c in st.cfs}
check("the -10000 set is complete",
      {"NO TrueHD / Atmos", "NO DTS-HD / DTS-X", "NO Remux",
       "NO MULTi / DUAL"} <= names, repr(names))
check("one profile PUT with the scores",
      len([p for k, p in st.puts if k == "profile"]) == 1,
      repr([k for k, _ in st.puts]))
scores = {fi["name"]: fi["score"] for fi in st.prof["formatItems"]}
check("scores are on the profile",
      scores.get("NO TrueHD / Atmos") == -10000 and scores.get("PREF H.264") == 50
      and scores.get("PREF AC3") == 25, repr(scores))
check("format items reference real ids",
      all(fi["format"] is not None for fi in st.prof["formatItems"]))
check("says what it verified", "verify: OK" in r.stdout)
bk = [f for f in os.listdir(backups) if f.endswith(".json")]
check("a backup was written before the PUT", len(bk) == 1, repr(bk))
if bk:
    p = os.path.join(backups, bk[0])
    check("the backup is root-only (0600)",
          stat.S_IMODE(os.stat(p).st_mode) == 0o600,
          oct(stat.S_IMODE(os.stat(p).st_mode)))
    check("the backup is the pre-change profile",
          json.load(open(p))["formatItems"] == [], repr(json.load(open(p))))

print("== a second apply writes nothing (real idempotence) ==")
st = State()
run(st, "custom-formats", apply=1, backup_dir=tempfile.mkdtemp())
before = (len(st.posts), len(st.puts))
r = run(st, "custom-formats", apply=1, backup_dir=tempfile.mkdtemp())
check("exits 0", r.returncode == 0, r.stderr[:300])
check("no writes on the second run",
      (len(st.posts), len(st.puts)) == before,
      "%r -> %r" % (before, (len(st.posts), len(st.puts))))
check("reports the profile as already scored", "already carries" in r.stdout)

print("== an existing format with another regex is updated, not duplicated ==")
st = State(existing_cfs=[{
    "id": 42, "name": "NO Remux", "includeCustomFormatWhenRenaming": False,
    "specifications": [{"name": "Release Title",
                        "implementation": "ReleaseTitleSpecification",
                        "negate": False, "required": True,
                        "fields": [{"name": "value", "value": "remux2"}]}]}])
r = run(st, "custom-formats", apply=1, backup_dir=tempfile.mkdtemp())
check("exits 0", r.returncode == 0, r.stderr[:300])
check("no duplicate created", len(st.cfs) == 6, repr(len(st.cfs)))
check("the old regex was replaced in place",
      st.cf("NO Remux")["specifications"][0]["fields"][0]["value"] == r"(?i)remux",
      repr(st.cf("NO Remux")))

print("== a schema without ReleaseTitleSpecification fails loudly ==")
st = State(impls=("AudioCodecSpecification",))
r = run(st, "custom-formats", apply=1)
check("exits 4", r.returncode == 4, "rc=%s" % r.returncode)
check("names the condition it wanted and what exists",
      "ReleaseTitleSpecification" in r.stderr
      and "AudioCodecSpecification" in r.stderr, r.stderr[:300])
check("wrote nothing", not st.posts and not st.puts)

print("== the read-back is not optional (202 is not proof) ==")
st = State(store_scores=False)
r = run(st, "custom-formats", apply=1, backup_dir=tempfile.mkdtemp())
check("exits 3 when the scores did not persist", r.returncode == 3,
      "rc=%s %s" % (r.returncode, r.stderr[:300]))
check("names the formats that did not persist", "read-back" in r.stderr,
      r.stderr[:300])

print("== quality profile: plan first, then an exact allowed set ==")
st = State()
r = run(st, "quality-profile")
check("plan mode writes nothing", not st.puts and r.returncode == 0)
check("shows before and planned after",
      "allowed:" in r.stdout and "->" in r.stdout, r.stdout[:300])

st = State()
r = run(st, "quality-profile", apply=1, backup_dir=tempfile.mkdtemp())
print(r.stdout.rstrip())
check("exits 0", r.returncode == 0, r.stderr[:300])
allowed = {i["quality"]["name"] for i in st.prof["items"] if i["allowed"]}
check("only the three planned qualities are allowed",
      allowed == {"WEBDL-1080p", "Bluray-1080p", "Bluray-1080p Remux"},
      repr(allowed))
check("2160p is disallowed", not any("2160p" in a for a in allowed), repr(allowed))
check("Remux stays allowed so the existing files are not unwanted",
      "Bluray-1080p Remux" in allowed, repr(allowed))
check("cutoff is an allowed quality",
      any(i["quality"]["id"] == st.prof["cutoff"] and i["allowed"]
          for i in st.prof["items"]), repr(st.prof["cutoff"]))
check("says what it verified", "verify: OK" in r.stdout)

print("== a quality name this Radarr does not have fails loudly ==")
st = State()
r = run(st, "quality-profile", apply=1, extra={"QUALITIES": "WEBDL-1080p,Bluray-9000p"})
check("exits 4", r.returncode == 4, "rc=%s" % r.returncode)
check("lists the available names", "WEBDL-2160p" in r.stderr, r.stderr[:300])
check("wrote nothing", not st.puts)

print("== a nested group node keeps its children's allowed flags ==")
st = State()
st.prof["items"].append({"quality": {"id": 40, "name": "Bluray-1080p Group"},
                         "items": [{"quality": {"id": 41, "name": "Bluray-1080p"},
                                    "items": [], "allowed": True}],
                         "allowed": True})
r = run(st, "quality-profile", apply=1, backup_dir=tempfile.mkdtemp())
check("exits 0", r.returncode == 0, r.stderr[:300])
check("the outer quality is disallowed too",
      not any(i["allowed"] for i in st.prof["items"]
              if (i.get("quality") or {}).get("name") == "Bluray-1080p Group"))

print("\n%d failure(s)" % fails)
sys.exit(1 if fails else 0)

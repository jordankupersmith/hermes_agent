#!/usr/bin/env python3
"""Offline test for qbt_admin.sh --fix-category-paths.

The trap this covers: qBittorrent 5 finishes an API add in *manual* torrent
management mode, because Radarr sends `category` but neither `savepath` nor
`autoTMM`. In that mode the category savePath is only used when
Session\\UseCategoryPathsInManualMode is true — default false. So a correctly
created category still had no effect and downloads landed in the default save
path (observed live: cat=radarr, save_path=/data/torrents, 2026-11-20).

The helper's decision logic lives in one python block (written to a temp file
and run twice: `check`, then `verify`). These fixtures drive every branch.
"""
import json
import os
import re
import subprocess
import sys
import tempfile

SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   "..", "qbt_admin.sh")

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
    m = re.search(r'cat > "\$TMP/catpaths\.py" <<\'PY\'\n(.*?)\nPY\n', src, re.S)
    if not m:
        sys.exit("could not extract the catpaths block from qbt_admin.sh")
    return m.group(1)


def run(mode, prefs, cats):
    d = tempfile.mkdtemp()
    script = os.path.join(d, "catpaths.py")
    open(script, "w").write(block())
    pp = os.path.join(d, "prefs.json")
    cp = os.path.join(d, "cats.json")
    json.dump(prefs, open(pp, "w"))
    json.dump(cats, open(cp, "w"))
    return subprocess.run([sys.executable, script, mode, pp, cp],
                          capture_output=True, text=True)


OFF = {"save_path": "/data/torrents",
       "use_category_paths_in_manual_mode": False}
ON = dict(OFF, use_category_paths_in_manual_mode=True)
CATS = {"radarr": {"name": "radarr", "savePath": "/data/torrents/movies"}}

print("== check: preference OFF ==")
r = run("check", OFF, CATS)
print(r.stdout.rstrip())
check("exits 10 (needs the fix)", r.returncode == 10, r.returncode)
check("prints the default path", "default save path" in r.stdout
      and "/data/torrents" in r.stdout)
check("explains why the category path is ignored",
      "ignoring the category path" in r.stdout)
check("prints the category path anyway", "/data/torrents/movies" in r.stdout)

print("\n== check: preference already ON ==")
r = run("check", ON, CATS)
print(r.stdout.rstrip())
check("exits 0 (idempotent)", r.returncode == 0, r.returncode)
check("says nothing to do", "nothing to do" in r.stdout)

print("\n== verify: preference persisted ==")
r = run("verify", ON, CATS)
print(r.stdout.rstrip())
check("exits 0", r.returncode == 0, r.returncode)
check("prints verify OK", "verify: OK" in r.stdout)

print("\n== verify: preference did NOT persist ==")
r = run("verify", OFF, CATS)
print(r.stdout.rstrip())
check("exits 3", r.returncode == 3, r.returncode)
check("says MISMATCH", "MISMATCH" in r.stdout)

print("\n== empty category savePath ==")
r = run("check", ON, {"radarr": {"name": "radarr", "savePath": ""}})
print(r.stdout.rstrip())
check("check exits 2", r.returncode == 2, r.returncode)
check("shows the implicit path", "/data/torrents/radarr" in r.stdout)
check("names the category", "radarr" in r.stdout)
r = run("verify", ON, {"radarr": {"name": "radarr", "savePath": ""}})
check("verify exits 2", r.returncode == 2, r.returncode)
check("says how to set it", "--create-category" in r.stdout)

print("\n== no categories at all ==")
r = run("verify", ON, {})
print(r.stdout.rstrip())
check("exits 0 with a note", r.returncode == 0, r.returncode)
check("says no categories", "no categories" in r.stdout)

print("\n%s" % ("ALL PASS" if not fails else "%d FAILURE(S)" % fails))
sys.exit(1 if fails else 0)

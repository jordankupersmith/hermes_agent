#!/usr/bin/env python3
"""Offline test for the normalizer's plan() (fix 78: keep Spanish subs).

plan() decides, per file, which audio track survives, whether a re-encode is
needed, and — the part fix 78 changed — which subtitle streams are carried into
the output. Getting it wrong is expensive in both directions: dropping a Spanish
track is what the owner objected to, and keeping a non-Spanish one breaks the
policy (diag S11 fails) while adding size for nothing.

The block is extracted from phase5_apply.sh and fed real ffprobe JSON shapes,
including the two traps this project has already been bitten by: a cover-art
stream at index 0, and `esp` (Esperanto) which is NOT Spanish.
"""
import json
import os
import re
import subprocess
import sys
import tempfile

APPLY = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                     "..", "phase5_apply.sh")

fails = 0


def check(label, cond, detail=""):
    global fails
    print("  %s  %s %s" % ("PASS" if cond else "FAIL", label, "" if cond else detail))
    if not cond:
        fails += 1


def block():
    src = open(APPLY).read()
    start = src.index("plan() {")
    m = re.search(r"python3 -c '\n(.*?)\n'\n\}", src[start:], re.S)
    if not m:
        sys.exit("could not extract plan() from phase5_apply.sh")
    return m.group(1)


def stream(idx, kind, lang=None, codec=None, w=0, h=0, br=0, ch=0, title=""):
    s = {"index": idx, "codec_type": kind}
    if codec:
        s["codec_name"] = codec
    tags = {}
    if lang:
        tags["language"] = lang
    if title:
        tags["title"] = title
    if tags:
        s["tags"] = tags
    if kind == "video":
        s["width"], s["height"], s["bit_rate"] = w, h, br
    if kind == "audio":
        s["channels"], s["bit_rate"] = ch, br
    return s


def plan(streams, ext="mkv"):
    d = tempfile.mkdtemp()
    script = os.path.join(d, "plan.py")
    open(script, "w").write(block())
    r = subprocess.run([sys.executable, script], input=json.dumps({"streams": streams}),
                       capture_output=True, text=True,
                       env=dict(os.environ, EXT=ext))
    out = {}
    for line in r.stdout.splitlines():
        if "=" in line and line.startswith("PLAN_"):
            k, v = line.split("=", 1)
            out[k] = v
    return out, r


# Alfred (film, eng AC3 5.1) + 2 Spanish subs + 1 English sub + cover art at 0.
FILM = stream(1, "video", codec="h264", w=1920, h=1080, br=8_000_000)
COVER = stream(0, "video", codec="mjpeg", w=600, h=600)
AUD = stream(2, "audio", lang="eng", codec="ac3", ch=6, br=640_000)
S_ES = stream(3, "subtitle", lang="spa", codec="subrip")
S_ESX = stream(4, "subtitle", lang="es-419", codec="subrip")
S_EN = stream(5, "subtitle", lang="eng", codec="subrip")
PGS_ES = stream(6, "subtitle", lang="spa", codec="hdmv_pgs_subtitle")

print("== the owner's case: spa + es-419 + eng -> keep the two Spanish, drop eng ==")
p, r = plan([COVER, FILM, AUD, S_ES, S_ESX, S_EN])
print("  ", {k: p.get(k) for k in ("PLAN_SUBS", "PLAN_SUBKEEP", "PLAN_SUBDROP",
                                  "PLAN_SUBIDX", "PLAN_NEED")})
check("plan ok", p.get("PLAN_OK") == "1", r.stdout + r.stderr)
check("two Spanish tracks kept", p.get("PLAN_SUBKEEP") == "2")
check("one non-Spanish dropped", p.get("PLAN_SUBDROP") == "1")
check("mapped by ABSOLUTE index", p.get("PLAN_SUBIDX") == "3,4")
check("needs a remux", p.get("PLAN_NEED") == "1")
check("film is the largest video, not the cover", p.get("PLAN_VIDX") == "1")

print("\n== already compliant: 1 audio + only Spanish subs -> no remux ==")
p, r = plan([FILM, AUD, S_ES])
check("need=0", p.get("PLAN_NEED") == "0", p)

print("\n== only non-Spanish subs -> all dropped (need=1) ==")
p, r = plan([FILM, AUD, S_EN])
check("nothing kept", p.get("PLAN_SUBKEEP") == "0")
check("remux still needed to drop it", p.get("PLAN_NEED") == "1")

print("\n== esp is Esperanto, never Spanish ==")
p, r = plan([FILM, AUD, stream(3, "subtitle", lang="esp", codec="subrip")])
check("nothing kept", p.get("PLAN_SUBKEEP") == "0", p)

print("\n== MP4 cannot carry bitmap subs: text kept, PGS excluded and reported ==")
p, r = plan([FILM, AUD, S_ES, PGS_ES], ext="mp4")
check("text kept", p.get("PLAN_SUBIDX") == "3", p)
check("uncarryable counted", p.get("PLAN_UNCARRY") == "1", p)
check("remux needed", p.get("PLAN_NEED") == "1")

print("\n== MP4 with only a PGS Spanish track -> nothing to map, no bogus index ==")
p, r = plan([FILM, AUD, PGS_ES], ext="mp4")
check("empty index list", p.get("PLAN_SUBIDX") == "", p)
check("reported as uncarryable", p.get("PLAN_UNCARRY") == "1")

print("\n== no subtitle streams at all (the pre-fix-78 shape) ==")
p, r = plan([FILM, AUD])
check("keep 0", p.get("PLAN_SUBKEEP") == "0")
check("need=0 once audio/video/codec are right", p.get("PLAN_NEED") == "0")

print("\n== TrueHD original audio still forces the AC3 re-encode ==")
p, r = plan([FILM, stream(2, "audio", lang="eng", codec="truehd", ch=8, br=4_000_000),
             S_ES])
check("copy=0 (must re-encode)", p.get("PLAN_COPY") == "0")
check("Spanish sub still kept", p.get("PLAN_SUBKEEP") == "1")
check("needs remux", p.get("PLAN_NEED") == "1")

print("\n%s" % ("ALL PASS" if not fails else "%d FAILED" % fails))
sys.exit(1 if fails else 0)

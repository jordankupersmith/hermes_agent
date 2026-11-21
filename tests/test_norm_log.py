#!/usr/bin/env python3
"""Offline tests for diag S11 (fix 88): what counts as a normalizer failure, and
which journal lines are still current.

Two false alarms motivated this suite, both observed live on 2026-11-21:

1. S11 counted every `fail(` line ever written. Two `fail(verify)` lines for
   Project Hail Mary were the PRE-fix-61 comparison (container 02:40:54 / German
   dub vs film 02:36:31) and the next attempt logged `done`. The diag warned
   about a bug that had already been fixed, forever.

2. The host journal scan counted boot-time bind failures that a later `Started`
   had superseded (the 2026-11-19 boot reached network-online.target ~20 s
   before DHCP assigned 192.168.1.133, so the discovery relay and Caddy failed
   to bind and were restarted). A unit that is still broken has no later start,
   so it must stay visible.

The awk programs are extracted from phase5_diag.sh, so the test cannot pass
against a copy that has drifted from the shipped script.
"""
import os
import re
import subprocess
import sys

DIAG = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "phase5_diag.sh")

fails = 0


def check(label, cond, detail=""):
    global fails
    print("  %s  %s %s" % ("PASS" if cond else "FAIL", label, "" if cond else detail))
    if not cond:
        fails += 1


def heredoc(name):
    src = open(DIAG).read()
    m = re.search(r"<<'%s'\n(.*?)\n%s\n" % (name, name), src, re.S)
    if not m:
        sys.exit("could not extract %s from phase5_diag.sh" % name)
    return m.group(1)


NORM_AWK = heredoc("NORMAWK")
JRNL_AWK = heredoc("JRANLEOF")
CADDY_BENIGN = re.search(r"^CADDY_BENIGN='(.*)'$", open(DIAG).read(), re.M).group(1)


def awk(program, text):
    p = subprocess.run(["awk", program], input=text, text=True,
                       capture_output=True)
    if p.returncode != 0:
        sys.exit("awk failed: %s" % p.stderr)
    return p.stdout


def norm(text):
    out = awk(NORM_AWK, text)
    return {k: v for k, v in (line.split("=", 1) for line in out.splitlines()
                              if "=" in line and not line.startswith("UNRESOLVED_FILE="))}, \
           [line.split("=", 1)[1] for line in out.splitlines()
            if line.startswith("UNRESOLVED_FILE=")]


T = "2026-11-18T22:%02d:%02dZ"


def line(ts, text):
    return "%s %s" % (ts, text)


print("== normalizer log: the real 2026-11-18 PHM history ==")
real = "\n".join([
    line(T % (57, 55), "ok(already normalized): /data/media/movies/Baseline Test (2026)/Baseline Test (2026).mp4"),
    line(T % (1, 14), "skip(space): need ~46354198 KiB, have 45316468 KiB: /data/media/movies/Project Hail Mary (2026)/Project Hail Mary (2026) Remux-1080p.mkv"),
    line(T % (35, 50), "remux: /data/media/movies/Project Hail Mary (2026)/Project Hail Mary (2026) Remux-1080p.mkv (orig_lang=eng audio=ac3 copy=1 audio_tracks:11->1 subs:36->0)"),
    line(T % (39, 39), "fail(verify a=1 s=0 v=1 want_s=0 dur=9654->9391): kept original: /data/media/movies/Project Hail Mary (2026)/Project Hail Mary (2026) Remux-1080p.mkv"),
    line(T % (45, 54), "remux: /data/media/movies/Project Hail Mary (2026)/Project Hail Mary (2026) Remux-1080p.mkv (orig_lang=eng audio=ac3 copy=1 audio_tracks:11->1 subs:36->0)"),
    line(T % (49, 39), "fail(verify a=1 s=0 v=1 want_s=0 dur=9654->9391): kept original: /data/media/movies/Project Hail Mary (2026)/Project Hail Mary (2026) Remux-1080p.mkv"),
    line(T % (55, 59), "remux: /data/media/movies/Project Hail Mary (2026)/Project Hail Mary (2026) Remux-1080p.mkv (orig_lang=eng audio=ac3 copy=1 audio_tracks:11->1 subs:36->0)"),
    line(T % (59, 52), "done: /data/media/movies/Project Hail Mary (2026)/Project Hail Mary (2026) Remux-1080p.mkv (audio:1 subs:0 video:1 dur:9391s->9391s)"),
]) + "\n"
counts, unresolved = norm(real)
check("both fix-61 retries are counted", counts.get("FAIL_LINES") == "2", repr(counts))
check("both are resolved by the later done", counts.get("RESOLVED") == "2", repr(counts))
check("nothing is reported as unresolved", counts.get("UNRESOLVED") == "0" and not unresolved,
      repr((counts, unresolved)))

print("== normalizer log: a failure with no later success stays news ==")
open_f = "\n".join([
    line(T % (10, 0), "fail(verify a=1 s=2 v=1 want_s=0 dur=100->100): kept original: /data/media/movies/Some Title (2020)/Some Title (2020) Bluray-1080p.mkv"),
]) + "\n"
counts, unresolved = norm(open_f)
check("the failure is counted", counts.get("FAIL_LINES") == "1", repr(counts))
check("it is unresolved", counts.get("UNRESOLVED") == "1", repr(counts))
check("the whole path (spaces, parentheses) is printed",
      unresolved == ["/data/media/movies/Some Title (2020)/Some Title (2020) Bluray-1080p.mkv"],
      repr(unresolved))

print("== normalizer log: a success for a DIFFERENT file does not resolve it ==")
other_f = open_f + line(T % (11, 0), "done: /data/media/movies/Other (2019)/Other (2019).mkv (audio:1 subs:0 video:1 dur:10s->10s)") + "\n"
counts, unresolved = norm(other_f)
check("still unresolved", counts.get("UNRESOLVED") == "1", repr(counts))
check("the unresolved path is the failed one", unresolved and "Some Title" in unresolved[0],
      repr(unresolved))

print("== normalizer log: a success EARLIER than the failure does not resolve it ==")
backwards = "\n".join([
    line(T % (9, 0), "done: /data/media/movies/A (2001)/A.mkv (audio:1 subs:0 video:1 dur:10s->10s)"),
    line(T % (10, 0), "fail(verify a=2 s=0 v=1 want_s=0 dur=10->10): kept original: /data/media/movies/A (2001)/A.mkv"),
]) + "\n"
counts, unresolved = norm(backwards)
check("order matters (later success only)", counts.get("UNRESOLVED") == "1", repr(counts))

print("== normalizer log: ok(already normalized) also resolves; ffmpeg fail has no path ==")
ok_after = "\n".join([
    line(T % (10, 0), "fail(ffmpeg): kept original: /data/media/movies/B (2002)/B.mkv"),
    line(T % (11, 0), "ok(already normalized): /data/media/movies/B (2002)/B.mkv"),
    line(T % (12, 0), "fail(ffmpeg): kept original: /data/media/movies/C (2003)/C.mkv"),
]) + "\n"
counts, unresolved = norm(ok_after)
check("two failures logged", counts.get("FAIL_LINES") == "2", repr(counts))
check("one resolved, one unresolved", counts.get("RESOLVED") == "1"
      and counts.get("UNRESOLVED") == "1", repr(counts))
check("only the real path is printed", unresolved == ["/data/media/movies/C (2003)/C.mkv"],
      repr(unresolved))

print("== normalizer log: empty and unreadable ==")
counts, unresolved = norm("")
check("empty log is 0/0/0", (counts.get("FAIL_LINES"), counts.get("RESOLVED"),
                             counts.get("UNRESOLVED")) == ("0", "0", "0"), repr(counts))
check("no invented path", unresolved == [], repr(unresolved))

print("== journal: the 2026-11-19 late-DHCP boot race, then a later start ==")
boot = "\n".join([
    "Nov 19 02:14:00 clawbox systemd[1]: Started jellyfin-discovery.service - Jellyfin LAN discovery relay",
    "Nov 19 02:14:00 clawbox socat[1651]: E bind(5): Cannot assign requested address",
    "Nov 19 02:14:00 clawbox systemd[1]: jellyfin-discovery.service: Main process exited, code=exited, status=1/FAILURE",
    "Nov 19 02:14:00 clawbox systemd[1]: jellyfin-discovery.service: Failed with result 'exit-code'.",
    "Nov 19 02:14:05 clawbox systemd[1]: jellyfin-discovery.service: Scheduled restart job, restart counter is at 1.",
    "Nov 19 02:14:26 clawbox systemd[1]: Started jellyfin-discovery.service - Jellyfin LAN discovery relay",
]) + "\n"
check("superseded boot failures are not current", awk(JRNL_AWK, boot) == "", repr(awk(JRNL_AWK, boot)))

print("== journal: a unit that is STILL failing has no later start ==")
broken = "\n".join([
    "Nov 19 02:14:00 clawbox systemd[1]: Started jellyfin-discovery.service - Jellyfin LAN discovery relay",
    "Nov 19 02:14:00 clawbox socat[1651]: E bind(5): Cannot assign requested address",
    "Nov 19 02:14:00 clawbox systemd[1]: jellyfin-discovery.service: Main process exited, code=exited, status=1/FAILURE",
    "Nov 19 02:14:00 clawbox systemd[1]: jellyfin-discovery.service: Failed with result 'exit-code'.",
]) + "\n"
out = awk(JRNL_AWK, broken)
check("the live bind failure survives", "Cannot assign requested address" in out, repr(out))
check("and its Failed line survives", "Failed with result" in out, repr(out))

print("== journal: a deliberate stop (apply restart) is not a failure ==")
stop = "\n".join([
    "Nov 21 10:44:01 clawbox systemd[1]: Started jellyfin-discovery.service - relay",
    "Nov 21 10:44:01 clawbox socat[183370]: W exiting on signal 15",
    "Nov 21 10:44:01 clawbox systemd[1]: Stopping jellyfin-discovery.service - relay...",
    "Nov 21 10:44:01 clawbox systemd[1]: jellyfin-discovery.service: Main process exited, code=exited, status=143/n/a",
    "Nov 21 10:44:01 clawbox systemd[1]: jellyfin-discovery.service: Failed with result 'exit-code'.",
    "Nov 21 10:44:01 clawbox systemd[1]: Stopped jellyfin-discovery.service - relay.",
]) + "\n"
check("SIGTERM is filtered", awk(JRNL_AWK, stop) == "", repr(awk(JRNL_AWK, stop)))

print("== journal: socket units reset on Listening on, not Started ==")
sock_old = "\n".join([
    "Nov 19 02:13:51 clawbox systemd[1]: Listening on jellyfin-lan-proxy.socket - listener",
    "Nov 19 02:13:51 clawbox systemd[1]: jellyfin-lan-proxy.socket: Failed to listen on sockets: Address already in use",
]) + "\n"
check("an error after the last Listening on stays visible",
      "Address already in use" in awk(JRNL_AWK, sock_old), repr(awk(JRNL_AWK, sock_old)))
sock_new = "\n".join([
    "Nov 19 02:13:51 clawbox systemd[1]: Failed to listen on jellyfin-lan-proxy.socket: Address already in use",
    "Nov 19 02:14:26 clawbox systemd[1]: Listening on jellyfin-lan-proxy.socket - listener",
]) + "\n"
check("but a later Listening on supersedes it", awk(JRNL_AWK, sock_new) == "",
      repr(awk(JRNL_AWK, sock_new)))

print("== caddy: only the documented local-CA line is ignored ==")
ca = '{"level":"error","logger":"pki.ca.local","msg":"failed to install root certificate","error":"failed to execute sudo: exit status 1"}'
bind = '{"level":"error","msg":"loading initial config: listen tcp 192.168.1.133:8443: bind: cannot assign requested address"}'
check("the fixed string matches the documented line", CADDY_BENIGN in ca, CADDY_BENIGN)
kept = [ln for ln in (ca, bind) if CADDY_BENIGN not in ln]
check("it keeps the documented line out", ca not in kept, repr(kept))
check("and keeps a real bind error in", bind in kept, repr(kept))
check("the filter is a FIXED string (dots are not wildcards)",
      "pki.ca.local" in CADDY_BENIGN and "\\." not in CADDY_BENIGN, CADDY_BENIGN)

print()
print("%d failure(s)" % fails)
sys.exit(1 if fails else 0)

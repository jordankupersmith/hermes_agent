# RESUME.md — start here after clearing the chat

One-screen handoff. Detailed context lives in `PROJECT_MEMORY.md` (§2a version
pairing, fixes 58–61), the runbook in `phase5_manual_steps.md` (Step 10), the
backlog in `TODO.md`, and the agent rules in `AGENTS.md`.

**Live state (verified 2026-11-19 18:0x UTC):**

| Thing | State |
| --- | --- |
| Jellyfin | `jellyfin/jellyfin:12.4`, reports `12.4.0`, plays on the Tizen TV (fix 58); server name **`Family Media`** |
| Library scan | **run** after the remux (`POST /Library/Refresh` → 204), task back to `Idle` |
| Bazarr | **`1.5.6` running** — fix 60 applied (V6/S4 green); OSC no longer returns 426 |
| Bazarr profile | `id=1` **`ea` non-HI → `es` non-HI → `ea` HI → `es` HI**, `cutoff=4` (item id), applied 17:56Z (fix 65) |
| The film | **normalized**: `audio 1 / subtitle 0 / video 1`, **32 GB** (was 41 GB), `dur:9391s->9391s`; `…es-MX.hi.srt` (117 KB) beside it; **`missing: []`** (was `missing=['ea']`) |
| Media normalizer (fix 59+61) | **installed + applied**; `timer` + `path` **active**; first good run `22:59:52Z` |
| Disk | `/data` **32 G used, 53 G free (38%)** — the 41 GiB torrent copy was removed with its data |
| Guardrail | `VERIFY_FAILS=0`; **G25** (fix 69) mutation-tested 6/6, **G26** (fixes 70/71) 11/11 — two of those mutations caught greps that matched prose instead of code, which is the point of the protocol |
| Repository | `git init -b main` done (commits `cc2e33d`, `db7c9bb`, `0e78996`, + fix 68); `tests/` holds the offline mock suites; **no remote yet**, license undecided |
| Download client (fix 67) | **repaired 2026-11-20**: ban cleared by restart, then `PUT downloadclient/1 -> 202` and `testall isValid=True` |
| qBt credential (fix 71/73) | first `--set-password` set it, "verified" it, then **lost it to a restart 3 s later** (settings flush at 5 s) — the stored file held a password nothing accepted. Fixed: the write is proven on disk *before* the restart and re-proven *after* it |
| qBt config path (fix 72) | **the file we wrote for weeks is not read by the app**: qBittorrent uses `/data/config/qbittorrent/qBittorrent/qBittorrent.conf` (subdirectory). That was the real cause of "the path switch reverts". apply/diag/--status now target the real path and the apply retires the ignored duplicate |
| *The Breakfast Club* (radarrId 3) | **orphaned at 34.3%** during the credential outage: Radarr removed the queue row, the torrent kept downloading. Fix the credential, then at 100% run `qbt_admin.sh --import-downloads "/data/torrents/<torrent folder>"` (a normal queue import will not happen) |

## Next commands (2026-11-20, in order)

```bash
cd /home/jordan/Documents/SystemBuild
sudo bash phase5_step1_install.sh          # install the apply/diag/guardrail edits
sudo bash /usr/local/sbin/phase5/phase5_apply.sh   # writes the path switch while qBt is stopped
sudo bash /usr/local/sbin/phase5/phase5_diag.sh    # S3 must PASS the path switch

sudo bash qbt_admin.sh --set-password      # ONE atomic credential (qBt + Radarr)
sudo bash qbt_admin.sh --status            # path mode live AND on disk = True
sudo bash library_status.sh "breakfast club"   # testall isValid=True
```

At 100% the torrent is an **orphan** (Radarr dropped the queue row while the
client was unreachable), so import it explicitly, then scan and reclaim:

```bash
sudo bash qbt_admin.sh --import-downloads "/data/torrents/<torrent folder>"
sudo bash jellyfin_admin.sh --scan
sudo bash library_status.sh "breakfast club"        # want YES
sudo bash qbt_admin.sh --remove-torrent "breakfast club" --yes   # clears the entry
```

The manual import resolves to Radarr's `ImportMode.Move`, so the library file is
a hardlink and the torrent's copy is unlinked by the import: the data is not
duplicated and `--remove-torrent` returns no space (expected — the library owns
the inode).

## Done 2026-11-19 (scripted — manual 10j)

```bash
cd /home/jordan/Documents/SystemBuild

sudo bash qbt_admin.sh --create-category radarr /data/torrents/movies   # 409 -> editCategory 200
sudo bash qbt_admin.sh --set-radarr-category radarr                     # movieCategory, verify OK
sudo bash qbt_admin.sh --remove-torrent "hail mary" --yes               # 40.2 GiB reclaimed
sudo bash jellyfin_admin.sh --scan                                      # library scan -> Idle
sudo bash jellyfin_admin.sh --server-name "Family Media"                # '' -> 'Family Media'
sudo bash bazarr_policy.sh --apply                                      # 4 rows, cutoff item id 4
```

**Status as of 2026-11-19 (status run):** login OK via the first-run temporary
password; the film's torrent was `uploading`, `cat=radarr`, `save_path=/data/torrents`,
`40.2 GiB`; `/data` was 72G/89G used, 13G free. The `radarr` category **existed
with an empty `savePath`**, and — see fix 69 — **even a correct path would not
have been used**: Radarr sends only a category, qBittorrent files such an add in
manual mode, and manual mode ignores the category path unless
`Session\UseCategoryPathsInManualMode` is on (default off). That is why the
torrent sat in `/data/torrents`; hardlinks were never affected (`/data` is one
filesystem). Setting the path then deleting the torrent with data brought
`/data` to **32G used / 53G free (38%)** with no Radarr queue entry to re-grab
it.

**Remaining (optional, fix 66): the upgrade task will not convert HI → non-HI.**
It was run on 2026-11-19 (job #33 `completed`, progress `Project Hail Mary`,
log `Finished searching for Subtitles to upgrade`) and correctly left the file
alone: it searches with the subtitle's own HI flag (and the new HI rows force
`hearing_impaired="force HI"`), needing `score + 2`. Only a fresh search
(backup + delete `.srt` + `scan-disk` + `search-missing`) could try for a
non-HI, at the risk of ending at `missing`. HI is an accepted row, so this is a
valid end state. Next real backlog item: Radarr Custom Formats (TODO 10i).

**Done 2026-11-19:** `--set-radarr-category` re-run with the fixed helper →
`movieCategory 'radarr' -> 'radarr'`, `verify: OK`; `check_normalize.sh` shows
the film still at **audio 1 / subtitle 0 / video 1**, 32G, units active.
`jellyfin_admin.sh --show` first failed with `ConnectionRefusedError` on
`127.0.0.1:8096` — the container is published as
`"192.168.122.10:8096:8096/tcp"`, so loopback refuses inside the VM. The helper
now probes the VM IP first (then loopback), prints the endpoint, and returns 5/7
with a clear message instead of a traceback.

**`--show` now works:** at the time it printed `endpoint:
http://192.168.122.10:8096`, `ServerName: ''` (before the rename below), scan
task `Idle` with a last run at `2026-11-19T13:15:43Z` (after the 22:59 remux).
The empty `ServerName` is why S5 saw a container id — the public endpoint falls
back to the hostname when the setting is blank.

**1. Reclaim — DONE (40.2 GiB).** The library `.mkv` was `nlink=1` (33.5 GB,
32G by `du`) while the **original 41 GiB remux** was still on disk in
`/data/torrents/<torrent name>/` and being seeded (`/proc/<qbt pid>/fd ->
/data/torrents/Project.Hail.Mary…-BTM/…mkv`). Removing that torrent **with
data** returned the space instantly: `/data` 72G used / 13G free → **32G / 53G
free (38%)**. The torrent sat directly under `/data/torrents/` because the
`radarr` category's `savePath` was empty — and, as fix 69 later proved, **a
correct path would still have been ignored** in qBittorrent's manual torrent
mode. New torrents reach `torrents/movies/` only after
`qbt_admin.sh --fix-category-paths`. Never delete from `/data/media/…` (that is
the file you built).

**2. Full library scan — DONE.** `jellyfin_admin.sh --scan` (`POST
/Library/Refresh` → 204) ran after the remux and the task returned to `Idle`.
This is mandatory after the 12.x upgrade (manual 10h) because the item keeps the
same path while the streams under it changed.

**3. Subtitle policy — DONE 2026-11-19T17:56Z (order corrected by the owner):
LatAm first, Castilian second, then the two HI fallbacks.**
`bazarr_policy.sh --apply` wrote the four profile rows (`ea` non-HI → `es`
non-HI → `ea` HI → `es` HI) with the cutoff on the last row's **item id 4**.
Read-back verified order + HI flags + cutoff, and the movie settled at
`missing: []` with `…Remux-1080p.es-MX.hi.srt` under `have` (`radarrId 1`).
Only one profile existed, so the settings-form POST carried one profile and
nothing else could be deleted. **Optional follow-up:** to replace the HI file
with a non-HI one (row 1 outranks row 3), run `sudo bash bazarr_status.sh
--upgrade` — the *Upgrade Previously Downloaded Subtitles* task. It only acts
when *Settings → Subtitles → Upgrade previously downloaded subtitles* is ON and
the subtitle is within `days_to_upgrade_subs`; `bazarr_status.sh` now prints
both settings.

**Subtitle writes go through the settings form (fix 65).** The profiles API is
read-only in 1.5.x (`Allow: HEAD, GET, OPTIONS`). The profile is written with
`POST /api/system/settings`, form field `languages-profiles`, carrying the
**complete** profile list — the handler deletes any profile missing from it, so
the script always sends all of them. `cutoff` is an **item id** (`65535` = any),
not a row index, so the script allocates ids and points the cutoff at the last
row. Movie assignment is `POST /api/movies?radarrid=&profileid=`.

**4. Rename the server — DONE.** `jellyfin_admin.sh --server-name "Family Media"`
wrote `'' -> 'Family Media'` (HTTP 204). S5 used to report a container id that
changes on every recreate because `/System/Info/Public` falls back to the
hostname when `ServerName` is blank; it no longer is. (The helper talks to
`192.168.122.10:8096` — loopback refuses inside the VM by design.)

## If you change apply / guardrail

The canonical sequence (Rule 3 in `AGENTS.md`) — `apply` re-installs the
normalizer and re-enables its units:

```bash
cd /home/jordan/Documents/SystemBuild
bash phase5_guardrail_test.sh                          # want VERIFY_FAILS=0
sudo bash phase5_step1_install.sh
sudo bash /usr/local/sbin/phase5/phase5_apply.sh       # want VERIFY_FAILS=0
sudo bash /usr/local/sbin/phase5/phase5_diag.sh        # want VERIFY_FAILS=0, S11 active
```

## Why fix 60 matters

OpenSubtitles.com returns **HTTP 426** to any Bazarr **below 1.5.4** — a client
*version* gate, not credentials or quota (OSC developer, bazarr issue #2121).
It was real: the last 426 is `22:29:44` from the old 1.5.1 container, then
`22:41:50 Using opensubtitlescom again`, status `Good`, and the es-MX `.srt`
appeared at `22:41`. `apply` V6 and `diag` S4 assert the running image.

## Why fix 61 matters

A remux lies about its shape. Its **container duration is the longest contained
stream** — this title has a `02:40:54` German dub and an mjpeg **cover-art
still** next to the `02:36:31` film, so `format=duration` read 9654 s and the
first sweep logged `fail(verify … dur=9654->9391): kept original` on a **correct**
remux, then retried every 10 minutes. Worse, `-map 0:v:0` would have written the
cover-art still as the "movie" and still passed the `1 video` count check.
The film stream is now chosen explicitly (`PLAN_VIDX`, cover-art codecs
excluded) and its own runtime is compared source-to-output. **The output is
~32 GB, not ~12 GB** — video is copied, only extra audio/subs are dropped.

## Open decisions / backlog (P1 in `TODO.md`)

- **es-LA vs es-ES:** RESOLVED 2026-11-19 — the profile accepts HI as rows 3–4,
  so `es-MX.hi` satisfies `missing: []`; LatAm non-HI still ranks first.
- **Radarr Custom Formats** — `-10000` for `TrueHD`/`Atmos`, `DTS-HD`/`DTS-X`,
  `Remux`, `MULTi`/`DUAL`; `+50` H.264, `+25` AC3 (manual 10i).
- **Rename the server** — DONE: `jellyfin_admin.sh --server-name "Family Media"`
  (`'' → 'Family Media'`, HTTP 204); the public endpoint stops falling back to
  the container hostname.
- **Full library scan** — DONE: `POST /Library/Refresh` → 204 after the remux;
  the task returned to `Idle`.
- Sonarr: skipped by choice. FlareSolverr/Bazarr extras/Lidarr: P2/P3.

## Landmines that already cost time

1. **Never paste `<placeholder>` into bash** — `<` is a redirect. The helpers
   auto-detect ids; omit the argument.
2. **`/data` is not mounted on clawbox.** Every `ls`/`find` of the library must
   run inside `media-vm` over the deploy key.
3. **Do not downgrade a pin to make a client work.** Client and server must be
   on the same major (`jellyfin 12.4` ↔ `Jellyfin-12.z.wgt`); `PROJECT_MEMORY.md` §2a.
4. **qBittorrent's listen port is `37686`** and is owned by apply — never edit it
   in the UI.
5. **Never widen the remux verify** to make a title pass. Compare the film
   stream to itself; `format=duration` is not a runtime.
6. **Change protocol**: `bash -n` → guardrail `VERIFY_FAILS=0` →
   mutation-test each new assertion → `phase5_step1_install.sh` → apply → diag →
   update manual + memory + TODO + this file. Secrets are never echoed.

## Useful commands

| Purpose | Command |
| --- | --- |
| TV/video diagnosis | `sudo bash diagnose_tv_playback.sh` |
| Subtitle latency | `sudo bash diagnose_subtitles.sh` |
| Normalizer progress | `sudo bash check_normalize.sh` |
| Bazarr API/log | `sudo bash bazarr_status.sh --assign` (also `--search`, `--upgrade`) |
| "Do I have this title?" | `sudo bash library_status.sh "breakfast club"` (see `--fix-client-host` in manual 10j/j6) |
| Offline gate | `bash phase5_guardrail_test.sh` |

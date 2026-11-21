# TODO — SystemBuild

Backlog of record. The operator runbook stays `phase5_manual_steps.md`; this file
only tracks *what is left*, so nothing depends on a chat scrollback.

> **Handing this build to someone else (or to another AI agent)?** Read
> `PROJECT_MEMORY.md` **§2a "Version-pairing invariant"** first. If a TV/console
> app shows the library but fails every play request, check
> `jellyfin/<server pin>` against the client's compile line
> (`Dashboard → Devices`) *before* touching codecs, transcoding, discovery or
> firewall rules — that mismatch is silent in the server log.

Last updated: **2026-11-18**.

---

## P1 — media stack, first-run (open now)

Details: manual **Step 10** (10a–10i).

- [x] **Apply fix 58 — DONE 2026-11-18 16:31Z** (`apply VERIFY_FAILS=0`,
      `diag VERIFY_FAILS=0`): backup `jellyfin-backup-20261118T163106Z-pre-10.10.6.tar.gz`
      (14M), stepped `10.10.7 → 12.4`, V6 `12.4 image` + `12.4.0`, S5 `12.4.0`.
- [ ] **After the 12.4 upgrade (manual 10h):** run *Dashboard → Scheduled Tasks →
      **Scan Media Library*** (**mandatory** — 12.0 drops auto-resolved
      alternative versions), then press **Play on the TV**. Populate the 10e
      client table with the `.wgt` version once playback is confirmed.
      Scripted: `sudo bash jellyfin_admin.sh --scan` (manual 10j).
- [ ] **Rename the server** — `/System/Configuration` has `ServerName` **empty**
      (observed 2026-11-19), and the *public* endpoint then falls back to the
      machine hostname, which in a container is the id (`a45dba6c517e`) and
      changes on every recreate.
      `sudo bash jellyfin_admin.sh --server-name "Family Media"` (manual 10j),
      or *Dashboard → General → Server Name*.
- [ ] **Re-check Jellyseerr on 12.4:** sign in at `https://192.168.1.133:8443`,
      confirm the Jellyfin connection and one request still work.
- [ ] **Prowlarr → Radarr sync** (see below), qBt password, categories,
      end-to-end hardlink proof, family-facing items.

- [ ] **Finish Prowlarr → Radarr sync.** Last error: `Unable to complete
      application test, cannot connect to Radarr. Connection refused
      (localhost:7878)` → the *Radarr Server* field still holds the pre-filled
      default. Set Prowlarr Server `http://prowlarr:9696`, Radarr Server
      `http://radarr:7878`, Radarr API key, Sync Level `Full Sync` → Test → Save.
      Expect: `api/v1/applications` shows `"implementation":"Radarr"` +
      `"syncLevel":"fullSync"`, and Radarr's indexer count becomes `1` (YTS).
- [ ] **qBittorrent WebUI password** permanently set (10b), then the same
      credentials in Radarr's download client.
      **Scripted (fix 71, 2026-11-20):** `sudo bash qbt_admin.sh --set-password`
      — one atomic run (set + fresh-login proof + 600 root-only store + Radarr
      PUT + ban-clearing restart + `testall`). Needed because qBittorrent's
      temporary password is **regenerated on every container start**, so each
      apply re-created the "Authentication Failure" incident.
- [ ] **qBt category** `radarr` → `/data/torrents/movies` **and** the manual-mode
      path switch (10c).
      **Confirmed 2026-11-19:** the category exists but its `savePath` is
      **empty**, and Radarr already tags the torrent `cat=radarr` — so the name
      is right and the path falls back to the default `/data/torrents`.
      Looking under `torrents/movies/` therefore finds nothing and the 41 GiB
      looks like a leak. `createCategory` returns 409 for an existing name and
      does not change the path; the helper falls back to `editCategory`.
      Scripted: `sudo bash qbt_admin.sh --create-category radarr /data/torrents/movies`
      then `sudo bash qbt_admin.sh --set-radarr-category radarr` (manual 10j).
      **Done 2026-11-19:** category `savePath` = `/data/torrents/movies`
      (`createCategory` 409 → `editCategory` 200). Radarr's client field is
      **`movieCategory`**, not `category` — writing `category` returns HTTP 202
      and is silently ignored (verified against a schema-faithful mock).
      **Still open (fix 69, 2026-11-20):** the path is not used at all until
      `Session\UseCategoryPathsInManualMode` is on — Radarr's add is manual-mode
      (category only, no `savepath`/`autoTMM`), and the switch defaults off, so
      the torrent still landed in `/data/torrents`. Run
      `sudo bash qbt_admin.sh --fix-category-paths` (live, no restart) and
      confirm the next grab's `save_path`.
      **fix 70/72:** it was never applied — the key was written to a
      `qBittorrent.conf` **outside** the `qBittorrent/` subdirectory, which the
      app never reads (fix 72). `phase5_apply.sh` now writes it to
      `/data/config/qbittorrent/qBittorrent/qBittorrent.conf` while qBt is
      stopped and retires the ignored duplicate; `phase5_diag.sh` S3 fails if
      the key is absent/`false` or the duplicate exists. Gate: after an apply,
      `qbt_admin.sh --status` must show the real path and
      `on disk: UseCategoryPathsInManualMode=true`.
- [ ] **`Session\Interface=tun0` is now live on this VM too — verify it can't
      bite.** The fix-72 migration carried `Session\Interface(+Name)=tun0` from
      the retired duplicate into the real conf, so after the 11:1x restart the
      app-level bind is in effect (diag S3 now PASSes it). It is correct while
      gluetun's netns uses `tun0` for both OpenVPN and WireGuard, but a name
      change would leave qBittorrent bound to nothing (`--status` would show
      `disconnected`). Either pin it deliberately with a startup check that the
      interface exists in the netns, or drop it and rely on the netns alone
      (which is the actual boundary). Do not remove it while the client is mid
      download.
- [x] **Both titles imported (2026-11-20 10:33Z / later).** *The Breakfast Club*
      `hasFile True`, `downloadFolderImported 10:33Z`, Jellyfin sees it as 97 min;
      *Ferris Bueller's Day Off* at 100% and importing. Verdict **YES**.
- [ ] **Reclaim the pre-remux copies (do this — it is the last step of the flow).**
      `copyUsingHardlinks` was **already True**; the 41 G -> 61 G jump is the
      fix-59 remux replacing the library inode (its own log shows `remux:`/`done:`
      for both titles), so each title legitimately exists twice until its torrent
      is removed. Remove both completed torrents to return ~14.8 GiB, then
      `--status` should read ~46 G used / 43 G free:
      `qbt_admin.sh --remove-torrent "breakfast club" --yes` and the same for
      `ferris`. Worth a sentence in the report: the hardlink is what keeps the
      *remux peak* at 2 copies instead of 3.
- [ ] **Subtitle policy reversed (fix 78) — new titles keep their Spanish subs.**
      Owner decision 2026-11-20: embedded `spa`/`es`/`es-XX` subtitle tracks are
      KEPT (a possibly-Castilian track beats none); every other language is still
      dropped, and Bazarr's es-LA `.srt` stays the preferred file. The normalizer,
      its verify gate, diag S11, AGENTS.md Rule 2b, manual 10i and G21 were all
      re-pinned. **The three existing films stay at 0 embedded subtitles** (owner:
      do not redownload) — Bazarr covers them, which is exactly why the fix-77
      check matters. Next real import is the first proof the new rule runs.
- [x] **Reversed subtitle rule installed** (apply + diag `VERIFY_FAILS=0`,
      17:57Z) — `subs:2->0` in the log is now the *old* entries only; the next
      import is the first proof the normalizer keeps `spa`.
- [x] **All three films have a Spanish subtitle on disk** (2026-11-20 19:49Z):
      Ferris `.es-MX.srt` + `.es.srt`; Breakfast Club the same pair after
      `--search` (the first attempt wrote nothing — transient provider miss);
      Project Hail Mary `.es-MX.hi.srt` (row 3, cutoff satisfied).
- [x] **Jellyfin indexing verified — and it exposed a naming bug (fix 83).**
      `--subs` reports `.es.srt` as `spa Spanish`, `.es-MX.srt` as
      `? Indefinido`, and `.es-MX.hi.srt` as **`hin Hindi`**: Jellyfin resolves
      the rightmost filename token as a culture, and the HI repair only fires
      when the token to its left is a real culture (`es`, not `es-MX`).
- [x] **3-row profile applied** (`ea, es, es.hi`, cutoff on `es.hi`).
- [x] **PHM's LatAm-HI file removed** (Jellyfin read it as Hindi).
- [x] **PHM recompute (fix 84)** — `--rescan` now syncs, scans and recomputes.
- [x] **Root cause found (fix 85): Bazarr trusted Radarr's import-time language list.**
      Bazarr's `audio_language` came from `movieFile.languages`, which still
      named Spanish/French/German/... after the normalizer left one English
      track, and `audio_exclude=True` then dropped every Spanish row — so
      `missing_subtitles` was `[]` and the search job exited in 0.13 s.
      **Done 2026-11-21:** `--fix-audio-source` live (`parse_embedded_audio_track=True`),
      PHM's list rebuilt to `ea, es, es.hi`, and the search then downloaded one.
- [x] **PHM's subtitle is plain Castilian, mislabelled `.hi` (fix 86).** The
      text has 1 HI-regex hit in 2445 cues (the year in the title card), so
      Bazarr named it `.es.hi.srt` and Jellyfin showed *HI Spanish*.
      **Done 2026-11-21:** renamed to `.es.srt`, `--rescan 1`, `--scan`, `--subs`
      → `spa external Spanish`, no `HI`, no `hin`. All three films now carry a
      plain non-HI Spanish track.
- [ ] **`missing: ea, es.hi` is expected on all three films, not a fault.**
      The `es.hi` row is the last resort and the providers have no HI match for
      these releases; the `ea` row can never be matched at all
      (`Subliminal` filters on `language.basename`, `spl` vs `es-MX`, fix 86), so
      it stays missing until a Castilian search happens to return an MX-tagged
      file — which is how Ferris/Breakfast got theirs. Bazarr retries both every
      6 h harmlessly. **Do not delete the `ea` row** to silence it: it is what
      ranks a `.es-MX.srt` as *best*, and dropping rows risks the LatAm sidecar
      being treated as unwanted.
- [ ] **Re-install + diag to verify fix 79 live**: `phase5_step1_install.sh`
      then `phase5_diag.sh`; S11 must print audio/subs **and languages** for the
      newest file with no `audio=?`.
- [ ] **`check_normalize.sh` does not yet print subtitle languages.** It reports
      audio/subs counts, which under fix 78 can read `subs:2` without saying
      whether both are `spa` (diag S11 does check languages). Low priority; add
      if a title with mixed-language subs shows up.
- [ ] **Install the reversed rule into media-vm.** The scripts live in the repo
      and the *units* come from `phase5_apply.sh`; the normalizer binary itself is
      rewritten by an apply:
      `sudo bash phase5_step1_install.sh` then
      `sudo bash /usr/local/sbin/phase5/phase5_apply.sh` (VERIFY_FAILS=0), then
      `sudo bash /usr/local/sbin/phase5/phase5_diag.sh` (S11 now reports subtitle
      languages).
- [ ] **Confirm the normalizer handled both new titles.** The library file is
      still exactly the torrent's size (6.68 GiB) and its mtime is 11 min after
      the import, which is consistent with a remux that had nothing to drop (a
      release already carrying 1 audio + 0 subs is copied, not shrunk). That is
      a *guess* until `sudo bash check_normalize.sh` (now: newest file by
      default, with inode/link count) shows `audio 1 subs 0` **and** a
      `done:`/`remux:` line for each title in the log.
- [ ] **Let both titles finish, then prove the hardlink (2026-11-20 11:3xZ).**
      The stall diagnosis came back clean: `connection_status=connected`,
      ~1.3 MiB/s combined, 27 seeds, DHT 226 — the earlier `stalledDL` was swarm
      timing, not the stack, and the live `Session\Interface=tun0` pin is not
      hurting (this is the check that had to be made before trusting it).
      *The Breakfast Club* ~20 min, *Ferris Bueller's Day Off* ~2 h 20 min.
      **Both are in Radarr's queue again** (`downloading / downloading`), i.e. the
      credential repair let Radarr re-adopt them — so Radarr imports both by
      itself and `--import-downloads` is NOT needed (fix 75 makes it refuse while
      a download is tracked). After each import: the normalizer rewrites the file
      (new inode), then Jellyfin scan, then `library_status.sh <title>` = YES.
      Hardlink proof *before* the normalizer runs: same inode, `n=2`.
- [ ] **End-to-end request** + hardlink proof (`n=2`, same inode) (10d).
- [ ] **Family-facing** (10e): CA import, Jellyfin users, Jellyseerr user import
      + permissions (Request on / Auto-Approve off), Application URL
      `https://192.168.1.133:8443`, Jellyfin server name, TV + Music libraries.
- [ ] **§5 peer-health check** (`phase5_fix52_plan.md`): AirVPN test-open green
      on both rows, qBt `Connected` not `Firewalled`, established peers; record
      in `PROJECT_MEMORY.md`. Overdue since 2026-11-16.

## P2 — FlareSolverr (deferred by choice, apply-tracked)

Added 2026-11-18. **Why:** EZTV (and most other Cloudflare-fronted Prowlarr
definitions) fail with `blocked by CloudFlare Protection`. YTS works without it,
so nothing is currently blocked — this is coverage, not a fix.

- [ ] Add a pinned `flaresolverr` service to `phase5_compose.yaml`.
- [ ] **No published port**: Prowlarr reaches it as `http://flaresolverr:8191`
      over the compose network. (If a debug port is ever published it must bind
      `192.168.122.10:8191`, gain a `ufw` row and the `DOCKER-USER` inbound
      guard, and be added to the guardrail's port list — more moving parts for
      no benefit.)
- [ ] Image pinned to an explicit release tag (never `:latest`), recorded in the
      compose header's image-pin line and added as a 10th entry in guardrail
      **G2** (mutation-test: drop the pin → must fail).
- [ ] Compose / apply / diag / guardrail edited **together**; every `.sh` passes
      `bash -n`; guardrail `VERIFY_FAILS=0`; new assertions mutation-tested.
- [ ] Re-run apply (does not need the `vpn` profile — FlareSolverr is clearnet).
- [ ] Prowlarr side: *Settings → Indexers → Indexer Proxies → + → FlareSolverr*
      (`http://flaresolverr:8191`), then tag the EZTV definition with that proxy
      and re-Test.
- [ ] Docs: manual 10a.2 (drop the "stack does not run FlareSolverr" note),
      `PROJECT_MEMORY.md` fix entry.
- [ ] Not a `docker run` side-car: it would be invisible to the next apply and
      fail the canonical-copy discipline.

## P2 — library policy: TV-compatible releases (added 2026-11-18)

**Why:** the first imported film (`Project Hail Mary (2026) Remux-1080p.mkv`,
43 GB) carries **1 video + 11 audio + 36 SubRip subtitle tracks + cover art**.
It plays in the browser (server-side software transcode, ~1.9× realtime). The
Tizen app also failed on it, but the *cause* of that failure turned out to be a
**client/server version mismatch** (fix 58), not the file: the sideloaded client
is `Jellyfin for Tizen 0.1.0 … with Jellyfin-12.z` while the server was pinned
to `10.10.6`. The policy below is still worth doing — it keeps the household on
files that direct-play and stops a 43 GB remux from pinning a CPU core per
stream — but it is no longer the blocker.

- [ ] **Preferred shape for household media:** 1080p **H.264 High** + **AC3 5.1**
      (or AAC 5.1), **one** audio track, **at most two** subtitle tracks
      (English + English SDH). MP4 or MKV. That combination direct-plays on
      Tizen/webOS/Android TV, so no HLS/fMP4 transcode is involved at all.
- [ ] **Reject** in Radarr's quality profile: `Remux`, `Bluray-2160p`, and
      anything tagged multi-audio/multi-sub (`MULTi`, `DUAL`, 10+ languages).
      Prefer `WEBDL-1080p` / `Bluray-1080p` with a sane size cap.
- [x] **Proof test before re-adding this title (ran 2026-11-18):** cut a 2-minute
      clip and remuxed to MP4 (`make_playback_test.sh`: `-map 0:0 -map 0:2 -c copy -map_metadata -1`,
      H.264 + English AC3 5.1, faststart). **Result:** visible on both Mac and TV;
      **plays on Mac, fails with the same playback error on the Tizen TV**. This
      proves the blocker was **not** the 43 GB remux — see the fix-58 root cause
      below (client built for jellyfin-web 12.z, server pinned to 10.10.6).
      (Keep the library policy anyway for sane storage and transcode load.)
- [ ] **Subtitles: the 43 GB remux costs ~10 min on first use.** With
      `EnableSubtitleExtraction=true` (Jellyfin default, and correct), the first
      request for *any* embedded track makes ffmpeg demux the **whole** file and
      write an `.srt` into `/config/data/subtitles/`; the TV blocks on that
      request. Confirmed on the TV 2026-11-18 (playback OK, ~10 min for subs).
      Once a track is cached the same track is instant — but the 12.4 upgrade +
      library scan cold-started the cache, and each *different* track costs
      another full pass. Two cheap mitigations: (a) keep two external
      `Movie (2026).en.srt` / `Movie (2026).en.sdh.srt` files next to the media
      (served as plain text, no demux pass, survives rescans); (b) slim the file
      so fewer tracks exist to extract. The library policy above is the durable
      fix. Do **not** set `EnableSubtitleExtraction=false` — that forces burn-in
      transcodes.
- [x] **Slimming is now automatic (fix 59).** A `media-normalize` timer +
      path unit in `media-vm` rewrites every title to one original-language
      audio track (never TrueHD/Atmos — re-encoded to AC3 5.1) and zero
      embedded subtitles. **For the existing film:** the gate is
      `1.05 × size + 256 MiB` (~42.4 GiB) and `/data` has ~43.2 GiB, so it fits
      (~0.8 GiB spare) and will run on the next sweep. The first sweep refused
      it under the old 1.1× gate (1 GiB short). Pause with
      `sudo systemctl stop media-normalize.timer` if you want to pick the time.
      **Result size: ~32 GB, not ~12 GB** — the video stream is copied.
- [x] **Install + apply fix 61 (2026-11-18), then let the film remux once —
      DONE 2026-11-18 22:59Z.** `apply`/`diag VERIFY_FAILS=0`, then a manual
      `systemctl start media-normalize.service` produced
      `done: … (audio:1 subs:0 video:1 dur:9391s->9391s)` in 3 m 53 s and a
      **32 GB** file (was 41 GB) with `audio 1 / subtitle 0 / video 1`.
      The bug it replaced: the first live sweep logged
      `fail(verify … dur=9654->9391): kept original` on a **correct** remux —
      `format=duration` is the container's longest stream, and this title
      carries a `02:40:54` German dub plus an mjpeg cover-art still next to the
      `02:36:31` film. The same code mapped `0:v:0`, which would have written
      the cover art as the "movie" and still passed the `1 video` check.
- [x] **Reclaim the hardlinked original (~41 GiB) — DONE 2026-11-19.**
      Removed the film's torrent **with data** (`c517e636…`): `/data` went from
      72 G used / 13 G free to **32 G used / 53 G free (38%)**, and the library
      remux was left untouched (`nlink=1`, `check_normalize.sh` still reports
      audio 1 / subtitle 0 / video 1).
- [x] **Decide the es-LA policy for the existing film — DECIDED 2026-11-19.**
      `…es-MX.hi.srt` (117 KB, Latin American, hearing-impaired) is accepted
      because the profile now carries HI fallback rows; `missing` went from
      `['ea']` to `[]` once the cutoff included them (see the policy item).
- [x] **Bazarr pin bumped 1.5.1 -> 1.5.6 (fix 60)** — OpenSubtitles.com rejects
      any Bazarr below 1.5.4 with HTTP 426, so the provider was throttled on
      every search. Apply V6 + diag S4 now assert the running image.
      **Verified live 2026-11-18:** last 426 at `22:29:44` (old container),
      `22:41:50 Using opensubtitlescom again`, status `Good`, `.srt` written.
- [x] **Subtitle policy — APPLIED 2026-11-19T17:56Z (order corrected by the
      owner): LatAm first, Castilian second, then the two HI fallbacks**
      (manual 10j). `sudo bash bazarr_policy.sh --apply` wrote the four rows
      below and the read-back verified order + HI flags + cutoff item id 4;
      movie `radarrId 1` now reports `missing: []` with
      `…es-MX.hi.srt` under `have`.
      1. `Spanish (Latino)` (`ea`) non-HI — **preferred**
      2. `Spanish` (`es`) non-HI — Castilian
      3. `Spanish (Latino)` (`ea`) HI — accepted
      4. `Spanish` (`es`) HI — accepted (**`es-MX.hi` counts as row 3**; it
      never satisfied a non-HI item, which is why `missing=['ea']` persisted
      with the file on disk)
      Cutoff on row 4 so any of the four satisfies. **Follow-up (tested
      2026-11-19, fix 66):** `sudo bash bazarr_status.sh --upgrade` ran the
      *Upgrade Previously Downloaded Subtitles* task and it **did** search this
      film (job #33 completed, progress `Project Hail Mary`) — and left the
      file alone, because the task is **HI-preserving** (it searches with the
      subtitle's own hi flag, forced to `force HI` by the new HI rows) and needs
      `score + 2`. It cannot convert HI → non-HI. Only a *fresh* search
      (backup + delete `.srt` + `scan-disk` + `search-missing`) can try, with a
      real risk of ending at `missing` if no non-HI exists. HI is an accepted
      row, so the applied profile + this file is a valid end state.
- [x] **Configure Bazarr: languages enabled, Radarr wired** (manual 10i):
      `Spanish (Latino)` + `Spanish` enabled, profile `id=1`, providers
      `opensubtitlescom` + `subf2m` both `Good`, embedded subs stripped by the
      normalizer so every new title is a fresh fetch.
- [ ] **Radarr Custom Formats** (manual 10i): `-10000` for `TrueHD`/`Atmos`,
      `DTS-HD`/`DTS-X`, `Remux`, `MULTi`/`DUAL`; `+50` H.264, `+25` AC3. This
      stops paying for 11-audio remuxes in the first place. Allow only
      `WEBDL-1080p` / `Bluray-1080p` in the quality profile.
- [x] **Client side — ROOT CAUSE FOUND (fix 58, 2026-11-18):** the sideloaded
      build reports `Jellyfin for Tizen 0.1.0 compiled 2026/11/06 @ 00h56 with
      Jellyfin-12.z` (jellyfin-web 12.z) while the stack was pinned to server
      `10.10.6`. The library renders (API works) and **every** play request dies
      before `PlaybackInfo`. Upstream moved `10.11.x → 12.0 → 12.4`, and
      `jeppevinkel/jellyfin-tizen-builds` no longer ships `10.10.z`; the stack is
      now pinned to `jellyfin/jellyfin:12.4` with a stepped, backed-up DB
      migration in `phase5_apply.sh`. **Remaining check:** after the apply,
      confirm playback on the TV (and a full library scan, manual 10h). If it
      still fails, capture the wire with `diagnose_tv_playback.sh` before
      changing anything else — do **not** re-pin the server backwards.

## P3 — later / optional (no household impact)

- [ ] **Deployment topologies — a non-VM install is allowed (owner, 2026-11-20).**
      `media-vm` must stop being mandatory: a single host running the same
      Compose stack is acceptable **provided torrent traffic still cannot leave
      without the tunnel**. The VM is defence-in-depth (boundary, snapshots,
      deploy key); the security property is the netns + gluetun firewall.
      Acceptance for a flat install:
      - qBittorrent in gluetun's namespace — no `network_mode: host`, no second
        interface, no re-added default route;
      - gluetun firewall **on** (the kill switch); `FIREWALL_OUTBOUND_SUBNETS`
        names only LANs that truly need direct access;
      - kill-switch proof: with the tunnel down, `docker exec qbittorrent curl
        -s ifconfig.me` fails and the client still reports `tun0`;
      - host firewall backstop replaces the VM's ufw rules: `DOCKER-USER`
        egress guard for 6881–6889 + inbound source guard, admin UIs bound to
        loopback/private address and **never** `0.0.0.0`;
      - `phase5_diag.sh` S6 re-expressed as "admin ports are not on the LAN
        interface" (the `192.168.122.10` literals become placeholders);
      - no guest→RFC1918 pivot guard on a flat host, so container→LAN is denied
        by the host firewall except for the services that need it;
      - same `PUID/PGID`, one ext4 filesystem, normalizer units run on the host.
      Do not relax the kill switch, port bindings or guards to make it pass.
- [ ] **Sonarr** — skipped by choice; blocked on the Jellyseerr `fetch failed`
      (URL field, not the key — see manual 10f introspection snippet). Then:
      root folder `/data/media/tv`, download client `gluetun:8080` category
      `sonarr`, Prowlarr app entry, qBt category `/data/torrents/tv`.
- [ ] **Lidarr** — music, owner-only; nothing in the request flow uses it.
- [ ] **Jellyfin Connect hook** from Radarr (`jellyfin:8096`) — instant library
      update on import instead of the scheduled scan.
- [ ] Extra indexers for coverage (1337x is a dead domain — `1337x.to` NXDOMAIN;
      don't chase mirrors).

## Phase 6 — Hermes request notifications (spec of record; implement later)

Recorded 2026-11-18 at the owner's request. Scope: when a movie is **requested**,
the assistant must report three milestones — **found on qBittorrent**,
**download actually started** (not merely "torrent added"), and **ready** — to the
chat that made the request. Written now so the Phase 6 design does not depend on
a chat scrollback.

**State machine (one row per request, persisted in SQLite):**

```
requested ──found──▶ downloading ──imported──▶ preparing ──normalized──▶ ready
                 └─(no progress 10 min)─▶ stalled ──resumed──▶ downloading
```

| State | Detect with | Message |
| --- | --- | --- |
| `requested` | the request itself | "Buscando *<title> (<year>)*…" |
| `found` | Radarr `GET /api/v3/queue` (or history `grabbed`) gains the movie, **or** qBt `/api/v2/torrents/info` shows a hash whose name matches | "Encontrada en qBittorrent: *<release name>*" |
| `downloading` | **must be proven, not assumed:** sample qBt `progress` (or `downloaded`) at t0, +45 s, +90 s; require `Δ > 0` across two consecutive samples **and** `dlspeed > 0` | "Descarga iniciada — <pct>% (<size>)" |
| `stalled` | 10 min with `Δ == 0` or `dlspeed == 0` after the torrent exists | once only: "Descarga detenida/sin seeds — reintentando" |
| `preparing` | Radarr history `downloadFolderImported` (file present in `/data/media/movies`), but `media-normalize` has not logged `done:` for that path yet | "Descargada — optimizando para la TV" |
| `ready` | `media-normalize` log has `done: <path>` **or** 15 min elapsed since import (then say "lista (aún optimizando)") **plus** Bazarr status for es-LA | "Lista para ver: *<title>* — subtítulos es-LA: sí/pendiente" |

**Rules that matter more than the text:**

1. **Never send `downloading` on "torrent added" alone** — that is the stall case
   the owner explicitly flagged. Two advancing samples is the gate.
2. **Exactly one message per (request, state).** Persist `last_notified_state`;
   a restart must not replay notifications. No percentage spam.
3. **"Ready" means playable on the TV** — i.e. after normalization, not merely
   after import, otherwise the first play hits a 10-minute remux.
4. **Deliver to the requesting chat**, not the admin, unless the request came
   from the owner. One message per state per chat.
5. **Timeouts**: no `found` in 6 h → "sin resultados aún"; no `ready` in 48 h →
   one summary, then stop (no daily nagging).
6. **Subtitle status is part of "ready"** — Bazarr es-LA presence is the
   household's actual requirement.

**APIs/keys already available** (harvested into `/opt/media-assistant/.env` by
apply): `RADARR_URL` / `RADARR_API_KEY`, `BAZARR_URL` / `BAZARR_API_KEY`,
`QBITTORRENT_URL`. **Missing:** qBt WebUI credentials/API key for
`/api/v2/torrents/info` — add a `QBITTORRENT_USER`/`QBITTORRENT_PASS` pair (or a
qBt API key) to that same harvest when Phase 6 starts. Never echo values.

## Done (for context)

- [x] 2026-11-16 — fix 56 applied live; port `37686` + `Session\Port` + netns
      listener green; AirVPN forward open TCP+UDP.
- [x] 2026-11-16 — Jellyfin wizard claimed; Jellyseerr ↔ Jellyfin sign-in fixed.
- [x] 2026-11-17 — Jellyseerr ↔ Radarr wired (root folder, `HD-1080p`,
      `Released`).
- [x] 2026-11-18 — Prowlarr **YTS** indexer added and testing green.

## Change protocol (for any script-touching item above)

1. Edit the working copy in `/home/jordan/Documents/SystemBuild`.
2. `bash -n` on every modified `.sh`.
3. `bash phase5_guardrail_test.sh` → must print `VERIFY_FAILS=0`; mutate each new
   assertion to prove it can fail.
4. Install to `/usr/local/sbin/phase5/` (manual Step 1), then root apply, then
   `phase5_diag.sh` → `VERIFY_FAILS=0`.
5. Update `phase5_manual_steps.md` **and** `PROJECT_MEMORY.md` in the same
   change. Preserve V1–V10, S1–S10, G1–G19; additive changes carry a
   `# fix NN` comment.

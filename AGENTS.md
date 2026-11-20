# AGENTS.md — read this before debugging playback

This repository deploys the SystemBuild Phase 5 media stack (KVM `media-vm` +
Docker Compose: Jellyfin, Jellyseerr, Radarr, Sonarr, Prowlarr, Lidarr, Bazarr,
qBittorrent behind gluetun).

Full context lives in `PROJECT_MEMORY.md` (see **§2a — version-pairing
invariant**) and the runbook is `phase5_manual_steps.md` (Step 10). This file is
the short version for an agent picking the project up cold.

## Rule 0 — match the client and the server before anything else

If a smart-TV/console app **shows the library but fails every play request**,
the most likely cause is a **client/server major-version mismatch**, not codecs,
transcoding, HLS, discovery or firewall.

Verify all three, read-only, before changing anything:

```bash
# 1. version the server advertises (e.g. 12.4.x)
curl -s http://192.168.122.10:8096/System/Info/Public | grep -o '"Version":"[^"]*"'

# 2. image actually running
ssh -i /etc/media-vm/deploy_ed25519 -o IdentitiesOnly=yes \
    -o UserKnownHostsFile=/etc/media-vm/known_hosts jordan@192.168.122.10 \
    "sudo docker inspect -f '{{.Config.Image}}' jellyfin"

# 3. compile line of the client the server has seen
ssh -i /etc/media-vm/deploy_ed25519 -o IdentitiesOnly=yes \
    -o UserKnownHostsFile=/etc/media-vm/known_hosts jordan@192.168.122.10 \
    'sudo cp /data/config/jellyfin/data/jellyfin.db* /tmp/ 2>/dev/null; sudo python3 -c "
import sqlite3;c=sqlite3.connect(\"/tmp/jellyfin.db\")
print(list(c.execute(\"select AppName,AppVersion,DeviceName from Devices\")))"'
```

Pin of record: **`jellyfin/jellyfin:12.4`** ↔ **`Jellyfin-12.z.wgt`**
(jeppevinkel builds, jellyfin-web 12.z). A `10.10.z` client or a `10.10.x`
server against the other is the known-bad pairing.

Why it is invisible: the REST API used for posters/*Recently Added* is stable
across majors, so the UI renders. The playback contract is not, so the request
dies **before `PlaybackInfo`** and nothing appears in `log_YYYYMMDD.log` at
`[INF]`. Do not conclude "the server is fine, so it is the file".

## Rule 1 — the 12.x database migration is one-way

- Never downgrade the pin to make a client work; move the server forward.
- `phase5_apply.sh` already tars `/data/config/jellyfin` (fail-closed on space)
  and steps `10.10.x → 10.10.7 → 12.4` through throwaway containers. Re-run it;
  do not hand-edit the image tag.
- Keep `/data/config/jellyfin-backup-*.tar.gz` until a title plays on the TV.

## Rule 2 — a full library scan is mandatory after a 12.x upgrade

*Dashboard → Scheduled Tasks → “Scan Media Library” → ▶*. The type change drops
auto-resolved alternative versions and some titles reappear as *newly added*.
Manual **Step 10h** has the details.

## Rule 2b — library files are rewritten on purpose (fix 59, amended by fix 78)

A **`media-normalize`** unit pair inside `media-vm` rewrites every title once so
it matches the household policy: **exactly one audio track** (the best
non-commentary track in the film's original language, and never TrueHD/Atmos/
DTS-HD — those are re-encoded to AC3 5.1), and **only the Spanish subtitle
tracks** — every other subtitle language is dropped. Bazarr additionally
supplies **Latin American Spanish** as an external `.srt`, which Jellyfin
prefers.

**Spanish subs are kept, not stripped (owner decision 2026-11-20, fix 78).**
An MKV tags subtitles `spa` and cannot distinguish es-ES from es-419, so an
embedded track may be Castilian. The owner's ruling: a Spanish track that is
present is worth keeping; the external es-LA `.srt` is the preferred one, not
the only one. So:

- `subs: 2` in the log is now a **normal, correct** result when both are `spa`;
- a **non-Spanish** subtitle in a library file means the policy was not applied
  (diag S11 fails on it);
- older files made under the old rule legitimately have **0 subtitles** —
  *The Breakfast Club*, *Ferris Bueller's Day Off* and *Project Hail Mary* are
  in that state on purpose. **Do not re-download or re-remux them** to add
  subtitles; Bazarr covers them with the external file.

That means a 43 GB remux becoming a **~32 GB** single-audio MKV is **expected**
(the video stream is copied byte-for-byte — only the extra audio and non-Spanish
subtitle tracks are dropped; the saving is whatever those tracks cost, not the
dubbing "quality"). Check state with:

```bash
ssh -i /etc/media-vm/deploy_ed25519 -o IdentitiesOnly=yes \
    -o UserKnownHostsFile=/etc/media-vm/known_hosts jordan@192.168.122.10 \
    'systemctl is-active media-normalize.timer media-normalize.path; \
     sudo tail -n 20 /var/log/media-normalize.log'
```

It is serialized (`flock`), waits 120 s for a file to stop changing, verifies
the output (1 audio / 0 subs / 1 video / the **film stream's own** duration
±5 s) **before** the atomic rename, and keeps the original on any failure —
including low disk space (`skip(space)`). ffmpeg is the already-pinned Jellyfin
image; no extra container.

**fix 61 — trust the stream, not the container.** A remux lies about its own
shape in two ways that both bit this system on 2026-11-18:

- its **container duration is the longest contained stream**, so a 02:40:54
  German dub (and an mjpeg cover-art still) made a correct 02:36:31 remux look
  263 s truncated — the verify rejected it and the timer retried every 10
  minutes forever. Duration is therefore compared between the source's and the
  output's **primary video stream**, never `format=duration`;
- its **first video stream may be cover art** (mjpeg/png). `-map 0:v:0` would
  have written the still as the "movie" and still passed a 1-video count check.
  The film is the largest non-cover-art video stream, mapped by absolute index.

If a film's runtime cannot be probed, it is **skipped** (`skip(no duration)`)
rather than remuxed blind.

## Rule 3 — change protocol for this repo

Any edit to `phase5_compose.yaml`, `phase5_apply.sh`, `phase5_diag.sh` or
`phase5_guardrail_test.sh` must satisfy, in this order:

1. `bash -n` on every `.sh` (including the heredoc bodies embedded in apply);
2. `bash phase5_guardrail_test.sh` → `VERIFY_FAILS=0`;
3. **mutation-test every new assertion** (break it deliberately, confirm it
   fails, restore, verify the hash);
4. `sudo bash phase5_step1_install.sh` (installs the canonical root-owned copies
   under `/usr/local/sbin/phase5/`);
5. `sudo bash /usr/local/sbin/phase5/phase5_apply.sh` → `VERIFY_FAILS=0`;
6. `sudo bash /usr/local/sbin/phase5/phase5_diag.sh` → `VERIFY_FAILS=0`;
7. update `phase5_manual_steps.md` **and** `PROJECT_MEMORY.md` / `TODO.md` in the
   same change.

Never loosen a security check to make something pass, never publish a port
outside `192.168.122.10` (LAN exposure is Jellyfin `:8096`, discovery
`:7359/udp`, Jellyseerr via Caddy `:8443`), and never echo secret values
(`vpn.env`, API keys, `.env`).

## Known-benign noise

`virsh net-start default` → "network is already active"; stale `ufw` DENY rows
for the old `51413`; one `caddy.service` error line per boot;
`"EndpointAddress": null` in the discovery JSON; `WebRootPath /wwwroot` warning;
`ServerName` showing a container ID until it is renamed in *Dashboard → General*.

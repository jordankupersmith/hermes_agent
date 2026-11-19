#!/usr/bin/env bash
#
# Creates a 2-minute, direct-play-friendly test item inside the Jellyfin library.
# Run as root on clawbox:   bash make_playback_test.sh
#
# Why: the first imported film is a 43 GB remux with 11 audio tracks and 36
# subtitle tracks. Playing it forces a transcode (fMP4 HLS) before the first
# frame, which is what the Samsung Tizen app chokes on. This clip is
# H.264 video + one AC3 5.1 track in MP4 with faststart, so it needs NO
# transcode at all. If the TV plays it, the client/network/session are fine and
# the problem is the transcode path (see TODO.md P2 "library policy").
#
# Nothing here touches the stack: no compose change, no ports, no secrets.

set -uo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "must run as root (the VM deploy key is root-only): sudo bash $0" >&2
    exit 1
fi

K=(-i /etc/media-vm/deploy_ed25519 -o IdentitiesOnly=yes -o UserKnownHostsFile=/etc/media-vm/known_hosts)
VM=jordan@192.168.122.10
SRC="/data/media/movies/Project Hail Mary (2026)/Project Hail Mary (2026) Remux-1080p.mkv"
DIR="/data/media/movies/Playback Test (2026)"
DST="$DIR/Playback Test (2026).mp4"

echo "[1/3] creating $DIR"
ssh "${K[@]}" "$VM" "sudo install -d -m 755 -o 1001 -g 1001 \"$DIR\"" || exit 1

echo "[2/3] cutting 120s clip (stream copy: H.264 video + English AC3 5.1)"
ssh "${K[@]}" "$VM" "sudo docker exec jellyfin /usr/lib/jellyfin-ffmpeg/ffmpeg -hide_banner -v error \
    -ss 300 -i \"$SRC\" -t 120 -map 0:0 -map 0:2 -c copy \
    -map_metadata -1 -metadata title='Playback Test' -movflags +faststart \"$DST\"" || exit 1
ssh "${K[@]}" "$VM" "sudo chown 1001:1001 \"$DST\" && ls -l \"$DST\"" || exit 1

echo "[3/3] waiting 25s for the real-time library monitor, then checking the item DB"
sleep 25
ssh "${K[@]}" "$VM" 'sudo bash -s' <<'REMOTE'
rm -rf /tmp/dbchk && mkdir -p /tmp/dbchk
cp /data/config/jellyfin/data/library.db* /tmp/dbchk/ 2>/dev/null || true
chmod -R a+r /tmp/dbchk
python3 - <<'PY'
import sqlite3
c = sqlite3.connect('/tmp/dbchk/library.db')
rows = list(c.execute("select Name,Path from TypedBaseItems where Path like '%Playback Test%'"))
print("item rows:", len(rows))
for n, p in rows:
    print("  NAME:", repr(n))
PY
REMOTE

cat <<'MSG'

Now, in Jellyfin (web UI on the Mac):
  1. Dashboard -> Libraries -> Movies -> ... -> Scan library
  2. wait ~20s, hard-refresh (Cmd-Shift-R)
  3. the Movies grid should show a tile called "Playback Test" (generic poster)

Then play "Playback Test" on the Tizen TV:
  - plays  -> the app/session/network are fine; only the transcode path fails
              for the 43 GB remux (TODO.md P2 "library policy" is the fix)
  - fails   -> the sideloaded Tizen build is the problem, not the media
MSG

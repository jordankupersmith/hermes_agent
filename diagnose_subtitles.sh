#!/usr/bin/env bash
#
# Why did subtitles take ~10 minutes on the TV? Read-only.
# Checks the subtitle extraction cache, the SubtitleEncoder timings in the log,
# the encoding settings, and how many subtitle streams the film carries.
#
# Run as root on clawbox:   bash diagnose_subtitles.sh

set -uo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "must run as root: sudo bash $0" >&2
    exit 1
fi

K=(-i /etc/media-vm/deploy_ed25519 -o IdentitiesOnly=yes -o UserKnownHostsFile=/etc/media-vm/known_hosts)
VM=jordan@192.168.122.10

ssh "${K[@]}" "$VM" 'sudo bash -s' <<'EOS'
echo "== subtitle cache size =="
sudo docker exec jellyfin sh -c '
  n=$(find /config/data/subtitles -type f 2>/dev/null | wc -l)
  s=$(du -sh /config/data/subtitles 2>/dev/null | cut -f1)
  echo "  files: $n   total: ${s:-0}"'

echo "== newest cache entries (mtime, bytes, name) =="
sudo docker exec jellyfin sh -c '
  find /config/data/subtitles -type f -printf "%TY-%Tm-%Td %TH:%TM %10s %p\n" 2>/dev/null | sort | tail -5'

echo "== SubtitleEncoder activity (extraction is what blocks the client) =="
sudo docker exec jellyfin sh -c '
  grep -h "SubtitleEncoder" /config/log/log_*.log 2>/dev/null | tail -12'

echo "== encoding.xml: subtitle / throttling =="
sudo docker exec jellyfin sh -c '
  grep -E "EnableSubtitleExtraction|EnableThrottling|ThrottleDelaySeconds|SegmentDeletion" /config/config/encoding.xml'

echo "== subtitle streams in the film =="
sudo docker exec jellyfin /usr/lib/jellyfin-ffmpeg/ffprobe -v error -select_streams s \
  -show_entries stream=index:stream_tags=language,title -of csv=p=0 \
  "/data/media/movies/Project Hail Mary (2026)/Project Hail Mary (2026) Remux-1080p.mkv" 2>/dev/null | wc -l

echo "== external subtitle files next to the media =="
sudo docker exec jellyfin sh -c '
  find /data/media -maxdepth 3 -type f \( -name "*.srt" -o -name "*.ass" -o -name "*.vtt" \) 2>/dev/null | head -5
  echo "(count: $(find /data/media -maxdepth 3 -type f \( -name "*.srt" -o -name "*.ass" -o -name "*.vtt" \) 2>/dev/null | wc -l))"'
EOS

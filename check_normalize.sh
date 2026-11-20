#!/usr/bin/env bash
#
# Watch the fix-59 normalization of the library (read-only).
#   bash check_normalize.sh                       # newest library file
#   bash check_normalize.sh "/data/media/movies/.../x.mkv"
#   watch -n 30 bash check_normalize.sh
#
# Also answers the two questions that come up after an import (fix 76):
#   * is this file still the un-normalized original?  (audio=1 subs=0 is the target)
#   * is it a HARDLINK of the torrent copy, or a second full copy?
#
# Run as root on clawbox (the deploy key is root-only).

set -uo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "must run as root: sudo bash $0" >&2
    exit 1
fi

K=(-i /etc/media-vm/deploy_ed25519 -o IdentitiesOnly=yes -o UserKnownHostsFile=/etc/media-vm/known_hosts)
VM=jordan@192.168.122.10
# Optional: a specific file. Empty = newest .mkv under /data/media/movies, which
# is what you want right after an import (the old hardcoded Project Hail Mary
# path stopped being the newest title as soon as two more were imported).
FILM="${1:-}"

ssh "${K[@]}" "$VM" "sudo FILM='$FILM' bash -s" <<'EOS'
FILM="${FILM:-$(find /data/media/movies -maxdepth 2 -type f -name '*.mkv' \
        -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)}"
echo "== units =="
printf '  timer: %s   path: %s\n' \
    "$(systemctl is-active media-normalize.timer)" \
    "$(systemctl is-active media-normalize.path)"
echo "== /data space =="
df -h /data | awk 'NR==2{printf "  used %s of %s — free %s (%s)\n", $3, $2, $4, $5}'
echo "== in-flight remux temp (grows to ~the video size) =="
find /data/media -maxdepth 3 -name '.*.norm.*' -printf '  %10s bytes  %TH:%TM  %p\n' 2>/dev/null || true
echo "  (none = no remux running right now)"
echo "== normalizer log (last 12) =="
sudo tail -n 12 /var/log/media-normalize.log 2>/dev/null | sed 's/^/  /'
echo "== the file =="
if [ -z "$FILM" ] || [ ! -f "$FILM" ]; then
    echo "  no .mkv found under /data/media/movies (nothing imported yet?)"
    exit 0
fi
printf '  %s\n' "$FILM"
for pair in a:audio s:subtitle v:video; do
    k="${pair%%:*}"; label="${pair##*:}"
    n=$(sudo docker run --rm --entrypoint /usr/lib/jellyfin-ffmpeg/ffprobe \
          -v "$FILM":"$FILM":ro jellyfin/jellyfin:12.4 \
          -v error -select_streams "$k" -show_entries stream=index -of csv=p=0 \
          "$FILM" 2>/dev/null | grep -c .)
    printf '  %-8s %s\n' "$label" "$n"
done
printf '  size     %s\n' "$(du -h "$FILM" | awk '{print $1}')"

echo "== hardlink status (fix 76) =="
INODE="$(stat -c '%i' "$FILM")"
LINKS="$(stat -c '%h' "$FILM")"
printf '  inode %s  links %s\n' "$INODE" "$LINKS"
OTHER="$(find /data/torrents -xdev -type f -inum "$INODE" -print 2>/dev/null | head -3)"
if [ -n "$OTHER" ]; then
    printf '  same inode also at:\n'
    printf '%s\n' "$OTHER" | sed 's/^/    /'
    echo "  -> the library file and the torrent share ONE extent: removing the"
    echo "     torrent returns no space (the library holds the inode)"
elif [ "$LINKS" -gt 1 ]; then
    echo "  -> n=$LINKS, but no counterpart under /data/torrents: another copy exists"
else
    echo "  -> n=1 and no torrent counterpart. Either the import COPIED, or the"
    echo "     remux already replaced the inode (expected after a fix-59 remux)."
    echo "     'remux'/'done' in the log above means the latter."
fi

SIZE=$(stat -c '%s' "$FILM")
TOTAL=$(find /data/torrents -xdev -type f -size "${SIZE}c" -print 2>/dev/null | wc -l)
echo "  files in /data/torrents with this exact size: $TOTAL"
echo "  (a matching size is a COPY when the inode differs — check"
echo "   Radarr's copyUsingHardlinks via: sudo bash library_status.sh \"x\")"
EOS

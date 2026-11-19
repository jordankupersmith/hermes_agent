#!/usr/bin/env bash
#
# Watch the fix-59 normalization of the library (read-only).
#   bash check_normalize.sh          # one snapshot
#   watch -n 30 bash check_normalize.sh
#
# Run as root on clawbox (the deploy key is root-only).

set -uo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "must run as root: sudo bash $0" >&2
    exit 1
fi

K=(-i /etc/media-vm/deploy_ed25519 -o IdentitiesOnly=yes -o UserKnownHostsFile=/etc/media-vm/known_hosts)
VM=jordan@192.168.122.10
FILM="/data/media/movies/Project Hail Mary (2026)/Project Hail Mary (2026) Remux-1080p.mkv"

ssh "${K[@]}" "$VM" "sudo FILM='$FILM' bash -s" <<'EOS'
echo "== units =="
printf '  timer: %s   path: %s\n' \
    "$(systemctl is-active media-normalize.timer)" \
    "$(systemctl is-active media-normalize.path)"
echo "== /data space =="
df -h /data | awk 'NR==2{printf "  used %s of %s — free %s (%s)\n", $3, $2, $4, $5}'
echo "== in-flight remux temp (grows to ~the video size) =="
find /data/media -maxdepth 3 -name '.*.norm.*' -printf '  %10s bytes  %TH:%TM  %p\n' 2>/dev/null || true
echo "  (none = no remux running right now)"
echo "== normalizer log (last 8) =="
sudo tail -n 8 /var/log/media-normalize.log 2>/dev/null | sed 's/^/  /'
echo "== the film, live stream shape (target: audio=1 subs=0) =="
if [ -f "$FILM" ]; then
    for pair in a:audio s:subtitle v:video; do
        k="${pair%%:*}"; label="${pair##*:}"
        n=$(sudo docker run --rm --entrypoint /usr/lib/jellyfin-ffmpeg/ffprobe \
              -v "$FILM":"$FILM":ro jellyfin/jellyfin:12.4 \
              -v error -select_streams "$k" -show_entries stream=index -of csv=p=0 \
              "$FILM" 2>/dev/null | grep -c .)
        printf '  %-8s %s\n' "$label" "$n"
    done
    printf '  size     %s\n' "$(du -h "$FILM" | awk '{print $1}')"
else
    echo "  film not found at that path (renamed?)"
fi
EOS

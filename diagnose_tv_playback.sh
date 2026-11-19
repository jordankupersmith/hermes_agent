#!/usr/bin/env bash
#
# Captures exact HTTP request methods/paths and HTTP response status codes on :8096
# for 25 seconds while you press Play on the TV (tokens redacted).
#
# Run as root on clawbox:   bash diagnose_tv_playback.sh

set -uo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "must run as root: sudo bash $0" >&2
    exit 1
fi

echo ">>> PRESS PLAY ON THE TV NOW (capturing HTTP requests & status codes on :8096 for 25s) <<<"
timeout 25 tcpdump -l -i virbr0 -nn -A -s 1024 'tcp port 8096 and (((ip[2:2] - ((ip[0]&0xf)<<2)) - ((tcp[12]&0xf0)>>2)) != 0)' 2>/dev/null \
  | grep --line-buffered -oE '(GET|POST|DELETE|HEAD) [^[:space:]]+ HTTP/1\.[01]|HTTP/1\.[01] [0-9]{3} [^\r\n]+|[Uu]ser-[Aa]gent: [^\r\n]+' \
  | sed -u -E 's/(api_key|ApiKey|Token)=[^&" \r]+/\1=<redacted>/gi' || true
echo "=== capture complete ==="

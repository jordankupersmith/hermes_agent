#!/usr/bin/env bash
#
# Read-only: how does THIS Bazarr build store language profiles, and what is the
# exact es-LA language code it expects? Prints no secrets (API key never echoed).
#
# Run as root on clawbox:   sudo bash inspect_bazarr.sh

set -uo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "must run as root: sudo bash $0" >&2
    exit 1
fi

K=(-i /etc/media-vm/deploy_ed25519 -o IdentitiesOnly=yes -o UserKnownHostsFile=/etc/media-vm/known_hosts)
VM=jordan@192.168.122.10

echo "== bazarr version =="
ssh "${K[@]}" "$VM" "sudo docker exec bazarr sh -c 'cat /app/bazarr/version.txt 2>/dev/null; cat /config/config/config.yaml 2>/dev/null | head -1'" 2>/dev/null | sed 's/^/  /'

echo "== config.yaml: profile-ish keys =="
ssh "${K[@]}" "$VM" "sudo docker exec bazarr sh -c 'grep -n \"profile\\|languages\" /config/config/config.yaml 2>/dev/null | head -24'" 2>/dev/null | sed 's/^/  /'

echo "== config.yaml: the language_profiles block, if present =="
ssh "${K[@]}" "$VM" "sudo docker exec bazarr sh -c 'awk \"/language_profiles:/{f=1} f{print; if (++n>70) exit}\" /config/config/config.yaml 2>/dev/null'" 2>/dev/null | sed 's/^/  /'

echo "== API: profile routes exposed by this build =="
KEY="$(grep -m1 '^BAZARR_API_KEY=' /opt/media-assistant/.env 2>/dev/null | cut -d= -f2-)"
if [ -z "${KEY:-}" ]; then
    echo "  (no BAZARR_API_KEY in /opt/media-assistant/.env — skipping API probe)"
else
    curl -s -m 6 -H "X-API-KEY: $KEY" http://192.168.122.10:6767/api/swagger.json 2>/dev/null \
        | tr ',' '\n' | grep -oE '"/api/[a-z/_{}]*[a-z]' | grep -iE 'language|profile' | sort -u | sed 's/^/  /' || true
    echo "  -- existing profiles --"
    curl -s -m 6 -H "X-API-KEY: $KEY" http://192.168.122.10:6767/api/languages/profiles 2>/dev/null \
        | head -c 1500 | sed 's/^/  /'
    echo
fi

echo "== API: language codes it knows for Spanish =="
if [ -n "${KEY:-}" ]; then
    for EP in /api/system/languages /api/languages; do
        OUT="$(curl -s -m 6 -H "X-API-KEY: $KEY" "http://192.168.122.10:6767$EP" 2>/dev/null)"
        if [ -n "$OUT" ] && printf '%s' "$OUT" | grep -qi 'spanish'; then
            echo "  ($EP)"
            printf '%s' "$OUT" | tr '}' '\n' | grep -i 'spanish' | head -8 | sed 's/^/  /'
            break
        fi
    done
fi

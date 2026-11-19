# Phase 5 — Fix 52/53 Remediation & Step 8 Implementation Plan

Date: 2026-11-15  
Host: `clawbox` (`192.168.1.133/24` on `eno1`) · Guest: `media-vm` (`192.168.122.10`, Debian 13)  
Target files:
- `/home/jordan/Documents/SystemBuild/phase5_apply.sh`
- `/home/jordan/Documents/SystemBuild/phase5_compose.yaml`
- `/home/jordan/Documents/SystemBuild/phase5_diag.sh`
- `/home/jordan/Documents/SystemBuild/phase5_guardrail_test.sh`
- `/home/jordan/Documents/SystemBuild/phase5_manual_steps.md`
- `/home/jordan/Documents/SystemBuild/PROJECT_MEMORY.md`

---

## 0. Context & Invariants (Must Not Regress)

1. **Root-only execution:** `phase5_apply.sh` runs as `root` on `clawbox` (no `sudo` on host; `sudo` exists only inside `media-vm`). Canonical installed copies live in `/usr/local/sbin/phase5/` (`root:root`, scripts `0755`, compose `0644`), mirrored via `phase5_step1_install.sh`.
2. **Never echo secrets:** Never print values from `/etc/media-vm/vpn.env`, `/opt/media-stack/vpn.env`, or `/opt/media-assistant/.env`. Only log variable names and line counts.
3. **Preserve all V1–V10, S1–S10, and G1–G16 (fixes 1–51):** Every change is additive, labeled `# fix 52` (and `# fix 53` if split), every `if ... then` has a non-empty body, and every `.sh` file must pass `bash -n` (no `shellcheck` installed).
4. **Approved Step 8 choices:**
   - **Sonarr:** Yes (`192.168.122.10:8989`, VM-only)
   - **Key harvest:** Yes (`SONARR_URL` + `SONARR_API_KEY` added to `/opt/media-assistant/.env`, bringing total from 10 to 12 keys; Jellyseerr not harvested)
   - **Family UI:** Jellyseerr (`192.168.122.10:5055`, VM-only) exposed on the host via **Option A2** (host Caddy on `192.168.1.133:8443`, `tls internal`, CA name `Family Media CA`, `ufw` restricted to `192.168.1.0/24` on `eno1`)
   - **VPN:** AirVPN WireGuard (`SERVER_COUNTRIES=Switzerland`, `SERVER_NAMES=Achernar`, `WIREGUARD_MTU=1280`) with static port forwarding (port `>= 2048`, e.g., `51413` or the exact port assigned in the AirVPN Client Area).

---

## Part 1 — Immediate Live Recovery (Run as `root` on `clawbox`)

### Root Cause of the `gluetun` Restart Loop
1. **IPv6 interface address in `WIREGUARD_ADDRESSES`:** AirVPN configs include `10.x.x.x/32, fd7d:.../128`. Because IPv6 is disabled in `media-vm`, `gluetun` exits `1` with:
   `ERROR VPN settings: Wireguard settings: interface address is IPv6 but IPv6 is not supported`
2. **Divergence guard blocked host -> VM sync:** Even after stripping `, fd7d:.../128` from `/etc/media-vm/vpn.env` on the host, `phase5_apply.sh` lines 980–985 saw that `media-vm:/opt/media-stack/vpn.env` already contained `VPN_SERVICE_PROVIDER=...` with a different SHA-256 and skipped overwriting it.
3. **Compose `env_file` recreate:** Debian's `docker compose` v2.26.1 does not reliably recreate running/restarting containers when only an `env_file` changes unless `--force-recreate` is passed.

### Commands to Run as `root` Now
```bash
# 1. Strip any IPv6 suffix (comma/colon) and surrounding quotes in host /etc/media-vm/vpn.env
sed -i -E 's/^(WIREGUARD_(PRIVATE|PRESHARED)_KEY=)"(.*)"[[:space:]]*$/\1\3/' /etc/media-vm/vpn.env
sed -i -E 's/^(WIREGUARD_ADDRESSES=[^,]*),.*/\1/' /etc/media-vm/vpn.env
sed -i -E 's/^([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*/\1=/' /etc/media-vm/vpn.env

# Verify: must print 0, and both key lengths must be 44
grep -c '^WIREGUARD_ADDRESSES=.*[,:]' /etc/media-vm/vpn.env
awk -F= '/^WIREGUARD_PRIVATE_KEY=/{print "private_key_len=" length($2)} /^WIREGUARD_PRESHARED_KEY=/{print "psk_len=" length($2)}' /etc/media-vm/vpn.env

# 2. Atomically stage and replace /opt/media-stack/vpn.env inside media-vm (mode 600, root:root)
ssh -i /etc/media-vm/deploy_ed25519 -o IdentitiesOnly=yes \
  -o UserKnownHostsFile=/etc/media-vm/known_hosts jordan@192.168.122.10 \
  'sudo sh -c "umask 077; cat >/root/.p5-stage.tmp; chown root:root /root/.p5-stage.tmp; chmod 600 /root/.p5-stage.tmp; mv -f /root/.p5-stage.tmp /opt/media-stack/vpn.env"' \
  < /etc/media-vm/vpn.env

# 3. Verify hashes match and VM copy has 0 IPv6 addresses
sha256sum /etc/media-vm/vpn.env
ssh -i /etc/media-vm/deploy_ed25519 -o IdentitiesOnly=yes \
  -o UserKnownHostsFile=/etc/media-vm/known_hosts jordan@192.168.122.10 \
  'sudo sha256sum /opt/media-stack/vpn.env; sudo grep -c "^WIREGUARD_ADDRESSES=.*[,:]" /opt/media-stack/vpn.env'

# 4. Force-recreate gluetun + qbittorrent
ssh -i /etc/media-vm/deploy_ed25519 -o IdentitiesOnly=yes \
  -o UserKnownHostsFile=/etc/media-vm/known_hosts jordan@192.168.122.10 \
  'sudo sh -c "cd /opt/media-stack && docker compose --profile vpn up -d --force-recreate gluetun qbittorrent"'

# 5. Wait ~15s and verify gluetun is Up (healthy) with a Swiss AirVPN IP
sleep 15
ssh -i /etc/media-vm/deploy_ed25519 -o IdentitiesOnly=yes \
  -o UserKnownHostsFile=/etc/media-vm/known_hosts jordan@192.168.122.10 \
  'sudo docker ps --format "{{.Names}}\t{{.Status}}"; sudo docker exec gluetun cat /tmp/gluetun/ip; echo'

# 6. Run live smoke diagnostics (expect VERIFY_FAILS=0)
bash /usr/local/sbin/phase5/phase5_diag.sh
```

---

## Part 2 — `gluetun` / `vpn.env` & Healthcheck Fixes (`# fix 52`)

### 2a. Pre-push `vpn.env` WireGuard validation (`phase5_apply.sh` + `phase5_diag.sh`)
In `env_lint()` (both `phase5_apply.sh` and `phase5_diag.sh`), add two non-echoing checks on `value`:
- If `var == "WIREGUARD_ADDRESSES"` and `[[ "$value" =~ [,:] ]]`, append flag `[IPV6-OR-MULTI-ADDR-UNSUPPORTED]`.
- If `[[ "$value" =~ ^\".*\"$ || "$value" =~ ^\'.*\'$ ]]`, append flag `[QUOTED-VALUE]`.

### 2b. Authoritative host `vpn.env` sync + `--force-recreate` on change (`phase5_apply.sh`)
Replace the divergence block at lines 977–991 of `phase5_apply.sh`:
- Track `VPN_ENV_CHANGED=0`.
- When `VM_VPN_SHA != HOST_VPN_SHA`:
  1. If `/etc/media-vm/vpn.env` holds real credentials (`grep -qE '^VPN_SERVICE_PROVIDER=[^[:space:]#]+' "$VPN_ENV_HOST"`):
     - Run `env_lint "$VPN_ENV_HOST" >/dev/null 2>&1`.
     - If clean: push host `vpn.env` to `$VPN_ENV_VM` (`600`) via `vm_put`, log `[pushed] vpn.env -> media-vm:$VPN_ENV_VM (600 — host real credentials synced; values NEVER echoed)`, and set `VPN_ENV_CHANGED=1`.
     - If `env_lint` fails: warn and do **not** push invalid syntax into the VM.
  2. Else (host `vpn.env` is comment-only skeleton) **and** the VM copy already has real credentials:
     - Keep the protective warning (`[warn] in-VM vpn.env holds real values while host is skeleton — left untouched`) so a reset host file never wipes working VM credentials.
  3. Else (both are skeleton, or VM copy is absent):
     - Push via `vm_put`.
- In APPLY 5/7 step F (`docker compose $COMPOSE_UP`, line 1125):
  - When `REAL_CREDS=1` and `VPN_ENV_CHANGED=1`, after `docker compose --profile vpn up -d`, explicitly run `docker compose --profile vpn up -d --force-recreate gluetun qbittorrent` so `gluetun` always reloads updated `vpn.env` values.

### 2c. Fix false-PASS container status checks in V6 (`phase5_apply.sh`) and S4 (`phase5_diag.sh`)
- **Bug 1:** `phase5_apply.sh` line 1649 currently runs `grep -qE 'Up|Restarting' && pass "$C running"`, which passes a crash-looping clearnet container. Change to `grep -qE 'Up' && ! grep -qF '(unhealthy)'`.
- **Bug 2:** `phase5_apply.sh` line 1657 and `phase5_diag.sh` line 269 check `grep -qE 'Up|healthy'` for `gluetun` and `qbittorrent`, which passes `Up 5 seconds (unhealthy)` or `Up 2 seconds (health: starting)`.
  - For `gluetun`: if status contains `(health: starting)`, poll up to 20s in V6; require `Up .* \(healthy\)` to pass.
  - For `qbittorrent`: require `Up` and not `Restarting`/`(unhealthy)`.

---

## Part 3 — Step 8 Family Browser Access + AirVPN Port Forwarding (`# fix 52` / `# fix 53`)

> **Pre-check before running Step 8:** Reserve your static port (`>= 2048`, e.g. `51413`) in the AirVPN Client Area (*Client Area → Forwarded Ports*). If AirVPN assigns a different port number than `51413`, substitute that number for `51413` below.

### 3a. `phase5_compose.yaml` Updates
1. **Image pins header & services:**
   - Add `sonarr`: `lscr.io/linuxserver/sonarr:4.0.11` (verify exact tag availability in Docker Hub before applying; never `:latest`), `container_name: sonarr`, `restart: unless-stopped`, `PUID=1001`, `PGID=1001`, `TZ=Etc/UTC`, `ports: ["192.168.122.10:8989:8989/tcp"]`.
   - **Critical hardlink fix on `sonarr`:** Mount:
     ```yaml
     volumes:
       - /data/config/sonarr:/config
       - /data:/data
     ```
     *(Never mount `/data/torrents` and `/data/media/tv` as separate bind mounts — separate bind mounts cross mount table entries in Docker and break hardlinks with `EXDEV`, forcing slow full copies. Mounting `/data:/data` matches `radarr` and `lidarr`.)*
   - Add `jellyseerr`: `fallenbagel/jellyseerr:2.1.0` (verify exact tag availability), `container_name: jellyseerr`, `restart: unless-stopped`, **`user: "1001:1001"`** (critical: `fallenbagel/jellyseerr` is an Alpine Node image without s6-overlay and ignores `PUID`/`PGID` unless `user:` is set), `environment: [PUID=1001, PGID=1001, TZ=Etc/UTC]`, `ports: ["192.168.122.10:5055:5055/tcp"]`, `volumes: ["/data/config/jellyseerr:/app/config"]`.
2. **AirVPN port forwarding on `gluetun` & `qbittorrent`:**
   - In `gluetun.environment`: add `- FIREWALL_VPN_INPUT_PORTS=51413`.
   - In `qbittorrent.environment`: change `TORRENTING_PORT=6881` to `TORRENTING_PORT=51413`.

### 3b. In-VM Provisioning Updates (`phase5_apply.sh` `vm_setup.sh` heredoc)
1. **Directories:**
   - Add `/data/torrents/tv`, `/data/media/tv`, and `/data/config/{sonarr,jellyseerr}` before `chown -R 1001:1001 /data`.
2. **`qBittorrent.conf` pre-seed + live migration:**
   - Keep `if [ ! -f "$QBC" ]; then` intact (required by G11 line 599), setting `Session\Port=51413` in the pre-seed.
   - Immediately after `fi`, add an idempotent migration for already-provisioned VMs:
     ```bash
     if grep -qF 'Session\Port=6881' "$QBC" 2>/dev/null; then
         sed -i 's/^Session\\Port=6881$/Session\\Port=51413/' "$QBC"
         chown 1001:1001 "$QBC"
     fi
     ```
3. **VM `ufw` & `torrent-port-guard` (`DOCKER-USER`):**
   - Update management/stack port allow loop in `vm_setup.sh`:
     `for P in 22 8080 9696 7878 8686 8989 6767 8096 5055; do`
   - Update inbound `DOCKER-USER` conntrack source guard loop in `/usr/sbin/torrent-port-guard`:
     `for P in 8080 9696 7878 8686 8989 6767 8096 5055; do` (8 stack ports).
   - Keep `6881:6889` `ufw deny` and `DOCKER-USER` rules intact, and additionally add `51413` (tcp+udp) to `ufw deny` and `DOCKER-USER -o "$NIC" -j DROP` (and `ip6tables`) so the forwarded port is also blocked on the clearnet NIC `enp1s0`.

### 3c. Host Caddy TLS Terminator on `192.168.1.133:8443` (`phase5_apply.sh` APPLY 1/7 & APPLY 6/7)
1. **Packages (APPLY 1/7):** Add `caddy` and `libnss3-tools` to `PKGS`.
2. **Caddyfile (`/etc/caddy/Caddyfile`, `root:root 0644`):**
   Write **before** starting/reloading `caddy.service` so Ubuntu's default `:80` wildcard site is replaced immediately. Include `admin off` and `auto_https disable_redirects` so Caddy never binds `localhost:2019` or `0.0.0.0:80`:
   ```caddyfile
   {
       admin off
       auto_https disable_redirects
       local_certs
       pki {
           ca local {
               name "Family Media CA"
           }
       }
   }

   https://clawbox.local:8443, https://192.168.1.133:8443 {
       bind 192.168.1.133
       tls internal
       header {
           Strict-Transport-Security "max-age=31536000"
           X-Content-Type-Options "nosniff"
           X-Frame-Options "SAMEORIGIN"
           Referrer-Policy "same-origin"
       }
       reverse_proxy 192.168.122.10:5055
   }
   ```
3. **Boot-safe systemd drop-in (`/etc/systemd/system/caddy.service.d/phase5.conf`, `root:root 0644`):**
   Because `bind 192.168.1.133` in Go's `net.Listen` does not set `IP_FREEBIND` unless ordered after DHCP or allowed to bind non-locally, prevent a Fix-50-style boot race by ordering `caddy.service` (safe for a `.service` unit, unlike a `.socket` unit) and sandboxing it:
   ```ini
   [Unit]
   After=network-online.target libvirtd.service
   Wants=network-online.target

   [Service]
   ProtectHome=yes
   PrivateTmp=yes
   NoNewPrivileges=yes
   RestrictAddressFamilies=AF_INET AF_UNIX
   IPAddressDeny=any
   IPAddressAllow=127.0.0.0/8 192.168.1.0/24 192.168.122.10
   Restart=on-failure
   RestartSec=3
   ```
4. **Host `ufw` rule (APPLY 6/7):**
   ```bash
   if ufw status 2>/dev/null | grep -qE "^8443/tcp( on [^[:space:]]+)?[[:space:]]+ALLOW"; then
       echo "  [ok]      ufw 8443/tcp allow already present"
   else
       ufw allow in on eno1 from 192.168.1.0/24 to any port 8443 proto tcp >/dev/null 2>&1 \
           && echo "  [ok]      ufw allow: LAN -> :8443/tcp (Family requests HTTPS via Caddy)"
   fi
   ```
5. **Local CA root export:**
   - Enable/restart `caddy.service`, issue one `curl -ksI -m 5 https://192.168.1.133:8443 >/dev/null 2>&1 || true` probe so Caddy initializes its local PKI if first run, and copy `/var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt` to `/etc/media-vm/family-media-ca.crt` (`root:root 0644`).

### 3d. Key Harvest Update (`phase5_apply.sh` APPLY 7/7)
- Poll loop: `for APP in prowlarr radarr lidarr sonarr bazarr; do` and break when `[ "$KC" -eq 5 ] && break`.
- Update `PORTS`:
  `PORTS=(prowlarr:9696 radarr:7878 lidarr:8686 sonarr:8989 bazarr:6767 jellyfin:8096 qbittorrent:8080)`
- Update API key append loop:
  `for APP in prowlarr radarr lidarr sonarr bazarr; do`
- Total harvested keys in `/opt/media-assistant/.env` becomes **12** (7 URLs + 5 API keys).

### 3e. Verification (`V1–V10`), Diagnostics (`S1–S10`), and Guardrail (`G1–G17`) Updates
- **`phase5_apply.sh`:**
  - `V1`: check `caddy` binary present.
  - `V4`: verify `/data/torrents/tv` and `/data/media/tv` exist.
  - `V6`: check all 7 clearnet containers (`prowlarr radarr lidarr sonarr bazarr jellyfin jellyseerr`) + `gluetun` (`Up .* \(healthy\)`) + `qbittorrent` (`Up`).
  - `V7`: verify `SONARR_URL` and `SONARR_API_KEY` included in harvest check.
  - `V8`: verify `caddy.service` active, `/etc/caddy/Caddyfile` pins `bind 192.168.1.133`, `admin off`, `auto_https disable_redirects`, exactly one `:8443` listener (`192.168.1.133:8443`), zero host listeners on `:80`, `:443`, `:2019`, or `8080|9696|7878|8686|8989|6767|5055`, `https://192.168.1.133:8443` answers HTTP 200/302/307, `/etc/media-vm/family-media-ca.crt` present, and exact `ufw` row for `8443/tcp` from `192.168.1.0/24` with no wildcard allow.
- **`phase5_diag.sh`:**
  - `S3`: check `{movies,music,tv}` subdirs on both `/data/torrents` and `/data/media`; check `Session\Port=51413`.
  - `S4`: check 7 clearnet containers; require `gluetun` `(healthy)`.
  - `S5`: check `caddy.service` active, `192.168.1.133:8443` listener pinned, `https://192.168.1.133:8443` -> HTTP 200/302/307.
  - `S6`: negative LAN probes on `192.168.1.133` for all 7 isolated ports (`8080 9696 7878 8686 8989 6767 5055`); verify no host listeners on those 7 ports or `:80`/`:443`/`:2019`.
  - `S7`: `DOCKER-USER` inbound `--ctorigdstport` count `-ge 8`; `51413` + `6881:6889` deny rules present.
  - `S9`: exact `ufw` row for `8443/tcp` from `192.168.1.0/24`; `UFW_ANY_ROW` covers `8096/tcp|7359/udp|8443/tcp`.
  - `S10`: require all **12** harvested keys (`SONARR_URL` and `SONARR_API_KEY` added); include `caddy.service` in the boot-scoped journal scan.
- **`phase5_guardrail_test.sh`:**
  - `G2`: 9/9 pinned images (`PIN_SONARR`, `PIN_JELLYSEERR` added).
  - `G3`: check `FIREWALL_VPN_INPUT_PORTS=51413` on `gluetun`.
  - `G4`: 8/8 published ports bound to `192.168.122.10`.
  - `G5`: 16/16 volume mappings (`sonarr` has `/data:/data` + `/data/config/sonarr:/config`; `jellyseerr` has `/data/config/jellyseerr:/app/config`).
  - `G8`: `Session\Port=51413`, 8-port `DOCKER-USER` inbound loop (`8080 9696 7878 8686 8989 6767 8096 5055`).
  - `G9`: `8443/tcp` LAN `ufw` rule, Caddyfile `bind 192.168.1.133`, `admin off`, `auto_https disable_redirects`, no wildcard allows on `8989`/`5055`.
  - `G15`: `[ "$NIN" -ge 8 ]`, 12 harvested keys (`SONARR_URL`, `SONARR_API_KEY`).
  - `G17` (new section): assert Fix 52/53 additions (`vpn.env` pre-push lint + IPv6 address guard, `VPN_ENV_CHANGED` recreate, `jellyseerr` `user: "1001:1001"`, `qBittorrent.conf` port migration, Caddy systemd drop-in hardening).
- **Docs (`phase5_manual_steps.md` & `PROJECT_MEMORY.md`):**
  - Update Step 8 status from `PLANNED` to `IMPLEMENTED (fix 52)`, fix the `sonarr` volume snippet in `8c` to `/data:/data`, and record the fix in `PROJECT_MEMORY.md`.

---

## 4. Recommended Implementation Model (`go-model-router`)

Live quota check (`bash ~/.config/opencode/skills/go-model-router/usage.sh`):
- **Usage:** 5h `12.0%` | Weekly `61.0%` | Monthly `83.0%` (`15.7d` left)
- **Mode:** `routing_mode=downgrade_1_tier` (`running_hot=True`)
- **Task class:** Intrinsic `T3` (multi-file bash/compose/firewall/guardrail refactoring) → shifted 1 tier left to **`T2`**.

| Option | Model ID & Variant | Why |
|---|---|---|
| **Primary (Row 2 SWE Bug Fixing & Refactoring, T2)** | `opencode-go/deepseek-v4.1-flash#high` | DeepSWE 77.0% (within 0.9% of T3 SOTA), backed by the **$100 monthly pool** and **43.3k req/5h** — protects the 83% monthly quota. |
| **Alternative (Row 3/8 Codegen & Security Audit, T2)** | `opencode-go/glm-5.3#high` | KingBench 3 91.25% (#1) + CyberGym 84.5%; ideal for strict bash quoting and guardrail regex precision. |
| **Per-Model Quota Fallback** | `opencode-go/kimi-k2.7-code` or `opencode-go/glm-5.2` | Independent **$60 monthly pools** if any rate limit occurs. |

### Prompt to Start the New Session
```text
Read /home/jordan/Documents/SystemBuild/phase5_fix52_plan.md.
First check whether Part 1 (gluetun live recovery) has already been run and what AirVPN forwarded port (>=2048) is reserved, then implement Part 2 and Part 3 (Fix 52), run bash -n on all scripts, run phase5_guardrail_test.sh (and mutation-test the new assertions), and provide the root install/apply/diag commands.
```

---

## 5. Deferred follow-up — torrent peer health (do LATER; NOT a Phase 5 gate)

**Status 2026-11-15:** Parts 1–3 are done and live. Guardrail + apply + diag are all
`VERIFY_FAILS=0` on the installed copies, S3 proves a `LISTEN` socket on `37686`
inside gluetun's netns (`0x9336 — fix 56`), S7 shows the `37686` DOCKER-USER rows
with the stale `51413` rows pruned, and AirVPN's forwarded-port test reads **open**
on both the TCP and UDP rows. Peer/ratio behaviour is therefore *observation only*
— nothing below needs to be fixed unless it regresses.

**When:** after the first full day of normal traffic (target **on/after
2026-11-16 ~14:30 UTC**, i.e. ≥24 h after the fix-56 apply). Do not judge inbound
peers earlier: a freshly opened forward needs announce/DHT cycles plus a few
session restarts before peer counts mean anything.

**What to check, in this order:**

1. **AirVPN Client Area → Forwarded Ports** → click *test open* again. Both the
   `TCP` and `UDP` rows for device `torrent`, port `37686`, must still read
   **open**. If one drops to timed-out, go to "If it regresses" below.
2. **qBittorrent status bar** (WebUI, step 4 of the hand-off): connection status
   must be green / `Connected` — **not** `Firewalled` — and the DHT node count
   should be a real number, not `0`.
3. **An active torrent → Peers column**: inbound peers (`incoming`/`I` flag)
   should appear over time; the tracker list should show `Working` and non-empty
   peer lists.
4. **Ratio/upload**: some sustained upload, not a permanently at-zero ratio.

**Optional hard evidence** (inside media-vm, after `ssh jordan@192.168.122.10
"sudo -i"`-style access):

```bash
sudo docker exec gluetun awk '$2 ~ /:9336$/ {print $4}' /proc/net/tcp | sort | uniq -c
#   0A = LISTEN (the fix-56 proof), 01 = ESTABLISHED inbound/outbound peers
sudo docker exec gluetun ip -4 -o addr show dev tun0   # record the tunnel IP
```

Then re-run `bash /usr/local/sbin/phase5/phase5_diag.sh` once: S3 must stay green
(`LISTENs on 37686 …`) and S7 must still show 8/8 inbound guards.

**Record the result** as a dated line in `PROJECT_MEMORY.md` under the fix-56
entry (what the test-open said, tunnel IP, established-peer count, ratio) so a
later drift is comparable.

**If it regresses:**

| Symptom | First check |
| --- | --- |
| test-open times out on both protocols, qBt still listens | AirVPN reservation changed for device `torrent` → manual §8k |
| test-open times out, S3 `LISTEN` fails | qBt conf/process drifted → re-run apply (fix 56 stops it, rewrites/inserts, asserts V4) |
| test-open open but qBt says `Firewalled` | qBt still on `6881`/a stale port, or `Session\Interface` ≠ `tun0` → `phase5_diag.sh` S3 |
| one protocol open, one closed | AirVPN reservation missing a row (must have both `TCP` and `UDP`) |

Do **not** "fix" this by opening extra ports on the clearnet side, loosening the
`DOCKER-USER` guards, or editing the conf by hand while the container runs
(qBittorrent overwrites it on SIGTERM — that is exactly what fix 56 prevents).

# Phase 5 — Root-Only Install, Gate Tests, Reboot Test, and Apply

Host: `clawbox` (Ubuntu 26.04) · Artifact: `phase5_apply.sh` + `phase5_compose.yaml` + `phase5_guardrail_test.sh` + `phase5_diag.sh`
Audience: the operator at a **root** shell on `clawbox`.

> **Root-only policy.** This host has no `sudo`. Every privileged command below runs from a root shell
> (root console, or `su -`). Unprivileged-user checks are performed **from** that root shell with
> `runuser -u <user> -- <cmd>`; never `sudo -u`.

> **SECURITY — rotate the VPN key if an earlier run was exposed (fix 27).**
> If an earlier version of `phase5_apply.sh` ever ran while `/var/lib/libvirt/images` was mode `0755`
> **or** `/var/lib/libvirt/images/media-vm-root.qcow2` was mode `0644`, **and** `/etc/media-vm/vpn.env`
> held real credentials, rotate the VPN WireGuard private key (and any OpenVPN password) with your
> provider before writing the new key into `vpn.env`.

---

## Access — getting into media-vm (cheat sheet)

Everything from Step 1 on runs as **root on `clawbox`**. The VM has one dedicated
deploy key and no password login, so these commands only work as root (the key
and its `known_hosts` are root-only, `600`).

```bash
# 0. sanity: root? VM up?
id -u                       # 0 = root
virsh list --all            # media-vm should read "running"

# 1. interactive shell inside the VM
ssh -i /etc/media-vm/deploy_ed25519 -o IdentitiesOnly=yes \
    -o UserKnownHostsFile=/etc/media-vm/known_hosts jordan@192.168.122.10

# 2. one-shot command, same shape
ssh -i /etc/media-vm/deploy_ed25519 -o IdentitiesOnly=yes \
    -o UserKnownHostsFile=/etc/media-vm/known_hosts jordan@192.168.122.10 \
    "docker ps --format '{{.Names}}\t{{.Status}}'"

# 3. boot it if it is "shut off" (then give it ~20 s)
virsh start media-vm

# 4. re-confirm the address if anything moved (static: 192.168.122.10)
virsh domifaddr media-vm
```

Inside the VM, `jordan` has **passwordless `sudo` scoped to that VM only** (the
uid-1001 stack account has none), and Docker commands need it because the socket
is root-owned.

Optional convenience, in root's shell:

```bash
alias mediavm='ssh -i /etc/media-vm/deploy_ed25519 -o IdentitiesOnly=yes -o UserKnownHostsFile=/etc/media-vm/known_hosts jordan@192.168.122.10'
```

From a **laptop** rather than the host console, tunnel the admin UIs through
clawbox (browser work belongs on the host side — the VM cannot reach the LAN by
design):

```bash
ssh -N -L 7878:192.168.122.10:7878 -L 9696:192.168.122.10:9696 \
       -L 8080:192.168.122.10:8080 -L 8989:192.168.122.10:8989 \
       -L 8686:192.168.122.10:8686 -L 6767:192.168.122.10:6767 \
       root@192.168.1.133
```

Failure map:

| Symptom | Cause / fix |
| --- | --- |
| `Permission denied (publickey)` | not root, or the wrong key — the flag is `-i /etc/media-vm/deploy_ed25519 -o IdentitiesOnly=yes` |
| `Host key verification failed` | wrong `known_hosts` path; use the `-o UserKnownHostsFile=…` above and never delete that file (apply owns it) |
| `Connection refused` / timeout | VM down or still booting: `virsh list --all`, `virsh start media-vm`, wait ~20 s |
| `virsh console media-vm` asks for a login | expected — cloud-init injects only the key, there is no console password; SSH above is the supported path |

---

## Step 1 — Install the canonical root-owned copies

```bash
install -d -m 0755 -o root -g root /usr/local/sbin/phase5

install -o root -g root -m 0755 \
    /home/jordan/Documents/SystemBuild/phase5_apply.sh \
    /usr/local/sbin/phase5/phase5_apply.sh

install -o root -g root -m 0644 \
    /home/jordan/Documents/SystemBuild/phase5_compose.yaml \
    /usr/local/sbin/phase5/phase5_compose.yaml

install -o root -g root -m 0755 \
    /home/jordan/Documents/SystemBuild/phase5_guardrail_test.sh \
    /usr/local/sbin/phase5/phase5_guardrail_test.sh

install -o root -g root -m 0755 \
    /home/jordan/Documents/SystemBuild/phase5_diag.sh \
    /usr/local/sbin/phase5/phase5_diag.sh

ls -ld /usr/local/sbin/phase5
ls -l  /usr/local/sbin/phase5/
```

Expected: directory `drwxr-xr-x root root`; the three `.sh` files `-rwxr-xr-x root root`;
`phase5_compose.yaml` `-rw-r--r-- root root`.

---

## Step 2 — Negative gate tests (prove the fail-closed guards fire)

### 2a. Refuse the jordan-owned workspace copy

```bash
bash /home/jordan/Documents/SystemBuild/phase5_apply.sh
```

Expected: `FATAL … not owned by root` and exit code `1`.

### 2b. Refuse a group/world-writable script mode (fix 24)

```bash
chmod 0775 /usr/local/sbin/phase5/phase5_apply.sh
bash /usr/local/sbin/phase5/phase5_apply.sh      # expect FATAL, exit 1

chmod 0755 /usr/local/sbin/phase5/phase5_apply.sh
```

Also confirm a standard `0755` is *accepted* (the old `-ge 2` digit test wrongly rejected it):
the run above must not fail on the mode check.

### 2c. Refuse a planted symlink on the log path (fix 12 / fix 25)

Logs live **only** under `/var/log/systembuild`, so a symlink under
`/home/jordan/Documents/SystemBuild/phase5.out*` is ignored by design. Test the active guard:

```bash
install -d -m 0750 -o root -g root /var/log/systembuild
rm -f /var/log/systembuild/phase5.out.vi
ln -s /etc/shadow /var/log/systembuild/phase5.out.vi

bash /usr/local/sbin/phase5/phase5_apply.sh
# expect: FATAL: /var/log/systembuild/phase5.out.vi is a symlink — refusing to run

rm -f /var/log/systembuild/phase5.out.vi
stat -c '%U:%G %a' /etc/shadow
# expect: root:shadow 640   (untouched)
```

### 2d. Confirm companion-script preflight (fix 28)

```bash
mv /usr/local/sbin/phase5/phase5_diag.sh /tmp/phase5_diag.sh.bak
bash /usr/local/sbin/phase5/phase5_apply.sh     # expect: WARN … not installed yet (not fatal)
mv /tmp/phase5_diag.sh.bak /usr/local/sbin/phase5/phase5_diag.sh

chmod 0777 /usr/local/sbin/phase5/phase5_diag.sh
bash /usr/local/sbin/phase5/phase5_apply.sh     # expect: FATAL … group/world-writable
chmod 0755 /usr/local/sbin/phase5/phase5_diag.sh
```

---

## Step 3 — First full apply (as root)

```bash
bash /usr/local/sbin/phase5/phase5_apply.sh
```

Default is `DISCOVERY_MODE=pinned` → the relay binds `192.168.1.133:7359/udp`. Because Linux sockets
bound to a unicast address do not receive `255.255.255.255:7359` limited broadcasts, **clients must
enter `http://192.168.1.133:8096` manually**. For LAN broadcast auto-discovery instead:

```bash
DISCOVERY_MODE=broadcast bash /usr/local/sbin/phase5/phase5_apply.sh
```

> **fix 57 — broadcast mode also needs the responder published.** A bound relay
> is not a working relay: it forwards probes to the container's `7359/udp`, and
> until fix 57 the compose spec published only `8096/tcp`. Result: every relayed
> probe hit a closed port (`ICMP port-unreachable` on `192.168.122.10:7359`) and
> **no TV ever auto-discovered the server**, in either mode. The stack now
> publishes `192.168.122.10:7359:7359/udp` (VM-bound only; the LAN still reaches
> it solely through the host relay), and diag **S5** probes the responder
> (`who is JellyfinServer?`) so a dead relay target is red, not green. Re-run
> apply after pulling this change — the compose spec is pushed verbatim.

> **fix 58 — the server image must match the TV client.** The Samsung Tizen app
> of record is compiled against **jellyfin-web 12.z** (`Jellyfin for Tizen
> 0.1.0 … with Jellyfin-12.z`). Upstream jumped **10.11.x → 12.0** in Oct 2026,
> so `jeppevinkel/jellyfin-tizen-builds` no longer ships `10.10.z`; a **10.10.6**
> server + 12.z client renders the library but fails *every* play request before
> it reaches `PlaybackInfo`. The stack is therefore pinned to
> **`jellyfin/jellyfin:12.4`**, and apply performs the upgrade **before**
> compose: it tars `/data/config/jellyfin` (fail-closed if `/data` is short on
> space), stops the live container, and steps `10.10.x → 10.10.7 → 12.4` through
> throwaway containers, waiting for `Startup complete` at each step. The 12.0
> DB change is irreversible — keep the `jellyfin-backup-*.tar.gz` until a title
> plays. **After the upgrade a full library scan is mandatory** (see Step 10h).

Expected: `=== VERIFY_FAILS=0 ===`, exit `0`.

> A first run now takes longer (~15–25 min): cloud-init performs
> `package_update` **and** `package_upgrade` and installs `unattended-upgrades`,
> so the VM patches itself. The script allows 10 min for SSH and 15 min for
> cloud-init before it holds the VM.

### 3a. Log of record is append-only (fix 39)

Re-running never truncates `/var/log/systembuild/phase5.out`; each run appends a
`===== Phase 5 run <UTC> on <host> (euid N) =====` header. At 10 MiB the
previous run is kept as `phase5.out.1`.

### 3b. Pre-run root-only confirmations

Two checks need root and are worth doing once before the apply:

```bash
# Phase 3 model allowlist is untouched (V9 precondition — expect 3)
grep -cE '^[[:space:]]*- model_name: ' /etc/litellm/config.yaml

# docker is NOT required on the host (fix 42); it is verified inside media-vm (V5)
command -v docker || echo "docker absent on host — expected"
```

### 3c. If V6 reports the five containers as `absent` (fix 45)

Symptom in the log:

```
[install] docker compose up -d (clearnet five: ...)
bash: line 1: cd: /opt/media-stack: Permission denied
[FAIL] prowlarr not running: absent            (… radarr/lidarr/bazarr/jellyfin)
```

Cause: the push helper created `/opt/media-stack` under `umask 077`, so the
directory was `0700 root:root` and `jordan`'s `cd` failed before `sudo` ever
ran. Fix 45 makes the deploy directory `0755` and moves the `cd` inside the
root shell (`sudo sh -c 'cd /opt/media-stack && docker compose …'`). Re-running
the apply converges — compose retries the pulls:

```bash
stat -c '%U:%G %a' /opt/media-stack        # inside media-vm — expect root:root 755
sudo sh -c 'ls -l /opt/media-stack'
```

> Related: `[FAIL] ufw default incoming policy changed` on a healthy host was a
> bad grep (`Deny incoming` vs ufw's real `Default: deny (incoming), …`), fixed
> in fix 44 for both the apply (V10) and the diag (S9).

### 3d. Diag S6/S7 report LEAKs on correctly isolated ports (fixes 47–48)

Symptom on a HEALTHY host:

```
[FAIL] 192.168.1.133:9696 -> HTTP 000000 (LEAK: this port must never answer on the LAN)
[FAIL] DOCKER-USER inbound guard count = 0 (want >=6)
```

Both were checker bugs, not posture bugs:

* `curl -w '%{http_code}'` already prints `000` when the connect fails; the old
  `|| echo 000` appended a second `000` → `000000`, and the case matched only
  the exact string `000`. Fixed in fix 47 (S5 uses the same pattern).
* the inbound DOCKER-USER guard is keyed on conntrack `--ctorigdstport` (the
  pre-DNAT published port), not `--dport`; the old regex counted 0 while six
  `DROP` rows were printed one line above. Fixed in fix 48.

### 3e. S10 keeps reporting 2 of 10 harvest keys missing (fix 49)

`BAZARR_API_KEY` and `QBITTORRENT_URL` were never written:

* bazarr is **not** a Servarr app — its key lives in
  `/data/config/bazarr/config/config.yaml` (`  apikey: …`), so the
  `config.xml` grep could never match. Fix 49 reads the YAML field.
* `QBITTORRENT_URL` was missing from the URL map. Fix 49 appends it
  (`http://192.168.122.10:8080`) even while the `vpn` profile is gated.

Re-run the apply once (append-only harvest fills the two keys, existing values
are never overwritten), then the diag:

```bash
bash /usr/local/sbin/phase5/phase5_apply.sh
bash /usr/local/sbin/phase5/phase5_diag.sh
```

### 3f. Jellyfin dead after a reboot (fix 50)

Symptom: after boot nothing listens on `192.168.1.133:8096`; the socket is
`failed (Result: resources)` and the journal shows either

```
Found ordering cycle … Job jellyfin-lan-proxy.socket/start deleted
jellyfin-lan-proxy.socket: Failed to create listening socket … Cannot assign requested address
```

Cause: a **socket** unit ordered `After=network-online.target` is a boot-time
ordering cycle (`sockets.target` precedes `basic.target`), and without
`FreeBind=yes` the early bind races DHCP. Fix 50 moves the ordering to the
service and adds `FreeBind=yes`. Apply + verify as root:

```bash
bash /home/jordan/Documents/SystemBuild/phase5_fix50_apply.sh   # writes units, reloads, restarts, installs
bash /home/jordan/Documents/SystemBuild/phase5_fix50_verify.sh  # read-only acceptance, VERIFY_FAILS=0
```

**Proven on a cold boot.** The units were written at 2026-11-11 18:42 and the
host booted at 18:49; the socket reported `Listening on
jellyfin-lan-proxy.socket` at 18:49:09 (boot + 9 s) with no manual
intervention, one and only one `Listening on` line, no ordering cycle and no
`Cannot assign requested address`. Section 8 of
`phase5_fix50_verify.sh` asserts exactly that evidence on every run (one
boot-time bind, no cycle/bind failure, no restart, unit enabled), so after any
reboot this script is the proof:

```bash
systemctl is-active jellyfin-lan-proxy.socket   # active
ss -tln | grep :8096                           # 192.168.1.133:8096
bash /home/jordan/Documents/SystemBuild/phase5_fix50_verify.sh   # section 8 all PASS
```

If section 8 fails, `journalctl -b -u jellyfin-lan-proxy.socket -n 30` names
the cause; re-running `phase5_fix50_apply.sh` is idempotent and self-heals a
failed listener without dropping a live one.

### 3g. Diag S10 "error-signature line(s)" that are stale or benign (fix 51)

Symptom after a clean reboot/apply:

```
[note] jellyfin-lan-proxy.socket: 5 error-signature line(s) in the last 60 — review: …
```

Nothing is listening wrongly: those 5 lines were the **pre-fix** 2026-11-10
23:34 bind failures. The scan used `journalctl -u … -n 60` with no `-b`, so it
walked back through *earlier boots* and kept reporting them as current. Fix 51
scopes the scan to the current boot and ignores deliberate stops — every apply
restarts the discovery relay, and systemd logs that SIGTERM as
`status=143` + `Failed with result 'exit-code'`, which is not a fault.

A clean run now prints:

```
[PASS] jellyfin-lan-proxy.socket journal clean of failure signatures (this boot)
[PASS] jellyfin-discovery.service journal clean of failure signatures (this boot)
```

A real failure still trips it (traceback / critical / failed / denied /
ordering cycle / deleted to break). To reproduce a failure-mode note on
demand:

```bash
journalctl -b -u jellyfin-lan-proxy.socket -n 30   # read-only, current boot only
```

### 3h. Diag S10 still flags vpn.env LEADING-SPACE after the Part 1 recovery (fix 52)

Symptom (2026-11-15, after the manual gluetun recovery):

```
[FAIL] /etc/media-vm/vpn.env line 9: WIREGUARD_PRIVATE_KEY — misparseable: [LEADING-SPACE]
[FAIL] /etc/media-vm/vpn.env line 10: WIREGUARD_PRESHARED_KEY — misparseable: [LEADING-SPACE]
```

The tunnel itself can still be healthy: docker compose's env_file parser trims
edge whitespace, so gluetun received a usable key while `env_lint` (correctly)
refused the line. Fix 52 makes apply self-healing: `vpn_env_normalize()` rewrites
the host file atomically (same directory, same owner/mode) and strips only
`\r`, edge whitespace, surrounding quotes and the `, fd7d:…` IPv6 tail — key
material is never touched and values are never echoed. It then pushes the host
copy when the lint is clean (the host is authoritative once it has real
credentials) and force-recreates `gluetun` + `qbittorrent` because compose
v2.26 does not reliably recreate on an `env_file`-only change. Re-run:

```bash
sudo bash /usr/local/sbin/phase5/phase5_apply.sh     # root; normalizes + pushes + recreates
sudo bash /usr/local/sbin/phase5/phase5_diag.sh      # expect VERIFY_FAILS=0
```

Do **not** hand-edit `/opt/media-stack/vpn.env` inside the VM — the next apply
now treats the host file as truth.

### 3i. Diag says `DOCKER-USER inbound guard count = 6` (fix 54)

Symptom (2026-11-15, after a port-substitution attempt):

```
[PASS] VM ufw deny rows for  present (tcp+udp)          <- empty port, grep matched a prefix
[PASS] DOCKER-USER carries >=2 DROP rules for  (tcp+udp)
[FAIL] DOCKER-USER inbound guard count = 6 (want >=8)
```

Two defects stack here, and neither is a security regression by itself:

1. The Step 8k `sed` ran with `NEW` empty, so the then-current placeholder
   `51413` was **deleted** from `phase5_compose.yaml`, `phase5_apply.sh`,
   `phase5_diag.sh` and the guardrail.
   Empty values still satisfy prefix greps (`FIREWALL_VPN_INPUT_PORTS=`,
   `--dport `), which is why the guardrail kept passing.
2. `phase5_apply.sh` rewrites `/usr/sbin/torrent-port-guard` but used
   `systemctl enable --now torrent-port-guard.service` — a **no-op when the
   unit is already active** — so the live `DOCKER-USER` chain kept the earlier
   6-port rule set (no `8989`/`5055` and no forwarded port).

Fix 54 makes both loud and self-healing: the port is validated by an
`AIRVPN_PORT` canary before any rule, apply repairs an empty `Session\Port=`,
the guard unit is **restarted** after every rewrite, diag/guardrail reject empty
port tokens (G18), and the 8k snippet refuses an empty `NEW`. Recover with:

```bash
cd /home/jordan/Documents/SystemBuild
bash phase5_guardrail_test.sh        # G18 must PASS: one numeric port, no empty token
sudo bash phase5_step1_install.sh    # install the repaired copies
sudo bash /usr/local/sbin/phase5/phase5_apply.sh
sudo bash /usr/local/sbin/phase5/phase5_diag.sh   # S3 numeric, S7 count >= 8
```

Verify the guard actually reloaded (inside media-vm):

```bash
sudo systemctl restart torrent-port-guard.service
sudo iptables -S DOCKER-USER | grep -c -- '--ctorigdstport .*--ctdir ORIGINAL.*-j DROP'   # expect 8
sudo iptables -S DOCKER-USER | grep -c -- '--dport 37686.*DROP'                            # expect >= 2
sudo grep -aF 'Session\Port=37686' /data/config/qbittorrent/qBittorrent/qBittorrent.conf                     # expect a hit
```

### 3j. Apply is green but diag fails both `Session\Port` checks (fix 56)

Symptom (2026-11-15, after pinning the reserved AirVPN port `37686`):

```
[FAIL] qBittorrent.conf does not pin Session\Port=37686 (key absent or stale — fix 56)
[FAIL] qBittorrent.conf Session\Port is empty/non-numeric (fix 54) — observed '<missing>'
```

…while `phase5_apply.sh` printed `VERIFY_FAILS=0`. It never inspected the
conf, so a broken listen port could not turn the apply red. Two gaps stack:

1. The fix-54 repair only rewrote an **existing** `Session\Port=` line. If
   qBittorrent removed the key entirely (libtorrent's default listen port is
   `6881`, and qBittorrent omits values it considers default when it rewrites
   its config), the `sed` matched nothing — yet the "repaired" message printed
   anyway.
2. qBittorrent dumps its **in-memory** config over `qBittorrent.conf` on
   SIGTERM. Editing the file while the container runs is therefore reverted by
   the very restart that is supposed to load the new port. That is also how a
   corrected value can silently revert during a gluetun/qBt recreate.

Fix 56 makes it converge and self-checking: apply stops `qbittorrent` first,
rewrites any existing value to the canary, **inserts** the key under
`[BitTorrent]` (awk + `ENVIRON`, so the literal `Session\` survives) when it is
absent, asserts the on-disk value in V4, and prunes `DOCKER-USER` single-port
DROP rows left by an older forwarded port. Diag also proves the **socket**, not
just the file: the conf value is only real if the process listens on it inside
gluetun's netns (that is the interface AirVPN forwards to), so diag reads
`/proc/net/tcp` inside `gluetun` and requires a `LISTEN` row on the port
(state `0A`; `37686` = `0x9336`, derived from the literal so a Step 8k port move
stays in sync). Recover with the same four commands as 3i. Expected diag S3
lines afterwards:

```
[PASS] qBittorrent.conf Session\Port=37686 (AirVPN forwarded port — fix 52)
[PASS] qBittorrent.conf Session\Port is numeric (37686)
[PASS] qBittorrent LISTENs on 37686 inside gluetun's netns (0x9336 — fix 56)
```

Verify by hand (inside media-vm):

```bash
sudo grep -aF 'Session\Port=37686' /data/config/qbittorrent/qBittorrent/qBittorrent.conf
sudo iptables -S DOCKER-USER | grep -c -- '--dport 37686.*DROP'   # expect >= 2
sudo iptables -S DOCKER-USER | grep -c -- '--dport 51413.*DROP'   # expect 0 (pruned)
```

`ufw status` may still list the previous placeholder's `51413/tcp|udp DENY`
rows. They are deny-only (strictly more restrictive, never a forwarding path)
and are left alone deliberately: a generic prune of `DENY` rows could remove an
unrelated rule you added. Only the script-owned `DOCKER-USER` rows are pruned.

### 3k. A title downloads but crawls, or `--status` says `firewalled` (fix 74)

`sudo bash qbt_admin.sh --status` now answers "why is this slow?" directly:

```
== transfer ==
  connection status            : firewalled
  download / upload            : 0.0 KiB/s / 12.4 KiB/s
  DHT nodes                    : 412
== stalled downloads: tracker verdict ==
  The Breakfast Club 1985 ...
    udp://tracker.opentrackr.org:1337/announce  working       peers=0    ...
```

Read it in this order:

| Field | Meaning | Action |
| --- | --- | --- |
| `connection_status: connected` | incoming + outgoing peers work | the swarm is the problem, not the stack |
| `connection_status: firewalled` | **no incoming connections** | the AirVPN port-forward is not reaching this tunnel — see below |
| `connection_status: disconnected` | no usable network/port | `docker logs gluetun`; check the tunnel and `Session\Port` |
| tracker `working` + `peers=0` | tracker reachable, nobody has the data | pick another release; nothing to fix in the stack |
| tracker `NOT WORKING` | tracker dead / DNS blocked | try another indexer/release; this one may never finish |
| `no HTTP/UDP trackers` | DHT/PEX only (magnet without trackers) | expect it to be slow to start |

`firewalled` still downloads — only from peers it can dial — which is exactly why
it looks like "the connection is fine but the title crawls". The forward must
match **the port in the conf and the compose file**: AirVPN binds a forwarded
port to the **key/server pair**, so changing country or server silently
invalidates it. Confirm the port in the AirVPN client area is `37686` for the key
in `vpn.env`, then make the three copies agree (`FIREWALL_VPN_INPUT_PORTS`,
`TORRENTING_PORT`, `Session\Port`); §8k has the change sequence.

If `connection_status` is `disconnected` **and** the conf carries
`Session\Interface=tun0`, check the interface name inside the tunnel namespace —
gluetun uses `tun0` for both OpenVPN and WireGuard today, but a name mismatch
means qBittorrent binds to nothing:

```bash
sudo docker exec gluetun ip -o link show | awk -F': ' '{print $2}'
```

---

## Step 4 — Post-apply permission and isolation checks (as root)

### 4a. `jordan` can read the log via traversal ACL (fix 26)

```bash
stat -c '%U:%G %a' /var/log/systembuild /var/log/systembuild/phase5.out
getfacl -p /var/log/systembuild /var/log/systembuild/phase5.out

runuser -u jordan -- head -n1 /var/log/systembuild/phase5.out    # must print line 1

# listing must still be denied (x-only traversal, no r):
runuser -u jordan -- ls /var/log/systembuild \
    && echo "UNEXPECTED: listing allowed" || echo "OK: listing denied"
```

### 4b. Images directory and root disk are not readable by others (fix 27)

```bash
stat -c '%U:%G %a' /var/lib/libvirt/images /var/lib/libvirt/images/media-vm-root.qcow2
# expect: root:root 711   /   root:root 600 (or libvirt-qemu:kvm 600 while the VM runs)

runuser -u nobody -- cat /var/lib/libvirt/images/media-vm-root.qcow2 >/dev/null
# expect: Permission denied (non-zero exit)
```

### 4c. Stack uid is separated from the admin uid (fix 37 / fix 43)

```bash
ssh -i /etc/media-vm/deploy_ed25519 -o IdentitiesOnly=yes \
    -o UserKnownHostsFile=/etc/media-vm/known_hosts jordan@192.168.122.10 \
    "stat -c '%u:%g' /data; getent passwd 1001 || echo 'no passwd entry for 1001 (expected)'; id -u jordan"
# expect: 1001:1001  /  no passwd entry for 1001 (expected)  /  1000

# the stack uid must have no sudo rights at all:
ssh -i /etc/media-vm/deploy_ed25519 -o IdentitiesOnly=yes \
    -o UserKnownHostsFile=/etc/media-vm/known_hosts jordan@192.168.122.10 \
    "sudo grep -R '1001' /etc/sudoers /etc/sudoers.d/ 2>/dev/null || echo 'no sudo rule for 1001 (expected)'"
```

> **fix 43 — host vs guest uid namespaces.** `1001` is account-less only *inside*
> `media-vm`. On `clawbox`, uid `1001` is the phase-4 **`hermes`** service account
> (`/bin/bash`, `/home/hermes`). That is safe because the media LV is raw
> passthrough and is **never mounted on the host** — the two namespaces never
> meet. Do not add a host-side export/bind mount of `/data`: it would surface
> guest files as `hermes`-owned, and vice-versa. Apply `V4` and diag `S3` now
> assert the guest side (`getent passwd 1001` empty, `id -u jordan` = 1000).

### 4d. Claim the Jellyfin admin account now

Open `http://192.168.1.133:8096` and finish the setup wizard. Until the first admin exists, **any**
LAN device can claim it.

---

## Step 5 — Host reboot test (run BEFORE the idempotency re-run)

Reboot first, so the reboot-only paths (`/etc/libvirt/hooks/network`, `media-vm` autostart, the LAN
proxy socket) are proven independent of the apply process.

```bash
reboot
```

After `clawbox` returns, log in as root and verify:

```bash
# 1. VM came back by itself
virsh domstate media-vm

# 2. RFC1918 DROPs sit at the TOP of FORWARD, above LIBVIRT_FWX
iptables -L FORWARD -n -v --line-numbers | head -n 12

# 3. libvirt hook + guard unit are in place (fix 30 / fix 40)
stat -c '%U:%G %a' /etc/libvirt/hooks /etc/libvirt/hooks/network
head -n1 /etc/libvirt/hooks/network            # must be a #!/...sh shebang
awk '/^exit([[:space:]]|$)/{print "early exit at line " NR; exit}' /etc/libvirt/hooks/network
systemctl is-active media-vm-lan-guard.service

# 4. Pivot still blocked after reboot (must NOT connect)
ssh -i /etc/media-vm/deploy_ed25519 -o IdentitiesOnly=yes \
    -o UserKnownHostsFile=/etc/media-vm/known_hosts jordan@192.168.122.10 \
    'sudo timeout 4 bash -c "exec 3<>/dev/tcp/192.168.1.1/80"' \
    && echo "FAIL: pivot succeeded" || echo "PASS: pivot blocked"

# 5. Live read-only diagnostics
bash /usr/local/sbin/phase5/phase5_diag.sh
```

---

## Step 6 — Idempotency re-run (and optional VPN activation)

1. *(Optional)* Fill `/etc/media-vm/vpn.env` with real credentials: `0600 root:root`, one
   `VAR=value` per line, **no** inline `#` comments, no edge whitespace.
   Provider choice, port-forwarding wiring and torrent-search basics are in
   **Step 8j**.
2. Re-run apply + diag as root:

```bash
bash /usr/local/sbin/phase5/phase5_apply.sh
bash /usr/local/sbin/phase5/phase5_diag.sh
```

Expected: `VERIFY_FAILS=0` on both; the second apply must make no destructive change.

---

## Step 6a — Migrating an ALREADY-PROVISIONED media-vm

Cloud-init only runs once, and the seed ISO is built only when it is absent, so
`package_upgrade` / `unattended-upgrades` only take effect automatically on a
**new** VM. The UID change (fix 37) *does* migrate automatically, because every
apply re-runs `chown -R 1001:1001 /data` and then recreates containers from the
updated compose file.

For the patch management on an existing VM, run the equivalent once by hand:

```bash
ssh -i /etc/media-vm/deploy_ed25519 -o IdentitiesOnly=yes \
    -o UserKnownHostsFile=/etc/media-vm/known_hosts jordan@192.168.122.10 \
    'sudo apt-get update && sudo apt-get -y upgrade && \
     sudo apt-get install -y unattended-upgrades && \
     sudo systemctl enable --now unattended-upgrades.service'
```

(Or destroy and re-create `media-vm` if you want the whole new cloud-init path
exercised — that also re-runs the seed-ISO YAML guard.)

---

## Step 7 — Offline guardrail suite

```bash
bash /usr/local/sbin/phase5/phase5_guardrail_test.sh
```

The **helper** suites need no VM and no network; they live in `tests/` in this
repo (offline HTTP mocks around the exact failure modes that were found live):

```bash
python3 tests/test_library_status.py   # request -> Radarr -> qBt -> disk -> Jellyfin verdicts
python3 tests/test_bz.py               # Bazarr profile write contract (fix 65)
python3 tests/test_jf.py               # Jellyfin endpoint probe / exits 2,5,7
python3 tests/test_rd.py               # Radarr movieCategory vs silently-dropped category
```

Run them before changing a helper; they are the regression net for the day-2
scripts, exactly as the guardrail is for apply/diag.

> **Known stale assertions (pre-existing, not caused by fixes 24–34).** Four G10/G12 checks still
> encode Round-1 behavior that Rounds 2–3 superseded:
>
> | Guardrail line | Expects (stale) | Apply actually does (stronger) | Superseding fix |
> | --- | --- | --- | --- |
> | ~425 | `iptables -C DOCKER-USER -p tcp --dport "$P" …` | `-m conntrack --ctorigdstport "$P" --ctdir ORIGINAL` | fix 18 |
> | ~538/712 | `chown jordan:jordan "$LOG"` / `chmod 644` / `install -m 644 -o jordan` | `root:root 640` + ACL, log under `/var/log/systembuild` | fix 12 |
> | ~666 | `"$WORKDIR/$IMG_NAME.part"` | `"${BASE_IMG}.part"` (same-fs atomic mv) | fix 19 |
>
> These four produce `[FAIL]` lines against a *correct* script. They are cosmetic guardrail drift and
> should be updated to the new literals; they are not security regressions.
>
> **Status 2026-11-12:** superseded — the guardrail now exits `0` with
> `VERIFY_FAILS=0` (154 PASS in the working tree, 152 + 2 benign notes
> installed). Treat the table above as history, not as a current expectation.

---

## Step 8 — Family browser access (IMPLEMENTED — fix 52, 2026-11-15)

**Status:** implemented in the artifacts by fix 52 (Option **A2**: host Caddy
TLS terminator on `192.168.1.133:8443` with `tls internal` / CA name
`Family Media CA`, reverse-proxying to Jellyseerr at `192.168.122.10:5055`).
The `phase5_apply.sh`, `phase5_compose.yaml`, `phase5_diag.sh` and
`phase5_guardrail_test.sh` copies in this directory are the source of truth;
run the canonical root copies after `phase5_step1_install.sh`. Step 8 still
needs the one-time live acceptance run (8h/8i): create the Jellyfin admin, wire
Jellyseerr to Jellyfin/Radarr/Sonarr, import `family-media-ca.crt` on each
family device, then play one title and complete one request.

Everything through Step 7 keeps the LAN surface at `8096/tcp + 7359/udp`
(Jellyfin). Fix 52 adds exactly one LAN port, `8443/tcp`, restricted to
`192.168.1.0/24`; V8, diag S4/S6/S7/S9 and the guardrail (G2–G5, G8, G9, G15,
G17) were updated in the same change and mutation-tested. The *arr/qBt admin
UIs remain off-LAN.

### 8a. Target experience (acceptance)

From a laptop or phone on the home LAN, with **no SSH, no terminal, no VPN app**:

1. Open one bookmark (e.g. `Movies`).
2. Sign in with the household member's **Jellyfin** account (no new password).
3. Search a movie or series, press **Request**.
4. Radarr/Sonarr grabs it, qBittorrent downloads it through gluetun.
5. It appears in Jellyfin; Jellyseerr notifies when ready.

Owner keeps Prowlarr/Radarr/Lidarr/Sonarr/Bazarr/qBittorrent **admin** UIs
host/VM-only. The only new LAN exposure is the requests UI.

### 8b. Recommended design

```text
wife's browser
  -> https://192.168.1.133:8443        (LAN, 192.168.1.0/24 only)
  -> host Caddy (TLS, pinned bind)     or  host socket-proxyd :8088 (HTTP)
  -> 192.168.122.10:5055  Jellyseerr   (VM-only)
       -> Radarr :7878 / Sonarr :8989  (VM-only)
            -> qBittorrent (gluetun netns) -> /data/torrents
                 -> Jellyfin :8096 -> LAN :8096 (unchanged)
```

| Component | Where | Bind | Why |
| --- | --- | --- | --- |
| **Jellyseerr** (requests UI) | media-vm | `192.168.122.10:5055` | Jellyfin login, friendly "search → Request" flow |
| **Sonarr** (TV) | media-vm | `192.168.122.10:8989` | series requests; optional if movies only |
| **Caddy** (TLS terminator) | clawbox | `192.168.1.133:8443` | valid cert + security headers, one URL |
| host relay (HTTP-only variant) | clawbox | `192.168.1.133:8088` | same socket-proxyd pattern as Jellyfin |
| Jellyfin / discovery | unchanged | `:8096`, `:7359/udp` | do not touch |

Deliberately **not** exposed: Radarr, Lidarr, Sonarr admin, Bazarr, Prowlarr,
qBittorrent. They have weak or no default auth and are not needed by the wife.
Lidarr has no Jellyseerr integration, so music requests stay owner-only.

### 8c. What changes, where

**Compose (media-vm):** `jellyseerr` + `sonarr`, pinned images (never
`latest`), `PUID=1001 PGID=1001`, VM-only port binds, and volumes:

```yaml
  jellyseerr:
    image: fallenbagel/jellyseerr:2.1.0
    container_name: jellyseerr
    restart: unless-stopped
    user: "1001:1001"          # CRITICAL: no s6-overlay -> PUID/PGID ignored
    ports: ["192.168.122.10:5055:5055/tcp"]
    environment: [PUID=1001, PGID=1001, TZ=Etc/UTC]
    volumes: ["/data/config/jellyseerr:/app/config"]

  sonarr:
    image: lscr.io/linuxserver/sonarr:4.0.11
    container_name: sonarr
    restart: unless-stopped
    ports: ["192.168.122.10:8989:8989/tcp"]
    environment: [PUID=1001, PGID=1001, TZ=Etc/UTC]
    volumes:
      - /data/config/sonarr:/config
      - /data:/data            # NEVER split torrents/media/tv -> EXDEV copies
```

**Host exposure, Option A1 — HTTP (fastest):** a second socket-proxyd pair,
copying the fix-50 pattern exactly:

```ini
# /etc/systemd/system/family-ui-lan-proxy.socket
[Unit]
Description=Family requests UI listener (192.168.1.133:8088 -> media-vm 5055)

[Socket]
ListenStream=192.168.1.133:8088
ReusePort=yes
Backlog=100
FreeBind=yes

[Install]
WantedBy=sockets.target
```

```ini
# /etc/systemd/system/family-ui-lan-proxy.service
[Unit]
Description=Family requests UI relay (systemd-socket-proxyd)
Requires=family-ui-lan-proxy.socket
After=network-online.target libvirtd.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/lib/systemd/systemd-socket-proxyd 192.168.122.10:5055
DynamicUser=yes
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectSystem=strict
NoNewPrivileges=yes
RestrictAddressFamilies=AF_INET AF_UNIX
IPAddressDeny=any
IPAddressAllow=192.168.1.0/24 192.168.122.10
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

**Host exposure, Option A2/A3 — HTTPS (recommended):** install Caddy on the
host instead of the relay, bound `192.168.1.133:8443`, reverse-proxying to
`192.168.122.10:5055`. Unit is root-owned with `ProtectSystem=strict`; cert
material and any DNS-01 token live `0600 root:root` under `/var/lib/caddy`.
A2 = `tls internal` (install the CA once on each household device);
A3 = real domain + DNS-01 wildcard (green lock on every device, needs a domain
and a DNS API token — best wife experience, most owner setup).

**ufw (exact row, LAN subnet only — never `Anywhere`):**

```bash
ufw allow in on eno1 from 192.168.1.0/24 to any port 8088 proto tcp   # A1
# or
ufw allow in on eno1 from 192.168.1.0/24 to any port 8443 proto tcp   # A2/A3
```

**Jellyseerr first-run — use the COMPOSE SERVICE NAMES, never the VM IP (verified
2026-11-16):** Jellyfin URL `http://jellyfin:8096` (port `8096`, SSL off,
**URL Base empty**); Radarr `http://radarr:7878`; Sonarr `http://sonarr:8989`.
The apps all share the `media-stack_default` bridge, so names resolve
(`getent hosts jellyfin` -> `172.18.0.2`). `http://192.168.122.10:<port>` does
**not** work from inside a container: that address is the VM's own host IP, so
the packet enters the VM's `INPUT` chain (docker's userland proxy) and `ufw`'s
`allow ... from 192.168.122.0/24` row does not match a `172.18.0.x` source — it
hangs until timeout. The VM IP is correct only for probes **from clawbox**
(source `192.168.122.1`), which is why diag S5 sees HTTP 200. Likewise
`192.168.1.133` can never work from a container: the host `:8096` relay is
one-way (`socket-proxyd`, host -> VM) and VM -> LAN is dropped by the pivot
guard. Also note `URL Base` is a reverse-proxy *subpath* (`/jellyfin`), not a
host — pasting a URL there makes Jellyseerr call
`http://<url>:8096//192.168.122.10:8096/...`; and the sign-in username is the
**Jellyfin** admin created in §4d, not the clawbox OS `root` account. Radarr's
and Sonarr's keys are harvested into `/opt/media-assistant/.env` (`SONARR_URL` +
`SONARR_API_KEY` included — 12 keys total); copy them into Jellyseerr's settings
(owner-only step). Sign-in via Jellyfin only; anonymous access OFF; admin =
owner. `/data/media/tv` and `/data/torrents/tv` are created by the in-VM
provisioning step (fix 52) and the qBittorrent listen port is migrated from
6881 to the AirVPN forwarded port (37686) automatically.

### 8d. TLS choice

| Option | Wife effort | Security | Owner effort |
| --- | --- | --- | --- |
| **A1** HTTP `:8088` | bookmark | password in clear on the LAN | ~15 min |
| **A2** HTTPS internal CA `:8443` | bookmark + one-time CA install per device | encrypted; no public CA needed | ~1 h |
| **A3** HTTPS real domain `:8443` | bookmark only | encrypted, valid cert everywhere | ~1–2 h + domain |

A1 is acceptable on a trusted WPA3 home LAN but the Jellyfin password is
readable to anyone sniffing the LAN. A2/A3 are the recommended end state.

### 8e. Alternative B — Tailscale (no new LAN port)

Install Tailscale on the host, advertise `192.168.122.0/24`, and let household
devices join the tailnet; wife opens a bookmark after the (always-on) app is
installed. It avoids a new `ufw` row but is **not** the recommended default:

* every device needs the app + an account, and a disconnected app looks like
  "the server is broken" to a non-technical user;
* the host **subnet router** must forward tailnet → `192.168.122.10`, but the
  VM→LAN pivot guard deliberately drops `192.168.122.0/24 -> 100.64.0.0/10`
  (S6), which also drops the VM's replies to tailnet clients. Making it work
  requires a `conntrack ESTABLISHED,RELATED` accept above that DROP plus a VM
  `ufw` allow from `100.64.0.0/10` — a real change to the pivot guard, with its
  own mutation tests. Do not attempt it casually.

Option A keeps the pivot guard untouched and gives the wife a plain URL, which
is why it is the recommendation.

### 8f. Verification/guardrail amendments (same patch, no weakening)

* **V8** — LAN surface is now exactly `8096/tcp + 7359/udp + 8088/tcp` (or
  `8443/tcp`), every one pinned to `192.168.1.133`, LAN-subnet-only ufw rows.
  Keep asserting: *arr/qBt still answer **nothing** on the LAN; no wildcard
  bind; new socket (A1) has `FreeBind=yes` and no `network-online` ordering.
* **diag S4** — 5 clearnet containers → 7 (or 6 without Sonarr); all binds
  `192.168.122.10` only.
* **diag S6** — add negative probes for `5055` and `8989` on `192.168.1.133`
  (must be refused) and keep the existing five.
* **diag S7** — DOCKER-USER inbound source guard count `-ge 6` → `-ge 8` (or
  `-ge 7` without Sonarr); raise the bar, do not leave the old count. The ufw
  rows list gains the new relay port.
* **guardrail** — pinned images (no `latest`), new volume/port expectations
  (recompute from the compose; do not hand-edit a count without mutation
  tests), Jellyseerr cannot run unauthenticated, and the new host unit mirrors
  the fix-50 socket rules.
* **PROJECT_MEMORY/manual invariant text** — change "LAN surface = Jellyfin
  only" to "LAN surface = Jellyfin + family requests UI, each pinned and
  LAN-subnet only" in the same commit.

### 8g. Rollback

```bash
systemctl disable --now family-ui-lan-proxy.socket        # A1
systemctl disable --now caddy                              # A2/A3
ufw delete allow in on eno1 from 192.168.1.0/24 to any port 8088 proto tcp
# A2/A3: same delete for 8443 instead of 8088
# and, inside media-vm:
sudo sh -c 'cd /opt/media-stack && docker compose stop jellyseerr sonarr'
```

Jellyfin, the VPN stack and all data are untouched; removing the unit/ufw row
restores the Step 7 posture exactly.

### 8h. Implementation order (when approved)

1. Decide: Sonarr yes/no; A1 vs A2 vs A3.
2. Compose: add services, pins, volumes, VM-only binds; run the in-VM compose.
3. Host: relay **or** Caddy + exact ufw row; verify pin and boot ordering.
4. Jellyseerr: Jellyfin/Radarr/Sonarr wiring; anonymous off; test a request.
5. Update V8 + diag + guardrail **in the same change**; mutation-test each new
   assertion; `bash -n` everything; install via `phase5_step1_install.sh`.
6. `phase5_apply.sh` → `phase5_diag.sh` → reboot test (`systemctl is-active
   family-ui-lan-proxy.socket`, listener up, no manual step).
7. Wife acceptance: bookmark → login → request → play in Jellyfin.
8. Record results in `PROJECT_MEMORY.md`.

### 8i. Wife quick card (print this)

> **Movies:** open the **Movies** bookmark → sign in with your Jellyfin
> account → type the name → press **Request**. Nothing else. If it says
> "already available", it is already in Jellyfin. New titles appear in Jellyfin
> when they finish downloading.

Owner-only: admin UIs (`:9696`, `:7878`, `:8686`, `:8989`, `:6767`, `:8080`)
stay off the LAN; reach them from the clawbox desktop or an SSH tunnel (Step 8j).

### 8j. Reference — VPN provider, port forwarding, torrent search

**Provider (prices Nov 2026, verify at checkout; needs WireGuard + port
forwarding + gluetun support):**

| Provider | Price | Port forwarding | Fit with pinned gluetun v3.40.0 |
| --- | --- | --- | --- |
| **PIA** | **$2.19/mo** on 2 yr + 2 mo ≈ **$57 up front** | yes, most **non-US** regions (NL/CH/CA/DE) | **native** — recommended, least friction |
| **AirVPN** | €2.75/mo on 3 yr ≈ €99 (~$107), flat renewals | yes, all servers, up to 20 ports | manual (`FIREWALL_VPN_INPUT_PORTS` + set the port on their site) |
| ProtonVPN | ~$3–5/mo | yes via NAT-PMP (paid) | needs gluetun **≥3.41.3**; stack pins v3.40.0 |
| Mullvad / IVPN | €5 / ~$6 | **no** | not suitable |
| Nord / Surfshark / Express | $2–4 | **no** | not suitable |
| PureVPN | $1.69 headline | add-on | not native; weak privacy record |

Cheapest credible = **PIA** (choose a non-US region). If flat renewals and
stronger privacy matter more than ~$1/month, take **AirVPN**. Avoid free VPNs
(usually block P2P or omit forwarding).

`/etc/media-vm/vpn.env` (0600 root:root, plain `VAR=value`):

```
VPN_SERVICE_PROVIDER=private internet access
VPN_TYPE=wireguard
PRIVATE_INTERNET_ACCESS_USER=...
PRIVATE_INTERNET_ACCESS_PASSWORD=...
SERVER_REGIONS=Netherlands
VPN_PORT_FORWARDING=on
```

PIA rotates the forwarded port, so qBittorrent's fixed `Session\Port=6881`
goes stale. Add to the gluetun `environment:` block (not `vpn.env`):

```yaml
- VPN_PORT_FORWARDING_UP_COMMAND=/bin/sh -c 'wget -O- -nv --retry-connrefused --post-data "json={\"listen_port\":{{PORT}},\"current_network_interface\":\"{{VPN_INTERFACE}}\",\"random_port\":false,\"upnp\":false}" http://127.0.0.1:8080/api/v2/app/setPreferences'
- VPN_PORT_FORWARDING_DOWN_COMMAND=/bin/sh -c 'wget -O- -nv --retry-connrefused --post-data "json={\"listen_port\":0,\"current_network_interface\":\"lo\"}" http://127.0.0.1:8080/api/v2/app/setPreferences'
```

This requires qBittorrent `WebUI\LocalHostAuth=false` (the call comes from
`127.0.0.1:8080` inside the netns). Compose changes need the guardrail updated
too; never put credentials in compose. Do **not** use
`VPN_PORT_FORWARDING_LISTENING_PORT` for torrents — qBittorrent advertises a
port the VPN does not know about.

**Searching (owner):** the stack already has the UIs — Prowlarr `:9696`,
Radarr `:7878`, Lidarr `:8686`, Bazarr `:6767`, qBittorrent `:8080`. They are
VM-only by design. From the clawbox desktop browse the VM address directly;
from a laptop use a tunnel (owner-only, never for the wife):

```bash
ssh -N -L 8080:192.168.122.10:8080 -L 9696:192.168.122.10:9696 \
       -L 7878:192.168.122.10:7878 -L 8686:192.168.122.10:8686 \
       -L 6767:192.168.122.10:6767 jordan@192.168.1.133
```

Terminal search through Prowlarr (run as root on clawbox; `.env` is `600
mediabot`; install `jq` once if absent: `apt-get install -y jq`):

```bash
set -a; . /opt/media-assistant/.env; set +a
curl -s -H "X-Api-Key: $PROWLARR_API_KEY" \
  "http://192.168.122.10:9696/api/v1/search?query=debian%2013&type=search" \
  | jq -r '.[] | [.indexer, ((.size/1073741824*10|floor)/10|toString)+" GiB", .title] | @tsv' | head -20
```

For everyday use, add indexers in Prowlarr once, connect Radarr/Sonarr in
Prowlarr → Settings → Apps, then let Radarr/Sonarr search and grab. For the
household, Jellyseerr (8b) is the only UI they see.

Use all of this only for content you have the rights to copy or distribute.

### 8k. If AirVPN assigns a different forwarded port (fix 52)

The artifacts are pinned to `37686`, the port reserved on 2026-11-15 in the
AirVPN **Client Area → Forwarded Ports** page (device `torrent`, Layer `IPv4`,
both `TCP` and `UDP`, local port = remote port = `37686`). AirVPN never writes
this value into the WireGuard `.conf`, so it is only known from that page. If
the reservation ever changes, reconcile with one of these two options:

1. **Preferable — change AirVPN, not the code.** Reserve the port the artifacts
   already carry (`37686`) and stop here. This keeps every artifact, the
   guardrail counts and this document accurate with zero edits.
2. **Otherwise edit the artifacts.** `37686` appears in exactly these places:

| File | Locations |
| --- | --- |
| `phase5_compose.yaml` | `FIREWALL_VPN_INPUT_PORTS=37686` (gluetun), `TORRENTING_PORT=37686` (qbittorrent) |
| `phase5_apply.sh` | the `AIRVPN_PORT=37686` canary, qBittorrent `Session\Port=37686` pre-seed, the idempotent `6881 -> 37686` migration, 2 `ufw deny` rows, the 8 `DOCKER-USER` statements that install 4 DROP rules (tcp+udp × `iptables`/`ip6tables`), the next-steps text |
| `phase5_diag.sh` | S3 `Session\Port=37686` checks/messages, S7 ufw + `DOCKER-USER` counts/messages, header comment |
| `phase5_guardrail_test.sh` | G8 compose/ufw/iptables/qBt assertions, G15 re-checks, G17 fix-52 block, G18 port-integrity checks |
| `phase5_manual_steps.md`, `PROJECT_MEMORY.md` | narrative only (no runtime effect) |

**Never run the substitution with an empty `NEW`.** An empty value turns
`FIREWALL_VPN_INPUT_PORTS=37686` into `FIREWALL_VPN_INPUT_PORTS=` and
`--dport 37686` into `--dport`, which aborts the in-VM provisioning under
`set -e` *after* the qBittorrent pre-seed and leaves the old 6-port
`DOCKER-USER` guard in place (diag then fails `inbound guard count = 6`).
Fix 54 makes that loud: `phase5_apply.sh` aborts before touching a rule when
the port is not numeric, diag fails a non-numeric `Session\Port`, and the
guardrail (G18) rejects an empty or mismatched port token.

**Do not hand-edit the qBittorrent conf while the container runs.** qBittorrent
writes its in-memory config over `qBittorrent.conf` on SIGTERM, so the edit is
reverted by the restart that loads it (fix 56). Apply now stops the container
before rewriting, inserts the key when absent, asserts the on-disk value in V4
and prunes `DOCKER-USER` rows for the previous port — just re-run apply.

One-shot substitution, then re-verify (run as `jordan`; the guardrail is
read-only and does **not** need root):

```bash
cd /home/jordan/Documents/SystemBuild
NEW="${NEW:?set NEW to the AirVPN-assigned port (1-65535) first}"
case "$NEW" in ''|*[!0-9]*) echo "NEW must be numeric"; exit 1;; esac
[ "$NEW" -ge 1 ] && [ "$NEW" -le 65535 ] || { echo "NEW out of range"; exit 1; }
sed -i "s/37686/${NEW}/g" phase5_compose.yaml phase5_apply.sh phase5_diag.sh \
    phase5_guardrail_test.sh phase5_manual_steps.md PROJECT_MEMORY.md
for f in phase5_*.sh; do bash -n "$f" || echo "SYNTAX FAIL: $f"; done
bash phase5_guardrail_test.sh                    # G18 rejects empty/mismatched ports
sudo bash phase5_step1_install.sh                # refresh the root copies
sudo bash /usr/local/sbin/phase5/phase5_apply.sh # pre-seed + migrate + re-create the VPN pair
sudo bash /usr/local/sbin/phase5/phase5_diag.sh  # expect VERIFY_FAILS=0
```

`NEW=37686` is a no-op; the `case`/range guard is what stops the empty-value
accident. The `sed` is otherwise safe because `37686` is not used for anything
else in these files. It also rewrites this section, so 8k reads back with the
new value — expected, not a bug. A wrong port is **not** a leak: it only means
inbound peers cannot reach qBittorrent, so downloads rely on outbound
connections and seeding is poor; the kill-switch and the LAN posture are
unaffected.

If the port changes **after** the stack is already running, apply migrates
`6881` and repairs an empty/non-numeric `Session\Port`, but it will not rewrite
some *other* valid old port. Set it directly (inside the VM) and restart
qBittorrent:

```bash
# inside media-vm, as root; OLD = the value currently in the file
OLD=37686 NEW=<assigned-port>
sed -i "s/^Session\\\\Port=${OLD}\$/Session\\\\Port=${NEW}/" \
    /data/config/qbittorrent/qBittorrent.conf
docker restart qbittorrent
```

Or set it in the UI (**Settings → Connection → Listening Port**) — qBittorrent
rewrites the same key. Then re-run the host diag (S3 selects the new port, S7
expects the matching `ufw`/`DOCKER-USER` rows) and remove any stale rows left
from the old port with `ufw delete deny …` / `iptables -D DOCKER-USER …`.

---

## Step 9 — Migrating or exporting the stack later (DOCS ONLY — nothing to run now)

**Status:** reference. This step changes no file, no unit and no `ufw` row; the
live posture and every guardrail count stay exactly as they are. It exists so a
future move to a bigger disk or a different machine is a planned change instead
of an improvised one.

**The one sentence to remember:** the applications are already Docker; the
library is just a filesystem. You never convert a partition into a container —
you copy the filesystem and point the same Compose project at it.

### 9a. What is portable and what is not

| Piece | Lives in | Moves with | Notes |
| --- | --- | --- | --- |
| Application definitions | `phase5_compose.yaml` | copy the file | Pinned images, no `latest` |
| Images themselves | Docker on media-vm | re-pull, or `docker save` | Public tags, so a re-pull is usually enough |
| Library + app configs | ext4 `/data` on the raw LV | `rsync -aH`, `tar`, or clone the LV | **Always on one filesystem** — see 9e |
| VM definition | libvirt XML | `virsh dumpxml` / re-run apply | Tied to this host |
| Host glue | ufw rows, `jellyfin-lan-proxy.*`, socat, Caddy, udev `UDISKS_IGNORE`, `media-vm-lan-guard` | **manual re-create** | Enforced by the scripts, not by Docker |
| Addresses / IDs | `192.168.1.133`, `192.168.122.10`, `eno1`, PUID/PGID `1001` | **edit the constants** | See 9f |

### 9b. Path A — same shape on another machine (VM + Docker)

Best when the destination also runs Linux with KVM/libvirt and you want to keep
the current isolation model (VPN netns inside a guest, host pivot guard).

1. Copy the four artifacts plus `phase5_step1_install.sh` to the new host.
2. Edit the constants in 9f, then `bash phase5_step1_install.sh` and run
   `phase5_apply.sh` — it creates the VM, the network and the host units from
   scratch. Do **not** copy the old qcow2 unless you also want the old OS state.
3. Stop the old stack, move `/data` (9e), start the new one.
4. Re-point the LAN bookmark/`/etc/hosts` entry if `192.168.1.133` changed.

### 9c. Path B — bare-metal Docker on the destination (no VM)

This is the simplest "install it on another machine" answer, and it works,
but it trades away the guest boundary.

1. Attach the LV/disk (or restore the files into a directory) and mount it at
   `/data`; `chown -R 1001:1001 /data` if you keep the same IDs, or change
   `PUID`/`PGID` in Compose to the destination owner and `chown` once.
2. Install Docker + Compose, copy `docker-compose.yml` to `/opt/media-stack/`,
   copy `vpn.env` separately as `0600 root:root` (never inside the repo).
3. `docker compose up -d` (add `--profile vpn` only once real credentials are
   in place). Starting without the `vpn` profile keeps `gluetun`/qBittorrent
   down — same credential gate as the VM.
4. Requirements the destination must satisfy: `NET_ADMIN` + `/dev/net/tun` for
   gluetun (some NAS Docker UIs block or hide this, and Synology/QNAP need
   extra configuration), outbound UDP for the tunnel, and `/dev/dri` if you
   want Jellyfin hardware transcoding.
5. Expected loss: the *arr apps and Jellyfin now run on the host instead of in
   a guest. qBittorrent is still isolated inside gluetun's netns, so the
   kill-switch itself survives. This is a deliberate, documented downgrade —
   not a silent one.

### 9d. Path C — offline appliance bundle

For a destination with no registry access, or for cold storage:

```bash
# inside media-vm, as root
cd /opt/media-stack
docker compose config --images            # or: docker-compose config --images
docker save $(docker compose config --images) | zstd -T0 > /mnt/backup/stack-images.tar.zst
cp /opt/media-stack/docker-compose.yml    /mnt/backup/
```

Restore with `zstd -dc stack-images.tar.zst | docker load`. Add the `/data`
copy from 9e and you have a complete offline restore set. This is a
**transport/backup format**, not a one-click installer: ufw, the socket
proxies, the Caddy bind and the addresses are still host work.

`vpn.env` is a secret. Move it out-of-band (root-only channel), never inside a
shared tarball, and keep it `0600 root:root` at both ends.

### 9e. Moving the data — where migrations actually fail

**Stop the apps first.** Radarr/Sonarr/Prowlarr/Jellyseerr keep SQLite
databases; copying them while running can produce a torn database.

```bash
# inside media-vm
cd /opt/media-stack && sudo docker compose stop
```

Then pick one method:

| Method | Command shape | When |
| --- | --- | --- |
| **rsync (recommended)** | `rsync -aH --numeric-ids /data/ /mnt/backup/data/` | Any destination with a filesystem |
| tar | `tar -C /data -cpf - . \| zstd > /mnt/backup/data.tar.zst` | Cold archive; restore with `tar -C /data -xpf -` |
| Clone the block device | `dd if=/dev/ubuntu-vg/media of=/mnt/backup/media-data.img bs=4M status=progress` | Byte-identical clone; needs ~90 GiB free |

From the host, the pull equivalent uses the dedicated deploy key (root only):

```bash
rsync -aH --numeric-ids \
  -e "ssh -i /etc/media-vm/deploy_ed25519 -o UserKnownHostsFile=/etc/media-vm/known_hosts" \
  --rsync-path="sudo rsync" \
  jordan@192.168.122.10:/data/ /mnt/backup/data/
```

**Rules that matter more than the command:**

* `-aH` / `-H` is not optional. `torrents` and `media` are intentionally on the
  same filesystem so completed downloads are **hardlinked** into the library.
  A copy without hardlink support duplicates every title and silently doubles
  disk use.
* Restore both trees onto **one** filesystem mounted at `/data`. Splitting
  `/data/torrents` and `/data/media` across two mounts breaks hardlinking and
  atomic moves.
* `--numeric-ids` keeps `1001:1001` (a UID with no passwd entry). If you change
  it, change `PUID`/`PGID` in Compose **and** `chown -R` once.
* Copy the whole `/data`, including `/data/config` — that is where the Servarr
  databases, API keys and Jellyseerr users live.
* Verify before deleting the source:

```bash
findmnt -no FSTYPE,SOURCE /data                    # ext4, the expected device
find /data -xdev -type f -links +1 | wc -l         # >0 means hardlinks survived
stat -c '%h %n' /data/media/movies              # spot-check a real title
du -sh /data; df -h /data                          # used ≈ copied, not doubled
```

**What the LV is and is not.** `/dev/ubuntu-vg/media` is a raw LV, not a file.
A destination with LVM can `vgimport`/`lvchange -ay` it directly; a destination
without LVM uses `dd` into a `.img` (mount with `-o loop`) or — normally the
right answer — rsyncs the *contents* out of the mounted filesystem. Do not
`mkfs` the destination while the source still holds the only copy.

### 9f. Host constants to change on a new machine

The scripts assert exact literals, so a migration edits these and re-runs the
guardrail — it is a reviewed fix, never a hand-edit of the live host.

| Constant | Current value | Appears in |
| --- | --- | --- |
| `VM_IP` | `192.168.122.10` | apply, diag, guardrail, compose, manual |
| LAN address / bind | `192.168.1.133` | apply (units, socat, Caddy), diag, guardrail |
| LAN interface | `eno1` | ufw rows, discovery relay |
| `VM_MAC` → static DHCP | `52:54:00:6d:65:6d` | apply, diag |
| `MEDIA_LV` | `/dev/ubuntu-vg/media` | apply, diag, guardrail |
| `VM_NAME` | `media-vm` | everywhere |
| Stack UID/GID | `1001` | compose, apply, diag, guardrail |
| Published ports | `8096`, `7359/udp`, (`8443`, `5055`, `8989` after Step 8) | all four artifacts |
| Image pins | gluetun `v3.40.0`, qBt `5.0.4`, etc. | compose + guardrail |

Practical rule: hoist these to one block at the top of each script before the
move. Until then, grep for them — `grep -n '192\.168\.' phase5_*.sh
phase5_compose.yaml` is the checklist.

### 9g. Post-migration verification

Run these on the destination before trusting it (root where required):

```bash
docker compose ps                                  # every expected container Up/healthy
docker compose config --images                     # no :latest
ss -ltnp | grep -E ':(8096|7359|8443|5055|8989)\b' # exact binds, never 0.0.0.0/[::]
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.1.133:8096   # LAN 302/200
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.1.133:8080   # MUST refuse/000
# inside the VM/host: the pivot probe must still be blocked
ping -c1 -W3 192.168.1.1                           # expect no replies
# with the VPN profile up:
docker exec gluetun cat /tmp/gluetun/forwarded_port # must match qBt Connection tab
```

Then play one title through Jellyfin and complete one Jellyseerr request. A
migration is done when media plays, not when `docker ps` is green.

### 9h. Rollback

Keep the source LV/disk **untouched and unmounted** until 9g passes; the
cheapest rollback is always "start the old stack again". Do not delete the old
`/data`, the old qcow2, or the old LV until the new host has played a title and
served a request.

### 9i. Optional prep worth doing now (no change to the live posture)

1. Keep `/data` as **flat bind mounts**; never move the library into named
   Docker volumes — named volumes make export and backup harder.
2. Keep `torrents` and `media` as siblings on one filesystem.
3. Add a monthly read-only snapshot job when convenient:

```bash
rsync -aH --numeric-ids --delete /data/ /mnt/backup/data/
docker compose -f /opt/media-stack/docker-compose.yml config > /mnt/backup/stack.yml
```

That pair is a complete, restorable definition + library snapshot — and it is
the same command a future migration uses.

---

## Step 10 — First-run operator runbook (Jellyfin / Jellyseerr / Radarr / qBittorrent)

Everything here is **owner work**: run it from the SSH tunnel below (or directly
on `clawbox`), never from a family device. Nothing in this step changes the
scripts, and none of it requires re-running the apply.

```bash
ssh -N -L 8080:192.168.122.10:8080 -L 9696:192.168.122.10:9696 \
       -L 7878:192.168.122.10:7878 -L 8989:192.168.122.10:8989 \
       -L 8686:192.168.122.10:8686 -L 6767:192.168.122.10:6767 jordan@192.168.1.133
```

UI map: qBittorrent `:8080` · Prowlarr `:9696` · Radarr `:7878` · Sonarr
`:8989` · Lidarr `:8686` · Bazarr `:6767` (all `http://localhost:<port>` through
the tunnel). Family UI stays `https://192.168.1.133:8443`.

**URL rule for every app-to-app field** (download clients, Jellyseerr services,
Bazarr, Connect hooks): use the compose **service name** (`gluetun`, `jellyfin`,
`radarr`, `sonarr`, `prowlarr`, `lidarr`) with plain HTTP and an **empty URL
Base**. `192.168.122.10:<port>` hangs from inside a container (the packet enters
the VM `INPUT` chain with a `172.18.0.x` source, which `ufw` does not allow) and
`192.168.1.133` is blocked by the VM→LAN pivot guard. See §8c.

### 10a. Make a Request actually download

A Jellyseerr request does not touch torrents; it asks Radarr to add the movie and
search. Four preconditions, all inside Radarr/Jellyseerr:

1. **Download client.** Radarr → *Settings → Download Clients* →
   *+ → qBittorrent*:

   | Field | Value |
   | --- | --- |
   | Name | `qBittorrent` |
   | Enable | on |
   | Host | `gluetun` |
   | Port | `8080` |
   | Use SSL | off |
   | URL Base | *(empty)* |
   | Username / Password | qBittorrent WebUI credentials (10b) |
   | Category | `radarr` |

   **Test** → *"Test was successful"* → **Save**. `401` = wrong qBt credentials ·
   timeout/`ENOTFOUND` = an IP or `http://` in Host · `ECONNREFUSED` = qBt stopped
   (an apply run stops it briefly).

2. **Indexers.** Radarr → *Settings → Indexers*. With Prowlarr `Full Sync` they
   arrive automatically (Prowlarr badge, not editable here). If the list is
   empty, searches can never succeed: Prowlarr → *Indexers → Add Indexer*,
   **Test** each, then *Settings → Apps → + → Radarr* with Prowlarr Server
   `http://prowlarr:9696`, Radarr Server `http://radarr:7878`, Radarr's API
   key, Sync Level `Full Sync` → Test → Save (saving syncs; otherwise click the
   sync icon on the Radarr row). The form pre-fills *localhost* for both URLs —
   that is wrong in containers and is the usual silent failure.

   Order matters: **indexers first, app second.** With no indexers in Prowlarr
   there is nothing to sync and Radarr's list stays empty (verified live
   2026-11-17: Prowlarr had 0 indexers, 0 apps, Radarr 0 indexers).

   Public-indexer reality (checked 2026-11-17, keyless, from the VM):

   | Indexer | Result | Note |
   | --- | --- | --- |
   | **YTS** | works | movies only; enough for the movie path |
   | EZTV | `blocked by CloudFlare Protection` | needs FlareSolverr, which this stack does not run — skip |
   | 1337x | `Name does not resolve (1337x.to:443)` | the `.to` domain is dead/NXDOMAIN; DNS itself is fine (YTS resolved) |

   One working indexer is enough to prove the chain. Do **not** add a torrent
   client's indexers by hand in Radarr: anything added there lives outside the
   Prowlarr sync. Cloudflare-fronted definitions would need a `flaresolverr`
   service — a compose + apply change (fix-tracked), not a `docker run`
   side-car; the guardrail pins the service set, so it must go through apply.
   Verify the sync landed: indexer count in Radarr equals the number of enabled
   Prowlarr indexers.

3. **Root folder + hardlinks.** Radarr → *Settings → Media Management*: root
   folder `/data/media/movies`, **Use Hardlinks instead of Copy** on.

4. **Auto-approve.** Jellyseerr → *Settings → Users*. The owner account
   auto-approves (a click searches immediately); family accounts default to
   **Pending** until approved under *Requests* (10c sets the permissions
   deliberately).

### 10b. qBittorrent WebUI password

**The config file is in the `qBittorrent/` subdirectory** — this matters more than
it sounds:

| Path | Read by qBittorrent? |
| --- | --- |
| `/data/config/qbittorrent/qBittorrent/qBittorrent.conf` | **yes** (the image runs with `$HOME=/config`; its service script greps `WebUI\Address` here) |
| `/data/config/qbittorrent/qBittorrent.conf` | **no** — an artifact of an earlier `phase5_apply.sh`; retired by fix 72 |

Anything written to the second path looks verified (you read your own value
back) and changes nothing. `phase5_diag.sh` now fails if that duplicate exists.

**Set the password with the script, not the GUI:**

```bash
sudo bash qbt_admin.sh --set-password
```

One atomic operation, in this order because each step protects the next:

| Step | What it does |
| --- | --- |
| 1/5 | logs in with the current credential **from the host** (a different source IP than Radarr, so a Radarr ban cannot block the repair) |
| — | `POST /api/v2/app/setPreferences` → `web_ui_password` (plaintext over the VM-only port; qBittorrent hashes it with PBKDF2 itself) and proves it with a **fresh login** |
| 2/5 | **waits until `Password_PBKDF2` in the real conf has changed** and aborts *without restarting* if it does not — settings are buffered and written ~5 s late, so a restart inside that window loses the password (**fix 73**) |
| 3/5 | stores it in `/etc/media-vm/qbt_webui_password` (**600 root:root**) and `PUT`s it into Radarr with `?forceSave=true` (its save-time test would fail while the ban is live) |
| 4/5 | restarts qBittorrent (the login-ban list is in memory only) |
| 5/5 | logs in **again** with the stored password, then requires Radarr's own `testall` to print `isValid=True` |

Read the value with `sudo cat /etc/media-vm/qbt_webui_password`; every helper
reads it automatically (`$QB_PASS` first, then that file, then the container log,
then a prompt) and **self-heals** the file if a stale copy is ever rejected.
Re-running is idempotent. `QB_NEW_PASS=...` supplies your own (minimum 12
characters), `--no-restart` skips step 4.

**Why this replaces the temporary password (fix 71).** With no password
configured, qBittorrent prints a **session-scoped** temporary password on every
start, so any container recreate — including every `phase5_apply.sh` run —
invalidates what Radarr stored. Radarr then retries the old value every ~60 s,
bans its own source IP after 5 failures for `BanDuration` (3600 s), and reports
the ban as a plain `Authentication Failure`. That is the whole incident class;
one permanent credential removes it.

Invariants while you are in that UI:

- **Never change the listen port** — it stays `37686` (apply V4 asserts it; a
  change breaks the AirVPN forward).
- *Settings → Connection* → "Use UPnP / NAT-PMP" stays **off**.
- Never change the password **in the UI** without Radarr: a half-done change
  re-creates the ban within a minute. Use the command above.

If the script reports that the password is live but not on disk, do **not**
restart qBittorrent (that is what loses it); check that uid 1001 can write
`/data/config/qbittorrent/qBittorrent/qBittorrent.conf` and re-run.

If the temporary line is gone and you have no password file (e.g. an older
install), reset it — **stop the container first** (qBittorrent dumps its
in-memory conf on SIGTERM; see §3j) — and delete the hash from the **real** path:

```bash
sudo docker stop qbittorrent
sudo sed -i '/^WebUI\\Password_PBKDF2=/d' /data/config/qbittorrent/qBittorrent/qBittorrent.conf
sudo docker start qbittorrent
sudo docker logs qbittorrent 2>&1 | grep -i temporary
```

…then run `--set-password` so it never happens again.

**Scripted fix when Radarr says `Authentication Failure` (2026-11-19).** Radarr
keeps the qBt password in its download-client entry, so if qBt is still on the
temporary password and Radarr was given a different one, every grab parks as
`downloadClientUnavailable` and qBittorrent never receives a torrent. The helper
copies qBt's **current** credential (the temp line from the container log, or
`QB_PASS` if exported) into Radarr's client entry without printing it, then
re-tests through Radarr's own `testall`:

```bash
sudo bash library_status.sh "breakfast club" --fix-client-password
sudo bash library_status.sh "breakfast club" --retry      # clears the parked grab, re-searches
```

The secret goes to a `0600` file in the helper's private temp dir, never to a
command line (`/proc/<pid>/cmdline` is readable). If the temporary password line
is gone, the flag exits **4** — set a permanent password in the UI first, then
`export QB_PASS=...` for the run (or update Radarr's entry by hand).

**A ban looks like a wrong password (fix 67).** qBittorrent bans a **source IP**
for an hour after five failed logins (defaults `MaxAuthenticationFailCount=5`,
`BanDuration=3600s`) and keeps the ban map **in memory**. Every login during the
ban answers 403 *"Your IP address has been banned…"*, which Radarr shows as a
plain `Authentication Failure` — and because Radarr retries on each queue
refresh, its container IP stays banned while a host-side helper logs in fine.
Clear it by restarting the container (`sudo bash library_status.sh "title"
--fix-qbt-auth`), then sync the credential and retry. **The restart alone does
not turn `testall` green** when the credential was never saved (the earlier
`PUT` answered 400 because the save is tested through the banned IP): expect
`isValid=False` on that run and treat the **`202` from `--fix-client-password`**
as the success signal, followed by `isValid=True` and then `--retry`'s
`DELETE … 200` / `POST command … 201`.

### 10c. Categories and hardlink layout

qBittorrent left sidebar → **Categories**:

- `radarr` → *Edit category* → Save path `/data/torrents/movies`
  (create it if absent).
- `sonarr` → Save path `/data/torrents/tv` (when Sonarr is wired, 10e).
- *Settings → Downloads → Default Save Path* = `/data/torrents`; the incomplete
  folder must live under `/data/torrents` as well. Everything is on the one ext4
  volume — that is what makes hardlinks possible.

**Then run the first-run helper (fix 69).** Radarr sends only a category, no
save path, so qBittorrent files the torrent in *manual* mode — and in that mode
the category path is ignored unless `Session\UseCategoryPathsInManualMode` is
true (default false). Skip this and `torrents/movies/` stays empty while
everything lands in `/data/torrents` (still hardlinkable, just not where the
layout says). One idempotent command does all three steps:

```bash
sudo bash qbt_admin.sh --first-run
```

| Step | What it does | Why it can fail silently |
| --- | --- | --- |
| 1/3 | `radarr` category → `/data/torrents/movies` | `createCategory` answers 409 for an existing name and **does not** change the path (falls back to `editCategory`) |
| 2/3 | Radarr client field `movieCategory = radarr` | writing a field named `category` returns **202** and is dropped |
| 3/3 | `use_category_paths_in_manual_mode = true` | the path is ignored until this is on, whatever the category says |

The individual commands remain available (`--create-category`,
`--set-radarr-category`, `--fix-category-paths`); the last one applies the
preference live (no restart), verifies it by reading it back, and exits 2 if a
category still has no `savePath`. All of it affects **new** adds only.

**fix 70/72 — the durable copy is `qBittorrent.conf`, and only the one in the
`qBittorrent/` subdirectory counts.** Settings are buffered in memory and written
~5 s after a change (`SettingsStorage`), so a live API write can be lost by a
recreate — but the deeper trap was the path: the file *without* the subdirectory
is never read, so writes there were invisible no matter how they were verified
(observed 2026-11-20: live `True` before `up -d`, `False` after, while the
ignored file said `true`). `phase5_apply.sh` writes
`Session\UseCategoryPathsInManualMode=true` into
`/data/config/qbittorrent/qBittorrent/qBittorrent.conf` **while qBittorrent is
stopped**, `phase5_diag.sh` S3 fails if the key is absent/`false` **or** if the
ignored duplicate exists, and `qbt_admin.sh --status` prints both candidate paths
with their keys. If the live value reads `False` after a rebuild, the apply step
was skipped — re-run apply, then `--first-run`.

### 10d. End-to-end test + hardlink proof

1. Request one small, popular, well-seeded movie in Jellyseerr.
2. Radarr → *Activity → Queue*: appears within ~10 s, then *Downloading*.
3. qBittorrent: torrent present with category `radarr` and save path
   `/data/torrents/movies` (with `--fix-category-paths` applied; a torrent added
   before that keeps the old `/data/torrents` location — harmless, still the same
   filesystem).
4. On completion Radarr shows **Imported** and the file exists under
   `/data/media/movies`.

**The hardlink is a Radarr SETTING, and it is on by default here (fix 76).**
The same-ext4 layout only makes it possible; *Settings → Media Management → “Use
Hardlinks instead of Copy”* (`copyUsingHardlinks`) decides, and
`library_status.sh` prints it in every run — do not assume, read it:

```bash
sudo bash library_status.sh "any title"                   # prints the policy
sudo bash library_status.sh "any title" --fix-hardlinks   # flip + prove it
```

**Do not read a doubled `/data` as a copy import.** After an import, the fix-59
normalizer writes a new file and renames it over the library path, so the library
inode is replaced and the torrent's copy becomes a second, independent one. That
is expected: 2026-11-20, two titles totalling 14.8 GiB took `/data` 41 G -> 61 G
*with* `copyUsingHardlinks=True`, because both had already been remuxed. The
inode is the evidence, not the gigabyte count:

- import **not yet remuxed** → library file and torrent file share one inode,
  `links 2`, and `--remove-torrent` returns ~nothing;
- import **already remuxed** (`remux:`/`done:` in `/var/log/media-normalize.log`)
  → two inodes, `links 1`, and removing the torrent returns its full size.

So the space comes back when you remove the completed torrent — that is the
normal end of the flow, not a misconfiguration. What the hardlink buys you is the
**peak**: during the remux it is 2 copies (original shared + new output) instead
of 3 (original + imported copy + new output), which is the difference between
finishing and `skip(space)` on a small disk.

To answer “is *this* file normalized, and is it a hardlink?”:

```bash
sudo bash check_normalize.sh                       # newest library file
sudo bash check_normalize.sh "/data/media/movies/X (2024)/X (2024) ....mkv"
```

It prints the stream counts (target `audio 1 / subs 0`), the log tail, the
in-file temp of a running remux, and inode + link count + any `/data/torrents`
file sharing that inode. Note that a fix-59 remux replaces the library inode, so
`n=1` there is the expected end state, not a failed import.

**If Radarr's queue row disappears while the torrent keeps going, the torrent is
an orphan** — Radarr drops a tracked download when its download client is
unreachable ("download was not found in the client"), and nobody imports it
afterwards. Fix the credential (`qbt_admin.sh --set-password`), then **look at
the queue again before importing**: once the client answers, Radarr normally
**re-adopts** the torrent (the queue row returns, `downloading / downloading`)
and imports it itself. Observed 2026-11-20 on both requested titles — the
"orphan" verdict was correct when printed and wrong ten minutes later, because
the repair had restored the client.

Only if the row is **still** absent when the torrent completes:

```bash
sudo bash qbt_admin.sh --import-downloads "/data/torrents/<torrent folder>"
```

`--import-downloads` now **refuses** while Radarr is tracking any active
download (fix 75); `--force` overrides that, and you should only want it after
`library_status.sh` says the title is an orphan. That queues Radarr's
`DownloadedMoviesScan` on the folder and imports what it recognises
(manual-import path — no queue row needed). Only `/data/torrents` is accepted.
Radarr resolves the manual mode to **Move**, so with hardlinks on it hardlinks
into the library and unlinks the torrent's copy: no data is duplicated, but the
torrent then reports missing files and `--remove-torrent` will not return space
(the library holds the inode). Do not run it while the torrent is still
incomplete — Radarr would import a partial file.

One command on the VM (jordan can read `/data`) groups duplicates by inode:

```bash
find /data/torrents /data/media -type f -name '*.mkv' -printf '%i %n %p\n' | sort -n
```

Expect the same movie **twice, same inode, `n=2`**:

```
1234567890 2 /data/media/movies/Some Movie (2024)/Some.Movie.2024.1080p.mkv
1234567890 2 /data/torrents/movies/Some.Movie.2024.1080p.mkv
```

`n=1` with different inodes means Radarr **copied**: re-check the category save
path (10c) and that Radarr's root folder is `/data/media/movies`, not a
`/data/torrents/...` path.

Failure map: queue stays empty / *Unable to find releases* → indexers (10a.2) ·
downloads but will not import → path mismatch (10a.3/10c) · request never reaches
Radarr → Jellyseerr *Settings → Services → Radarr* test, or the request is still
*Pending*.

### 10e. Family-facing

**CA install.** The file is in a root-only directory, so stage a readable copy on
`clawbox` first:

```bash
sudo install -o jordan -g jordan -m 644 /etc/media-vm/family-media-ca.crt /home/jordan/family-media-ca.crt
scp jordan@192.168.1.133:/home/jordan/family-media-ca.crt .   # from the laptop
```

| Platform | Steps |
| --- | --- |
| iPhone / iPad | Open the `.crt` → *Profile Downloaded* → Install → then **Settings → General → About → Certificate Trust Settings** → enable full trust for **Family Media CA** (the second step is the commonly missed one) |
| Android / Fire TV / Android TV | Settings → Security (or *Security & privacy → More security settings*) → *Encryption & credentials* → *Install a certificate* → **CA certificate** → *Install anyway* → pick the file |
| macOS | Double-click → Keychain Access → *System* → **Family Media CA** → Get Info → Trust → **Always Trust** |
| Windows | Double-click → *Local Machine* → *Place all certificates in the following store* → **Trusted Root Certification Authorities** |
| Firefox (any OS) | Settings → Privacy & Security → Certificates → *View Certificates → Authorities → Import* → trust for websites |

Verify: `https://192.168.1.133:8443` loads with no warning.

**Jellyfin on TVs and consoles.** The app needs the server address exactly once:

```
http://192.168.1.133:8096
```

Plain HTTP (8096 is HTTP-only — no certificate, no warning). Never
`192.168.122.10:8096` (VM-internal; only clawbox can reach that) and never
`:8443` (that is Jellyseerr's request UI, not the player).

| Client | Where it goes |
| --- | --- |
| Android TV / Google TV / Fire TV | *Add Server* → host `192.168.1.133`, port `8096` |
| LG webOS / Samsung Tizen | *Enter Server Address* → the full `http://192.168.1.133:8096` |
| Apple TV / iOS | *Add Server* → the same URL |

The client stores the server after the first successful connect, so the prompt
appears once per device. Different profiles on the same TV reuse it.

**Client/server version match (fix 58).** The sideloaded Tizen build must be
compiled against the server's major line: the build of record is
`Jellyfin for Tizen 0.1.0 … with Jellyfin-12.z`, so the server is pinned to
**`jellyfin/jellyfin:12.4`**. A 12.z client against a 10.10.x server renders the
library (posters, *Recently Added*) but fails **every** play request with a
generic error, because the request never reaches `PlaybackInfo`. `jeppevinkel/
jellyfin-tizen-builds` only publishes `Jellyfin-12.z.wgt` and
`Jellyfin-10.11.z.wgt` now — the old `10.10.z` asset is only in archived
releases. Confirm the pairing in *Dashboard → Devices* (the `Devices` row shows
the app's compile line) and with the version probe in Step 10h.

**Auto-discovery** (the server lists itself, no typing) requires
`DISCOVERY_MODE=broadcast` **and** the `7359/udp` publish added by fix 57 — see
Step 3. Apps that were already open must be closed/reopened to re-scan. Set the
Jellyfin **server name** first, otherwise the list shows the container ID
(`533eb713f16e`). Sign-in without a remote keyboard: enable *Dashboard → Quick
Connect*, then on the TV choose *Quick Connect* and approve the 6-digit code
from a phone/laptop.

**Jellyfin users.** *Dashboard → Users → + Add User*: username/password, uncheck
*Allow this user to manage the server*, allow the libraries. Keep the admin
account for configuration only.

**Jellyseerr users.** *Settings → Users → Import Jellyfin Users*, then per
family user: **Request** on · **Auto-Approve** off · *Manage Requests / Manage
Users / Admin* off · **Request 4K** off. The owner keeps auto-approve. Approve
family requests under *Requests*.

**Jellyseerr Application URL.** *Settings → General → Application URL* =
`https://192.168.1.133:8443` → Save. Otherwise links point at `localhost:5055`.

**Jellyfin server name.** *Dashboard → General → Server Name* → e.g.
`Family Media`. It defaults to the container ID (`533eb713f16e`), which is what
TVs and Jellyseerr display.

**TV + Music libraries now.** *Dashboard → Libraries → Add Media Library*:
Shows → `/data/media/tv`, Music → `/data/media/music`. Empty is fine — it means
Sonarr imports land in an already-watched library later, with no rescan.

### 10f. Deferred / optional work

**Sonarr (skipped by choice).** When returning:

1. *Inside Sonarr*: *Settings → Media Management → Root Folders → + Add Root
   Folder* → type `/data/media/tv`.
2. *Settings → Download Clients* → qBittorrent, host `gluetun`, port `8080`,
   category `sonarr`.
3. Prowlarr → *Settings → Apps → + → Sonarr* → `http://prowlarr:9696` /
   `http://sonarr:8989` / API key / `Full Sync` → Test → Save.
4. qBittorrent category `sonarr` → `/data/torrents/tv`.
5. Jellyseerr → *Settings → Services → Sonarr → Add Server*: hostname `sonarr`,
   port `8989`, **Use SSL off**, API key, **URL Base empty** → Test →
   `HD-1080p` · `/data/media/tv` · Series Type `Standard` · Scan + Automatic
   Search on.

If the Test still fails with `fetch failed`, it is a **URL field**, not the key
(undici reports TLS/URL/DNS problems with that string; a bad key logs
`Unauthorized`). Inspect the saved entry (prints no secrets):

```bash
sudo docker exec jellyseerr node -e '
const s=JSON.parse(require("fs").readFileSync("/app/config/settings.json","utf8")).sonarr||[];
for (const x of s) console.log(JSON.stringify({hostname:x.hostname,port:x.port,useSsl:x.useSsl,baseUrl:x.baseUrl,apiKeyLen:(x.apiKey||"").length}));'
```

**Bazarr (subtitles).** *Settings → Radarr*: Address `radarr`, Port `7878`,
Base URL `/`, API key, SSL off; then *Sonarr* similarly. *Settings → Languages* →
add a profile and set it default; *Settings → Providers* → add OpenSubtitles.com
(account) or a keyless provider. Leave path mappings empty — `/data/media` is
identical across containers by design.

**Lidarr (music, owner-only).** Root folder `/data/media/music`; download client
qBittorrent host `gluetun` port `8080` category `lidarr` (qBt save path
`/data/torrents/music`); Prowlarr → *Settings → Apps → + → Lidarr*
(`http://lidarr:8686`). Nothing in the family flow depends on it.

**§5 peer-health check (plan file).** AirVPN *test open* green on both rows;
qBittorrent status `Connected` (not `Firewalled`); then, inside media-vm:

```bash
sudo docker exec gluetun awk '$2 ~ /:9336$/ {print $4}' /proc/net/tcp | sort | uniq -c
# 0A = the fix-56 listener proof, 01 = established peers
sudo docker exec gluetun ip -4 -o addr show dev tun0
```

Record the outcome in `PROJECT_MEMORY.md` under the fix-56 entry.

**Jellyfin Connect hook from Radarr (optional).** Jellyfin → *Dashboard → API
Keys → +* (name `radarr`) → Radarr → *Settings → Connect → + → Emby / Jellyfin*:
host `jellyfin`, port `8096`, SSL off, that key, notify on Import/Upgrade/Rename
→ Test → Save. New imports then appear in Jellyfin within seconds instead of on
the scheduled scan.

### 10g. Done criteria

The stack is "operational for the household" when: one requested movie
downloaded through qBittorrent, hardlinked (`n=2`, same inode), visible and
playable in Jellyfin via `http://192.168.1.133:8096`; `https://192.168.1.133:8443`
loads without a certificate warning on the main family devices; and family
Jellyseerr accounts can request (pending approval). Everything else in Step 10 is
polish and can wait indefinitely.

### 10h. Jellyfin 12.4 upgrade (fix 58 — required for the Tizen client)

Apply does this automatically; this section is the manual equivalent and the
post-upgrade checks. It exists because the 12.0 DB migration cannot be rolled
back and because **12.x requires a full library scan afterwards**.

1. **Confirm what is running** (read-only):
   ```bash
   curl -s http://192.168.122.10:8096/System/Info/Public | grep -o '"Version":"[^"]*"'
   sudo docker inspect -f '{{.Config.Image}}' jellyfin
   ```
   Want `12.4.x` and `jellyfin/jellyfin:12.4`. Apply's V6 and diag **S5** both
   fail on a mismatch, so a green run already proves this.
2. **Keep the backup.** Apply writes
   `/data/config/jellyfin-backup-<UTC>-pre-<old>.tar.gz` (600) before touching
   the database. Restore with `docker compose stop jellyfin`, unpack over
   `/data/config`, then pin the old image and `docker compose up -d` — only while
   no 12.x run has written to the DB.
3. **Full library scan is mandatory** (*Dashboard → Scheduled Tasks →
   “Scan Media Library” → ▶*). The 12.0 notes: alternative versions resolved
   automatically are dropped by the type change, and some movies can appear as
   *newly added* on the first scan. Expect the first scan to be slower.
4. **Plugins**: only built-in providers are installed (TMDb, Studio Images,
   OMDb, MusicBrainz, AudioDB), so there is nothing to remove first. Any
   third-party plugin added later must be re-added after the upgrade.
5. **Re-test the TV**: *Play* a title on the Tizen app. The 12.z client against
   a 12.4 server is the supported combination; if playback still fails, capture
   the wire (`diagnose_tv_playback.sh`) before changing anything else.

### 10i. Media normalization (fix 59 — one audio, no TrueHD, es-LA subtitles)

**What it does.** Every file that lands in `/data/media/movies` or
`/data/media/tv` is rewritten **once** to the shape this house plays:

| Stream | Policy |
| --- | --- |
| Video | untouched (`-c:v copy`) — no quality loss, no re-encode cost |
| Audio | **exactly one track**: the best non-commentary track in the film's **original language** (the language of the first non-commentary audio stream, which is what remuxes carry first). A codec the TV can decode is copied; **TrueHD / Atmos / DTS-HD are never copied** — they are re-encoded to **AC3 5.1 @ 640k** (MKV) or **AAC 5.1 @ 384k** (MP4) |
| Subtitles | **the Spanish tracks are kept**; every other subtitle language is dropped. Bazarr *additionally* supplies Latin American Spanish as an external `.srt` |
| Filename | never changes (same path/extension) so Radarr's file record stays valid |

**Why es-LA is still the preferred subtitle (fix 78 changed this).** An MKV tags
subtitles as `spa` — there is no es-ES vs es-419 distinction in the container, so
an embedded Spanish track may be Castilian. The original rule therefore dropped
**all** embedded subtitles. **The owner reversed that on 2026-11-20:** a Spanish
track that is present is worth keeping, and the embedded track is a fallback
while Bazarr's `Spanish (Latin America)` `.srt` is the preferred one (Jellyfin
serves an external `.srt` instantly — no demux pass over a 40 GB file).

So the normalizer now keeps `spa` / `es` / `es-XX` subtitle tracks (it never
treats `esp`, Esperanto, as Spanish) and drops the rest. Consequences to expect:

- `subs:2->2` in the log is **correct** when both are Spanish;
- `subs:2->0` is correct when neither was Spanish;
- a **non-Spanish** subtitle in a library file means the policy was not applied —
  diag S11 fails on it and prints the languages;
- titles normalized **before** 2026-11-20 (*Project Hail Mary*, *The Breakfast
  Club*, *Ferris Bueller's Day Off*) legitimately have **0** embedded subtitles.
  **Do not re-download or re-remux them for subtitles**; Bazarr covers them.

**So "the film has no subtitles" is two different questions (fix 77).** After a
remux the file may legitimately carry **0 subtitle streams**: either the source
had none in Spanish, or it was normalized under the old rule (before fix 78).
What matters for those titles is whether Bazarr put the external file beside it.
One command answers both, per title:

```bash
sudo bash bazarr_status.sh "ferris"      # a title term, not a hardcoded film
sudo bash bazarr_status.sh               # every movie Bazarr knows
```

The block to read is:

```
  profileId  : NONE  <-- Bazarr will NEVER search this movie
  missing    : ea, es, ea.hi, es.hi
  on disk    : 0 .srt — no sidecar beside the .mkv
  verdict    : MISSING — no Spanish subtitle at all
```

When files exist, the verdict names the **best row of the owner order** that is
present (`LatAm Spanish, non-HI (best)` → `Castilian Spanish, non-HI` →
`LatAm Spanish, HI` → `Castilian Spanish, HI`), and every sidecar is listed with
its classification. That ranking is read from the filename (`...es-MX.srt`,
`...es.srt`, `...es-MX.hi.srt`, `...es.hi.srt`), not guessed from the count.

`profileId: NONE` is the silent cause: with no language profile Bazarr computes
`missing_subtitles` as **empty**, so there is nothing "missing" to search for and
no error appears anywhere. Its scheduled job still logs *"Finished searching for
missing Movies Subtitles"* every 6 h — it simply has no candidates.

Observed 2026-11-20: **every** movie synced from Radarr was `profileId: NONE`,
so `--assign` per film would fix today and break again on the next request. Fix
the default once, then repair what is already there:

```bash
sudo bash bazarr_status.sh --default-profile   # future movies inherit profile 1
sudo bash bazarr_status.sh --assign-all        # profile + search-missing, each film
sudo bash bazarr_status.sh                     # expect on disk: N .srt + verdict present
```

Both are idempotent and both **re-read** the value afterwards (`POST` returning
204 means "accepted", not "stored" — and in this API a wrong *key shape* also
returns 204 and stores nothing, fix 81).

`--default-profile` posts **flat fields**, one per setting:
`settings-general-movie_default_enabled=true` and
`settings-general-movie_default_profile=1`. That is the only shape Bazarr's
`save_settings()` applies (`key.split('-')` must give 3 or 4 parts); a
`settings-general=<json>` blob is silently skipped. Because only the posted keys
are touched, other sections cannot be blanked, and the script refuses an
unrecognised `/api/system/settings` payload rather than posting blind.
A single film can still be done with `--assign "<title>"`.

If the write still reports `MISMATCH`, check the container's key format before
touching the payload:

```bash
sudo docker exec bazarr sh -c \
  'grep -n -A60 "def post" /app/bazarr/bazarr/api/system/settings.py'
```

A `verdict: LatAm Spanish, non-HI (best)` line means the family gets LatAm
Spanish from the sidecar even though the container may carry zero subtitle
streams. `LatAm Spanish, HI` means only a hearing-impaired track was available
(row 3); that still satisfies the profile's cutoff, but it is not the preferred
row. `missing:` lists what Bazarr still wants as `ea`, `es`, `ea.hi`, `es.hi`.

If the script says `MISSING` while a `.srt` is plainly beside the film, that is
fix 82 territory: the join is on the movie **directory** (`Bazarr` returns the
`.mkv` path, not a folder), so a false MISSING means the file is in a different
folder than Bazarr's `path`, not that the file is missing.

**How it runs.** Two units inside `media-vm`, both installed and enabled by
apply:

```bash
systemctl status media-normalize.timer   # sweep every 10 min
systemctl status media-normalize.path    # fires when a title appears
journalctl -u media-normalize -n 40      # unit view
sudo tail -n 40 /var/log/media-normalize.log   # per-file decisions
sudo systemctl start media-normalize.service   # force a sweep now
```

Safety properties (all asserted by guardrail **G21**/**G24** and diag **S11**):
`flock` serialises remuxes (3 vCPU — one at a time), a file must be quiet for
**120 s** before it is touched (never remux a half-copied import), the output is
written to a hidden `.name.norm.ext` temp and **verified** (1 audio, 0 subs, 1
video, and the **film stream's own** duration within 5 s) **before** the atomic
rename, and the original is **kept on any failure** — including low disk space.
ffmpeg comes from the already-pinned `jellyfin/jellyfin:12.4` image: no new
image, no new port.

> **First sweep and the 43 GB remux.** The gate is `1.05 × file size + 256 MiB`
> (the temp only holds the video stream plus one audio encode — the extra audio
> and subtitle tracks are never written), so the film needs ~42.4 GiB and starts
> as soon as `/data` has it. If you would rather choose the moment:
> `sudo systemctl stop media-normalize.timer` to pause, then
> `sudo systemctl start media-normalize.service` when nobody is watching (the
> copy is IO-heavy for ~10–20 min). Previous versions of this gate used 1.1×,
> which refused this film by ~1 GiB — that is why the log showed `skip(space)`.
> Note the hardlink trade-off: replacing the library copy leaves the torrent's
> copy (same inode until then) intact, so peak usage is about twice the title
> until qBittorrent removes the torrent.

> **fix 61 — why the first remux was rejected, and what the file really weighs.**
> On 2026-11-18 the sweep ran and logged
> `fail(verify a=1 s=0 v=1 dur=9654->9391): kept original`. The stream counts
> were already correct — the **duration** check was wrong: a remux's container
> duration is the **longest contained stream**, and this title carries a
> `02:40:54` German dub (`9654 s`) next to the `02:36:31` film (`9391 s`), plus
> an **mjpeg cover-art still** that also reports `9654 s`. The remux was correct
> and was thrown away, and because a failed verify writes no state marker the
> timer retried every 10 minutes. The check now compares the **primary video
> stream** of source and output (`probe_vdur`), and never `format=duration`.
>
> The same code carried a second, silent hazard: `-map 0:v:0` assumed the first
> video stream is the film. Many remuxes store the cover art first, so the old
> code would have written a ~100 KiB still with one audio track, passed the
> `1 video` count check, and replaced a 40 GiB film. The film is now the largest
> non-cover-art video stream (`mjpeg/png/bmp/gif/webp/ppm` and `attached_pic`
> excluded), mapped by absolute index `PLAN_VIDX`.
>
> **Expected size: ~32 GB, not ~12 GB.** (Measured 2026-11-18: 41 GB → **32 GB**,
> `dur:9391s->9391s`.) The video stream is copied
> byte-for-byte; only the audio/subtitle tracks are dropped. Verify with
> `bash check_normalize.sh` — the log should read
> `done: … (audio:1 subs:0 video:1 dur:9391s->9391s)` and the file should be
> ~32 GiB. If a title's runtime cannot be probed at all, the sweep logs
> `skip(no duration)` and leaves it alone rather than remuxing blind.
>
> **Reading the log after the fix:** S11 counts every `fail(` line still in
> `/var/log/media-normalize.log`, so the two pre-fix failures (`22:39:39Z`,
> `22:49:39Z`) keep it showing `[note] N normalizer failure line(s)` until the
> log rotates — even though the very next line is `done:`. Judge the newest
> line for the file, not the count.

**Bazarr version gate (fix 60).** OpenSubtitles.com answers **HTTP 426**
(`Bad status code: 426`, then Bazarr throttles the provider for 10 minutes) to
**any Bazarr below 1.5.4** — it is a *client-version* gate, not credentials,
quota or a missing account (confirmed by the OSC developer on bazarr issue
#2121). The stack is pinned to `lscr.io/linuxserver/bazarr:1.5.6` for that
reason, and apply **V6** + diag **S4** fail if the running image is older. If
you see 426 again, check the image tag before touching the provider settings.

**Bazarr — Latin American Spanish only.**

1. *Settings → Languages → **Languages Filter → Select languages***: enable
   **both**:
   - **`Spanish (Latino)`** — Bazarr's name for Latin American Spanish
     (custom entry, `alpha2=ea`, `alpha3=spl`, maps to `es-MX` / script `419`);
   - **`Spanish`** — pycountry `es`/`spa`, i.e. Castilian. Used only as a
     **fallback** for titles that have no LatAm release.

   The profile editor's language picker only lists **enabled** languages, so
   plain `Spanish` is unselectable until it is enabled here. Enabling a language
   is also what unlocks the **Add New Profile** button under the *Languages
   Profile* table (until then it is a greyed bar reading *No Enabled Languages*).
2. Click **Add New Profile** (full width, directly under the table). In the
   dialog: **Name** `Latin American Spanish`, **Tag** empty, then add
   **`Spanish (Latino)` first** and **`Spanish` second**, leave *Forced*/*HI*
   unchecked, tick **Cutoff on the `Spanish (Latino)` row only**, leave *Must
   contain* / *Must not contain* empty → Save.

   **How that behaves:** Bazarr wants both while neither is on disk, so it may
   fetch a Castilian file as a stop-gap; the moment a LatAm file exists the
   cutoff is met and the profile counts as satisfied (no further searching).
   If you want **only** LatAm and would rather have no subtitles than Castilian,
   skip the `Spanish` item and skip enabling it in the filter.
3. *Settings → Providers*: enable one that carries es-LA (OpenSubtitles.com
   needs a free account; add the username/password there).
4. *Settings → Subtitles*: turn **Ignore embedded subtitles** ON (otherwise the
   embedded `spa` tracks count as "already subtitled" and es-LA is never
   fetched), and set the minimum score (e.g. 80) so a low-confidence match is
   not accepted.
5. *Settings → Radarr*: enable it, Address **`http://radarr:7878`** (compose
   service name — the VM IP is unreachable from inside the container), API key,
   and **automatic subtitle downloading** on. After the normalizer strips
   embedded subs, Bazarr sees every film as "no subtitles" and fetches es-LA on
   import. Bazarr writes them as `Movie.es-la.srt` / `.spl.srt`.
6. *Bottom of the Languages page → Default Language Profiles For Newly Added
   Shows → Movies*: tick it and select `Latin American Spanish`. Then apply it to
   the existing library: **Movies** tab → select the film → *Edit* → *Language
   Profile*.

**Radarr — refuse the bad releases at the source** (the normalizer is the
safety net, not the first line of defence). *Settings → Custom Formats* → *Add*:

| Custom Format | Condition | Score |
| --- | --- | --- |
| `TrueHD / Atmos` | Release title contains `TrueHD` OR `Atmos` | **-10000** |
| `DTS-HD / DTS-X` | contains `DTS-HD` OR `DTS-X` | **-10000** |
| `Remux` | contains `Remux` | **-10000** |
| `MULTi / DUAL` | contains `MULTi` OR `DUAL` | **-10000** |
| `H.264` | contains `x264` OR `H.264` | **+50** |
| `AC3 5.1` | contains `AC3` OR `DD5.1` | **+25** |

Then in the quality profile, allow only `WEBDL-1080p` / `Bluray-1080p` (drop
`Remux` and `2160p`) and attach those custom formats. Scores of -10000 make a
release effectively ungrabbable, so you stop paying for 11-audio remuxes at all.

**Verification.** `diag` section **S11** fails if either unit is not active and
prints the newest library file's stream counts (`audio=1 subs=0` is the target).
`grep -c "fail(" /var/log/media-normalize.log` should stay at 0.

---

### 10j. Housekeeping after the first remux (ops scripts, 2026-11-19)

Four chores stay after a title is normalized. Three are scripted (run as root on
clawbox); the GUI is only the fallback when a credential is missing. Never
publish a new port to reach them — every helper talks to the **VM-side**
`192.168.122.10` address, which is exactly what `diag` S6 proves is *not*
reachable from the LAN.

**j1. Reclaim the pre-remux copy (`qbt_admin.sh`).** After `mv`, the old inode
is still owned by the torrent, so `/data` looks full *after* a successful
shrink. Measured 2026-11-18: `config 99M / media 32G / torrents 41G`, and the
seeding handle was visible at `/proc/<qbt>/fd -> /data/torrents/…-BTM/…mkv`.

```bash
sudo bash qbt_admin.sh --status                          # categories + torrents + df
sudo bash qbt_admin.sh --remove-torrent "hail mary"      # dry run: name/space/path
sudo bash qbt_admin.sh --remove-torrent "hail mary" --yes
```

The matcher ignores dots/spaces/case, so `"hail mary"` matches
`Project.Hail.Mary.2026…`. It refuses any torrent whose `save_path` is outside
`/data/torrents`, and it prints the reclaimed space. **A hardlink does not make
this dangerous** — unlinking the torrent's name leaves the library inode alive;
it only means no space is freed (the script warns when that happens).
Auth: `QB_PASS=…` or the first-run temporary password in the container log
(observed working 2026-11-19 — the log line is read inside the VM). The torrent
reported `save_path=/data/torrents` exactly, i.e. the default directory with no
category subdir, which the guard accepts.

**j2. Full library scan (`jellyfin_admin.sh`).** Still mandatory after the 12.x
upgrade (10h), and again after the streams under a path change:

```bash
sudo bash jellyfin_admin.sh --show     # current ServerName + last scan
sudo bash jellyfin_admin.sh --scan     # POST /Library/Refresh, then wait
sudo bash jellyfin_admin.sh --subs     # what the TV is offered, per film
```

`--subs` is the read-only close of the subtitle loop: it lists every movie's
subtitle streams with their **language as Jellyfin parsed it**, whether the
stream is `external` (the Bazarr `.srt`) or `embedded`, and whether it is
flagged HI. It exits **1** if any film has no Spanish stream, and prints
`language NOT parsed from the filename` when Jellyfin could not decode a
suffix — which is the one failure a sidecar on disk cannot reveal. At the time
of writing the suffixes were `Title.es.srt`, `Title.es-MX.srt` and
`Title.es-MX.hi.srt`.

It reads an **existing** API key from `jellyfin.db` *inside the VM*, uses it
there, and never prints it. If the DB has no key it exits 2 and prints the two
GUI clicks instead of inventing credentials.

**Endpoint:** the compose file publishes `"192.168.122.10:8096:8096/tcp"`, so
Docker binds **only the VM's LAN address** — `127.0.0.1:8096` refuses inside the
VM by design (the same binding `diag` S6 relies on to stay off the physical
LAN). An early version hardcoded loopback and died with
`ConnectionRefusedError`. The helper now probes `192.168.122.10:8096` then
`127.0.0.1:8096`, prints the endpoint it chose, and exits **5** with a
`docker ps` hint if neither answers, **7** if the stored key is rejected (401),
and **2** if no key exists at all — no tracebacks in any of those paths.

**j3. qBt category (10c) — stop the "where did my torrent go" moment.** Observed
2026-11-19: the `radarr` category **already existed with an empty `savePath`**,
and Radarr already tagged the torrent `cat=radarr`. That is the misleading half
of the bug — the category name is right, but **the category path is not used at
all** unless qBittorrent is told to use it (see the 2026-11-20 note below), so
`torrents/movies/` stays empty and the torrent lands in the default
`/data/torrents`:

```bash
sudo bash qbt_admin.sh --first-run      # all three steps, idempotent
# or one at a time:
sudo bash qbt_admin.sh --create-category radarr /data/torrents/movies
sudo bash qbt_admin.sh --set-radarr-category radarr
sudo bash qbt_admin.sh --fix-category-paths      # required — see below
```

`createCategory` answers **409** when the name exists and does **not** update the
path, so the helper also calls `editCategory` (qBittorrent ≥ 4.5.0) and then
fails loudly if the stored `savePath` still does not match. On a build older
than 4.5.0 `editCategory` 404s and the GUI is the only way (*qBt → Categories →
edit*).

**2026-11-20 (fix 69): setting the path is necessary but not sufficient.**
Radarr adds a torrent with `category` and neither `savepath` nor `autoTMM`, so
qBittorrent runs it in **manual** torrent-management mode. In that mode the
category `savePath` is consulted **only** when
`Session\UseCategoryPathsInManualMode` is true, and it defaults to **false**
(`sessionimpl.cpp`); `Session\DisableAutoTMMByDefault` defaults to **true**, so
even a freshly created category with a correct path had no effect. The live
evidence was `save_path=/data/torrents` on a torrent whose category was
`radarr` → `/data/torrents/movies`. `--fix-category-paths` sets the preference
through `POST /api/v2/app/setPreferences` (**applied live**, 200, no restart;
it affects new adds only, so an in-flight torrent keeps its location).
"Empty savePath" alone was never the whole explanation — the path was ignored
either way.

The second command writes Radarr's qBittorrent download-client **`movieCategory`**
field (GET → modify → PUT → GET) and prints the value back. **The field is not
called `category`.** An earlier version of this helper wrote `category`, got
`HTTP 202`, and verified nothing — Radarr deserializes only schema fields, so an
unknown name is silently dropped while the request still succeeds. Observed
2026-11-19: `category -> radarr (HTTP 202)` followed by `verify: []`. The helper
now targets `movieCategory` (Sonarr's equivalent is `tvCategory`), treats a
stray `category` field as a warning, and exits 3 if the value does not persist.
It is idempotent, so it doubles as the verification that Radarr is still tagging
`radarr`. The layout must stay on one filesystem (`/data`) or hardlinks silently
become copies.

**j4. Subtitle policy (`bazarr_policy.sh`).** Decision of 2026-11-19 (corrected
by the owner): **Latin American Spanish first, non-HI Castilian second, then the
two HI fallbacks.** Bazarr treats HI and non-HI as different items, so
`…es-MX.hi.srt` never satisfied the non-HI `Spanish (Latino)` cutoff — that is
why `missing=['ea']` persisted with the file already on disk.

```bash
sudo bash bazarr_policy.sh            # dry run: shows current vs wanted profile
sudo bash bazarr_policy.sh --apply    # save, verify, re-search radarrId 1
```

Resulting order (cutoff on the **last** row, so any of the four satisfies):

| # | Language | HI | Role |
| --- | --- | --- | --- |
| 1 | `Spanish (Latino)` (`ea`) | no | **preferred** — LatAm |
| 2 | `Spanish` (`es`) | no | preferred Castilian |
| 3 | `Spanish (Latino)` (`ea`) | yes | accepted fallback |
| 4 | `Spanish` (`es`) | yes | accepted fallback |

The live profile this was applied to had `cutoff=1` with rows `ea`, `es` — so the
substantive change is the cutoff (`1 → 4`), which is what makes the HI rows
count, plus the two HI rows themselves.

Safety: profile JSON is backed up to `/var/backups/bazarr/profiles-*.json`, a
`bazarr.db` copy is taken, and if the POST does not verify the previous profile
is POSTed back automatically. The existing `es-MX.hi` stays — HI is an accepted
row — and the upgrade task will not swap it for a non-HI file (fix 66, next).

Exit codes: **2** Bazarr did not return a profile list (bad key/endpoint — the
error body is printed, nothing changed); **3** the saved profile did not match
and the rollback ran; **4** the update was rejected (HTTP status and body
printed, nothing saved); **5** Bazarr unreachable. The verify checks the row
**order**, the **HI flag on each row** (booleans or Bazarr's `"True"`/`"False"`
strings), and the cutoff **item id** — not just the row count. New rows get ids
`max+1…` and the cutoff points at the last row's id, because Bazarr compares
`cutoff` against `item['id']`; a row index is meaningless there.

**Applied 2026-11-19T17:56Z** on a profile that had only rows `ea`, `es` with
`cutoff=1`: read-back verified `ea, es, ea, es` with HI flags
`False, False, True, True`, `cutoff=4`, and movie `radarrId 1` moved to
`missing: []` with `…Remux-1080p.es-MX.hi.srt` under `have`. Only one profile
existed at the time, so the settings POST carried one entry. The live rows carry
`audio_exclude="True"` / `audio_only_include="False"` — "don't fetch a subtitle
in the language you are already hearing" — copied onto the new HI rows, so all
four behave the same way (with English audio, the Spanish rows stay desired).

**Can the HI file be replaced by a non-HI one? (fix 66 — tested 2026-11-19: no.)**
`bazarr_status.sh --upgrade` queued the task and it *did* run for this film —
job **#33 `Tried to upgrade movies subtitles` completed, progress
`Project Hail Mary`**, log `18:06:49|INFO|BAZARR Finished searching for
Subtitles to upgrade` — and nothing changed. That is by design, not a failure:

1. `upgrade.py` searches with the subtitle's **own** history language and hi
   flag; because the profile now has an HI row for that language,
   `_is_hi_required()` keeps `is_hi='True'` instead of downgrading it;
2. `download.py` therefore passes `hearing_impaired="force HI"`, and
   `subliminal_patch/core.py` skips HI-verifiable results that are not HI;
3. only history rows with `score < 117` are candidates, and the search demands
   `score + 2` (`forced_minimum_score=score+1`, then `min_score = +1` again).

So the task can improve an HI subtitle and never converts it. A **non-HI** file
only comes from a *fresh* search: back up and delete the `.srt`, run
`scan-disk`, then `search-missing` — the four-row profile is then searched with
`hearing_impaired="don't prefer"` (mixed HI flags) and a non-HI result can win
on score. Risk: if neither provider has a non-HI es-LA for this release, the
title goes back to `missing` and has no subtitle. The policy does **not** require
that gamble — HI is an accepted row — so the applied profile plus this HI file is
a valid end state.

**How the profile is actually written (fix 65).** The profiles API is
**read-only** in Bazarr 1.5.x: `GET /api/system/languages/profiles` is the only
method, and both that route and its item route advertise
`Allow: HEAD, GET, OPTIONS` — which is why PATCH/PUT/POST all returned 405. The
write path is **`POST /api/system/settings`** with a **form** field
`languages-profiles` holding the **complete** profile list as JSON
(`Content-Type: application/x-www-form-urlencoded`). Two consequences that
matter:

1. the handler **deletes every profile that is not in the posted list**, so the
   script sends *all* profiles with only the target one replaced — posting just
   the edited profile would erase the others;
2. `cutoff` is an **item id**, not a row index (see
   `get_profile_cutoff()`: it compares `item['id'] == cutoff`; `65535` means
   "Any"). The script therefore assigns the new rows ids (`max+1…`) and points
   the cutoff at the **last row's id**. Item flags are the strings
   `"True"`/`"False"`, and `audio_exclude`/`audio_only_include` are copied from
   the same-language non-HI row so the "search only when…" behaviour is kept.

The movie-side assignment is **`POST /api/movies?radarrid=&profileid=`** —
`PATCH` there only runs actions (`scan-disk`/`search-missing`/`sync`). Verified
offline against a mock that reproduces the real contract, including a second
profile that must survive.

**j5. Server name.** `S5` reports a container id that changes on every recreate:

```bash
sudo bash jellyfin_admin.sh --server-name "Family Media"
```

Why the id appears: `/System/Configuration` had `ServerName` **empty** (observed
2026-11-19), and Jellyfin's *public* endpoint falls back to the machine hostname
when the setting is blank — in a container that hostname *is* the container id.
So there was never a stale name to correct, only an unset one; setting it fixes
both endpoints at once. The helper prints the transition and reads it back.

**j6. Did a requested title actually arrive? (`library_status.sh`).** A title
appearing in Bazarr's *Synced movies with Radarr* job (or in the Radarr UI) only
proves **metadata**, not a file — observed 2026-11-19 with *The Breakfast Club*,
which Bazarr synced while the question "do I have it?" was still open. One
read-only pass answers it down the whole chain:

```bash
sudo bash library_status.sh "breakfast club"
```

It prints, in order: the **Radarr** movie (`hasFile`, `sizeOnDisk`, quality,
path, queue state + progress), the **Radarr history** events, the matching
**qBittorrent** torrent (state/percent/save_path), the **file under
`/data/media/movies`** (size + mtime, looked up inside the VM), and the
**Jellyfin item** (name, runtime, path). The last block is a verdict:

| Verdict | Meaning |
| --- | --- |
| `YES` | file on disk **and** Jellyfin has the item (TV may need a home-screen refresh) |
| `PARTLY` | file on disk, Jellyfin has no item → `jellyfin_admin.sh --scan`, then check the library path |
| Radarr says it has the file, nothing on disk | path mapping / import problem (prints the expected path) |
| `NOT YET` + queue | still downloading — percent and ETA |
| `STUCK` + `downloadClientUnavailable` | Radarr queued the release but it never reached qBittorrent (no matching torrent) — see the download-client block |
| `NOT YET` + torrent but no queue | category/import mismatch (TODO 10c) |
| `NO` | metadata only: no file, no download — failed grab, retry from Jellyseerr/Radarr |
| Radarr does not know the title | the request never reached Radarr (Jellyseerr side) |

**When it says `STUCK`.** The script also prints Radarr's **download-client**
config (host/port/urlBase/movieCategory/username + whether a password is set),
runs Radarr's own `POST /api/v3/downloadclient/test` (does not save), and probes
`http://gluetun:8080` **from inside the radarr container** next to
`http://192.168.122.10:8080`. The IP host is the documented trap: the packet
enters the VM `INPUT` chain from `172.18.0.x`, which ufw does not allow, so the
client shows `downloadClientUnavailable` and nothing is ever added to
qBittorrent. Fix it with:

```bash
sudo bash library_status.sh "breakfast club" --fix-client-host
```

That writes exactly **one** field (`host` → `gluetun`, the compose service
name), re-runs the client test, and does nothing if the host is already correct
— in which case the failure is the WebUI password (manual 10b) and the test
message says so. The script never prints the password, only whether it is set.

**If the client test says `isValid=true`** (as it did live on 2026-11-19: host
already `gluetun`, `http://gluetun:8080 -> 200` from inside radarr, the VM IP
`-> 000`), then the queue row is just **parked** from an earlier client outage —
the grab never became a torrent and Radarr will not retry it on its own. Clear
it and search again:
```bash
sudo bash library_status.sh "breakfast club" --retry
```

It re-runs `testall` first and **refuses** unless every client is valid, then
deletes only that movie's `downloadClientUnavailable` queue rows with
`removeFromClient=false&blocklist=false` (the release was never downloaded, so
nothing is blocklisted) and posts `MoviesSearch`. Re-run the plain command to
watch it change from `STUCK` to `NOT YET … downloading`.

**If `testall` says `isValid=false` / `Authentication Failure`** the password is
not necessarily wrong. qBittorrent **bans a source IP for one hour after five
failed logins** (`MaxAuthenticationFailCount=5`, `BanDuration=3600s`), and the
ban map is **in memory only** (`src/webui/api/authcontroller.cpp`,
`AuthController::isBanned`). Every login during a ban answers 403 *"Your IP
address has been banned…"*, which Radarr reports as a plain
`Authentication Failure`. Radarr retries on each queue refresh, so its
**container** IP stays banned while this helper — connecting from the host —
keeps logging in fine. That asymmetry is the tell.

Sequence (each step re-tests; nothing prints the password):

```bash
sudo bash library_status.sh "breakfast club" --fix-qbt-auth        # restart qBt: clears the ban map
sudo bash library_status.sh "breakfast club" --fix-client-password # save qBt's current credential
sudo bash library_status.sh "breakfast club" --retry               # drop the parked grab, search
```

A **PUT that returns 400 is not a malformed body**: Radarr tests the client on
save (`ProviderControllerBase.UpdateProvider`) and returns the validation
failure in the body; the helper now prints it. If that body is again
`Authentication Failure` *while the ban is active*, the same ban explains it —
which is why the restart comes first. Host header validation is **not** the
cause in this deployment: with no explicit keys qBittorrent uses
`ServerDomains=*` (any host) and `CSRFProtection` explicitly allows requests
that carry no `Origin`/`Referer` (`isCrossSiteRequest`). Keep those settings
alone.

Verified live on 2026-11-20: the restart run still ended `isValid=False`, then
`--fix-client-password` printed **`PUT … HTTP 202`** and `isValid=True`, then
`--retry` printed `DELETE queue/… 200` and `POST command … 201`. Expect exactly
that shape — a still-red testall after the restart is **not** a failed fix.

**The verdict after an action says so (fix 68).** These flags work on the
snapshot taken at the start of the run, so the final block reads
`== VERDICT (snapshot taken before --retry) ==` and prints `ACTION TAKEN …,
re-run the plain command` rather than `STUCK`. Run the plain command again
about a minute later; that is the run that shows `NOT YET … downloading x%`.

Secrets stay put: `RADARR_API_KEY` from `/opt/media-assistant/.env`, the qBt
password from `QB_PASS`/the container log, the Jellyfin token from
`jellyfin.db` inside the VM. Nothing is printed, written or re-scanned.

**GUI fallback (last resort)** — only if a helper says it cannot authenticate:

| Chore | Path |
| --- | --- |
| Reclaim | qBittorrent → torrent → *Remove* → tick *delete files* |
| Scan | Dashboard → Scheduled Tasks → *Scan Media Library* → ▶ |
| Category | qBt → *Categories* → add `radarr` → `/data/torrents/movies`; Radarr → Settings → Download Clients → qBittorrent → *Category*; then `qbt_admin.sh --first-run` (fix 69) |
| Subtitles | Bazarr → Settings → Languages → profile rows + *Cutoff* radio |
| Server name | Dashboard → General → *Server Name* → **Family Media** → Save |

The qBt WebUI is VM-only; reach it with
`ssh -L 8080:192.168.122.10:8080 jordan@192.168.1.133` from a machine with a
browser. Do not add a LAN publish rule for `:8080`.

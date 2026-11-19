# TASK (fix 50): make `jellyfin-lan-proxy.socket` survive a reboot

**Audience:** an OpenCode session working in `/home/jordan/Documents/SystemBuild/`.
**Scope:** host-side Phase 5 units only. **Do not** touch SSH, firewall posture, the LAN exposure surface, or the media-vm.
**Deliverable:** a patched `phase5_apply.sh` (working copy), a corrected live unit, a new guardrail assertion, and a `PROJECT_MEMORY.md` entry.

---

## 1. Symptom

After the host rebooted on **2026-11-10 17:26**, Jellyfin on `http://192.168.1.133:8096` was dead until it was fixed by hand. Nothing was listening on 8096; the unit was `inactive (dead)`.

`journalctl -b -u jellyfin-lan-proxy.socket`:

```
sockets.target: Found ordering cycle: jellyfin-lan-proxy.socket/start after
  network-online.target/start after NetworkManager-wait-online.service/start
  after basic.target/start after sockets.target/start - after jellyfin-lan-proxy.socket
sockets.target: Job jellyfin-lan-proxy.socket/start deleted to break ordering cycle
```

**Semantics:** socket units live under `sockets.target`, which is ordered *before* `basic.target` → `network-online.target`. A socket unit can therefore never be ordered `After=network-online.target`. systemd breaks the cycle by deleting the socket's start job, so the listener silently never comes up.

`ssh.socket` hit the **identical** bug from its own drop-in and was fixed separately (`/etc/systemd/system/ssh.socket.d/listen.conf` now has no `[Unit]` ordering; `ssh.socket` has `FreeBind=yes` in its base unit). **Do not touch SSH units in this task.**

## 2. Two defects to fix

### 2a. Ordering cycle (primary)

`phase5_apply.sh` lines **1294–1295** write `Wants=`/`After=network-online.target` into the **socket** heredoc:

```bash
cat >"$PROXY_SOCKET" <<'SOKEOF'      # line 1291
[Unit]
Description=Jellyfin LAN proxy listener (192.168.1.133:8096 -> media-vm 8096)
Wants=network-online.target          # line 1294  <-- remove
After=network-online.target          # line 1295  <-- remove

[Socket]
# Pin to the LAN address - never a wildcard.  The ONLY port media exposes.
ListenStream=192.168.1.133:8096
ReusePort=yes
Backlog=100

[Install]
WantedBy=sockets.target
SOKEOF
```

### 2b. DHCP race (latent — will appear the moment 2a is fixed)

`jellyfin-lan-proxy.socket` has **no `FreeBind=yes`**. Once the ordering is gone the socket starts early (before NetworkManager has assigned `192.168.1.133`), and `bind()` on a not-yet-local unicast address fails:

```
jellyfin-lan-proxy.socket: Failed to listen on 192.168.1.133:8096: Cannot assign requested address
```

`ssh.socket` solves this with `FreeBind=yes` (it binds `192.168.1.133:22` very early on this same host). Do the same here — **do not** fall back to `0.0.0.0` (that would break the "never a wildcard" invariant and guardrail G9).

### 2c. Keep the ordering on the *service* (it is legal there)

`jellyfin-lan-proxy.service` (heredoc starts line 1306) already has:

```ini
Requires=jellyfin-lan-proxy.socket
After=network-online.target libvirtd.service
```

A `.service` may be ordered after `network-online.target`. Add `Wants=network-online.target` there so the dependency is pulled explicitly, matching `jellyfin-discovery.service`.

---

## 3. Required changes

Work on the **writable working copy** `/home/jordan/Documents/SystemBuild/phase5_apply.sh` (verified byte-identical to the canonical root copy `/usr/local/sbin/phase5/phase5_apply.sh`; both 103589 bytes). The canonical root copy is what a real apply runs — install the patched file there at the end.

### 3.1 Socket heredoc — target content

```bash
cat >"$PROXY_SOCKET" <<'SOKEOF'
[Unit]
Description=Jellyfin LAN proxy listener (192.168.1.133:8096 -> media-vm 8096)

[Socket]
# Pin to the LAN address - never a wildcard.  The ONLY port media exposes.
ListenStream=192.168.1.133:8096
ReusePort=yes
Backlog=100
# Bind before DHCP assigns the LAN IP; packets are delivered once it appears.
# (ssh.socket uses the same mechanism on this host — a socket unit must NEVER
# be ordered After=network-online.target: sockets.target precedes basic.target,
# so that ordering is a boot-time cycle that deletes this unit's start job.)
FreeBind=yes

[Install]
WantedBy=sockets.target
SOKEOF
```

### 3.2 Service heredoc — add `Wants=`

```ini
[Unit]
Description=Jellyfin LAN proxy relay (systemd-socket-proxyd)
Requires=jellyfin-lan-proxy.socket
After=network-online.target libvirtd.service
Wants=network-online.target
```

### 3.3 Documentation comment

Near the Phase 5 header comment block (the `socket-proxyd … ALWAYS pinned` notes around lines 96–101), add one line stating that host LAN-facing **socket** units must not be ordered after `network-online.target`, and that `FreeBind=yes` covers the pre-DHCP bind. Keep it terse and consistent with the existing comment style.

### 3.4 Live unit (this host, now)

The live file is already missing the ordering (hand-fixed) but lacks `FreeBind=yes`. Bring it in line with 3.1:

```bash
sudo tee /etc/systemd/system/jellyfin-lan-proxy.socket >/dev/null <<'EOF'
[Unit]
Description=Jellyfin LAN proxy listener (192.168.1.133:8096 -> media-vm 8096)

[Socket]
# Pin to the LAN address - never a wildcard.  The ONLY port media exposes.
ListenStream=192.168.1.133:8096
ReusePort=yes
Backlog=100
FreeBind=yes

[Install]
WantedBy=sockets.target
EOF
sudo systemctl daemon-reload
sudo systemctl restart jellyfin-lan-proxy.socket
```

⚠️ `restart` drops the listener for ~1 s and terminates any in-flight stream (`jellyfin-lan-proxy.service` exits and respawns on the next connection). Do it when nothing is streaming; the `.service` comes back by itself on the next request.

### 3.5 Install the script

```bash
bash -n /home/jordan/Documents/SystemBuild/phase5_apply.sh
sudo install -o root -g root -m 755 \
  /home/jordan/Documents/SystemBuild/phase5_apply.sh \
  /usr/local/sbin/phase5/phase5_apply.sh
diff -q /home/jordan/Documents/SystemBuild/phase5_apply.sh /usr/local/sbin/phase5/phase5_apply.sh
```

### 3.6 Guardrail regression assertion

`phase5_guardrail_test.sh` is offline and non-privileged; run the working copy (`bash phase5_guardrail_test.sh`) — never install/modify the root copy's behaviour, but do install the test alongside the script if you keep the two trees mirrored.

Add, inside **G9** (`CHK_OK` scope) immediately **before** the line `[ "$CHK_OK" -eq 1 ] && pass "G9 complete: LAN surface = Jellyfin only"`:

```bash
# fix 50 — the proxy socket must not be ordered after network-online.target
# (socket units precede basic.target => boot-time ordering cycle), and must
# FreeBind so it can bind before DHCP assigns the pinned LAN address.
SOK_START="$(grep -n "<<'SOKEOF'" "$APPLY" | head -n1 | cut -d: -f1 || true)"
SOKSEC=""
if [ -n "${SOK_START:-}" ]; then
    SOKSEC="$(sed -n "$((SOK_START+1)),/^SOKEOF$/p" "$APPLY" | sed '$d')"
fi
if [ -z "$SOKSEC" ]; then
    fail "jellyfin-lan-proxy socket heredoc (<<'SOKEOF') not found"; CHK_OK=0
elif printf '%s\n' "$SOKSEC" | grep -qE '^After=.*network-online'; then
    fail "proxy SOCKET ordered After=network-online.target (boot ordering cycle)"; CHK_OK=0
else
    pass "proxy socket has no network-online ordering (boot-safe)"
fi
printf '%s\n' "$SOKSEC" | grep -Fq 'FreeBind=yes' \
    && pass "proxy socket uses FreeBind=yes (binds before DHCP assigns the LAN IP)" \
    || { fail "proxy socket missing FreeBind=yes (DHCP race at boot)"; CHK_OK=0; }
```

**Mutation-test it, as this project requires** (project convention: every new assertion is proven to fail against the bug):
1. Re-add `After=network-online.target` inside the heredoc → guardrail must FAIL.
2. Remove `FreeBind=yes` → guardrail must FAIL.
3. Revert both → guardrail back to `VERIFY_FAILS=0`.

### 3.7 Project memory

Append one bullet to the Phase 5 section of `PROJECT_MEMORY.md`, in the same style as fixes 47–49: what broke (boot ordering cycle, socket job deleted, 8096 dead), why (socket units precede `basic.target`; `After=network-online.target` is illegal there), the fix (`FreeBind=yes`, ordering moved to the service), and the evidence (journal line + post-fix listener). Label it **fix 50**.

---

## 4. Acceptance criteria

Run each; every one must hold.

```bash
# 1. no socket unit on the host is ordered after network-online
grep -rlE '^After=.*network-online' /etc/systemd/system/*.socket /usr/lib/systemd/system/*.socket ; echo "rc=$? (1 = none, good)"

# 2. no ordering cycle / no network-online in the live unit's ordering
systemd-analyze verify /etc/systemd/system/jellyfin-lan-proxy.socket
systemctl show jellyfin-lan-proxy.socket -p After | tr ' ' '\n' | grep -c network-online   # -> 0

# 3. FreeBind live and no pending reload
systemctl show jellyfin-lan-proxy.socket -p FreeBind -p NeedDaemonReload   # -> FreeBind=yes, NeedDaemonReload=no

# 4. listener + end-to-end relay
systemctl is-active jellyfin-lan-proxy.socket
ss -tln | grep ':8096'                                  # -> 192.168.1.133:8096
curl -sS -m 8 -o /dev/null -w 'HTTP %{http_code}\n' -I http://192.168.1.133:8096   # -> 302
systemctl is-active jellyfin-lan-proxy.service          # -> active after the curl

# 5. static guardrails stay green
cd /home/jordan/Documents/SystemBuild && bash phase5_guardrail_test.sh; echo "rc=$?"   # -> rc=0, VERIFY_FAILS=0

# 6. installed copy matches the working copy
diff -q /home/jordan/Documents/SystemBuild/phase5_apply.sh /usr/local/sbin/phase5/phase5_apply.sh

# 7. script still parses
bash -n /home/jordan/Documents/SystemBuild/phase5_apply.sh
bash -n /usr/local/sbin/phase5/phase5_apply.sh
```

**Real boot proof (do NOT reboot the host during this task):** the post-reboot check is, after the next legitimate reboot, `systemctl is-active jellyfin-lan-proxy.socket` and `ss -tln | grep :8096` **with no manual intervention**. Note in the report that this remains to be observed.

---

## 5. Constraints

- **Do not** run the full `phase5_apply.sh`. It provisions the VM, harvests keys and takes 10–20 min; it is not needed to fix a unit file. The script edit is for future runs only.
- **Do not** reboot or shut down the host; SSH access is in use (two live sessions).
- **Do not** modify anything under `/etc/ssh`, `ssh.socket*`, `ssh.service*`, ufw rules, libvirt, DOCKER-USER chains, or `media-vm-lan-guard`.
- **Do not** change `ListenStream=192.168.1.133:8096` to a wildcard, and do not add/remove published ports. The LAN surface must stay exactly `8096/tcp` + `7359/udp`, LAN-subnet only.
- **Do not** remove `ReusePort=yes`, `Backlog=100`, the `[Install] WantedBy=sockets.target`, or the sandbox directives on the `.service`.
- Keep both `phase5_apply.sh` trees mirrored (working copy ↔ `/usr/local/sbin/phase5/`, root:root 755).
- No secrets in any file, log, or report; Jellyfin/`*arr` keys and `vpn.env` values must never be echoed.

## 6. Rollback

```bash
sudo tee /etc/systemd/system/jellyfin-lan-proxy.socket >/dev/null <<'EOF'
[Unit]
Description=Jellyfin LAN proxy listener (192.168.1.133:8096 -> media-vm 8096)

[Socket]
# Pin to the LAN address - never a wildcard.  The ONLY port media exposes.
ListenStream=192.168.1.133:8096
ReusePort=yes
Backlog=100

[Install]
WantedBy=sockets.target
EOF
sudo systemctl daemon-reload && sudo systemctl restart jellyfin-lan-proxy.socket
```

That restores today's hand-fixed state (working now, DHCP-racy at boot). Rollback is not reboot-safe, which is exactly why the fix is needed.

## 7. Report back

State, with command output quoted: the 7 acceptance checks, the guardrail PASS/FAIL counts (was 145 PASS before; it should grow by 2), the mutation-test results, and the `PROJECT_MEMORY.md` bullet added. Flag explicitly that reboot-safety is static-only until the next real reboot.

---

### Appendix — verified facts (as of 2026-11-10 ~22:45 CET)

| Item | Value |
|---|---|
| Host | `clawbox`, LAN IP `192.168.1.133` on `eno1`, media-vm `192.168.122.10` running |
| Script | `/home/jordan/Documents/SystemBuild/phase5_apply.sh` == `/usr/local/sbin/phase5/phase5_apply.sh` (byte-identical) |
| Bad lines | 1294 `Wants=network-online.target`, 1295 `After=network-online.target` (socket heredoc) |
| Service heredoc | starts line 1306; `After=network-online.target libvirtd.service` at 1310 |
| Live unit | `/etc/systemd/system/jellyfin-lan-proxy.socket` — ordering removed, **`FreeBind=yes` absent** |
| `ssh.socket` | base unit has `FreeBind=yes`; drop-in fixed; active on `192.168.1.133:22` |
| Guardrail anchor | `phase5_guardrail_test.sh` ~line 466 checks the two unit names inside G9 |
| Fix number | 50 (47–49 are the latest recorded) |

---

### Addendum — reboot proof (2026-11-11)

The "static-only until the next real reboot" caveat is now closed. Units were
written at **18:42**, the host cold-booted at **18:49**, and the socket came up
on its own:

```
$ uptime -s
2026-11-11 18:49:00

$ journalctl -b -u jellyfin-lan-proxy.socket --no-pager
Nov 11 18:49:09 clawbox systemd[1]: Listening on jellyfin-lan-proxy.socket - Jellyfin LAN proxy listener (192.168.1.133:8096 -> media-vm 8096)

$ journalctl -b | grep -iE 'ordering cycle|deleted to break|Cannot assign requested address'
(no output)

$ systemctl show jellyfin-lan-proxy.socket -p FreeBind -p ActiveEnterTimestamp
FreeBind=yes
ActiveEnterTimestamp=Wed 2026-11-11 18:49:09 CET
```

Exactly one `Listening on` line for the boot (no restart), still active ~16 h
later, and `http://192.168.1.133:8096` answers `HTTP 302`. Acceptance:

```
$ bash phase5_fix50_verify.sh
...
----- 8. boot evidence (current boot) -----
  [PASS] no ordering cycle and no bind failure in this boot's socket journal
  [PASS] socket bound exactly once this boot (no manual restart)
  [PASS] socket active 9s after boot (automatic, boot: 2026-11-11 18:49:00)
  [PASS] jellyfin-lan-proxy.socket enabled (starts on every boot)
=== VERIFY_FAILS=0 ===
```

`phase5_fix50_verify.sh` section 8 now asserts this evidence on every run, so
each future reboot is self-proving. No further reboots are needed to prove fix
50.

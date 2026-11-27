# Quick Start — SystemBuild Phase 5 (Media Stack)

> **For an AI agent or a human operator:** read this file top-to-bottom and execute
> each step in order. Every command is idempotent and fail-closed. Stop and report
> if any `VERIFY_FAILS` is non-zero or any assertion fails.
>
> **Prerequisites:** Ubuntu 24.04+ host with libvirt, a spare 90 GB LVM volume
> for media storage, and root access. Two machines are assumed (host + VM) but a
> single-host install is supported — see the "Topology" section below.

---

## Step 0 — Clone and inspect

```bash
git clone git@github.com:jordankupersmith/hermes_agent.git SystemBuild
cd SystemBuild
bash phase5_guardrail_test.sh          # offline gate: want VERIFY_FAILS=0
```

If the guardrail fails, do not proceed. Fix the reported assertion first.

## Step 1 — Install canonical copies

```bash
sudo bash phase5_step1_install.sh
```

This installs root-owned copies under `/usr/local/sbin/phase5/`. Every subsequent
step uses those copies, not the working tree, so the working tree can be edited
without affecting the running system.

## Step 2 — Apply (provisions VM, stack, firewall, LAN exposure)

```bash
sudo bash /usr/local/sbin/phase5/phase5_apply.sh
```

Expect 10–20 minutes on first run (apt, image download, VM boot, docker pulls).
The script is idempotent — re-running converges to the same state.

**Before running:** put real VPN credentials in `/etc/media-vm/vpn.env` (see
`phase5_compose.yaml` for the required keys). Without them, gluetun and
qbittorrent do not start, but the other seven containers do.

## Step 3 — Diagnose

```bash
sudo bash /usr/local/sbin/phase5/phase5_diag.sh
```

Want `VERIFY_FAILS=0`. This is read-only and safe to run at any time.

## Step 4 — First-run (human steps)

Follow `phase5_manual_steps.md` Step 10. The scripted helpers:

```bash
sudo bash jellyfin_admin.sh --scan          # mandatory full library scan after 12.4 upgrade
sudo bash qbt_admin.sh --set-password       # permanent qBt WebUI password
sudo bash qbt_admin.sh --status             # verify category path, port, connection
sudo bash bazarr_status.sh                  # subtitle providers and profiles
```

## Step 5 — Verify done criteria (§10g)

The stack is operational when all of these hold:

1. A requested movie downloads through qBittorrent, hardlinks (`n=2`), and is
   visible and playable in Jellyfin at `http://192.168.1.133:8096`.
2. `https://192.168.1.133:8443` loads without a certificate warning on family
   devices (import `/etc/media-vm/family-media-ca.crt`).
3. Family Jellyseerr accounts can request (pending approval).
4. qBittorrent reports `Connected` (not `Firewalled`), AirVPN test-open on
   port 37686 is green.

## Topology

Two machines are assumed:

- **Host** (`clawbox`): libvirt, media storage LV, SSH on `192.168.1.133`.
- **Guest** (`media-vm`): `192.168.122.10`, reachable via deploy key at
  `/etc/media-vm/deploy_ed25519`.

A single-host install is supported if qBittorrent shares gluetun's network
namespace, the VPN kill switch is proven with the tunnel down, admin ports are
never on the LAN, and firewall guards are carried to the host. The VM is
defence-in-depth, not the security property itself.

## Safety rules (do not violate)

- **Ports:** only Jellyfin `:8096`, discovery `:7359/udp`, Jellyseerr via Caddy
  `:8443` face the LAN. All admin UIs are VM-only.
- **VPN kill switch:** qBittorrent has no NIC of its own. Never add a second
  route.
- **Version pairing:** Jellyfin server and TV client must be on the same major
  (12.x ↔ 12.x). The 12.x DB migration is one-way.
- **Normalizer:** one audio track, zero embedded subtitles, video copied
  byte-for-byte. A 43 GB → ~32 GB shrink is expected.
- **Secrets:** never commit `vpn.env`, API keys, or `.env` files. They are
  root-only on the host.

## Key files

| File | Role |
| --- | --- |
| `AGENTS.md` | Rules before touching the media stack. Start here. |
| `PROJECT_MEMORY.md` | Decision log — numbered fixes with cause and regression test. |
| `phase5_manual_steps.md` | Operator runbook (Step 10 = first-run / day-2). |
| `TODO.md` | Backlog. |
| `phase5_apply.sh` | Idempotent apply. |
| `phase5_diag.sh` | Read-only diagnostics. |
| `phase5_guardrail_test.sh` | Regression suite. |
| `phase5_compose.yaml` | Stack definition. |

## Further reading

- `PROJECT_MEMORY.md` §2a — version-pairing invariant.
- `phase5_manual_steps.md` Step 10 — operator runbook.
- `AGENTS.md` Rule 3 — change protocol for script edits.
path="/home/jordan/Documents/SystemBuild/QUICKSTART.md"
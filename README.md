# SystemBuild — a reproducible home media + local-AI stack

## What this is

This repository is a reproducible build of a self-hosted home datacenter on a
single Ubuntu host: a KVM guest (`media-vm`) running a Docker Compose media stack
(Jellyfin, Jellyseerr, Radarr, Sonarr, Prowlarr, Lidarr, Bazarr, qBittorrent
behind a gluetun VPN kill switch), plus a local AI phase (LiteLLM proxy +
Hermes agent). It is written as **runbooks plus fail-closed scripts**, not a pile
of copy-pasted commands — every phase has an apply script, a diagnostic script,
and a guardrail test, and every mistake found on the live system is recorded with
its cause and regression test.

**Completed (Phases 0–5):** host hardening, storage provisioning, user isolation,
LiteLLM proxy, Hermes agent, KVM guest provisioning, the full media stack with VPN
kill switch, Jellyfin 12.4 upgrade, Latin-American Spanish subtitle policy,
media normalizer (one audio track / Spanish-only subtitles), qBittorrent
integration, and all family-facing items (CA import, Jellyfin users, Jellyseerr
requests, TV playback). The stack is operationally live and all §10g done
criteria are satisfied.

**Not yet started (Phases 6–8):** Phase 6 — Python Telegram front-door and media
extraction pipeline (`/opt/media-assistant`) with request-state notifications;
Phase 7 — end-to-end integration testing and operational runbook; Phase 8 —
documentation, backup, and private GitHub deployment. These are planned and
specified but not implemented.

The point of the project is that someone else can follow the same phases on their
own hardware and end up with the same result — including knowing **why** each
awkward decision was made.

## Status

| Phase | Scope | State |
| --- | --- | --- |
| 0 | Host inspection / inventory | done |
| 1 | Host baseline (users, storage LV, libvirt) | done |
| 2 | `media-vm` provisioning | done |
| 3 | Local AI service (LiteLLM pin, model routing) | done |
| 4 | Hermes agent (pinned commit + manifest) | done |
| 5 | Media stack: Jellyfin, Jellyseerr, Radarr, Prowlarr, qBittorrent behind gluetun | **done** |
| 6 | Python Telegram front-door & media extraction pipeline (`/opt/media-assistant`) | not started |
| 7 | End-to-end integration testing & operational runbook | not started |
| 8 | Documentation, backup & private GitHub deployment | in progress |

Phase 5 is complete — Jellyfin `12.4` for the Tizen client, Bazarr `1.5.6` for
Latin-American Spanish subtitles, and a normalizer that rewrites every title to
one audio track / Spanish-only subtitles before it is served. See
`QUICKSTART.md` for a step-by-step deployment guide.

## Layout

| File | Role |
| --- | --- |
| `QUICKSTART.md` | Step-by-step deployment guide. Pull the repo and tell your LLM to read and execute it. |
| `PROJECT_MEMORY.md` | The decision log. Numbered **fixes** (55–66 in phase 5) with symptom, root cause, evidence and lesson, plus the version-pairing invariant (§2a). |
| `phase5_manual_steps.md` | The operator runbook for phase 5 (Step 10 is the first-run / day-2 book). |
| `TODO.md` / `RESUME.md` | Backlog and the one-screen handoff that a fresh session reads first. |
| `phase5_apply.sh` | Idempotent apply: compose, normalizer units, permissions, pins. Fail-closed. |
| `phase5_diag.sh` | Read-only diagnostics (`VERIFY_FAILS=0` or it tells you why). |
| `phase5_guardrail_test.sh` | The regression suite for the phase-5 scripts. |
| `phase5_compose.yaml` | The stack definition (pinned images, VM-only port publishing, VPN kill switch). |
| `qbt_admin.sh`, `jellyfin_admin.sh`, `bazarr_policy.sh`, `bazarr_status.sh`, `library_status.sh`, `check_normalize.sh`, `diagnose_*.sh` | Day-2 helpers. Each has a header explaining what it will and will not touch. |
| `tests/` | **Offline** mock suites for the helpers — no VM, no network, no credentials. |

## Quick start

See **`QUICKSTART.md`** for the full step-by-step deployment guide. The short
version:

```bash
git clone git@github.com:jordankupersmith/hermes_agent.git SystemBuild
cd SystemBuild
bash phase5_guardrail_test.sh          # offline gate: want VERIFY_FAILS=0
sudo bash phase5_step1_install.sh      # install canonical root-owned copies
sudo bash /usr/local/sbin/phase5/phase5_apply.sh    # apply, idempotent
sudo bash /usr/local/sbin/phase5/phase5_diag.sh     # read-only diagnostics
```

Then follow `phase5_manual_steps.md` Step 10 for the parts that need a human.

See `QUICKSTART.md` for the full topology, safety rules, and day-2 helpers.

## Safety model (do not "fix" these)

- **Ports**: only Jellyfin `:8096`, discovery `:7359/udp` and Jellyseerr via
  Caddy `:8443` face the LAN. Every admin UI (qBittorrent, Radarr, Sonarr,
  Prowlarr, Lidarr, Bazarr, Jellyseerr's own port) is published **only** on the
  VM's libvirt address `192.168.122.10` and is reached through an SSH tunnel.
- **VPN kill switch**: qBittorrent has no NIC of its own; it shares gluetun's
  network namespace, and gluetun's firewall drops all egress when the tunnel
  dies. Do not add a second route "to make it work".
- **Version pairing** (`PROJECT_MEMORY.md` §2a): the Jellyfin server and the TV
  client must be on the same major. The 12.x database migration is one-way.
- **Normalizer**: one audio track, zero embedded subtitles, video stream copied
  byte-for-byte. A file shrinking from 43 GB to ~32 GB is expected; do not
  "restore" the removed tracks.
- **Secrets never enter this tree**: `/opt/media-assistant/.env`,
  `/opt/media-stack/vpn.env`, the deploy key and API keys are root-only and
  referenced by name only. `.gitignore` blocks the obvious paths, but review
  before publishing.

## Verification

```bash
# offline helper suites
python3 tests/test_library_status.py
python3 tests/test_bz.py && python3 tests/test_jf.py && python3 tests/test_rd.py && python3 tests/test_qbt.py && python3 tests/test_qbt_pw.py

# the mandatory change protocol (AGENTS.md Rule 3)
bash -n phase5_apply.sh phase5_diag.sh phase5_guardrail_test.sh
bash phase5_guardrail_test.sh        # want VERIFY_FAILS=0
sudo bash phase5_step1_install.sh
sudo bash /usr/local/sbin/phase5/phase5_apply.sh
sudo bash /usr/local/sbin/phase5/phase5_diag.sh
```

Any edit to `phase5_compose.yaml`, `phase5_apply.sh`, `phase5_diag.sh` or
`phase5_guardrail_test.sh` must also **mutation-test** every new assertion:
break it deliberately, confirm the guardrail fails, restore, and verify the
hash. Documentation and `PROJECT_MEMORY.md`/`TODO.md` are updated in the same
change.

## Before you publish (housekeeping)

1. `git log` and `git diff` are the provenance; keep commits scoped and
   message-rich (the *why*, not just the *what*).
2. Captured `*.out` transcripts are ignored on purpose — they can contain
   service output. Read them before ever adding one.
3. Grep the tree for real credentials and for LAN identifiers you would rather
   not publish (the docs contain `192.168.122.x`, `192.168.1.133` as examples).
4. The offline suites in `tests/` must pass from a clean clone.
5. License is **not decided yet** (add one before making the repository public).

## Further reading

- `PROJECT_MEMORY.md` §2a — the version-pairing invariant.
- `PROJECT_MEMORY.md` fixes 58–66 — the phase-5 history, including the mistakes
  that produced each guardrail assertion.
- `phase5_manual_steps.md` Step 10 — the operator runbook.

# Offline test suites

These tests need **no VM, no containers and no network**. Each one extracts the
Python (or shell) logic out of the helper it covers, points a mock HTTP server
at it, and asserts the behaviour that was learned the hard way on the live
stack. Run them before changing a helper:

```bash
python3 tests/test_bz.py            # bazarr_policy.sh  — profile writes
python3 tests/test_jf.py            # jellyfin_admin.sh — scan / server name
python3 tests/test_rd.py            # qbt_admin.sh      — Radarr category field
python3 tests/test_qbt.py           # qbt_admin.sh      — category path mode (fix 69)
python3 tests/test_qbt_pw.py        # qbt_admin.sh      — --set-password (fix 71)
python3 tests/test_library_status.py # library_status.sh — verdicts + fixes
```

| Test | What it proves |
| --- | --- |
| `test_bz.py` | Bazarr 1.5.6's profiles API is read-only; the write goes through `POST /api/system/settings` as a form field carrying the **complete** profile list (a profile missing from it is deleted). `cutoff` is an item id. A second profile must survive. |
| `test_jf.py` | The Jellyfin helper probes `192.168.122.10:8096` then loopback, exits 2/5/7 without tracebacks, and observes `Running -> Idle` on a scan. |
| `test_rd.py` | Radarr's qBittorrent category field is `movieCategory`: an unknown `category` name is accepted (202) and silently dropped, so the read-back is what must decide success. |
| `test_qbt.py` | A category `savePath` is **not** used for a *arr add unless `use_category_paths_in_manual_mode` is on (qBt default off, and Radarr sends no `savepath`/`autoTMM`). Covers the check/verify branches, an empty category path, and the idempotent already-on case (fix 69). |
| `test_qbt_pw.py` | `--set-password` must be one atomic repair. Fake qBittorrent (session cookie, ban switch, a setPreferences that can be rejected **or silently ignored**) and fake Radarr (save-time client test, `testall` that checks the stored password). Proves the new value with a **fresh** login, that nothing changes when the current password is wrong, and every exit code 4/5/6/7/8/9/10 (fix 71). Also covers `--import-downloads` → `DownloadedMoviesScan`. |
| `test_library_status.py` | Every verdict branch (YES / PARTLY / STUCK / downloading / NO / unknown title), the download-client host warning, password injection (without echoing it), that `--retry` selects only parked rows, and that a run with a write flag reports `ACTION TAKEN` from the pre-action snapshot instead of repeating `STUCK` (fix 68). |

`test_library_status.py` locates each embedded block by a **content marker**, not
by position, so reordering the script does not break the suite.

## What is *not* here

- No live-stack tests: they need root, the deploy key and the VM. Those are the
  guardrail suites (`phase*_guardrail_test.sh`), which fail closed and are run
  against the installed copies.
- No network calls and no real credentials. Mock servers bind `127.0.0.1` on an
  ephemeral port.

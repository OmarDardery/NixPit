# Implementation sequence

Architecture and release criteria: [architecture.md](architecture.md). Execute in order; each milestone has a testable definition of done. G0 is verified; later gates remain open until verified. Work in focused PRs; do not merge unfinished security-sensitive features as enabled defaults.

| Gate | Work | Required evidence |
|---|---|---|
| G0 (complete) | Pin flake.lock, fix NixOS/NixVirt/Cockpit option and package compatibility, CI and reproducible fixture | Committed lock; clean flake check; full host eval and installer build; verified service/package paths |
| G1 | Safe installation, idempotent host setup, DHCP default and optional validated static IPv4 | Disposable NixOS VM install/reinstall; preserves hardware, boot, login, stateVersion and connectivity; failed cutover recovery |
| G2 | Versioned strict workload schema and deterministic compiler | Tests for OCI/VM/Compose, names, ports TCP/UDP and IPv6, mounts, devices, networks, domain collisions, missing prerequisites, secret references and invalid inputs |
| G3 | Privileged typed backend and Git repository management | Auth, path/symlink, atomic writes, root-equivalent trust, per-repo identity and verified host keys, branch pinning, explicit staging, dirty/conflict behavior, secret exclusion and concurrent requests tested |
| G4 | Candidate snapshots, build, activation, health, rollback and recovery | Immutable host/workload revisions; shared lock; persisted generation/revision journal; injected failures at each phase retain previous active state; safe data-preserving Compose/VM reconciliation |
| G5 | Native Cockpit UX and operational controls | UI integration tests for onboarding, multi-repo editors/raw, status, logs, USB, secrets, diffs, validate/deploy/rollback; escaped output; operation serialization; no generic root shell from UI |
| G6 | Auto-sync and recovery lifecycle | Persistent disabled-by-default toggle; 15-minute timer uses G4 transaction; dirty/conflict/network failures safe; protected GC roots; backup/restore secrets and persistent data tested separately |
| G7 | End-to-end release | NixOS VM smoke and failure tests, docs and threat model, verified upgrade/rollback, locked inputs, required CI checks green; tag release only with explicit authorization |

## Evidence log

- Foundation: prototype imported; architecture documented; auto-sync disabled; syntax checks available. Full NixOS build and integration gates are not yet verified.
- For each gate, add PR links, test commands/results, and any limitation. Do not change the definition of done to fit incomplete code.

## Required CI / release policy

Static checks and full host evaluation/build are baseline. Add unit, schema, backend, NixOS VM and UI test jobs as implemented and make them required through the aggregate check. CI must never access real homelab credentials, modify live hosts, or run untrusted PR code with write tokens. A missing lock file is a release blocker. Use GitHub branch protection/rulesets to require PRs and the CI aggregate; repository settings need explicit setup and verification. No automatic release or merge of untrusted code.

- G0 (#3, [PR #11](https://github.com/OmarDardery/NixPit/pull/11)): committed lock; CI rejects missing locks and uses `--no-update-lock-file`. Fixed Cockpit plugin dependency metadata; platform-path checks cover packaged plugins, bridge, Compose and ble.sh. Local disposable Alpine/Nix container: full locked host evaluation and installer build pass. Locked flake check passes; [remote static, nix and required aggregate checks](https://github.com/OmarDardery/NixPit/actions/runs/45394690722) all passed on `18a7379`. Branch-protection inspection through the GitHub connector returned `403 Resource not accessible by integration`; settings cannot be configured or verified with this connection. G0 acceptance is verified, with the settings access limitation documented above.

- G1 (#4): candidate bootstrap implementation in review; static validation, private atomic writes and failure-path unit tests added. Disposable NixOS VM install/reinstall, SSH and network cutover/rollback tests remain required; do not close G1 before they pass.

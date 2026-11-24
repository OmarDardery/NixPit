# Implementation sequence

Architecture and release criteria: [architecture.md](architecture.md). Execute in order; each milestone has a testable definition of done. All are open until verified. Work in focused PRs; do not merge unfinished security-sensitive features as enabled defaults.

| Gate | Work | Required evidence |
|---|---|---|
| G0 | Pin flake.lock, fix NixOS/NixVirt/Cockpit option and package compatibility, CI and reproducible fixture | Committed lock; clean flake check; full host eval and installer build; verified service/package paths |
| G1 | Safe installation, idempotent host setup, DHCP default and optional validated static IPv4 | Disposable NixOS VM install/reinstall; preserves hardware, boot, login, stateVersion and connectivity; failed cutover recovery |
| G2 | Versioned strict workload schema and deterministic compiler | Tests for OCI/VM/Compose, names, ports TCP/UDP and IPv6, mounts, devices, networks, domain collisions, missing prerequisites, secret references and invalid inputs |
| G3 | Privileged typed backend and Git repository management | Auth, path/symlink, atomic writes, root-equivalent trust, per-repo identity and verified host keys, branch pinning, explicit staging, dirty/conflict behavior, secret exclusion and concurrent requests tested |
| G4 | Candidate snapshots, build, activation, health, rollback and recovery | Immutable host/workload revisions; shared lock; persisted generation/revision journal; injected failures at each phase retain previous active state; safe data-preserving Compose/VM reconciliation |
| G5 | Native Cockpit UX and operational controls | UI integration tests for onboarding, multi-repo editors/raw, status, logs, USB, secrets, diffs, validate/deploy/rollback; escaped output; operation serialization; no generic root shell from UI |
| G6 | Auto-sync and recovery lifecycle | Persistent disabled-by-default toggle; 15-minute timer uses G4 transaction; dirty/conflict/network failures safe; protected GC roots; backup/restore secrets and persistent data tested separately |
| G7 | End-to-end release | NixOS VM smoke and failure tests, docs and threat model, verified upgrade/rollback, locked inputs, required CI checks green; tag release only with explicit authorization |

## Evidence log

- Foundation: prototype imported; architecture documented; auto-sync disabled; syntax checks available. Full NixOS build and integration gates are not yet verified.
- G0 (in review, #3): inputs locked via git transport (nixpkgs `nixos-26.05`, NixVirt `v0.6.0`); Cockpit plugin `passthru.cockpitPath` fixed to a package list for nixos-26.05; `nix flake check` runs `javascript`, `installer` and `host-paths` (asserts cockpit.socket/libvirtd.service/podman.socket, no auto-sync unit, realised plugin manifests and runtime `git`); negative test: removing the plugin manifest fails `host-paths`. CI fails on missing or changed lock. Limitation: branch protection/required-check settings need repository admin access not available to the agent.
- For each gate, add PR links, test commands/results, and any limitation. Do not change the definition of done to fit incomplete code.

## Required CI / release policy

Static checks and full host evaluation/build are baseline. Add unit, schema, backend, NixOS VM and UI test jobs as implemented and make them required through the aggregate check. CI must never access real homelab credentials, modify live hosts, or run untrusted PR code with write tokens. A missing lock file is a release blocker. Use GitHub branch protection/rulesets to require PRs and the CI aggregate; repository settings need explicit setup and verification. No automatic release or merge of untrusted code.

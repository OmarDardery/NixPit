# NixPit architecture and release plan

## Goal and invariants

NixPit is a reproducible hypervisor appliance, not another independent hypervisor UI. Native Cockpit panels are for observation and operational actions; durable workload changes flow through Git. The host repo supplies platform modules, and external workload repos supply JSON/Compose/Dockerfiles. Runtime state and secrets stay on the host. There is no dependency on Incus, Portainer or Arcane.

| Layer | Responsibility |
|---|---|
| Host | NixOS, boot/hardware, KVM/Libvirt, Podman, Cockpit, Caddy, Git reconciliation |
| Workloads | Declarative containers, VM definitions, Compose stacks, local Dockerfile builds |
| Control plane | Onboarding, repository registration, visual editors, USB discovery, raw editor, status, logs, Git and deployment operations |
| Local state | Deploy credentials, env files (0600 in 0700 directory), persistent volumes, VM disks, registry and deployment history |

## Desired deployment transaction

1. Register explicit repository, branch and identity; authenticate against verified SSH host keys. Clone into staging, not an active workload path.
2. Validate schemas, unique names, ports, paths, domain ownership, VM disk/network prerequisites and Compose definitions. Reject symlinks escaping the repo and unsafe identifiers. Treat trusted workload definitions as root-equivalent.
3. Show staged/unstaged/untracked diffs; stage an explicit allowlist of workload files and exclude secrets. Push fast-forward only.
4. Resolve immutable host and workload revisions, snapshot the candidate and build NixOS. Do not change the active deployment on validation failure.
5. Activate under a shared lock, reconcile Compose and VMs, verify actual health, record commit IDs and generation only after success. Failed activation restores previous deployment pointer and generation. Keep previous snapshots and generations for rollback.
6. Optional 15-minute sync follows the same transaction; no rebase or overwrite of dirty worktrees. Persist toggle and surface failures.

## Workload contract

`guests.json` describes OCI images, command, published ports, volumes, environment (nonsecret), named secrets, dependencies, optional Podman network, USB serial paths and domain; VM fields include UUID, vCPU, memory, existing disk, network, USB vendor/product IDs and active state. Compose YAML and referenced Dockerfiles remain standard, not rewritten into Nix syntax. A standalone Dockerfile must be referenced by Compose or a future explicit build declaration. Bind mount creation must be restricted to approved data roots; explicit public TCP/UDP firewall mappings and loopback-only defaults should be supported. Caddy local `.home.arpa` names require LAN DNS; public HTTPS requires valid DNS and ACME reachability. VM storage pools, disks and networks must be provisioned or validated before activation.

## Release gates (not yet complete)

- [ ] Pin a committed flake.lock; evaluate a full NixOS test configuration and run a boot/install VM integration test. Verify NixVirt templates, storage pools, USB and network XML against real Libvirt; verify Cockpit plugin packaging and systemd units.
- [ ] Complete network bootstrap: optional validated static IPv4 with rollback on failed connectivity, DNS and gateway, keep DHCP as default. Preserve administrator, hardware, boot and stateVersion.
- [ ] Add schema and validation for all workload inputs; restrict host mounts, reject duplicates (basic duplicate container/VM checks already added), validate firewall protocols/ranges, network dependencies and Caddy domain uniqueness. Require explicit secret files and never put secret values into Nix evaluation.
- [ ] Implement root-owned transactional backend with safe paths, symlink defenses, privilege checks, atomic file writes, allowlisted operations and verified SSH keys; per-repository deploy keys or dedicated service identity, secret scanning and explicit staging. Existing UI uses Cockpit root commands and is not a security boundary.
- [ ] Implement immutable workload snapshots, revision-aware Compose restart/rebuild, transactional deploy and rollback, shared sync lock, persistent toggle, retries, and health checks. Prototype currently reads mutable checkouts and Compose systemd health is not container health. Do not enable auto-sync until this is fixed.
- [ ] Complete UI status/operations for VMs via Libvirt, actual Compose health, onboarding deployment state, validated form fields, preserve raw fields, errors and concurrency control, correct HTTP/HTTPS links, and safe secrets editor. Test UI workflows.
- [ ] Test recovery, backup/restore of persistent data and local secrets independently of generation rollback, and ensure garbage collection retains rollback targets.

## Acceptance

A clean supported NixOS host installs without losing network or login access. An admin can onboard multiple independent repositories, declare a container, VM and Compose stack, deploy, restart, view logs, and roll back a failed change without losing data or secrets. Git revisions and the active generation agree; invalid or dirty inputs never silently replace the working deployment. Automated CI exercises these cases before calling the project production-ready.

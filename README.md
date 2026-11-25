# NixPit

A declarative, GitOps-driven NixOS hypervisor appliance with Cockpit as its single web control plane. Separate the host operating system from workload repositories: NixOS provides the platform, Git records desired state, and Cockpit provides visual management.

**Status: experimental prototype, not production-ready.** Imported from the v4 hypervisor prototype. See [architecture and release gates](docs/architecture.md) before installing on a real server. Only trusted administrators and trusted Git repositories may be used: rootful containers, Compose builds and Nix evaluation are privileged.

## Architecture

- **NixPit host:** NixOS, KVM/Libvirt via NixVirt (with `virbr0` NAT network, `default` storage pool, nested virtualization, `virtiofsd` and `swtpm`), rootful Podman, Podman Compose, Caddy, Cockpit Machines/Podman, custom NixPit Workloads & Virtualization Monitor plugins, `nixpit_virtmon.ko` kernel monitor module, and ble.sh.
- **Independent workload repositories:** plain `guests.json`, `compose.yaml` or `docker-compose.yml`, and Dockerfiles. No NixOS boilerplate. See [template](templates/guests/).
- **Local state:** `/var/lib/nixpit` stores registered repositories, deploy key, local environment files and host flake reference. Secrets and workload data do not belong in Git or the Nix store.

## Bootstrap (test host only)

On an existing x86_64 NixOS machine with flakes enabled and conventional `/etc/nixos/configuration.nix`:

```sh
nix run github:OmarDardery/NixPit#install
```

The installer reports network details, preserves existing host configuration, creates a local wrapper flake, locks its inputs, builds and switches. Reserve the reported MAC/IP on your router. Existing flake-based hosts should instead import `nixosModules.default` into their existing flake and initialize the local state manually.

Open `https://<server-ip>:9090` on a trusted LAN, sign in as an existing administrator, then open **NixPit Workloads**. Generate a key, register a trusted workload repository, edit declarations and local secrets, review changes, validate, commit/push and deploy. The prototype's rollback switches the OS generation only; it does not restore Git or persistent data. Auto-sync is intentionally unavailable until transactional deployments are implemented.

## Repository layout

- `flake.nix` — installer, kernel monitor package, exported NixOS module, checks and VM test
- `kernel/nixpit-virtmon/` — out-of-tree Linux kernel module (`nixpit_virtmon.ko`) monitoring KVM, module, virtual network and virtualization process activity
- `modules/host.nix` — platform services, KVM/Libvirt virtualization and kernel monitor wiring
- `modules/guest-loader.nix` — validated workload translation
- `cockpit/` — custom control plane (`homelab-gitops` and `virtmon` Virtualization Monitor panel)
- `scripts/install.sh` — bootstrap
- `templates/guests/` — example external workload repository (not automatically deployed)
- `docs/architecture.md` — intended behavior, gaps and release gates

The example printer and streaming stacks need hardware-specific configuration and trusted images; do not deploy them blindly.

## Development

Start with [AGENTS.md](AGENTS.md), then follow the ordered [implementation plan](docs/implementation.md). The [architecture](docs/architecture.md) defines release gates. CI failures are blockers; passing static checks alone is not production readiness.

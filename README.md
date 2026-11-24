# NixPit

A declarative, GitOps-driven NixOS hypervisor appliance with Cockpit as its single web control plane. Separate the host operating system from workload repositories: NixOS provides the platform, Git records desired state, and Cockpit provides visual management.

**Status: experimental prototype, not production-ready.** Imported from the v4 hypervisor prototype. See [architecture and release gates](docs/architecture.md) before installing on a real server. Only trusted administrators and trusted Git repositories may be used: rootful containers, Compose builds and Nix evaluation are privileged.

## Architecture

- **NixPit host:** NixOS, KVM/Libvirt via NixVirt, rootful Podman, Podman Compose, Caddy, Cockpit Machines/Podman, a custom NixPit Workloads plugin and ble.sh.
- **Independent workload repositories:** plain `guests.json`, `compose.yaml` or `docker-compose.yml`, and Dockerfiles. No NixOS boilerplate. See [template](templates/guests/).
- **Local state:** `/var/lib/nixpit` stores registered repositories, deploy key, local environment files and host flake reference. Secrets and workload data do not belong in Git or the Nix store.

## Bootstrap (test host only)

On an existing x86_64 NixOS machine with flakes enabled and conventional `/etc/nixos/configuration.nix`:

```sh
nix run github:OmarDardery/NixPit#install
```

The installer reports network details, preserves existing host configuration, builds a locked candidate, tests runtime activation before committing the boot profile, and attempts recovery on failure. DHCP/router reservation is the default. Experimental static IPv4 on conventional scripted networking: append `-- --static 192.168.1.20/24 --gateway 192.168.1.1 --dns 192.168.1.1` (use your real LAN values); the gateway must respond to ping. The detached `nixpit-bootstrap` systemd unit continues even if SSH disconnects; inspect `journalctl -u nixpit-bootstrap`. Reinstall reuses the existing locked source; legacy wrappers require manual migration. G1 remains unverified until disposable VM tests pass. Existing flake-based hosts should instead import `nixosModules.default` into their existing flake and initialize the local state manually.

Open `https://<server-ip>:9090` on a trusted LAN, sign in as an existing administrator, then open **NixPit Workloads**. Generate a key, register a trusted workload repository, edit declarations and local secrets, review changes, validate, commit/push and deploy. The prototype's rollback switches the OS generation only; it does not restore Git or persistent data. Auto-sync is intentionally unavailable until transactional deployments are implemented.

## Repository layout

- `flake.nix` — installer, exported NixOS module and checks
- `modules/host.nix` — platform services and experimental sync
- `modules/guest-loader.nix` — workload translation
- `cockpit/` — custom control plane
- `scripts/install.sh` — bootstrap
- `templates/guests/` — example external workload repository (not automatically deployed)
- `docs/architecture.md` — intended behavior, gaps and release gates

The example printer and streaming stacks need hardware-specific configuration and trusted images; do not deploy them blindly.

## Development

Start with [AGENTS.md](AGENTS.md), then follow the ordered [implementation plan](docs/implementation.md). The [architecture](docs/architecture.md) defines release gates. CI failures are blockers; passing static checks alone is not production readiness.

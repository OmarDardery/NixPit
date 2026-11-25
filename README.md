# NixPit

A declarative, GitOps-driven NixOS hypervisor appliance with Cockpit as its single web control plane. Separate the host operating system from workload repositories: NixOS provides the platform, Git records desired state, and Cockpit provides visual management.

**Status: experimental prototype, not production-ready.** Imported from the v4 hypervisor prototype. See [architecture and release gates](docs/architecture.md) before installing on a real server. Only trusted administrators and trusted Git repositories may be used: rootful containers, Compose builds and Nix evaluation are privileged.

## Architecture

- **NixPit host:** NixOS, KVM/Libvirt via NixVirt (with `virbr0` NAT network, `default` storage pool, nested virtualization, `virtiofsd` and `swtpm`), rootful Podman, Podman Compose, Caddy, Cockpit Machines/Podman, custom NixPit Workloads & Virtualization Monitor plugins, `nixpit_virtmon.ko` kernel monitor module, `nixpit-repo` per-profile SSH keygen/sync, `sops-nix` + `nixpit-secrets`, and ble.sh.
- **Independent workload repositories:** pure Nix modules (`workloads.nix`, `default.nix`, `nix/*.nix`), `compose.yaml` or `docker-compose.yml`, standalone Dockerfiles, `.sops.yaml`, and SOPS-encrypted environment files (`secrets/*.sops.env`). See [template](templates/guests/).
- **Local state & RAM-only secrets:** `/var/lib/nixpit` stores repo profiles (`repos.json`), per-profile SSH keys (`keys/`), checkouts (`repos/`), and the host Age identity (`sops/age/keys.txt`). Repo `secrets/*.sops.env` files can be added, decrypted, edited, re-encrypted with SOPS + Age, and pushed straight from Cockpit; on deploy, `sops-nix` decrypts them only into RAM at `/run/secrets/nixpit/<repo>/<name>` (`0400`), never Git plaintext or `/nix/store`.

## Bootstrap (test host only)

On an existing x86_64 NixOS machine with flakes enabled and conventional `/etc/nixos/configuration.nix`:

```sh
sudo nix --extra-experimental-features 'nix-command flakes' run --refresh github:OmarDardery/NixPit#install
```

The installer reports network details, preserves existing host configuration, creates a local wrapper flake, locks its inputs, builds and switches. Reserve the reported MAC/IP on your router. The generated wrapper explicitly allows the detected LAN HTTPS origin for Cockpit (port 9090); rerun the installer after an address change. Custom flake users must add their own exact LAN origin to `services.cockpit.allowed-origins`. Rerunning the installer refreshes the locked NixPit input before rebuilding. Existing flake-based hosts should instead import `nixosModules.default` into their existing flake and initialize the local state manually.

Open `https://<server-ip>:9090` on a trusted LAN, sign in as an existing administrator, then open **NixPit Workloads**. Add a repository profile, copy its SSH deploy key to GitHub/Forgejo, pull (`Sync`), add/edit Nix workloads, Compose/Dockerfiles, and SOPS-encrypted env vars, **Commit & Push**, **Validate**, and **Deploy**. The prototype's rollback switches the OS generation only; it does not restore Git or persistent data. Auto-sync is intentionally unavailable until transactional deployments are implemented.

## Repository layout

- `flake.nix` — installer, kernel monitor package, exported NixOS module, checks and VM test
- `kernel/nixpit-virtmon/` — out-of-tree Linux kernel module (`nixpit_virtmon.ko`) monitoring KVM, module, virtual network and virtualization process activity
- `modules/host.nix` — platform services, KVM/Libvirt virtualization, `sops-nix`, `nixpit-secrets.service`, `nixpit-repo` and kernel monitor wiring
- `modules/guest-loader.nix` — dynamic Nix module importer + validated container/VM/Compose/Dockerfile and `sops-nix` secret compiler
- `cockpit/` — shared Vercel-style theme (`theme.css`) and Cockpit panels (`homelab-gitops` and `virtmon`)
- `scripts/` — shared package definitions (`packages.nix`), bootstrap, checks, `nixpit-repo` and `nixpit-secrets` CLIs
- `templates/guests/` — example external workload repository (pure Nix + Compose + Dockerfile + SOPS `.gitignore`)
- `docs/architecture.md` — intended behavior, gaps and release gates

## Development

Start with [AGENTS.md](AGENTS.md), then follow the ordered [implementation plan](docs/implementation.md). The [architecture](docs/architecture.md) defines release gates. CI failures are blockers; passing static checks alone is not production readiness.

# NixPit Workload Repository Template

Copy these files into a separate trusted Git repository, then register it in Cockpit **Profiles** and click **Pull / Sync**:

- `workloads.nix` / `nix/*.nix` — Pure NixOS modules declaring `services.nixpit.workloads.containers.*`, `services.nixpit.workloads.vms.*`, or standard NixOS options (`services.*`, `networking.*`).
- `compose.yaml` (or `docker-compose.yml`) and `Dockerfile` — Automatically built and run via `podman-compose` (or standalone `podman` if only a `Dockerfile` is present).
- `secrets/*.sops.env` + `.sops.yaml` — Managed directly from Cockpit's **Secrets** / **Workloads** UI (or `nixpit-secrets repo-set`), encrypted with SOPS + the host Age public key, safely pushed to Git, and decrypted by `sops-nix` into RAM at `/run/secrets/nixpit/<repo>/<name>` on deploy. Keep plaintext `.env` files out of Git.

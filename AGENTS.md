# Codex / contributor instructions

## Source of truth
Read README.md, docs/architecture.md, docs/implementation.md, then only files relevant to the next unchecked gate. Inspect git status and recent commits. Do not re-scan the entire repository or repeat completed plans. This is a real NixOS appliance; the existing prototype is not the specification.

## Non-negotiable design
- NixOS host module; KVM/Libvirt via NixVirt, Podman and standard Compose/Dockerfiles; Cockpit is the sole web control plane. No Incus, Docker daemon, Portainer, Arcane or parallel dashboard.
- External Git repositories declare workloads without Nix boilerplate. Preserve their standard files and user changes. Local credentials, data and private keys must never enter Git, command logs or Nix store. Treat rootful workload authors as trusted administrators.
- Use small, testable components and native NixOS facilities. Prefer a single typed privileged backend, argument-vector subprocesses, explicit permissions, atomic writes and one shared lock. Do not introduce frameworks or dependencies without a concrete need.
- Separate editable worktrees, immutable candidate revisions and active deployed state. Auto-sync must be disabled until transactional deploy/rollback is proven. Never claim OS generation rollback restores volume data.
- Never mutate a live host or run destructive commands for testing; use disposable VMs and fixtures. Preserve boot, hardware, administrator, networking and stateVersion.
- Fail closed on validation, build, authorization or health errors. No fake green checks, swallowed errors, or placeholders presented as functionality.

## Work and Git
1. Pick the first incomplete milestone in docs/implementation.md. Inspect its relevant code and tests; implement the smallest complete vertical slice.
2. Write focused tests for normal and failure paths; run scripts/check.sh and the relevant Nix checks. Use the actual CI result, not assumptions.
3. Branch from current main as feat/<scope> or fix/<scope>. Conventional commits; no force-push, no unrelated formatting, no secrets, no bypassing failed checks. Open a focused PR with acceptance evidence and remaining limitations. Prefer squash merge only after all required checks pass and authorization permits.
4. Update only changed gate statuses and evidence links in docs/implementation.md; do not duplicate the spec. Mark a gate complete only when its stated tests pass. Stop at a real blocker and record the exact error; never invent a passing result.

## Token budget
Do not narrate routine steps, echo full file contents, or generate speculative designs. Use rg, git diff --stat, targeted reads, and concise test output; inspect full logs only on failure. Keep the final report to PR/commit, tests, blockers and next gate. Reuse existing implementation and test infrastructure. Do not spend time repeatedly polling CI; report pending checks as pending.

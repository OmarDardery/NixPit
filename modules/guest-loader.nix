# modules/guest-loader.nix — Default Host Workload & SOPS-Nix Compiler
#
# What: Instantiates mk-guest-loader.nix against the live host state directory (/var/lib/nixpit).
# Why:  Keeps dynamic repository `imports` completely free of `_module.args` / `config.*` cycles.
import ./mk-guest-loader.nix "/var/lib/nixpit"

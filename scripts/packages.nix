# Shared CLI script derivations wrapped with pkgs.writeShellApplication.
# Reused by both modules/host.nix and flake.nix so runtimeInputs stay in one place.
{ pkgs }:

{
  nixpit-install = pkgs.writeShellApplication {
    name = "nixpit-install";
    runtimeInputs = with pkgs; [ nix nixos-rebuild iproute2 jq coreutils gawk ];
    text = builtins.readFile ./install.sh;
  };

  nixpit-repo = pkgs.writeShellApplication {
    name = "nixpit-repo";
    runtimeInputs = with pkgs; [ git openssh jq coreutils findutils nix gnugrep ];
    text = builtins.readFile ./nixpit-repo.sh;
  };

  nixpit-secrets = pkgs.writeShellApplication {
    name = "nixpit-secrets";
    runtimeInputs = with pkgs; [ sops age jq coreutils findutils gnused gnugrep ];
    text = builtins.readFile ./nixpit-secrets.sh;
  };
}

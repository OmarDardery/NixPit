{ lib, pkgs, ... }:

let
  cockpit-homelab = pkgs.stdenv.mkDerivation {
    pname = "cockpit-homelab";
    version = "4.0.0";
    src = ../cockpit;
    passthru.cockpitPath = "/share/cockpit";
    installPhase = ''
      mkdir -p $out/share/cockpit/homelab-gitops
      cp -r * $out/share/cockpit/homelab-gitops/
    '';
  };
in {
  imports = lib.optional (builtins.pathExists /var/lib/nixpit/network.nix) /var/lib/nixpit/network.nix;

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # Virtualization Engines
  virtualisation.libvirt.enable = true;
  virtualisation.podman = {
    enable = true;
    dockerCompat = true;
    defaultNetwork.settings.dns_enabled = true;

  };

  # Cockpit Web UI
  services.cockpit = {
    enable = true;
    openFirewall = true;
    plugins = [ pkgs.cockpit-machines pkgs.cockpit-podman cockpit-homelab ];
  };

  # ble.sh for Cockpit's Web Terminal & SSH
  programs.bash.interactiveShellInit = ''
    [[ $- == *i* ]] && source ${pkgs.blesh}/share/blesh/ble.sh
  '';

  # Default Git identity for Cockpit Commit & Push
  programs.git = {
    enable = true;
    config = {
      user.name = "NixOS Hypervisor";
      user.email = "hypervisor@homelab.local";

    };
  };

  # Background Auto-Sync Service & Timer (toggled from Cockpit)
  systemd.services.homelab-autosync = {
    description = "Pull all Homelab guest Git repositories and redeploy if changed";
    path = with pkgs; [ git openssh nixos-rebuild nix jq ];
    environment = {
      GIT_SSH_COMMAND = "ssh -i /var/lib/nixpit/deploy_key -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new";
    };
    serviceConfig = {
      Type = "oneshot";
    };
    script = ''
      set -euo pipefail
      STATE="/var/lib/nixpit"
      CHANGED=0

      for name in $(jq -r '[].name' "$STATE/repos.json"); do
        dir="$STATE/repos/$name"
        [ -d "$dir/.git" ] || continue
        cd "$dir"
        [ -z "$(git status --porcelain)" ] || { echo "Dirty repo: $name"; exit 1; }
        git fetch origin
        LOCAL=$(git rev-parse HEAD)
        REMOTE=$(git rev-parse @{u} 2>/dev/null || echo "$LOCAL")
        if [ "$LOCAL" != "$REMOTE" ]; then
          git pull --ff-only
          CHANGED=1
        fi
      done

      if [ "$CHANGED" -eq 1 ]; then
        FLAKE=$(cat "$STATE/hypervisor.flake" 2>/dev/null || echo "path:/etc/nixpit#nixpit")
        nixos-rebuild switch --impure --flake "$FLAKE"
      else
        echo "All guest repositories are up to date."
      fi
    '';
  };

  # Prototype timer is deliberately not enabled by default.
  systemd.timers.homelab-autosync = {
    description = "Periodically sync Homelab guest Git repositories";
    timerConfig = {
      OnCalendar = "*:0/15";
      Persistent = true;
    };
  };

  environment.systemPackages = with pkgs; [
    cockpit-machines
    cockpit-podman
    cockpit-homelab
    podman-compose
    usbutils
    git
    jq
    openssh
  ];


}

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

  # Auto-sync intentionally unavailable until the transactional backend is implemented.

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

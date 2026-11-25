{ config, lib, pkgs, nixvirt, ... }:

let
  cfg = config.services.nixpit;

  cockpit-homelab = pkgs.stdenv.mkDerivation {
    pname = "cockpit-homelab";
    version = "4.0.0";
    src = ../cockpit;
    passthru.cockpitPath = [];
    installPhase = ''
      mkdir -p $out/share/cockpit/homelab-gitops
      cp manifest.json index.html app.js $out/share/cockpit/homelab-gitops/
    '';
  };

  cockpit-virtmon = pkgs.stdenv.mkDerivation {
    pname = "cockpit-virtmon";
    version = "1.0.0";
    src = ../cockpit/virtmon;
    passthru.cockpitPath = [];
    installPhase = ''
      mkdir -p $out/share/cockpit/nixpit-virtmon
      cp manifest.json index.html app.js $out/share/cockpit/nixpit-virtmon/
    '';
  };

  nixpit-virtmon = config.boot.kernelPackages.callPackage ../kernel/nixpit-virtmon { };
in {
  options.services.nixpit.virtmon.enable = lib.mkEnableOption "NixPit kernel virtualization monitor" // {
    default = true;
  };

  imports = lib.optional (builtins.pathExists /var/lib/nixpit/network.nix) /var/lib/nixpit/network.nix;

  config = {
    nix.settings.experimental-features = [ "nix-command" "flakes" ];

    # Kernel Virtualization & Monitor Module (.ko)
    boot.extraModulePackages = lib.optional cfg.virtmon.enable nixpit-virtmon;
    boot.kernelModules = [
      "kvm"
      "vhost_net"
      "tun"
    ] ++ lib.optional cfg.virtmon.enable "nixpit_virtmon";
    boot.extraModprobeConfig = ''
      options kvm_intel nested=1
      options kvm_amd nested=1
    '';

    # Virtualization Engines (KVM/QEMU/Libvirt + Rootful Podman)
    virtualisation.libvirt = {
      enable = true;
      swtpm.enable = true;
      connections."qemu:///system" = {
        networks = [
          {
            active = true;
            definition = nixvirt.lib.network.writeXML (nixvirt.lib.network.templates.bridge {
              name = "default";
              uuid = "b7a1e620-3f2e-4f4c-8d8a-9c1e2f3a4b5c";
              bridge_name = "virbr0";
              subnet_byte = 122;
            });
          }
        ];
        pools = [
          {
            active = true;
            definition = nixvirt.lib.pool.writeXML {
              type = "dir";
              name = "default";
              uuid = "a8c9f8b8-4c5d-4d6e-9f7a-1b2c3d4e5f60";
              target = {
                path = "/var/lib/libvirt/images";
              };
            };
          }
        ];
      };
    };

    virtualisation.libvirtd = {
      enable = true;
      onBoot = "ignore";
      onShutdown = "shutdown";
      qemu = {
        package = pkgs.qemu_kvm;
        runAsRoot = true;
        vhostUserPackages = [ pkgs.virtiofsd ];
      };
    };

    virtualisation.spiceUSBRedirection.enable = true;

    virtualisation.podman = {
      enable = true;
      dockerCompat = true;
      defaultNetwork.settings.dns_enabled = true;
    };

    # Allow VM NAT bridge traffic on virbr0
    networking.firewall.trustedInterfaces = [ "virbr0" ];

    systemd.tmpfiles.rules = [
      "d /var/lib/libvirt/images 0711 root root -"
    ];

    # Cockpit Web UI
    services.cockpit = {
      enable = true;
      openFirewall = true;
      plugins = [
        pkgs.cockpit-machines
        pkgs.cockpit-podman
        cockpit-homelab
      ] ++ lib.optional cfg.virtmon.enable cockpit-virtmon;
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
      libvirt
      qemu_kvm
      podman-compose
      pciutils
      usbutils
      git
      jq
      openssh
    ] ++ lib.optional cfg.virtmon.enable cockpit-virtmon;
  };
}

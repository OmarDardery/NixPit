{ config, lib, pkgs, nixvirt, ... }:

let
  cfg = config.services.nixpit;
  cli = import ../scripts/packages.nix { inherit pkgs; };

  mkCockpitPlugin = { pname, version, src, dest }: pkgs.stdenv.mkDerivation {
    inherit pname version src;
    passthru.cockpitPath = [];
    installPhase = ''
      mkdir -p $out/share/cockpit/${dest}
      cp manifest.json index.html app.js $out/share/cockpit/${dest}/
      cp ${../cockpit/theme.css} $out/share/cockpit/${dest}/theme.css
    '';
  };

  cockpit-homelab = mkCockpitPlugin {
    pname = "cockpit-homelab";
    version = "4.0.0";
    src = ../cockpit;
    dest = "homelab-gitops";
  };

  cockpit-virtmon = mkCockpitPlugin {
    pname = "cockpit-virtmon";
    version = "1.0.0";
    src = ../cockpit/virtmon;
    dest = "nixpit-virtmon";
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

    # Virtualization Engines (KVM/QEMU/Libvirt via NixVirt + Rootful Podman)
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
              target = { path = "/var/lib/libvirt/images"; };
            };
          }
        ];
      };
    };

    virtualisation.libvirtd = {
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

    networking.firewall.trustedInterfaces = [ "virbr0" ];

    # Shared Age identity for sops-nix and nixpit-secrets.service
    sops.age = {
      keyFile = lib.mkDefault "/var/lib/nixpit/sops/age/keys.txt";
      generateKey = lib.mkDefault true;
      sshKeyPaths = lib.mkDefault [];
    };
    sops.gnupg.sshKeyPaths = lib.mkDefault [];

    systemd.tmpfiles.rules = [
      "d /var/lib/libvirt/images 0711 root root -"
      "d ${cfg.stateDir}/sops 0700 root root -"
      "d ${cfg.stateDir}/sops/age 0700 root root -"
      "d ${cfg.stateDir}/secrets 0700 root root -"
      "d /run/nixpit 0755 root root -"
      "d /run/nixpit/secrets 0700 root root -"
    ];

    systemd.services.nixpit-secrets = {
      description = "NixPit SOPS secret management service";
      wantedBy = [ "multi-user.target" ];
      before = [ "podman.service" ];
      after = [ "local-fs.target" ];
      environment = {
        NIXPIT_STATE_DIR = cfg.stateDir;
        NIXPIT_RUNTIME_DIR = "/run/nixpit/secrets";
      };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${cli.nixpit-secrets}/bin/nixpit-secrets sync";
      };
    };

    services.cockpit = {
      enable = true;
      openFirewall = true;
      plugins = [
        pkgs.cockpit-machines
        pkgs.cockpit-podman
        cockpit-homelab
      ] ++ lib.optional cfg.virtmon.enable cockpit-virtmon;
    };

    programs.bash.interactiveShellInit = ''
      [[ $- == *i* ]] && source ${pkgs.blesh}/share/blesh/ble.sh
    '';

    programs.git = {
      enable = true;
      config = {
        user.name = "NixOS Hypervisor";
        user.email = "hypervisor@homelab.local";
      };
    };

    environment.systemPackages = with pkgs; [
      cli.nixpit-repo
      cli.nixpit-secrets
      sops
      age
      libvirt
      qemu_kvm
      podman-compose
      pciutils
      usbutils
      git
      jq
      openssh
    ];
  };
}

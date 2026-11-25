# modules/host.nix — NixOS Hypervisor Platform Configuration
#
# What: Configures the base NixOS host with KVM/Libvirt virtualization, rootful
#       Podman, Cockpit web UI (+ our custom plugins), the nixpit_virtmon.ko
#       kernel module, and SOPS/Age secret decryption (sops-nix + nixpit-secrets).
# How:  Declares NixOS options in a pure attrset (`config = { ... }`) so the
#       NixOS module system builds systemd units, kernel modules, and firewall
#       rules deterministically.
# Why:  Separates the stable OS platform from dynamic workload repos loaded by
#       modules/guest-loader.nix.

{ config, lib, pkgs, nixvirt, ... }:

let
  cfg = config.services.nixpit;
  cli = import ../scripts/packages.nix { inherit pkgs; };

  # Package a Cockpit web plugin directory into /share/cockpit/<dest>/ along with
  # the shared Vercel dark stylesheet (cockpit/theme.css).
  # passthru.cockpitPath = [] tells NixOS's services.cockpit module where to link it.
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

  # Compile nixpit_virtmon.ko against the exact kernelPackages configured on this host.
  nixpit-virtmon = config.boot.kernelPackages.callPackage ../kernel/nixpit-virtmon { };
in {
  # Allow disabling the kernel monitor cleanly without removing the rest of NixPit.
  options.services.nixpit.virtmon.enable = lib.mkEnableOption "NixPit kernel virtualization monitor" // {
    default = true;
  };

  # Optionally import static network config created during host bootstrap if present.
  imports = lib.optional (builtins.pathExists /var/lib/nixpit/network.nix) /var/lib/nixpit/network.nix;

  config = {
    nix.settings.experimental-features = [ "nix-command" "flakes" ];

    # Build and auto-load KVM, vhost_net, tun, and our nixpit_virtmon.ko module at boot.
    # Nested virtualization options are set for both Intel and AMD via modprobe.d rather
    # than forcing kvm_intel/kvm_amd in boot.kernelModules (which fails on the other CPU).
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

    # Enable KVM/Libvirt via NixVirt and declaratively provision the default NAT bridge
    # network (virbr0, 192.168.122.0/24) and default directory pool (/var/lib/libvirt/images).
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

    # Configure QEMU/KVM runtime: virtiofsd for shared host folders and SPICE USB redirection.
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

    # Rootful Podman with Docker CLI compatibility and container DNS enabled.
    virtualisation.podman = {
      enable = true;
      dockerCompat = true;
      defaultNetwork.settings.dns_enabled = true;
    };

    # Trust virbr0 in the host firewall so VMs can get DHCP leases and DNS from dnsmasq.
    networking.firewall.trustedInterfaces = [ "virbr0" ];

    # Configure sops-nix to use the single host Age identity (/var/lib/nixpit/sops/age/keys.txt).
    # Keeping the literal path prevents Nix store-context errors when tests override cfg.stateDir.
    sops.age = {
      keyFile = lib.mkDefault "/var/lib/nixpit/sops/age/keys.txt";
      generateKey = lib.mkDefault true;
      sshKeyPaths = lib.mkDefault [];
    };
    sops.gnupg.sshKeyPaths = lib.mkDefault [];

    # Create persistent directories for VM disks, encrypted secrets, and tmpfs runtime secrets.
    systemd.tmpfiles.rules = [
      "d /var/lib/libvirt/images 0711 root root -"
      "d ${cfg.stateDir}/sops 0700 root root -"
      "d ${cfg.stateDir}/sops/age 0700 root root -"
      "d ${cfg.stateDir}/secrets 0700 root root -"
      "d /run/nixpit 0755 root root -"
      "d /run/nixpit/secrets 0700 root root -"
    ];

    # Decrypt host-managed SOPS secrets into tmpfs (/run/nixpit/secrets) before containers start.
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

    # Enable Cockpit web control plane on port 9090 with VMs, Podman, and NixPit panels.
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

    # Host CLI tools needed by Cockpit actions, Libvirt/QEMU, Podman Compose, and SOPS.
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

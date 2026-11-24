{
  description = "NixPit — declarative GitOps hypervisor appliance";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixvirt = {
      url = "https://flakehub.com/f/AshleyYakeley/NixVirt/*.tar.gz";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  outputs = { self, nixpkgs, nixvirt, ... }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
    installer = pkgs.writeShellApplication {
      name = "nixpit-install";
      runtimeInputs = with pkgs; [ nix iproute2 coreutils python3 iputils systemd ];
      text = ''
        export NIXPIT_INSTALLER=${./scripts/installer.py}
        export NIXPIT_DEFAULT_SOURCE="github:OmarDardery/NixPit/${self.rev or "main"}"
        ${builtins.readFile ./scripts/install.sh}
      '';
    };
  in {
    apps.${system}.install = { type = "app"; program = "${installer}/bin/nixpit-install"; };
    packages.${system}.default = installer;
    nixosModules.default = { ... }: {
      imports = [ nixvirt.nixosModules.default ./modules/host.nix ./modules/guest-loader.nix ];
      _module.args.nixvirt = nixvirt;
    };
    # Evaluation fixture only: not a deployable host or a boot test.
    nixosConfigurations.ci = nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        self.nixosModules.default
        {
          system.stateVersion = "25.11";
          boot.loader.grub.enable = false;
          fileSystems."/" = { device = "/dev/vda"; fsType = "ext4"; };
        }
      ];
    };
    checks.${system} = {
    platform-paths = let
      config = self.nixosConfigurations.ci.config;
    in pkgs.runCommand "nixpit-platform-paths" {} ''
      test -x ${pkgs.podman-compose}/bin/podman-compose
      test -r ${pkgs.blesh}/share/blesh/ble.sh
      test -x ${pkgs.cockpit}/bin/cockpit-bridge
      test -r ${pkgs.cockpit-machines}/share/cockpit/machines/manifest.json
      test -r ${pkgs.cockpit-podman}/share/cockpit/podman/manifest.json
      ${pkgs.lib.concatMapStringsSep "\n" (plugin:
        "test -d ${plugin}/share/cockpit") config.services.cockpit.plugins}
      touch $out
    '';
    javascript = pkgs.runCommand "nixpit-js-check" { nativeBuildInputs = [ pkgs.nodejs ]; } ''
      node --check ${./cockpit/app.js}
      touch $out
    '';
    };
  };
}

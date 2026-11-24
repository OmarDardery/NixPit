{
  description = "NixPit — declarative GitOps hypervisor appliance";
  inputs = {
    # Git transport keeps locking reproducible without the GitHub API; stable channel for an appliance.
    nixpkgs.url = "git+https://github.com/NixOS/nixpkgs?ref=nixos-26.05&shallow=1";
    nixvirt = {
      url = "git+https://github.com/AshleyYakeley/NixVirt?ref=refs/tags/v0.6.0&shallow=1";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  outputs = { self, nixpkgs, nixvirt, ... }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
    installer = pkgs.writeShellApplication {
      name = "nixpit-install";
      runtimeInputs = with pkgs; [ nix nixos-rebuild iproute2 jq coreutils gawk ];
      text = builtins.readFile ./scripts/install.sh;
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
      javascript = pkgs.runCommand "nixpit-js-check" { nativeBuildInputs = [ pkgs.nodejs ]; } ''
        node --check ${./cockpit/app.js}
        touch $out
      '';
      installer = installer;
      # Verifies evaluated service units and the realised Cockpit plugin/dependency paths of the fixture.
      host-paths = let
        cfg = self.nixosConfigurations.ci.config;
        units = builtins.attrNames cfg.systemd.units;
        required = [ "cockpit.socket" "libvirtd.service" "podman.socket" ];
        missing = builtins.filter (u: !(builtins.elem u units)) required;
        forbidden = builtins.filter (u: builtins.match "nixpit-(auto-)?sync.*" u != null) units;
        share = cfg.environment.etc."cockpit/share".source;
        bin = cfg.environment.etc."cockpit/bin".source;
      in
        assert missing == [ ] || throw "NixPit fixture missing units: ${toString missing}";
        assert forbidden == [ ] || throw "NixPit auto-sync must stay disabled: ${toString forbidden}";
        pkgs.runCommand "nixpit-host-paths" { } ''
          for plugin in homelab-gitops machines podman; do
            test -f ${share}/cockpit/$plugin/manifest.json || { echo "missing Cockpit plugin $plugin" >&2; exit 1; }
          done
          test -f ${share}/cockpit/homelab-gitops/index.html
          test -x ${bin}/git || { echo "plugin runtime dependency git missing" >&2; exit 1; }
          touch $out
        '';
    };
  };
}

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
    checks.${system}.javascript = pkgs.runCommand "nixpit-js-check" { nativeBuildInputs = [ pkgs.nodejs ]; } ''
      node --check ${./cockpit/app.js}
      touch $out
    '';
  };
}

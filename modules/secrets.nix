{ config, lib, pkgs, ... }:

let
  cfg = config.services.nixpit;
  nixpit-secrets = pkgs.writeShellApplication {
    name = "nixpit-secrets";
    runtimeInputs = with pkgs; [ sops age jq coreutils findutils gnused ];
    text = builtins.readFile ../scripts/nixpit-secrets.sh;
  };
in {
  config = {
    # Configure sops-nix to use the shared host Age identity
    sops.age = {
      keyFile = lib.mkDefault "/var/lib/nixpit/sops/age/keys.txt";
      generateKey = lib.mkDefault true;
      sshKeyPaths = lib.mkDefault [];
    };
    sops.gnupg.sshKeyPaths = lib.mkDefault [];

    systemd.tmpfiles.rules = [
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
        ExecStart = "${nixpit-secrets}/bin/nixpit-secrets sync";
      };
    };

    environment.systemPackages = [
      nixpit-secrets
      pkgs.sops
      pkgs.age
    ];
  };
}

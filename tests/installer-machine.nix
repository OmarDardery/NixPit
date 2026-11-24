{ pkgs, lib, ... }: {
  system.stateVersion = "25.11";
  system.nixos.versionSuffix = lib.mkForce ".nixpit-test";
  system.nixos.revision = lib.mkForce null;
  nixpkgs.hostPlatform = "x86_64-linux";
  nix.enable = true;
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    sandbox = false;
    substituters = lib.mkForce [];
    connect-timeout = 1;
  };
  boot.loader.grub.enable = false;
  networking.hostName = "machine";
  networking.useDHCP = false;
  networking.useNetworkd = false;
  networking.interfaces.eth0.useDHCP = false;
  networking.interfaces.eth1.useDHCP = true;
  networking.interfaces.eth1.ipv4.addresses = [];
  services.openssh.enable = true;
  services.openssh.settings.PasswordAuthentication = true;
  users.users.admin = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    initialPassword = "nixpit-fixture-only";
  };
  security.sudo.wheelNeedsPassword = false;
  environment.systemPackages = with pkgs; [ python3 iputils ];
  virtualisation.writableStore = true;
  virtualisation.writableStoreUseTmpfs = false;
  virtualisation.diskSize = 8192;
  virtualisation.memorySize = 3072;
}

{ pkgs, lib, ... }: {
  system.stateVersion = "25.11";
  # Keep the VM driver console alive across candidate activation.
  system.switch.enable = true;
  systemd.services.backdoor = {
    restartIfChanged = false;
    stopIfChanged = false;
  };
  system.nixos.versionSuffix = lib.mkOverride 40 ".nixpit-test";
  system.nixos.revision = lib.mkOverride 40 null;
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

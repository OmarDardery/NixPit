{ pkgs, nixpkgs, nixvirt, self, installer }:

let
  qemuModule = nixpkgs.outPath + "/nixos/modules/virtualisation/qemu-vm.nix";
  testBase = nixpkgs.outPath + "/nixos/lib/testing/nixos-test-base.nix";
  baseModule = ./installer-machine.nix;
  # The offline source uses the same pinned inputs and the actual production module.
  # Only the transport changes: CI test guests have no internet.
  source = pkgs.writeTextDir "flake.nix" ''
    {
      inputs.nixpkgs.url = "path:${nixpkgs.outPath}";
      inputs.nixvirt.url = "path:${nixvirt.outPath}";
      inputs.nixvirt.inputs.nixpkgs.follows = "nixpkgs";
      outputs = { nixpkgs, nixvirt, ... }: {
        nixosModules.default = { ... }: {
          imports = [
            nixvirt.nixosModules.default
            ${self.outPath}/modules/host.nix
            ${self.outPath}/modules/guest-loader.nix
          ];
          _module.args.nixvirt = nixvirt;
        };
      };
    }
  '';
  hostConfig = pkgs.writeText "configuration.nix" ''
    { ... }: { imports = [ ${qemuModule} ${testBase} ${baseModule} ]; }
  '';
  staticModule = address: gateway: { lib, ... }: {
    networking.interfaces.eth1.useDHCP = lib.mkForce false;
    networking.interfaces.eth1.ipv4.addresses = lib.mkForce [{ inherit address; prefixLength = 24; }];
    networking.defaultGateway = lib.mkForce { address = gateway; interface = "eth1"; };
    networking.nameservers = lib.mkForce [ "192.168.77.1" ];
  };
  candidate = network: (nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [ qemuModule testBase baseModule self.nixosModules.default network ];
  }).config.system.build.toplevel;
  prepared = [
    (candidate {})
    (candidate (staticModule "192.168.77.20" "192.168.77.1"))
    (candidate (staticModule "192.168.77.30" "192.168.77.254"))
  ];
in pkgs.testers.runNixOSTest {
  name = "nixpit-installer-end-to-end";
  nodes.machine = { lib, ... }: {
    imports = [ baseModule ];
    networking.interfaces.eth1.ipv4.addresses = lib.mkForce [];
    virtualisation.vlans = [ 1 ];
    virtualisation.additionalPaths = [
      source hostConfig baseModule self.outPath nixpkgs.outPath nixvirt.outPath installer
    ] ++ prepared;
  };
  nodes.peer = { pkgs, lib, ... }: {
    virtualisation.vlans = [ 1 ];
    networking.interfaces.eth1.ipv4.addresses = lib.mkForce [{ address = "192.168.77.1"; prefixLength = 24; }];
    networking.firewall.allowedUDPPorts = [ 67 ];
    services.dnsmasq = {
      enable = true;
      settings = {
        port = 0;
        interface = "eth1";
        bind-interfaces = true;
        dhcp-range = "192.168.77.10,192.168.77.10,255.255.255.0,1h";
        dhcp-option = [ "3,192.168.77.1" "6,192.168.77.1" ];
      };
    };
    environment.systemPackages = [ pkgs.sshpass pkgs.openssh ];
  };
  testScript = ''
    import shlex

    print("G1: boot DHCP peer")
    peer.start()
    peer.wait_for_unit("dnsmasq.service")
    print("G1: boot target")
    machine.start()
    machine.wait_for_unit("sshd.service")
    machine.succeed("mkdir -p /etc/nixos; cp ${hostConfig} /etc/nixos/configuration.nix")
    machine.succeed("nix-env --profile /nix/var/nix/profiles/system --set $(readlink -f /run/current-system)")

    def ssh(ip, command):
        return "sshpass -p nixpit-fixture-only ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null admin@" + ip + " " + shlex.quote(command)

    def check(ip, command):
        peer.wait_until_succeeds(ssh(ip, command), timeout=180)

    install = "${installer}/bin/nixpit-install --yes"
    print("G1: verify DHCP and remote login")
    machine.succeed("ip -4 addr; ip -4 route")
    check("192.168.77.10", "sudo -n true")
    print("G1: initial install")
    peer.succeed(ssh("192.168.77.10", install + " path:${source}"), timeout=900)
    check("192.168.77.10", "sudo -n test -e /etc/nixpit/active/flake.lock")
    check("192.168.77.10", "sudo -n systemctl is-active cockpit.socket")
    check("192.168.77.10", "sudo -n cmp /etc/nixos/configuration.nix ${hostConfig}")
    peer.succeed(ssh("192.168.77.10", "sudo -n sh -c 'printf fixture > /var/lib/nixpit/secrets/keep.env; chmod 600 /var/lib/nixpit/secrets/keep.env'"))
    print("G1: reinstall")
    peer.succeed(ssh("192.168.77.10", install), timeout=900)
    check("192.168.77.10", "sudo -n grep -qx fixture /var/lib/nixpit/secrets/keep.env")

    # Launch through a detached outer service; the SSH connection can drop on cutover.
    def launch(ip, unit, arguments, result):
        script = install + " " + arguments + "; rc=$?; echo $rc > " + result + "; exit $rc"
        peer.succeed(ssh(ip, "sudo -n systemd-run --no-block --unit=" + unit + " /bin/sh -c " + shlex.quote(script)))

    print("G1: successful static cutover")
    launch("192.168.77.10", "g1-good-cutover",
           "--static 192.168.77.20/24 --gateway 192.168.77.1 --dns 192.168.77.1",
           "/var/lib/nixpit/good-result")
    check("192.168.77.20", "sudo -n grep -qx 0 /var/lib/nixpit/good-result")
    check("192.168.77.20", "sudo -n test -f /etc/nixpit/active/static.json")
    before = peer.succeed(ssh("192.168.77.20", "sudo -n readlink /etc/nixpit/active")).strip()
    before_system = peer.succeed(ssh("192.168.77.20", "readlink -f /run/current-system; readlink -f /nix/var/nix/profiles/system")).strip()
    print("G1: failed static cutover and recovery")
    launch("192.168.77.20", "g1-bad-cutover",
           "--static 192.168.77.30/24 --gateway 192.168.77.254 --dns 192.168.77.1",
           "/var/lib/nixpit/bad-result")
    check("192.168.77.20", "sudo -n grep -qx 1 /var/lib/nixpit/bad-result")
    after = peer.succeed(ssh("192.168.77.20", "sudo -n readlink /etc/nixpit/active")).strip()
    assert before == after, (before, after)
    after_system = peer.succeed(ssh("192.168.77.20", "readlink -f /run/current-system; readlink -f /nix/var/nix/profiles/system")).strip()
    assert before_system == after_system, (before_system, after_system)
    check("192.168.77.20", "sudo -n journalctl -u nixpit-bootstrap --no-pager | grep -F 'Connectivity/SSH check failed'")
    check("192.168.77.20", "sudo -n grep -qx fixture /var/lib/nixpit/secrets/keep.env")
    check("192.168.77.20", "sudo -n cmp /etc/nixos/configuration.nix ${hostConfig}")
  '';
}

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
    ciSystem = nixpkgs.lib.nixosSystem {
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
    virtmon = ciSystem.config.boot.kernelPackages.callPackage ./kernel/nixpit-virtmon { };

    fixtureState = pkgs.runCommand "nixpit-fixture-state" {} ''
      mkdir -p "$out/repos/test-repo" "$out/secrets"
      cat > "$out/repos.json" <<'JSON'
      [
        { "name": "test-repo", "url": "https://github.com/example/test-repo.git" }
      ]
JSON
      cat > "$out/repos/test-repo/guests.json" <<'JSON'
      {
        "containers": {
          "web": {
            "image": "docker.io/library/nginx:alpine",
            "ports": ["8080:80", "5353:5353/udp", "[::]:8443:443/tcp"],
            "volumes": ["/var/lib/web:/data", "/etc/nixpit-forbidden:/ro:ro"],
            "network": "app-net",
            "domain": "app.home.arpa"
          },
          "local-only": {
            "image": "docker.io/library/redis:alpine",
            "ports": ["127.0.0.1:3000:3000", "[::1]:3001:3001"]
          }
        },
        "vms": {
          "vm-default": {
            "uuid": "cc7439ed-36af-4696-a6f2-1f0c4474d87e",
            "vcpus": 2,
            "memoryGiB": 2,
            "disk": "debian-13.qcow2",
            "network": "default",
            "usbPassthrough": ["0bda:8812"],
            "active": true
          },
          "vm-bridge": {
            "uuid": "dd7439ed-36af-4696-a6f2-1f0c4474d87f",
            "vcpus": 4,
            "memoryGiB": 4,
            "disk": "/var/lib/libvirt/images/custom.qcow2",
            "network": "br0",
            "active": false
          }
        }
      }
JSON
      cat > "$out/repos/test-repo/compose.yaml" <<'YAML'
      services:
        demo:
          image: docker.io/library/alpine:3.20
          command: ["sleep", "infinity"]
YAML
    '';

    mkFixtureSystem = stateDir: (nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        self.nixosModules.default
        {
          system.stateVersion = "25.11";
          boot.loader.grub.enable = false;
          fileSystems."/" = { device = "/dev/vda"; fsType = "ext4"; };
          services.nixpit.stateDir = stateDir;
        }
      ];
    }).config;

    fixtureCfg = mkFixtureSystem "${fixtureState}";

    badDupDomainState = pkgs.runCommand "nixpit-bad-dup-domain" {} ''
      mkdir -p "$out/repos/bad"
      printf '[{"name":"bad","url":"https://github.com/example/bad.git"}]\n' > "$out/repos.json"
      cat > "$out/repos/bad/guests.json" <<'JSON'
      {
        "containers": {
          "a": { "image": "alpine:3.20", "ports": ["8081:80"], "domain": "dup.home.arpa" },
          "b": { "image": "alpine:3.20", "ports": ["8082:80"], "domain": "dup.home.arpa" }
        }
      }
JSON
    '';

    badDupPortState = pkgs.runCommand "nixpit-bad-dup-port" {} ''
      mkdir -p "$out/repos/bad"
      printf '[{"name":"bad","url":"https://github.com/example/bad.git"}]\n' > "$out/repos.json"
      cat > "$out/repos/bad/guests.json" <<'JSON'
      {
        "containers": {
          "a": { "image": "alpine:3.20", "ports": ["8080:80"] },
          "b": { "image": "alpine:3.20", "ports": ["8080:8080"] }
        }
      }
JSON
    '';

    badUuidState = pkgs.runCommand "nixpit-bad-uuid" {} ''
      mkdir -p "$out/repos/bad"
      printf '[{"name":"bad","url":"https://github.com/example/bad.git"}]\n' > "$out/repos.json"
      cat > "$out/repos/bad/guests.json" <<'JSON'
      {
        "vms": {
          "vm1": { "uuid": "not-a-uuid", "disk": "vm1.qcow2" }
        }
      }
JSON
    '';

    badNetState = pkgs.runCommand "nixpit-bad-net" {} ''
      mkdir -p "$out/repos/bad"
      printf '[{"name":"bad","url":"https://github.com/example/bad.git"}]\n' > "$out/repos.json"
      cat > "$out/repos/bad/guests.json" <<'JSON'
      {
        "containers": {
          "a": { "image": "alpine:3.20", "network": "bad;net" }
        }
      }
JSON
    '';

    badSecretState = pkgs.runCommand "nixpit-bad-secret" {} ''
      mkdir -p "$out/repos/bad"
      printf '[{"name":"bad","url":"https://github.com/example/bad.git"}]\n' > "$out/repos.json"
      cat > "$out/repos/bad/guests.json" <<'JSON'
      {
        "containers": {
          "a": { "image": "alpine:3.20", "secretName": "../escape" }
        }
      }
JSON
    '';
  in {
    apps.${system}.install = {
      type = "app";
      program = "${installer}/bin/nixpit-install";
      meta.description = "Install and configure NixPit on an existing NixOS host";
    };

    packages.${system} = {
      default = installer;
      inherit virtmon;
      vm-test = pkgs.testers.runNixOSTest {
        name = "nixpit-virtualization-vm-test";
        nodes.machine = { ... }: {
          imports = [ self.nixosModules.default ];
          virtualisation.memorySize = 2048;
          virtualisation.cores = 2;
        };
        testScript = ''
          import json

          machine.start()
          machine.wait_for_unit("multi-user.target")
          machine.wait_for_unit("libvirtd.service")
          machine.wait_for_unit("cockpit.socket")
          machine.succeed("systemctl show -p Result nixvirt.service | grep -q 'Result=success'")

          # Verify kernel module is loaded
          lsmod_out = machine.succeed("lsmod")
          assert "nixpit_virtmon" in lsmod_out, f"nixpit_virtmon missing from lsmod:\n{lsmod_out}"

          # Verify /proc/nixpit_virtmon/status JSON and active probes
          status_raw = machine.succeed("cat /proc/nixpit_virtmon/status")
          status = json.loads(status_raw)
          assert status["module"] == "nixpit_virtmon", status
          assert status["probes"]["module_notifier"] is True, status
          assert status["probes"]["netdev_notifier"] is True, status
          assert status["probes"]["vfs_open_kprobe"] is True, status

          # Trigger probe snapshot and verify events NDJSON + dmesg
          machine.succeed("printf 'probe\n' > /proc/nixpit_virtmon/control")
          events_raw = machine.succeed("cat /proc/nixpit_virtmon/events")
          events = [json.loads(line) for line in events_raw.strip().splitlines() if line.strip()]
          assert len(events) >= 2, f"Expected >=2 events, got: {events_raw}"
          assert any(e["category"] == "system" and "probe snapshot" in e["message"] for e in events), events

          dmesg_out = machine.succeed("journalctl -k -g nixpit_virtmon --no-pager")
          assert "nixpit_virtmon" in dmesg_out, dmesg_out

          # Verify clear control works
          machine.succeed("printf 'clear\n' > /proc/nixpit_virtmon/control")
          cleared_raw = machine.succeed("cat /proc/nixpit_virtmon/events")
          cleared_events = [json.loads(line) for line in cleared_raw.strip().splitlines() if line.strip()]
          assert len(cleared_events) == 1 and "cleared" in cleared_events[0]["message"], cleared_events

          # Verify libvirt default network & storage pool exist and are active
          net_out = machine.succeed("virsh net-list --all")
          assert "default" in net_out and "active" in net_out, net_out
          pool_out = machine.succeed("virsh pool-list --all")
          assert "default" in pool_out and "active" in pool_out, pool_out

          # Verify Cockpit plugins are installed in /etc/cockpit/share/cockpit
          machine.succeed("test -r /etc/cockpit/share/cockpit/homelab-gitops/manifest.json")
          machine.succeed("test -r /etc/cockpit/share/cockpit/nixpit-virtmon/manifest.json")
        '';
      };
    };

    nixosModules.default = { ... }: {
      imports = [ nixvirt.nixosModules.default ./modules/host.nix ./modules/guest-loader.nix ];
      _module.args.nixvirt = nixvirt;
    };

    # Evaluation fixture only: not a deployable host or a boot test.
    nixosConfigurations.ci = ciSystem;

    checks.${system} = {
      platform-paths = let
        config = ciSystem.config;
      in pkgs.runCommand "nixpit-platform-paths" {} ''
        test -x ${pkgs.podman-compose}/bin/podman-compose
        test -r ${pkgs.blesh}/share/blesh/ble.sh
        test -x ${pkgs.cockpit}/bin/cockpit-bridge
        test -r ${pkgs.cockpit-machines}/share/cockpit/machines/manifest.json
        test -r ${pkgs.cockpit-podman}/share/cockpit/podman/manifest.json
        test -x ${pkgs.libvirt}/bin/virsh
        test -x ${pkgs.qemu_kvm}/bin/qemu-system-x86_64
        test -x ${pkgs.virtiofsd}/bin/virtiofsd
        test -x ${pkgs.swtpm}/bin/swtpm
        ls ${virtmon}/lib/modules/*/extra/nixpit_virtmon.ko* >/dev/null
        test -n "$(find ${virtmon}/lib/modules -type f \( -name 'nixpit_virtmon.ko' -o -name 'nixpit_virtmon.ko.xz' -o -name 'nixpit_virtmon.ko.zst' \) | head -n 1)"
        ${pkgs.lib.concatMapStringsSep "\n" (plugin:
          "test -d ${plugin}/share/cockpit") config.services.cockpit.plugins}
        touch $out
      '';

      javascript = pkgs.runCommand "nixpit-js-check" { nativeBuildInputs = [ pkgs.nodejs ]; } ''
        node --check ${./cockpit/app.js}
        node --check ${./cockpit/virtmon/app.js}
        touch $out
      '';

      virtmon-ko = pkgs.runCommand "nixpit-virtmon-ko-check" {
        nativeBuildInputs = [ pkgs.kmod pkgs.xz pkgs.zstd ];
      } ''
        ko=$(find ${virtmon}/lib/modules -type f \( -name 'nixpit_virtmon.ko' -o -name 'nixpit_virtmon.ko.xz' -o -name 'nixpit_virtmon.ko.zst' \) | head -n 1)
        test -n "$ko"
        cp "$ko" ./
        fname=$(basename "$ko")
        case "$fname" in
          *.xz) xz -d "$fname"; fname="''${fname%.xz}" ;;
          *.zst) zstd -d "$fname"; fname="''${fname%.zst}" ;;
        esac
        modinfo "./$fname" | tee modinfo.txt
        grep -q '^license:[[:space:]]*GPL$' modinfo.txt
        grep -q '^vermagic:' modinfo.txt
        touch $out
      '';

      guest-loader-eval = let
        domains = fixtureCfg.virtualisation.libvirt.connections."qemu:///system".domains;
        networks = fixtureCfg.virtualisation.libvirt.connections."qemu:///system".networks;
        pools = fixtureCfg.virtualisation.libvirt.connections."qemu:///system".pools;
        tcpPorts = fixtureCfg.networking.firewall.allowedTCPPorts;
        udpPorts = fixtureCfg.networking.firewall.allowedUDPPorts;
        tmpRules = fixtureCfg.systemd.tmpfiles.rules;
        caddyOn = fixtureCfg.services.caddy.enable;
        hasVhost = fixtureCfg.services.caddy.virtualHosts ? "http://app.home.arpa";
        hasNetUnit = fixtureCfg.systemd.services ? "podman-network-app-net";
        hasComposeUnit = fixtureCfg.systemd.services ? "homelab-compose-test-repo";
        dom0Xml = (builtins.elemAt domains 1).definition;
        dom1Xml = (builtins.elemAt domains 0).definition;
      in
        assert builtins.length domains == 2;
        assert builtins.length networks == 1;
        assert builtins.length pools == 1;
        assert pkgs.lib.elem 8080 tcpPorts;
        assert pkgs.lib.elem 8443 tcpPorts;
        assert pkgs.lib.elem 80 tcpPorts;
        assert pkgs.lib.elem 443 tcpPorts;
        assert !(pkgs.lib.elem 3000 tcpPorts);
        assert !(pkgs.lib.elem 3001 tcpPorts);
        assert udpPorts == [ 5353 ];
        assert caddyOn && hasVhost && hasNetUnit && hasComposeUnit;
        assert pkgs.lib.elem "d /var/lib/web 0755 root root -" tmpRules;
        assert !(pkgs.lib.any (r: pkgs.lib.hasInfix "/etc/nixpit-forbidden" r) tmpRules);
        pkgs.runCommand "nixpit-guest-loader-eval" {
          nativeBuildInputs = [ pkgs.libxml2 ];
        } ''
          xmllint --noout ${dom0Xml}
          xmllint --noout ${dom1Xml}
          grep -q "<interface type='network'>" ${dom0Xml} || grep -q '<interface type="network">' ${dom0Xml}
          grep -q "<source network='default'/>" ${dom0Xml} || grep -q '<source network="default"/>' ${dom0Xml}
          grep -q "<hostdev mode='subsystem' type='usb' managed='yes'>" ${dom0Xml} || grep -q '<hostdev mode="subsystem" type="usb" managed="yes">' ${dom0Xml}
          ! grep -q 'accel3d' ${dom0Xml}
          grep -q "<interface type='bridge'>" ${dom1Xml} || grep -q '<interface type="bridge">' ${dom1Xml}
          grep -q "<source bridge='br0'/>" ${dom1Xml} || grep -q '<source bridge="br0"/>' ${dom1Xml}
          grep -q "/var/lib/libvirt/images/custom.qcow2" ${dom1Xml}
          touch $out
        '';

      guest-loader-failures = let
        evalRejects = stateDir:
          let
            cfg = mkFixtureSystem "${stateDir}";
            res = builtins.tryEval (builtins.deepSeq [
              cfg.networking.firewall.allowedTCPPorts
              cfg.networking.firewall.allowedUDPPorts
              cfg.services.caddy.virtualHosts
              cfg.virtualisation.libvirt.connections."qemu:///system".domains
              cfg.virtualisation.oci-containers.containers
            ] true);
          in !res.success;
      in
        assert evalRejects badDupDomainState;
        assert evalRejects badDupPortState;
        assert evalRejects badUuidState;
        assert evalRejects badNetState;
        assert evalRejects badSecretState;
        pkgs.runCommand "nixpit-guest-loader-failures" {} ''
          touch $out
        '';
    };
  };
}

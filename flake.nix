# flake.nix — Top-level Nix flake for NixPit
#
# What: Declares pinned dependencies (nixpkgs, NixVirt, sops-nix) and exports the
#       NixOS appliance module, installer, nixpit_virtmon.ko package, checks, and
#       a disposable QEMU VM integration test (`packages.x86_64-linux.vm-test`).
# Why:  Keeps kernel headers, packages, and tests reproducible via flake.lock.

{
  description = "NixPit — declarative GitOps hypervisor appliance";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixvirt = {
      url = "https://flakehub.com/f/AshleyYakeley/NixVirt/*.tar.gz";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  outputs = { self, nixpkgs, nixvirt, sops-nix, ... }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
    cli = import ./scripts/packages.nix { inherit pkgs; };

    # Minimal NixOS evaluation fixture used by CI and to extract the target kernelPackages.
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

    # Build a synthetic NixPit state directory containing pure Nix workload modules (`nix/*.nix`),
    # `compose.yaml`, and SOPS-encrypted dotenv secrets to test guest-loader.nix offline.
    fixtureState = pkgs.runCommand "nixpit-fixture-state" {
      nativeBuildInputs = [ pkgs.age pkgs.sops ];
    } ''
      mkdir -p "$out/repos/test-repo/nix" "$out/repos/test-repo/secrets" "$out/secrets" "$out/sops/age"
      age-keygen -o "$out/sops/age/keys.txt" 2>/dev/null
      pub=$(age-keygen -y "$out/sops/age/keys.txt")

      printf 'WEB_TOKEN=fixture-sops-token\n' > web.env
      SOPS_AGE_KEY_FILE="$out/sops/age/keys.txt" sops --encrypt --age "$pub" \
        --input-type dotenv --output-type dotenv web.env > "$out/repos/test-repo/secrets/web.sops.env"

      printf 'COMPOSE_API_KEY=compose-sops-key\n' > compose.env
      SOPS_AGE_KEY_FILE="$out/sops/age/keys.txt" sops --encrypt --age "$pub" \
        --input-type dotenv --output-type dotenv compose.env > "$out/repos/test-repo/secrets/compose.sops.env"

      cat > "$out/repos.json" <<'JSON'
      [{ "name": "test-repo", "url": "https://github.com/example/test-repo.git", "branch": "main" }]
JSON
      cat > "$out/repos/test-repo/nix/web.nix" <<'NIX'
      { ... }: {
        services.nixpit.workloads.containers.web = {
          image = "docker.io/library/nginx:alpine";
          ports = [ "8080:80" "5353:5353/udp" "[::]:8443:443/tcp" ];
          volumes = [ "/var/lib/web:/data" "/etc/nixpit-forbidden:/ro:ro" ];
          network = "app-net";
          domain = "app.home.arpa";
          secretName = "web";
        };
      }
NIX
      cat > "$out/repos/test-repo/nix/local-only.nix" <<'NIX'
      { ... }: {
        services.nixpit.workloads.containers.local-only = {
          image = "docker.io/library/redis:alpine";
          ports = [ "127.0.0.1:3000:3000" "[::1]:3001:3001" ];
        };
      }
NIX
      cat > "$out/repos/test-repo/nix/vm-default.nix" <<'NIX'
      { ... }: {
        services.nixpit.workloads.vms.vm-default = {
          uuid = "cc7439ed-36af-4696-a6f2-1f0c4474d87e";
          vcpus = 2;
          memoryGiB = 2;
          disk = "debian-13.qcow2";
          network = "default";
          usbPassthrough = [ "0bda:8812" ];
          active = true;
        };
      }
NIX
      cat > "$out/repos/test-repo/nix/vm-bridge.nix" <<'NIX'
      { ... }: {
        services.nixpit.workloads.vms.vm-bridge = {
          uuid = "dd7439ed-36af-4696-a6f2-1f0c4474d87f";
          vcpus = 4;
          memoryGiB = 4;
          disk = "/var/lib/libvirt/images/custom.qcow2";
          network = "br0";
          active = false;
        };
      }
NIX
      cat > "$out/repos/test-repo/compose.yaml" <<'YAML'
      services:
        demo:
          image: docker.io/library/alpine:3.20
          command: ["sleep", "infinity"]
YAML
    '';

    # Synthetic state containing a standalone Dockerfile + SOPS secret (no compose.yaml).
    dockerfileFixtureState = pkgs.runCommand "nixpit-dockerfile-fixture" {
      nativeBuildInputs = [ pkgs.age pkgs.sops ];
    } ''
      mkdir -p "$out/repos/df-repo/secrets" "$out/sops/age"
      age-keygen -o "$out/sops/age/keys.txt" 2>/dev/null
      pub=$(age-keygen -y "$out/sops/age/keys.txt")
      printf 'DF_SECRET=df-ok\n' > df.env
      SOPS_AGE_KEY_FILE="$out/sops/age/keys.txt" sops --encrypt --age "$pub" \
        --input-type dotenv --output-type dotenv df.env > "$out/repos/df-repo/secrets/dockerfile.sops.env"
      printf '[{ "name": "df-repo", "url": "https://github.com/example/df-repo.git", "branch": "main" }]\n' > "$out/repos.json"
      printf 'FROM alpine:3.20\nCMD ["sleep", "10"]\n' > "$out/repos/df-repo/Dockerfile"
    '';

    # Evaluate NixPit against a custom stateDir passed cleanly to mk-guest-loader (no infinite recursion).
    mkFixtureSystem = stateDir: (nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        nixvirt.nixosModules.default
        sops-nix.nixosModules.sops
        ./modules/host.nix
        (import ./modules/mk-guest-loader.nix "${stateDir}")
        {
          _module.args.nixvirt = nixvirt;
          system.stateVersion = "25.11";
          boot.loader.grub.enable = false;
          fileSystems."/" = { device = "/dev/vda"; fsType = "ext4"; };
        }
      ];
    }).config;

    fixtureCfg = mkFixtureSystem "${fixtureState}";
    dockerfileCfg = mkFixtureSystem "${dockerfileFixtureState}";

    # Helper to construct invalid Nix workload fixtures for fail-closed negative tests.
    mkBadState = name: nixText: pkgs.runCommand "nixpit-bad-${name}" {} ''
      mkdir -p "$out/repos/bad"
      printf '[{"name":"bad","url":"https://github.com/example/bad.git"}]\n' > "$out/repos.json"
      cat > "$out/repos/bad/workloads.nix" <<'NIX'
      ${nixText}
NIX
    '';

    # Ephemeral Age keypair + encrypted secret used inside the QEMU VM integration test.
    vmSopsFixture = pkgs.runCommand "nixpit-vm-sops-fixture" {
      nativeBuildInputs = [ pkgs.age pkgs.sops ];
    } ''
      mkdir -p "$out"
      age-keygen -o "$out/keys.txt" 2>/dev/null
      pub=$(age-keygen -y "$out/keys.txt")
      printf 'VM_SOPS_OK=yes\n' > secret.env
      SOPS_AGE_KEY_FILE="$out/keys.txt" sops --encrypt --age "$pub" \
        --input-type dotenv --output-type dotenv secret.env > "$out/vm-secret.sops.env"
    '';
  in {
    apps.${system}.install = {
      type = "app";
      program = "${cli.nixpit-install}/bin/nixpit-install";
      meta.description = "Install and configure NixPit on an existing NixOS host";
    };

    packages.${system} = {
      default = cli.nixpit-install;
      inherit virtmon;

      # Disposable NixOS QEMU VM test verifying nixpit_virtmon.ko, Libvirt/NixVirt,
      # Cockpit plugin packaging, sops-nix, nixpit-secrets repo roundtrip, and nixpit-repo.
      vm-test = pkgs.testers.runNixOSTest {
        name = "nixpit-virtualization-vm-test";
        nodes.machine = { lib, ... }: {
          imports = [ self.nixosModules.default ];
          virtualisation.memorySize = 2048;
          virtualisation.cores = 2;

          # Seed the test Age private key before sops-nix's setupSecrets activation runs.
          system.activationScripts.seedVmAgeKey = lib.stringAfter [ ] ''
            install -d -m 0700 /var/lib/nixpit/sops/age
            cp ${vmSopsFixture}/keys.txt /var/lib/nixpit/sops/age/keys.txt
            chmod 0600 /var/lib/nixpit/sops/age/keys.txt
          '';
          system.activationScripts.setupSecrets.deps = [ "seedVmAgeKey" ];

          sops.secrets."nixpit/vm-secret" = {
            sopsFile = "${vmSopsFixture}/vm-secret.sops.env";
            format = "dotenv";
            key = "";
            mode = "0400";
          };
        };
        testScript = ''
          import json

          machine.start()
          machine.wait_for_unit("multi-user.target")
          machine.wait_for_unit("libvirtd.service")
          machine.wait_for_unit("cockpit.socket")
          machine.succeed("systemctl show -p Result nixvirt.service | grep -q 'Result=success'")
          machine.succeed("systemctl show -p Result nixpit-secrets.service | grep -q 'Result=success'")

          # 1. Kernel module + /proc interface + dmesg
          assert "nixpit_virtmon" in machine.succeed("lsmod")
          status = json.loads(machine.succeed("cat /proc/nixpit_virtmon/status"))
          assert status["module"] == "nixpit_virtmon", status
          assert all(status["probes"][p] is True for p in ("module_notifier", "netdev_notifier", "vfs_open_kprobe", "exec_kprobe")), status

          machine.succeed("printf 'probe\n' > /proc/nixpit_virtmon/control")
          events = [json.loads(l) for l in machine.succeed("cat /proc/nixpit_virtmon/events").splitlines() if l.strip()]
          assert any(e["category"] == "system" and "probe snapshot" in e["message"] for e in events), events
          assert "nixpit_virtmon" in machine.succeed("journalctl -k -g nixpit_virtmon --no-pager")

          machine.succeed("printf 'clear\n' > /proc/nixpit_virtmon/control")
          cleared = [json.loads(l) for l in machine.succeed("cat /proc/nixpit_virtmon/events").splitlines() if l.strip()]
          assert len(cleared) == 1 and "cleared" in cleared[0]["message"], cleared

          # 2. Libvirt default network & pool + Cockpit manifests & shared theme.css
          assert "active" in machine.succeed("virsh net-list --all")
          assert "active" in machine.succeed("virsh pool-list --all")
          for p in ("homelab-gitops", "nixpit-virtmon"):
            machine.succeed(f"test -r /etc/cockpit/share/cockpit/{p}/manifest.json")
            machine.succeed(f"test -r /etc/cockpit/share/cockpit/{p}/theme.css")

          # 3. sops-nix & repo-scoped SOPS encrypt -> push -> pull -> decrypt/edit -> push
          assert machine.succeed("stat -c '%a' /run/secrets/nixpit/vm-secret").strip() == "400"
          assert machine.succeed("cat /run/secrets/nixpit/vm-secret").strip() == "VM_SOPS_OK=yes"

          machine.succeed("""
            set -eu
            git init --bare /tmp/remote.git
            git clone /tmp/remote.git /tmp/seed
            git -C /tmp/seed -c user.name=Test -c user.email=t@t checkout -b main
            printf '{ ... }: { services.nixpit.workloads.containers.demo = { image = "docker.io/library/nginx:alpine"; ports = [ "8080:80" ]; }; }\n' > /tmp/seed/workloads.nix
            git -C /tmp/seed add workloads.nix
            git -C /tmp/seed -c user.name=Test -c user.email=t@t commit -m init
            git -C /tmp/seed push origin main

            nixpit-repo add lab /tmp/remote.git main
            test "$(stat -c '%a' /var/lib/nixpit/keys/lab.ed25519)" = "600"
            nixpit-repo sync lab
            inspected=$(nixpit-repo inspect lab)
            echo "$inspected" | jq -e '.containers.demo.image == "docker.io/library/nginx:alpine"'

            printf 'DB_PASS=first-pass\n' | nixpit-secrets repo-set lab demo
            test -f /var/lib/nixpit/repos/lab/.sops.yaml
            ! grep -q 'first-pass' /var/lib/nixpit/repos/lab/secrets/demo.sops.env
            test "$(nixpit-secrets repo-get lab demo)" = "DB_PASS=first-pass"
            nixpit-repo push lab "add demo secret"

            nixpit-repo add lab2 /tmp/remote.git main
            nixpit-repo sync lab2
            test "$(nixpit-secrets repo-get lab2 demo)" = "DB_PASS=first-pass"
            printf 'DB_PASS=edited-pass\n' | nixpit-secrets repo-set lab2 demo
            nixpit-repo push lab2 "edit demo secret"

            nixpit-repo sync lab
            test "$(nixpit-secrets repo-get lab demo)" = "DB_PASS=edited-pass"
            nixpit-repo remove lab --purge
            nixpit-repo remove lab2 --purge
          """)
        '';
      };
    };

    # Combined NixOS module imported by real hosts and test fixtures.
    nixosModules.default = { ... }: {
      imports = [
        nixvirt.nixosModules.default
        sops-nix.nixosModules.sops
        ./modules/host.nix
        ./modules/guest-loader.nix
      ];
      _module.args.nixvirt = nixvirt;
    };

    nixosConfigurations.ci = ciSystem;

    checks.${system} = {
      # Verify all platform binaries, Cockpit plugins, and nixpit_virtmon.ko exist in the build.
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
        test -x ${pkgs.sops}/bin/sops
        test -x ${pkgs.age}/bin/age-keygen
        test -x ${cli.nixpit-repo}/bin/nixpit-repo
        test -x ${cli.nixpit-secrets}/bin/nixpit-secrets
        test -n "$(find ${virtmon}/lib/modules -type f \( -name 'nixpit_virtmon.ko' -o -name 'nixpit_virtmon.ko.xz' -o -name 'nixpit_virtmon.ko.zst' \) | head -n 1)"
        ${pkgs.lib.concatMapStringsSep "\n" (plugin:
          "test -d ${plugin}/share/cockpit") config.services.cockpit.plugins}
        touch $out
      '';

      # Verify JS syntax of both Cockpit panels with Node.js.
      javascript = pkgs.runCommand "nixpit-js-check" { nativeBuildInputs = [ pkgs.nodejs ]; } ''
        node --check ${./cockpit/app.js}
        node --check ${./cockpit/virtmon/app.js}
        touch $out
      '';

      # Verify nixpit_virtmon.ko compiles cleanly and exposes GPL license + kernel vermagic.
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

      # Run sandboxed end-to-end tests on nixpit-repo and nixpit-secrets CLIs:
      # pull -> inspect -> encrypt repo SOPS -> push -> pull in 2nd checkout -> edit -> push -> pull.
      cli-tests = pkgs.runCommand "nixpit-cli-tests" {
        nativeBuildInputs = [ pkgs.git pkgs.openssh pkgs.jq pkgs.sops pkgs.age pkgs.nix ];
      } ''
        set -eu
        export NIXPIT_STATE_DIR="$TMPDIR/state"
        export NIXPIT_RUNTIME_DIR="$TMPDIR/run"
        export GIT_AUTHOR_NAME="NixPit CI"
        export GIT_AUTHOR_EMAIL="ci@nixpit.local"
        export GIT_COMMITTER_NAME="NixPit CI"
        export GIT_COMMITTER_EMAIL="ci@nixpit.local"

        git init --bare "$TMPDIR/remote.git"
        git clone "$TMPDIR/remote.git" "$TMPDIR/seed"
        git -C "$TMPDIR/seed" checkout -b main
        mkdir -p "$TMPDIR/seed/nix"
        cat > "$TMPDIR/seed/nix/web.nix" <<'NIX'
        { ... }: {
          services.nixpit.workloads.containers.web = {
            image = "docker.io/library/nginx:alpine";
            ports = [ "8080:80" ];
          };
        }
NIX
        printf 'services:\n  web:\n    image: alpine:3.20\n' > "$TMPDIR/seed/compose.yaml"
        printf 'FROM alpine:3.20\n' > "$TMPDIR/seed/Dockerfile"
        git -C "$TMPDIR/seed" add nix/web.nix compose.yaml Dockerfile
        git -C "$TMPDIR/seed" commit -m init
        git -C "$TMPDIR/seed" push origin main

        ${cli.nixpit-repo}/bin/nixpit-repo add p1 "file://$TMPDIR/remote.git" main >/dev/null
        test "$(stat -c '%a' "$NIXPIT_STATE_DIR/keys/p1.ed25519")" = "600"
        ${cli.nixpit-repo}/bin/nixpit-repo sync p1
        inspected=$(${cli.nixpit-repo}/bin/nixpit-repo inspect p1)
        echo "$inspected" | jq -e '.containers.web.image == "docker.io/library/nginx:alpine"'
        echo "$inspected" | jq -e '.composeFile == "compose.yaml" and .hasDockerfile == true'

        pub=$(${cli.nixpit-secrets}/bin/nixpit-secrets pubkey)
        [[ "$pub" == age1* ]]
        ${cli.nixpit-secrets}/bin/nixpit-secrets sops-config | grep -q "$pub"

        printf 'API_TOKEN=super-secret-v1\nDB_URL=postgres://db\n' | ${cli.nixpit-secrets}/bin/nixpit-secrets repo-set p1 web >/dev/null
        test -f "$NIXPIT_STATE_DIR/repos/p1/.sops.yaml"
        ! grep -q 'super-secret-v1' "$NIXPIT_STATE_DIR/repos/p1/secrets/web.sops.env"
        ${cli.nixpit-secrets}/bin/nixpit-secrets repo-list p1 | jq -e '.secrets == ["web"] and .hasSopsYaml == true'
        ${cli.nixpit-secrets}/bin/nixpit-secrets repo-get p1 web | grep -q '^API_TOKEN=super-secret-v1$'

        ${cli.nixpit-repo}/bin/nixpit-repo push p1 "encrypt web env"

        # Clone into p2, pull, decrypt & edit env vars, push back, pull in p1
        ${cli.nixpit-repo}/bin/nixpit-repo add p2 "file://$TMPDIR/remote.git" main >/dev/null
        ${cli.nixpit-repo}/bin/nixpit-repo sync p2
        ${cli.nixpit-secrets}/bin/nixpit-secrets repo-get p2 web | grep -q '^API_TOKEN=super-secret-v1$'
        printf 'API_TOKEN=rotated-secret-v2\nDB_URL=postgres://db2\n' | ${cli.nixpit-secrets}/bin/nixpit-secrets repo-set p2 web >/dev/null
        ${cli.nixpit-repo}/bin/nixpit-repo push p2 "rotate web env"

        ${cli.nixpit-repo}/bin/nixpit-repo sync p1
        ${cli.nixpit-secrets}/bin/nixpit-secrets repo-get p1 web | grep -q '^API_TOKEN=rotated-secret-v2$'

        # Plaintext .env files must be rejected by push (fail-closed)
        printf 'LEAK=plaintext\n' > "$NIXPIT_STATE_DIR/repos/p1/secret.env"
        if ${cli.nixpit-repo}/bin/nixpit-repo push p1 "should fail" 2>/dev/null; then
          echo "Expected push with plaintext .env to fail" >&2
          exit 1
        fi
        rm -f "$NIXPIT_STATE_DIR/repos/p1/secret.env"

        ${cli.nixpit-repo}/bin/nixpit-repo keygen p1 --force >/dev/null
        ${cli.nixpit-repo}/bin/nixpit-repo remove p1 --purge >/dev/null
        ${cli.nixpit-repo}/bin/nixpit-repo remove p2 --purge >/dev/null
        test ! -d "$NIXPIT_STATE_DIR/repos/p1"
        touch $out
      '';

      # Verify guest-loader.nix compiles Nix modules, Compose, Dockerfile, Caddy, sops-nix, and VM XMLs.
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
        composeEnvFiles = fixtureCfg.systemd.services."homelab-compose-test-repo".serviceConfig.EnvironmentFile or [];
        composeSopsPath = fixtureCfg.sops.secrets."nixpit/test-repo/compose".path;
        hasSopsSecret = fixtureCfg.sops.secrets ? "nixpit/test-repo/web";
        webEnvFiles = fixtureCfg.virtualisation.oci-containers.containers.web.environmentFiles;
        sopsPath = fixtureCfg.sops.secrets."nixpit/test-repo/web".path;
        sopsManifest = fixtureCfg.system.build.sops-nix-manifest;
        hasDockerfileUnit = dockerfileCfg.systemd.services ? "homelab-dockerfile-df-repo";
        dfExec = dockerfileCfg.systemd.services."homelab-dockerfile-df-repo".serviceConfig.ExecStart;
        dfSecretPath = dockerfileCfg.sops.secrets."nixpit/df-repo/dockerfile".path;
        dom0Xml = (builtins.elemAt domains 1).definition;
        dom1Xml = (builtins.elemAt domains 0).definition;
      in
        assert builtins.length domains == 2;
        assert builtins.length networks == 1;
        assert builtins.length pools == 1;
        assert pkgs.lib.elem 8080 tcpPorts && pkgs.lib.elem 8443 tcpPorts && pkgs.lib.elem 80 tcpPorts && pkgs.lib.elem 443 tcpPorts;
        assert !(pkgs.lib.elem 3000 tcpPorts) && !(pkgs.lib.elem 3001 tcpPorts);
        assert udpPorts == [ 5353 ];
        assert caddyOn && hasVhost && hasNetUnit && hasComposeUnit;
        assert pkgs.lib.elem composeSopsPath composeEnvFiles;
        assert hasSopsSecret && pkgs.lib.hasPrefix "/run/secrets/nixpit/test-repo/" sopsPath && pkgs.lib.elem sopsPath webEnvFiles;
        assert hasDockerfileUnit && pkgs.lib.hasInfix "--env-file ${dfSecretPath}" dfExec;
        assert pkgs.lib.elem "d /var/lib/web 0755 root root -" tmpRules;
        assert !(pkgs.lib.any (r: pkgs.lib.hasInfix "/etc/nixpit-forbidden" r) tmpRules);
        pkgs.runCommand "nixpit-guest-loader-eval" {
          nativeBuildInputs = [ pkgs.libxml2 ];
        } ''
          test -s ${sopsManifest}
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

      # Verify guest-loader.nix fails closed on duplicate domains/ports, bad UUIDs, and traversal.
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
        assert evalRejects (mkBadState "dup-domain" ''
          { ... }: {
            services.nixpit.workloads.containers = {
              a = { image = "alpine:3.20"; ports = [ "8081:80" ]; domain = "dup.home.arpa"; };
              b = { image = "alpine:3.20"; ports = [ "8082:80" ]; domain = "dup.home.arpa"; };
            };
          }
        '');
        assert evalRejects (mkBadState "dup-port" ''
          { ... }: {
            services.nixpit.workloads.containers = {
              a = { image = "alpine:3.20"; ports = [ "8080:80" ]; };
              b = { image = "alpine:3.20"; ports = [ "8080:8080" ]; };
            };
          }
        '');
        assert evalRejects (mkBadState "uuid" ''
          { ... }: {
            services.nixpit.workloads.vms.vm1 = { uuid = "not-a-uuid"; disk = "vm1.qcow2"; };
          }
        '');
        assert evalRejects (mkBadState "net" ''
          { ... }: {
            services.nixpit.workloads.containers.a = { image = "alpine:3.20"; network = "bad;net"; };
          }
        '');
        assert evalRejects (mkBadState "secret" ''
          { ... }: {
            services.nixpit.workloads.containers.a = { image = "alpine:3.20"; secretName = "../escape"; };
          }
        '');
        pkgs.runCommand "nixpit-guest-loader-failures" {} ''
          touch $out
        '';
    };
  };
}

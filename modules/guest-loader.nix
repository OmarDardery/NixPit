{ lib, pkgs, nixvirt, ... }:

let
  stateDir = "/var/lib/nixpit";
  reposDir = "${stateDir}/repos";
  secretsDir = "${stateDir}/secrets";

  registry = "${stateDir}/repos.json";
  repoNames = if builtins.pathExists registry then
    map (r: assert builtins.match "[a-zA-Z0-9][a-zA-Z0-9._-]*" r.name != null; r.name)
      (builtins.fromJSON (builtins.readFile registry)) else [];
  loadRepoGuests = name:
    let jsonFile = "${reposDir}/${name}/guests.json";
    in if builtins.pathExists jsonFile then builtins.fromJSON (builtins.readFile jsonFile) else {};
  loadedGuests = map loadRepoGuests repoNames;
  mergeUnique = key: lib.foldl' (acc: g:
    let next = g.${key} or {}; overlap = lib.intersectAttrs acc next;
    in if overlap != {} then throw "NixPit: duplicate ${key}: ${builtins.concatStringsSep ", " (builtins.attrNames overlap)}" else acc // next) {} loadedGuests;
  mergedContainers = mergeUnique "containers";
  mergedVms = mergeUnique "vms";

  # 2. Extract public host TCP ports (skip localhost-only bindings)
  extractPublicPort = portSpec:
    let
      parts = lib.splitString ":" portSpec;
      count = builtins.length parts;
    in
      if count == 2 then [ (lib.toInt (builtins.elemAt parts 0)) ]
      else if count == 3 && (builtins.elemAt parts 0) != "127.0.0.1" && (builtins.elemAt parts 0) != "::1" then
        [ (lib.toInt (builtins.elemAt parts 1)) ]
      else [];

  extractAnyHostPort = portSpec:
    let
      parts = lib.splitString ":" portSpec;
      count = builtins.length parts;
    in
      if count == 2 then builtins.elemAt parts 0
      else if count == 3 then builtins.elemAt parts 1
      else null;

  allContainerPorts = lib.unique (lib.concatMap (c:
    lib.concatMap extractPublicPort (c.ports or [])
  ) (builtins.attrValues mergedContainers));

  # 3. Extract custom Podman networks declared by containers
  customNetworks = lib.unique (lib.filter (n: n != null && n != "" && n != "host" && n != "bridge" && n != "none")
    (map (c: c.network or null) (builtins.attrValues mergedContainers)));

  # 4. Extract Caddy virtual hosts for containers with a `domain` field
  domainContainers = lib.filterAttrs (_: c: (c.domain or "") != "" && (c.ports or []) != []) mergedContainers;
  hasDomains = domainContainers != {};

  caddyVirtualHosts = lib.mapAttrs' (_: c:
    let
      port = extractAnyHostPort (builtins.head c.ports);
      isLocal = lib.hasSuffix ".local" c.domain || lib.hasSuffix ".lan" c.domain || lib.hasSuffix ".home.arpa" c.domain;
      hostKey = if isLocal then "http://${c.domain}" else c.domain;
    in {
      name = hostKey;
      value.extraConfig = ''
        reverse_proxy 127.0.0.1:${port}
      '';
    }
  ) domainContainers;

  # 5. Extract bind-mount host directories to auto-create via systemd.tmpfiles.rules
  extractHostDir = volSpec:
    let
      hostPath = builtins.head (lib.splitString ":" volSpec);
      isAbsolute = lib.hasPrefix "/" hostPath;
      isSystemPath =
        lib.hasPrefix "/dev" hostPath ||
        lib.hasPrefix "/sys" hostPath ||
        lib.hasPrefix "/proc" hostPath ||
        lib.hasPrefix "/run" hostPath;
    in
      if isAbsolute && !isSystemPath then [ "d ${hostPath} 0755 root root -" ] else [];

  allTmpfilesRules = lib.unique (
    [ "d ${secretsDir} 0700 root root -" ]
    ++ lib.concatMap (c:
      lib.concatMap extractHostDir (c.volumes or [])
    ) (builtins.attrValues mergedContainers)
  );

  # 6. Build NixVirt USB hostdev entries from "vendor:product" hex strings
  mkUsbHostdev = vp:
    let parts = lib.splitString ":" vp;
    in {
      mode = "subsystem";
      type = "usb";
      managed = true;
      source = {
        vendor = { id = lib.fromHexString (builtins.elemAt parts 0); };
        product = { id = lib.fromHexString (builtins.elemAt parts 1); };
      };
    };

  # 7. Detect repos containing compose.yaml or docker-compose.yml
  composeRepos = lib.filter (name:
    builtins.pathExists "${reposDir}/${name}/docker-compose.yml" ||
    builtins.pathExists "${reposDir}/${name}/compose.yaml"
  ) repoNames;
in {
  # Auto-create bind-mount host directories & secrets folder
  systemd.tmpfiles.rules = allTmpfilesRules;

  # Auto-open public container host ports (+ 80/443 if Caddy domains are used)
  networking.firewall.allowedTCPPorts =
    allContainerPorts ++ lib.optionals hasDomains [ 80 443 ];

  # Automatic Reverse Proxy via Caddy when any container declares `domain`
  services.caddy = lib.mkIf hasDomains {
    enable = true;
    virtualHosts = caddyVirtualHosts;
  };

  # Compile Declared Containers -> Podman OCI Containers
  virtualisation.oci-containers = {
    backend = "podman";
    containers = lib.mapAttrs (name: c:
      let
        secretPath = "${secretsDir}/${c.secretName or name}.env";
        autoSecret = lib.optional (builtins.pathExists secretPath) secretPath;
        netOpt = lib.optional ((c.network or "") != "") "--network=${c.network}";
      in {
        image = c.image;
        cmd = c.cmd or [];
        ports = c.ports or [];
        volumes = c.volumes or [];
        environment = c.environment or {};
        environmentFiles = lib.unique ((c.environmentFiles or []) ++ autoSecret);
        dependsOn = c.dependsOn or [];
        extraOptions =
          (c.extraOptions or [])
          ++ netOpt
          ++ (map (dev: "--device=${dev}:${dev}") (c.usbPassthrough or []));
      }
    ) mergedContainers;
  };

  # Compile Declared VMs -> NixVirt Libvirt Domains (with vCPUs, network, and USB hostdev passthrough)
  virtualisation.libvirt.connections."qemu:///system".domains =
    lib.mapAttrsToList (name: vm:
      let
        baseDomain = nixvirt.lib.domain.templates.linux {
          inherit name;
          uuid = vm.uuid;
          memory = { count = vm.memoryGiB or 2; unit = "GiB"; };
          storage_vol = { pool = "default"; volume = vm.disk; };
          bridge_name = if (vm.network or "default") != "default" then vm.network else null;
        };
        usbDevs = map mkUsbHostdev (vm.usbPassthrough or []);
        finalDomain = baseDomain // {
          vcpu = { count = vm.vcpus or 2; };
          devices = (baseDomain.devices or {}) // lib.optionalAttrs (usbDevs != []) {
            hostdev = (baseDomain.devices.hostdev or []) ++ usbDevs;
          };
        };
      in {
        active = vm.active or true;
        definition = nixvirt.lib.domain.writeXML finalDomain;
      }
    ) mergedVms;

  # Generate systemd services for custom Podman networks & Compose/Dockerfile repos
  systemd.services =
    (lib.mapAttrs' (name: c: lib.nameValuePair "podman-${name}" (lib.mkIf (lib.elem (c.network or "") customNetworks) {
      requires = [ "podman-network-${c.network}.service" ];
      after = [ "podman-network-${c.network}.service" ];
    })) mergedContainers)
    // (lib.listToAttrs (map (net: {
      name = "podman-network-${net}";
      value = {
        description = "Ensure Podman network ${net} exists";
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" "podman.service" ];
        path = [ pkgs.podman ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          podman network exists "${net}" || podman network create "${net}"
        '';
      };
    }) customNetworks))
    // (lib.listToAttrs (map (name: {
      name = "homelab-compose-${name}";
      value = {
        description = "Podman Compose stack for ${name}";
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" "podman.service" ];
        path = [ pkgs.podman pkgs.podman-compose ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          WorkingDirectory = "${reposDir}/${name}";
          ExecStart = "${pkgs.podman-compose}/bin/podman-compose up -d --build --remove-orphans";
          ExecStop = "${pkgs.podman-compose}/bin/podman-compose down";
        };
      };
    }) composeRepos));
}

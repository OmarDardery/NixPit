# modules/guest-loader.nix — Declarative Workload & SOPS Compiler
#
# What: Reads repos.json and each synced repository's guests.json / compose files
#       and translates them into Podman containers, Libvirt VM XML domains, firewall
#       rules, Caddy reverse proxies, tmpfiles directories, and sops-nix secrets.
# How:  Validates all identifiers, ports, domains, UUIDs, USB IDs, and paths at
#       Nix evaluation time (fail-closed via `throw`), then emits standard NixOS options.
# Why:  Lets external workload Git repos stay plain JSON/Compose/SOPS without Nix syntax.

{ config, lib, pkgs, nixvirt, ... }:

let
  cfg = config.services.nixpit;
  stateDir = cfg.stateDir;
  reposDir = "${stateDir}/repos";
  secretsDir = "${stateDir}/secrets";

  identRegex = "^[a-zA-Z0-9][a-zA-Z0-9._-]*$";
  uuidRegex = "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$";
  usbVpRegex = "^[0-9a-fA-F]{4}:[0-9a-fA-F]{4}$";
  domainRegex = "^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$";
  approvedMountRoots = [ "/var/lib/" "/srv/" "/mnt/" "/data/" ];

  # Reject unsafe names (shell metacharacters, slashes, or leading dots) used in unit/file names.
  assertIdent = kind: value:
    if builtins.isString value && builtins.match identRegex value != null then value
    else throw "NixPit: invalid ${kind} identifier '${toString value}'";

  # Reject empty paths or ".." traversal segments in volume/disk specifications.
  assertNoTraversal = kind: value:
    if builtins.isString value && value != "" && !(lib.hasInfix ".." value) then value
    else throw "NixPit: invalid ${kind} path '${toString value}'";

  # Load registered repo names from repos.json (empty list before any profile is added).
  registry = "${stateDir}/repos.json";
  repoNames =
    if builtins.pathExists registry then
      map (r: assertIdent "repository" (r.name or "")) (builtins.fromJSON (builtins.readFile registry))
    else [];

  # Read guests.json for each registered repository.
  loadedGuests = map (name:
    let jsonFile = "${reposDir}/${name}/guests.json";
    in { inherit name; data = if builtins.pathExists jsonFile then builtins.fromJSON (builtins.readFile jsonFile) else {}; }
  ) repoNames;

  # Merge containers/vms across all repos, failing closed if two repos declare the same name.
  # Tags each container with `_repo` so we know which repo owns `secrets/<secret>.sops.env`.
  mergeUnique = key:
    lib.foldl' (acc: entry:
      let
        raw = entry.data.${key} or {};
        next = if key == "containers" then lib.mapAttrs (_: v: v // { _repo = entry.name; }) raw else raw;
        overlap = lib.intersectAttrs acc next;
      in
        if overlap != {} then
          throw "NixPit: duplicate ${key}: ${builtins.concatStringsSep ", " (builtins.attrNames overlap)}"
        else acc // next
    ) {} loadedGuests;

  # Validate container fields and resolve whether SOPS secrets come from the repo or host.
  mergedContainers = lib.mapAttrs (name: c:
    let
      _name = assertIdent "container" name;
      _image =
        if builtins.isString (c.image or null) && c.image != "" then c.image
        else throw "NixPit: container '${name}' missing non-empty image";
      _secret = if (c.secretName or "") != "" then assertIdent "secretName" c.secretName else _name;
      _net = if (c.network or "") != "" then assertIdent "network" c.network else "";
      _dom =
        if (c.domain or "") != "" then
          if builtins.match domainRegex c.domain != null then c.domain
          else throw "NixPit: container '${name}' has invalid domain '${c.domain}'"
        else "";
      repoSopsFile = "${reposDir}/${c._repo}/secrets/${_secret}.sops.env";
      hostSopsFile = "${secretsDir}/${_secret}.sops.env";
    in c // {
      image = _image;
      secretName = _secret;
      network = _net;
      domain = _dom;
      _repoSopsFile = repoSopsFile;
      _hasRepoSops = builtins.pathExists repoSopsFile;
      _hasHostSops = builtins.pathExists hostSopsFile;
    }
  ) (mergeUnique "containers");

  # Validate VM fields (UUID, positive CPU/RAM, disk path, network/bridge, USB vendor:product).
  mergedVms = lib.mapAttrs (name: vm:
    let
      _name = assertIdent "vm" name;
      _uuid =
        if builtins.isString (vm.uuid or null) && builtins.match uuidRegex vm.uuid != null then vm.uuid
        else throw "NixPit: vm '${name}' has invalid uuid '${toString (vm.uuid or "")}'";
      _vcpus = let v = vm.vcpus or 2; in if builtins.isInt v && v >= 1 then v else throw "NixPit: vm '${name}' invalid vcpus";
      _mem = let m = vm.memoryGiB or 2; in if builtins.isInt m && m >= 1 then m else throw "NixPit: vm '${name}' invalid memoryGiB";
      _disk = assertNoTraversal "vm disk" (vm.disk or "");
      _pool = if (vm.storagePool or "") != "" then assertIdent "storagePool" vm.storagePool else "default";
      _net = if (vm.network or "default") != "default" then assertIdent "vm network" vm.network else "default";
      _usb = map (vp:
        if builtins.isString vp && builtins.match usbVpRegex vp != null then vp
        else throw "NixPit: vm '${name}' has invalid USB vendor:product '${toString vp}'"
      ) (vm.usbPassthrough or []);
    in vm // {
      uuid = _uuid; vcpus = _vcpus; memoryGiB = _mem;
      disk = _disk; storagePool = _pool; network = _net; usbPassthrough = _usb;
    }
  ) (mergeUnique "vms");

  # Register repo-committed `secrets/<name>.sops.env` files with sops-nix so they decrypt
  # into /run/secrets/nixpit/<name> (ramfs, mode 0400) at activation time.
  repoSopsSecrets = lib.listToAttrs (lib.concatLists (lib.mapAttrsToList (_: c:
    lib.optional c._hasRepoSops {
      name = "nixpit/${c.secretName}";
      value = {
        sopsFile = builtins.path { path = c._repoSopsFile; name = "nixpit-${c.secretName}.sops.env"; };
        format = "dotenv";
        key = "";
        mode = "0400";
      };
    }
  ) mergedContainers));

  # Parse `[hostIp:]hostPort:containerPort[/proto]` (including IPv6 brackets like `[::]:8443:443/tcp`).
  # Distinguishes loopback bindings (127.0.0.1 / ::1) from public bindings that need firewall holes.
  parsePortSpec = containerName: rawSpec:
    let
      protoParts = lib.splitString "/" rawSpec;
      protoCount = builtins.length protoParts;
      proto =
        if protoCount == 1 then "tcp"
        else if protoCount == 2 && (builtins.elemAt protoParts 1 == "tcp" || builtins.elemAt protoParts 1 == "udp") then
          builtins.elemAt protoParts 1
        else throw "NixPit: container '${containerName}' invalid port protocol '${rawSpec}'";
      addrPart = builtins.elemAt protoParts 0;
      ipv6Match = builtins.match "^\\[([0-9a-fA-F:]+)]:([0-9]+):([0-9]+)$" addrPart;
      stdParts = lib.splitString ":" addrPart;
      parsed =
        if ipv6Match != null then { hostIp = builtins.elemAt ipv6Match 0; hostPortStr = builtins.elemAt ipv6Match 1; }
        else if builtins.length stdParts == 2 then { hostIp = ""; hostPortStr = builtins.elemAt stdParts 0; }
        else if builtins.length stdParts == 3 then { hostIp = builtins.elemAt stdParts 0; hostPortStr = builtins.elemAt stdParts 1; }
        else throw "NixPit: container '${containerName}' invalid port spec '${rawSpec}'";
      hostPort =
        if builtins.match "^[0-9]+$" parsed.hostPortStr != null then lib.toInt parsed.hostPortStr
        else throw "NixPit: container '${containerName}' non-numeric port '${rawSpec}'";
      _portRange =
        if hostPort >= 1 && hostPort <= 65535 then hostPort
        else throw "NixPit: container '${containerName}' port ${toString hostPort} out of range";
      isLoopback = parsed.hostIp == "127.0.0.1" || parsed.hostIp == "::1";
    in { port = _portRange; inherit proto; isPublic = !isLoopback; key = "${proto}:${toString _portRange}"; };

  publicPorts = builtins.filter (p: p.isPublic) (lib.concatLists (lib.mapAttrsToList (name: c:
    map (p: parsePortSpec name p // { container = name; }) (c.ports or [])
  ) mergedContainers));

  # Fail closed if two containers try to publish the same host port+protocol.
  _uniquePublicPorts = lib.foldl' (seen: p:
    if builtins.hasAttr p.key seen then
      throw "NixPit: duplicate public port ${p.key} between '${seen.${p.key}}' and '${p.container}'"
    else seen // { ${p.key} = p.container; }
  ) {} publicPorts;

  customNetworks = lib.unique (lib.filter (n: n != "" && n != "host" && n != "bridge" && n != "none")
    (map (c: c.network) (builtins.attrValues mergedContainers)));

  domainContainers = lib.filterAttrs (_: c: c.domain != "") mergedContainers;
  hasDomains = domainContainers != {};

  # Fail closed if two containers claim the same reverse-proxy domain.
  _uniqueDomains = lib.foldl' (seen: entry:
    let dom = entry.value.domain;
    in if builtins.hasAttr dom seen then
      throw "NixPit: duplicate domain '${dom}' between '${seen.${dom}}' and '${entry.name}'"
    else seen // { ${dom} = entry.name; }
  ) {} (lib.attrsToList domainContainers);

  # Generate Caddy virtual hosts (`http://` for local .local/.lan/.home.arpa, HTTPS otherwise).
  caddyVirtualHosts = lib.mapAttrs' (name: c:
    let
      ports = c.ports or [];
      _hasPorts = if ports != [] then true else throw "NixPit: container '${name}' has domain '${c.domain}' without ports";
      firstPort = parsePortSpec name (builtins.head ports);
      isLocal = lib.hasSuffix ".local" c.domain || lib.hasSuffix ".lan" c.domain || lib.hasSuffix ".home.arpa" c.domain;
    in assert _hasPorts; {
      name = if isLocal then "http://${c.domain}" else c.domain;
      value.extraConfig = "reverse_proxy 127.0.0.1:${toString firstPort.port}\n";
    }
  ) domainContainers;

  # Emit systemd-tmpfiles directory rules only for approved persistent host data roots.
  extractHostDir = containerName: volSpec:
    let
      hostPath = builtins.head (lib.splitString ":" volSpec);
      _check = if lib.hasInfix ".." hostPath then throw "NixPit: container '${containerName}' volume '${volSpec}' contains '..'" else true;
    in assert _check; lib.optional (lib.any (r: lib.hasPrefix r hostPath) approvedMountRoots) "d ${hostPath} 0755 root root -";

  # Convert "vendor:product" hex strings into Libvirt XML <hostdev> attribute sets.
  mkUsbHostdev = vp:
    let parts = lib.splitString ":" vp;
    in {
      mode = "subsystem"; type = "usb"; managed = true;
      source = {
        vendor = { id = lib.fromHexString (builtins.elemAt parts 0); };
        product = { id = lib.fromHexString (builtins.elemAt parts 1); };
      };
    };

  # Detect repos that define a standard Podman Compose stack.
  composeRepos = lib.filter (name:
    builtins.pathExists "${reposDir}/${name}/docker-compose.yml" ||
    builtins.pathExists "${reposDir}/${name}/compose.yaml"
  ) repoNames;
in {
  # Configurable so tests can evaluate isolated fixture directories in /nix/store.
  options.services.nixpit.stateDir = lib.mkOption {
    type = lib.types.str;
    default = "/var/lib/nixpit";
    description = "Directory containing NixPit repository registry, checkouts, keys, and encrypted secrets.";
  };

  config = {
    sops.secrets = repoSopsSecrets;

    systemd.tmpfiles.rules = lib.unique (lib.concatLists (lib.mapAttrsToList (name: c:
      lib.concatMap (extractHostDir name) (c.volumes or [])
    ) mergedContainers));

    # Open firewall TCP/UDP ports only for non-loopback bindings (+ 80/443 when Caddy is used).
    networking.firewall.allowedTCPPorts =
      assert builtins.isAttrs _uniquePublicPorts;
      lib.unique (map (p: p.port) (builtins.filter (p: p.proto == "tcp") publicPorts))
      ++ lib.optionals hasDomains [ 80 443 ];
    networking.firewall.allowedUDPPorts =
      assert builtins.isAttrs _uniquePublicPorts;
      lib.unique (map (p: p.port) (builtins.filter (p: p.proto == "udp") publicPorts));

    services.caddy = lib.mkIf hasDomains {
      enable = true;
      virtualHosts = assert builtins.isAttrs _uniqueDomains; caddyVirtualHosts;
    };

    # Compile container definitions into Podman systemd units (`podman-<name>.service`).
    # Secret resolution order: 1) repo sops-nix -> 2) host SOPS tmpfs -> 3) legacy .env.
    virtualisation.oci-containers = {
      backend = "podman";
      containers = lib.mapAttrs (name: c:
        let
          legacySecret = "${secretsDir}/${c.secretName}.env";
          autoSecret =
            if c._hasRepoSops then [ config.sops.secrets."nixpit/${c.secretName}".path ]
            else if c._hasHostSops then [ "/run/nixpit/secrets/${c.secretName}.env" ]
            else lib.optional (builtins.pathExists legacySecret) legacySecret;
          netOpt = lib.optional (c.network != "") "--network=${c.network}";
        in {
          image = c.image;
          cmd = c.cmd or [];
          ports = c.ports or [];
          volumes = c.volumes or [];
          environment = c.environment or {};
          environmentFiles = lib.unique ((c.environmentFiles or []) ++ autoSecret);
          dependsOn = c.dependsOn or [];
          extraOptions = (c.extraOptions or []) ++ netOpt ++ map (dev: "--device=${dev}:${dev}") (c.usbPassthrough or []);
        }
      ) mergedContainers;
    };

    # Compile VM declarations into NixVirt Libvirt domain XMLs.
    # Uses virtio_video = null so SPICE binds to 127.0.0.1 without requiring host 3D GPU accel.
    virtualisation.libvirt.connections."qemu:///system".domains =
      lib.mapAttrsToList (name: vm:
        let
          isDefaultNet = vm.network == "default";
          baseDomain = nixvirt.lib.domain.templates.linux {
            inherit name;
            uuid = vm.uuid;
            memory = { count = vm.memoryGiB; unit = "GiB"; };
            storage_vol = if lib.hasPrefix "/" vm.disk then vm.disk else { pool = vm.storagePool; volume = vm.disk; };
            bridge_name = if isDefaultNet then "virbr0" else vm.network;
            virtio_video = null;
          };
          usbDevs = map mkUsbHostdev vm.usbPassthrough;
        in {
          active = vm.active or true;
          definition = nixvirt.lib.domain.writeXML (baseDomain // {
            vcpu = { count = vm.vcpus; };
            devices = (baseDomain.devices or {}) // {
              interface =
                if isDefaultNet then { type = "network"; model = { type = "virtio"; }; source = { network = "default"; }; }
                else baseDomain.devices.interface;
            } // lib.optionalAttrs (usbDevs != []) {
              hostdev = (baseDomain.devices.hostdev or []) ++ usbDevs;
            };
          });
        }
      ) mergedVms;

    # Generate ordering dependencies (custom networks + nixpit-secrets) and Compose stack units.
    systemd.services =
      (lib.mapAttrs' (name: c:
        let
          deps = lib.optional (lib.elem c.network customNetworks) "podman-network-${c.network}.service"
            ++ lib.optional (!c._hasRepoSops && c._hasHostSops) "nixpit-secrets.service";
        in lib.nameValuePair "podman-${name}" (lib.mkIf (deps != []) { requires = deps; after = deps; })
      ) mergedContainers)
      // (lib.listToAttrs (map (net: {
        name = "podman-network-${net}";
        value = {
          description = "Ensure Podman network ${net} exists";
          wantedBy = [ "multi-user.target" ];
          after = [ "network-online.target" "podman.service" ];
          path = [ pkgs.podman ];
          serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
          script = ''podman network exists "${net}" || podman network create "${net}"'';
        };
      }) customNetworks))
      // (lib.listToAttrs (map (name: {
        name = "homelab-compose-${name}";
        value = {
          description = "Podman Compose stack for ${name}";
          wantedBy = [ "multi-user.target" ];
          requires = [ "podman.service" ];
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
  };
}

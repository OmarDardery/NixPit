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

  assertIdent = kind: value:
    if builtins.isString value && builtins.match identRegex value != null then
      value
    else
      throw "NixPit: invalid ${kind} identifier '${toString value}'";

  assertNoTraversal = kind: value:
    if builtins.isString value && value != "" && !(lib.hasInfix ".." value) then
      value
    else
      throw "NixPit: invalid ${kind} path '${toString value}'";

  registry = "${stateDir}/repos.json";
  repoNames =
    if builtins.pathExists registry then
      map (r: assertIdent "repository" (r.name or ""))
        (builtins.fromJSON (builtins.readFile registry))
    else
      [];

  loadRepoGuests = name:
    let jsonFile = "${reposDir}/${name}/guests.json";
    in {
      inherit name;
      data = if builtins.pathExists jsonFile then builtins.fromJSON (builtins.readFile jsonFile) else {};
    };

  loadedGuests = map loadRepoGuests repoNames;

  mergeUnique = key:
    lib.foldl' (acc: entry:
      let
        raw = entry.data.${key} or {};
        next =
          if key == "containers" then
            lib.mapAttrs (_: v: v // { _repo = entry.name; }) raw
          else
            raw;
        overlap = lib.intersectAttrs acc next;
      in
        if overlap != {} then
          throw "NixPit: duplicate ${key}: ${builtins.concatStringsSep ", " (builtins.attrNames overlap)}"
        else
          acc // next
    ) {} loadedGuests;

  rawContainers = mergeUnique "containers";
  rawVms = mergeUnique "vms";

  # Validate containers
  mergedContainers = lib.mapAttrs (name: c:
    let
      _name = assertIdent "container" name;
      _image =
        if builtins.isString (c.image or null) && c.image != "" then c.image
        else throw "NixPit: container '${name}' missing non-empty image";
      _secret =
        if (c.secretName or "") != "" then assertIdent "secretName" c.secretName
        else _name;
      _net =
        if (c.network or "") != "" then assertIdent "network" c.network
        else "";
      _dom =
        if (c.domain or "") != "" then
          if builtins.match domainRegex c.domain != null then c.domain
          else throw "NixPit: container '${name}' has invalid domain '${c.domain}'"
        else "";
    in c // {
      image = _image;
      secretName = _secret;
      network = _net;
      domain = _dom;
    }
  ) rawContainers;

  # Validate VMs
  mergedVms = lib.mapAttrs (name: vm:
    let
      _name = assertIdent "vm" name;
      _uuid =
        if builtins.isString (vm.uuid or null) && builtins.match uuidRegex vm.uuid != null then vm.uuid
        else throw "NixPit: vm '${name}' has invalid uuid '${toString (vm.uuid or "")}'";
      _vcpus =
        let v = vm.vcpus or 2;
        in if builtins.isInt v && v >= 1 then v
           else throw "NixPit: vm '${name}' has invalid vcpus '${toString v}'";
      _mem =
        let m = vm.memoryGiB or 2;
        in if builtins.isInt m && m >= 1 then m
           else throw "NixPit: vm '${name}' has invalid memoryGiB '${toString m}'";
      _disk = assertNoTraversal "vm disk" (vm.disk or "");
      _pool =
        if (vm.storagePool or "") != "" then assertIdent "storagePool" vm.storagePool
        else "default";
      _net =
        if (vm.network or "default") != "default" then assertIdent "vm network" vm.network
        else "default";
      _usb = map (vp:
        if builtins.isString vp && builtins.match usbVpRegex vp != null then vp
        else throw "NixPit: vm '${name}' has invalid USB vendor:product '${toString vp}'"
      ) (vm.usbPassthrough or []);
    in vm // {
      uuid = _uuid;
      vcpus = _vcpus;
      memoryGiB = _mem;
      disk = _disk;
      storagePool = _pool;
      network = _net;
      usbPassthrough = _usb;
    }
  ) rawVms;

  # Repo-embedded SOPS secrets managed via sops-nix
  repoSopsSecrets = lib.listToAttrs (lib.concatLists (lib.mapAttrsToList (_: c:
    let repoSopsFile = "${reposDir}/${c._repo}/secrets/${c.secretName}.sops.env";
    in lib.optional (builtins.pathExists repoSopsFile) {
      name = "nixpit/${c.secretName}";
      value = {
        sopsFile = builtins.path {
          path = repoSopsFile;
          name = "nixpit-${c.secretName}.sops.env";
        };
        format = "dotenv";
        key = "";
        mode = "0400";
      };
    }
  ) mergedContainers));

  # Parse port specs: [hostIp:]hostPort:containerPort[/proto]
  parsePortSpec = containerName: rawSpec:
    let
      protoParts = lib.splitString "/" rawSpec;
      protoCount = builtins.length protoParts;
      proto =
        if protoCount == 1 then "tcp"
        else if protoCount == 2 && (builtins.elemAt protoParts 1 == "tcp" || builtins.elemAt protoParts 1 == "udp") then
          builtins.elemAt protoParts 1
        else
          throw "NixPit: container '${containerName}' has invalid port protocol in '${rawSpec}'";
      addrPart = builtins.elemAt protoParts 0;
      ipv6Match = builtins.match "^\\[([0-9a-fA-F:]+)]:([0-9]+):([0-9]+)$" addrPart;
      stdParts = lib.splitString ":" addrPart;
      parsed =
        if ipv6Match != null then {
          hostIp = builtins.elemAt ipv6Match 0;
          hostPortStr = builtins.elemAt ipv6Match 1;
        }
        else if builtins.length stdParts == 2 then {
          hostIp = "";
          hostPortStr = builtins.elemAt stdParts 0;
        }
        else if builtins.length stdParts == 3 then {
          hostIp = builtins.elemAt stdParts 0;
          hostPortStr = builtins.elemAt stdParts 1;
        }
        else
          throw "NixPit: container '${containerName}' has invalid port spec '${rawSpec}'";
      hostPort =
        if builtins.match "^[0-9]+$" parsed.hostPortStr != null then
          lib.toInt parsed.hostPortStr
        else
          throw "NixPit: container '${containerName}' has non-numeric host port in '${rawSpec}'";
      _portRange =
        if hostPort >= 1 && hostPort <= 65535 then hostPort
        else throw "NixPit: container '${containerName}' port ${toString hostPort} out of range (1..65535)";
      isLoopback = parsed.hostIp == "127.0.0.1" || parsed.hostIp == "::1";
    in {
      port = _portRange;
      inherit proto isLoopback;
      isPublic = !isLoopback;
      key = "${proto}:${toString _portRange}";
    };

  allParsedPorts = lib.concatLists (lib.mapAttrsToList (name: c:
    map (p: parsePortSpec name p // { container = name; }) (c.ports or [])
  ) mergedContainers);

  publicPortBindings = builtins.filter (p: p.isPublic) allParsedPorts;

  _uniquePublicPorts = lib.foldl' (seen: p:
    if builtins.hasAttr p.key seen then
      throw "NixPit: duplicate public port ${p.key} between '${seen.${p.key}}' and '${p.container}'"
    else
      seen // { ${p.key} = p.container; }
  ) {} publicPortBindings;

  allContainerTcpPorts = lib.unique (map (p: p.port) (builtins.filter (p: p.proto == "tcp") publicPortBindings));
  allContainerUdpPorts = lib.unique (map (p: p.port) (builtins.filter (p: p.proto == "udp") publicPortBindings));

  customNetworks = lib.unique (lib.filter (n: n != "" && n != "host" && n != "bridge" && n != "none")
    (map (c: c.network) (builtins.attrValues mergedContainers)));

  domainContainers = lib.filterAttrs (_: c: c.domain != "") mergedContainers;
  hasDomains = domainContainers != {};

  _uniqueDomains = lib.foldl' (seen: entry:
    let dom = entry.value.domain;
    in if builtins.hasAttr dom seen then
      throw "NixPit: duplicate domain '${dom}' between '${seen.${dom}}' and '${entry.name}'"
    else
      seen // { ${dom} = entry.name; }
  ) {} (lib.attrsToList domainContainers);

  caddyVirtualHosts = lib.mapAttrs' (name: c:
    let
      ports = c.ports or [];
      _hasPorts =
        if ports != [] then true
        else throw "NixPit: container '${name}' declares domain '${c.domain}' without any ports";
      firstParsed = parsePortSpec name (builtins.head ports);
      isLocal = lib.hasSuffix ".local" c.domain || lib.hasSuffix ".lan" c.domain || lib.hasSuffix ".home.arpa" c.domain;
      hostKey = if isLocal then "http://${c.domain}" else c.domain;
    in assert _hasPorts; {
      name = hostKey;
      value.extraConfig = ''
        reverse_proxy 127.0.0.1:${toString firstParsed.port}
      '';
    }
  ) domainContainers;

  extractHostDir = containerName: volSpec:
    let
      hostPath = builtins.head (lib.splitString ":" volSpec);
      isApproved = lib.any (root: lib.hasPrefix root hostPath) approvedMountRoots;
      hasTraversal = lib.hasInfix ".." hostPath;
      _checkTraversal =
        if hasTraversal then
          throw "NixPit: container '${containerName}' volume '${volSpec}' contains '..'"
        else true;
    in
      assert _checkTraversal;
      if isApproved then [ "d ${hostPath} 0755 root root -" ] else [];

  allTmpfilesRules = lib.unique (
    lib.concatLists (lib.mapAttrsToList (name: c:
      lib.concatMap (extractHostDir name) (c.volumes or [])
    ) mergedContainers)
  );

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

  composeRepos = lib.filter (name:
    builtins.pathExists "${reposDir}/${name}/docker-compose.yml" ||
    builtins.pathExists "${reposDir}/${name}/compose.yaml"
  ) repoNames;
in {
  options.services.nixpit.stateDir = lib.mkOption {
    type = lib.types.str;
    default = "/var/lib/nixpit";
    description = "Directory containing NixPit repository registry, checkouts, keys, and encrypted secrets.";
  };

  config = {
    sops.secrets = repoSopsSecrets;

    systemd.tmpfiles.rules = allTmpfilesRules;

    networking.firewall.allowedTCPPorts =
      assert builtins.isAttrs _uniquePublicPorts;
      allContainerTcpPorts ++ lib.optionals hasDomains [ 80 443 ];
    networking.firewall.allowedUDPPorts =
      assert builtins.isAttrs _uniquePublicPorts;
      allContainerUdpPorts;

    services.caddy = lib.mkIf hasDomains {
      enable = true;
      virtualHosts = assert builtins.isAttrs _uniqueDomains; caddyVirtualHosts;
    };

    virtualisation.oci-containers = {
      backend = "podman";
      containers = lib.mapAttrs (name: c:
        let
          repoSopsPath = "${reposDir}/${c._repo}/secrets/${c.secretName}.sops.env";
          hasRepoSops = builtins.pathExists repoSopsPath;
          hasHostSops = builtins.pathExists "${secretsDir}/${c.secretName}.sops.env";
          legacySecretPath = "${secretsDir}/${c.secretName}.env";
          autoSecret =
            if hasRepoSops then [ config.sops.secrets."nixpit/${c.secretName}".path ]
            else if hasHostSops then [ "/run/nixpit/secrets/${c.secretName}.env" ]
            else lib.optional (builtins.pathExists legacySecretPath) legacySecretPath;
          netOpt = lib.optional (c.network != "") "--network=${c.network}";
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

    virtualisation.libvirt.connections."qemu:///system".domains =
      lib.mapAttrsToList (name: vm:
        let
          storageVol =
            if lib.hasPrefix "/" vm.disk then vm.disk
            else { pool = vm.storagePool; volume = vm.disk; };
          isDefaultNet = vm.network == "default";
          baseDomain = nixvirt.lib.domain.templates.linux {
            inherit name;
            uuid = vm.uuid;
            memory = { count = vm.memoryGiB; unit = "GiB"; };
            storage_vol = storageVol;
            bridge_name = if isDefaultNet then "virbr0" else vm.network;
            virtio_video = null;
          };
          usbDevs = map mkUsbHostdev vm.usbPassthrough;
          netInterface =
            if isDefaultNet then {
              type = "network";
              model = { type = "virtio"; };
              source = { network = "default"; };
            }
            else baseDomain.devices.interface;
          finalDomain = baseDomain // {
            vcpu = { count = vm.vcpus; };
            devices = (baseDomain.devices or {}) // {
              interface = netInterface;
            } // lib.optionalAttrs (usbDevs != []) {
              hostdev = (baseDomain.devices.hostdev or []) ++ usbDevs;
            };
          };
        in {
          active = vm.active or true;
          definition = nixvirt.lib.domain.writeXML finalDomain;
        }
      ) mergedVms;

    systemd.services =
      (lib.mapAttrs' (name: c:
        let
          isCustomNet = lib.elem c.network customNetworks;
          usesHostSops =
            !(builtins.pathExists "${reposDir}/${c._repo}/secrets/${c.secretName}.sops.env")
            && builtins.pathExists "${secretsDir}/${c.secretName}.sops.env";
          deps =
            lib.optional isCustomNet "podman-network-${c.network}.service"
            ++ lib.optional usesHostSops "nixpit-secrets.service";
        in lib.nameValuePair "podman-${name}" (lib.mkIf (deps != []) {
          requires = deps;
          after = deps;
        })
      ) mergedContainers)
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

# modules/mk-guest-loader.nix — Parameterized Pure Nix / Compose / Dockerfile & SOPS Compiler
#
# What: Factory returning the NixOS workload loader module bound to a concrete `nixpitStateDir`.
# How:  Accepts `nixpitStateDir` as an outer function argument (NOT a NixOS `_module.args`
#       parameter) so dynamic `imports` can inspect repos without infinite recursion.
# Why:  Host builds pass `"/var/lib/nixpit"` (via modules/guest-loader.nix); offline tests pass
#       isolated `/nix/store` fixture directories.

nixpitStateDir:
{ config, lib, pkgs, nixvirt, ... }:

let
  # Resolve state paths from module arg `nixpitStateDir` (specialArgs in tests, /var/lib/nixpit on host)
  # so dynamic `imports` can inspect synced repos without triggering NixOS infinite recursion.
  reposDir = "${nixpitStateDir}/repos";
  secretsDir = "${nixpitStateDir}/secrets";

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
  registry = "${nixpitStateDir}/repos.json";
  repoNames =
    if builtins.pathExists registry then
      map (r: assertIdent "repository" (r.name or "")) (builtins.fromJSON (builtins.readFile registry))
    else [];

  # Return sorted regular filenames inside `dir` ending with `suffix`.
  listDirWithSuffix = dir: suffix:
    if builtins.pathExists dir then
      let
        entries = builtins.readDir dir;
        matched = builtins.filter (f:
          (entries.${f} == "regular" || entries.${f} == "symlink") && lib.hasSuffix suffix f
        ) (builtins.attrNames entries);
      in lib.sort (a: b: a < b) matched
    else [];

  # Discover Nix modules, SOPS secret files, Compose stacks, and standalone Dockerfiles per repo.
  repoData = map (name:
    let
      dir = "${reposDir}/${name}";
      rootNix = lib.filter builtins.pathExists [ "${dir}/workloads.nix" "${dir}/default.nix" ];
      subNix = map (f: "${dir}/nix/${f}") (listDirWithSuffix "${dir}/nix" ".nix");
      secretFiles = listDirWithSuffix "${dir}/secrets" ".sops.env";
      secretNames = map (f: assertIdent "secret" (lib.removeSuffix ".sops.env" f)) secretFiles;
      hasCompose = builtins.pathExists "${dir}/compose.yaml" || builtins.pathExists "${dir}/docker-compose.yml";
      hasDockerfile = builtins.pathExists "${dir}/Dockerfile";
    in {
      inherit name dir hasCompose secretNames;
      hasStandaloneDockerfile = hasDockerfile && !hasCompose;
      nixFiles = rootNix ++ subNix;
    }
  ) repoNames;

  repoNixImports = lib.concatMap (r: r.nixFiles) repoData;
  composeRepos = builtins.filter (r: r.hasCompose) repoData;
  dockerfileRepos = builtins.filter (r: r.hasStandaloneDockerfile) repoData;

  # Register every `<repo>/secrets/<name>.sops.env` with sops-nix so it decrypts into
  # `/run/secrets/nixpit/<repo>/<name>` (ramfs, mode 0400) during activation.
  repoSopsSecrets = lib.listToAttrs (lib.concatLists (map (r:
    map (sec: {
      name = "nixpit/${r.name}/${sec}";
      value = {
        sopsFile = builtins.path {
          path = "${r.dir}/secrets/${sec}.sops.env";
          name = "nixpit-${r.name}-${sec}.sops.env";
        };
        format = "dotenv";
        key = "";
        mode = "0400";
      };
    }) r.secretNames
  ) repoData));

  wCfg = config.services.nixpit.workloads;

  # Helper: find all repos that ship `secrets/<sec>.sops.env`.
  findSecretRepos = sec:
    map (r: r.name) (builtins.filter (r: lib.elem sec r.secretNames) repoData);

  # Validate declared container options and resolve SOPS secret paths.
  validatedContainers = lib.mapAttrs (name: c:
    let
      _name = assertIdent "container" name;
      _image =
        if builtins.isString (c.image or null) && c.image != "" then c.image
        else throw "NixPit: container '${name}' missing non-empty image";
      _secret = if c.secretName != "" then assertIdent "secretName" c.secretName else _name;
      _net = if c.network != "" then assertIdent "network" c.network else "";
      _dom =
        if c.domain != "" then
          if builtins.match domainRegex c.domain != null then c.domain
          else throw "NixPit: container '${name}' has invalid domain '${c.domain}'"
        else "";
      _repo = if c.repo != "" then assertIdent "repository" c.repo else "";
      matchedRepos = findSecretRepos _secret;
      sopsKey =
        if _repo != "" then
          let k = "nixpit/${_repo}/${_secret}";
          in if builtins.hasAttr k repoSopsSecrets then k else null
        else if builtins.length matchedRepos == 1 then
          "nixpit/${builtins.head matchedRepos}/${_secret}"
        else if builtins.length matchedRepos > 1 then
          throw "NixPit: ambiguous secret '${_secret}' found in repos (${builtins.concatStringsSep ", " matchedRepos}); set workloads.containers.${name}.repo"
        else null;
      hostSopsFile = "${secretsDir}/${_secret}.sops.env";
    in c // {
      image = _image;
      secretName = _secret;
      network = _net;
      domain = _dom;
      _sopsKey = sopsKey;
      _hasHostSops = builtins.pathExists hostSopsFile;
    }
  ) wCfg.containers;

  # Validate declared VM options (UUID, vCPUs, memoryGiB, disk traversal, network, USB IDs).
  validatedVms = lib.mapAttrs (name: vm:
    let
      _name = assertIdent "vm" name;
      _uuid =
        if builtins.isString (vm.uuid or null) && builtins.match uuidRegex vm.uuid != null then vm.uuid
        else throw "NixPit: vm '${name}' has invalid uuid '${toString (vm.uuid or "")}'";
      _vcpus = if builtins.isInt vm.vcpus && vm.vcpus >= 1 then vm.vcpus else throw "NixPit: vm '${name}' invalid vcpus";
      _mem = if builtins.isInt vm.memoryGiB && vm.memoryGiB >= 1 then vm.memoryGiB else throw "NixPit: vm '${name}' invalid memoryGiB";
      _disk = assertNoTraversal "vm disk" vm.disk;
      _pool = if vm.storagePool != "" then assertIdent "storagePool" vm.storagePool else "default";
      _net = if vm.network != "default" then assertIdent "vm network" vm.network else "default";
      _usb = map (vp:
        if builtins.isString vp && builtins.match usbVpRegex vp != null then vp
        else throw "NixPit: vm '${name}' has invalid USB vendor:product '${toString vp}'"
      ) vm.usbPassthrough;
    in assert _name != ""; vm // {
      uuid = _uuid; vcpus = _vcpus; memoryGiB = _mem;
      disk = _disk; storagePool = _pool; network = _net; usbPassthrough = _usb;
    }
  ) wCfg.vms;

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
    map (p: parsePortSpec name p // { container = name; }) c.ports
  ) validatedContainers));

  # Fail closed if two containers try to publish the same host port+protocol.
  _uniquePublicPorts = lib.foldl' (seen: p:
    if builtins.hasAttr p.key seen then
      throw "NixPit: duplicate public port ${p.key} between '${seen.${p.key}}' and '${p.container}'"
    else seen // { ${p.key} = p.container; }
  ) {} publicPorts;

  customNetworks = lib.unique (lib.filter (n: n != "" && n != "host" && n != "bridge" && n != "none")
    (map (c: c.network) (builtins.attrValues validatedContainers)));

  domainContainers = lib.filterAttrs (_: c: c.domain != "") validatedContainers;
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
      _hasPorts = if c.ports != [] then true else throw "NixPit: container '${name}' has domain '${c.domain}' without ports";
      firstPort = parsePortSpec name (builtins.head c.ports);
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

  containerSubmodule = lib.types.submodule {
    options = {
      image = lib.mkOption { type = lib.types.str; description = "OCI container image reference."; };
      repo = lib.mkOption { type = lib.types.str; default = ""; description = "Optional owning repo profile name for secret disambiguation."; };
      secretName = lib.mkOption { type = lib.types.str; default = ""; description = "SOPS secret name (defaults to container name)."; };
      ports = lib.mkOption { type = lib.types.listOf lib.types.str; default = []; description = "Published ports ([hostIp:]hostPort:containerPort[/proto])."; };
      volumes = lib.mkOption { type = lib.types.listOf lib.types.str; default = []; description = "Bind mounts (/host:/container[:opts])."; };
      network = lib.mkOption { type = lib.types.str; default = ""; description = "Podman network name."; };
      domain = lib.mkOption { type = lib.types.str; default = ""; description = "Optional Caddy virtual host domain."; };
      cmd = lib.mkOption { type = lib.types.listOf lib.types.str; default = []; description = "Container command override."; };
      environment = lib.mkOption { type = lib.types.attrsOf lib.types.str; default = {}; description = "Non-secret environment variables."; };
      environmentFiles = lib.mkOption { type = lib.types.listOf lib.types.str; default = []; description = "Explicit env files to inject."; };
      dependsOn = lib.mkOption { type = lib.types.listOf lib.types.str; default = []; description = "Container startup dependencies."; };
      extraOptions = lib.mkOption { type = lib.types.listOf lib.types.str; default = []; description = "Additional Podman CLI flags."; };
      usbPassthrough = lib.mkOption { type = lib.types.listOf lib.types.str; default = []; description = "USB device paths to attach."; };
    };
  };

  vmSubmodule = lib.types.submodule {
    options = {
      uuid = lib.mkOption { type = lib.types.str; description = "Libvirt domain UUID."; };
      vcpus = lib.mkOption { type = lib.types.int; default = 2; description = "Number of virtual CPUs."; };
      memoryGiB = lib.mkOption { type = lib.types.int; default = 2; description = "Guest RAM size in GiB."; };
      disk = lib.mkOption { type = lib.types.str; description = "Volume name in storagePool or absolute image path."; };
      storagePool = lib.mkOption { type = lib.types.str; default = "default"; description = "Libvirt storage pool name."; };
      network = lib.mkOption { type = lib.types.str; default = "default"; description = "'default' NAT network or host bridge interface."; };
      usbPassthrough = lib.mkOption { type = lib.types.listOf lib.types.str; default = []; description = "USB vendor:product hex IDs."; };
      active = lib.mkOption { type = lib.types.bool; default = true; description = "Autostart VM domain at activation."; };
    };
  };
in {
  # Import all Nix workload modules discovered in synced repositories (`workloads.nix`, `default.nix`, `nix/*.nix`).
  imports = repoNixImports;

  options.services.nixpit = {
    stateDir = lib.mkOption {
      type = lib.types.str;
      default = nixpitStateDir;
      description = "Directory containing NixPit repository registry, checkouts, keys, and encrypted secrets.";
    };
    workloads = {
      containers = lib.mkOption {
        type = lib.types.attrsOf containerSubmodule;
        default = {};
        description = "Declarative Podman containers declared in repo Nix modules.";
      };
      vms = lib.mkOption {
        type = lib.types.attrsOf vmSubmodule;
        default = {};
        description = "Declarative KVM/Libvirt VMs declared in repo Nix modules.";
      };
    };
  };

  config = {
    sops.secrets = repoSopsSecrets;

    systemd.tmpfiles.rules = lib.unique (lib.concatLists (lib.mapAttrsToList (name: c:
      lib.concatMap (extractHostDir name) c.volumes
    ) validatedContainers));

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
    # Secret resolution: 1) repo sops-nix (`/run/secrets/nixpit/<repo>/<secret>`) -> 2) host SOPS tmpfs.
    virtualisation.oci-containers = {
      backend = "podman";
      containers = lib.mapAttrs (name: c:
        let
          autoSecret =
            if c._sopsKey != null then [ config.sops.secrets.${c._sopsKey}.path ]
            else lib.optional c._hasHostSops "/run/nixpit/secrets/${c.secretName}.env";
          netOpt = lib.optional (c.network != "") "--network=${c.network}";
        in {
          inherit (c) image cmd ports volumes environment dependsOn;
          environmentFiles = lib.unique (c.environmentFiles ++ autoSecret);
          extraOptions = c.extraOptions ++ netOpt ++ map (dev: "--device=${dev}:${dev}") c.usbPassthrough;
        }
      ) validatedContainers;
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
          active = vm.active;
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
      ) validatedVms;

    # Generate ordering dependencies, custom Podman networks, Compose stacks, and standalone Dockerfile units.
    systemd.services =
      (lib.mapAttrs' (name: c:
        let
          deps = lib.optional (lib.elem c.network customNetworks) "podman-network-${c.network}.service"
            ++ lib.optional (c._sopsKey == null && c._hasHostSops) "nixpit-secrets.service";
        in lib.nameValuePair "podman-${name}" (lib.mkIf (deps != []) { requires = deps; after = deps; })
      ) validatedContainers)
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
      // (lib.listToAttrs (map (r:
        let composeSecretKey = "nixpit/${r.name}/compose";
        in {
          name = "homelab-compose-${r.name}";
          value = {
            description = "Podman Compose stack for ${r.name}";
            wantedBy = [ "multi-user.target" ];
            requires = [ "podman.service" ];
            after = [ "network-online.target" "podman.service" ];
            path = [ pkgs.podman pkgs.podman-compose ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              WorkingDirectory = r.dir;
              ExecStart = "${pkgs.podman-compose}/bin/podman-compose up -d --build --remove-orphans";
              ExecStop = "${pkgs.podman-compose}/bin/podman-compose down";
            } // lib.optionalAttrs (builtins.hasAttr composeSecretKey repoSopsSecrets) {
              EnvironmentFile = [ config.sops.secrets.${composeSecretKey}.path ];
            };
          };
        }
      ) composeRepos))
      // (lib.listToAttrs (map (r:
        let
          dfKey = "nixpit/${r.name}/dockerfile";
          repoKey = "nixpit/${r.name}/${r.name}";
          secPath =
            if builtins.hasAttr dfKey repoSopsSecrets then config.sops.secrets.${dfKey}.path
            else if builtins.hasAttr repoKey repoSopsSecrets then config.sops.secrets.${repoKey}.path
            else null;
          envFlag = lib.optionalString (secPath != null) " --env-file ${secPath}";
        in {
          name = "homelab-dockerfile-${r.name}";
          value = {
            description = "Standalone Dockerfile workload for ${r.name}";
            wantedBy = [ "multi-user.target" ];
            requires = [ "podman.service" ];
            after = [ "network-online.target" "podman.service" ];
            path = [ pkgs.podman ];
            serviceConfig = {
              Type = "simple";
              Restart = "on-failure";
              WorkingDirectory = r.dir;
              ExecStartPre = "${pkgs.podman}/bin/podman build -t nixpit-${r.name}:latest .";
              ExecStart = "${pkgs.podman}/bin/podman run --rm --replace --name nixpit-${r.name} -P${envFlag} nixpit-${r.name}:latest";
              ExecStop = "-${pkgs.podman}/bin/podman stop nixpit-${r.name}";
            };
          };
        }
      ) dockerfileRepos));
  };
}

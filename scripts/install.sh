# shellcheck shell=bash
# NixPit installer for an existing NixOS host (no disk formatting).
# Usage: nixpit-install [--yes] [--source URI] [--static ADDR/PREFIX --gateway GW [--dns IP]]
# Default networking is unchanged (DHCP). The new config is tried with
# `nixos-rebuild test` first and only made the boot default if the network still works.
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

valid_ipv4() {
  local IFS=. o
  [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  for o in $1; do (( 10#$o <= 255 )) || return 1; done
}

ip_to_int() { local IFS=. a b c d; read -r a b c d <<< "$1"; echo $(( (a << 24) | (b << 16) | (c << 8) | d )); }

# Gateway must be a different address inside the same subnet.
same_subnet() {
  local mask=$(( (0xFFFFFFFF << (32 - $3)) & 0xFFFFFFFF ))
  (( ($(ip_to_int "$1") & mask) == ($(ip_to_int "$2") & mask) )) && [[ "$1" != "$2" ]]
}

# Write a file atomically: temp file in the same directory, then rename.
write_file() { local tmp; tmp=$(mktemp "$1.XXXX"); cat > "$tmp"; chmod 0644 "$tmp"; mv -f "$tmp" "$1"; }

parse_args() {
  yes=0 source_uri="github:OmarDardery/NixPit" static="" gateway="" dns=""
  while (( $# )); do
    case "$1" in
      --yes) yes=1 ;;
      --source) source_uri="${2:?}"; shift ;;
      --static) static="${2:?}"; shift ;;
      --gateway) gateway="${2:?}"; shift ;;
      --dns) dns="${2:?}"; shift ;;
      github:*|path:*) source_uri="$1" ;;  # positional URI kept for compatibility
      *) die "unknown argument: $1" ;;
    esac
    shift
  done
  [[ "$source_uri" =~ ^(github:[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+(/[a-zA-Z0-9_./-]+)?|path:/[a-zA-Z0-9_./-]+)$ ]] \
    || die 'expected a github: or absolute path: flake URI'
  if [[ -n "$static" ]]; then
    [[ "$static" =~ ^([0-9.]+)/([0-9]{1,2})$ ]] || die '--static expects ADDR/PREFIX'
    addr=${BASH_REMATCH[1]} prefix=${BASH_REMATCH[2]}
    valid_ipv4 "$addr" || die "invalid static address: $static"
    (( prefix >= 1 && prefix <= 32 )) || die "invalid prefix: $static"
    valid_ipv4 "$gateway" || die '--static requires a valid --gateway'
    same_subnet "$addr" "$gateway" "$prefix" || die 'gateway must be another address in the same subnet'
    [[ -z "$dns" ]] || valid_ipv4 "$dns" || die "invalid --dns: $dns"
  elif [[ -n "$gateway$dns" ]]; then
    die '--gateway/--dns require --static'
  fi
}

# Print the wrapper flake that imports the host's own configuration plus NixPit.
render_flake() {
  local net=""
  if [[ -n "$static" ]]; then
    net="services.nixpit.network.static = { interface = \"$iface\"; address = \"$addr\"; prefixLength = $prefix; gateway = \"$gateway\"; nameservers = [ ${dns:+\"$dns\"} ]; };"
  fi
  cat <<FLAKE
{
  inputs.nixpit.url = "$source_uri";
  inputs.nixpkgs.follows = "nixpit/nixpkgs";
  outputs = { nixpkgs, nixpit, ... }: {
    nixosConfigurations.nixpit = nixpkgs.lib.nixosSystem {
      system = "$system";
      modules = [
        /etc/nixos/configuration.nix
        nixpit.nixosModules.default
        { services.cockpit.allowed-origins = [ "https://$cockpit_ip:9090" ]; $net }
      ];
    };
  };
}
FLAKE
}

# After `nixos-rebuild test`, the gateway must answer (or at least have a route).
network_ok() {
  local gw="${gateway:-$detected_gw}"
  for _ in 1 2 3 4 5 6; do
    ping -c1 -W2 "$gw" >/dev/null 2>&1 && return 0
    sleep 5
  done
  return 1
}

main() {
  (( EUID == 0 )) || die 'run with sudo nix run (see README)'
  parse_args "$@"
  [[ -f /etc/nixos/configuration.nix ]] || die '/etc/nixos/configuration.nix required'
  [[ ! -f /etc/nixos/flake.nix ]] || die 'host already uses a flake; import nixosModules.default instead'
  NIX_CONFIG="$(printf '%s\n%s' "${NIX_CONFIG:-}" 'extra-experimental-features = nix-command flakes')"
  export NIX_CONFIG

  local route
  route=$(ip -j -4 route show default | jq -c '.[0] // {}')
  iface=$(jq -r '.dev // empty' <<< "$route")
  detected_gw=$(jq -r '.gateway // empty' <<< "$route")
  [[ -n "$iface" ]] || die 'no IPv4 default route found'
  cockpit_ip=$(ip -j -4 addr show dev "$iface" | jq -r '.[0].addr_info[]? | select(.family == "inet") | .local' | head -n1)
  if [[ -n "$static" ]]; then cockpit_ip=$addr; fi
  valid_ipv4 "$cockpit_ip" || die 'no usable IPv4 address'
  system=$(nix eval --impure --raw --expr builtins.currentSystem)

  printf 'Interface: %s\nAddress: %s (%s)\nGateway: %s\n' "$iface" "$cockpit_ip" "$([[ -n "$static" ]] && echo static || echo DHCP)" "${gateway:-$detected_gw}"
  if (( ! yes )); then
    read -rp 'Enable NixPit (privileged Cockpit, KVM, Podman) on this host [y/N]? ' answer
    [[ "$answer" =~ ^[Yy]$ ]] || exit 0
  fi

  install -d -m 0700 /etc/nixpit /var/lib/nixpit /var/lib/nixpit/repos /var/lib/nixpit/secrets
  [[ -f /var/lib/nixpit/repos.json ]] || printf '[]\n' | write_file /var/lib/nixpit/repos.json

  # Back up the previous wrapper so a failed cutover can be undone.
  local f
  for f in flake.nix flake.lock; do
    if [[ -f /etc/nixpit/$f ]]; then cp -p "/etc/nixpit/$f" "/etc/nixpit/$f.bak"; fi
  done
  restore() {
    echo 'Install failed; restoring previous configuration.' >&2
    for f in flake.nix flake.lock; do
      if [[ -f /etc/nixpit/$f.bak ]]; then mv -f "/etc/nixpit/$f.bak" "/etc/nixpit/$f"; else rm -f "/etc/nixpit/$f"; fi
    done
    # Re-activate the current boot default (the previous generation).
    /nix/var/nix/profiles/system/bin/switch-to-configuration test || true
    exit 1
  }

  render_flake | write_file /etc/nixpit/flake.nix
  printf 'path:/etc/nixpit#nixpit\n' | write_file /var/lib/nixpit/hypervisor.flake
  if [[ -f /etc/nixpit/flake.lock ]]; then
    nix flake update nixpit --refresh --flake path:/etc/nixpit || restore
  else
    nix flake lock path:/etc/nixpit || restore
  fi

  local target=path:/etc/nixpit#nixpit
  nixos-rebuild build --impure --flake "$target" || restore
  nixos-rebuild test --impure --flake "$target" || restore   # live, but not the boot default
  network_ok || restore
  nixos-rebuild switch --impure --flake "$target" || restore
  rm -f /etc/nixpit/flake.nix.bak /etc/nixpit/flake.lock.bak
  printf 'Cockpit: https://%s:9090\n' "$cockpit_ip"
}

# Run only when executed, so tests can source the helper functions.
if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then main "$@"; fi

# Existing conventional NixOS installations only; no disk formatting.
set -euo pipefail
# Run as root once; nested sudo can discard NIX_CONFIG and the packaged PATH.
if (( EUID != 0 )); then
  echo 'Run this installer with sudo nix run (see README).' >&2
  exit 1
fi
# Preserve existing NIX_CONFIG and enable features for all child processes.
NIX_CONFIG="$(printf '%s\n%s' "${NIX_CONFIG:-}" 'extra-experimental-features = nix-command flakes')"
export NIX_CONFIG
source_uri="${1:-github:OmarDardery/NixPit}"
if [[ ! -f /etc/nixos/configuration.nix ]]; then
  echo 'Existing /etc/nixos/configuration.nix required; import nixosModules.default manually for custom flakes.' >&2
  exit 1
fi
if [[ -f /etc/nixos/flake.nix ]]; then
  echo 'Existing flake detected. Import NixPit as a module instead of replacing your host flake.' >&2
  exit 1
fi
if [[ ! "$source_uri" =~ ^(github:[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+(/[a-zA-Z0-9_./-]+)?|path:/[a-zA-Z0-9_./-]+)$ ]]; then
  echo 'Expected a GitHub or absolute path flake URI without a fragment.' >&2; exit 1
fi
route=$(ip -j -4 route show default | jq -c '.[0] // {}')
iface=$(jq -r '.dev // empty' <<< "$route")
gateway=$(jq -r '.gateway // empty' <<< "$route")
if [[ -z "$iface" ]]; then echo 'No IPv4 default route found.' >&2; exit 1; fi
ip_addr=$(ip -j -4 addr show dev "$iface" | jq -r '.[0].addr_info[]? | select(.family == "inet") | .local' | head -n 1)
if [[ ! "$ip_addr" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
  echo 'No usable IPv4 address found for Cockpit.' >&2; exit 1
fi
mac=$(cat "/sys/class/net/$iface/address")
printf 'Interface: %s\nIP: %s\nGateway: %s\nMAC: %s\n' "$iface" "$ip_addr" "$gateway" "$mac"
echo 'For a stable address, reserve this MAC/IP on your router. Existing network settings are preserved.'
echo 'This experimental appliance will enable privileged Cockpit and virtualization services. Use a test host.'
read -rp 'Continue [y/N]? ' answer
[[ "$answer" =~ ^[Yy]$ ]] || exit 0
install -d -m 0700 /etc/nixpit /var/lib/nixpit /var/lib/nixpit/repos /var/lib/nixpit/secrets
if ! test -f /var/lib/nixpit/repos.json; then printf '[]\n' | tee /var/lib/nixpit/repos.json >/dev/null; fi
tee /etc/nixpit/flake.nix >/dev/null <<FLAKE
{
  inputs.nixpit.url = "$source_uri";
  inputs.nixpkgs.follows = "nixpit/nixpkgs";
  outputs = { nixpkgs, nixpit, ... }: {
    nixosConfigurations.nixpit = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        /etc/nixos/configuration.nix
        nixpit.nixosModules.default
        { services.cockpit.allowed-origins = [ "https://$ip_addr:9090" ]; }
      ];
    };
  };
}
FLAKE
printf 'path:/etc/nixpit#nixpit\n' | tee /var/lib/nixpit/hypervisor.flake >/dev/null
if [[ -f /etc/nixpit/flake.lock ]]; then
  # Re-running the installer must refresh the appliance input, not silently
  # keep the old revision from the previously generated wrapper lock.
  nix --extra-experimental-features 'nix-command flakes' flake update nixpit --refresh --flake path:/etc/nixpit
else
  nix --extra-experimental-features 'nix-command flakes' flake lock path:/etc/nixpit
fi
nixos-rebuild build --impure --flake path:/etc/nixpit#nixpit
nixos-rebuild switch --impure --flake path:/etc/nixpit#nixpit
printf 'Cockpit: https://%s:9090\n' "$ip_addr"

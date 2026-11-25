# Existing conventional NixOS installations only; no disk formatting.
set -euo pipefail
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
mac=$(cat "/sys/class/net/$iface/address")
printf 'Interface: %s\nIP: %s\nGateway: %s\nMAC: %s\n' "$iface" "$ip_addr" "$gateway" "$mac"
echo 'For a stable address, reserve this MAC/IP on your router. Existing network settings are preserved.'
echo 'This experimental appliance will enable privileged Cockpit and virtualization services. Use a test host.'
read -rp 'Continue [y/N]? ' answer
[[ "$answer" =~ ^[Yy]$ ]] || exit 0
sudo install -d -m 0700 /etc/nixpit /var/lib/nixpit /var/lib/nixpit/repos /var/lib/nixpit/secrets
if ! sudo test -f /var/lib/nixpit/repos.json; then printf '[]\n' | sudo tee /var/lib/nixpit/repos.json >/dev/null; fi
sudo tee /etc/nixpit/flake.nix >/dev/null <<FLAKE
{
  inputs.nixpit.url = "$source_uri";
  inputs.nixpkgs.follows = "nixpit/nixpkgs";
  outputs = { nixpkgs, nixpit, ... }: {
    nixosConfigurations.nixpit = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [ /etc/nixos/configuration.nix nixpit.nixosModules.default ];
    };
  };
}
FLAKE
printf 'path:/etc/nixpit#nixpit\n' | sudo tee /var/lib/nixpit/hypervisor.flake >/dev/null
sudo nix flake lock path:/etc/nixpit
sudo nixos-rebuild build --impure --flake path:/etc/nixpit#nixpit
sudo nixos-rebuild switch --impure --flake path:/etc/nixpit#nixpit
printf 'Cockpit: https://%s:9090\n' "$ip_addr"

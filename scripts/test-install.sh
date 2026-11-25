#!/usr/bin/env bash
# Unit tests for installer argument validation and wrapper rendering (no root, no host changes).
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/install.sh
source scripts/install.sh
fails=0
ok()  { if ( parse_args "$@" ) >/dev/null 2>&1; then echo "ok   accept: $*"; else echo "FAIL accept: $*"; fails=$((fails+1)); fi; }
bad() { if ( parse_args "$@" ) >/dev/null 2>&1; then echo "FAIL reject: $*"; fails=$((fails+1)); else echo "ok   reject: $*"; fi; }

ok
ok --yes path:/tmp/nixpit
ok --static 192.168.1.50/24 --gateway 192.168.1.1
ok --static 10.0.0.5/8 --gateway 10.200.0.1 --dns 1.1.1.1 --source github:a/b
bad --static 192.168.1.50/24                          # no gateway
bad --static 192.168.1.50 --gateway 192.168.1.1       # no prefix
bad --static 192.168.1.256/24 --gateway 192.168.1.1   # bad octet
bad --static 192.168.1.50/33 --gateway 192.168.1.1    # bad prefix
bad --static 192.168.1.50/24 --gateway 192.168.2.1    # other subnet
bad --static 192.168.1.50/24 --gateway 192.168.1.50   # gateway == address
bad --static 192.168.1.50/24 --gateway 192.168.1.1 --dns 8.8.8
bad --gateway 192.168.1.1                             # gateway without static
bad --source 'github:a/b#evil'
bad --bogus

# Rendered wrapper must contain the typed static option and parse as Nix.
parse_args --static 192.168.1.50/24 --gateway 192.168.1.1 --dns 1.1.1.1
iface=eth0 system=x86_64-linux cockpit_ip=192.168.1.50
out=$(render_flake)
grep -qF 'services.nixpit.network.static = { interface = "eth0"; address = "192.168.1.50"; prefixLength = 24; gateway = "192.168.1.1"; nameservers = [ "1.1.1.1" ]; };' <<< "$out" \
  || { echo 'FAIL render static'; fails=$((fails+1)); }
parse_args
out_dhcp=$(render_flake)
if grep -q network.static <<< "$out_dhcp"; then echo 'FAIL render dhcp'; fails=$((fails+1)); fi
if command -v nix-instantiate >/dev/null 2>&1; then
  for f in "$out" "$out_dhcp"; do
    NIX_REMOTE="" NIX_STATE_DIR="${TMPDIR:-/tmp}/nixpit-check-state" nix-instantiate --parse -E "$f" >/dev/null \
      || { echo 'FAIL render parse'; fails=$((fails+1)); }
  done
fi
echo "render checks done"
(( fails == 0 )) || { echo "$fails failure(s)"; exit 1; }

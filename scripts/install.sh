# Existing conventional NixOS installations only; no disk formatting.
set -euo pipefail
if (( EUID != 0 )); then
  exec /run/wrappers/bin/sudo -- "$0" "$@"
fi
exec python3 "$NIXPIT_INSTALLER" "$@"

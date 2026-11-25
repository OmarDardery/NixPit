#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
node --check cockpit/app.js
node --check cockpit/virtmon/app.js
bash -n scripts/install.sh
bash -n scripts/check.sh
bash -n scripts/nixpit-repo.sh
bash -n scripts/nixpit-secrets.sh
python3 - <<'PY'
import json
from pathlib import Path
for path in (
    Path("cockpit/manifest.json"),
    Path("cockpit/virtmon/manifest.json"),
):
    json.loads(path.read_text())
    print("JSON:", path)
PY
if command -v nix-instantiate >/dev/null 2>&1; then
  NIX_REMOTE="" NIX_STATE_DIR="${TMPDIR:-/tmp}/nixpit-check-state" nix-instantiate --parse templates/guests/workloads.nix templates/guests/nix/whoami.nix >/dev/null
fi
# Fail if obvious plaintext secrets, private keys, or compiled kernel binaries are tracked.
if git ls-files | grep -vE '(^|/)secrets/.*\.sops\.env$' | grep -E '(^|/)(\.env|[^/]+\.env|deploy_key|id_ed25519|id_rsa)$|\.(ko|o|mod\.c)$'; then
  echo "Tracked runtime credential or binary artifact filename" >&2
  exit 1
fi
git diff --check

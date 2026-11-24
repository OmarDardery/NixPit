#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
node --check cockpit/app.js
bash -n scripts/install.sh
bash -n scripts/check.sh
python3 - <<'PY'
import json
from pathlib import Path
for path in (Path("cockpit/manifest.json"), *Path("templates/guests").glob("*.json")):
    json.loads(path.read_text())
    print("JSON:", path)
PY
# Fail if obvious local runtime secrets or private keys are tracked.
if git ls-files | grep -E '(^|/)(\.env|[^/]+\.env|deploy_key|id_ed25519|id_rsa)$'; then
  echo "Tracked runtime credential filename" >&2
  exit 1
fi
git diff --check

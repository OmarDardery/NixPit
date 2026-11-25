#!/usr/bin/env bash
# nixpit-secrets — SOPS + Age Secret Management CLI and Service Runner.
#
# What: Manages the host Age keypair and encrypts/decrypts SOPS dotenv secrets both
#       inside external Git workload repos (`<repo>/secrets/<name>.sops.env`, auto-
#       maintaining `<repo>/.sops.yaml` for `sops-nix`) and on the host (`/var/lib/nixpit/secrets`).
# How:  Shares the exact same Age key file (/var/lib/nixpit/sops/age/keys.txt)
#       used by sops-nix, validates KEY=VALUE dotenv syntax, verifies SOPS ciphertext,
#       and uses atomic temp-file writes with strict permissions.
# Why:  Lets users add and edit workload env vars in the UI, commit ciphertext safely
#       to Git, and let sops-nix decrypt into RAM-only `/run/secrets/nixpit/` on deploy.

set -euo pipefail

STATE_DIR="${NIXPIT_STATE_DIR:-/var/lib/nixpit}"
RUNTIME_DIR="${NIXPIT_RUNTIME_DIR:-/run/nixpit/secrets}"
REPOS_DIR="${STATE_DIR}/repos"
AGE_DIR="${STATE_DIR}/sops/age"
KEY_FILE="${AGE_DIR}/keys.txt"
PUB_FILE="${AGE_DIR}/public.key"
SECRETS_DIR="${STATE_DIR}/secrets"

# Print error to stderr and abort immediately.
die() {
  echo "nixpit-secrets: $*" >&2
  exit 1
}

# Validate repo/secret names to prevent path traversal into parent directories.
validate_name() {
  local name="$1"
  [[ "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || die "invalid name '$name'"
}

# Validate repo checkout exists locally before reading or writing repo secrets.
validate_repo_dir() {
  local repo="$1"
  validate_name "$repo"
  [[ -d "${REPOS_DIR}/${repo}" ]] || die "repo checkout not found for '$repo' (sync first)"
}

# `init` — Ensure 0700 state/runtime directories and generate the host Age key if absent,
# then derive and cache the public `age1...` key for encryption and .sops.yaml rules.
cmd_init() {
  install -d -m 0755 "${STATE_DIR}"
  install -d -m 0700 "${STATE_DIR}/sops" "${AGE_DIR}" "${SECRETS_DIR}" "${RUNTIME_DIR}"
  if [[ ! -s "${KEY_FILE}" ]]; then
    (umask 077 && age-keygen -o "${KEY_FILE}" >/dev/null 2>&1)
  fi
  chmod 0600 "${KEY_FILE}"
  local pub
  pub="$(age-keygen -y "${KEY_FILE}")"
  local tmp
  tmp="$(mktemp "${PUB_FILE}.tmp.XXXXXX")"
  chmod 0644 "$tmp"
  printf '%s\n' "$pub" > "$tmp"
  mv -f "$tmp" "${PUB_FILE}"
  printf '%s\n' "$pub"
}

# `pubkey` — Initialize if needed and print the host Age public key.
cmd_pubkey() {
  cmd_init
}

# Build a .sops.yaml creation_rules document for the given comma-separated Age recipients.
render_sops_yaml() {
  local recipients="$1"
  cat <<YAML
creation_rules:
  - path_regex: secrets/.*\.sops\.(env|ya?ml)$
    age: ${recipients}
YAML
}

# `sops-config` — Output a ready-to-use .sops.yaml snippet targeting this host's Age key.
cmd_sops_config() {
  local pub
  pub="$(cmd_init)"
  render_sops_yaml "$pub"
}

# Ensure `<repo>/.sops.yaml` exists and includes this host's Age public key (preserving
# any teammate Age keys already configured). Prints the comma-separated recipient list.
ensure_repo_sops_yaml() {
  local repo="$1"
  local pub repo_dir sops_yaml existing recipients
  pub="$(cmd_init)"
  repo_dir="${REPOS_DIR}/${repo}"
  sops_yaml="${repo_dir}/.sops.yaml"

  if [[ -f "$sops_yaml" ]]; then
    existing="$(grep -oE 'age1[0-9a-z]+' "$sops_yaml" || true)"
    recipients="$(printf '%s\n%s\n' "$existing" "$pub" | grep -E '^age1[0-9a-z]+$' | sort -u | paste -sd, -)"
  else
    recipients="$pub"
  fi

  if [[ ! -f "$sops_yaml" ]] || ! grep -qF "$pub" "$sops_yaml"; then
    local tmp
    tmp="$(mktemp "${repo_dir}/.sops.yaml.tmp.XXXXXX")"
    chmod 0644 "$tmp"
    render_sops_yaml "$recipients" > "$tmp"
    mv -f "$tmp" "$sops_yaml"
  fi

  printf '%s\n' "$recipients"
}

# List basenames (stripped of `suffix`) inside `dir` sorted alphabetically.
list_dir_names() {
  local dir="$1"
  local suffix="$2"
  if [[ -d "$dir" ]]; then
    find "$dir" -maxdepth 1 -type f -name "*${suffix}" -printf '%f\n' | sed "s/${suffix}\$//" | sort
  fi
}

# `list` — Output JSON summarizing the Age pubkey, encrypted host secrets, tmpfs runtime files,
# and repo secrets decrypted into /run/secrets/nixpit by sops-nix.
cmd_list() {
  local pub
  pub="$(cmd_init)"
  local host_json runtime_json sopsnix_json
  host_json="$(list_dir_names "${SECRETS_DIR}" ".sops.env" | jq -R . | jq -s .)"
  runtime_json="$(list_dir_names "${RUNTIME_DIR}" ".env" | jq -R . | jq -s .)"
  if [[ -d /run/secrets/nixpit ]]; then
    sopsnix_json="$(find /run/secrets/nixpit -mindepth 1 -maxdepth 2 -type f -printf '%P\n' | sort | jq -R . | jq -s .)"
  else
    sopsnix_json='[]'
  fi
  jq -nc \
    --arg pub "$pub" \
    --argjson host "$host_json" \
    --argjson runtime "$runtime_json" \
    --argjson sopsNix "$sopsnix_json" \
    '{ agePublicKey: $pub, hostSecrets: $host, runtimeActive: $runtime, sopsNixSecrets: $sopsNix }'
}

# `repo-list <repo>` — Output JSON of SOPS secrets inside `<repo>/secrets/` and active sops-nix mounts.
cmd_repo_list() {
  local repo="${1:-}"
  [[ -n "$repo" ]] || die "usage: nixpit-secrets repo-list <repo>"
  validate_repo_dir "$repo"
  local pub repo_dir has_yaml=false sec_json active_json
  pub="$(cmd_init)"
  repo_dir="${REPOS_DIR}/${repo}"
  [[ -f "${repo_dir}/.sops.yaml" ]] && has_yaml=true
  sec_json="$(list_dir_names "${repo_dir}/secrets" ".sops.env" | jq -R . | jq -s .)"
  if [[ -d "/run/secrets/nixpit/${repo}" ]]; then
    active_json="$(find "/run/secrets/nixpit/${repo}" -maxdepth 1 -type f -printf '%f\n' | sort | jq -R . | jq -s .)"
  else
    active_json='[]'
  fi
  jq -nc \
    --arg repo "$repo" \
    --arg pub "$pub" \
    --argjson hasSopsYaml "$has_yaml" \
    --argjson secrets "$sec_json" \
    --argjson activeSopsNix "$active_json" \
    '{ repo: $repo, agePublicKey: $pub, hasSopsYaml: $hasSopsYaml, secrets: $secrets, activeSopsNix: $activeSopsNix }'
}

# Decrypt `enc_file` using the host Age key and stream dotenv pairs to stdout.
decrypt_to_stdout() {
  local enc_file="$1"
  [[ -r "$enc_file" ]] || die "encrypted secret not found: $enc_file"
  SOPS_AGE_KEY_FILE="${KEY_FILE}" sops -d --input-type dotenv --output-type dotenv "$enc_file"
}

# `get <name>` — Print decrypted KEY=VALUE lines for host-local secret `name`.
cmd_get() {
  local name="${1:-}"
  [[ -n "$name" ]] || die "usage: nixpit-secrets get <name>"
  validate_name "$name"
  cmd_init >/dev/null
  decrypt_to_stdout "${SECRETS_DIR}/${name}.sops.env"
}

# `repo-get <repo> <name>` — Decrypt `<repo>/secrets/<name>.sops.env` to stdout for UI editing.
cmd_repo_get() {
  local repo="${1:-}" name="${2:-}"
  [[ -n "$repo" && -n "$name" ]] || die "usage: nixpit-secrets repo-get <repo> <name>"
  validate_repo_dir "$repo"
  validate_name "$name"
  cmd_init >/dev/null
  decrypt_to_stdout "${REPOS_DIR}/${repo}/secrets/${name}.sops.env"
}

# Read KEY=VALUE dotenv pairs from stdin, encrypt via SOPS+Age for `recipients`, verify SOPS
# ciphertext markers, and atomically write to `out_file` with `mode`.
encrypt_stdin_dotenv() {
  local recipients="$1"
  local out_file="$2"
  local mode="$3"
  local label="$4"

  local workdir tmp_plain tmp_enc count=0
  workdir="$(mktemp -d)"
  chmod 0700 "$workdir"
  tmp_plain="${workdir}/${label}.env"
  tmp_enc="$(mktemp "${out_file}.tmp.XXXXXX")"
  chmod 0600 "$tmp_enc"

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*=.*$ ]] || {
      rm -rf "$workdir" "$tmp_enc"
      die "invalid dotenv line (expected KEY=VALUE)"
    }
    printf '%s\n' "$line" >> "$tmp_plain"
    count=$((count + 1))
  done

  if [[ "$count" -eq 0 ]]; then
    rm -rf "$workdir" "$tmp_enc"
    die "at least one KEY=VALUE entry is required"
  fi

  if ! SOPS_AGE_KEY_FILE="${KEY_FILE}" sops --encrypt --age "$recipients" --input-type dotenv --output-type dotenv "$tmp_plain" > "$tmp_enc"; then
    rm -rf "$workdir" "$tmp_enc"
    die "sops encryption failed for '$label'"
  fi
  rm -rf "$workdir"

  if ! grep -q 'ENC\[AES256_GCM,' "$tmp_enc" || ! grep -q '^sops_version=' "$tmp_enc"; then
    rm -f "$tmp_enc"
    die "encrypted output failed ciphertext verification for '$label'"
  fi

  chmod "$mode" "$tmp_enc"
  mv -f "$tmp_enc" "$out_file"
}

# Atomically decrypt host secret `<name>.sops.env` into tmpfs `${RUNTIME_DIR}/<name>.env`.
decrypt_one_runtime() {
  local name="$1"
  local enc_file="${SECRETS_DIR}/${name}.sops.env"
  local out_file="${RUNTIME_DIR}/${name}.env"
  local tmp
  tmp="$(mktemp "${RUNTIME_DIR}/.${name}.tmp.XXXXXX")"
  chmod 0600 "$tmp"
  if ! SOPS_AGE_KEY_FILE="${KEY_FILE}" sops -d --input-type dotenv --output-type dotenv "$enc_file" > "$tmp"; then
    rm -f "$tmp"
    die "failed to decrypt ${enc_file}"
  fi
  chmod 0400 "$tmp"
  mv -f "$tmp" "$out_file"
}

# `set <name>` — Encrypt stdin KEY=VALUE pairs into host `${SECRETS_DIR}/<name>.sops.env` (0600)
# and refresh tmpfs `${RUNTIME_DIR}/<name>.env`.
cmd_set() {
  local name="${1:-}"
  [[ -n "$name" ]] || die "usage: nixpit-secrets set <name>"
  validate_name "$name"
  local pub
  pub="$(cmd_init)"
  encrypt_stdin_dotenv "$pub" "${SECRETS_DIR}/${name}.sops.env" 0600 "$name"
  decrypt_one_runtime "$name"
  echo "Encrypted host ${name}.sops.env and synced runtime secret"
}

# `repo-set <repo> <name>` — Ensure `<repo>/.sops.yaml` has host Age key and encrypt stdin
# KEY=VALUE pairs straight into `<repo>/secrets/<name>.sops.env` ready for `git push` + `sops-nix`.
cmd_repo_set() {
  local repo="${1:-}" name="${2:-}"
  [[ -n "$repo" && -n "$name" ]] || die "usage: nixpit-secrets repo-set <repo> <name>"
  validate_repo_dir "$repo"
  validate_name "$name"
  local recipients sec_dir
  recipients="$(ensure_repo_sops_yaml "$repo")"
  sec_dir="${REPOS_DIR}/${repo}/secrets"
  install -d -m 0755 "$sec_dir"
  encrypt_stdin_dotenv "$recipients" "${sec_dir}/${name}.sops.env" 0644 "$name"
  echo "Encrypted ${repo}/secrets/${name}.sops.env (ready to push)"
}

# `ensure-sops-yaml <repo>` — Create or update `<repo>/.sops.yaml` with host Age pubkey and print it.
cmd_ensure_sops_yaml() {
  local repo="${1:-}"
  [[ -n "$repo" ]] || die "usage: nixpit-secrets ensure-sops-yaml <repo>"
  validate_repo_dir "$repo"
  ensure_repo_sops_yaml "$repo" >/dev/null
  cat "${REPOS_DIR}/${repo}/.sops.yaml"
}

# `delete <name>` — Remove host-local encrypted SOPS file and its tmpfs runtime file.
cmd_delete() {
  local name="${1:-}"
  [[ -n "$name" ]] || die "usage: nixpit-secrets delete <name>"
  validate_name "$name"
  rm -f "${SECRETS_DIR}/${name}.sops.env" "${RUNTIME_DIR}/${name}.env"
  echo "Deleted host secret ${name}"
}

# `repo-delete <repo> <name>` — Remove `<repo>/secrets/<name>.sops.env`.
cmd_repo_delete() {
  local repo="${1:-}" name="${2:-}"
  [[ -n "$repo" && -n "$name" ]] || die "usage: nixpit-secrets repo-delete <repo> <name>"
  validate_repo_dir "$repo"
  validate_name "$name"
  rm -f "${REPOS_DIR}/${repo}/secrets/${name}.sops.env"
  echo "Deleted ${repo}/secrets/${name}.sops.env"
}

# `sync` — Invoked by nixpit-secrets.service at boot: decrypt all host *.sops.env files into tmpfs
# and prune any stale runtime .env files whose encrypted source was removed.
cmd_sync() {
  cmd_init >/dev/null
  shopt -s nullglob
  local enc
  declare -A active=()
  for enc in "${SECRETS_DIR}"/*.sops.env; do
    local base name
    base="$(basename "$enc")"
    name="${base%.sops.env}"
    validate_name "$name"
    decrypt_one_runtime "$name"
    active["$name"]=1
  done
  local rt
  for rt in "${RUNTIME_DIR}"/*.env; do
    local base name
    base="$(basename "$rt")"
    name="${base%.env}"
    if [[ -z "${active[$name]:-}" ]]; then
      rm -f "$rt"
    fi
  done
  shopt -u nullglob
}

sub="${1:-}"
shift || true
case "$sub" in
  init) cmd_init "$@" ;;
  pubkey) cmd_pubkey "$@" ;;
  sops-config) cmd_sops_config "$@" ;;
  ensure-sops-yaml) cmd_ensure_sops_yaml "$@" ;;
  list) cmd_list "$@" ;;
  repo-list) cmd_repo_list "$@" ;;
  get) cmd_get "$@" ;;
  repo-get) cmd_repo_get "$@" ;;
  set) cmd_set "$@" ;;
  repo-set) cmd_repo_set "$@" ;;
  delete) cmd_delete "$@" ;;
  repo-delete) cmd_repo_delete "$@" ;;
  sync) cmd_sync "$@" ;;
  *) die "unknown command '$sub' (expected: init, pubkey, sops-config, ensure-sops-yaml, list, repo-list, get, repo-get, set, repo-set, delete, repo-delete, sync)" ;;
esac

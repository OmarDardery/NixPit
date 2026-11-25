#!/usr/bin/env bash
# nixpit-secrets — SOPS + Age Secret Management CLI and Service Runner.
#
# What: Manages the host Age keypair, encrypts host secrets at rest into
#       /var/lib/nixpit/secrets/*.sops.env (0600), and decrypts them into
#       in-memory tmpfs at /run/nixpit/secrets/*.env (0400).
# How:  Shares the exact same Age key file (/var/lib/nixpit/sops/age/keys.txt)
#       used by sops-nix, using atomic temp-file writes and strict permissions.
# Why:  Ensures plaintext credentials never reside on persistent disk, in Git,
#       or in the world-readable /nix/store.

set -euo pipefail

STATE_DIR="${NIXPIT_STATE_DIR:-/var/lib/nixpit}"
RUNTIME_DIR="${NIXPIT_RUNTIME_DIR:-/run/nixpit/secrets}"
AGE_DIR="${STATE_DIR}/sops/age"
KEY_FILE="${AGE_DIR}/keys.txt"
PUB_FILE="${AGE_DIR}/public.key"
SECRETS_DIR="${STATE_DIR}/secrets"

# Print error to stderr and abort immediately.
die() {
  echo "nixpit-secrets: $*" >&2
  exit 1
}

# Validate secret names to prevent path traversal into parent directories.
validate_name() {
  local name="$1"
  [[ "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || die "invalid secret name '$name'"
}

# `init` — Ensure 0700 state/runtime directories and generate the host Age key if absent,
# then derive and cache the public `age1...` key for encryption and .sops.yaml snippets.
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

# `sops-config` — Output a ready-to-use .sops.yaml snippet targeting this host's Age key.
cmd_sops_config() {
  local pub
  pub="$(cmd_init)"
  cat <<YAML
creation_rules:
  - path_regex: secrets/.*\.sops\.(env|ya?ml)$
    age: ${pub}
YAML
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
    sopsnix_json="$(find /run/secrets/nixpit -maxdepth 1 -type f -printf '%f\n' | sort | jq -R . | jq -s .)"
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

# Decrypt `enc_file` using the host Age key and stream dotenv pairs to stdout.
decrypt_to_stdout() {
  local enc_file="$1"
  [[ -r "$enc_file" ]] || die "encrypted secret not found: $enc_file"
  SOPS_AGE_KEY_FILE="${KEY_FILE}" sops -d --input-type dotenv --output-type dotenv "$enc_file"
}

# `get <name>` — Print decrypted KEY=VALUE lines for `name` (used by Cockpit editor).
cmd_get() {
  local name="${1:-}"
  [[ -n "$name" ]] || die "usage: nixpit-secrets get <name>"
  validate_name "$name"
  cmd_init >/dev/null
  decrypt_to_stdout "${SECRETS_DIR}/${name}.sops.env"
}

# Atomically decrypt `<name>.sops.env` into tmpfs `${RUNTIME_DIR}/<name>.env`.
# Writes with 0600 (owner-writable during redirection) then locks down to 0400 before mv.
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

# `set <name>` — Read KEY=VALUE pairs from stdin, validate keys, encrypt with SOPS+Age into
# `${SECRETS_DIR}/<name>.sops.env` (0600), and refresh the tmpfs runtime file immediately.
cmd_set() {
  local name="${1:-}"
  [[ -n "$name" ]] || die "usage: nixpit-secrets set <name>"
  validate_name "$name"
  local pub
  pub="$(cmd_init)"

  local workdir tmp_plain tmp_enc count=0
  workdir="$(mktemp -d)"
  chmod 0700 "$workdir"
  trap 'rm -rf "$workdir"' RETURN
  tmp_plain="${workdir}/${name}.env"
  tmp_enc="$(mktemp "${SECRETS_DIR}/.${name}.tmp.XXXXXX")"
  chmod 0600 "$tmp_enc"

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*=.*$ ]] || {
      rm -f "$tmp_enc"
      die "invalid dotenv line (expected KEY=VALUE)"
    }
    printf '%s\n' "$line" >> "$tmp_plain"
    count=$((count + 1))
  done

  if [[ "$count" -eq 0 ]]; then
    rm -f "$tmp_enc"
    die "at least one KEY=VALUE entry is required"
  fi

  if ! SOPS_AGE_KEY_FILE="${KEY_FILE}" sops --encrypt --age "$pub" --input-type dotenv --output-type dotenv "$tmp_plain" > "$tmp_enc"; then
    rm -f "$tmp_enc"
    die "sops encryption failed for '$name'"
  fi

  chmod 0600 "$tmp_enc"
  mv -f "$tmp_enc" "${SECRETS_DIR}/${name}.sops.env"
  decrypt_one_runtime "$name"
  echo "Encrypted ${name}.sops.env and synced runtime secret"
}

# `delete <name>` — Remove both the encrypted SOPS file and its tmpfs runtime file.
cmd_delete() {
  local name="${1:-}"
  [[ -n "$name" ]] || die "usage: nixpit-secrets delete <name>"
  validate_name "$name"
  rm -f "${SECRETS_DIR}/${name}.sops.env" "${RUNTIME_DIR}/${name}.env"
  echo "Deleted secret ${name}"
}

# `sync` — Invoked by nixpit-secrets.service at boot: decrypt all *.sops.env files into tmpfs
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
  list) cmd_list "$@" ;;
  get) cmd_get "$@" ;;
  set) cmd_set "$@" ;;
  delete) cmd_delete "$@" ;;
  sync) cmd_sync "$@" ;;
  *) die "unknown command '$sub' (expected: init, pubkey, sops-config, list, get, set, delete, sync)" ;;
esac

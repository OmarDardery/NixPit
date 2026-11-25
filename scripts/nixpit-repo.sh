#!/usr/bin/env bash
# nixpit-repo — Per-profile SSH Git keygen and pure Nix/Compose/Dockerfile/SOPS repo manager.
#
# What: Manages Git repo profiles in repos.json, generates an isolated ed25519
#       SSH deploy key per profile, clones/syncs/inspects/diffs/pushes workload configs.
# How:  Uses atomic temp-file writes for repos.json, checks Nix syntax with
#       `nix-instantiate --parse`, passes per-profile GIT_SSH_COMMAND (`IdentitiesOnly=yes`),
#       and blocks plaintext .env files or tampered SOPS files from being pushed.
# Why:  Isolates deploy credentials per repo and keeps external workload repos
#       100% standard Nix / Compose / Dockerfile / SOPS ciphertext.

set -euo pipefail

STATE_DIR="${NIXPIT_STATE_DIR:-/var/lib/nixpit}"
REPOS_FILE="${STATE_DIR}/repos.json"
REPOS_DIR="${STATE_DIR}/repos"
KEYS_DIR="${STATE_DIR}/keys"
KNOWN_HOSTS="${STATE_DIR}/ssh_known_hosts"

# Print an error message to stderr and exit non-zero (fail-closed helper).
die() {
  echo "nixpit-repo: $*" >&2
  exit 1
}

# Reject profile names that could cause path traversal or break systemd unit naming.
validate_name() {
  local name="$1"
  [[ "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || die "invalid profile name '$name'"
}

# Reject empty branch names, whitespace, or ".." traversal in ref names.
validate_branch() {
  local branch="$1"
  [[ -n "$branch" && "$branch" =~ ^[a-zA-Z0-9._/-]+$ && "$branch" != *".."* && "$branch" != /* && "$branch" != */ ]] || die "invalid branch '$branch'"
}

# Allow only SSH, HTTPS, or local filesystem repository URLs without spaces.
validate_url() {
  local url="$1"
  [[ -n "$url" && ! "$url" =~ [[:space:]] ]] || die "invalid repository url"
  [[ "$url" =~ ^(git@[a-zA-Z0-9._-]+:|ssh://|https://|file:///|/) ]] || die "unsupported repository url '$url'"
}

# Initialize state directories with 0700 permissions on keys/ and an empty repos.json array.
ensure_dirs() {
  install -d -m 0755 "${STATE_DIR}" "${REPOS_DIR}"
  install -d -m 0700 "${KEYS_DIR}"
  if [[ ! -f "${REPOS_FILE}" ]]; then
    atomic_write "${REPOS_FILE}" 0644 '[]'
  fi
}

# Write `content` to a temporary file in the target directory, chmod, and atomically rename.
atomic_write() {
  local target="$1"
  local mode="$2"
  local content="$3"
  local tmp
  tmp="$(mktemp "${target}.tmp.XXXXXX")"
  chmod "$mode" "$tmp"
  printf '%s\n' "$content" > "$tmp"
  mv -f "$tmp" "$target"
}

# Build GIT_SSH_COMMAND pinned to this profile's private key and isolated known_hosts file.
ssh_cmd_for() {
  local key_path="$1"
  printf 'ssh -i %s -o IdentitiesOnly=yes -o UserKnownHostsFile=%s -o StrictHostKeyChecking=accept-new' \
    "$key_path" "$KNOWN_HOSTS"
}

# Run nix-instantiate cleanly even inside sandboxed builds without nix-daemon.
run_nix_instantiate() {
  local nix_state="${TMPDIR:-/tmp}/nixpit-nix-state"
  install -d -m 0700 "$nix_state"
  NIX_REMOTE="" NIX_STATE_DIR="$nix_state" nix-instantiate "$@"
}

# Verify Nix syntax on every discovered `.nix` workload module in `dir`.
validate_repo_nix() {
  local dir="$1"
  local f
  for f in "${dir}/workloads.nix" "${dir}/default.nix"; do
    if [[ -f "$f" ]]; then
      run_nix_instantiate --parse "$f" >/dev/null || die "invalid Nix syntax in $f"
    fi
  done
  if [[ -d "${dir}/nix" ]]; then
    while IFS= read -r -d '' f; do
      run_nix_instantiate --parse "$f" >/dev/null || die "invalid Nix syntax in $f"
    done < <(find "${dir}/nix" -maxdepth 1 -type f -name '*.nix' -print0 | sort -z)
  fi
}

# Look up a field (url, branch, keyPath) for profile `name` inside repos.json.
get_profile_field() {
  local name="$1"
  local field="$2"
  jq -er --arg n "$name" --arg f "$field" '.[] | select(.name == $n) | .[$f] // empty' "${REPOS_FILE}"
}

# Create an ed25519 SSH keypair for `name` (0600 private, 0644 public); rotates only if force=1.
generate_key() {
  local name="$1"
  local force="${2:-0}"
  local key_path="${KEYS_DIR}/${name}.ed25519"
  if [[ -e "$key_path" && "$force" != "1" ]]; then
    chmod 0600 "$key_path"
    return 0
  fi
  rm -f "${key_path}" "${key_path}.pub"
  ssh-keygen -t ed25519 -f "$key_path" -N "" -C "nixpit:${name}" >/dev/null
  chmod 0600 "$key_path"
  chmod 0644 "${key_path}.pub"
}

# `list` — Return JSON array of all profiles enriched with public key, clone state, HEAD, and dirty flag.
cmd_list() {
  ensure_dirs
  jq -c '.[]' "${REPOS_FILE}" | while IFS= read -r row; do
    local name url branch key_path pubkey="" cloned=false commit="" dirty=false
    name="$(jq -r '.name' <<< "$row")"
    url="$(jq -r '.url' <<< "$row")"
    branch="$(jq -r '.branch // "main"' <<< "$row")"
    key_path="$(jq -r '.keyPath // ""' <<< "$row")"
    if [[ -n "$key_path" && -r "${key_path}.pub" ]]; then
      pubkey="$(tr -d '\n' < "${key_path}.pub")"
    fi
    local dir="${REPOS_DIR}/${name}"
    if [[ -d "${dir}/.git" ]]; then
      cloned=true
      commit="$(git -C "$dir" rev-parse --short HEAD 2>/dev/null || true)"
      if [[ -n "$(git -C "$dir" status --porcelain 2>/dev/null || true)" ]]; then
        dirty=true
      fi
    fi
    jq -nc \
      --arg name "$name" \
      --arg url "$url" \
      --arg branch "$branch" \
      --arg keyPath "$key_path" \
      --arg pubkey "$pubkey" \
      --argjson cloned "$cloned" \
      --arg commit "$commit" \
      --argjson dirty "$dirty" \
      '{ name: $name, url: $url, branch: $branch, keyPath: $keyPath, pubkey: $pubkey, cloned: $cloned, commit: $commit, dirty: $dirty }'
  done | jq -s '.'
}

# `add <name> <url> [branch]` — Register a new repo profile, generate its SSH keypair, and print JSON.
cmd_add() {
  local name="${1:-}" url="${2:-}" branch="${3:-main}"
  [[ -n "$name" && -n "$url" ]] || die "usage: nixpit-repo add <name> <url> [branch]"
  validate_name "$name"
  validate_url "$url"
  validate_branch "$branch"
  ensure_dirs

  if jq -e --arg n "$name" 'any(.[]; .name == $n)' "${REPOS_FILE}" >/dev/null; then
    die "profile '$name' already exists"
  fi

  generate_key "$name" 0
  local key_path="${KEYS_DIR}/${name}.ed25519"
  local updated
  updated="$(jq --arg n "$name" --arg u "$url" --arg b "$branch" --arg k "$key_path" \
    '. + [{ name: $n, url: $u, branch: $b, keyPath: $k }]' "${REPOS_FILE}")"
  atomic_write "${REPOS_FILE}" 0644 "$updated"

  local pubkey
  pubkey="$(tr -d '\n' < "${key_path}.pub")"
  jq -nc --arg n "$name" --arg u "$url" --arg b "$branch" --arg k "$key_path" --arg p "$pubkey" \
    '{ name: $n, url: $u, branch: $b, keyPath: $k, pubkey: $p }'
}

# `keygen <name> [--force]` — Generate or rotate (--force) a profile's SSH key and print its pubkey.
cmd_keygen() {
  local name="${1:-}" flag="${2:-}"
  [[ -n "$name" ]] || die "usage: nixpit-repo keygen <name> [--force]"
  validate_name "$name"
  ensure_dirs

  local force=0
  if [[ "$flag" == "--force" ]]; then
    force=1
  elif [[ -n "$flag" ]]; then
    die "unknown flag '$flag'"
  fi

  local key_path="${KEYS_DIR}/${name}.ed25519"
  if [[ -e "$key_path" && "$force" != "1" ]]; then
    die "key already exists for '$name' (pass --force to rotate)"
  fi
  generate_key "$name" "$force"
  cat "${key_path}.pub"
}

# `pubkey <name>` — Print the SSH public key for `name` so the user can add it as a deploy key.
cmd_pubkey() {
  local name="${1:-}"
  [[ -n "$name" ]] || die "usage: nixpit-repo pubkey <name>"
  validate_name "$name"
  local pub="${KEYS_DIR}/${name}.ed25519.pub"
  [[ -r "$pub" ]] || die "no public key found for '$name'"
  cat "$pub"
}

# Clone (if missing) or fast-forward pull a single profile's pinned branch using its SSH key.
# Fails closed if the local checkout has uncommitted changes or invalid `.nix` syntax.
sync_one() {
  local name="$1"
  validate_name "$name"
  local url branch key_path
  url="$(get_profile_field "$name" url)" || die "unknown profile '$name'"
  branch="$(get_profile_field "$name" branch || echo main)"
  [[ -n "$branch" ]] || branch="main"
  key_path="$(get_profile_field "$name" keyPath || true)"
  if [[ -z "$key_path" ]]; then
    generate_key "$name" 0
    key_path="${KEYS_DIR}/${name}.ed25519"
  fi

  local dir="${REPOS_DIR}/${name}"
  local ssh_cmd
  ssh_cmd="$(ssh_cmd_for "$key_path")"

  if [[ ! -d "${dir}/.git" ]]; then
    GIT_SSH_COMMAND="$ssh_cmd" git clone --branch "$branch" --single-branch -- "$url" "$dir"
  else
    if [[ -n "$(git -C "$dir" status --porcelain)" ]]; then
      die "refusing to sync dirty worktree in '$dir'"
    fi
    GIT_SSH_COMMAND="$ssh_cmd" git -C "$dir" fetch origin "$branch"
    git -C "$dir" checkout "$branch"
    GIT_SSH_COMMAND="$ssh_cmd" git -C "$dir" pull --ff-only origin "$branch"
  fi

  validate_repo_nix "$dir"
  echo "Synced ${name} (${branch}) at $(git -C "$dir" rev-parse --short HEAD)"
}

# `sync <name|--all>` — Sync one profile or every registered profile.
cmd_sync() {
  local target="${1:-}"
  [[ -n "$target" ]] || die "usage: nixpit-repo sync <name|--all>"
  ensure_dirs
  if [[ "$target" == "--all" ]]; then
    local names
    names="$(jq -r '.[].name' "${REPOS_FILE}")"
    for n in $names; do
      sync_one "$n"
    done
  else
    sync_one "$target"
  fi
}

# `inspect <name>` — Parse all `.nix` workload files, Compose/Dockerfile files, `.sops.yaml`,
# and `secrets/*.sops.env` in `name`, emitting a single JSON summary for Cockpit UI.
cmd_inspect() {
  local name="${1:-}"
  [[ -n "$name" ]] || die "usage: nixpit-repo inspect <name>"
  validate_name "$name"
  local dir="${REPOS_DIR}/${name}"
  [[ -d "$dir" ]] || die "profile '$name' is not cloned"

  local compose_file="" has_df=false has_sops=false
  if [[ -f "${dir}/compose.yaml" ]]; then
    compose_file="compose.yaml"
  elif [[ -f "${dir}/docker-compose.yml" ]]; then
    compose_file="docker-compose.yml"
  fi
  [[ -f "${dir}/Dockerfile" ]] && has_df=true
  [[ -f "${dir}/.sops.yaml" ]] && has_sops=true

  local secrets_json="[]"
  if [[ -d "${dir}/secrets" ]]; then
    secrets_json="$(find "${dir}/secrets" -maxdepth 1 -type f -name '*.sops.env' -printf '%f\n' | sed 's/\.sops\.env$//' | sort | jq -R . | jq -s .)"
  fi

  local -a rel_nix=()
  local f
  for f in workloads.nix default.nix; do
    [[ -f "${dir}/${f}" ]] && rel_nix+=("$f")
  done
  if [[ -d "${dir}/nix" ]]; then
    while IFS= read -r -d '' f; do
      rel_nix+=("nix/$(basename "$f")")
    done < <(find "${dir}/nix" -maxdepth 1 -type f -name '*.nix' -print0 | sort -z)
  fi

  local nix_files_json containers_json="{}" vms_json="{}" custom_json="[]"
  nix_files_json="$(printf '%s\n' "${rel_nix[@]:-}" | sed '/^$/d' | jq -R . | jq -s .)"

  for rel in "${rel_nix[@]:-}"; do
    [[ -n "$rel" ]] || continue
    local abs="${dir}/${rel}" eval_out=""
    local expr
    expr="let
      m = import ${abs};
      stubLib = { mkIf = c: v: if c then v else {}; mkDefault = x: x; mkForce = x: x; };
      res = if builtins.isFunction m then m { config = {}; pkgs = {}; lib = stubLib; nixvirt = {}; nixpitStateDir = \"/var/lib/nixpit\"; } else m;
      w = (res.services or {}).nixpit.workloads or {};
    in {
      containers = w.containers or {};
      vms = w.vms or {};
    }"
    if eval_out="$(run_nix_instantiate --eval --strict --json --expr "$expr" 2>/dev/null)"; then
      local c_chunk v_chunk
      c_chunk="$(jq --arg f "$rel" '.containers | with_entries(.value += { _file: $f })' <<< "$eval_out")"
      v_chunk="$(jq --arg f "$rel" '.vms | with_entries(.value += { _file: $f })' <<< "$eval_out")"
      containers_json="$(jq -s '.[0] * .[1]' <<< "${containers_json}"$'\n'"${c_chunk}")"
      vms_json="$(jq -s '.[0] * .[1]' <<< "${vms_json}"$'\n'"${v_chunk}")"
      if [[ "$(jq '(.containers | length) + (.vms | length)' <<< "$eval_out")" -eq 0 ]]; then
        custom_json="$(jq --arg f "$rel" '. + [$f]' <<< "$custom_json")"
      fi
    else
      custom_json="$(jq --arg f "$rel" '. + [$f]' <<< "$custom_json")"
    fi
  done

  jq -nc \
    --arg name "$name" \
    --argjson nixFiles "$nix_files_json" \
    --argjson customNixModules "$custom_json" \
    --arg composeFile "$compose_file" \
    --argjson hasDockerfile "$has_df" \
    --argjson hasSopsYaml "$has_sops" \
    --argjson secrets "$secrets_json" \
    --argjson containers "$containers_json" \
    --argjson vms "$vms_json" \
    '{ name: $name, nixFiles: $nixFiles, customNixModules: $customNixModules, composeFile: $composeFile, hasDockerfile: $hasDockerfile, hasSopsYaml: $hasSopsYaml, secrets: $secrets, containers: $containers, vms: $vms }'
}

# `diff <name>` — Display working-tree status plus unstaged and staged diffs for `name`.
cmd_diff() {
  local name="${1:-}"
  [[ -n "$name" ]] || die "usage: nixpit-repo diff <name>"
  validate_name "$name"
  local dir="${REPOS_DIR}/${name}"
  [[ -d "${dir}/.git" ]] || die "profile '$name' is not cloned"
  git -C "$dir" status --short
  git -C "$dir" diff
  git -C "$dir" diff --cached
}

# `push <name> [message]` — Stage allowlisted Nix/Compose/Dockerfile/SOPS files (never
# plaintext .env or symlinks), verify SOPS ciphertext, commit, and push with profile SSH key.
cmd_push() {
  local name="${1:-}" msg="${2:-Update NixPit configs}"
  [[ -n "$name" ]] || die "usage: nixpit-repo push <name> [message]"
  validate_name "$name"
  ensure_dirs
  local branch key_path dir ssh_cmd
  branch="$(get_profile_field "$name" branch || echo main)"
  [[ -n "$branch" ]] || branch="main"
  key_path="$(get_profile_field "$name" keyPath || true)"
  [[ -n "$key_path" ]] || key_path="${KEYS_DIR}/${name}.ed25519"
  dir="${REPOS_DIR}/${name}"
  [[ -d "${dir}/.git" ]] || die "profile '$name' is not cloned"
  ssh_cmd="$(ssh_cmd_for "$key_path")"

  validate_repo_nix "$dir"

  (
    cd "$dir"
    # Fail closed if any plaintext .env file (not *.sops.env) exists in tracked or untracked paths.
    while IFS= read -r status_line; do
      [[ -n "$status_line" ]] || continue
      local path="${status_line:3}"
      path="${path##* -> }"
      local base
      base="$(basename "$path")"
      if [[ "$base" == ".env" || ( "$base" == *.env && "$base" != *.sops.env ) ]]; then
        die "refusing plaintext env file '$path' (use nixpit-secrets repo-set)"
      fi
    done < <(git status --porcelain --untracked-files=all)

    if [[ -n "$(git status --porcelain)" ]]; then
      if ! git diff --cached --quiet; then
        die "refusing to commit pre-staged index; unstage first"
      fi

      local -a candidates=(workloads.nix default.nix compose.yaml docker-compose.yml Dockerfile .sops.yaml .gitignore)
      local item
      if [[ -d nix ]]; then
        while IFS= read -r -d '' item; do
          candidates+=("$item")
        done < <(find nix -maxdepth 1 -name '*.nix' -print0)
      fi
      while IFS= read -r item; do
        [[ -n "$item" ]] && candidates+=("$item")
      done < <(git ls-files 'nix/*.nix')

      if [[ -d secrets ]]; then
        while IFS= read -r -d '' item; do
          candidates+=("$item")
        done < <(find secrets -maxdepth 1 \( -name '*.sops.env' -o -name '*.sops.yaml' -o -name '*.sops.yml' \) -print0)
      fi
      while IFS= read -r item; do
        [[ "$item" =~ ^secrets/.*\.sops\.(env|ya?ml)$ ]] && candidates+=("$item")
      done < <(git ls-files 'secrets/*')

      declare -A seen=()
      for f in "${candidates[@]}"; do
        [[ -z "${seen[$f]:-}" ]] || continue
        seen["$f"]=1
        if [[ -L "$f" ]]; then
          die "refusing symlink: $f"
        fi
        if [[ "$f" =~ ^secrets/.*\.sops\.env$ && -f "$f" ]]; then
          if ! grep -q 'ENC\[AES256_GCM,' "$f" || ! grep -q 'sops_version=' "$f"; then
            die "refusing unencrypted SOPS file '$f'"
          fi
        fi
        if [[ -f "$f" ]] || git ls-files --error-unmatch -- "$f" >/dev/null 2>&1; then
          git add -- "$f"
        fi
      done
      git diff --cached --quiet || git commit -m "$msg"
    fi
    GIT_SSH_COMMAND="$ssh_cmd" git push origin "$branch"
  )
}

# `remove <name> [--purge]` — Remove profile from repos.json; delete checkout & keys only with --purge.
cmd_remove() {
  local name="${1:-}" flag="${2:-}"
  [[ -n "$name" ]] || die "usage: nixpit-repo remove <name> [--purge]"
  validate_name "$name"
  ensure_dirs
  local updated
  updated="$(jq --arg n "$name" '[ .[] | select(.name != $n) ]' "${REPOS_FILE}")"
  atomic_write "${REPOS_FILE}" 0644 "$updated"
  if [[ "$flag" == "--purge" ]]; then
    rm -rf "${REPOS_DIR:?}/${name}"
    rm -f "${KEYS_DIR}/${name}.ed25519" "${KEYS_DIR}/${name}.ed25519.pub"
  fi
  echo "Removed profile ${name}"
}

sub="${1:-}"
shift || true
case "$sub" in
  list) cmd_list "$@" ;;
  add) cmd_add "$@" ;;
  keygen) cmd_keygen "$@" ;;
  pubkey) cmd_pubkey "$@" ;;
  sync) cmd_sync "$@" ;;
  inspect) cmd_inspect "$@" ;;
  diff) cmd_diff "$@" ;;
  push) cmd_push "$@" ;;
  remove) cmd_remove "$@" ;;
  *) die "unknown command '$sub' (expected: list, add, keygen, pubkey, sync, inspect, diff, push, remove)" ;;
esac

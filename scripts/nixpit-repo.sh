#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="${NIXPIT_STATE_DIR:-/var/lib/nixpit}"
REPOS_FILE="${STATE_DIR}/repos.json"
REPOS_DIR="${STATE_DIR}/repos"
KEYS_DIR="${STATE_DIR}/keys"
KNOWN_HOSTS="${STATE_DIR}/ssh_known_hosts"

die() {
  echo "nixpit-repo: $*" >&2
  exit 1
}

validate_name() {
  local name="$1"
  [[ "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || die "invalid profile name '$name'"
}

validate_branch() {
  local branch="$1"
  [[ -n "$branch" && "$branch" =~ ^[a-zA-Z0-9._/-]+$ && "$branch" != *".."* && "$branch" != /* && "$branch" != */ ]] || die "invalid branch '$branch'"
}

validate_url() {
  local url="$1"
  [[ -n "$url" && ! "$url" =~ [[:space:]] ]] || die "invalid repository url"
  [[ "$url" =~ ^(git@[a-zA-Z0-9._-]+:|ssh://|https://|file:///|/) ]] || die "unsupported repository url '$url'"
}

ensure_dirs() {
  install -d -m 0755 "${STATE_DIR}" "${REPOS_DIR}"
  install -d -m 0700 "${KEYS_DIR}"
  if [[ ! -f "${REPOS_FILE}" ]]; then
    atomic_write "${REPOS_FILE}" 0644 '[]'
  fi
}

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

ssh_cmd_for() {
  local key_path="$1"
  printf 'ssh -i %s -o IdentitiesOnly=yes -o UserKnownHostsFile=%s -o StrictHostKeyChecking=accept-new' \
    "$key_path" "$KNOWN_HOSTS"
}

get_profile_field() {
  local name="$1"
  local field="$2"
  jq -er --arg n "$name" --arg f "$field" '.[] | select(.name == $n) | .[$f] // empty' "${REPOS_FILE}"
}

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

cmd_pubkey() {
  local name="${1:-}"
  [[ -n "$name" ]] || die "usage: nixpit-repo pubkey <name>"
  validate_name "$name"
  local pub="${KEYS_DIR}/${name}.ed25519.pub"
  [[ -r "$pub" ]] || die "no public key found for '$name'"
  cat "$pub"
}

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

  if [[ -f "${dir}/guests.json" ]]; then
    jq empty "${dir}/guests.json" || die "invalid JSON in ${dir}/guests.json"
  fi
  echo "Synced ${name} (${branch}) at $(git -C "$dir" rev-parse --short HEAD)"
}

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

  (
    cd "$dir"
    if [[ -n "$(git status --porcelain)" ]]; then
      if ! git diff --cached --quiet; then
        die "refusing to commit pre-staged index; unstage first"
      fi
      local candidates=(guests.json compose.yaml docker-compose.yml Dockerfile .sops.yaml)
      if [[ -d secrets ]]; then
        while IFS= read -r -d '' sf; do
          candidates+=("$sf")
        done < <(find secrets -maxdepth 1 \( -name '*.sops.env' -o -name '*.sops.yaml' -o -name '*.sops.yml' \) -print0)
      fi
      for f in "${candidates[@]}"; do
        if [[ -L "$f" ]]; then
          die "refusing symlink: $f"
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
  diff) cmd_diff "$@" ;;
  push) cmd_push "$@" ;;
  remove) cmd_remove "$@" ;;
  *) die "unknown command '$sub' (expected: list, add, keygen, pubkey, sync, diff, push, remove)" ;;
esac

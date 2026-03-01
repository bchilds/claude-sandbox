#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE_BASE="/tmp/claude-worktrees"
SANDBOX_IMAGE="claude"
SESSIONS_DIR="$HOME/.claude-sandbox/sessions"

# Defaults
MODE="copy"
NAME=""
NAME_PROVIDED=false
BRANCH=""
PROMPT=""
DESTROY=false
DRY_RUN=false
CLAUDE_ARGS=()

# ── Helpers ──────────────────────────────────────────────────────────────────

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "=> $*"; }
warn() { echo "WARN: $*" >&2; }

is_wsl2() {
  [[ -f /proc/version ]] && grep -qi microsoft /proc/version
}

sync_to_host() {
  local sandbox="$1" container_src="$2" host_dst="$3"
  rm -rf "$host_dst"
  mkdir -p "$host_dst"
  docker sandbox exec "$sandbox" \
    tar -cf - -C "$container_src" . \
    | tar -xf - -C "$host_dst"
}

ensure_hosts_conf() {
  local conf="$SCRIPT_DIR/allowed-hosts.conf"
  local example="$SCRIPT_DIR/allowed-hosts.conf.example"
  [[ -f "$conf" ]] && return
  [[ -f "$example" ]] || die "No allowed-hosts.conf or allowed-hosts.conf.example found"
  cp "$example" "$conf"
  info "Created allowed-hosts.conf from example template"
}

host_exists() {
  local file="$1" target="$2"
  while IFS= read -r line; do
    local stripped="${line%%#*}"
    stripped="$(echo "$stripped" | xargs)"
    [[ -z "$stripped" ]] && continue
    [[ "${stripped%% *}" == "$target" ]] && return 0
  done < "$file"
  return 1
}

usage() {
  cat <<'EOF'
Usage: claude-sandbox [OPTIONS] [repo-path] [-- <claude-args>]
       claude-sandbox list [repo-path | --all]
       claude-sandbox accept <name>
       claude-sandbox reject <name>
       claude-sandbox resume <name> [-- <claude-args>]
       claude-sandbox cleanup <name>

Run Claude Code in an isolated Docker sandbox with strict network whitelisting.

Options:
  -m, --mode copy|direct   Workspace mode (default: copy)
  -n, --name <name>        Sandbox name (default: auto-generated)
  -b, --branch <name>      Branch name (default: sandbox/<name> or sandbox/<timestamp>)
  -p, --prompt <text>      Pass prompt to claude via -p
  --destroy                Auto-remove sandbox + worktree on exit
  --dry-run                Print commands without executing
  -h, --help               Show this help

Subcommands:
  list [path|--all]        List sandbox sessions (default: filter by cwd repo)
  accept <name>            Merge sandbox branch into base branch and clean up
  reject <name>            Delete sandbox branch and clean up
  resume <name>            Re-enter sandbox with fresh AWS credentials
  cleanup <name>           Remove docker sandbox + session metadata only
  hosts [list|add|remove]  Manage network allowlist

Host management:
  hosts list                 Show configured hosts
  hosts add <host>           Allow host through sandbox proxy
  hosts add <host> --bypass  Allow + bypass proxy
  hosts remove <host>        Remove host from allowlist
EOF
  exit 0
}

run_cmd() {
  if $DRY_RUN; then
    echo "[dry-run] $*"
  else
    "$@"
  fi
}

# ── Session helpers ──────────────────────────────────────────────────────────

save_session() {
  mkdir -p "$SESSIONS_DIR"
  cat > "$SESSIONS_DIR/${NAME}.env" <<SESS
NAME="$NAME"
REPO_PATH="$REPO_PATH"
WORKSPACE="$WORKSPACE"
CONTAINER_WORKSPACE="$CONTAINER_WORKSPACE"
BRANCH_NAME="$BRANCH_NAME"
BASE_BRANCH="$BASE_BRANCH"
MODE="$MODE"
WORKTREE_PATH="${WORKTREE_PATH:-}"
VIRTIOFS_WORKSPACE="${VIRTIOFS_WORKSPACE:-}"
CREATED_AT="$CREATED_AT"
SESS
}

load_session() {
  local name="$1"
  local f="$SESSIONS_DIR/${name}.env"
  [[ -f "$f" ]] || die "No session found: $name"
  # shellcheck disable=SC1090
  source "$f"
}

remove_session() {
  rm -f "$SESSIONS_DIR/${1}.env"
}

remove_docker_sandbox() {
  docker sandbox rm "$1" 2>/dev/null || true
}

remove_clone() {
  local clone_path="$1"
  rm -rf "$clone_path"
}

# ── Subcommands ──────────────────────────────────────────────────────────────

cmd_list() {
  local filter_repo=""
  local show_all=false

  if [[ "${1:-}" == "--all" ]]; then
    show_all=true
  elif [[ -n "${1:-}" ]]; then
    filter_repo="$(cd "$1" && git rev-parse --show-toplevel 2>/dev/null)" \
      || die "$1 is not inside a git repository"
  else
    filter_repo="$(git rev-parse --show-toplevel 2>/dev/null)" || true
  fi

  mkdir -p "$SESSIONS_DIR"
  local files=("$SESSIONS_DIR"/*.env)
  if [[ ! -f "${files[0]:-}" ]]; then
    echo "No sandbox sessions found."
    return 0
  fi

  # Grab docker sandbox status once
  local docker_json
  docker_json="$(docker sandbox ls --json 2>/dev/null || echo '{}')"

  printf "%-35s %-7s %-30s %-20s %-8s\n" "NAME" "MODE" "BRANCH" "CREATED" "DOCKER"
  printf "%-35s %-7s %-30s %-20s %-8s\n" "---" "----" "------" "-------" "------"

  for f in "${files[@]}"; do
    [[ -f "$f" ]] || continue
    (
      # shellcheck disable=SC1090
      source "$f"
      if ! $show_all && [[ -n "$filter_repo" && "$REPO_PATH" != "$filter_repo" ]]; then
        exit 0
      fi
      local docker_status
      docker_status="$(echo "$docker_json" | python3 -c "
import sys, json
vms = json.load(sys.stdin).get('vms', [])
match = [v for v in vms if v['name'] == '$NAME']
print(match[0]['status'] if match else 'gone')
" 2>/dev/null || echo "unknown")"
      printf "%-35s %-7s %-30s %-20s %-8s\n" \
        "$NAME" "$MODE" "$BRANCH_NAME" "${CREATED_AT:-?}" "$docker_status"
    )
  done
}

cmd_accept() {
  local name="${1:?Usage: claude-sandbox accept <name>}"
  load_session "$name"

  if [[ "$MODE" == "copy" ]]; then
    # WSL2: sync container-local workspace back to host clone via tar pipe
    if [[ -n "${VIRTIOFS_WORKSPACE:-}" ]]; then
      info "Syncing container-local workspace back to host..."
      sync_to_host "$name" "$CONTAINER_WORKSPACE" "$WORKTREE_PATH"
    fi

    git -C "$WORKTREE_PATH" rev-parse --verify "$BRANCH_NAME" >/dev/null 2>&1 \
      || die "Branch $BRANCH_NAME not found in clone $WORKTREE_PATH"

    info "Fetching $BRANCH_NAME from clone..."
    git -C "$REPO_PATH" fetch "$WORKTREE_PATH" "$BRANCH_NAME:$BRANCH_NAME"
    info "Branch $BRANCH_NAME created in $REPO_PATH"

    remove_clone "$WORKTREE_PATH"
  else
    git -C "$REPO_PATH" rev-parse --verify "$BRANCH_NAME" >/dev/null 2>&1 \
      || die "Branch $BRANCH_NAME not found in $REPO_PATH"
    info "Branch $BRANCH_NAME already in $REPO_PATH"
  fi

  remove_docker_sandbox "$name"
  remove_session "$name"

  echo ""
  echo "Merge when ready:"
  echo "  git -C $REPO_PATH checkout $BASE_BRANCH"
  echo "  git -C $REPO_PATH merge $BRANCH_NAME"
  echo ""
  echo "Review:"
  echo "  git -C $REPO_PATH log $BASE_BRANCH..$BRANCH_NAME --oneline"
  echo "  git -C $REPO_PATH diff $BASE_BRANCH..$BRANCH_NAME"
}

cmd_reject() {
  local name="${1:?Usage: claude-sandbox reject <name>}"
  load_session "$name"

  remove_docker_sandbox "$name"

  if [[ "$MODE" == "copy" ]]; then
    remove_clone "$WORKTREE_PATH"
  else
    git -C "$REPO_PATH" checkout "$BASE_BRANCH" 2>/dev/null || true
    git -C "$REPO_PATH" branch -D "$BRANCH_NAME" 2>/dev/null || true
  fi

  remove_session "$name"
  info "Session $name rejected and cleaned up."
}

cmd_resume() {
  local name="${1:?Usage: claude-sandbox resume <name>}"
  shift
  load_session "$name"

  # WSL2: re-copy workspace if container was restarted and local copy is gone
  if [[ -n "${VIRTIOFS_WORKSPACE:-}" ]]; then
    local has_git
    has_git=$(docker sandbox exec "$name" \
      bash -c "[[ -d '$CONTAINER_WORKSPACE/.git' ]] && echo yes || echo no" 2>/dev/null || echo "no")
    if [[ "$has_git" != "yes" ]]; then
      info "WSL2: re-copying workspace to container-local path..."
      docker sandbox exec "$name" \
        bash -c "cp -a '$VIRTIOFS_WORKSPACE' '$CONTAINER_WORKSPACE'"
    fi
  fi

  # Remaining args after name are passed to claude
  local claude_args=(claude --dangerously-skip-permissions "$@")

  info "Resolving AWS credentials (profile: claude)..."
  eval "$(aws configure export-credentials --profile claude --format env)" \
    || die "Failed to resolve AWS credentials. Is 'claude' profile configured and SSO session active?"

  local exec_env=(
    -e "AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID"
    -e "AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY"
    -e "AWS_SESSION_TOKEN=${AWS_SESSION_TOKEN:-}"
    -e "AWS_REGION=us-east-1"
    -e "CLAUDE_CODE_USE_BEDROCK=1"
    -e "ANTHROPIC_MODEL=us.anthropic.claude-opus-4-6-v1"
  )

  info "Resuming sandbox: $name"
  docker sandbox exec -it \
    -w "$CONTAINER_WORKSPACE" \
    "${exec_env[@]}" \
    "$name" \
    "${claude_args[@]}"
}

cmd_cleanup() {
  local name="${1:?Usage: claude-sandbox cleanup <name>}"
  load_session "$name"
  remove_docker_sandbox "$name"
  remove_session "$name"
  info "Docker sandbox + session metadata removed for $name."
}

cmd_hosts() {
  local op="${1:-list}"
  shift 2>/dev/null || true
  case "$op" in
    list)   cmd_hosts_list ;;
    add)    cmd_hosts_add "$@" ;;
    remove) cmd_hosts_remove "$@" ;;
    *)      die "Unknown hosts operation: $op (use list, add, remove)" ;;
  esac
}

cmd_hosts_list() {
  ensure_hosts_conf
  local hosts_file="$SCRIPT_DIR/allowed-hosts.conf"
  printf "%-50s %s\n" "HOST" "FLAGS"
  printf "%-50s %s\n" "----" "-----"
  local count=0
  while IFS= read -r line; do
    local stripped="${line%%#*}"
    stripped="$(echo "$stripped" | xargs)"
    [[ -z "$stripped" ]] && continue
    local host="${stripped%% *}"
    local flags="${stripped#* }"
    [[ "$flags" == "$host" ]] && flags=""
    printf "%-50s %s\n" "$host" "$flags"
    count=$((count + 1))
  done < "$hosts_file"
  echo ""
  info "$count host(s) configured"
}

cmd_hosts_add() {
  [[ $# -lt 1 ]] && die "Usage: claude-sandbox hosts add <host> [--bypass]"
  ensure_hosts_conf
  local hosts_file="$SCRIPT_DIR/allowed-hosts.conf"
  local host="$1"
  local bypass=false
  [[ "${2:-}" == "--bypass" ]] && bypass=true
  host_exists "$hosts_file" "$host" && die "Host already exists: $host"
  local entry="$host"
  $bypass && entry="$host bypass"
  echo "$entry" >> "$hosts_file"
  info "Added: $entry"
}

cmd_hosts_remove() {
  [[ $# -lt 1 ]] && die "Usage: claude-sandbox hosts remove <host>"
  ensure_hosts_conf
  local hosts_file="$SCRIPT_DIR/allowed-hosts.conf"
  local host="$1"
  host_exists "$hosts_file" "$host" || die "Host not found: $host"
  local tmp
  tmp="$(mktemp)"
  while IFS= read -r line; do
    local stripped="${line%%#*}"
    stripped="$(echo "$stripped" | xargs)"
    local line_host="${stripped%% *}"
    if [[ -n "$stripped" && "$line_host" == "$host" ]]; then
      continue
    fi
    echo "$line" >> "$tmp"
  done < "$hosts_file"
  mv "$tmp" "$hosts_file"
  info "Removed: $host"
}

# ── Subcommand dispatch ──────────────────────────────────────────────────────

if [[ $# -gt 0 ]]; then
  case "$1" in
    help) usage ;;
    list|accept|reject|resume|cleanup|hosts)
      SUBCMD="$1"; shift; "cmd_$SUBCMD" "$@"; exit $? ;;
  esac
fi

# ── Parse args ───────────────────────────────────────────────────────────────

REPO_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--mode)    MODE="$2"; shift 2 ;;
    -n|--name)    NAME="$2"; NAME_PROVIDED=true; shift 2 ;;
    -b|--branch)  BRANCH="$2"; shift 2 ;;
    -p|--prompt)  PROMPT="$2"; shift 2 ;;
    --destroy)    DESTROY=true; shift ;;
    --dry-run)    DRY_RUN=true; shift ;;
    -h|--help)    usage ;;
    --)           shift; CLAUDE_ARGS=("$@"); break ;;
    -*)           die "Unknown option: $1" ;;
    *)
      [[ -z "$REPO_PATH" ]] && REPO_PATH="$1" || die "Unexpected argument: $1"
      shift
      ;;
  esac
done

# Default to current directory if no repo path given
if [[ -z "$REPO_PATH" ]]; then
  REPO_PATH="$(pwd)"
fi
REPO_PATH="$(cd "$REPO_PATH" && pwd)"
REPO_NAME="$(basename "$REPO_PATH")"

[[ "$MODE" == "copy" || "$MODE" == "direct" ]] || die "Invalid mode: $MODE (must be copy|direct)"

# ── 1. Check prerequisites ──────────────────────────────────────────────────

info "Checking prerequisites..."

command -v docker >/dev/null 2>&1 || die "docker not found"
docker sandbox ls >/dev/null 2>&1 || die "docker sandbox not available — requires Docker Desktop with sandbox support"
command -v aws >/dev/null 2>&1 || die "aws CLI not found"
command -v git >/dev/null 2>&1 || die "git not found"

# Verify repo is a git repository
git -C "$REPO_PATH" rev-parse --git-dir >/dev/null 2>&1 || die "$REPO_PATH is not a git repository"

# ── 2. Resolve workspace ────────────────────────────────────────────────────

BASE_BRANCH="$(git -C "$REPO_PATH" rev-parse --abbrev-ref HEAD)"
CREATED_AT="$(date -Iseconds)"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

# Resolve branch name: explicit -b > sandbox/<name> > sandbox/<timestamp>
if [[ -n "$BRANCH" ]]; then
  BRANCH_NAME="$BRANCH"
elif $NAME_PROVIDED; then
  BRANCH_NAME="sandbox/$NAME"
else
  BRANCH_NAME="sandbox/$TIMESTAMP"
fi

if [[ "$MODE" == "copy" ]]; then
  WORKTREE_PATH="$WORKTREE_BASE/${REPO_NAME}-$$"
  mkdir -p "$WORKTREE_BASE"
  info "Cloning repo: $WORKTREE_PATH (branch: $BRANCH_NAME)"
  run_cmd git clone --local --branch "$BASE_BRANCH" "$REPO_PATH" "$WORKTREE_PATH"
  run_cmd git -C "$WORKTREE_PATH" checkout -b "$BRANCH_NAME"
  WORKSPACE="$WORKTREE_PATH"
else
  info "Creating branch in-place: $BRANCH_NAME"
  run_cmd git -C "$REPO_PATH" checkout -b "$BRANCH_NAME"
  WORKSPACE="$REPO_PATH"
fi

# ── 3. Resolve AWS credentials ──────────────────────────────────────────────

info "Resolving AWS credentials (profile: claude)..."

if $DRY_RUN; then
  echo "[dry-run] eval \$(aws configure export-credentials --profile claude --format env)"
  AWS_ACCESS_KEY_ID="DRY_RUN"
  AWS_SECRET_ACCESS_KEY="DRY_RUN"
  AWS_SESSION_TOKEN="DRY_RUN"
else
  eval "$(aws configure export-credentials --profile claude --format env)" \
    || die "Failed to resolve AWS credentials. Is 'claude' profile configured and SSO session active?"

  [[ -n "${AWS_ACCESS_KEY_ID:-}" ]]     || die "AWS_ACCESS_KEY_ID not set after credential export"
  [[ -n "${AWS_SECRET_ACCESS_KEY:-}" ]] || die "AWS_SECRET_ACCESS_KEY not set after credential export"
fi

# ── 4. Generate sandbox name ────────────────────────────────────────────────

if [[ -z "$NAME" ]]; then
  NAME="claude-${REPO_NAME}-$$"
fi

info "Sandbox name: $NAME"

# ── 5. Create sandbox ───────────────────────────────────────────────────────

info "Creating sandbox (may take a minute on first run)..."
run_cmd docker sandbox create --name "$NAME" "$SANDBOX_IMAGE" "$WORKSPACE"
info "Sandbox created."

# Resolve container-side workspace path (handles WSL2 UNC paths)
CONTAINER_WORKSPACE=$(
  docker sandbox ls --json 2>/dev/null \
    | python3 -c "
import sys, json
vms = json.load(sys.stdin).get('vms', [])
match = [v for v in vms if v['name'] == '$NAME']
if match:
    ws = match[0].get('workspaces', [''])[0]
    print(ws.replace('\\\\', '/'))
" 2>/dev/null || echo "$WORKSPACE"
)
info "Container workspace: $CONTAINER_WORKSPACE"

# WSL2: copy workspace to container-local path to avoid EIO on bind-mount
VIRTIOFS_WORKSPACE=""
if is_wsl2 && [[ "$MODE" == "copy" ]]; then
  info "WSL2 detected — copying workspace to container-local path..."
  VIRTIOFS_WORKSPACE="$CONTAINER_WORKSPACE"
  CONTAINER_WORKSPACE="/home/agent/project"
  docker sandbox exec "$NAME" \
    bash -c "cp -a '$VIRTIOFS_WORKSPACE' '$CONTAINER_WORKSPACE'"
  info "Workspace copied to $CONTAINER_WORKSPACE (bind-mount: $VIRTIOFS_WORKSPACE)"
fi

save_session

# ── 6. Configure network ────────────────────────────────────────────────────

info "Locking down network (deny all, whitelist from allowed-hosts.conf)..."

HOSTS_FILE="$SCRIPT_DIR/allowed-hosts.conf"
ensure_hosts_conf

ALLOW_ARGS=()
BYPASS_ARGS=()

while IFS= read -r line; do
  # Strip comments and blank lines
  line="${line%%#*}"
  line="$(echo "$line" | xargs)"
  [[ -z "$line" ]] && continue

  host="${line%% *}"
  flags="${line#* }"

  ALLOW_ARGS+=(--allow-host "$host")

  if [[ "$flags" == *bypass* ]]; then
    BYPASS_ARGS+=(--bypass-host "$host")
  fi
done < "$HOSTS_FILE"

run_cmd docker sandbox network proxy "$NAME" \
  --policy deny \
  "${ALLOW_ARGS[@]}" \
  "${BYPASS_ARGS[@]}"
info "Network configured."

# ── 7. Build exec command ───────────────────────────────────────────────────

EXEC_ENV=(
  -e "AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID"
  -e "AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY"
  -e "AWS_SESSION_TOKEN=${AWS_SESSION_TOKEN:-}"
  -e "AWS_REGION=us-east-1"
  -e "CLAUDE_CODE_USE_BEDROCK=1"
  -e "ANTHROPIC_MODEL=us.anthropic.claude-opus-4-6-v1"
)

EXEC_CLAUDE_ARGS=(claude --dangerously-skip-permissions)

if [[ -n "$PROMPT" ]]; then
  EXEC_CLAUDE_ARGS+=(-p "$PROMPT")
fi

if [[ ${#CLAUDE_ARGS[@]} -gt 0 ]]; then
  EXEC_CLAUDE_ARGS+=("${CLAUDE_ARGS[@]}")
fi

# ── 8. Cleanup trap ─────────────────────────────────────────────────────────

cleanup() {
  local exit_code=$?
  echo ""

  # WSL2: sync container-local workspace back to host clone via tar pipe
  if ! $DESTROY && [[ -n "${VIRTIOFS_WORKSPACE:-}" ]]; then
    info "Syncing container-local workspace back to host..."
    sync_to_host "$NAME" "$CONTAINER_WORKSPACE" "${WORKTREE_PATH:-$WORKSPACE}"
  fi

  if $DESTROY; then
    info "Destroying sandbox: $NAME"
    remove_docker_sandbox "$NAME"

    if [[ "$MODE" == "copy" ]]; then
      info "Removing clone: $WORKTREE_PATH"
      remove_clone "$WORKTREE_PATH"
    fi

    remove_session "$NAME"
  else
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  Sandbox session ended                                      ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Resume sandbox:"
    echo "  claude-sandbox resume $NAME"
    echo ""

    if [[ "$MODE" == "copy" ]]; then
      echo "Review changes:"
      echo "  git -C $WORKTREE_PATH log --oneline"
      echo "  git -C $WORKTREE_PATH diff ${BASE_BRANCH}..HEAD"
    else
      echo "Review changes:"
      echo "  git -C $REPO_PATH log --oneline $BRANCH_NAME"
      echo "  git -C $REPO_PATH diff ${BASE_BRANCH}..$BRANCH_NAME"
    fi

    echo ""
    echo "Accept:   claude-sandbox accept $NAME"
    echo "Reject:   claude-sandbox reject $NAME"
    echo "Cleanup:  claude-sandbox cleanup $NAME"
    echo ""
  fi

  exit $exit_code
}

trap cleanup EXIT INT TERM

# ── 9. Run Claude ────────────────────────────────────────────────────────────

info "Launching Claude in sandbox..."
echo ""

run_cmd docker sandbox exec -it \
  -w "$CONTAINER_WORKSPACE" \
  "${EXEC_ENV[@]}" \
  "$NAME" \
  "${EXEC_CLAUDE_ARGS[@]}"

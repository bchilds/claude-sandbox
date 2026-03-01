#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE_BASE="/tmp/claude-worktrees"
SANDBOX_IMAGE="claude"

# Defaults
MODE="copy"
NAME=""
PROMPT=""
DESTROY=false
DRY_RUN=false
CLAUDE_ARGS=()

# ── Helpers ──────────────────────────────────────────────────────────────────

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "=> $*"; }
warn() { echo "WARN: $*" >&2; }

usage() {
  cat <<'EOF'
Usage: claude-sandbox [OPTIONS] <repo-path> [-- <claude-args>]

Run Claude Code in an isolated Docker sandbox with strict network whitelisting.

Options:
  -m, --mode copy|direct   Workspace mode (default: copy)
  -n, --name <name>        Sandbox name (default: auto-generated)
  -p, --prompt <text>      Pass prompt to claude via -p
  --destroy                Auto-remove sandbox + worktree on exit
  --dry-run                Print commands without executing
  -h, --help               Show this help
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

# ── Parse args ───────────────────────────────────────────────────────────────

REPO_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--mode)    MODE="$2"; shift 2 ;;
    -n|--name)    NAME="$2"; shift 2 ;;
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

[[ -n "$REPO_PATH" ]] || die "Missing required <repo-path>. See --help."
REPO_PATH="$(cd "$REPO_PATH" && pwd)"
REPO_NAME="$(basename "$REPO_PATH")"

[[ "$MODE" == "copy" || "$MODE" == "direct" ]] || die "Invalid mode: $MODE (must be copy|direct)"

# ── 1. Check prerequisites ──────────────────────────────────────────────────

info "Checking prerequisites..."

command -v docker >/dev/null 2>&1 || die "docker not found"
docker sandbox --help >/dev/null 2>&1 || die "docker sandbox not available — requires Docker Desktop with sandbox support"
command -v aws >/dev/null 2>&1 || die "aws CLI not found"
command -v git >/dev/null 2>&1 || die "git not found"

# Verify repo is a git repository
git -C "$REPO_PATH" rev-parse --git-dir >/dev/null 2>&1 || die "$REPO_PATH is not a git repository"

# ── 2. Resolve workspace ────────────────────────────────────────────────────

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BRANCH_NAME="sandbox/$TIMESTAMP"

if [[ "$MODE" == "copy" ]]; then
  WORKTREE_PATH="$WORKTREE_BASE/${REPO_NAME}-$$"
  mkdir -p "$WORKTREE_BASE"
  info "Creating worktree: $WORKTREE_PATH (branch: $BRANCH_NAME)"
  run_cmd git -C "$REPO_PATH" worktree add "$WORKTREE_PATH" -b "$BRANCH_NAME"
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

info "Creating sandbox..."
run_cmd docker sandbox create --name "$NAME" "$SANDBOX_IMAGE" "$WORKSPACE"

# ── 6. Configure network ────────────────────────────────────────────────────

info "Locking down network (deny all, whitelist from allowed-hosts.conf)..."

HOSTS_FILE="$SCRIPT_DIR/allowed-hosts.conf"
[[ -f "$HOSTS_FILE" ]] || die "Missing $HOSTS_FILE"

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

  if $DESTROY; then
    info "Destroying sandbox: $NAME"
    docker sandbox rm "$NAME" 2>/dev/null || true

    if [[ "$MODE" == "copy" ]]; then
      info "Removing worktree: $WORKTREE_PATH"
      git -C "$REPO_PATH" worktree remove "$WORKTREE_PATH" --force 2>/dev/null || true
      git -C "$REPO_PATH" branch -D "$BRANCH_NAME" 2>/dev/null || true
    fi
  else
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  Sandbox session ended                                      ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Resume sandbox:"
    echo "  docker sandbox exec -it ${EXEC_ENV[*]} $NAME claude --dangerously-skip-permissions"
    echo ""

    if [[ "$MODE" == "copy" ]]; then
      echo "Review changes:"
      echo "  git -C $WORKTREE_PATH log --oneline"
      echo "  git -C $WORKTREE_PATH diff main..HEAD"
      echo ""
      echo "Accept (merge into your repo):"
      echo "  cd $REPO_PATH && git merge $BRANCH_NAME"
      echo ""
      echo "Reject (clean up):"
      echo "  git -C $REPO_PATH worktree remove $WORKTREE_PATH"
      echo "  git -C $REPO_PATH branch -D $BRANCH_NAME"
    else
      echo "Review changes:"
      echo "  git -C $REPO_PATH log --oneline $BRANCH_NAME"
      echo "  git -C $REPO_PATH diff main..$BRANCH_NAME"
      echo ""
      echo "Reject:"
      echo "  cd $REPO_PATH && git checkout main && git branch -D $BRANCH_NAME"
    fi

    echo ""
    echo "Remove sandbox:"
    echo "  docker sandbox rm $NAME"
    echo ""
  fi

  exit $exit_code
}

trap cleanup EXIT INT TERM

# ── 9. Run Claude ────────────────────────────────────────────────────────────

info "Launching Claude in sandbox..."
echo ""

run_cmd docker sandbox exec -it \
  "${EXEC_ENV[@]}" \
  "$NAME" \
  "${EXEC_CLAUDE_ARGS[@]}"

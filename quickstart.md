# Quickstart

## Prerequisites

**Required software:**

- Docker Desktop with sandbox support (`docker sandbox --help` must work)
- AWS CLI v2.13+ (`aws --version`)
- git

**AWS SSO profile (`claude`):**

```bash
aws configure sso --profile claude
# SSO start URL: <your org's SSO URL>
# Region: us-east-1
# Account/role: whichever has Bedrock InvokeModel access
```

Your repo must be a git repository.

---

## First run (copy mode)

Copy mode is the default — creates a git worktree so your original repo stays untouched.

```bash
# 1. Authenticate
aws sso login --profile claude

# 2. Launch sandbox
./claude-sandbox.sh ~/projects/my-repo
```

What happens:

1. Creates a git worktree at `/tmp/claude-worktrees/<repo>-<pid>` on branch `sandbox/<timestamp>`
2. Spins up a Docker sandbox with only whitelisted hosts (Bedrock, STS)
3. Injects AWS credentials as env vars
4. Runs `claude --dangerously-skip-permissions` inside the sandbox

---

## Review & merge

On exit (copy mode), you'll see:

```
Review changes:
  git -C /tmp/claude-worktrees/my-repo-12345 log --oneline
  git -C /tmp/claude-worktrees/my-repo-12345 diff main..HEAD

Accept (merge into your repo):
  cd ~/projects/my-repo && git merge sandbox/20260228-143000

Reject (clean up):
  git -C ~/projects/my-repo worktree remove /tmp/claude-worktrees/my-repo-12345
  git -C ~/projects/my-repo branch -D sandbox/20260228-143000
```

You can also resume the sandbox instead of merging immediately:

```bash
docker sandbox exec -it \
  -e "AWS_ACCESS_KEY_ID=..." -e "AWS_SECRET_ACCESS_KEY=..." -e "AWS_SESSION_TOKEN=..." \
  -e "AWS_REGION=us-east-1" -e "CLAUDE_CODE_USE_BEDROCK=1" -e "ANTHROPIC_MODEL=us.anthropic.claude-opus-4-6-v1" \
  claude-my-repo-12345 claude --dangerously-skip-permissions
```

---

## Other modes

### Direct mode

Works in-place on your repo (creates a branch, no worktree):

```bash
./claude-sandbox.sh -m direct ~/projects/my-repo
```

### Auto-destroy on exit

Removes the sandbox container and worktree/branch automatically:

```bash
./claude-sandbox.sh --destroy ~/projects/my-repo
```

### Pass a prompt

```bash
./claude-sandbox.sh -p "Refactor auth module to use JWT" ~/projects/my-repo
```

### Extra claude args

Everything after `--` is forwarded to `claude`:

```bash
./claude-sandbox.sh ~/projects/my-repo -- --model us.anthropic.claude-sonnet-4-6-v1
```

### Custom sandbox name

```bash
./claude-sandbox.sh -n my-sandbox ~/projects/my-repo
```

---

## Dry run

Prints every command without executing:

```bash
./claude-sandbox.sh --dry-run ~/projects/my-repo
```

Output prefixed with `[dry-run]` — useful for verifying setup before committing resources.

---

## Customizing allowed hosts

Edit `allowed-hosts.conf` to control network access inside the sandbox:

```conf
# format: <host> [bypass]
# "bypass" skips the Docker network proxy for that host

bedrock-runtime.us-east-1.amazonaws.com bypass
sts.amazonaws.com bypass
registry.npmjs.org
```

Hosts without `bypass` go through the Docker sandbox proxy. The default policy is **deny all** — only listed hosts are reachable.

---

## Troubleshooting

| Error | Fix |
|---|---|
| `docker sandbox not available` | Install/update Docker Desktop; enable sandbox feature in settings |
| `Failed to resolve AWS credentials` | Run `aws sso login --profile claude` |
| `AWS_ACCESS_KEY_ID not set` | SSO session expired — re-run `aws sso login --profile claude` |
| `<repo> is not a git repository` | Target path must be a git repo (`git init` first) |
| Network timeout inside sandbox | Host not in `allowed-hosts.conf` — add it and recreate the sandbox |
| `Missing allowed-hosts.conf` | File must exist alongside `claude-sandbox.sh` |

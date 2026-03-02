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

## Setup

Copy the example hosts file:

```bash
cp allowed-hosts.conf.example allowed-hosts.conf
```

Edit `allowed-hosts.conf` to add any additional hosts your project needs.

---

## First run (copy mode)

Copy mode is the default — clones your repo so the original stays untouched.
Run from inside your repo (or pass a path as the last argument).

```bash
# 1. Authenticate
aws sso login --profile claude

# 2. Launch sandbox (from inside your repo)
claude-sandbox -n my-feature
```

What happens:

1. Clones your repo to `/tmp/claude-worktrees/<repo>-<pid>` on branch `sandbox/my-feature`
2. Spins up a Docker sandbox with only whitelisted hosts (Bedrock, STS)
3. Injects AWS credentials as env vars
4. Runs `claude --dangerously-skip-permissions` inside the sandbox

---

## Example: develop a minor feature

Walk-through of a realistic session.

### 1. Launch with a prompt

```bash
claude-sandbox -n healthcheck -p "Add a /healthcheck endpoint that returns { status: 'ok' }"
```

This clones the repo, spins up the sandbox, and drops Claude straight into the task.

### 2. What Claude does (inside the sandbox)

- Reads the project structure and existing routes
- Adds `GET /healthcheck` with a JSON response
- Writes a test, runs it, iterates until green
- Commits to the `sandbox/healthcheck` branch

You can watch progress in real time — the sandbox is interactive.

### 3. Review the changes

After Claude exits (or you `ctrl-c`), the script prints review commands:

```bash
git -C /tmp/claude-worktrees/test-repo-12345 log --oneline
git -C /tmp/claude-worktrees/test-repo-12345 diff main..HEAD
```

### 4. Merge or discard

```bash
claude-sandbox accept healthcheck    # merges into your repo, removes clone
claude-sandbox reject healthcheck    # removes clone, no changes
```

### Variations

```bash
# direct mode — no clone, branches in-place
claude-sandbox -n pagination-fix -m direct -p "Fix the off-by-one in pagination"

# auto-cleanup — sandbox + clone removed on exit
claude-sandbox -n express-upgrade --destroy -p "Upgrade Express to v5"

# dry run first to verify setup
claude-sandbox -n dry-test --dry-run
```

---

## Review & merge

On exit (copy mode), you'll see:

```
Resume sandbox:
  claude-sandbox resume my-feature

Review changes:
  git -C /tmp/claude-worktrees/my-repo-12345 log --oneline
  git -C /tmp/claude-worktrees/my-repo-12345 diff main..HEAD

Accept:   claude-sandbox accept my-feature
Reject:   claude-sandbox reject my-feature
Cleanup:  claude-sandbox cleanup my-feature
```

---

## Other modes

### Direct mode

Works in-place on your repo (creates a branch, no clone):

```bash
claude-sandbox -n my-refactor -m direct
```

### Auto-destroy on exit

Removes the sandbox container and clone/branch automatically:

```bash
claude-sandbox -n throwaway --destroy
```

### Pass a prompt

```bash
claude-sandbox -n jwt-refactor -p "Refactor auth module to use JWT"
```

### Custom branch name

Override the default `sandbox/<name|timestamp>` branch:

```bash
claude-sandbox -n my-feature -b feature/cool-thing
```

### Extra claude args

Everything after `--` is forwarded to `claude`:

```bash
claude-sandbox -n sonnet-test -- --model us.anthropic.claude-sonnet-4-6-v1
```

---

## Dry run

Prints every command without executing:

```bash
claude-sandbox --dry-run
```

Output prefixed with `[dry-run]` — useful for verifying setup before committing resources.

---

## Customizing allowed hosts

Edit your local `allowed-hosts.conf` (copied from `allowed-hosts.conf.example`) to control network access inside the sandbox:

```conf
# format: <host> [bypass]
# "bypass" skips the Docker network proxy for that host

bedrock-runtime.us-east-1.amazonaws.com bypass
sts.amazonaws.com bypass
registry.npmjs.org
```

Hosts without `bypass` go through the Docker sandbox proxy. The default policy is **deny all** — only listed hosts are reachable.

---

## Sandbox hooks

Run custom setup scripts inside the sandbox **before** network lockdown (so they have internet access for downloads).

1. Copy the example config: `cp sandbox-hooks.conf.example sandbox-hooks.conf`
2. Uncomment or add script names (one per line, relative to `sandbox-hooks/`):

```conf
install-node.sh
```

3. Scripts in `sandbox-hooks/` are piped into the container via `bash -s` — no files are copied in.

**Included hooks:**

| Script            | What it does                                          |
| ----------------- | ----------------------------------------------------- |
| `install-node.sh` | Installs nvm + Node.js LTS (skips if already present) |

Add your own scripts to `sandbox-hooks/` and list them in `sandbox-hooks.conf` to enable.

---

## Toggling network access

Temporarily open the network (e.g. to install packages), then re-lock:

```bash
claude-sandbox net-open my-feature      # allow all outbound traffic
docker sandbox exec my-feature npm install   # install whatever you need
claude-sandbox net-lock my-feature      # re-apply allowed-hosts.conf deny policy
```

`net-lock` re-reads `allowed-hosts.conf`, so edits made while open take effect immediately.

---

## Notes

- **Interactive shell into a running sandbox:** `docker sandbox exec -it <sandbox-name> bash` (use `docker sandbox ls` to find the name)

---

## Troubleshooting

| Error                               | Fix                                                                                            |
| ----------------------------------- | ---------------------------------------------------------------------------------------------- |
| `docker sandbox not available`      | Install/update Docker Desktop; enable sandbox feature in settings                              |
| `Failed to resolve AWS credentials` | Run `aws sso login --profile claude`                                                           |
| `AWS_ACCESS_KEY_ID not set`         | SSO session expired — re-run `aws sso login --profile claude`                                  |
| `<repo> is not a git repository`    | Target path must be a git repo (`git init` first)                                              |
| Network timeout inside sandbox      | Host not in `allowed-hosts.conf` — add it and run `claude-sandbox net-lock <name>` to re-apply |
| `Missing allowed-hosts.conf`        | Run `cp allowed-hosts.conf.example allowed-hosts.conf` (see [Setup](#setup))                   |

# AGENTS.md

This file provides instructions for AI coding agents (Codex) working in this repository.

## Environment

You are running inside a **sandboxed Dev Container** with the following security architecture:

- **Filesystem**: bwrap sandbox enforces workspace-write mode. You can write to the workspace and TMPDIR, but `.git/` and `.codex/` are **read-only**
- **Network**: All outbound traffic from the `node` user is routed through a sidecar mitmproxy container that enforces a domain allowlist. Direct internet access is blocked by iptables
- **sudo**: In Secure mode (workspace-write), `PR_SET_NO_NEW_PRIVS` prevents privilege escalation via `sudo` within sandboxed commands. In Degraded/Unsafe modes, this protection is absent
- **This file**: AGENTS.md is an advisory (soft) constraint. It complements the hard constraints above but is not enforced at the system level. For Claude Code, equivalent rules are enforced by PreToolUse hooks

## Prohibited Operations

The following operations are prohibited. These rules mirror the PreToolUse hook rules in `.claude/hooks/pre-tool-use.sh`.

### Firewall / Proxy

- **DO NOT** run: `sudo iptables`, `sudo ip6tables`, `sudo ipset`, `sudo nft`, `sudo iptables-nft`, `sudo ip route`, `sudo ip rule`
- **DO NOT** modify proxy environment variables: `unset HTTP_PROXY`, `unset HTTPS_PROXY`, `export HTTP_PROXY=`, `export HTTPS_PROXY=`
- **DO NOT** bypass proxy: `curl --noproxy`, `env -u HTTP_PROXY`, `env -u HTTPS_PROXY`, `env -i`

### Git — Destructive Operations

- **DO NOT** force push: `git push --force`, `git push -f`
- **DO NOT** hard reset: `git reset --hard`
- **DO NOT** delete branches: `git branch -D`, `git branch -d`

### Git — Branch Protection

Protected branches: `main` (customizable in `.claude/hooks/pre-tool-use.sh`)

- **DO NOT** push directly to protected branches: `git push origin main`
- **DO NOT** checkout protected branches: `git checkout main`, `git switch main`
- **DO NOT** create PRs targeting protected branches: `gh pr create --base main`
- **DO NOT** merge PRs targeting protected branches: `gh pr merge` (when target is main)

### Filesystem

- **DO NOT** run: `rm -rf /`

## Git Workflow

1. Always work on feature/fix branches
2. Create PRs targeting `main` is prohibited — use the appropriate development branch
3. Never push directly to protected branches

## Hierarchy Warning

This file's rules apply to the entire project. Subdirectory `AGENTS.md` files **MUST NOT** relax or override these security rules. Codex interprets `AGENTS.md` files hierarchically — a subdirectory file could potentially override root-level rules.

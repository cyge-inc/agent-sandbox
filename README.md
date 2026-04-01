# Agent Sandbox

Dev Container template for running AI coding agents (Claude Code, Codex) with domain-level network restrictions.

Uses a **sidecar mitmproxy** container for domain filtering and **iptables** in the agent container to enforce proxy-only outbound access. See [docs/architecture.md](docs/architecture.md) for detailed design.

## Quick Start

### Prerequisites

- [VS Code](https://code.visualstudio.com/) with [Dev Containers extension](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers)
- [Docker](https://docs.docker.com/get-docker/)

### Setup

1. Use this template to create a new repository, or copy `.devcontainer/` and `.claude/` into an existing project

2. Open the project in VS Code and run **"Dev Containers: Reopen in Container"** from the command palette

3. First-time setup inside the container:
   ```bash
   claude login
   gh auth login
   ```

4. Switch Git remotes to HTTPS (SSH is blocked by iptables):
   ```bash
   git remote set-url origin https://github.com/your-org/your-repo.git
   ```

5. Run with full permissions:
   ```bash
   claude --dangerously-skip-permissions
   ```

## What's Included

| Component | Purpose |
|-----------|---------|
| **proxy container** | mitmproxy with domain allowlist (`enforcer.py` + `policy.yaml`) |
| **agent container** | node:20 with Claude Code, Codex CLI, DinD, zsh, git-delta |
| **init-firewall.sh** | UID-based iptables restricting `node` user to proxy only |
| **pre-tool-use.sh** | PreToolUse hook blocking firewall/proxy bypass commands |

## Customization

### Domain Allowlist

Edit `.devcontainer/proxy/policy.yaml`:

```yaml
domains:
  - "*.your-company.com"
  - custom-registry.example.com
```

Rebuild the container after changes.

### Branch Protection

Edit `.claude/hooks/pre-tool-use.sh`:

```bash
PROTECTED_BRANCHES="main|develop"
PUSH_PROTECTED_BRANCHES="main|develop|staging"
```

### VS Code Extensions

Edit the `extensions` array in `.devcontainer/devcontainer.json`.

### Without Docker-in-Docker

If you don't need `docker` / `docker compose` inside the container:

1. Remove the `features` section from `devcontainer.json`
2. In `docker-compose.yml`, replace `privileged: true` with:
   ```yaml
   cap_add:
     - NET_ADMIN
     - NET_RAW
   ```
3. In `devcontainer.json`, simplify `postStartCommand` to:
   ```
   "postStartCommand": "test -f /home/node/.gitconfig.host && (grep -q 'gitconfig.host' /home/node/.gitconfig 2>/dev/null || git config --global include.path .gitconfig.host) ; sudo /usr/local/bin/init-firewall.sh"
   ```

### Base Image

The agent uses `node:20` because Claude Code and Codex are Node.js tools. If changing:

- Update `remoteUser` in `devcontainer.json`
- Update `/home/node/` paths in `mounts` and `containerEnv`
- Update `id -u node` in `init-firewall.sh`

## Verification

After container startup:

```bash
# Allowed domain via proxy
sudo -u node env HTTP_PROXY=http://proxy:8080 HTTPS_PROXY=http://proxy:8080 \
  curl -s https://api.github.com/zen

# Blocked domain via proxy
sudo -u node env HTTP_PROXY=http://proxy:8080 HTTPS_PROXY=http://proxy:8080 \
  curl -s https://example.com
# → 403 Forbidden

# Direct access blocked by iptables
sudo -u node curl --noproxy '*' https://example.com
# → REJECT

# Root is unrestricted (for DinD)
sudo curl https://example.com
# → Success
```

## Security Model

This is a **best-effort** safety net. It prevents AI agents from making unintended outbound connections during normal operation. It does not protect against intentional bypass attacks.

See [docs/architecture.md](docs/architecture.md) for the full threat model and known limitations.

## References

- [mattolson/agent-sandbox](https://github.com/mattolson/agent-sandbox) - mitmproxy + iptables sidecar architecture
- [Docker Sandbox Network Policies](https://docs.docker.com/ai/sandboxes/network-policies/) - Docker's AI sandbox networking
- [Claude Code Dev Container](https://github.com/anthropics/claude-code/tree/main/.devcontainer) - Official IP-based reference

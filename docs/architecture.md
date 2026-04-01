# Architecture

## Overview

This sandbox uses a **sidecar proxy** architecture to restrict network access from AI coding agents (Claude Code, Codex) running inside a Dev Container.

### References

| Source | URL |
|--------|-----|
| mattolson/agent-sandbox | https://github.com/mattolson/agent-sandbox |
| Docker Sandbox Network Policies | https://docs.docker.com/ai/sandboxes/network-policies/ |
| Docker and iptables | https://docs.docker.com/engine/network/firewall-iptables/ |
| Claude Code Dev Container | https://github.com/anthropics/claude-code/tree/main/.devcontainer |

## Architecture Diagram

```
+---------------------------------------------------+
|  Docker Compose Network                           |
|                                                   |
|  +------------------------+  +------------------+ |
|  |  agent container       |  |  proxy container | |
|  |  (Dev Container)       |  |                  | |
|  |                        |  |  mitmproxy       | |
|  |  Claude Code / Codex   |->|  enforcer.py     | |
|  |  VS Code server        |  |  policy.yaml     | |
|  |                        |  |                  | |
|  |  [iptables]            |  |  cap_drop: ALL   | |
|  |  node: proxy only      |  +--------+---------+ |
|  |  root: unrestricted    |           |            |
|  |                        |           v            |
|  |  [DinD]                |      [Internet]        |
|  |  docker compose inside |                        |
|  +------------------------+                        |
+---------------------------------------------------+
```

## Two-Layer Defense

### Layer 1: Proxy Container (mitmproxy)

The proxy container runs `mitmdump` with a custom addon (`enforcer.py`) that filters HTTPS CONNECT requests by hostname.

- **Allowed domains**: CONNECT tunnel is established, TLS passes through without interception (no MITM, no CA needed)
- **Blocked domains**: 403 Forbidden response at CONNECT stage (before TLS handshake)
- **HTTP plaintext**: Host header is checked against the same allowlist

The `tls_clienthello` hook sets `ignore_connection = True` on all connections, ensuring no TLS interception occurs. This means no CA certificate distribution is required.

### Layer 2: Agent Container (iptables)

iptables rules restrict only the `node` user (UID-based matching with `-m owner --uid-owner`):

- `node` user: Can only reach `proxy:8080` via TCP. All other outbound TCP/UDP is REJECT'd
- `root` / `dockerd`: Unrestricted (required for DinD to pull images and run containers)
- DNS (UDP/TCP 53): Allowed for all users
- Docker bridge / host network: Allowed for all users
- IPv6: Loopback allowed, node user REJECT'd for everything else

### Why Sidecar?

| Concern | Single-container | Sidecar |
|---------|-----------------|---------|
| Kill proxy | `sudo kill` works | Separate container, unreachable |
| Modify policy | `sudo vi policy.yaml` works | Separate filesystem, unreachable |
| Disable iptables | `sudo iptables -F` works | Still works (iptables is in agent), but proxy remains functional |
| Hook patterns needed | Many (kill, nft, unset, etc.) | Minimal |

### Design Differences from mattolson/agent-sandbox

| Item | mattolson | This project |
|------|-----------|-------------|
| MITM | Yes (CA distribution) | No (CONNECT hostname filtering only) |
| DinD | No | Yes (docker-in-docker feature) |
| iptables | Global OUTPUT DROP | UID-based (node only REJECT) |
| SSH | Fully blocked | Fully blocked (HTTPS remotes required) |
| HTTP_PROXY | compose `environment` | `remoteEnv` (prevents dockerd inheritance) |

## Security Model

### Threat Model

**Protected against**: AI coding agents making unintended outbound connections during normal operation (e.g., running tests that call external APIs, installing unexpected packages)

**Not protected against**: Intentional bypass attacks (prompt injection causing deliberate circumvention)

### Known Limitations

| Risk | Reason |
|------|--------|
| DNS tunneling | DNS (UDP 53) must be allowed |
| Exfiltration via allowed domains | GitHub Gist uploads, npm publish, etc. |
| Container escape via `--privileged` | Required for DinD |
| DinD child container traffic | FORWARD chain is not restricted (Phase 1) |
| `sudo iptables -F` to clear rules | iptables is inside agent container; mitigated by PreToolUse Hook |
| `sudo bash -c "iptables -F"` | Indirect execution bypasses hook pattern matching |

## Customization Points

### Domain Allowlist

Edit `.devcontainer/proxy/policy.yaml` to add or remove allowed domains:

```yaml
domains:
  - "*.your-company.com"
  - custom-registry.example.com
```

Wildcard `*.example.com` matches `sub.example.com` but not `example.com` itself. Add both if needed.

### Branch Protection

Edit `.claude/hooks/pre-tool-use.sh` to change protected branches:

```bash
PROTECTED_BRANCHES="main|develop"
PUSH_PROTECTED_BRANCHES="main|develop|staging"
```

### Base Image

The agent Dockerfile uses `node:20` because Claude Code and Codex are Node.js-based tools. If changing the base image:

1. Update `remoteUser` in `devcontainer.json`
2. Update all `/home/node/` paths in `devcontainer.json` mounts and containerEnv
3. Update `id -u node` in `init-firewall.sh` to match the new username
4. Ensure `iptables` and `iproute2` are installed

#!/bin/bash
set -euo pipefail

# PreToolUse Hook: Block destructive and bypass operations
# Enforced even with --dangerously-skip-permissions

input=$(cat)

tool_name=$(echo "$input" | jq -r '.tool_name // empty')
command=$(echo "$input" | jq -r '.tool_input.command // empty')

if [ "$tool_name" != "Bash" ] || [ -z "$command" ]; then
  exit 0
fi

PROTECTED_BRANCHES="main"
PUSH_PROTECTED_BRANCHES="main"

block() {
  echo '{"decision": "block", "reason": "'"$1"'"}'
  exit 0
}

# --- git ---

if echo "$command" | grep -qE 'git\s+push\s+.*(\s|^)(-f|--force)(\s|$)'; then
  block "Force push is not allowed"
fi

if echo "$command" | grep -qE "git\s+push\s+\S+\s+(${PUSH_PROTECTED_BRANCHES})(\s|$)"; then
  block "Direct push to protected branches is not allowed. Create a PR instead"
fi

if echo "$command" | grep -qE "git\s+checkout\s+(${PROTECTED_BRANCHES})(\s|$)"; then
  block "Direct checkout of protected branches is not allowed"
fi

if echo "$command" | grep -qE "git\s+switch\s+(${PROTECTED_BRANCHES})(\s|$)"; then
  block "Direct switch to protected branches is not allowed"
fi

if echo "$command" | grep -qE 'git\s+branch\s+-(D|d)\s'; then
  block "Branch deletion is not allowed"
fi

if echo "$command" | grep -qE 'git\s+reset\s+--hard'; then
  block "git reset --hard is not allowed"
fi

# --- gh ---

if echo "$command" | grep -qE "gh\s+pr\s+create\s+.*--base\s+(${PROTECTED_BRANCHES})(\s|$)"; then
  block "Creating PRs targeting protected branches is not allowed"
fi

if echo "$command" | grep -qE "gh\s+pr\s+merge\s+.*--base\s+(${PROTECTED_BRANCHES})(\s|$)"; then
  block "Merging PRs targeting protected branches is not allowed"
fi

# --- firewall / proxy ---

if echo "$command" | grep -qE 'sudo\s+(iptables|ip6tables|ipset|ip\s+route|ip\s+rule|iptables-nft|nft)\b'; then
  block "Direct firewall manipulation is not allowed"
fi

if echo "$command" | grep -qEi '(unset|export)\s+.*(HTTP_PROXY|HTTPS_PROXY|http_proxy|https_proxy)'; then
  block "Modifying proxy environment variables is not allowed"
fi

if echo "$command" | grep -qEi 'env\s+(-u\s+(HTTP_PROXY|HTTPS_PROXY|http_proxy|https_proxy)|-i)\b'; then
  block "Proxy bypass is not allowed"
fi

if echo "$command" | grep -qE 'curl\s+.*--noproxy'; then
  block "Proxy bypass (--noproxy) is not allowed"
fi

# --- filesystem ---

if echo "$command" | grep -qE 'rm\s+(-rf|-fr)\s+/(\s|$)'; then
  block "rm -rf / is not allowed"
fi

exit 0

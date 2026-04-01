#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# =============================================================================
# Sidecar proxy firewall for Dev Container
#
# Restricts the node user to communicate only via the mitmproxy sidecar.
# root / dockerd are unrestricted so DinD (make up) continues to work.
#
# Reference: https://github.com/mattolson/agent-sandbox
# =============================================================================

# ---- 1. Force iptables-nft ----
# The DinD feature swaps to iptables-legacy, but Fedora kernels only support
# nf_tables. The Dockerfile creates /usr/local/sbin/iptables -> iptables-nft
# which takes PATH priority. Verify it here.
if ! iptables --version 2>/dev/null | grep -q nf_tables; then
    echo "WARNING: iptables is not using nf_tables backend"
    echo "Attempting update-alternatives fallback..."
    update-alternatives --set iptables /usr/sbin/iptables-nft 2>/dev/null || true
    update-alternatives --set ip6tables /usr/sbin/ip6tables-nft 2>/dev/null || true
fi

# ---- 2. Flush only INPUT/OUTPUT (preserve FORWARD/NAT/mangle for DinD) ----
iptables -F INPUT
iptables -F OUTPUT

# ---- 3. Detect proxy container IP ----
PROXY_IP=$(getent ahostsv4 proxy 2>/dev/null | awk 'NR==1 {print $1}')
if [ -z "$PROXY_IP" ]; then
    echo "ERROR: Cannot resolve 'proxy' service. Is the sidecar running?"
    exit 1
fi
echo "Proxy IP: $PROXY_IP"

# ---- 4. Detect node user UID ----
NODE_UID=$(id -u node)
echo "Node UID: $NODE_UID"

# ---- 5. Detect host/Docker bridge network ----
HOST_IP=$(ip route | grep default | head -1 | cut -d" " -f3)
if [ -z "$HOST_IP" ]; then
    echo "ERROR: Failed to detect host IP"
    exit 1
fi
HOST_NETWORK=$(ip route | grep -E "^[0-9].*dev" | grep -v default | head -1 | awk '{print $1}')
if [ -z "$HOST_NETWORK" ]; then
    HOST_NETWORK=$(echo "$HOST_IP" | sed "s/\.[0-9]*$/.0\/16/")
fi
echo "Host network: $HOST_NETWORK"

# ---- 6. IPv4 iptables rules (order matters) ----

# a. Loopback
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# b. Established/related (early for performance)
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# c. DNS (Docker DNS 127.0.0.11 is covered by loopback rule above)
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
iptables -A INPUT -p udp --sport 53 -j ACCEPT

# d. Host network / Docker bridge
iptables -A INPUT -s "$HOST_NETWORK" -j ACCEPT
iptables -A OUTPUT -d "$HOST_NETWORK" -j ACCEPT
iptables -A INPUT -s 172.16.0.0/12 -j ACCEPT
iptables -A OUTPUT -d 172.16.0.0/12 -j ACCEPT

# e. node user: allow proxy:8080 only
iptables -A OUTPUT -m owner --uid-owner "$NODE_UID" -d "$PROXY_IP" -p tcp --dport 8080 -j ACCEPT

# f. node user: REJECT everything else
iptables -A OUTPUT -m owner --uid-owner "$NODE_UID" -p tcp -j REJECT --reject-with icmp-admin-prohibited
iptables -A OUTPUT -m owner --uid-owner "$NODE_UID" -p udp -j REJECT --reject-with icmp-admin-prohibited

# g. OUTPUT policy stays ACCEPT (root/dockerd unrestricted)

# ---- 7. IPv6 ----
ip6tables -A INPUT -i lo -j ACCEPT 2>/dev/null || true
ip6tables -A OUTPUT -o lo -j ACCEPT 2>/dev/null || true
ip6tables -A OUTPUT -m owner --uid-owner "$NODE_UID" -j REJECT --reject-with icmp6-adm-prohibited 2>/dev/null || true

# ---- 8. Verification ----
echo ""
echo "Firewall configuration complete. Verifying..."

if sudo -u node env HTTP_PROXY="http://proxy:8080" HTTPS_PROXY="http://proxy:8080" \
    curl --connect-timeout 10 -s -o /dev/null -w "%{http_code}" https://api.github.com/zen | grep -q "200"; then
    echo "PASS: api.github.com reachable via proxy"
else
    echo "ERROR: Cannot reach api.github.com via proxy"
    exit 1
fi

if sudo -u node curl --connect-timeout 5 --noproxy '*' -s https://example.com >/dev/null 2>&1; then
    echo "ERROR: Direct outbound should be blocked for node user"
    exit 1
else
    echo "PASS: Direct outbound blocked for node user"
fi

echo ""
echo "Firewall setup complete"

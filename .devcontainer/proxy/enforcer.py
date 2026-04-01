"""
mitmproxy addon: Domain-based CONNECT filtering without MITM.

Checks CONNECT hostname against an allowlist (policy.yaml).
Blocked domains receive 403. Allowed domains pass through as
plain TLS tunnels (no certificate interception).
"""
import os
import yaml
from mitmproxy import http, tls, ctx

POLICY_PATH = os.environ.get("POLICY_PATH", "/opt/proxy/policy.yaml")


class Enforcer:
    def __init__(self):
        with open(POLICY_PATH) as f:
            policy = yaml.safe_load(f) or {}

        self.mode = policy.get("mode", "enforce")
        self.exact: set[str] = set()
        self.wildcards: list[str] = []

        for d in policy.get("domains", []):
            d = d.lower()
            if d.startswith("*."):
                self.wildcards.append(d[1:])  # ".github.com"
            else:
                self.exact.add(d)

        ctx.log.info(
            f"Enforcer loaded: {len(self.exact)} exact, "
            f"{len(self.wildcards)} wildcard rules, mode={self.mode}"
        )

    def _is_allowed(self, hostname: str) -> bool:
        hostname = hostname.lower()
        if hostname in self.exact:
            return True
        for suffix in self.wildcards:
            if hostname.endswith(suffix):
                return True
        return False

    def http_connect(self, flow: http.HTTPFlow):
        host = flow.request.pretty_host
        allowed = self._is_allowed(host)

        if allowed:
            ctx.log.info(f"ALLOW CONNECT {host}")
        else:
            ctx.log.warn(f"BLOCK CONNECT {host}")
            if self.mode == "enforce":
                flow.response = http.Response.make(
                    403,
                    f"Blocked by policy: {host}",
                    {"Content-Type": "text/plain"},
                )

    def tls_clienthello(self, data: tls.ClientHelloData):
        """Skip TLS interception for all connections (no MITM)."""
        data.ignore_connection = True

    def request(self, flow: http.HTTPFlow):
        """Filter HTTP plaintext requests by Host header."""
        host = flow.request.pretty_host
        if not self._is_allowed(host):
            ctx.log.warn(f"BLOCK HTTP {host}")
            if self.mode == "enforce":
                flow.response = http.Response.make(
                    403,
                    f"Blocked by policy: {host}",
                    {"Content-Type": "text/plain"},
                )
        else:
            ctx.log.info(f"ALLOW HTTP {host}")


addons = [Enforcer()]

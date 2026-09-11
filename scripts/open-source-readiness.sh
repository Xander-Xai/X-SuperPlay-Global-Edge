#!/usr/bin/env bash
# Clean-room public snapshot gate. It reports counts only; never prints a
# matching line or secret value.
# shellcheck shell=bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT_DIR

python3 - <<'PY'
import ipaddress
import os
import re
import sys
from pathlib import Path

root = Path(os.environ["ROOT_DIR"])
skip_dirs = {".git", "node_modules", "target", "dist", "build", "coverage", ".temp", ".workbuddy", "reports"}
skip_files = {"open-source-readiness.sh", "OPEN_SOURCE_AUDIT.md", "OPEN_SOURCE_READINESS.md"}
ipv4_re = re.compile(r"(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])")
escaped_ipv4_re = re.compile(
    r"(?<![\d.])(?:\d{1,3}(?:\\+\.|\[\.\]|%2e)){3}\d{1,3}(?![\d.])",
    re.I,
)
domain_re = re.compile(r"(?<![A-Za-z0-9.-])(?:[A-Za-z0-9-]+\.)+(?:com|net|org|io|cn|xyz|dev|cloud|app)(?![A-Za-z0-9.-])", re.I)
private_key_re = re.compile(r"BEGIN (?:OPENSSH |RSA |EC |PGP )?PRIVATE KEY", re.I)
secret_shape_re = re.compile(r"(?:^|[^A-Za-z0-9_])(?:AKIA[0-9A-Z]{16}|gh[pous]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[baprs]-[0-9A-Za-z-]{10,}|sk-[A-Za-z0-9]{20,}|AIza[A-Za-z0-9_-]{20,})(?:$|[^A-Za-z0-9_])")
credential_re = re.compile(r"(?:PrivateKey|PresharedKey|password|token|secret|api[_-]?key|auth)[ \t]*[:=][ \t]*(.*)$", re.I)
personal_path_re = re.compile(r"(?:[A-Za-z]:\\(?:Users|Documents|Projects)\\|/Users/|/home/[^/<\s]+|\\\\wsl\$)", re.I)
internal_re = re.compile(r"OPC-LINK|X-SuperPlay-OPC-Blueprint|WS-005|Personal Economic Stage|revenue truth|PD evidence|founder business decision", re.I)
private_doc_re = re.compile(r"(?:production-preflight|production-change-plan|p11-r3-phase0|pre-deployment-review|code-review-20260903|g1-v2-(?:gate-status|evidence-index)|OPC-LINK)", re.I)
allowed_domains = {
    "github.com", "ghcr.io", "registry.npmjs.org", "schema.tauri.app", "www.w3.org",
    "json-schema.org", "api.ipify.org", "example.com", "vpn.example.com",
    "www.cloudflare.com", "www.google.com", "www.gstatic.com", "cloud.tencent.com",
}

files = []
for path in root.rglob("*"):
    if not path.is_file() or path.name in skip_files:
        continue
    if any(part in skip_dirs for part in path.relative_to(root).parts):
        continue
    try:
        data = path.read_bytes()
    except OSError:
        continue
    if b"\x00" in data:
        continue
    files.append((path, data.decode("utf-8", errors="ignore")))

known_ip = 0
public_ip = 0
regex_escaped_public_ip = 0
private_key = 0
credential = 0
client_profile = 0
personal_path = 0
cloud_account = 0
internal = 0
private_ops = 0
real_domains = set()
doc_networks = [ipaddress.ip_network(x) for x in ("192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24")]


def ipv4_tokens(line):
    yield from ((raw, False) for raw in ipv4_re.findall(line))
    yield from ((raw, True) for raw in escaped_ipv4_re.findall(line))


def parse_ipv4(raw, escaped):
    if escaped:
        raw = re.sub(r"(?:\\+\.|\[\.\]|%2e)", ".", raw, flags=re.I)
    try:
        return ipaddress.ip_address(raw)
    except ValueError:
        return None


# In-memory fixtures guard against regressions where escaped dots bypass the
# repository-wide privacy gate. They never enter candidate-tree counts.
for fixture in ("203.0.113.10", r"203\.0\.113\.10", "203[.]0[.]113[.]10", "203%2e0%2e113%2e10"):
    if not any(parse_ipv4(raw, escaped) for raw, escaped in ipv4_tokens(fixture)):
        print(f"IPv4 detection fixture failed: {fixture!r}", file=sys.stderr)
        sys.exit(1)

for path, text in files:
    rel = path.relative_to(root).as_posix()
    if private_doc_re.search(rel):
        private_ops += 1
    if internal_re.search(text):
        internal += 1
    if path.suffix.lower() in {".conf", ".key", ".pem", ".p12", ".pfx"} and not path.name.endswith(".example"):
        client_profile += 1
    for line in text.splitlines():
        if private_key_re.search(line):
            private_key += 1
        credential_match = credential_re.search(line)
        credential_value = credential_match.group(1).strip() if credential_match else ""
        placeholder = (not credential_value or credential_value.startswith(("<", "REPLACE_WITH", "EXTERNAL", "PLACEHOLDER", "${")))
        if (secret_shape_re.search(line) or (credential_match and not placeholder)) and "github.token" not in line and "ACTIONS_GIT_TOKEN" not in line:
            credential += 1
        if personal_path_re.search(line):
            personal_path += 1
        account_match = re.search(r"(?:account|tenant|subscription|instance|security[_ -]?group|firewall[_ -]?rule)[ _-]?id[ \t]*[:=][ \t]*(.*)$", line, re.I)
        account_value = account_match.group(1).strip() if account_match else ""
        if account_match and account_value and not account_value.startswith(("<", "REPLACE", "EXTERNAL", "PLACEHOLDER", "${")):
            cloud_account += 1
        for raw, escaped in ipv4_tokens(line):
            ip = parse_ipv4(raw, escaped)
            if ip is None:
                continue
            if escaped and not (ip.is_private or ip.is_loopback or ip.is_unspecified or ip.is_link_local or any(ip in n for n in doc_networks)):
                regex_escaped_public_ip += 1
            if not (ip.is_private or ip.is_loopback or ip.is_unspecified or ip.is_link_local or any(ip in n for n in doc_networks)):
                public_ip += 1
        for domain in domain_re.findall(line):
            d = domain.lower().lstrip("-")
            if d not in allowed_domains:
                real_domains.add(d)

counts = {
    "REAL_PUBLIC_IP_COUNT": public_ip,
    "KNOWN_REAL_IP_COUNT": known_ip,
    "REGEX_ESCAPED_REAL_IP_COUNT": regex_escaped_public_ip,
    "REAL_DOMAIN_COUNT": len(real_domains),
    "PRIVATE_KEY_COUNT": private_key,
    "PRODUCTION_CREDENTIAL_COUNT": credential,
    "REAL_CLIENT_PROFILE_COUNT": client_profile,
    "PERSONAL_LOCAL_PATH_COUNT": personal_path,
    "CLOUD_ACCOUNT_ID_COUNT": cloud_account,
    "PRIVATE_OPS_DOCUMENT_COUNT": private_ops,
    "OPC_INTERNAL_METADATA_COUNT": internal,
}
for key, value in counts.items():
    print(f"{key}={value}")
print("OSS_LICENSE_PRESENT=" + ("PASS" if (root / "LICENSE").is_file() else "FAIL"))
print("THIRD_PARTY_PROVENANCE=" + ("PASS" if (root / "docs/client/reference/provenance.md").is_file() else "NEEDS_REVIEW"))
failed = any(counts.values()) or not (root / "LICENSE").is_file() or not (root / "docs/client/reference/provenance.md").is_file()
print("SECRET_SCAN=" + ("PASS" if not (private_key or credential) else "FAIL"))
print("INFRA_PRIVACY_SCAN=" + ("PASS" if not (public_ip or known_ip or len(real_domains) or personal_path or cloud_account or private_ops or internal) else "FAIL"))
print("OPEN_SOURCE_READY=" + ("TRUE" if not failed else "FALSE"))
sys.exit(0 if not failed else 1)
PY

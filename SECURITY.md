# Security policy

## Supported versions

The current `0.1.x` release line is supported for security reports. The
project is an open-source reference stack, not a managed production service.

## Reporting a vulnerability

Use GitHub's private security reporting mechanisms when available. If private
reporting is unavailable, contact the repository owner through a private
GitHub channel before opening any public issue. Do not publish exploitable
details, credentials, or complete client configurations in a public issue.

Please include the affected version or commit, a minimal reproduction, and
the impact. Redact all infrastructure identifiers from the report.

## Do not disclose publicly

Never include real production IPs/domains, VPN peer files, private keys,
tokens, provider account identifiers, raw runtime evidence, or personal
machine paths in Issues, Discussions, pull requests, or logs.

## Credential exposure response

If a credential or private key may have been exposed, stop using it, rotate or
revoke it in the owning private system, preserve only sanitized diagnostics,
and report the incident privately. Do not add the secret to a follow-up commit
or rely on deleting it from the working tree.

## Infrastructure privacy

Public examples must remain provider-neutral and use documentation addresses,
synthetic credentials, and placeholder hostnames. Production topology,
operator records, and evidence belong outside this repository.

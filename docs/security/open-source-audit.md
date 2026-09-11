# Public security audit record

This document describes the permanent public-tree privacy boundary. It is not
a record of private infrastructure or production operations.

The public tree is checked for:

- private keys, credential-shaped values, and client profile files;
- real or encoded public IP addresses and non-placeholder domains;
- personal machine paths and cloud account identifiers;
- internal business metadata and raw production evidence.

The audit remediation rule is simple: keep reusable contracts and examples,
remove populated operational material, and use documentation addresses,
synthetic credentials, and placeholders in fixtures. The CI gates in
`scripts/secret-scan.sh` and `scripts/open-source-readiness.sh` enforce this
boundary continuously.

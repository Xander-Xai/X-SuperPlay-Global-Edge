# Edge host selection guide

This guide is a generic procurement checklist. Live prices, account details,
instance identifiers, and provider-to-node mappings belong in a private
operations record and must be rechecked immediately before purchase.

Evaluate candidate hosts on:

- supported Linux kernel and Docker Compose;
- root/sudo and key-only SSH access with a recovery console;
- IPv4/IPv6 controls, WireGuard/TUN capability, and firewall support;
- CPU, memory, disk, bandwidth, transfer quota, and overage rules;
- region and route suitability measured with controlled tests;
- backup, rebuild, billing, refund, and account-ownership controls.

Record only non-secret decisions in a private asset ledger. The public
repository should contain the deployment contract and synthetic examples, not
a current provider choice or production cost baseline.

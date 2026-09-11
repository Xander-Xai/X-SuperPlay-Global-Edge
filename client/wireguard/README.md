# WireGuard admin/private canary

This directory contains a split-tunnel schema only. It does not replace the
existing full-tunnel wg-easy profile. Render a private copy after the Reality
and Hysteria canary has passed, and fill in the actual SSH/admin routes from
the private operations inventory.

`PersistentKeepalive` is intentionally commented out: enable it only when a
measured NAT/firewall state-expiry hypothesis requires it. It is not a generic
packet-loss fix.

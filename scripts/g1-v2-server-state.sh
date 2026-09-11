#!/usr/bin/env bash
# Read-only Linux/VPS evidence collector for G1 v2.
# Usage: bash scripts/g1-v2-server-state.sh [output.json] [label]
# Secrets and raw client material are intentionally not collected.
# shellcheck shell=bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT=''; test "$#" -ge 1 && OUT="$1"
test -n "$OUT" || OUT="$ROOT_DIR/.temp/g1-v2-server-state-$(date -u +%Y%m%dT%H%M%SZ).json"
LABEL=T0; test "$#" -ge 2 && LABEL="$2"
mkdir -p "$(dirname "$OUT")"
python3 - "$OUT" "$LABEL" <<'PY'
import datetime as dt, json, shutil, subprocess, sys
out, label = sys.argv[1:]
def run(*args):
    try:
        p = subprocess.run(args, text=True, capture_output=True, check=False, timeout=20)
        value = (p.stdout or "").strip()
        if p.stderr.strip(): value += ("\n" if value else "") + "[stderr] " + p.stderr.strip()
        return {"rc": p.returncode, "output": value}
    except Exception as exc: return {"rc": 127, "output": str(exc)}
def proc(path):
    try:
        with open(path, encoding="utf-8") as fh: return fh.read().strip()
    except OSError as exc: return "[unavailable] " + str(exc)
commands = {
 "uname": ("uname","-a"), "os_release": ("cat","/etc/os-release"),
 "ip_addr": ("ip","addr"), "ip_route": ("ip","route"), "ip_rule": ("ip","rule"),
 "listeners": ("ss","-lntup"), "wireguard": ("wg","show"), "link_counters": ("ip","-s","link"),
 "udp_counters": ("netstat","-su"), "nstat": ("nstat","-az"), "conntrack_stats": ("conntrack","-S"),
 "docker": ("docker","ps","--no-trunc"),
 "systemd_running": ("systemctl","list-units","--type=service","--state=running","--no-pager"),
 "firewall_nft": ("nft","list","ruleset"), "firewall_iptables": ("iptables","-S"),
 "dmesg_network": ("dmesg","--color=never")}
available = {n: run(*c) for n,c in commands.items() if shutil.which(c[0])}
data = {"schema":"g1-v2-server-state.v1",
 "timestamp_utc":dt.datetime.now(dt.timezone.utc).isoformat(), "label":label,
 "host":{"hostname":run("hostname").get("output","")}, "commands":available,
 "proc":{"nf_conntrack_count":proc("/proc/sys/net/netfilter/nf_conntrack_count"),
 "nf_conntrack_max":proc("/proc/sys/net/netfilter/nf_conntrack_max"),
 "softnet_stat":proc("/proc/net/softnet_stat"), "snmp":proc("/proc/net/snmp"),
 "netstat":proc("/proc/net/netstat"), "uptime":proc("/proc/uptime")},
 "port_ownership":{"tcp_443":"inspect commands.listeners; unresolved until reviewed",
 "udp_443":"inspect commands.listeners; unresolved until reviewed",
 "udp_51820":"inspect commands.listeners; expected current WireGuard/wg-easy"}}
raw=data["commands"].get("dmesg_network",{}).get("output","")
data["commands"].get("dmesg_network",{})["output"]="\n".join(
 line for line in raw.splitlines() if any(x in line.lower() for x in
 ("drop","udp","tcp","conntrack","net","mtu","buffer")))
with open(out,"w",encoding="utf-8") as fh: json.dump(data,fh,ensure_ascii=False,indent=2); fh.write("\n")
print("OUTPUT="+out); print("PORT_OWNERSHIP=UNRESOLVED")
print("SERVER_BASELINE=COLLECTED" if available else "SERVER_BASELINE=BLOCKED_NO_LINUX_TOOLS")
PY

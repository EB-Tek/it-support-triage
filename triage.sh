#!/usr/bin/env bash
# triage.sh — collect a ticket-ready diagnostic snapshot of a workstation.
#
# Written for Tier 1 / Tier 2 help desk work: instead of asking a user to read
# out their IP, check their DNS, and describe their disk space over the phone,
# run this once and paste the Markdown into the ticket.
#
# Read-only. Changes nothing on the machine. No network calls except the
# connectivity tests, which can be skipped with --offline.
#
# Usage:
#   ./triage.sh                 print the report
#   ./triage.sh -o report.md    write it to a file
#   ./triage.sh --offline       skip connectivity tests
#
# MIT licensed.

set -uo pipefail

OUT=""
OFFLINE=0
while [ $# -gt 0 ]; do
  case "$1" in
    -o|--out) OUT="${2:-}"; shift 2 ;;
    --offline) OFFLINE=1; shift ;;
    -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

OS="$(uname -s)"
DISK_WARN=85          # percent used before a disk is flagged
PING_COUNT=4

have() { command -v "$1" >/dev/null 2>&1; }
# Some values are simply unavailable on a given platform; say so rather than
# printing an empty field that looks like a failed lookup.
na() { printf '_not available_'; }

# ------------------------------------------------------------------ system
sys_report() {
  echo "## System"
  echo
  echo "| Field | Value |"
  echo "|---|---|"
  echo "| Hostname | $(hostname) |"
  echo "| User | ${USER:-$(id -un)} |"
  if [ "$OS" = "Darwin" ]; then
    echo "| OS | macOS $(sw_vers -productVersion 2>/dev/null) (build $(sw_vers -buildVersion 2>/dev/null)) |"
    echo "| Model | $(sysctl -n hw.model 2>/dev/null || na) |"
    local serial
    serial=$(ioreg -l 2>/dev/null | awk -F'"' '/IOPlatformSerialNumber/{print $4; exit}')
    echo "| Serial | ${serial:-$(na)} |"
  else
    if [ -r /etc/os-release ]; then . /etc/os-release; echo "| OS | ${PRETTY_NAME:-Linux} |"; else echo "| OS | $(uname -sr) |"; fi
    echo "| Model | $(cat /sys/class/dmi/id/product_name 2>/dev/null || na) |"
    echo "| Serial | $(cat /sys/class/dmi/id/product_serial 2>/dev/null || na) |"
  fi
  echo "| Kernel | $(uname -r) |"
  echo "| Uptime | $(uptime | sed 's/.*up \([^,]*\),.*/\1/' | xargs) |"
  echo
}

# ---------------------------------------------------------------- hardware
hw_report() {
  echo "## Hardware & Capacity"
  echo
  if [ "$OS" = "Darwin" ]; then
    local mem_b; mem_b=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
    echo "- **CPU:** $(sysctl -n machdep.cpu.brand_string 2>/dev/null || na) ($(sysctl -n hw.ncpu 2>/dev/null) cores)"
    echo "- **RAM:** $(( mem_b / 1073741824 )) GB total"
  else
    echo "- **CPU:** $(awk -F: '/model name/{print $2; exit}' /proc/cpuinfo 2>/dev/null | xargs || na)"
    echo "- **RAM:** $(awk '/MemTotal/{printf "%.1f GB total", $2/1048576}' /proc/meminfo 2>/dev/null || na), \
$(awk '/MemAvailable/{printf "%.1f GB available", $2/1048576}' /proc/meminfo 2>/dev/null)"
  fi
  echo
  echo "**Disks**"
  echo
  echo "| Mount | Size | Used | Free | Use% | Status |"
  echo "|---|---|---|---|---|---|"
  df -h 2>/dev/null | awk -v w="$DISK_WARN" 'NR>1 && $1 ~ /^\/dev\// {
      mnt=$NF;
      # skip macOS firmware/system volumes and mounted simulator images: they are
      # not disks a user can free space on, and they raise meaningless alarms
      if (mnt ~ /^\/System\/Volumes\/(VM|Preboot|Update|xarts|iSCPreboot|Hardware)/) next;
      if (mnt ~ /CoreSimulator/) next;
      pct=$5; gsub(/%/,"",pct);
      status = (pct+0 >= w) ? "LOW SPACE" : "ok";
      label = (mnt == "/System/Volumes/Data") ? "/ (data)" : mnt;
      printf "| %s | %s | %s | %s | %s%% | %s |\n", label, $2, $3, $4, pct, status
    }'
  echo
}

# ----------------------------------------------------------------- network
net_report() {
  echo "## Network"
  echo
  local iface ip gw
  if [ "$OS" = "Darwin" ]; then
    iface=$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')
    gw=$(route -n get default 2>/dev/null | awk '/gateway:/{print $2; exit}')
    ip=$(ipconfig getifaddr "${iface:-en0}" 2>/dev/null)
  else
    iface=$(ip route 2>/dev/null | awk '/^default/{print $5; exit}')
    gw=$(ip route 2>/dev/null | awk '/^default/{print $3; exit}')
    ip=$(ip -4 addr show "${iface:-eth0}" 2>/dev/null | awk '/inet /{sub(/\/.*/,"",$2); print $2; exit}')
  fi
  echo "| Field | Value |"
  echo "|---|---|"
  echo "| Active interface | ${iface:-unknown} |"
  echo "| IPv4 address | ${ip:-none} |"
  echo "| Default gateway | ${gw:-none} |"

  local dns=""
  if [ "$OS" = "Darwin" ]; then
    dns=$(scutil --dns 2>/dev/null | awk '/nameserver\[[0-9]+\]/{print $3}' | sort -u | paste -sd, - | sed 's/,/, /g')
  else
    dns=$(awk '/^nameserver/{print $2}' /etc/resolv.conf 2>/dev/null | paste -sd, - | sed 's/,/, /g')
  fi
  echo "| DNS servers | ${dns:-none found} |"
  echo

  if [ "$OFFLINE" -eq 1 ]; then
    echo "_Connectivity tests skipped (--offline)._"
    echo
    return
  fi

  echo "**Connectivity**"
  echo
  echo "| Test | Result |"
  echo "|---|---|"
  # Gateway reachability isolates "local network problem" from "internet problem"
  if [ -n "${gw:-}" ]; then
    if ping -c "$PING_COUNT" -W 2000 "$gw" >/dev/null 2>&1 || ping -c "$PING_COUNT" -w 3 "$gw" >/dev/null 2>&1; then
      echo "| Gateway reachable | PASS ($gw) |"
    else
      echo "| Gateway reachable | **FAIL** ($gw) — local network issue |"
    fi
  else
    echo "| Gateway reachable | no default route |"
  fi

  # DNS resolution separates name-resolution faults from raw connectivity
  if have nslookup && nslookup github.com >/dev/null 2>&1; then
    echo "| DNS resolution | PASS |"
  elif have host && host github.com >/dev/null 2>&1; then
    echo "| DNS resolution | PASS |"
  else
    echo "| DNS resolution | **FAIL** — DNS not resolving |"
  fi

  local rtt
  rtt=$(ping -c "$PING_COUNT" 1.1.1.1 2>/dev/null | awk -F'/' '/round-trip|rtt/{printf "%.0f ms avg", $5}')
  if [ -n "$rtt" ]; then
    echo "| Internet (1.1.1.1) | PASS — $rtt |"
  else
    echo "| Internet (1.1.1.1) | **FAIL** — no route to internet |"
  fi
  echo
}

# ---------------------------------------------------------------- vpn/print
services_report() {
  echo "## VPN & Printing"
  echo
  local vpn=""
  if [ "$OS" = "Darwin" ]; then
    vpn=$(ifconfig 2>/dev/null | awk '/^(utun|ppp|ipsec)[0-9]*:/{print $1}' | tr -d ':' | paste -sd, - | sed 's/,/, /g')
  else
    vpn=$(ip -o link show 2>/dev/null | awk -F': ' '$2 ~ /^(tun|tap|ppp|wg)/{print $2}' | paste -sd, - | sed 's/,/, /g')
  fi
  # utun interfaces exist on macOS even with no VPN, so report, don't conclude
  echo "- **Tunnel interfaces present:** ${vpn:-none}"

  if have lpstat; then
    local printers
    printers=$(lpstat -p 2>/dev/null | awk '/^printer/{print "  - " $2 " (" $3 ")"}')
    if [ -n "$printers" ]; then
      echo "- **Printers:**"
      echo "$printers"
      local jobs; jobs=$(lpstat -o 2>/dev/null | wc -l | xargs)
      echo "- **Jobs queued:** ${jobs:-0}"
    else
      echo "- **Printers:** none configured"
    fi
  else
    echo "- **Printers:** lpstat unavailable"
  fi
  echo
}

# ------------------------------------------------------------------- load
load_report() {
  echo "## Top Resource Consumers"
  echo
  echo '```'
  ps aux 2>/dev/null | sort -nrk 3 | head -6 | awk '{printf "%-9s %5s%% CPU %5s%% MEM  %s\n", $1, $3, $4, $11}'
  echo '```'
  echo
}

# ------------------------------------------------------------------ errors
errors_report() {
  echo "## Recent System Errors"
  echo
  local out=""
  if [ "$OS" = "Darwin" ]; then
    out=$(log show --last 1h --style compact 2>/dev/null | grep -iE '\b(error|fault)\b' | tail -8)
  elif have journalctl; then
    out=$(journalctl -p err -n 8 --no-pager 2>/dev/null)
  fi
  if [ -n "$out" ]; then
    echo '```'
    echo "$out" | cut -c1-160
    echo '```'
  else
    echo "_No recent errors found (or log access requires elevated permissions)._"
  fi
  echo
}

# ------------------------------------------------------------------ render
render() {
  echo "# Support Triage Report"
  echo
  echo "**Generated:** $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo
  sys_report
  hw_report
  net_report
  services_report
  load_report
  errors_report
  echo "---"
  echo "_Generated by [it-support-triage](https://github.com/) — read-only diagnostic collector._"
}

if [ -n "$OUT" ]; then
  render > "$OUT"
  echo "Report written to $OUT"
else
  render
fi

#!/usr/bin/env bash
set -euo pipefail

REPO="Zuvpn/PQP"
BRANCH="main"
BIN_PATH="/usr/local/sbin/pqp"
ETC_DIR="/etc/pqp"

[[ ${EUID:-0} -ne 0 ]] && echo "Run as root: sudo bash install.sh" && exit 1

mkdir -p "$ETC_DIR"

if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y curl ca-certificates socat iproute2 iptables tar gzip cron
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y curl ca-certificates socat iproute iptables tar gzip cronie
elif command -v yum >/dev/null 2>&1; then
  yum install -y curl ca-certificates socat iproute iptables tar gzip cronie
fi

curl -fsSL "https://raw.githubusercontent.com/${REPO}/${BRANCH}/pqp.sh" -o "$BIN_PATH"
chmod +x "$BIN_PATH"

echo "Installed. Run: sudo pqp"

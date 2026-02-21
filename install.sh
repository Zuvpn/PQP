#!/usr/bin/env bash
set -euo pipefail

# PQP one-liner installer (robust)
# - Validates download isn't HTML/error page
# - Fixes CRLF line endings
# - Ensures executable + in PATH

REPO_DEFAULT="Zuvpn/PQP"
BRANCH_DEFAULT="main"
BIN_PATH="/usr/local/sbin/pqp"
ETC_DIR="/etc/pqp"

REPO="${REPO:-$REPO_DEFAULT}"
BRANCH="${BRANCH:-$BRANCH_DEFAULT}"

die(){ echo "ERROR: $*" >&2; exit 1; }
need_root(){ [[ ${EUID:-0} -eq 0 ]] || die "Run as root: sudo bash install.sh"; }

install_deps(){
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y curl ca-certificates socat iproute2 iptables tar gzip cron
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl ca-certificates socat iproute iptables tar gzip cronie
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl ca-certificates socat iproute iptables tar gzip cronie
  else
    die "No supported package manager (apt/dnf/yum). Install curl + socat manually."
  fi
}

fetch_raw(){
  local url="$1" out="$2"
  curl -fL --retry 3 --retry-delay 1 --connect-timeout 10 --max-time 60 \
    -H 'Cache-Control: no-cache' \
    "$url" -o "$out"
}

is_valid_pqp(){
  local f="$1"
  [[ -s "$f" ]] || return 1
  [[ "$(wc -c <"$f")" -ge 2000 ]] || return 1
  local first
  first="$(head -n1 "$f" | tr -d '\r')"
  [[ "$first" == "#!/usr/bin/env bash" ]] || return 1
  if head -n5 "$f" | grep -qiE '<!doctype|<html|<head|cloudflare|access denied'; then
    return 1
  fi
  grep -q "PQP - Paqet Quick Panel" "$f" || return 1
  return 0
}

main(){
  need_root
  mkdir -p "$ETC_DIR"
  echo "[*] Installing dependencies..."
  install_deps

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  url1="https://raw.githubusercontent.com/${REPO}/${BRANCH}/pqp.sh"
  url2="https://raw.fastgit.org/${REPO}/${BRANCH}/pqp.sh"

  echo "[*] Downloading pqp script..."
  if ! fetch_raw "$url1" "$tmp/pqp"; then
    echo "[!] Primary download failed, trying fallback mirror..."
    fetch_raw "$url2" "$tmp/pqp" || die "Download failed from both sources."
  fi

  sed -i 's/\r$//' "$tmp/pqp" || true

  if ! is_valid_pqp "$tmp/pqp"; then
    echo "[!] Downloaded file seems invalid (HTML/blocked/corrupt)."
    echo "    URL tried: $url1"
    echo "    First 5 lines:"
    head -n 5 "$tmp/pqp" || true
    die "Refusing to install invalid pqp file."
  fi

  install -m 0755 "$tmp/pqp" "$BIN_PATH"
  echo "[+] Installed: $BIN_PATH"
  echo "Run: sudo pqp"
}

main "$@"

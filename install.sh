#!/usr/bin/env bash
set -euo pipefail

REPO_OWNER="Zuvpn"
REPO_NAME="PQP"
BRANCH="main"

PQP_BIN="/usr/local/sbin/pqp"
ENV_DIR="/etc/pqp"

# -------- helpers --------
log(){ echo -e "[*] $*"; }
ok(){ echo -e "[+] $*"; }
warn(){ echo -e "[!] $*" >&2; }
die(){ echo -e "[ERROR] $*" >&2; exit 1; }

have(){ command -v "$1" >/dev/null 2>&1; }

wait_apt(){
  # Wait until apt/dpkg locks are free (prevents 'Could not get lock')
  local timeout="${1:-600}" # seconds
  local start now
  start="$(date +%s)"
  while true; do
    if sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
       sudo fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || \
       sudo fuser /var/cache/apt/archives/lock >/dev/null 2>&1; then
      now="$(date +%s)"
      if (( now - start > timeout )); then
        warn "APT is busy for > ${timeout}s. Showing holder processes:"
        ps -eo pid,etime,cmd | egrep 'apt|dpkg' | head -n 25 || true
        die "APT lock timeout"
      fi
      log "APT is busy... waiting"
      sleep 5
    else
      break
    fi
  done
}

install_deps(){
  log "Installing dependencies..."
  wait_apt 900
  sudo apt-get update -y
  wait_apt 900
  sudo apt-get install -y curl ca-certificates socat iproute2 iptables tar gzip cron
}

download_pqp(){
  log "Downloading pqp script..."
  local url="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${BRANCH}/pqp.sh"
  sudo curl -fL --retry 3 --retry-delay 1 --connect-timeout 10 --max-time 60 \
    -o "${PQP_BIN}" "$url" || die "Failed to download pqp.sh from GitHub (check repo file)"
  sudo chmod +x "${PQP_BIN}"
  ok "Installed: ${PQP_BIN}"
}

self_check(){
  # Make sure we didn't download a partial file
  local need=("ask_yesno" "normalize_ports" "parse_list" "save_env_kv" "wizard_create_tunnel")
  local f
  for f in "${need[@]}"; do
    if ! grep -q "${f}()" "${PQP_BIN}"; then
      warn "pqp.sh seems incomplete: missing function ${f}()"
      warn "You likely have an older/partial pqp.sh in GitHub."
      die "Installer aborted (pqp incomplete). Please update pqp.sh in your repo to the stable version."
    fi
  done
}

post_msg(){
  echo
  ok "Done."
  echo "Run: sudo pqp"
  echo "Tip: If you see 'Could not get lock' wait until apt finishes, then re-run install.sh"
}

main(){
  [[ "$(id -u)" -eq 0 ]] || die "Run as root (or use sudo bash install.sh)"
  install_deps
  download_pqp
  self_check
  mkdir -p "${ENV_DIR}" || true
  post_msg
}

main "$@"

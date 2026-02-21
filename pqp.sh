#!/usr/bin/env bash
set -euo pipefail

# =======================
# PQP - Paqet Quick Panel
# - Wizard-based tunnel creation (interactive)
# - Smart Auto MTU: multi-run + median + fallback
# - MTU_CAP: keep AUTO_MTU enabled but cap max MTU
# - Adaptive MTU: sets MTU_CAP (doesn't disable auto)
# =======================

ENV_FILE="/etc/pqp/pqp.env"
PAQET_BIN="/usr/local/bin/paqet"
WORKDIR="/opt/paqet"
CFG_DIR="/etc/paqet"
SERVICE_TEMPLATE="/etc/systemd/system/paqet@.service"
FWD_TEMPLATE="/etc/systemd/system/pqp-forward@.service"
CRON_FILE="/etc/cron.d/pqp"

die(){ echo "ERROR: $*" >&2; exit 1; }
need_root(){ [[ ${EUID:-0} -eq 0 ]] || die "Run as root: sudo pqp"; }
have(){ command -v "$1" >/dev/null 2>&1; }
parse_list(){ echo "${1//,/ }"; }

is_tty(){ [[ -t 0 && -t 1 ]]; }
cls(){ is_tty && command -v clear >/dev/null 2>&1 && clear || true; }
pause(){ is_tty && read -r -p "Enter to continue..." _ || true; }

ask(){
  local prompt="$1" def="${2:-}"
  local ans=""
  if ! is_tty; then
    echo "$def"
    return 0
  fi
  if [[ -n "$def" ]]; then
    read -r -p "${prompt} [${def}]: " ans || true
    echo "${ans:-$def}"
  else
    read -r -p "${prompt}: " ans || true
    echo "$ans"
  fi
}


is_ipv4() {
  local ip="${1:-}"
  [[ -n "$ip" ]] || return 1
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local o1 o2 o3 o4
  IFS='.' read -r o1 o2 o3 o4 <<< "$ip"
  for o in "$o1" "$o2" "$o3" "$o4"; do
    [[ "$o" =~ ^[0-9]+$ ]] || return 1
    (( o >= 0 && o <= 255 )) || return 1
  done
  return 0
}

default_env(){
  mkdir -p "$(dirname "$ENV_FILE")"
  cat >"$ENV_FILE" <<'EOF'
PROFILE=balanced            # low-traffic | balanced | max-speed
ROLE=client                 # client|server
KEY=CHANGE_ME

SERVER_IP=1.2.3.4
SERVER_PORT=9999
SOCKS_PORT=1080
FORWARDS="443:1.2.3.4:4000,8443:1.2.3.4:4001"

LISTEN_PORT=9999
IRAN_IP=
IR_LISTEN_PORTS=
FWD_DEST_HOST=
FWD_DEST_PORT=

LISTEN_PORT=9999

AUTO_MTU=1
MTU=1350
MTU_TARGET=
MTU_MARGIN=90

MTU_VERIFY=5
MTU_TIMEOUT=1
MTU_MIN_PAYLOAD=1200
MTU_MAX_PAYLOAD=1472
MTU_FALLBACK_MODE=auto

MTU_RUNS=3
MTU_MEDIAN=1
MTU_CAP=0

ADAPTIVE_MTU=1
ADAPT_STEP=12
ADAPT_MIN_MTU=1200

KCP_MODE=fast
KCP_CONN=1
KCP_RCVWND=512
KCP_SNDWND=512

LOG_LEVEL=info
EOF
  chmod 600 "$ENV_FILE"
}

load_env(){
  [[ -f "$ENV_FILE" ]] || default_env
  # shellcheck disable=SC1090
  source "$ENV_FILE"

  # ---- Safe defaults (crash-proof under 'set -u') ----
  : "${ROLE:=client}"
  : "${PROFILE:=balanced}"
  : "${KEY:=CHANGE_ME}"

  : "${SERVER_IP:=}"
  : "${SERVER_PORT:=9999}"
  : "${SOCKS_PORT:=1080}"
  : "${FORWARDS:=}"

  : "${IRAN_IP:=}"
  : "${IR_LISTEN_PORTS:=}"
  : "${FWD_DEST_HOST:=}"
  : "${FWD_DEST_PORT:=}"
  : "${LISTEN_PORT:=9999}"

  : "${AUTO_MTU:=1}"
  : "${MTU:=1350}"
  : "${MTU_TARGET:=}"
  : "${MTU_MARGIN:=90}"
  : "${MTU_VERIFY:=5}"
  : "${MTU_TIMEOUT:=1}"
  : "${MTU_MIN_PAYLOAD:=1200}"
  : "${MTU_MAX_PAYLOAD:=1472}"
  : "${MTU_FALLBACK_MODE:=auto}"
  : "${MTU_RUNS:=3}"
  : "${MTU_MEDIAN:=1}"
  : "${MTU_CAP:=0}"

  : "${ADAPTIVE_MTU:=1}"
  : "${ADAPT_STEP:=12}"
  : "${ADAPT_MIN_MTU:=1200}"

  : "${KCP_MODE:=fast}"
  : "${KCP_CONN:=1}"
  : "${KCP_RCVWND:=512}"
  : "${KCP_SNDWND:=512}"
  : "${LOG_LEVEL:=info}"
}

save_env_kv(){
  local key="$1" val="$2"
  if grep -qE "^${key}=" "$ENV_FILE" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$ENV_FILE"
  else
    echo "${key}=${val}" >>"$ENV_FILE"
  fi
}

apply_profile(){
  load_env
  case "$PROFILE" in
    low-traffic)
      save_env_kv "KCP_MODE" "normal"
      save_env_kv "KCP_CONN" "1"
      save_env_kv "KCP_RCVWND" "384"
      save_env_kv "KCP_SNDWND" "384"
      save_env_kv "MTU_MARGIN" "100"
      save_env_kv "MTU_VERIFY" "5"
      ;;
    balanced)
      save_env_kv "KCP_MODE" "fast"
      save_env_kv "KCP_CONN" "1"
      save_env_kv "KCP_RCVWND" "512"
      save_env_kv "KCP_SNDWND" "512"
      save_env_kv "MTU_MARGIN" "90"
      save_env_kv "MTU_VERIFY" "5"
      ;;
    max-speed)
      save_env_kv "KCP_MODE" "fast2"
      save_env_kv "KCP_CONN" "2"
      save_env_kv "KCP_RCVWND" "1024"
      save_env_kv "KCP_SNDWND" "1024"
      save_env_kv "MTU_MARGIN" "80"
      save_env_kv "MTU_VERIFY" "3"
      ;;
    *) die "Unknown PROFILE=$PROFILE (use low-traffic|balanced|max-speed)" ;;
  esac
  echo "[+] Applied profile: $PROFILE"
}

wizard_create_tunnel(){
  need_root
  load_env
  echo "=== PQP Wizard: Create/Update Tunnel ==="
  echo
  echo "Select server location:"
  echo "  1) Iran (Client)"
  echo "  2) Kharej (Server)"
  local sel
  while true; do
    sel="$(ask "Choose [1-2]" "")"
    case "$sel" in
      1) ROLE="client"; break ;;
      2) ROLE="server"; break ;;
      *) echo "Please enter 1 or 2." ;;
    esac
  done
  save_env_kv "ROLE" "$ROLE"
  is_tty || die "Wizard needs a TTY. Use /etc/pqp/pqp.env for non-interactive."

  cls
  echo "=== PQP Wizard: Create/Update Tunnel ==="
  echo

  local role key profile
  role="$(ask "Role (client/server)" "${ROLE}")"
  [[ "$role" == "client" || "$role" == "server" ]] || die "Role must be client or server"
  key="$(ask "KEY (shared secret)" "${KEY}")"
  profile="$(ask "PROFILE (low-traffic/balanced/max-speed)" "${PROFILE}")"

  save_env_kv "ROLE" "$role"
  save_env_kv "KEY" "$key"
  save_env_kv "PROFILE" "$profile"

  if [[ "$role" == "server" ]]; then
    local lp
    lp="$(ask "LISTEN_PORT (comma-separated)" "${LISTEN_PORT:-9999}")"
    save_env_kv "LISTEN_PORT" "$lp"
  else
    local sip sp socks fw
    sip="$(ask "SERVER_IP (kharej)" "${SERVER_IP}")"
    sp="$(ask "SERVER_PORT (comma-separated)" "${SERVER_PORT:-9999}")"
    socks="$(ask "SOCKS_PORT (local)" "${SOCKS_PORT:-1080}")"
    fw="$(ask 'FORWARDS (optional) ex: 443:127.0.0.1:4000,8443:127.0.0.1:4001' "${FORWARDS:-}")"
    save_env_kv "SERVER_IP" "$sip"
    save_env_kv "SERVER_PORT" "$sp"
    save_env_kv "SOCKS_PORT" "$socks"
    save_env_kv "FORWARDS" "$fw"
  fi

  echo
  local automtu mtu margin runs cap
  automtu="$(ask "AUTO_MTU (1=on,0=manual)" "${AUTO_MTU:-1}")"
  save_env_kv "AUTO_MTU" "$automtu"
  if [[ "$automtu" == "1" ]]; then
    margin="$(ask "MTU_MARGIN" "${MTU_MARGIN:-90}")"
    runs="$(ask "MTU_RUNS (1..3)" "${MTU_RUNS:-3}")"
    cap="$(ask "MTU_CAP (0=off, else max mtu)" "${MTU_CAP:-0}")"
    save_env_kv "MTU_MARGIN" "$margin"
    save_env_kv "MTU_RUNS" "$runs"
    save_env_kv "MTU_CAP" "$cap"
  else
    mtu="$(ask "MTU (manual kcp.mtu)" "${MTU:-1350}")"
    cap="$(ask "MTU_CAP (0=off, else max mtu)" "${MTU_CAP:-0}")"
    save_env_kv "MTU" "$mtu"
    save_env_kv "MTU_CAP" "$cap"
  fi

  echo
  echo "[*] Applying profile..."
  apply_profile

  echo "[*] Generating config..."
  generate_config

  echo
  local startnow
  startnow="$(ask "Start services now? (y/n)" "y")"
  if [[ "$startnow" =~ ^[Yy]$ ]]; then
    start_all
  else
    echo "[*] Skipped start."
  fi
  pause
}

ping_df_ok(){ local t="$1" p="$2"; ping -4 -c 1 -W "${MTU_TIMEOUT:-1}" -M do -s "$p" "$t" >/dev/null 2>&1; }

verify_payload(){
  local target="$1" payload="$2" tries="$3"
  local i ok=0
  for ((i=1;i<=tries;i++)); do ping_df_ok "$target" "$payload" && ok=$((ok+1)) || true; done
  local need=$(( (tries + 1) / 2 ))
  [[ $ok -ge $need ]]
}

iface_for_target(){ ip -4 route get "$1" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n1; }
iface_mtu(){ ip link show dev "$1" 2>/dev/null | awk '/mtu/{for(i=1;i<=NF;i++) if($i=="mtu") print $(i+1)}' | head -n1; }

fallback_mtu(){
  local target="$1" mode="${MTU_FALLBACK_MODE:-auto}" pmtu=""
  if [[ "$mode" == "auto" || "$mode" == "tracepath" ]] && have tracepath; then
    pmtu="$(tracepath -n -m 3 "$target" 2>/dev/null | awk '/pmtu/ {for(i=1;i<=NF;i++) if($i=="pmtu") print $(i+1)}' | head -n1)"
    [[ -n "$pmtu" && "$pmtu" =~ ^[0-9]+$ ]] && { echo "$pmtu"; return 0; }
  fi
  if [[ "$mode" == "auto" || "$mode" == "iface" ]]; then
    local iface mtu
    iface="$(iface_for_target "$target")"
    mtu="$(iface_mtu "$iface")"
    [[ -n "$mtu" && "$mtu" =~ ^[0-9]+$ ]] && { echo "$mtu"; return 0; }
  fi
  echo "1500"
}

auto_detect_mtu_once(){
  local target="$1" margin="$2"

  local lo hi verify best
  lo="${MTU_MIN_PAYLOAD:-1200}"
  hi="${MTU_MAX_PAYLOAD:-1472}"
  verify="${MTU_VERIFY:-5}"
  best="$lo"

  # Coerce to ints if empty/non-numeric
  [[ "$lo" =~ ^[0-9]+$ ]] || lo=1200
  [[ "$hi" =~ ^[0-9]+$ ]] || hi=1472
  [[ "$verify" =~ ^[0-9]+$ ]] || verify=5

  if ! ping_df_ok "$target" 900; then
    local fb tuned
    fb="$(fallback_mtu "$target")"
    [[ "$fb" =~ ^[0-9]+$ ]] || fb=1500
    tuned=$(( fb - margin ))
    (( tuned < 1200 )) && tuned=1200
    (( tuned > 1450 )) && tuned=1450
    echo "$tuned"
    return 0
  fi

  while [[ $lo -le $hi ]]; do
    local mid=$(( (lo + hi) / 2 ))
    if ping_df_ok "$target" "$mid"; then
      best="$mid"
      lo=$(( mid + 1 ))
    else
      hi=$(( mid - 1 ))
    fi
  done

  local stable="$best"
  while [[ $stable -gt 800 ]]; do
    verify_payload "$target" "$stable" "$verify" && break
    stable=$(( stable - 4 ))
  done

  local path_mtu=$(( stable + 28 ))
  local tuned=$(( path_mtu - margin ))
  (( tuned < 1200 )) && tuned=1200
  (( tuned > 1450 )) && tuned=1450
  echo "$tuned"
}

get_mtu_target(){
  load_env
  local target="${MTU_TARGET:-}"
  [[ -z "$target" ]] && { [[ "$ROLE" == "client" ]] && target="${SERVER_IP:-}" || target="1.1.1.1"; }
  [[ -n "$target" ]] || die "Auto MTU: target empty"
  echo "$target"
}

median_of(){
  # Reads numbers from stdin, prints median (for up to 3 runs we use robust median)
  mapfile -t arr || true
  local n="${#arr[@]}"
  [[ "$n" -gt 0 ]] || { echo ""; return 1; }

  IFS=$'
' arr=($(printf "%s
" "${arr[@]}" | sed '/^$/d' | sort -n))
  n="${#arr[@]}"
  [[ "$n" -gt 0 ]] || { echo ""; return 1; }

  if [[ "$n" -eq 1 ]]; then
    echo "${arr[0]}"; return 0
  elif [[ "$n" -eq 2 ]]; then
    echo "${arr[0]}"; return 0
  else
    # n>=3
    echo "${arr[1]}"; return 0
  fi
}

apply_mtu_cap(){
  local mtu="$1"; load_env
  local cap="${MTU_CAP:-0}"
  if [[ -n "$cap" && "$cap" =~ ^[0-9]+$ && "$cap" -gt 0 ]] && (( mtu > cap )); then echo "$cap"; else echo "$mtu"; fi
}

pick_mtu(){
  load_env
  if [[ "${AUTO_MTU:-1}" != "1" ]]; then
    apply_mtu_cap "${MTU:-1350}"
    return 0
  fi

  local runs="${MTU_RUNS:-1}"
  [[ "$runs" =~ ^[0-9]+$ ]] || runs=1
  (( runs < 1 )) && runs=1
  (( runs > 3 )) && runs=3

  local target margin
  target="$(get_mtu_target)"
  margin="${MTU_MARGIN:-90}"

  local results=() i
  for ((i=1;i<=runs;i++)); do
    results+=("$(auto_detect_mtu_once "$target" "$margin")")
    sleep 1
  done

  # Filter empties
  local filtered=()
  for i in "${results[@]}"; do
    [[ -n "$i" ]] && filtered+=("$i")
  done

  local final=""
  if [[ "${MTU_MEDIAN:-1}" == "1" && ${#filtered[@]} -ge 2 ]]; then
    final="$(printf "%s
" "${filtered[@]}" | median_of || true)"
  fi

  if [[ -z "$final" ]]; then
    # fallback to last non-empty result, else MTU
    if [[ ${#filtered[@]} -ge 1 ]]; then
      final="${filtered[$(( ${#filtered[@]} - 1 ))]}"
    else
      final="${MTU:-1350}"
    fi
  fi

  apply_mtu_cap "$final"
}

current_kcp_mtu_from_cfg(){ [[ -f "$1" ]] || return 1; awk '/^[[:space:]]*mtu:[[:space:]]*[0-9]+/{print $2; exit}' "$1" 2>/dev/null; }

adaptive_mtu_once(){
  load_env
  [[ "${ADAPTIVE_MTU:-1}" == "1" ]] || { echo "[*] Adaptive MTU disabled"; return 0; }
  local target margin verify step minmtu
  target="$(get_mtu_target)"; margin="${MTU_MARGIN:-90}"; verify="${MTU_VERIFY:-5}"; step="${ADAPT_STEP:-12}"; minmtu="${ADAPT_MIN_MTU:-1200}"

  local cfgport cfgfile kcpmtu
  cfgport="$([[ "$ROLE" == "client" ]] && parse_list "${SERVER_PORT:-}" | awk '{print $1}' || parse_list "${LISTEN_PORT:-}" | awk '{print $1}')"
  [[ -n "$cfgport" ]] || die "Adaptive MTU: no ports"
  cfgfile="${CFG_DIR}/paqet_${cfgport}.yaml"
  [[ -f "$cfgfile" ]] || { echo "[!] Adaptive MTU: config not found, generating first..."; generate_config; }
  kcpmtu="$(current_kcp_mtu_from_cfg "$cfgfile" || true)"
  [[ -n "$kcpmtu" && "$kcpmtu" =~ ^[0-9]+$ ]] || die "Adaptive MTU: cannot read mtu from $cfgfile"

  local payload=$(( kcpmtu + margin - 28 ))
  verify_payload "$target" "$payload" "$verify" && { echo "[+] Adaptive MTU: OK"; return 0; }

  local newmtu="$kcpmtu"
  while (( newmtu > minmtu )); do
    newmtu=$(( newmtu - step )); (( newmtu < minmtu )) && newmtu="$minmtu"
    payload=$(( newmtu + margin - 28 ))
    if verify_payload "$target" "$payload" "$verify"; then
      save_env_kv "MTU_CAP" "$newmtu"
      echo "[+] Set MTU_CAP=$newmtu"
      generate_config
      restart_all
      return 0
    fi
    (( newmtu == minmtu )) && break
  done
  echo "[!] Adaptive MTU: no stable mtu found"
  return 1
}

install_paqet(){
  # Robust downloader (v1.1 hotfix):
  # - Uses GitHub API to find the correct asset name (avoids 404 when naming changes)
  # - Validates the downloaded file isn't HTML/Not Found and looks like a gzip tarball
  # - Retries and falls back to a heuristic if API is blocked

  local arch api url tmp size
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) die "Unsupported arch: $arch" ;;
  esac

  tmp="$(mktemp -d)"
  rm -f "$tmp/paqet.tgz" 2>/dev/null || true

  api="https://api.github.com/repos/hanselime/paqet/releases/latest"

  # 1) GitHub API (preferred)
  url="$(curl -fsSL \
      -H "Accept: application/vnd.github+json" \
      -H "User-Agent: pqp" \
      "$api" 2>/dev/null \
      | grep -oE 'https://github.com/hanselime/paqet/releases/download/[^"]+' \
      | grep -iE 'linux' \
      | grep -iE "${arch}" \
      | grep -iE '\.tar\.gz$' \
      | head -n1 || true)"

  # 2) Fallback: resolve tag + try common naming patterns
  if [[ -z "$url" ]]; then
    local tag
    tag="$(curl -fsSI -H "User-Agent: pqp" https://github.com/hanselime/paqet/releases/latest \
      | awk -F': ' 'tolower($1)=="location"{print $2}' \
      | tr -d '
' | tail -n1)"
    tag="${tag##*/}"
    [[ -n "$tag" ]] || die "Failed to resolve latest paqet tag"

    local candidates=(
      "paqet-linux-${arch}-${tag}.tar.gz"
      "paqet-linux-${arch}-v${tag}.tar.gz"
      "paqet-linux-${arch}-v${tag#v}.tar.gz"
      "paqet-linux-${arch}.tar.gz"
      "paqet_linux_${arch}.tar.gz"
      "paqet_linux_${arch}_${tag}.tar.gz"
    )
    local c
    for c in "${candidates[@]}"; do
      url="https://github.com/hanselime/paqet/releases/download/${tag}/${c}"
      if curl -fsSLI -H "User-Agent: pqp" "$url" >/dev/null 2>&1; then
        break
      fi
      url=""
    done
  fi

  [[ -n "$url" ]] || die "No matching paqet release asset found (arch=$arch)"

  echo "[*] Downloading paqet: $url"
  curl -fL --retry 3 --retry-delay 1 --connect-timeout 10 --max-time 180 \
    -H "User-Agent: pqp" \
    "$url" -o "$tmp/paqet.tgz" || die "Download failed"

  # Basic validation: file should be reasonably large and not HTML/Not Found
  size="$(wc -c <"$tmp/paqet.tgz" 2>/dev/null || echo 0)"
  if [[ "$size" -lt 50000 ]]; then
    echo "[!] Download too small ($size bytes). First 200 bytes:"
    head -c 200 "$tmp/paqet.tgz" | cat || true
    rm -rf "$tmp"
    die "Downloaded file is not a valid tar.gz (likely Not Found/HTML)"
  fi

  # gzip header check (1F 8B)
  if ! head -c 2 "$tmp/paqet.tgz" | od -An -tx1 | tr -d ' 
' | grep -qi '^1f8b'; then
    echo "[!] File does not look like gzip. First 200 bytes:"
    head -c 200 "$tmp/paqet.tgz" | cat || true
    rm -rf "$tmp"
    die "Downloaded file is not gzip (blocked/HTML?)"
  fi

  mkdir -p "$WORKDIR"
  tar -xzf "$tmp/paqet.tgz" -C "$WORKDIR" || { rm -rf "$tmp"; die "Extract failed"; }
  rm -rf "$tmp"

  local bin
  # Some releases ship binary as paqet_linux_amd64 / paqet-linux-amd64 / etc.
  # Find the first matching binary and normalize it to $WORKDIR/paqet
  if [[ -f "$WORKDIR/paqet" ]]; then
    bin="$WORKDIR/paqet"
  else
    bin="$(find "$WORKDIR" -maxdepth 2 -type f \( -name 'paqet' -o -name 'paqet_*' -o -name 'paqet-*' -o -name 'paqetlinux*' \) | head -n1 || true)"
  fi
  [[ -n "${bin:-}" && -f "$bin" ]] || die "paqet binary not found after extract"

  # Normalize to a stable path/name
  if [[ "$bin" != "$WORKDIR/paqet" ]]; then
    cp -f "$bin" "$WORKDIR/paqet"
    bin="$WORKDIR/paqet"
  fi

  chmod +x "$bin"
  ln -sf "$bin" "$PAQET_BIN"
  echo "[+] Installed paqet -> $PAQET_BIN"
}

install_paqet_template(){
  cat >"$SERVICE_TEMPLATE" <<EOF
[Unit]
Description=paqet tunnel instance %i
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=${PAQET_BIN} run -c ${CFG_DIR}/paqet_%i.yaml
Restart=always
RestartSec=2
LimitNOFILE=1048576
User=root
Group=root
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

install_forward_template(){
  cat >"$FWD_TEMPLATE" <<'EOF'
[Unit]
Description=PQP TCP Forward %i
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=/usr/local/sbin/pqp --run-forward %i
Restart=always
RestartSec=2
LimitNOFILE=1048576
User=root
Group=root
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

generate_config(){
  load_env
  apply_profile >/dev/null 2>&1 || true
  load_env
  mkdir -p "$CFG_DIR"
  local mtu mode conn rcv snd
  mtu="$(pick_mtu)"; mode="${KCP_MODE:-fast}"; conn="${KCP_CONN:-1}"; rcv="${KCP_RCVWND:-512}"; snd="${KCP_SNDWND:-512}"
    if [[ "$ROLE" == "server" ]]; then
    echo
    echo "این سرور خارج (Server) است:"
    echo "- پورت/پورت‌های گوش دادن (UDP)"
    echo "- (اختیاری) آی‌پی سرور ایران برای Allow کردن در فایروال"
    local lp lp_norm iran_ip
    while true; do
      lp="$(ask "LISTEN_PORT (comma-separated)" "${LISTEN_PORT:-9999}")"
      lp_norm="$(normalize_ports "$lp" 2>/dev/null || true)"
      [[ -n "$lp_norm" ]] && break
      echo "Invalid ports. Example: 9999 or 9999,8888"
    done
    iran_ip="$(ask "IRAN_IP (optional, for firewall allow) e.g. 1.2.3.4" "${IRAN_IP:-}")"
    if [[ -n "$iran_ip" ]]; then
      is_ipv4 "$iran_ip" || { echo "Invalid IPv4, skipping IRAN_IP."; iran_ip=""; }
    fi
    save_env_kv "LISTEN_PORT" "$lp_norm"
    save_env_kv "IRAN_IP" "$iran_ip"

    echo
    if [[ -n "$iran_ip" ]]; then
      local fw; fw="$(ask_yesno "Apply UFW allow rule for UDP ports from IRAN_IP? (recommended)" "n")"
      if [[ "$fw" == "y" ]]; then
        if have ufw; then
          ufw --force enable >/dev/null 2>&1 || true
          local p
          for p in $(parse_list "$lp_norm"); do
            ufw allow proto udp from "$iran_ip" to any port "$p" || true
          done
          echo "[+] UFW rules applied."
        else
          echo "[!] ufw not installed; skipping firewall rules."
        fi
      fi
    fi

  else
    echo
    echo "این سرور ایران (Client) است:"
    echo "- یک پورت واحد تانل (SERVER_PORT) برای اتصال به خارج"
    echo "- چند پورت ورودی ایران (برای اتصال کاربران) که همگی به یک پورت مقصد روی خارج فوروارد شوند"
    local sip tunnel_port tp_norm socks irports ir_norm dest_port dest_host

    while true; do
      sip="$(ask "SERVER_IP (kharej)" "${SERVER_IP}")"
      is_ipv4 "$sip" && break
      echo "Invalid IPv4. Example: 45.92.219.224"
    done

    while true; do
      tunnel_port="$(ask "TUNNEL_PORT (single, on kharej)" "${SERVER_PORT:-9999}")"
      tp_norm="$(normalize_ports "$tunnel_port" 2>/dev/null || true)"
      [[ -n "$tp_norm" && "$tp_norm" != *","* ]] && break
      echo "Invalid. Enter ONE port. Example: 9999"
    done

    while true; do
      socks="$(ask "SOCKS_PORT (local)" "${SOCKS_PORT:-1080}")"
      [[ "$socks" =~ ^[0-9]+$ ]] && ((socks>=1 && socks<=65535)) && break
      echo "Invalid port."
    done

    while true; do
      irports="$(ask "IRAN_IN_PORTS (comma-separated) ex: 443,8443,2053" "${IR_LISTEN_PORTS:-}")"
      ir_norm="$(normalize_ports "$irports" 2>/dev/null || true)"
      [[ -n "$ir_norm" ]] && break
      echo "Invalid ports. Example: 443,8443,2053"
    done

    while true; do
      dest_port="$(ask "DEST_PORT on kharej (single) ex: 443" "${FWD_DEST_PORT:-443}")"
      [[ "$dest_port" =~ ^[0-9]+$ ]] && ((dest_port>=1 && dest_port<=65535)) && break
      echo "Invalid port."
    done

    dest_host="$(ask "DEST_HOST on kharej (default: SERVER_IP)" "${FWD_DEST_HOST:-$sip}")"
    [[ -n "$dest_host" ]] || dest_host="$sip"
    [[ "$dest_host" =~ ^[A-Za-z0-9\.\-]+$ ]] || { echo "Invalid DEST_HOST, using SERVER_IP"; dest_host="$sip"; }

    local fwd="" p
    for p in $(parse_list "$ir_norm"); do
      fwd+="${p}:${dest_host}:${dest_port},"
    done
    fwd="${fwd%,}"

    save_env_kv "SERVER_IP" "$sip"
    save_env_kv "SERVER_PORT" "$tp_norm"
    save_env_kv "SOCKS_PORT" "$socks"
    save_env_kv "IR_LISTEN_PORTS" "$ir_norm"
    save_env_kv "FWD_DEST_HOST" "$dest_host"
    save_env_kv "FWD_DEST_PORT" "$dest_port"
    save_env_kv "FORWARDS" "$fwd"
  fi
  echo "[+] Generated configs (kcp.mtu=$mtu)"
}

run_forward(){
  load_env
  local ir_port="${1:-}"; [[ -n "$ir_port" ]] || die "run-forward needs port"
  [[ "$ROLE" == "client" ]] || die "Forward is client-only"
  [[ -n "${FORWARDS:-}" ]] || die "FORWARDS empty"
  local rules rule lport dest_host dest_port
  rules="$(parse_list "$FORWARDS")"; dest_host=""; dest_port=""
  for rule in $rules; do
    lport="${rule%%:*}"
    if [[ "$lport" == "$ir_port" ]]; then
      dest_host="$(echo "$rule" | awk -F: '{print $2}')"; dest_port="$(echo "$rule" | awk -F: '{print $3}')"; break
    fi
  done
  [[ -n "$dest_host" && -n "$dest_port" ]] || die "No forward rule for $ir_port"
  exec socat TCP-LISTEN:"$ir_port",fork,reuseaddr SOCKS5:127.0.0.1:"$dest_host":"$dest_port",socksport="$SOCKS_PORT"
}

start_all(){
  load_env
  install_paqet_template
  if [[ "$ROLE" == "server" ]]; then
    local ports; ports="$(parse_list "${LISTEN_PORT:-}")"
    for p in $ports; do systemctl enable --now "paqet@${p}"; done
  else
    local ports; ports="$(parse_list "${SERVER_PORT:-}")"
    for p in $ports; do systemctl enable --now "paqet@${p}"; done
    if [[ -n "${FORWARDS:-}" ]]; then
      install_forward_template
      local rules rule lport; rules="$(parse_list "$FORWARDS")"
      for rule in $rules; do lport="${rule%%:*}"; systemctl enable --now "pqp-forward@${lport}"; done
    fi
  fi
  echo "[+] Started services"
}

restart_all(){
  load_env
  if [[ "$ROLE" == "server" ]]; then
    local ports; ports="$(parse_list "${LISTEN_PORT:-}")"
    for p in $ports; do systemctl restart "paqet@${p}" || true; done
  else
    local ports; ports="$(parse_list "${SERVER_PORT:-}")"
    for p in $ports; do systemctl restart "paqet@${p}" || true; done
    if [[ -n "${FORWARDS:-}" ]]; then
      local rules rule lport; rules="$(parse_list "$FORWARDS")"
      for rule in $rules; do lport="${rule%%:*}"; systemctl restart "pqp-forward@${lport}" || true; done
    fi
  fi
  echo "[+] Restarted services"
}

stop_all(){
  load_env
  if [[ "$ROLE" == "server" ]]; then
    local ports; ports="$(parse_list "${LISTEN_PORT:-}")"
    for p in $ports; do systemctl stop "paqet@${p}" || true; done
  else
    local ports; ports="$(parse_list "${SERVER_PORT:-}")"
    for p in $ports; do systemctl stop "paqet@${p}" || true; done
    if [[ -n "${FORWARDS:-}" ]]; then
      local rules rule lport; rules="$(parse_list "$FORWARDS")"
      for rule in $rules; do lport="${rule%%:*}"; systemctl stop "pqp-forward@${lport}" || true; done
    fi
  fi
  echo "[+] Stopped services"
}

status_all(){
  load_env
  echo "==== ENV (redacted) ===="
  sed 's/^KEY=.*/KEY=***redacted***/' "$ENV_FILE" || true
  echo
  echo "Configs in $CFG_DIR:"
  ls -1 "$CFG_DIR" 2>/dev/null || true
}

cron_on(){
  cat >"$CRON_FILE" <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
0 */6 * * * root /usr/local/sbin/pqp --adapt-mtu >/dev/null 2>&1
EOF
  chmod 644 "$CRON_FILE"
  echo "[+] Cron enabled"
}
cron_off(){ rm -f "$CRON_FILE"; echo "[+] Cron disabled"; }

edit_env(){
  load_env
  if have nano; then nano "$ENV_FILE"; elif have vi; then vi "$ENV_FILE"; else echo "Edit: $ENV_FILE"; fi
}

uninstall_all(){
  cron_off || true
  stop_all || true
  rm -rf "$WORKDIR" "$CFG_DIR" "$(dirname "$ENV_FILE")"
  rm -f "$PAQET_BIN" 2>/dev/null || true
  rm -f /usr/local/sbin/pqp 2>/dev/null || true
  rm -f "$SERVICE_TEMPLATE" "$FWD_TEMPLATE" 2>/dev/null || true
  systemctl daemon-reload || true
  echo "[+] Uninstalled"
}

menu(){
  while true; do
    clear || true
    echo "=============================="
    echo "   PQP - Paqet Quick Panel"
    echo "=============================="
    echo "1) Install/Update paqet binary"
    echo "2) Create/Update tunnel (Wizard)"
    echo "3) Apply PROFILE"
    echo "4) Generate config (Auto MTU median runs)"
    echo "5) Start all services"
    echo "6) Restart all services"
    echo "7) Stop all services"
    echo "8) Status"
    echo "------------------------------"
    echo "9) Adaptive MTU now (set MTU_CAP)"
    echo "10) Cron ON"
    echo "11) Cron OFF"
    echo "------------------------------"
    echo "12) Edit settings (advanced)"
    echo "13) Uninstall everything"
    echo "0) Exit"
    echo
    read -r -p "Select: " c || exit 0
    case "$c" in
      1) install_paqet; pause ;;
      2) wizard_create_tunnel ;;
      3) apply_profile; pause ;;
      4) generate_config; pause ;;
      5) start_all; pause ;;
      6) restart_all; pause ;;
      7) stop_all; pause ;;
      8) status_all; pause ;;
      9) adaptive_mtu_once; pause ;;
      10) cron_on; pause ;;
      11) cron_off; pause ;;
      12) edit_env ;;
      13) uninstall_all ;;
      0) exit 0 ;;
      *) echo "Invalid"; sleep 1 ;;
    esac
  done
}

main(){
  need_root
  
self_check(){
  local missing=0
  for fn in ask ask_yesno normalize_ports parse_list save_env_kv is_ipv4; do
    if ! declare -F "$fn" >/dev/null 2>&1; then
      echo "ERROR: internal function missing: $fn" >&2
      missing=1
    fi
  done
  [[ "$missing" -eq 0 ]] || exit 1
}

self_check

case "${1:-}" in
    --wizard) wizard_create_tunnel ;;
    --install) install_paqet ;;
    --profile) apply_profile ;;
    --gen) generate_config ;;
    --start) start_all ;;
    --restart) restart_all ;;
    --stop) stop_all ;;
    --status) status_all ;;
    --adapt-mtu) adaptive_mtu_once ;;
    --cron-on) cron_on ;;
    --cron-off) cron_off ;;
    "" ) menu ;;
    --run-forward) run_forward "${2:-}" ;;
    * ) die "Unknown option: $1" ;;
  esac
}

main "$@"

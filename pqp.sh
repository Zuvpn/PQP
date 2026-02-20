#!/usr/bin/env bash
set -euo pipefail

# =======================
# PQP - Paqet Quick Panel
# Features:
# - Smart Auto MTU: DF ping binary search + verify + fallback
# - Profiles: low-traffic | balanced | max-speed
# - Adaptive MTU: if DF verification fails for current MTU, auto-step-down + regenerate + restart
# =======================

ENV_FILE="/etc/pqp/pqp.env"
PAQET_BIN="/usr/local/bin/paqet"
WORKDIR="/opt/paqet"
CFG_DIR="/etc/paqet"
SERVICE_TEMPLATE="/etc/systemd/system/paqet@.service"
FWD_TEMPLATE="/etc/systemd/system/pqp-forward@.service"
CRON_FILE="/etc/cron.d/pqp"

die(){ echo "ERROR: $*" >&2; exit 1; }
need_root(){ [[ ${EUID:-0} -ne 0 ]] && die "Run as root: sudo pqp"; }
have(){ command -v "$1" >/dev/null 2>&1; }
parse_list(){ echo "${1//,/ }"; }

default_env(){
  mkdir -p "$(dirname "$ENV_FILE")"
  cat >"$ENV_FILE" <<'EOF'
# ===== Profile =====
# low-traffic | balanced | max-speed
PROFILE=balanced

# ===== Basic =====
ROLE=client                 # client|server
KEY=CHANGE_ME

# ===== Client only =====
SERVER_IP=1.2.3.4
SERVER_PORT=9999
SOCKS_PORT=1080

# Forward rules (client only)
# IR_LISTEN_PORT:DEST_HOST:DEST_PORT , separated by comma
FORWARDS="443:1.2.3.4:4000,8443:1.2.3.4:4001"

# ===== Server only =====
LISTEN_PORT=9999

# ===== MTU =====
AUTO_MTU=1                  # 1=auto, 0=manual
MTU=1350                    # used when AUTO_MTU=0
MTU_TARGET=                 # empty => client uses SERVER_IP ; server uses 1.1.1.1
MTU_MARGIN=90               # safety margin subtracted from detected path MTU

# Smart Auto MTU tuning
MTU_VERIFY=5                # verify best payload with N pings
MTU_TIMEOUT=1               # ping timeout seconds
MTU_MIN_PAYLOAD=1200
MTU_MAX_PAYLOAD=1472
MTU_FALLBACK_MODE=auto      # auto|iface|tracepath (auto prefers tracepath if available)

# Adaptive MTU
ADAPTIVE_MTU=1              # 1=enabled, 0=disabled
ADAPT_STEP=12               # step-down (bytes) when current MTU fails verification
ADAPT_MIN_MTU=1200          # do not go below this for kcp.mtu

# ===== KCP =====
# (PQP generates YAML with these values)
KCP_MODE=fast               # normal|fast|fast2|fast3
KCP_CONN=1
KCP_RCVWND=512
KCP_SNDWND=512

# ===== Logging =====
LOG_LEVEL=info
EOF
  chmod 600 "$ENV_FILE"
}

load_env(){
  [[ -f "$ENV_FILE" ]] || default_env
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  ROLE="${ROLE:-client}"
  PROFILE="${PROFILE:-balanced}"
}

save_env_kv(){
  local key="$1" val="$2"
  # update or append KEY=VAL (simple)
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
      # prioritize lower overhead and fewer retransmits
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
      # prioritize throughput (more overhead possible)
      save_env_kv "KCP_MODE" "fast2"
      save_env_kv "KCP_CONN" "2"
      save_env_kv "KCP_RCVWND" "1024"
      save_env_kv "KCP_SNDWND" "1024"
      save_env_kv "MTU_MARGIN" "80"
      save_env_kv "MTU_VERIFY" "3"
      ;;
    *)
      die "Unknown PROFILE=$PROFILE (use low-traffic|balanced|max-speed)"
      ;;
  esac
  echo "[+] Applied profile: $PROFILE"
}

# -------- Smart Auto MTU --------
ping_df_ok(){
  local target="$1" payload="$2"
  ping -4 -c 1 -W "${MTU_TIMEOUT:-1}" -M do -s "$payload" "$target" >/dev/null 2>&1
}

verify_payload(){
  local target="$1" payload="$2" tries="$3"
  local i ok=0
  for ((i=1;i<=tries;i++)); do
    if ping_df_ok "$target" "$payload"; then
      ok=$((ok+1))
    fi
  done
  local need=$(( (tries + 1) / 2 ))
  [[ $ok -ge $need ]]
}

iface_for_target(){
  local target="$1"
  ip -4 route get "$target" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n1
}

iface_mtu(){
  local iface="$1"
  ip link show dev "$iface" 2>/dev/null | awk '/mtu/{for(i=1;i<=NF;i++) if($i=="mtu") print $(i+1)}' | head -n1
}

fallback_mtu(){
  local target="$1"
  local mode="${MTU_FALLBACK_MODE:-auto}"
  local pmtu=""

  if [[ "$mode" == "auto" || "$mode" == "tracepath" ]]; then
    if have tracepath; then
      pmtu="$(tracepath -n -m 3 "$target" 2>/dev/null | awk '/pmtu/ {for(i=1;i<=NF;i++) if($i=="pmtu") print $(i+1)}' | head -n1)"
    fi
    if [[ -n "$pmtu" && "$pmtu" =~ ^[0-9]+$ ]]; then
      echo "$pmtu"
      return 0
    fi
  fi

  if [[ "$mode" == "auto" || "$mode" == "iface" ]]; then
    local iface mtu
    iface="$(iface_for_target "$target")"
    mtu="$(iface_mtu "$iface")"
    if [[ -n "$mtu" && "$mtu" =~ ^[0-9]+$ ]]; then
      echo "$mtu"
      return 0
    fi
  fi

  echo "1500"
}

auto_detect_mtu_smart(){
  local target="$1" margin="$2"
  [[ -n "$target" ]] || die "Auto MTU: target is empty"
  [[ "$margin" =~ ^[0-9]+$ ]] || die "Auto MTU: MTU_MARGIN must be numeric"

  local lo="${MTU_MIN_PAYLOAD:-1200}"
  local hi="${MTU_MAX_PAYLOAD:-1472}"
  local verify="${MTU_VERIFY:-5}"
  local best="$lo"

  echo "[*] Auto MTU (smart): DF ping binary search to $target ..."

  # quick sanity: if DF ping blocked/unreachable, fallback
  if ! ping_df_ok "$target" 900; then
    echo "[!] Auto MTU: DF ping seems blocked/unreachable; using fallback estimation..."
    local fb tuned
    fb="$(fallback_mtu "$target")"
    tuned=$(( fb - margin ))
    (( tuned < 1200 )) && tuned=1200
    (( tuned > 1450 )) && tuned=1450
    echo "[+] Auto MTU fallback: base_mtu=$fb, margin=$margin => kcp.mtu=$tuned"
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

  # verify stability; if flaky, step down until stable
  local stable="$best"
  while [[ $stable -gt 800 ]]; do
    if verify_payload "$target" "$stable" "$verify"; then
      break
    fi
    stable=$(( stable - 4 ))
  done

  local path_mtu=$(( stable + 28 ))
  local tuned=$(( path_mtu - margin ))
  (( tuned < 1200 )) && tuned=1200
  (( tuned > 1450 )) && tuned=1450

  echo "[+] Auto MTU smart: best_payload=$best, stable_payload=$stable => path_mtu=$path_mtu, margin=$margin => kcp.mtu=$tuned"
  echo "$tuned"
}

get_mtu_target(){
  load_env
  local target="${MTU_TARGET:-}"
  if [[ -z "$target" ]]; then
    if [[ "$ROLE" == "client" ]]; then
      target="${SERVER_IP:-}"
    else
      target="1.1.1.1"
    fi
  fi
  [[ -n "$target" ]] || die "Auto MTU: target empty (set MTU_TARGET or SERVER_IP)"
  echo "$target"
}

pick_mtu(){
  load_env
  if [[ "${AUTO_MTU:-1}" != "1" ]]; then
    echo "${MTU:-1350}"
    return 0
  fi
  auto_detect_mtu_smart "$(get_mtu_target)" "${MTU_MARGIN:-90}"
}

# -------- Adaptive MTU --------
# Verifies current MTU (derived from current KCP_MTU + MTU_MARGIN) using DF ping.
# If fails, step down kcp.mtu and re-verify until pass or hit ADAPT_MIN_MTU.
current_kcp_mtu_from_cfg(){
  local cfg="$1"
  [[ -f "$cfg" ]] || return 1
  awk '/^[[:space:]]*mtu:[[:space:]]*[0-9]+/{print $2; exit}' "$cfg" 2>/dev/null
}

adaptive_mtu_once(){
  load_env
  [[ "${ADAPTIVE_MTU:-1}" == "1" ]] || { echo "[*] Adaptive MTU disabled"; return 0; }

  local target margin verify step minmtu
  target="$(get_mtu_target)"
  margin="${MTU_MARGIN:-90}"
  verify="${MTU_VERIFY:-5}"
  step="${ADAPT_STEP:-12}"
  minmtu="${ADAPT_MIN_MTU:-1200}"

  # choose one config to read current kcp.mtu from (first tunnel port)
  local cfgport cfgfile kcpmtu
  if [[ "$ROLE" == "client" ]]; then
    cfgport="$(parse_list "${SERVER_PORT:-}" | awk '{print $1}')"
  else
    cfgport="$(parse_list "${LISTEN_PORT:-}" | awk '{print $1}')"
  fi
  [[ -n "$cfgport" ]] || die "Adaptive MTU: no configured ports found"
  cfgfile="${CFG_DIR}/paqet_${cfgport}.yaml"
  kcpmtu="$(current_kcp_mtu_from_cfg "$cfgfile" || true)"
  [[ -n "$kcpmtu" && "$kcpmtu" =~ ^[0-9]+$ ]] || die "Adaptive MTU: cannot read current mtu from $cfgfile (generate config first)"

  # To test whether fragmentation might happen, test DF payload for path_mtu ~= kcp_mtu + margin
  # payload = (path_mtu - 28) = (kcpmtu + margin - 28)
  local payload=$(( kcpmtu + margin - 28 ))
  echo "[*] Adaptive MTU: verifying current kcp.mtu=$kcpmtu (test payload=$payload) to $target ..."
  if verify_payload "$target" "$payload" "$verify"; then
    echo "[+] Adaptive MTU: current MTU looks OK"
    return 0
  fi

  echo "[!] Adaptive MTU: verification failed; stepping down mtu in increments of $step ..."
  local newmtu="$kcpmtu"
  while (( newmtu > minmtu )); do
    newmtu=$(( newmtu - step ))
    (( newmtu < minmtu )) && newmtu="$minmtu"
    payload=$(( newmtu + margin - 28 ))
    if verify_payload "$target" "$payload" "$verify"; then
      echo "[+] Adaptive MTU: found stable kcp.mtu=$newmtu"
      # lock in by disabling AUTO_MTU and setting MTU (manual) to newmtu
      save_env_kv "AUTO_MTU" "0"
      save_env_kv "MTU" "$newmtu"
      echo "[*] Adaptive MTU: updating configs and restarting services..."
      generate_config
      restart_all
      return 0
    fi
    (( newmtu == minmtu )) && break
  done

  echo "[!] Adaptive MTU: could not find stable mtu above $minmtu; leaving as-is"
  return 1
}

# -------- Paqet install (latest release) --------
install_paqet(){
  local arch tag url tmp
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) die "Unsupported arch: $arch" ;;
  esac

  tag="$(curl -fsSI https://github.com/hanselime/paqet/releases/latest | awk -F': ' 'tolower($1)=="location"{print $2}' | tr -d '\r' | tail -n1)"
  tag="${tag##*/}"
  [[ -n "$tag" ]] || die "Failed to resolve latest paqet release tag"

  url="https://github.com/hanselime/paqet/releases/download/${tag}/paqet_linux_${arch}.tar.gz"
  mkdir -p "$WORKDIR"
  tmp="$(mktemp -d)"
  echo "[*] Downloading paqet $tag ($arch)..."
  curl -fL --connect-timeout 10 --max-time 180 "$url" -o "$tmp/paqet.tgz" || die "Download failed: $url"
  tar -xzf "$tmp/paqet.tgz" -C "$WORKDIR"
  rm -rf "$tmp"

  local bin
  if [[ -f "$WORKDIR/paqet" ]]; then
    bin="$WORKDIR/paqet"
  else
    bin="$(find "$WORKDIR" -maxdepth 3 -type f -name paqet | head -n1 || true)"
  fi
  [[ -n "${bin:-}" && -f "$bin" ]] || die "paqet binary not found after extract"
  chmod +x "$bin"
  ln -sf "$bin" "$PAQET_BIN"
  echo "[+] Installed paqet -> $PAQET_BIN"
  "$PAQET_BIN" version || true
}

# -------- systemd templates --------
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
  echo "[+] Installed systemd template: paqet@.service"
}

install_forward_template(){
  cat >"$FWD_TEMPLATE" <<'EOF'
[Unit]
Description=PQP TCP Forward %i (listen on Iran -> via local SOCKS)
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
  echo "[+] Installed systemd template: pqp-forward@.service"
}

# -------- configs --------
generate_config(){
  load_env
  apply_profile >/dev/null 2>&1 || true  # safe if profile set; keeps env consistent
  load_env
  mkdir -p "$CFG_DIR"

  local mtu mode conn rcv snd
  mtu="$(pick_mtu)"
  mode="${KCP_MODE:-fast}"
  conn="${KCP_CONN:-1}"
  rcv="${KCP_RCVWND:-512}"
  snd="${KCP_SNDWND:-512}"

  if [[ "$ROLE" == "server" ]]; then
    local ports
    ports="$(parse_list "${LISTEN_PORT:-}")"
    [[ -n "$ports" ]] || die "LISTEN_PORT required for server"

    for p in $ports; do
      cat >"${CFG_DIR}/paqet_${p}.yaml" <<EOF
role: "server"

log:
  level: "${LOG_LEVEL}"

listen:
  addr: ":${p}"

transport:
  protocol: "kcp"
  conn: ${conn}
  kcp:
    mode: "${mode}"
    mtu: ${mtu}
    rcvwnd: ${rcv}
    sndwnd: ${snd}
    key: "${KEY}"
EOF
    done
    echo "[+] Wrote server configs for ports: $ports"
  else
    local ports
    ports="$(parse_list "${SERVER_PORT:-}")"
    [[ -n "${SERVER_IP:-}" ]] || die "SERVER_IP required for client"
    [[ -n "$ports" ]] || die "SERVER_PORT required for client"

    for p in $ports; do
      cat >"${CFG_DIR}/paqet_${p}.yaml" <<EOF
role: "client"

log:
  level: "${LOG_LEVEL}"

socks5:
  - listen: "127.0.0.1:${SOCKS_PORT}"
    username: ""
    password: ""

server:
  addr: "${SERVER_IP}:${p}"

transport:
  protocol: "kcp"
  conn: ${conn}
  kcp:
    mode: "${mode}"
    mtu: ${mtu}
    rcvwnd: ${rcv}
    sndwnd: ${snd}
    key: "${KEY}"
EOF
    done
    echo "[+] Wrote client configs for tunnel ports: $ports"
  fi
}

# -------- forward runner --------
run_forward(){
  load_env
  local ir_port="${1:-}"
  [[ -n "$ir_port" ]] || die "run-forward needs a listen port"
  [[ "$ROLE" == "client" ]] || die "Forward service is for ROLE=client only"
  [[ -n "${SOCKS_PORT:-}" ]] || die "SOCKS_PORT missing"
  [[ -n "${FORWARDS:-}" ]] || die "FORWARDS empty"

  local rules rule lport dest_host dest_port
  rules="$(parse_list "$FORWARDS")"

  dest_host=""
  dest_port=""
  for rule in $rules; do
    lport="${rule%%:*}"
    if [[ "$lport" == "$ir_port" ]]; then
      dest_host="$(echo "$rule" | awk -F: '{print $2}')"
      dest_port="$(echo "$rule" | awk -F: '{print $3}')"
      break
    fi
  done
  [[ -n "$dest_host" && -n "$dest_port" ]] || die "No forward rule found for IR port $ir_port"

  exec socat -ly -d -d \
    TCP-LISTEN:"$ir_port",fork,reuseaddr \
    SOCKS5:127.0.0.1:"$dest_host":"$dest_port",socksport="$SOCKS_PORT"
}

# -------- service control --------
start_all(){
  load_env
  install_paqet_template

  if [[ "$ROLE" == "server" ]]; then
    local ports
    ports="$(parse_list "${LISTEN_PORT:-}")"
    [[ -n "$ports" ]] || die "LISTEN_PORT required for server"
    for p in $ports; do
      systemctl enable --now "paqet@${p}"
    done
    echo "[+] Started paqet on server ports: $ports"
  else
    local ports
    ports="$(parse_list "${SERVER_PORT:-}")"
    [[ -n "$ports" ]] || die "SERVER_PORT required for client"
    for p in $ports; do
      systemctl enable --now "paqet@${p}"
    done
    echo "[+] Started paqet client tunnels: $ports"

    if [[ -n "${FORWARDS:-}" ]]; then
      install_forward_template
      local rules rule lport
      rules="$(parse_list "$FORWARDS")"
      for rule in $rules; do
        lport="${rule%%:*}"
        systemctl enable --now "pqp-forward@${lport}"
      done
      echo "[+] Started forwarders: $FORWARDS"
    fi
  fi
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
      for rule in $rules; do
        lport="${rule%%:*}"
        systemctl restart "pqp-forward@${lport}" || true
      done
    fi
  fi
  echo "[+] Restarted services"
}

stop_all(){
  load_env
  if [[ "$ROLE" == "server" ]]; then
    local ports
    ports="$(parse_list "${LISTEN_PORT:-}")"
    for p in $ports; do systemctl stop "paqet@${p}" || true; done
  else
    local ports
    ports="$(parse_list "${SERVER_PORT:-}")"
    for p in $ports; do systemctl stop "paqet@${p}" || true; done
    if [[ -n "${FORWARDS:-}" ]]; then
      local rules rule lport
      rules="$(parse_list "$FORWARDS")"
      for rule in $rules; do
        lport="${rule%%:*}"
        systemctl stop "pqp-forward@${lport}" || true
      done
    fi
  fi
  echo "[+] Stopped services"
}

status_all(){
  load_env
  echo "==== ENV (redacted) ===="
  sed 's/^KEY=.*/KEY=***redacted***/' "$ENV_FILE" || true
  echo

  if [[ "$ROLE" == "server" ]]; then
    local ports
    ports="$(parse_list "${LISTEN_PORT:-}")"
    for p in $ports; do
      systemctl --no-pager -l status "paqet@${p}" || true
      echo
    done
  else
    local ports
    ports="$(parse_list "${SERVER_PORT:-}")"
    for p in $ports; do
      systemctl --no-pager -l status "paqet@${p}" || true
      echo
    done
    if [[ -n "${FORWARDS:-}" ]]; then
      local rules rule lport
      rules="$(parse_list "$FORWARDS")"
      for rule in $rules; do
        lport="${rule%%:*}"
        systemctl --no-pager -l status "pqp-forward@${lport}" || true
        echo
      done
    fi
  fi
}

cron_on(){
  cat >"$CRON_FILE" <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# Adaptive MTU check every 6 hours
0 */6 * * * root /usr/local/sbin/pqp --adapt-mtu >/dev/null 2>&1
EOF
  chmod 644 "$CRON_FILE"
  echo "[+] Cron enabled: adaptive MTU every 6 hours"
}

cron_off(){
  rm -f "$CRON_FILE"
  echo "[+] Cron disabled"
}

remove_services_only(){
  load_env
  stop_all

  if [[ "$ROLE" == "server" ]]; then
    local ports; ports="$(parse_list "${LISTEN_PORT:-}")"
    for p in $ports; do systemctl disable "paqet@${p}" >/dev/null 2>&1 || true; done
  else
    local ports; ports="$(parse_list "${SERVER_PORT:-}")"
    for p in $ports; do systemctl disable "paqet@${p}" >/dev/null 2>&1 || true; done
    if [[ -n "${FORWARDS:-}" ]]; then
      local rules rule lport
      rules="$(parse_list "$FORWARDS")"
      for rule in $rules; do
        lport="${rule%%:*}"
        systemctl disable "pqp-forward@${lport}" >/dev/null 2>&1 || true
      done
    fi
  fi

  rm -f "$SERVICE_TEMPLATE" "$FWD_TEMPLATE"
  systemctl daemon-reload
  echo "[+] Removed systemd templates (services only)"
}

uninstall_all(){
  remove_services_only
  cron_off || true
  rm -rf "$WORKDIR" "$CFG_DIR" "$(dirname "$ENV_FILE")"
  rm -f "$PAQET_BIN" 2>/dev/null || true
  rm -f /usr/local/sbin/pqp 2>/dev/null || true
  echo "[+] Uninstalled PQP + configs + paqet binary symlink"
}

edit_env(){
  load_env
  if have nano; then nano "$ENV_FILE"
  elif have vi; then vi "$ENV_FILE"
  else
    echo "Edit this file manually: $ENV_FILE"
  fi
}

menu(){
  while true; do
    clear || true
    echo "=============================="
    echo "   PQP - Paqet Quick Panel"
    echo "=============================="
    echo "1) Install/Update paqet binary"
    echo "2) Edit settings (pqp.env)"
    echo "3) Apply PROFILE (low-traffic/balanced/max-speed)"
    echo "4) Generate config (Smart Auto MTU)"
    echo "5) Start all services"
    echo "6) Restart all services"
    echo "7) Stop all services"
    echo "8) Status (all)"
    echo "------------------------------"
    echo "9) Adaptive MTU now (step-down on fragmentation)"
    echo "10) Cron ON (adaptive MTU every 6h)"
    echo "11) Cron OFF"
    echo "------------------------------"
    echo "12) Remove services only (keep configs)"
    echo "13) Uninstall everything (remove script too)"
    echo "0) Exit"
    echo
    read -r -p "Select: " c
    case "$c" in
      1) install_paqet; read -r -p "Enter to continue..." _ ;;
      2) edit_env ;;
      3) apply_profile; read -r -p "Enter to continue..." _ ;;
      4) generate_config; read -r -p "Enter to continue..." _ ;;
      5) start_all; read -r -p "Enter to continue..." _ ;;
      6) restart_all; read -r -p "Enter to continue..." _ ;;
      7) stop_all; read -r -p "Enter to continue..." _ ;;
      8) status_all; read -r -p "Enter to continue..." _ ;;
      9) adaptive_mtu_once; read -r -p "Enter to continue..." _ ;;
      10) cron_on; read -r -p "Enter to continue..." _ ;;
      11) cron_off; read -r -p "Enter to continue..." _ ;;
      12) remove_services_only; read -r -p "Enter to continue..." _ ;;
      13) uninstall_all; read -r -p "Enter to continue..." _ ;;
      0) exit 0 ;;
      *) echo "Invalid"; sleep 1 ;;
    esac
  done
}

main(){
  need_root
  case "${1:-}" in
    --run-forward) run_forward "${2:-}";;
    --install) install_paqet;;
    --profile) apply_profile;;
    --gen) generate_config;;
    --start) start_all;;
    --restart) restart_all;;
    --stop) stop_all;;
    --status) status_all;;
    --adapt-mtu) adaptive_mtu_once;;
    --cron-on) cron_on;;
    --cron-off) cron_off;;
    --rm-services) remove_services_only;;
    --uninstall) uninstall_all;;
    "" ) menu ;;
    * ) die "Unknown option: $1" ;;
  esac
}

main "$@"

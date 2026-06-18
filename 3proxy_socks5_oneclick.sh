#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_NAME="$(basename "$0")"
REPO_URL="https://github.com/3proxy/3proxy.git"
REPO_BRANCH="master"
SERVICE_NAME="3proxy-socks5"
CFG_DIR="/etc/3proxy"
CFG_FILE="${CFG_DIR}/3proxy.cfg"
LOG_DIR="/var/log/3proxy"
STATE_DIR="/var/lib/3proxy-socks5"
NODE_FILE="${STATE_DIR}/nodes.csv"
ENDPOINT_FILE="${STATE_DIR}/endpoints.txt"
CREDS_FILE="${STATE_DIR}/credentials.txt"
UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

COUNT=""
IPS_FILE=""
AUTH_MODE="shared"
USERNAME=""
PASSWORD=""
USER_PREFIX="socks"
PORT_MODE="same"
PORT="1080"
PORT_START="20000"
OPEN_FIREWALL=1

BUILD_DIR=""
SRC_DIR=""
NODE_USERS=()
NODE_PASSWORDS=()
OPENSSL_ROOT_DIR=""
OPENSSL_INCLUDE_DIR="/usr/include"
OPENSSL_CRYPTO_LIBRARY=""
OPENSSL_SSL_LIBRARY=""

usage() {
  cat <<EOF
Usage: sudo bash ${SCRIPT_NAME} [options]

Options:
  --count N            Limit how many IPs to use from auto-detection or --ips-file.
  --ips-file FILE      Read IPv4 addresses from FILE, one per line.
  --auth-mode MODE     shared | per-node (default: shared)
  --username USER      Shared username for shared mode.
  --password PASS      Shared password for shared mode.
  --user-prefix PREF   Prefix used for per-node usernames (default: socks)
  --port-mode MODE     same | incremental (default: same)
  --port PORT          Listening port for same mode (default: 1080)
  --port-start PORT    First port for incremental mode (default: 20000)
  --no-firewall        Skip firewall opening.
  -h, --help           Show this help.

Examples:
  bash ${SCRIPT_NAME} --auth-mode shared --username demo --password DemoPass123
  bash ${SCRIPT_NAME} --auth-mode per-node --port-mode incremental --port-start 20000
  bash ${SCRIPT_NAME} --ips-file /root/ips.txt --count 256 --port-mode same --port 1080
EOF
}

log() {
  printf '[%s] %s\n' "INFO" "$*"
}

warn() {
  printf '[%s] %s\n' "WARN" "$*" >&2
}

die() {
  printf '[%s] %s\n' "ERROR" "$*" >&2
  exit 1
}

cleanup() {
  if [[ -n "${BUILD_DIR:-}" && -d "${BUILD_DIR}" ]]; then
    rm -rf "${BUILD_DIR}"
  fi
  if [[ -n "${SRC_DIR:-}" && -d "${SRC_DIR}" ]]; then
    rm -rf "${SRC_DIR}"
  fi
}

trap cleanup EXIT

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Please run this script as root."
  fi
}

check_os() {
  [[ -r /etc/os-release ]] || die "Cannot read /etc/os-release."
  # shellcheck disable=SC1091
  . /etc/os-release

  case "${ID:-}" in
    debian)
      if ! command -v dpkg >/dev/null 2>&1 || ! dpkg --compare-versions "${VERSION_ID:-0}" ge "11"; then
        die "This script supports Debian 11+."
      fi
      if command -v dpkg >/dev/null 2>&1 && ! dpkg --compare-versions "${VERSION_ID:-0}" le "13"; then
        warn "Debian ${VERSION_ID:-unknown} is newer than the tested range (11-13). Continuing."
      fi
      ;;
    ubuntu)
      if ! command -v dpkg >/dev/null 2>&1 || ! dpkg --compare-versions "${VERSION_ID:-0}" ge "22.04"; then
        die "This script supports Ubuntu 22.04+."
      fi
      if command -v dpkg >/dev/null 2>&1 && ! dpkg --compare-versions "${VERSION_ID:-0}" le "26.04"; then
        warn "Ubuntu ${VERSION_ID:-unknown} is newer than the tested range (22.04-26.04). Continuing."
      fi
      ;;
    *)
      die "Unsupported distribution: ${ID:-unknown}. Use Debian or Ubuntu."
      ;;
  esac
}

validate_int() {
  local value="$1"
  [[ "$value" =~ ^[0-9]+$ ]] || return 1
}

validate_port() {
  local value="$1"
  validate_int "$value" || return 1
  (( value >= 1 && value <= 65535 ))
}

validate_username() {
  local value="$1"
  [[ "$value" =~ ^[A-Za-z0-9._-]+$ ]]
}

validate_password() {
  local value="$1"
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* && "$value" != *" "* ]]
}

rand_alnum() {
  local length="$1"
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$length"
}

detect_openssl_paths() {
  OPENSSL_ROOT_DIR="/usr"
  OPENSSL_INCLUDE_DIR="/usr/include"
  OPENSSL_CRYPTO_LIBRARY=""
  OPENSSL_SSL_LIBRARY=""

  local multiarch=""
  if command -v gcc >/dev/null 2>&1; then
    multiarch="$(gcc -print-multiarch 2>/dev/null || true)"
  fi
  if [[ -z "${multiarch}" ]] && command -v dpkg-architecture >/dev/null 2>&1; then
    multiarch="$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || true)"
  fi

  if [[ -n "${multiarch}" ]]; then
    local crypto_candidate="/usr/lib/${multiarch}/libcrypto.so"
    local ssl_candidate="/usr/lib/${multiarch}/libssl.so"
    [[ -r "${crypto_candidate}" ]] && OPENSSL_CRYPTO_LIBRARY="${crypto_candidate}"
    [[ -r "${ssl_candidate}" ]] && OPENSSL_SSL_LIBRARY="${ssl_candidate}"
  fi

  if [[ -z "${OPENSSL_CRYPTO_LIBRARY}" || -z "${OPENSSL_SSL_LIBRARY}" ]]; then
    if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists openssl 2>/dev/null; then
      local pkg_libdir
      pkg_libdir="$(pkg-config --variable=libdir openssl 2>/dev/null || true)"
      if [[ -n "${pkg_libdir}" ]]; then
        [[ -z "${OPENSSL_CRYPTO_LIBRARY}" && -r "${pkg_libdir}/libcrypto.so" ]] && OPENSSL_CRYPTO_LIBRARY="${pkg_libdir}/libcrypto.so"
        [[ -z "${OPENSSL_SSL_LIBRARY}" && -r "${pkg_libdir}/libssl.so" ]] && OPENSSL_SSL_LIBRARY="${pkg_libdir}/libssl.so"
      fi
    fi
  fi

  if [[ -z "${OPENSSL_CRYPTO_LIBRARY}" && -r /usr/lib/libcrypto.so ]]; then
    OPENSSL_CRYPTO_LIBRARY="/usr/lib/libcrypto.so"
  fi
  if [[ -z "${OPENSSL_SSL_LIBRARY}" && -r /usr/lib/libssl.so ]]; then
    OPENSSL_SSL_LIBRARY="/usr/lib/libssl.so"
  fi
}

verify_build_deps() {
  command -v cmake >/dev/null 2>&1 || die "cmake is required."
  command -v make >/dev/null 2>&1 || die "make is required."
  command -v git >/dev/null 2>&1 || die "git is required."
  command -v openssl >/dev/null 2>&1 || die "openssl command is required."
  [[ -r /usr/include/openssl/ssl.h ]] || die "OpenSSL headers are missing. libssl-dev was not installed correctly."
  detect_openssl_paths
  if [[ -z "${OPENSSL_CRYPTO_LIBRARY}" || -z "${OPENSSL_SSL_LIBRARY}" ]]; then
    warn "Could not auto-detect OpenSSL library paths; CMake will still try standard locations."
  fi
}

apt_install_deps() {
  export DEBIAN_FRONTEND=noninteractive
  log "Installing build dependencies..."
  apt-get update
  apt-get install -y --no-install-recommends \
    ca-certificates \
    cmake \
    git \
    build-essential \
    iproute2 \
    libssl-dev \
    openssl \
    pkg-config
  verify_build_deps
}

build_3proxy() {
  log "Fetching official 3proxy source..."
  SRC_DIR="$(mktemp -d /tmp/3proxy-src.XXXXXX)"
  BUILD_DIR="$(mktemp -d /tmp/3proxy-build.XXXXXX)"

  git clone --depth 1 --branch "${REPO_BRANCH}" "${REPO_URL}" "${SRC_DIR}"

  if command -v cmake >/dev/null 2>&1; then
    log "Building 3proxy with CMake..."
    local cmake_args=(
      -S "${SRC_DIR}"
      -B "${BUILD_DIR}"
      -DCMAKE_BUILD_TYPE=Release
      -DCMAKE_INSTALL_PREFIX=/usr/local
      -DOPENSSL_ROOT_DIR="${OPENSSL_ROOT_DIR}"
      -DOPENSSL_INCLUDE_DIR="${OPENSSL_INCLUDE_DIR}"
    )
    if [[ -n "${OPENSSL_CRYPTO_LIBRARY}" ]]; then
      cmake_args+=("-DOPENSSL_CRYPTO_LIBRARY=${OPENSSL_CRYPTO_LIBRARY}")
    fi
    if [[ -n "${OPENSSL_SSL_LIBRARY}" ]]; then
      cmake_args+=("-DOPENSSL_SSL_LIBRARY=${OPENSSL_SSL_LIBRARY}")
    fi

    if cmake "${cmake_args[@]}" \
      && cmake --build "${BUILD_DIR}" --parallel "$(nproc)" \
      && cmake --install "${BUILD_DIR}"; then
      :
    else
      warn "CMake build failed, falling back to Makefile.Linux."
      rm -rf "${BUILD_DIR}"
      BUILD_DIR="$(mktemp -d /tmp/3proxy-build.XXXXXX)"
      (
        cd "${SRC_DIR}"
        ln -sf Makefile.Linux Makefile
        make -j"$(nproc)"
      )
      local built_bin
      built_bin="$(find "${SRC_DIR}" -type f -name 3proxy -perm -111 | head -n 1 || true)"
      [[ -n "${built_bin}" ]] || die "Unable to locate the compiled 3proxy binary."
      install -d -m 0755 /usr/local/bin
      install -m 0755 "${built_bin}" /usr/local/bin/3proxy
    fi
  else
    warn "cmake not found, falling back to Makefile.Linux."
    (
      cd "${SRC_DIR}"
      ln -sf Makefile.Linux Makefile
      make -j"$(nproc)"
    )
    local built_bin
    built_bin="$(find "${SRC_DIR}" -type f -name 3proxy -perm -111 | head -n 1 || true)"
    [[ -n "${built_bin}" ]] || die "Unable to locate the compiled 3proxy binary."
    install -d -m 0755 /usr/local/bin
    install -m 0755 "${built_bin}" /usr/local/bin/3proxy
  fi

  command -v /usr/local/bin/3proxy >/dev/null 2>&1 || die "3proxy installation failed."
}

read_ips() {
  local -a raw_ips=()
  if [[ -n "${IPS_FILE}" ]]; then
    [[ -r "${IPS_FILE}" ]] || die "Cannot read IP file: ${IPS_FILE}"
    mapfile -t raw_ips < <(grep -vE '^[[:space:]]*($|#)' "${IPS_FILE}" | tr -d '\r')
  else
    mapfile -t raw_ips < <(ip -o -4 addr show up scope global | awk '{split($4,a,"/"); print a[1]}' | sort -u)
  fi

  IPS=()
  local ip
  for ip in "${raw_ips[@]}"; do
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      IPS+=("$ip")
    else
      warn "Skipping invalid IPv4 address: $ip"
    fi
  done

  if [[ "${#IPS[@]}" -eq 0 ]]; then
    die "No usable IPv4 addresses were found."
  fi

  if [[ -n "${COUNT}" ]]; then
    if (( COUNT < 1 )); then
      die "--count must be greater than 0."
    fi
    if (( COUNT < ${#IPS[@]} )); then
      IPS=("${IPS[@]:0:COUNT}")
    elif (( COUNT > ${#IPS[@]} )); then
      warn "Requested ${COUNT} IPs, but only ${#IPS[@]} usable IPs were found. Using all available IPs."
    fi
  fi
}

validate_args() {
  if [[ -n "${COUNT}" ]] && ! validate_int "${COUNT}"; then
    die "--count must be a positive integer."
  fi
  if ! validate_port "${PORT}"; then
    die "Invalid --port value: ${PORT}"
  fi
  if ! validate_port "${PORT_START}"; then
    die "Invalid --port-start value: ${PORT_START}"
  fi
  if [[ "${AUTH_MODE}" != "shared" && "${AUTH_MODE}" != "per-node" ]]; then
    die "--auth-mode must be shared or per-node."
  fi
  if [[ "${PORT_MODE}" != "same" && "${PORT_MODE}" != "incremental" ]]; then
    die "--port-mode must be same or incremental."
  fi
  if [[ -n "${USERNAME}" ]] && ! validate_username "${USERNAME}"; then
    die "Username may contain only letters, numbers, dot, underscore, and dash."
  fi
  if [[ -n "${PASSWORD}" ]] && ! validate_password "${PASSWORD}"; then
    die "Password must not contain whitespace or line breaks."
  fi
  if ! validate_username "${USER_PREFIX}"; then
    die "--user-prefix may contain only letters, numbers, dot, underscore, and dash."
  fi
}

choose_credentials() {
  if [[ "${AUTH_MODE}" == "shared" ]]; then
    if [[ -z "${USERNAME}" ]]; then
      USERNAME="$(rand_alnum 10)"
    fi
    if [[ -z "${PASSWORD}" ]]; then
      PASSWORD="$(rand_alnum 18)"
    fi
  fi
}

generate_nodes() {
  mkdir -p "${STATE_DIR}"
  chmod 0755 "${STATE_DIR}"
  : > "${NODE_FILE}"
  : > "${ENDPOINT_FILE}"
  : > "${CREDS_FILE}"
  chmod 0600 "${NODE_FILE}" "${ENDPOINT_FILE}" "${CREDS_FILE}"
  NODE_USERS=()
  NODE_PASSWORDS=()

  local count="${#IPS[@]}"
  local idx ip port username password
  for ((idx = 0; idx < count; idx++)); do
    ip="${IPS[$idx]}"
    if [[ "${PORT_MODE}" == "same" ]]; then
      port="${PORT}"
    else
      port=$((PORT_START + idx))
      if (( port > 65535 )); then
        die "Port range exceeds 65535. Lower --count or --port-start."
      fi
    fi

    if [[ "${AUTH_MODE}" == "shared" ]]; then
      username="${USERNAME}"
      password="${PASSWORD}"
    else
      username="${USER_PREFIX}${idx}_$(rand_alnum 6)"
      password="$(rand_alnum 18)"
    fi

    NODE_USERS+=("${username}")
    NODE_PASSWORDS+=("${password}")

    printf '%s,%s,%s,%s\n' "${ip}" "${port}" "${username}" "${password}" >> "${NODE_FILE}"
    printf 'socks5://%s:%s@%s:%s\n' "${username}" "${password}" "${ip}" "${port}" >> "${ENDPOINT_FILE}"
    printf '%s %s %s %s\n' "${ip}" "${port}" "${username}" "${password}" >> "${CREDS_FILE}"
  done
}

write_config() {
  install -d -m 0755 "${CFG_DIR}" "${LOG_DIR}"

  {
    cat <<'EOF'
# Generated by 3proxy_socks5_oneclick.sh
nserver 1.1.1.1
nserver 8.8.8.8
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
log /var/log/3proxy/3proxy.log
rotate 30
auth strong
EOF

    if [[ "${AUTH_MODE}" == "shared" ]]; then
      printf 'users %s:CL:%s\n' "${USERNAME}" "${PASSWORD}"
    fi

    local idx count ip port username password
    count="${#IPS[@]}"
    for ((idx = 0; idx < count; idx++)); do
      ip="${IPS[$idx]}"
      if [[ "${PORT_MODE}" == "same" ]]; then
        port="${PORT}"
      else
        port=$((PORT_START + idx))
      fi

      if [[ "${AUTH_MODE}" == "per-node" ]]; then
        username="${NODE_USERS[$idx]}"
        password="${NODE_PASSWORDS[$idx]}"
        printf 'users %s:CL:%s\n' "${username}" "${password}"
      else
        username="${USERNAME}"
      fi

      printf 'internal %s\n' "${ip}"
      printf 'external %s\n' "${ip}"
      printf 'allow %s\n' "${username}"
      printf 'socks -p%s\n' "${port}"
      printf 'flush\n'
    done
  } > "${CFG_FILE}"

  chmod 0600 "${CFG_FILE}"
}

write_service() {
  cat > "${UNIT_FILE}" <<EOF
[Unit]
Description=3proxy SOCKS5 pool
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/3proxy ${CFG_FILE}
Restart=always
RestartSec=3
LimitNOFILE=65536
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
}

open_firewall() {
  [[ "${OPEN_FIREWALL}" -eq 1 ]] || return 0

  local start_port end_port
  if [[ "${PORT_MODE}" == "same" ]]; then
    start_port="${PORT}"
    end_port="${PORT}"
  else
    start_port="${PORT_START}"
    end_port="$((PORT_START + ${#IPS[@]} - 1))"
  fi

  if command -v ufw >/dev/null 2>&1; then
    if ufw status 2>/dev/null | grep -qi '^Status: active'; then
      log "Opening ports in ufw..."
      if [[ "${PORT_MODE}" == "same" ]]; then
        ufw --force allow "${start_port}/tcp"
      else
        ufw --force allow "${start_port}:${end_port}/tcp"
      fi
      return 0
    fi
  fi

  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    log "Opening ports in firewalld..."
    if [[ "${PORT_MODE}" == "same" ]]; then
      firewall-cmd --permanent --add-port="${start_port}/tcp" >/dev/null
      firewall-cmd --add-port="${start_port}/tcp" >/dev/null
    else
      firewall-cmd --permanent --add-port="${start_port}-${end_port}/tcp" >/dev/null
      firewall-cmd --add-port="${start_port}-${end_port}/tcp" >/dev/null
    fi
    firewall-cmd --reload >/dev/null
    return 0
  fi

  if command -v iptables >/dev/null 2>&1; then
    log "Adding best-effort iptables accept rule..."
    if [[ "${PORT_MODE}" == "same" ]]; then
      iptables -C INPUT -p tcp --dport "${start_port}" -j ACCEPT 2>/dev/null || \
        iptables -I INPUT 1 -p tcp --dport "${start_port}" -j ACCEPT
    else
      iptables -C INPUT -p tcp --dport "${start_port}:${end_port}" -j ACCEPT 2>/dev/null || \
        iptables -I INPUT 1 -p tcp --dport "${start_port}:${end_port}" -j ACCEPT
    fi
    return 0
  fi

  warn "No active ufw/firewalld/iptables manager detected. Open the ports manually if needed."
}

start_service() {
  systemctl daemon-reload
  systemctl enable --now "${SERVICE_NAME}"
}

main() {
  while (($#)); do
    case "$1" in
      --count)
        COUNT="${2:-}"
        shift 2
        ;;
      --ips-file)
        IPS_FILE="${2:-}"
        shift 2
        ;;
      --auth-mode)
        AUTH_MODE="${2:-}"
        shift 2
        ;;
      --username)
        USERNAME="${2:-}"
        shift 2
        ;;
      --password)
        PASSWORD="${2:-}"
        shift 2
        ;;
      --user-prefix)
        USER_PREFIX="${2:-}"
        shift 2
        ;;
      --port-mode)
        PORT_MODE="${2:-}"
        shift 2
        ;;
      --port)
        PORT="${2:-}"
        shift 2
        ;;
      --port-start)
        PORT_START="${2:-}"
        shift 2
        ;;
      --no-firewall)
        OPEN_FIREWALL=0
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done

  require_root
  check_os
  validate_args
  apt_install_deps
  build_3proxy
  read_ips
  choose_credentials
  generate_nodes
  write_config
  write_service
  open_firewall
  start_service

  log "Installation complete."
  log "Config: ${CFG_FILE}"
  log "Service: ${SERVICE_NAME}"
  log "Nodes: ${NODE_FILE}"
  log "Endpoints: ${ENDPOINT_FILE}"
  log "Credentials: ${CREDS_FILE}"
  printf '\nFirst few endpoints:\n'
  head -n 5 "${ENDPOINT_FILE}" || true
}

main "$@"

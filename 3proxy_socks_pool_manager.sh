#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

APP_NAME="3proxy SOCKS5 单进程池管理器"
REPO_URL="https://github.com/3proxy/3proxy.git"
REPO_BRANCH="master"
SRC_DIR="/usr/local/src/3proxy-src"
PREFIX="/usr/local"
BIN_PATH="/usr/local/bin/3proxy"

BASE_DIR="/etc/3proxy"
MAIN_CFG="/etc/3proxy/3proxy.cfg"
NODE_INDEX="/etc/3proxy/nodes.tsv"
USERS_FILE="/etc/3proxy/users.passwd"
LOG_DIR="/var/log/3proxy"
MAIN_UNIT="3proxy.service"
MAIN_SERVICE_FILE="/etc/systemd/system/3proxy.service"
SCRIPT_INSTALL_PATH="/usr/local/bin/3proxy_socks_pool_manager.sh"
LAUNCHER_PATH="/usr/local/bin/sk5"

FIREWALL_NFT_HELPER="/usr/local/bin/3proxy-firewall-sync"
FIREWALL_NFT_SERVICE="/etc/systemd/system/3proxy-firewall.service"

DEPS=(
  git
  curl
  ca-certificates
  build-essential
  cmake
  pkg-config
  libssl-dev
  libpcre2-dev
  libpam0g-dev
  iproute2
  iptables
  nftables
  python3
)

log() {
  printf '[信息] %s\n' "$*" >&2
}

warn() {
  printf '[警告] %s\n' "$*" >&2
}

die() {
  printf '[错误] %s\n' "$*" >&2
  exit 1
}

pause() {
  read -r -p "按回车键继续..." _
}

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    die "请使用 root 身份运行此脚本。"
  fi
}

require_3proxy_installed() {
  [[ -x "$BIN_PATH" ]] || die "请先使用菜单 1 安装 3proxy。"
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

version_ge() {
  local left="$1"
  local right="$2"
  [[ "$(printf '%s\n%s\n' "$right" "$left" | sort -V | head -n1)" == "$right" ]]
}

detect_os() {
  [[ -r /etc/os-release ]] || die "无法读取 /etc/os-release。"
  # shellcheck disable=SC1091
  . /etc/os-release

  case "${ID:-}" in
    debian)
      version_ge "${VERSION_ID:-0}" "11" || die "仅支持 Debian 11 - 13。"
      ;;
    ubuntu)
      version_ge "${VERSION_ID:-0}" "22.04" || die "仅支持 Ubuntu 22.04 及以上。"
      ;;
    *)
      die "当前系统 ${ID:-unknown} 不在支持范围内，仅支持 Debian / Ubuntu。"
      ;;
  esac
}

install_dependencies() {
  log "正在检查依赖环境..."
  local missing=()
  local pkg
  for pkg in "${DEPS[@]}"; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
      missing+=("$pkg")
    fi
  done

  if ((${#missing[@]} == 0)); then
    log "依赖已全部安装。"
    return 0
  fi

  log "正在安装缺失依赖：${missing[*]}"
  apt-get update
  apt-get install -y "${missing[@]}"
}

ensure_service_user() {
  if ! getent group 3proxy >/dev/null 2>&1; then
    groupadd --system 3proxy
  fi

  if ! id -u 3proxy >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin --gid 3proxy 3proxy
  fi
}

ensure_dirs() {
  install -d -m 0750 -o root -g 3proxy "$BASE_DIR"
  install -d -m 0750 -o 3proxy -g 3proxy "$LOG_DIR"

  touch "$NODE_INDEX" "$USERS_FILE"
  chown root:3proxy "$NODE_INDEX" "$USERS_FILE"
  chmod 0640 "$NODE_INDEX" "$USERS_FILE"
}

install_self_and_launcher() {
  local source_file="${BASH_SOURCE[0]-}"
  if [[ -n "$source_file" && -f "$source_file" && -r "$source_file" ]]; then
    install -m 0755 "$source_file" "$SCRIPT_INSTALL_PATH"
  fi

  cat >"$LAUNCHER_PATH" <<EOF
#!/usr/bin/env bash
exec "$SCRIPT_INSTALL_PATH" "\$@"
EOF
  chmod 0755 "$LAUNCHER_PATH"
  ln -sfn "$LAUNCHER_PATH" /usr/bin/sk5
}

write_main_systemd_service() {
  cat >"$MAIN_SERVICE_FILE" <<EOF
[Unit]
Description=3proxy SOCKS5 pool
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=3proxy
Group=3proxy
ExecStart=$BIN_PATH $MAIN_CFG
ExecReload=/bin/kill -USR1 \$MAINPID
Restart=on-failure
RestartSec=2
LimitNOFILE=65536
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
}

build_3proxy() {
  log "正在拉取 3proxy 源码..."
  if [[ -d "$SRC_DIR/.git" ]]; then
    git -C "$SRC_DIR" fetch --depth 1 origin "$REPO_BRANCH"
    git -C "$SRC_DIR" reset --hard "origin/${REPO_BRANCH}"
  else
    rm -rf "$SRC_DIR"
    git clone --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$SRC_DIR"
  fi

  log "正在编译并安装 3proxy..."
  cmake -S "$SRC_DIR" -B "$SRC_DIR/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX"
  cmake --build "$SRC_DIR/build" -j"$(nproc)"
  cmake --install "$SRC_DIR/build"

  [[ -x "$BIN_PATH" ]] || die "3proxy 安装失败。"
}

random_alnum() {
  local length="${1:-12}"
  python3 - "$length" <<'PY'
import secrets
import string
import sys

n = int(sys.argv[1])
alphabet = string.ascii_letters + string.digits
print(''.join(secrets.choice(alphabet) for _ in range(n)))
PY
}

expand_path() {
  local path="$1"
  if [[ "$path" == "~" ]]; then
    printf '%s\n' "$HOME"
  elif [[ "${path:0:2}" == "~/" ]]; then
    printf '%s/%s\n' "$HOME" "${path:2}"
  else
    printf '%s\n' "$path"
  fi
}

validate_ipv4() {
  local ip="$1"
  python3 - "$ip" <<'PY'
import ipaddress
import sys

addr = ipaddress.ip_address(sys.argv[1])
if addr.version != 4:
    raise SystemExit(1)
PY
}

ip_is_local() {
  local ip="$1"
  ip -o -4 addr show | awk -v ip="$ip" '
    $4 !~ /^127\./ {
      split($4, a, "/")
      if (a[1] == ip) found = 1
    }
    END { exit(found ? 0 : 1) }
  '
}

discover_local_ipv4s() {
  ip -o -4 addr show | awk '
    $4 !~ /^127\./ {
      split($4, a, "/")
      print a[1]
    }
  ' | sort -V -u
}

discover_local_ipv4s_by_interfaces() {
  local iface_csv="$1"
  local tmp
  tmp="$(mktemp)"

  local normalized="${iface_csv// /}"
  local -a ifaces=()
  IFS=',' read -r -a ifaces <<<"$normalized"

  local iface
  for iface in "${ifaces[@]}"; do
    [[ -n "$iface" ]] || continue
    if ! ip link show "$iface" >/dev/null 2>&1; then
      warn "网卡不存在，已跳过：$iface"
      continue
    fi
    ip -o -4 addr show dev "$iface" | awk '
      $4 !~ /^127\./ {
        split($4, a, "/")
        print a[1]
      }
    ' >>"$tmp"
  done

  sort -V -u "$tmp"
  rm -f "$tmp"
}

filter_ips_by_cidrs() {
  local cidr_list="$1"
  local tmp_ips
  tmp_ips="$(mktemp)"
  discover_local_ipv4s >"$tmp_ips"

  python3 - "$cidr_list" "$tmp_ips" <<'PY'
import ipaddress
import sys

cidrs = [item.strip() for item in sys.argv[1].split(',') if item.strip()]
with open(sys.argv[2], 'r', encoding='utf-8') as fh:
    ips = [line.strip() for line in fh if line.strip()]

if not cidrs:
    print('\n'.join(ips))
    raise SystemExit(0)

nets = [ipaddress.ip_network(item, strict=False) for item in cidrs]
for ip in ips:
    addr = ipaddress.ip_address(ip)
    if any(addr in net for net in nets):
        print(ip)
PY

  rm -f "$tmp_ips"
}

import_ipv4s_from_file() {
  local file_path="$1"
  file_path="$(expand_path "$file_path")"
  [[ -r "$file_path" ]] || die "无法读取 IP 文件：$file_path"

  python3 - "$file_path" <<'PY'
import ipaddress
import re
import sys

seen = set()
with open(sys.argv[1], 'r', encoding='utf-8') as fh:
    for raw in fh:
        line = raw.split('#', 1)[0].strip()
        if not line:
            continue
        for token in re.split(r'[\s,]+', line):
            if not token:
                continue
            try:
                addr = ipaddress.ip_address(token)
            except ValueError:
                print(f'跳过无效 IP: {token}', file=sys.stderr)
                continue
            if addr.version == 4 and token not in seen:
                seen.add(token)
                print(token)
PY
}

slug_from_ip_port() {
  local ip="$1"
  local port="$2"
  printf 'node-%s-%s' "$ip" "$port" | tr -cs 'A-Za-z0-9' '-'
}

list_node_records() {
  [[ -s "$NODE_INDEX" ]] || return 0
  awk -F'\t' 'NF >= 6 { print }' "$NODE_INDEX"
}

node_record_by_index() {
  local target_index="$1"
  list_node_records | awk -F'\t' -v target="$target_index" '
    NF >= 6 {
      count++
      if (count == target) {
        print
        exit
      }
    }
  '
}

node_exists() {
  local ip="$1"
  local port="$2"
  list_node_records | awk -F'\t' -v ip="$ip" -v port="$port" '
    $2 == ip && $3 == port { found = 1 }
    END { exit(found ? 0 : 1) }
  '
}

username_exists() {
  local username="$1"
  list_node_records | awk -F'\t' -v user="$username" '
    $4 == user { found = 1 }
    END { exit(found ? 0 : 1) }
  '
}

append_node_record() {
  local slug="$1"
  local ip="$2"
  local port="$3"
  local username="$4"
  local password="$5"
  local created
  created="$(date +%F\ %T)"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$slug" "$ip" "$port" "$username" "$password" "$created" >>"$NODE_INDEX"
}

remove_node_record() {
  local slug="$1"
  local tmp
  tmp="$(mktemp)"
  awk -F'\t' -v slug="$slug" 'BEGIN { OFS="\t" } $1 != slug { print }' "$NODE_INDEX" >"$tmp"
  cat "$tmp" >"$NODE_INDEX"
  rm -f "$tmp"
}

rebuild_users_file() {
  ensure_dirs
  local tmp
  tmp="$(mktemp)"
  list_node_records | awk -F'\t' 'NF >= 5 && $4 != "" && !seen[$4]++ { print $4 ":CL:" $5 }' >"$tmp"
  : >"$USERS_FILE"
  cat "$tmp" >"$USERS_FILE"
  rm -f "$tmp"
  chown root:3proxy "$USERS_FILE" "$NODE_INDEX"
  chmod 0640 "$USERS_FILE" "$NODE_INDEX"
}

write_main_config() {
  ensure_dirs
  rebuild_users_file

  local tmp
  tmp="$(mktemp)"
  cat >"$tmp" <<EOF
# 由 $APP_NAME 自动生成
# 生成时间: $(date +%F\ %T)

nserver 1.1.1.1
nserver 8.8.8.8
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
auth strong
users \$$USERS_FILE
rotate 30
maxconn 1024

EOF

  local slug ip port username password created
  while IFS=$'\t' read -r slug ip port username password created; do
    [[ -n "${slug:-}" ]] || continue
    cat >>"$tmp" <<EOF
# $slug $ip:$port $username
flush
allow $username * * *
internal $ip
external $ip
log $LOG_DIR/$slug.log D
socks -p$port -i$ip -e$ip

EOF
  done < <(list_node_records)

  install -m 0640 -o root -g 3proxy "$tmp" "$MAIN_CFG"
  rm -f "$tmp"
}

main_service_active() {
  systemctl is-active --quiet "$MAIN_UNIT"
}

restart_main_service() {
  write_main_config
  if [[ ! -s "$NODE_INDEX" ]]; then
    systemctl disable --now "$MAIN_UNIT" >/dev/null 2>&1 || true
    log "当前没有节点，已停止主服务。"
    return 0
  fi

  systemctl daemon-reload
  systemctl enable "$MAIN_UNIT" >/dev/null
  systemctl restart "$MAIN_UNIT"
}

port_is_listening_on_ip() {
  local ip="$1"
  local port="$2"
  ss -ltnH 2>/dev/null | awk -v ip="$ip" -v port="$port" '
    {
      local = $4
      if (local ~ "\\[::\\]:" port "$" || local ~ "\\*:" port "$" || local ~ "0\\.0\\.0\\.0:" port "$") {
        found = 1
      }
      if (local == ip ":" port) {
        found = 1
      }
    }
    END { exit(found ? 0 : 1) }
  '
}

addr_port_in_use() {
  local ip="$1"
  local port="$2"
  ss -ltnH 2>/dev/null | awk -v ip="$ip" -v port="$port" '
    {
      local = $4
      if (local ~ "\\[::\\]:" port "$" || local ~ "\\*:" port "$" || local ~ "0\\.0\\.0\\.0:" port "$") {
        found = 1
      }
      if (local == ip ":" port) {
        found = 1
      }
    }
    END { exit(found ? 0 : 1) }
  '
}

random_unique_username() {
  local candidate
  while true; do
    candidate="u$(random_alnum 10)"
    if ! username_exists "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
}

random_password() {
  random_alnum 16
}

preview_ips() {
  local -a ips=("$@")
  local total="${#ips[@]}"
  printf '已选择 %d 个 IP。\n' "$total"
  local limit=20
  local i
  for ((i = 0; i < total && i < limit; i++)); do
    printf '  %s\n' "${ips[$i]}"
  done
  if ((total > limit)); then
    printf '  ... 还有 %d 个未显示。\n' "$((total - limit))"
  fi
}

prompt_credentials_mode() {
  local mode username password
  printf '\n====== 账号模式选择 ======\n' >&2
  printf '1) 所有节点使用同一组账号密码\n' >&2
  printf '2) 每个节点随机账号密码\n' >&2
  printf '说明：\n' >&2
  printf '  - 选 1 时，所有节点共享同一套用户名和密码。\n' >&2
  printf '  - 选 2 时，每个节点都会生成单独账号。\n' >&2
  printf '\n' >&2
  read -r -p "请选择账号模式：" mode
  mode="${mode:-1}"

  case "$mode" in
    1)
      printf '\n'
      read -r -p "请输入统一用户名（留空自动生成）：" username
      if [[ -z "$username" ]]; then
        username="$(random_unique_username)"
        log "已自动生成统一用户名：$username"
      fi
      [[ "$username" =~ ^[A-Za-z0-9._-]+$ ]] || die "用户名仅允许字母、数字、点、下划线和横线。"
      if username_exists "$username"; then
        die "该用户名已存在，请换一个。"
      fi

      read -r -p "请输入统一密码（留空自动生成）：" password
      if [[ -z "$password" ]]; then
        password="$(random_password)"
        log "已自动生成统一密码：$password"
      fi
      [[ "$password" != *:* && "$password" != *[[:space:]]* ]] || die "密码中不能包含冒号或空白字符。"
      printf '[信息] 账号模式：所有节点共用同一组账号密码\n' >&2
      printf 'shared\t%s\t%s\n' "$username" "$password"
      ;;
    2)
      printf '[信息] 账号模式：每个节点单独生成随机账号密码\n' >&2
      printf 'random\t\t\n'
      ;;
    *)
      die "账号模式选择无效。"
      ;;
  esac
}

prompt_port_mode() {
  local mode port
  printf '\n====== 端口模式选择 ======\n' >&2
  printf '1) 所有 IP 使用同一个端口（推荐站群场景）\n' >&2
  printf '2) 从起始端口开始递增\n' >&2
  printf '说明：\n' >&2
  printf '  - 选 1 时，每个 IP 都监听同一个端口。\n' >&2
  printf '  - 选 2 时，从起始端口开始依次递增。\n' >&2
  printf '\n' >&2
  read -r -p "请选择端口模式：" mode
  mode="${mode:-1}"

  case "$mode" in
    1)
      printf '\n'
      read -r -p "请输入监听端口 [20000]：" port
      port="${port:-20000}"
      [[ "$port" =~ ^[0-9]+$ ]] || die "端口必须是数字。"
      ((port >= 1 && port <= 65535)) || die "端口超出范围。"
      printf '[信息] 端口模式：所有 IP 共用同一个端口 %s\n' "$port" >&2
      printf 'same\t%s\n' "$port"
      ;;
    2)
      printf '\n'
      read -r -p "请输入起始端口 [20000]：" port
      port="${port:-20000}"
      [[ "$port" =~ ^[0-9]+$ ]] || die "起始端口必须是数字。"
      ((port >= 1 && port <= 65535)) || die "起始端口超出范围。"
      printf '[信息] 端口模式：从 %s 开始递增分配端口\n' "$port" >&2
      printf 'increment\t%s\n' "$port"
      ;;
    *)
      die "端口模式选择无效。"
      ;;
  esac
}

firewall_backend() {
  if has_cmd ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
    printf 'ufw\n'
  elif has_cmd firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
    printf 'firewalld\n'
  elif has_cmd nft && nft list chain inet filter input >/dev/null 2>&1; then
    printf 'nft\n'
  elif has_cmd iptables; then
    printf 'iptables\n'
  else
    printf 'none\n'
  fi
}

current_ports() {
  list_node_records | awk -F'\t' 'NF >= 3 && $3 ~ /^[0-9]+$/ { print $3 }' | sort -n -u
}

ensure_nft_firewall_helper() {
  has_cmd nft || return 1

  cat >"$FIREWALL_NFT_HELPER" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

INDEX_FILE="/etc/3proxy/nodes.tsv"

if ! nft list chain inet filter input >/dev/null 2>&1; then
  echo "nftables 未找到 inet filter input 链，跳过自动放行。" >&2
  exit 0
fi

awk -F'\t' 'NF >= 3 && $3 ~ /^[0-9]+$/ { print $3 }' "$INDEX_FILE" 2>/dev/null \
  | sort -n -u \
  | while read -r port; do
      if nft list chain inet filter input 2>/dev/null | grep -Eq "tcp dport ${port} .*accept"; then
        continue
      fi
      nft add rule inet filter input tcp dport "$port" accept comment "3proxy"
    done
EOF

  chmod 0755 "$FIREWALL_NFT_HELPER"
  cat >"$FIREWALL_NFT_SERVICE" <<EOF
[Unit]
Description=3proxy nftables 防火墙同步
Before=network-pre.target
Wants=network-pre.target
DefaultDependencies=no

[Service]
Type=oneshot
ExecStart=$FIREWALL_NFT_HELPER
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "$(basename "$FIREWALL_NFT_SERVICE")" >/dev/null 2>&1 || true
  systemctl start "$(basename "$FIREWALL_NFT_SERVICE")" >/dev/null 2>&1 || true
}

sync_nft_firewall_rules() {
  ensure_nft_firewall_helper || return 1
  "$FIREWALL_NFT_HELPER"
}

ensure_firewall_port_open() {
  local port="$1"
  local backend
  backend="$(firewall_backend)"

  case "$backend" in
    ufw)
      ufw allow "${port}/tcp" >/dev/null || return 1
      ;;
    firewalld)
      firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null || return 1
      firewall-cmd --reload >/dev/null || return 1
      ;;
    nft)
      sync_nft_firewall_rules || return 1
      ;;
    iptables)
      if ! iptables -C INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1; then
        iptables -I INPUT -p tcp --dport "$port" -j ACCEPT || return 1
      fi
      if has_cmd netfilter-persistent; then
        netfilter-persistent save >/dev/null 2>&1 || true
      fi
      ;;
    *)
      warn "未检测到常见防火墙管理工具，已跳过端口放行：${port}"
      ;;
  esac
}

sync_firewall_ports() {
  local port
  while read -r port; do
    [[ -n "$port" ]] || continue
    ensure_firewall_port_open "$port" || warn "端口放行失败：$port"
  done < <(current_ports)
}

create_nodes_from_ips() {
  require_root
  require_3proxy_installed

  local -a ips=("$@")
  ((${#ips[@]} > 0)) || die "没有找到符合条件的 IP。"

  printf '\n====== 批量生成向导 ======\n'
  preview_ips "${ips[@]}"
  printf '\n'
  read -r -p "是否继续生成这些节点？[Y/N]：" confirm
  if [[ "${confirm:-Y}" =~ ^[Nn]$ ]]; then
    die "已取消。"
  fi

  local port_pair port_mode base_port
  port_pair="$(prompt_port_mode)"
  port_mode="${port_pair%%$'\t'*}"
  base_port="${port_pair#*$'\t'}"

  local cred_pair cred_mode shared_user shared_pass
  cred_pair="$(prompt_credentials_mode)"
  cred_mode="${cred_pair%%$'\t'*}"
  shared_user="$(printf '%s' "$cred_pair" | awk -F'\t' '{ print $2 }')"
  shared_pass="$(printf '%s' "$cred_pair" | awk -F'\t' '{ print $3 }')"

  printf '\n[信息] 开始生成节点：%d 个 IP\n' "${#ips[@]}"
  if [[ "$port_mode" == "same" ]]; then
    printf '[信息] 端口策略：所有 IP 使用同一个端口 %s\n' "$base_port"
  else
    printf '[信息] 端口策略：从 %s 开始递增\n' "$base_port"
  fi
  if [[ "$cred_mode" == "shared" ]]; then
    printf '[信息] 账号策略：所有节点共享同一组账号密码\n'
  else
    printf '[信息] 账号策略：每个节点单独随机账号密码\n'
  fi
  printf '[信息] 即将开始写入节点与主配置\n'
  printf '\n'

  local success=0 failed=0 idx ip port username password slug
  local -a added_slugs=()

  for idx in "${!ips[@]}"; do
    ip="${ips[$idx]}"
    validate_ipv4 "$ip" || {
      warn "IP 无效，跳过：$ip"
      failed=$((failed + 1))
      continue
    }

    if ! ip_is_local "$ip"; then
      warn "IP 未绑定到本机网卡，跳过：$ip"
      failed=$((failed + 1))
      continue
    fi

    if [[ "$port_mode" == "same" ]]; then
      port="$base_port"
    else
      port=$((base_port + idx))
    fi

    if ((port > 65535)); then
      warn "端口超过 65535，跳过：$ip"
      failed=$((failed + 1))
      continue
    fi

    if node_exists "$ip" "$port"; then
      warn "节点已存在，跳过：$ip:$port"
      failed=$((failed + 1))
      continue
    fi

    if addr_port_in_use "$ip" "$port"; then
      warn "地址端口已被占用，跳过：$ip:$port"
      failed=$((failed + 1))
      continue
    fi

    if [[ "$cred_mode" == "shared" ]]; then
      username="$shared_user"
      password="$shared_pass"
    else
      username="$(random_unique_username)"
      password="$(random_password)"
    fi

    slug="$(slug_from_ip_port "$ip" "$port")"
    append_node_record "$slug" "$ip" "$port" "$username" "$password"
    added_slugs+=("$slug")
    success=$((success + 1))
  done

  if ((success == 0)); then
    die "没有成功创建任何节点。"
  fi

  sync_firewall_ports

  if ! restart_main_service; then
    warn "主服务启动失败，正在回滚本次新增节点。"
    for slug in "${added_slugs[@]}"; do
      remove_node_record "$slug"
    done
    restart_main_service || true
    die "本次新增已回滚，请查看 journalctl -u $MAIN_UNIT。"
  fi

  printf '\n批量生成完成：成功 %d 个，失败 %d 个。\n' "$success" "$failed"
}

batch_create_nodes() {
  require_root
  require_3proxy_installed

  printf '\n====== 批量生成向导 ======\n'
  printf '这一步先决定节点来源，后面再决定端口和账号策略。\n'
  printf '\n'
  printf '1) 自动发现本机全部 IPv4\n'
  printf '2) 按网卡名称筛选\n'
  printf '3) 按 CIDR/IP 段筛选\n'
  printf '4) 从 IP 文件导入\n'
  read -r -p "请选择来源：" source_mode

  local -a ips=()
  case "$source_mode" in
    1)
      printf '[信息] 已选择：自动发现本机全部 IPv4\n'
      mapfile -t ips < <(discover_local_ipv4s)
      ;;
    2)
      printf '[信息] 已选择：按网卡名称筛选\n'
      read -r -p "请输入网卡名称，多个用英文逗号分隔（留空表示全部）：" ifaces
      if [[ -z "${ifaces// /}" ]]; then
        mapfile -t ips < <(discover_local_ipv4s)
      else
        mapfile -t ips < <(discover_local_ipv4s_by_interfaces "$ifaces")
      fi
      ;;
    3)
      printf '[信息] 已选择：按 CIDR/IP 段筛选\n'
      read -r -p "请输入 CIDR / IP 段，多个用英文逗号分隔（留空表示全部）：" cidrs
      mapfile -t ips < <(filter_ips_by_cidrs "$cidrs")
      ;;
    4)
      printf '[信息] 已选择：从 IP 文件导入\n'
      read -r -p "请输入 IP 文件路径：" ip_file
      mapfile -t ips < <(import_ipv4s_from_file "$ip_file")
      ;;
    *)
      die "来源选择无效。"
      ;;
  esac

  create_nodes_from_ips "${ips[@]}"
}

print_node_table() {
  local records
  records="$(list_node_records)"
  if [[ -z "$records" ]]; then
    printf '当前没有已生成的节点。\n'
    return 1
  fi

  local service_state="未运行"
  if main_service_active; then
    service_state="运行中"
  elif systemctl is-failed --quiet "$MAIN_UNIT" 2>/dev/null; then
    service_state="失败"
  fi

  printf '%-4s %-26s %-16s %-8s %-18s %-12s %-10s\n' "序号" "节点标识" "IP" "端口" "用户名" "主服务" "监听"
  printf '%s\n' "------------------------------------------------------------------------------------------------"

  local no=1 slug ip port username password created listen_state
  while IFS=$'\t' read -r slug ip port username password created; do
    [[ -n "${slug:-}" ]] || continue
    if port_is_listening_on_ip "$ip" "$port"; then
      listen_state="是"
    else
      listen_state="否"
    fi

    printf '%-4s %-26s %-16s %-8s %-18s %-12s %-10s\n' \
      "$no" "$slug" "$ip" "$port" "$username" "$service_state" "$listen_state"
    no=$((no + 1))
  done <<<"$records"
}

delete_nodes_by_ip() {
  require_root
  local target_ip="$1"
  validate_ipv4 "$target_ip" || die "IP 地址无效或不是 IPv4：$target_ip"

  local records
  records="$(list_node_records)"
  [[ -n "$records" ]] || die "当前没有可删除的节点。"

  local -a matches=()
  local slug ip port username password created
  while IFS=$'\t' read -r slug ip port username password created; do
    [[ -n "${slug:-}" ]] || continue
    [[ "$ip" == "$target_ip" ]] || continue
    matches+=("$slug|$ip|$port|$username|$created")
  done <<<"$records"

  if ((${#matches[@]} == 0)); then
    warn "没有找到 IP 为 $target_ip 的节点。"
    return 0
  fi

  printf '\n====== 删除确认 ======\n'
  printf '本次准备删除的 IP：%s\n' "$target_ip"
  printf '匹配到 %d 个节点：\n' "${#matches[@]}"
  local item
  for item in "${matches[@]}"; do
    IFS='|' read -r slug ip port username created <<<"$item"
    printf '  %s  [%s:%s]  用户:%s  创建:%s\n' "$slug" "$ip" "$port" "$username" "$created"
  done

  printf '\n'
  read -r -p "确认删除这些节点吗？输入 y 继续，其他键取消：" answer
  [[ "${answer:-N}" =~ ^[Yy]$ ]] || die "已取消。"

  for item in "${matches[@]}"; do
    IFS='|' read -r slug ip port username created <<<"$item"
    remove_node_record "$slug"
  done

  if [[ "$(firewall_backend)" == "nft" ]]; then
    sync_nft_firewall_rules || true
  fi
  restart_main_service
  log "已删除 IP 为 $target_ip 的 ${#matches[@]} 个节点。"
}

delete_node_by_index() {
  require_root
  local target_index="$1"
  [[ "$target_index" =~ ^[0-9]+$ ]] || die "序号必须是数字。"

  local record
  record="$(node_record_by_index "$target_index")"
  [[ -n "$record" ]] || die "没有找到序号为 $target_index 的节点。"

  local slug ip port username password created
  IFS=$'\t' read -r slug ip port username password created <<<"$record"

  printf '\n====== 删除确认 ======\n'
  printf '序号：%s\n' "$target_index"
  printf '节点：%s\n' "$slug"
  printf '地址：%s:%s\n' "$ip" "$port"
  printf '用户名：%s\n' "$username"
  printf '创建时间：%s\n' "$created"
  printf '\n'
  read -r -p "确认删除这个节点吗？输入 y 继续，其他键取消：" answer
  [[ "${answer:-N}" =~ ^[Yy]$ ]] || die "已取消。"

  remove_node_record "$slug"

  if [[ "$(firewall_backend)" == "nft" ]]; then
    sync_nft_firewall_rules || true
  fi
  restart_main_service
  log "已删除序号为 $target_index 的节点。"
}

list_nodes() {
  printf '\n====== 节点列表 ======\n'
  print_node_table || return 0

  printf '\n'
  printf '说明：你可以输入序号删除单个节点，或输入 IP 删除该 IP 对应的所有节点；直接回车返回主菜单。\n'
  read -r -p "请输入要删除的序号或 IP：" delete_key
  delete_key="${delete_key// /}"
  [[ -z "$delete_key" ]] && return 0

  if [[ "$delete_key" =~ ^[0-9]+$ ]]; then
    delete_node_by_index "$delete_key"
  else
    delete_nodes_by_ip "$delete_key"
  fi
}

show_status() {
  require_root
  if has_cmd script; then
    script -qec "env TERM=xterm-256color SYSTEMD_COLORS=1 systemctl status '$MAIN_UNIT' --no-pager -l" /dev/null 2>/dev/null || true
  else
    TERM=xterm-256color SYSTEMD_COLORS=1 systemctl status "$MAIN_UNIT" --no-pager -l 2>/dev/null || true
  fi
}

show_logs() {
  require_root
  local records
  records="$(list_node_records)"
  [[ -n "$records" ]] || die "当前没有节点。"

  printf '\n====== 日志查看 ======\n'
  printf '\n====== 主服务最近日志 ======\n'
  journalctl -u "$MAIN_UNIT" -n 60 --no-pager 2>/dev/null || true

  printf '\n====== 节点文件日志 ======\n'
  local slug ip port username password created log_file
  while IFS=$'\t' read -r slug ip port username password created; do
    [[ -n "${slug:-}" ]] || continue
    log_file="$LOG_DIR/$slug.log"
    printf '\n[%s] %s:%s 用户:%s\n' "$slug" "$ip" "$port" "$username"
    if [[ -f "$log_file" ]]; then
      tail -n 20 "$log_file" 2>/dev/null || true
    else
      printf '暂无文件日志。\n'
    fi
  done <<<"$records"
}

export_proxy_list() {
  require_root
  local records
  records="$(list_node_records)"
  [[ -n "$records" ]] || die "当前没有可导出的代理。"

  printf '\n====== 导出格式选择 ======\n' >&2
  printf '1) ip:port:user:pass\n' >&2
  printf '2) socks5://user:pass@ip:port\n' >&2
  printf '说明：\n' >&2
  printf '  - 选 1 时导出原始清单。\n' >&2
  printf '  - 选 2 时导出标准 SOCKS5 URI。\n' >&2
  printf '\n' >&2
  local export_mode
  read -r -p "请选择导出格式：" export_mode
  export_mode="${export_mode:-1}"

  read -r -p "请输入导出路径 [ /root/3proxy_proxy_list.txt ]：" out_path
  out_path="${out_path:-/root/3proxy_proxy_list.txt}"
  out_path="$(expand_path "$out_path")"

  mkdir -p "$(dirname "$out_path")"

  case "$export_mode" in
    1)
      printf '%s\n' "$records" | awk -F'\t' 'NF >= 5 { printf "%s:%s:%s:%s\n", $2, $3, $4, $5 }' >"$out_path"
      ;;
    2)
      printf '%s\n' "$records" | awk -F'\t' 'NF >= 5 { printf "socks5://%s:%s@%s:%s\n", $4, $5, $2, $3 }' >"$out_path"
      ;;
    *)
      die "导出格式选择无效。"
      ;;
  esac

  chmod 0600 "$out_path" || true
  log "代理清单已导出：$out_path"
}

check_proxy_health() {
  require_root
  local records
  records="$(list_node_records)"
  [[ -n "$records" ]] || die "当前没有节点。"

  printf '\n====== 健康检查 ======\n' >&2
  printf '1) 仅检查端口监听\n' >&2
  printf '2) 检查端口监听 + SOCKS 出口连通性\n' >&2
  printf '说明：\n' >&2
  printf '  - 选 1 时只看本机监听状态。\n' >&2
  printf '  - 选 2 时会额外检查代理出口 IP。\n' >&2
  printf '\n' >&2

  local health_mode
  read -r -p "请选择检查模式：" health_mode
  health_mode="${health_mode:-1}"
  case "$health_mode" in
    1)
      printf '[信息] 检查模式：仅检查端口监听\n'
      ;;
    2)
      printf '[信息] 检查模式：端口监听 + SOCKS 出口连通性\n'
      ;;
    *)
      die "健康检查模式无效。"
      ;;
  esac

  printf '\n'

  local total=0 listening_ok=0 proxy_ok=0 proxy_fail=0
  local slug ip port username password created listen_state exit_state exit_ip
  local listen_text proxy_text

  if main_service_active; then
    printf '[总览] 主服务：运行中\n'
  else
    printf '[总览] 主服务：未运行或异常\n'
  fi

  while IFS=$'\t' read -r slug ip port username password created; do
    [[ -n "${slug:-}" ]] || continue
    total=$((total + 1))
    if port_is_listening_on_ip "$ip" "$port"; then
      listen_state="正常"
      listening_ok=$((listening_ok + 1))
    else
      listen_state="异常"
    fi

    exit_state="未检查"
    exit_ip=""
    if [[ "$listen_state" == "正常" && "$health_mode" == "2" ]]; then
      if exit_ip="$(timeout 20 curl -fsS --proxy "socks5h://${username}:${password}@${ip}:${port}" https://api.ipify.org 2>/dev/null)"; then
        exit_ip="${exit_ip//$'\r'/}"
        if [[ -n "$exit_ip" && "$exit_ip" == "$ip" ]]; then
          exit_state="正常"
          proxy_ok=$((proxy_ok + 1))
        elif [[ -n "$exit_ip" ]]; then
          exit_state="不一致:${exit_ip}"
          proxy_fail=$((proxy_fail + 1))
        else
          exit_state="空结果"
          proxy_fail=$((proxy_fail + 1))
        fi
      else
        exit_state="连接失败"
        proxy_fail=$((proxy_fail + 1))
      fi
    fi

    if [[ "$listen_state" == "正常" ]]; then
      listen_text="已监听"
    else
      listen_text="未监听"
    fi

    if [[ "$health_mode" == "2" ]]; then
      proxy_text="$exit_state"
    else
      proxy_text="未检查"
    fi

    printf '%s %s:%s 监听=%s 出口=%s\n' "$slug" "$ip" "$port" "$listen_text" "$proxy_text"
  done <<<"$records"

  printf '\n'
  printf '[汇总] 节点总数：%d\n' "$total"
  printf '[汇总] 端口监听正常：%d\n' "$listening_ok"
  if [[ "$health_mode" == "2" ]]; then
    printf '[汇总] SOCKS 出口正常：%d\n' "$proxy_ok"
    printf '[汇总] SOCKS 出口异常：%d\n' "$proxy_fail"
  fi
}

install_or_upgrade() {
  require_root
  detect_os
  install_dependencies
  ensure_service_user
  ensure_dirs
  install_self_and_launcher
  write_main_systemd_service
  build_3proxy
  write_main_config
  if has_cmd nft; then
    ensure_nft_firewall_helper || true
  fi

  if [[ -s "$NODE_INDEX" ]]; then
    sync_firewall_ports
    restart_main_service
  fi

  cat >&2 <<EOF

安装完成。

下一步建议：
  1. 使用菜单 2 批量生成节点。
  2. 站群机器推荐所有 IP 使用同一个端口，例如 20000。
  3. 使用菜单 3 查看节点列表，并可按 IP 删除。
  4. 使用菜单 5 查看主服务状态和每个 IP 的监听状态。
  5. 使用菜单 6 导出代理清单，格式为 ip:port:user:pass。
  6. 后续可以直接输入 sk5 打开菜单。

主配置：
  $MAIN_CFG

节点索引：
  $NODE_INDEX

账号文件：
  $USERS_FILE
EOF
}

uninstall_all() {
  require_root
  detect_os

  read -r -p "确定要卸载本工具创建的配置、服务、二进制和日志吗？[Y/N]：" answer
  [[ "${answer:-N}" =~ ^[Yy]$ ]] || die "已取消。"

  systemctl disable --now "$MAIN_UNIT" >/dev/null 2>&1 || true
  systemctl disable --now "$(basename "$FIREWALL_NFT_SERVICE")" >/dev/null 2>&1 || true

  rm -f "$MAIN_SERVICE_FILE" "$FIREWALL_NFT_SERVICE" "$FIREWALL_NFT_HELPER"
  rm -f "$MAIN_CFG" "$NODE_INDEX" "$USERS_FILE"
  rm -f "$LAUNCHER_PATH" /usr/bin/sk5 "$SCRIPT_INSTALL_PATH"
  rm -f "$BIN_PATH" /usr/local/bin/3proxy_* /usr/local/bin/add3proxyuser
  rm -rf /usr/local/lib/3proxy /usr/local/share/3proxy "$SRC_DIR"
  rm -rf "$BASE_DIR" "$LOG_DIR"

  if id -u 3proxy >/dev/null 2>&1; then
    userdel 3proxy >/dev/null 2>&1 || true
  fi
  if getent group 3proxy >/dev/null 2>&1; then
    groupdel 3proxy >/dev/null 2>&1 || true
  fi

  systemctl daemon-reload
  log "清理完成。"
}

main_menu() {
  while true; do
    printf '\n%s\n' "========================================" >&2
    printf '%s\n' " $APP_NAME" >&2
    printf '%s\n' "========================================" >&2
    printf '%s\n' "1) 安装 / 升级 3proxy" >&2
    printf '%s\n' "2) 批量生成节点（全量/网卡/CIDR/文件）" >&2
    printf '%s\n' "3) 查看节点列表 / 按 IP 删除" >&2
    printf '%s\n' "4) 重启主 3proxy 服务" >&2
    printf '%s\n' "5) 查看状态（主服务 + 端口监听）" >&2
    printf '%s\n' "6) 导出代理清单" >&2
    printf '%s\n' "7) 健康检查" >&2
    printf '%s\n' "8) 卸载本工具创建的所有内容" >&2
    printf '%s\n' "0) 退出" >&2
    printf '%s\n' "========================================" >&2
    if ! read -r -p "请选择：" choice; then
      printf '\n'
      exit 0
    fi
    choice="${choice//[[:space:]]/}"
    [[ -z "$choice" ]] && continue

    case "$choice" in
      1)
        install_or_upgrade
        return 0
        ;;
      2)
        batch_create_nodes
        pause
        ;;
      3)
        list_nodes
        pause
        ;;
      4)
        require_root
        restart_main_service
        log "主服务已重启。"
        pause
        ;;
      5)
        show_status
        pause
        ;;
      6)
        export_proxy_list
        pause
        ;;
      7)
        check_proxy_health
        pause
        ;;
      8)
        uninstall_all
        pause
        ;;
      0)
        exit 0
        ;;
      *)
        warn "无效选项。"
        pause
        ;;
    esac
  done
}

main() {
  if [[ -e /dev/tty ]]; then
    exec </dev/tty >/dev/tty 2>&1
  fi
  main_menu
}

if [[ "${BASH_SOURCE[0]-}" == "$0" ]]; then
  main "$@"
fi

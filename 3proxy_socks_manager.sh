#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

APP_NAME="3proxy SOCKS5 一键管理器"
REPO_URL="https://github.com/3proxy/3proxy.git"
REPO_BRANCH="master"
SRC_DIR="/usr/local/src/3proxy-src"
PREFIX="/usr/local"
BIN_PATH="/usr/local/bin/3proxy"
INSTALLED_SCRIPT_PATH="/usr/local/bin/3proxy_socks_manager.sh"
BASE_DIR="/etc/3proxy"
NODE_DIR="/etc/3proxy/nodes"
LOG_DIR="/var/log/3proxy"
USERS_MANUAL_FILE="/etc/3proxy/users.manual.passwd"
USERS_FILE="/etc/3proxy/users.passwd"
INDEX_FILE="/etc/3proxy/nodes.tsv"
SYSTEMD_TEMPLATE="/etc/systemd/system/3proxy@.service"
SERVICE_PREFIX="3proxy@"
FIREWALL_NFT_HELPER="/usr/local/bin/3proxy-firewall-sync"
FIREWALL_NFT_SERVICE="/etc/systemd/system/3proxy-firewall.service"

DEPS=(
  "git"
  "curl"
  "ca-certificates"
  "build-essential"
  "cmake"
  "pkg-config"
  "libssl-dev"
  "libpcre2-dev"
  "libpam0g-dev"
  "iproute2"
  "iptables"
  "nftables"
  "python3"
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
  local left right
  left="$1"
  right="$2"
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
    useradd \
      --system \
      --no-create-home \
      --shell /usr/sbin/nologin \
      --gid 3proxy \
      3proxy
  fi
}

ensure_dirs() {
  install -d -m 0750 -o root -g 3proxy "$BASE_DIR"
  install -d -m 0750 -o root -g 3proxy "$NODE_DIR"
  install -d -m 0750 -o 3proxy -g 3proxy "$LOG_DIR"

  touch "$USERS_MANUAL_FILE" "$USERS_FILE" "$INDEX_FILE"
  chown root:3proxy "$USERS_MANUAL_FILE" "$USERS_FILE" "$INDEX_FILE"
  chmod 0640 "$USERS_MANUAL_FILE" "$USERS_FILE" "$INDEX_FILE"
}

install_sk5_launcher() {
  cat >/usr/local/bin/sk5 <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec bash "$INSTALLED_SCRIPT_PATH" "\$@"
EOF
  chmod 0755 /usr/local/bin/sk5
  chmod 0755 "$INSTALLED_SCRIPT_PATH" || true

  cat >/etc/profile.d/3proxy-sk5.sh <<'EOF'
sk5() {
  /usr/local/bin/sk5 "$@"
}
EOF
  chmod 0644 /etc/profile.d/3proxy-sk5.sh
}

install_self_copy() {
  local source_file="${BASH_SOURCE[0]}"
  install -m 0755 "$source_file" "$INSTALLED_SCRIPT_PATH"
}

write_systemd_template() {
  cat >"$SYSTEMD_TEMPLATE" <<'EOF'
[Unit]
Description=3proxy SOCKS5 节点 %i
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=3proxy
Group=3proxy
ExecStart=/usr/local/bin/3proxy /etc/3proxy/nodes/%i.cfg
ExecReload=/bin/kill -USR1 $MAINPID
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

  if ! has_cmd 3proxy; then
    die "3proxy 安装失败。"
  fi
}

prepare_environment() {
  require_root
  detect_os
  install_dependencies
  ensure_service_user
  ensure_dirs
  write_systemd_template
  install_sk5_launcher
  if has_cmd nft; then
    ensure_nft_firewall_helper || true
  fi
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

  if ip -o -4 addr show | awk -v ip="$ip" '
      $4 !~ /^127\./ {
        split($4, a, "/")
        if (a[1] == ip) {
          found = 1
        }
      }
      END { exit(found ? 0 : 1) }
    '; then
    return 0
  fi

  if ip route get "$ip" >/dev/null 2>&1; then
    ip route get "$ip" 2>/dev/null | awk -v ip="$ip" '
      {
        for (i = 1; i <= NF; i++) {
          if ($i == "local" && $(i + 1) == ip) {
            found = 1
          }
          if ($i == "src" && $(i + 1) == ip) {
            found = 1
          }
        }
      }
      END { exit(found ? 0 : 1) }
    ' && return 0
  fi

  return 1
}

discover_local_ipv4s() {
  ip -o -4 addr show | awk '
    $4 !~ /^127\./ {
      split($4, a, "/")
      print a[1]
    }
  ' | sort -u
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

  sort -u "$tmp"
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
if not cidrs:
    with open(sys.argv[2], 'r', encoding='utf-8') as fh:
        for line in fh:
            ip = line.strip()
            if ip:
                print(ip)
    raise SystemExit(0)

nets = [ipaddress.ip_network(item, strict=False) for item in cidrs]
with open(sys.argv[2], 'r', encoding='utf-8') as fh:
    for line in fh:
        ip = line.strip()
        if not ip:
            continue
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

path = sys.argv[1]
seen = set()

with open(path, 'r', encoding='utf-8') as fh:
    for raw in fh:
        line = raw.split('#', 1)[0].strip()
        if not line:
            continue
        for token in re.split(r'[\s,]+', line):
            token = token.strip()
            if not token:
                continue
            try:
                addr = ipaddress.ip_address(token)
            except ValueError:
                print(f'跳过无效 IP: {token}', file=sys.stderr)
                continue
            if addr.version != 4:
                continue
            if token not in seen:
                seen.add(token)
                print(token)
PY
}

preview_ips() {
  local -a ips=("$@")
  local total="${#ips[@]}"
  printf '已选择 %d 个 IP。\n' "$total"
  if (( total == 0 )); then
    return 0
  fi

  local limit=20
  local i
  for ((i = 0; i < total && i < limit; i++)); do
    printf '  %s\n' "${ips[$i]}"
  done
  if (( total > limit )); then
    printf '  ... 还有 %d 个未显示。\n' "$((total - limit))"
  fi
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

slug_from_ip_port() {
  local ip="$1"
  local port="$2"
  printf 'node-%s-%s' "$ip" "$port" | tr -cs 'A-Za-z0-9' '-'
}

node_cfg_path() {
  local slug="$1"
  printf '%s/%s.cfg' "$NODE_DIR" "$slug"
}

service_name() {
  local slug="$1"
  printf '%s%s' "$SERVICE_PREFIX" "$slug"
}

node_service_state() {
  local unit="$1"
  local load_state active_state sub_state result main_pid enabled_state

  load_state="$(systemctl show -p LoadState --value "$unit" 2>/dev/null || printf 'unknown')"
  active_state="$(systemctl show -p ActiveState --value "$unit" 2>/dev/null || printf 'unknown')"
  sub_state="$(systemctl show -p SubState --value "$unit" 2>/dev/null || printf 'unknown')"
  result="$(systemctl show -p Result --value "$unit" 2>/dev/null || printf 'unknown')"
  main_pid="$(systemctl show -p MainPID --value "$unit" 2>/dev/null || printf '0')"
  enabled_state="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
  [[ -n "$enabled_state" ]] || enabled_state="unknown"

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$load_state" \
    "$active_state" \
    "$sub_state" \
    "$result" \
    "$main_pid" \
    "$enabled_state"
}

show_runtime_overview() {
  printf '%s\n' "====== 运行概览 ======"
  if [[ -x "$BIN_PATH" ]]; then
    printf '3proxy 二进制: 已安装 (%s)\n' "$BIN_PATH"
  else
    printf '3proxy 二进制: 未安装 (%s)\n' "$BIN_PATH"
  fi

  if [[ -d "$BASE_DIR" ]]; then
    printf '配置目录: %s\n' "$BASE_DIR"
  else
    printf '配置目录: 不存在 (%s)\n' "$BASE_DIR"
  fi

  local pids
  pids="$(pgrep -af "$BIN_PATH" 2>/dev/null || true)"
  if [[ -n "$pids" ]]; then
    printf '3proxy 进程: 发现运行中的实例\n'
    printf '%s\n' "$pids" | sed 's/^/  /'
  else
    printf '3proxy 进程: 未发现运行中的实例\n'
  fi
}

sync_existing_node_configs() {
  local records
  records="$(list_node_records)"
  if [[ -z "$records" ]]; then
    return 0
  fi

  while IFS=$'\t' read -r slug ip port username password created; do
    [[ -n "${slug:-}" ]] || continue
    write_node_config "$slug" "$ip" "$port" "$username" "$password"
  done <<<"$records"

  systemctl daemon-reload
}

print_node_table() {
  local records
  records="$(list_node_records)"
  if [[ -z "$records" ]]; then
    printf '当前没有已生成的节点。\n'
    return 1
  fi

  printf '%-4s %-26s %-16s %-8s %-18s %-12s %-10s %-10s\n' "序号" "节点标识" "IP" "端口" "用户名" "状态" "启用" "监听"
  printf '%s\n' "--------------------------------------------------------------------------------------------------------------"

  local no=1
  while IFS=$'\t' read -r slug ip port username password created; do
    [[ -n "${slug:-}" ]] || continue
    local unit load_state active_state sub_state result main_pid enabled_state listen_state status_text
    unit="$(service_name "$slug")"
    read -r load_state active_state sub_state result main_pid enabled_state <<<"$(node_service_state "$unit")"

    if port_is_listening "$port"; then
      listen_state="是"
    else
      listen_state="否"
    fi

    case "$active_state:$listen_state" in
      active:是)
        status_text="运行中"
        ;;
      active:否)
        status_text="运行异常"
        ;;
      failed:*)
        status_text="失败"
        ;;
      activating:*)
        status_text="启动中"
        ;;
      inactive:*)
        status_text="未运行"
        ;;
      *)
        status_text="${active_state:-unknown}"
        ;;
    esac

    printf '%-4s %-26s %-16s %-8s %-18s %-12s %-10s %-10s\n' \
      "$no" \
      "$slug" \
      "$ip" \
      "$port" \
      "$username" \
      "$status_text" \
      "$enabled_state" \
      "$listen_state"

    if [[ "$active_state" != "active" || "$listen_state" != "是" ]]; then
      printf '     详情: load=%s sub=%s result=%s pid=%s listening=%s\n' \
        "$load_state" \
        "$sub_state" \
        "$result" \
        "$main_pid" \
        "$listen_state"
      if [[ "$result" != "success" ]]; then
        journalctl -u "$unit" -n 8 --no-pager 2>/dev/null | sed 's/^/     日志: /' || true
      fi
    fi

    no=$((no + 1))
  done <<<"$records"
}

node_record_by_index() {
  local target_index="$1"
  local records
  records="$(list_node_records)"
  if [[ -z "$records" ]]; then
    return 1
  fi

  printf '%s\n' "$records" | awk -F'\t' -v target="$target_index" '
    NF >= 6 {
      count++
      if (count == target) {
        print
        exit
      }
    }
  '
}

manual_username_exists() {
  local username="$1"
  if [[ ! -s "$USERS_MANUAL_FILE" ]]; then
    return 1
  fi
  awk -F: -v user="$username" '$1 == user { found=1 } END { exit found ? 0 : 1 }' "$USERS_MANUAL_FILE"
}

node_username_exists() {
  local username="$1"
  local records
  records="$(list_node_records)"
  if [[ -z "$records" ]]; then
    return 1
  fi
  printf '%s\n' "$records" | awk -F'\t' -v user="$username" '$4 == user { found=1 } END { exit found ? 0 : 1 }'
}

username_exists_anywhere() {
  local username="$1"
  manual_username_exists "$username" && return 0
  node_username_exists "$username" && return 0
  return 1
}

port_in_use() {
  local port="$1"
  ss -ltnH 2>/dev/null | awk -v port=":$port" '$4 ~ port "$" { found=1 } END { exit found ? 0 : 1 }'
}

port_is_listening() {
  local port="$1"
  ss -ltnH 2>/dev/null | awk -v port=":$port" '$4 ~ port "$" { found=1 } END { exit found ? 0 : 1 }'
}

node_exists() {
  local ip="$1"
  local port="$2"
  local records
  records="$(list_node_records)"
  if [[ -z "$records" ]]; then
    return 1
  fi
  printf '%s\n' "$records" | awk -F'\t' -v ip="$ip" -v port="$port" '$2 == ip && $3 == port { found=1 } END { exit found ? 0 : 1 }'
}

current_node_ports_csv() {
  if [[ ! -s "$INDEX_FILE" ]]; then
    printf ''
    return 0
  fi

  awk -F'\t' 'NF >= 3 && $3 ~ /^[0-9]+$/ { print $3 }' "$INDEX_FILE" | sort -n -u | paste -sd, -
}

ensure_nft_firewall_helper() {
  has_cmd nft || return 1

  cat >"$FIREWALL_NFT_HELPER" <<'EOF'
#!/usr/bin/env bash

set -euo pipefail

INDEX_FILE="/etc/3proxy/nodes.tsv"
INPUT_CHAIN="inet filter input"

ports_csv="$(
  awk -F'\t' 'NF >= 3 && $3 ~ /^[0-9]+$/ { print $3 }' "$INDEX_FILE" 2>/dev/null \
    | sort -n -u \
    | paste -sd, -
)"

if ! nft list chain inet filter input >/dev/null 2>&1; then
  echo "nftables 未找到 inet filter input 链，跳过自动放行。" >&2
  exit 0
fi

if [[ -n "$ports_csv" ]]; then
  IFS=',' read -r -a ports <<<"$ports_csv"
  for port in "${ports[@]}"; do
    if nft list chain inet filter input 2>/dev/null | grep -Eq "tcp dport ${port} .*accept"; then
      continue
    fi
    nft add rule inet filter input tcp dport "$port" accept comment "3proxy"
  done
fi
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
  return 0
}

sync_nft_firewall_rules() {
  ensure_nft_firewall_helper || return 1
  "$FIREWALL_NFT_HELPER"
}

firewall_backend() {
  if has_cmd ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
    printf 'ufw\n'
    return 0
  fi

  if has_cmd firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
    printf 'firewalld\n'
    return 0
  fi

  if has_cmd nft && nft list chain inet filter input >/dev/null 2>&1; then
    printf 'nft\n'
    return 0
  fi

  if has_cmd iptables; then
    printf 'iptables\n'
    return 0
  fi

  printf 'none\n'
}

ensure_firewall_port_open() {
  local port="$1"
  local backend
  backend="$(firewall_backend)"

  case "$backend" in
    ufw)
      if ufw status 2>/dev/null | grep -Eq "^[[:space:]]*${port}/tcp"; then
        return 0
      fi
      log "检测到 UFW，正在放行端口 ${port}/tcp"
      ufw allow "${port}/tcp" >/dev/null || return 1
      return 0
      ;;
    firewalld)
      if firewall-cmd --query-port="${port}/tcp" >/dev/null 2>&1; then
        return 0
      fi
      log "检测到 firewalld，正在放行端口 ${port}/tcp"
      firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null || return 1
      firewall-cmd --reload >/dev/null || return 1
      return 0
      ;;
    nft)
      sync_nft_firewall_rules
      return 0
      ;;
    iptables)
      if iptables -C INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1; then
        return 0
      fi
      log "检测到 iptables，正在放行端口 ${port}/tcp"
      iptables -I INPUT -p tcp --dport "$port" -j ACCEPT || return 1
      if has_cmd netfilter-persistent; then
        netfilter-persistent save >/dev/null 2>&1 || warn "iptables 规则已写入运行时，持久化保存失败。"
      else
        warn "iptables 规则已写入运行时，如需重启后保留，请自行保存。"
      fi
      return 0
      ;;
    *)
      warn "未检测到常见防火墙管理工具，已跳过端口放行：${port}"
      return 0
      ;;
  esac
}

append_node_record() {
  local slug="$1"
  local ip="$2"
  local port="$3"
  local username="$4"
  local password="$5"
  local created
  created="$(date +%F\ %T)"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$slug" "$ip" "$port" "$username" "$password" "$created" >>"$INDEX_FILE"
}

remove_node_record() {
  local slug="$1"
  local tmp
  tmp="$(mktemp)"
  awk -F'\t' -v slug="$slug" 'BEGIN { OFS="\t" } $1 != slug { print }' "$INDEX_FILE" >"$tmp"
  cat "$tmp" >"$INDEX_FILE"
  rm -f "$tmp"
}

append_manual_user() {
  local username="$1"
  local password="$2"
  printf '%s:CL:%s\n' "$username" "$password" >>"$USERS_MANUAL_FILE"
}

remove_manual_user() {
  local username="$1"
  local tmp
  tmp="$(mktemp)"
  awk -F: -v user="$username" 'BEGIN { OFS=":" } $1 != user { print }' "$USERS_MANUAL_FILE" >"$tmp"
  cat "$tmp" >"$USERS_MANUAL_FILE"
  rm -f "$tmp"
}

rebuild_effective_users() {
  ensure_dirs
  local tmp
  tmp="$(mktemp)"
  {
    if [[ -s "$USERS_MANUAL_FILE" ]]; then
      cat "$USERS_MANUAL_FILE"
    fi
    if [[ -s "$INDEX_FILE" ]]; then
      awk -F'\t' 'NF >= 5 { print $4 ":CL:" $5 }' "$INDEX_FILE"
    fi
  } | awk -F: 'NF >= 3 && !seen[$1]++ { print }' >"$tmp"

  : >"$USERS_FILE"
  cat "$tmp" >"$USERS_FILE"
  rm -f "$tmp"
  chown root:3proxy "$USERS_MANUAL_FILE" "$USERS_FILE" "$INDEX_FILE"
  chmod 0640 "$USERS_MANUAL_FILE" "$USERS_FILE" "$INDEX_FILE"
}

cfg_comment_value() {
  local cfg="$1"
  local key="$2"
  local value
  value="$(
    awk -v key="$key" '
      BEGIN { pat1 = "^# " key ":"; pat2 = "^# " key "：" }
      $0 ~ pat1 || $0 ~ pat2 {
        sub(/^# [^:：]+[:：][[:space:]]*/, "", $0)
        print
        exit
      }
    ' "$cfg" 2>/dev/null || true
  )"
  printf '%s\n' "$value"
}

record_from_cfg() {
  local cfg="$1"
  local slug ip port username password created
  slug="$(cfg_comment_value "$cfg" "节点")"
  [[ -n "$slug" ]] || slug="$(cfg_comment_value "$cfg" "slug")"
  [[ -n "$slug" ]] || slug="$(basename "$cfg" .cfg)"

  ip="$(cfg_comment_value "$cfg" "监听IP")"
  [[ -n "$ip" ]] || ip="$(cfg_comment_value "$cfg" "listen_ip")"

  port="$(cfg_comment_value "$cfg" "监听端口")"
  [[ -n "$port" ]] || port="$(cfg_comment_value "$cfg" "listen_port")"

  username="$(awk '$1 == "allow" { print $2; exit }' "$cfg" 2>/dev/null || true)"
  password=""
  if [[ -n "$username" ]]; then
    password="$(awk -F: -v user="$username" '$1 == user { print $3; exit }' "$USERS_FILE" 2>/dev/null || true)"
  fi

  if [[ -z "$password" ]]; then
    password="$(cfg_comment_value "$cfg" "密码")"
    [[ -n "$password" ]] || password="$(cfg_comment_value "$cfg" "password")"
  fi

  created="$(cfg_comment_value "$cfg" "创建时间")"
  [[ -n "$created" ]] || created="$(cfg_comment_value "$cfg" "created")"
  [[ -n "$created" ]] || created="$(date +%F\ %T)"

  if [[ -n "$ip" && -n "$port" ]]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$slug" "$ip" "$port" "$username" "$password" "$created"
  fi
}

list_node_records() {
  if [[ -s "$INDEX_FILE" ]]; then
    awk -F'\t' 'NF >= 6 { print }' "$INDEX_FILE"
    return 0
  fi

  shopt -s nullglob
  local cfg
  for cfg in "$NODE_DIR"/*.cfg; do
    record_from_cfg "$cfg" || true
  done
  shopt -u nullglob
}

list_nodes() {
  if ! print_node_table; then
    return 0
  fi

  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    return 0
  fi

  printf '\n'
  local delete_ip
  read -r -p "输入要删除的 IP（留空返回）：" delete_ip
  delete_ip="${delete_ip// /}"
  if [[ -z "$delete_ip" ]]; then
    return 0
  fi

  delete_nodes_by_ip "$delete_ip"
}

delete_nodes_by_ip() {
  require_root
  local target_ip="$1"
  validate_ipv4 "$target_ip" || die "IP 地址无效或不是 IPv4：$target_ip"

  local records
  records="$(list_node_records)"
  if [[ -z "$records" ]]; then
    die "当前没有可删除的节点。"
  fi

  local -a matches=()
  while IFS=$'\t' read -r slug ip port username password created; do
    [[ -n "${slug:-}" ]] || continue
    [[ "$ip" == "$target_ip" ]] || continue
    matches+=("$slug|$ip|$port|$username|$created")
  done <<<"$records"

  if (( ${#matches[@]} == 0 )); then
    warn "没有找到 IP 为 $target_ip 的节点。"
    return 0
  fi

  printf '\n将删除以下节点：\n'
  local item slug ip port username created
  for item in "${matches[@]}"; do
    IFS='|' read -r slug ip port username created <<<"$item"
    printf '  %s  [%s:%s]  用户:%s  创建:%s\n' "$slug" "$ip" "$port" "$username" "$created"
  done

  local answer
  read -r -p "确认删除上述 IP 相关节点吗？[y/N]：" answer
  [[ "${answer:-N}" =~ ^[Yy]$ ]] || die "已取消。"

  for item in "${matches[@]}"; do
    IFS='|' read -r slug ip port username created <<<"$item"
    systemctl disable --now "$(service_name "$slug")" >/dev/null 2>&1 || true
    rm -f "$(node_cfg_path "$slug")"
    remove_node_record "$slug"
  done

  rebuild_effective_users
  if [[ "$(firewall_backend)" == "nft" ]]; then
    sync_nft_firewall_rules || true
  fi
  systemctl daemon-reload

  log "已删除 IP 为 $target_ip 的 ${#matches[@]} 个节点。"
}

list_users() {
  rebuild_effective_users
  if [[ ! -s "$USERS_FILE" ]]; then
    printf '当前没有可用账号。\n'
    return 0
  fi

  printf '%-4s %-24s %-20s\n' "序号" "用户名" "来源"
  printf '%s\n' "--------------------------------------------------------"

  local manual_users index_users
  manual_users="$(awk -F: 'NF >= 3 { print $1 "\t手动" }' "$USERS_MANUAL_FILE" 2>/dev/null || true)"
  index_users="$(awk -F'\t' 'NF >= 5 { print $4 "\t节点" }' "$INDEX_FILE" 2>/dev/null || true)"
  printf '%s\n%s\n' "$manual_users" "$index_users" | awk -F'\t' '
    NF >= 2 && !seen[$1]++ {
      count++
      printf "%-4s %-24s %-20s\n", count ".", $1, $2
    }
  '
}

write_node_config() {
  local slug="$1"
  local ip="$2"
  local port="$3"
  local username="$4"
  local password="$5"
  local cfg
  cfg="$(node_cfg_path "$slug")"

  cat >"$cfg" <<EOF
# 由 $APP_NAME 自动生成
# 节点: $slug
# 监听IP: $ip
# 监听端口: $port
# 用户名: $username
# 密码: $password
# 创建时间: $(date +%F\ %T)

nserver 1.1.1.1
nserver 8.8.8.8
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
auth strong
users \$${USERS_FILE}
flush
allow ${username} * * *
internal $ip
external $ip
log $LOG_DIR/$slug.log D
rotate 30
maxconn 1024
socks -p$port -i$ip -e$ip
EOF

  chown root:3proxy "$cfg"
  chmod 0640 "$cfg"
}

start_node_service() {
  local slug="$1"
  local unit
  unit="$(service_name "$slug")"
  systemctl enable --now "$unit"
}

reload_node_service() {
  local slug="$1"
  local unit
  unit="$(service_name "$slug")"
  if systemctl is-active --quiet "$unit"; then
    systemctl reload "$unit" || systemctl restart "$unit"
  fi
}

reload_all_nodes() {
  local records
  records="$(list_node_records)"
  if [[ -z "$records" ]]; then
    return 0
  fi

  while IFS=$'\t' read -r slug ip port username password created; do
    [[ -n "${slug:-}" ]] || continue
    reload_node_service "$slug" || true
  done <<<"$records"
}

random_unique_username() {
  local candidate
  while true; do
    candidate="u$(random_alnum 10)"
    if ! username_exists_anywhere "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
}

random_unique_password() {
  random_alnum 16
}

prompt_global_credentials() {
  local username password confirm
  read -r -p "请输入统一用户名（留空自动生成）：" username
  if [[ -z "$username" ]]; then
    username="$(random_unique_username)"
    log "已自动生成统一用户名：$username"
  fi

  [[ "$username" =~ ^[A-Za-z0-9._-]+$ ]] || die "用户名仅允许字母、数字、点、下划线和横线。"
  if username_exists_anywhere "$username"; then
    die "该用户名已经存在，请换一个。"
  fi

  read -r -p "请输入统一密码（留空自动生成）：" password
  if [[ -z "$password" ]]; then
    password="$(random_unique_password)"
    log "已自动生成统一密码：$password"
  fi

  if [[ "$password" == *:* || "$password" == *[[:space:]]* ]]; then
    die "密码中不能包含冒号或空白字符。"
  fi

  printf '%s\t%s\n' "$username" "$password"
}

create_node() {
  require_root
  require_3proxy_installed

  local ip="$1"
  local port="$2"
  local username="$3"
  local password="$4"
  local slug cfg unit

  validate_ipv4 "$ip" || die "IP 地址无效或不是 IPv4：$ip"
  (( port >= 1 && port <= 65535 )) || die "端口超出范围：$port"
  [[ -n "$username" ]] || die "用户名不能为空。"
  [[ -n "$password" ]] || die "密码不能为空。"

  if ! ip_is_local "$ip"; then
    warn "IP 未绑定到本机网卡：$ip"
    warn "请先把该 IP 配置到服务器网卡后再生成节点，否则 3proxy 无法成功监听。"
    return 1
  fi

  slug="$(slug_from_ip_port "$ip" "$port")"
  cfg="$(node_cfg_path "$slug")"
  unit="$(service_name "$slug")"

  if node_exists "$ip" "$port"; then
    warn "已存在相同 IP 和端口，跳过：$ip:$port"
    return 1
  fi

  if port_in_use "$port"; then
    warn "端口已被占用，跳过：$port"
    return 1
  fi

  append_node_record "$slug" "$ip" "$port" "$username" "$password"
  rebuild_effective_users
  write_node_config "$slug" "$ip" "$port" "$username" "$password"

  if ! ensure_firewall_port_open "$port"; then
    warn "端口放行失败，已回滚该节点：$ip:$port"
    rm -f "$cfg"
    remove_node_record "$slug"
    rebuild_effective_users
    if [[ "$(firewall_backend)" == "nft" ]]; then
      sync_nft_firewall_rules || true
    fi
    return 1
  fi

  systemctl daemon-reload
  if ! start_node_service "$slug"; then
    warn "节点启动失败，正在回滚：$ip:$port"
    systemctl disable --now "$unit" >/dev/null 2>&1 || true
    rm -f "$cfg"
    remove_node_record "$slug"
    rebuild_effective_users
    if [[ "$(firewall_backend)" == "nft" ]]; then
      sync_nft_firewall_rules || true
    fi
    systemctl daemon-reload
    return 1
  fi

  if ! systemctl is-active --quiet "$unit"; then
    warn "节点服务未进入运行状态：$unit"
    journalctl -u "$unit" -n 20 --no-pager 2>/dev/null || true
    systemctl disable --now "$unit" >/dev/null 2>&1 || true
    rm -f "$cfg"
    remove_node_record "$slug"
    rebuild_effective_users
    if [[ "$(firewall_backend)" == "nft" ]]; then
      sync_nft_firewall_rules || true
    fi
    systemctl daemon-reload
    return 1
  fi

  log "节点已创建：$ip:$port -> $username"
  return 0
}

batch_create_nodes_from_ips() {
  require_root
  require_3proxy_installed

  local -a ips=("$@")
  if (( ${#ips[@]} == 0 )); then
    die "没有找到符合条件的 IP。"
  fi

  preview_ips "${ips[@]}"
  read -r -p "是否继续生成这些节点？[Y/n]：" confirm
  if [[ "${confirm:-Y}" =~ ^[Nn]$ ]]; then
    die "已取消。"
  fi

  local start_port
  read -r -p "请输入起始端口 [20000]：" start_port
  start_port="${start_port:-20000}"
  [[ "$start_port" =~ ^[0-9]+$ ]] || die "起始端口必须是数字。"
  (( start_port >= 1 && start_port <= 65535 )) || die "起始端口超出范围。"

  local mode
  printf '\n1) 统一用户名密码\n2) 每个节点随机用户名密码\n'
  read -r -p "请选择账号模式：" mode

  local global_user="" global_pass=""
  if [[ "$mode" == "1" ]]; then
    local pair
    pair="$(prompt_global_credentials)"
    global_user="${pair%%$'\t'*}"
    global_pass="${pair#*$'\t'}"
  elif [[ "$mode" == "2" ]]; then
    :
  else
    die "账号模式选择无效。"
  fi

  local success=0 failed=0 idx port username password
  for idx in "${!ips[@]}"; do
    port=$((start_port + idx))
    if [[ "$port" -gt 65535 ]]; then
      warn "端口已超过 65535，后续 IP 将不再生成。"
      break
    fi

    if [[ "$mode" == "1" ]]; then
      username="$global_user"
      password="$global_pass"
    else
      username="$(random_unique_username)"
      password="$(random_unique_password)"
      [[ -n "$username" ]] || die "随机用户名生成失败。"
      [[ -n "$password" ]] || die "随机密码生成失败。"
    fi

    if create_node "${ips[$idx]}" "$port" "$username" "$password"; then
      success=$((success + 1))
      if [[ "$mode" == "2" ]]; then
        log "随机凭据：${ips[$idx]}:${port} -> ${username}:${password}"
      fi
    else
      failed=$((failed + 1))
    fi
  done

  printf '\n批量生成完成：成功 %d 个，失败 %d 个。\n' "$success" "$failed"
  rebuild_effective_users
}

batch_create_nodes() {
  require_root
  require_3proxy_installed

  printf '\n%s\n' "====== 批量生成来源选择 ======"
  printf '%s\n' "1) 自动发现本机全部 IPv4"
  printf '%s\n' "2) 按网卡名称筛选"
  printf '%s\n' "3) 按 CIDR/IP 段筛选"
  printf '%s\n' "4) 从 IP 文件导入"
  read -r -p "请选择来源：" source_mode

  local -a ips=()
  case "$source_mode" in
    1)
      mapfile -t ips < <(discover_local_ipv4s)
      ;;
    2)
      read -r -p "请输入网卡名称，多个用英文逗号分隔（留空表示全部）：" ifaces
      if [[ -z "${ifaces// /}" ]]; then
        mapfile -t ips < <(discover_local_ipv4s)
      else
        mapfile -t ips < <(discover_local_ipv4s_by_interfaces "$ifaces")
      fi
      ;;
    3)
      read -r -p "请输入 CIDR / IP 段，多个用英文逗号分隔（留空表示全部）：" cidrs
      mapfile -t ips < <(filter_ips_by_cidrs "$cidrs")
      ;;
    4)
      read -r -p "请输入 IP 文件路径：" ip_file
      batch_create_nodes_from_file "$ip_file"
      return 0
      ;;
    *)
      die "来源选择无效。"
      ;;
  esac

  batch_create_nodes_from_ips "${ips[@]}"
}

batch_create_nodes_from_file() {
  require_root
  require_3proxy_installed

  local ip_file
  if [[ $# -ge 1 && -n "${1:-}" ]]; then
    ip_file="$(expand_path "$1")"
  else
    read -r -p "请输入 IP 文件路径：" ip_file
    ip_file="$(expand_path "$ip_file")"
  fi

  local -a ips=()
  mapfile -t ips < <(import_ipv4s_from_file "$ip_file")
  batch_create_nodes_from_ips "${ips[@]}"
}

restart_all_nodes() {
  require_root
  local records
  records="$(list_node_records)"
  if [[ -z "$records" ]]; then
    log "当前没有节点可重启。"
    return 0
  fi

  while IFS=$'\t' read -r slug ip port username password created; do
    [[ -n "${slug:-}" ]] || continue
    local unit
    unit="$(service_name "$slug")"
    systemctl restart "$unit"
  done <<<"$records"

  log "全部节点已重启。"
}

show_status() {
  require_root
  show_runtime_overview
  printf '\n'
  if ! print_node_table; then
    return 0
  fi

  printf '\n'
  local choice record slug ip port username password created unit
  read -r -p "请输入节点序号查看 systemctl status（留空返回）：" choice
  choice="${choice//[[:space:]]/}"
  if [[ -z "$choice" ]]; then
    return 0
  fi
  [[ "$choice" =~ ^[0-9]+$ ]] || die "序号必须是数字。"

  record="$(node_record_by_index "$choice")"
  if [[ -z "$record" ]]; then
    die "没有找到序号为 $choice 的节点。"
  fi

  IFS=$'\t' read -r slug ip port username password created <<<"$record"
  unit="$(service_name "$slug")"
  listen_state="否"
  if port_is_listening "$port"; then
    listen_state="是"
  fi

  printf '\n====== 节点详情 ======\n'
  printf '序号: %s\n' "$choice"
  printf '节点: %s\n' "$slug"
  printf 'IP: %s\n' "$ip"
  printf '端口: %s\n' "$port"
  printf '用户名: %s\n' "$username"
  printf '端口监听: %s\n' "$listen_state"
  printf 'systemctl status %s\n\n' "$unit"
  SYSTEMD_COLORS=1 systemctl status "$unit" --no-pager -l 2>/dev/null || true
  printf '\n最近 20 行日志:\n'
  journalctl -u "$unit" -n 20 --no-pager 2>/dev/null || true
}

export_proxy_list() {
  require_root
  local records
  records="$(list_node_records)"
  if [[ -z "$records" ]]; then
    die "当前没有可导出的代理。"
  fi

  local out_path
  read -r -p "请输入导出路径 [ /root/3proxy_proxy_list.txt ]：" out_path
  out_path="${out_path:-/root/3proxy_proxy_list.txt}"
  out_path="$(expand_path "$out_path")"

  mkdir -p "$(dirname "$out_path")"
  printf '%s\n' "$records" | awk -F'\t' 'NF >= 5 && $2 != "" && $3 != "" && $4 != "" && $5 != "" { printf "%s:%s:%s:%s\n", $2, $3, $4, $5 }' >"$out_path"
  chmod 0600 "$out_path" || true

  log "代理清单已导出：$out_path"
}

show_logs() {
  require_root
  local records
  records="$(list_node_records)"
  if [[ -z "$records" ]]; then
    die "当前没有节点。"
  fi

  show_runtime_overview
  printf '\n'
  print_node_table || true

  printf '\n====== 节点日志 ======\n'
  while IFS=$'\t' read -r slug ip port username password created; do
    [[ -n "${slug:-}" ]] || continue
    local unit log_file status_text
    unit="$(service_name "$slug")"
    log_file="$LOG_DIR/$slug.log"

    if systemctl is-active --quiet "$unit"; then
      status_text="运行中"
    else
      status_text="未运行"
    fi

    printf '\n[%s] %s:%s 用户:%s 状态:%s\n' "$slug" "$ip" "$port" "$username" "$status_text"
    printf 'systemd 最近日志:\n'
    journalctl -u "$unit" -n 20 --no-pager 2>/dev/null || true
    if [[ -f "$log_file" ]]; then
      printf '文件日志:\n'
      tail -n 20 "$log_file" 2>/dev/null || true
    fi
  done <<<"$records"
}

add_manual_user() {
  require_root
  require_3proxy_installed

  local username password confirm
  read -r -p "请输入用户名：" username
  [[ "$username" =~ ^[A-Za-z0-9._-]+$ ]] || die "用户名仅允许字母、数字、点、下划线和横线。"
  if username_exists_anywhere "$username"; then
    die "该用户名已存在，请换一个。"
  fi

  read -r -p "请输入密码：" password
  printf '\n'
  read -r -p "请再次输入密码：" confirm
  printf '\n'

  [[ -n "$password" ]] || die "密码不能为空。"
  [[ "$password" == "$confirm" ]] || die "两次密码不一致。"
  [[ "$password" != *:* && "$password" != *[[:space:]]* ]] || die "密码中不能包含冒号或空白字符。"

  append_manual_user "$username" "$password"
  rebuild_effective_users
  reload_all_nodes

  log "手动账号已添加。"
}

remove_manual_user_menu() {
  require_root
  require_3proxy_installed
  if [[ ! -s "$USERS_MANUAL_FILE" ]]; then
    die "当前没有可删除的手动账号。"
  fi

  local username
  read -r -p "请输入要删除的手动用户名：" username
  [[ "$username" =~ ^[A-Za-z0-9._-]+$ ]] || die "用户名格式不正确。"

  if node_username_exists "$username"; then
    die "该用户名正在被节点使用，请先删除对应节点。"
  fi

  if ! manual_username_exists "$username"; then
    die "手动账号不存在。"
  fi

  remove_manual_user "$username"
  rebuild_effective_users
  reload_all_nodes

  log "手动账号已删除。"
}

user_menu() {
  while true; do
    printf '\n%s\n' "====== 用户管理 ======"
    printf '%s\n' "1) 添加手动账号（独立）"
    printf '%s\n' "2) 删除手动账号（独立）"
    printf '%s\n' "3) 查看当前账号"
    printf '%s\n' "0) 返回主菜单"
    read -r -p "请选择：" choice

    case "$choice" in
      1)
        add_manual_user
        pause
        ;;
      2)
        remove_manual_user_menu
        pause
        ;;
      3)
        list_users
        pause
        ;;
      0)
        return 0
        ;;
      *)
        warn "无效选项。"
        pause
        ;;
    esac
  done
}

uninstall_all() {
  require_root
  detect_os

  read -r -p "确定要卸载本工具创建的所有节点、配置和二进制吗？[y/N]：" answer
  [[ "${answer:-N}" =~ ^[Yy]$ ]] || die "已取消。"

  if [[ -s "$INDEX_FILE" ]]; then
    while IFS=$'\t' read -r slug ip port username password created; do
      [[ -n "${slug:-}" ]] || continue
      systemctl disable --now "$(service_name "$slug")" >/dev/null 2>&1 || true
      rm -f "$(node_cfg_path "$slug")"
    done <"$INDEX_FILE"
  fi

  systemctl disable --now "$(basename "$FIREWALL_NFT_SERVICE")" >/dev/null 2>&1 || true
  rm -f "$SYSTEMD_TEMPLATE"
  rm -f "$FIREWALL_NFT_SERVICE" "$FIREWALL_NFT_HELPER"
  rm -f /usr/local/bin/sk5
  rm -f /etc/profile.d/3proxy-sk5.sh
  rm -f "$INDEX_FILE" "$USERS_FILE" "$USERS_MANUAL_FILE"
  rm -f /usr/local/bin/3proxy /usr/local/bin/3proxy_* /usr/local/bin/3proxy-firewall-sync
  rm -rf /usr/local/lib/3proxy /usr/local/share/3proxy
  rm -rf "$SRC_DIR"
  rm -rf "$NODE_DIR" "$BASE_DIR"
  rm -rf "$LOG_DIR"
  if id -u 3proxy >/dev/null 2>&1; then
    userdel 3proxy >/dev/null 2>&1 || true
  fi
  if getent group 3proxy >/dev/null 2>&1; then
    groupdel 3proxy >/dev/null 2>&1 || true
  fi

  systemctl daemon-reload
  log "清理完成。"
}

show_install_summary() {
  cat <<EOF

安装完成。

下一步建议：
  1. 使用菜单 2 批量生成节点（全量/网卡/CIDR/文件）。
  2. 使用菜单 3 查看节点列表，并可直接按 IP 删除不需要的节点。
  3. 使用菜单 6 导出代理清单，格式为 ip:port:user:pass。
  4. 批量生成时可以按网卡、CIDR，或者直接导入 IP 文件。
  5. 后续可以直接输入 `sk5` 打开菜单。

配置目录：
  $BASE_DIR

节点目录：
  $NODE_DIR

账号文件：
  $USERS_FILE
EOF
}

main_menu() {
  while true; do
    printf '\n%s\n' "========================================"
    printf '%s\n' " $APP_NAME"
    printf '%s\n' "========================================"
    printf '%s\n' "1) 安装 / 升级 3proxy"
    printf '%s\n' "2) 批量生成节点（全量/网卡/CIDR/文件）"
    printf '%s\n' "3) 查看节点列表 / 按 IP 删除"
    printf '%s\n' "4) 重启全部节点"
    printf '%s\n' "5) 查看节点状态"
    printf '%s\n' "6) 导出代理清单"
    printf '%s\n' "7) 查看节点日志"
    printf '%s\n' "8) 卸载本工具创建的所有内容"
    printf '%s\n' "9) 从 IP 文件导入并批量生成节点"
    printf '%s\n' "0) 退出"
    printf '%s\n' "========================================"
    if ! read -r -p "请选择：" choice; then
      printf '\n'
      exit 0
    fi
    choice="${choice//[[:space:]]/}"
    if [[ -z "$choice" ]]; then
      continue
    fi

    case "$choice" in
      1)
        require_root
        detect_os
        install_dependencies
        ensure_service_user
        ensure_dirs
        install_self_copy
        write_systemd_template
        install_sk5_launcher
        if has_cmd nft; then
          ensure_nft_firewall_helper || true
        fi
        build_3proxy
        sync_existing_node_configs
        restart_all_nodes
        show_install_summary
        pause
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
        restart_all_nodes
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
        show_logs
        pause
        ;;
      8)
        uninstall_all
        pause
        ;;
      9)
        batch_create_nodes_from_file
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
  if [[ $# -gt 0 ]]; then
    warn "此脚本为交互式菜单工具，不接受参数。"
  fi
  main_menu
}

if [[ "${BASH_SOURCE[0]}" == "$0" || "$(basename "${BASH_SOURCE[0]}")" == "sk5" ]]; then
  main "$@"
fi

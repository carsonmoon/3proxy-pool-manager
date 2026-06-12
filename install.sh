#!/usr/bin/env bash
set -e

BASE_DIR="/usr/local/3proxy"
DATA_DIR="${BASE_DIR}/data"
LIB_DIR="${BASE_DIR}/lib"
PM_BIN="/usr/local/bin/pm"
SERVICE_FILE="/etc/systemd/system/3proxy.service"

echo "=== 安装依赖 ==="
apt update
DEBIAN_FRONTEND=noninteractive apt install -y git gcc g++ make build-essential libssl-dev zlib1g-dev curl wget

echo "=== 下载3proxy源代码并编译 ==="
cd /tmp
rm -rf 3proxy
git clone https://github.com/z3APA3A/3proxy.git
cd 3proxy
make -f Makefile.Linux
mkdir -p "$BASE_DIR"
cp bin/3proxy "$BASE_DIR/"
chmod +x "$BASE_DIR/3proxy"

echo "=== 创建项目目录结构 ==="
mkdir -p "$DATA_DIR" "$LIB_DIR"

echo "=== 下载管理脚本 ==="
curl -sSL https://raw.githubusercontent.com/你的用户名/duosocks5/main/pm -o "$PM_BIN"
chmod +x "$PM_BIN"

for f in firewall.sh proxy.sh status.sh uninstall.sh; do
    curl -sSL https://raw.githubusercontent.com/你的用户名/duosocks5/main/lib/$f -o "$LIB_DIR/$f"
    chmod +x "$LIB_DIR/$f"
done

echo "=== 配置 systemd 服务 ==="
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=3proxy Proxy Server
After=network.target

[Service]
Type=simple
ExecStart=${BASE_DIR}/3proxy ${DATA_DIR}/3proxy.cfg
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable 3proxy

echo "=== 安装完成 ==="
echo "输入 'pm' 启动管理菜单"

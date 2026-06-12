#!/usr/bin/env bash

proxy_status() {
    systemctl is-active 3proxy && echo "[√] 运行中" || echo "[×] 未运行"
    ss -lntp | grep 3proxy || echo "未发现监听端口"
}

proxy_status_detailed() {
    echo "=== 3proxy 运行详细状态 ==="
    proxy_status
    echo "代理数量: $(wc -l < /usr/local/3proxy/data/socks5_list.csv)"
    echo "账号文件: /usr/local/3proxy/data/socks5_list.csv / /usr/local/3proxy/data/socks5_list.txt"
}

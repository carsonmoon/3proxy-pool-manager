#!/usr/bin/env bash

open_ports() {
    END_PORT=$((START_PORT + $(wc -l < /usr/local/3proxy/data/socks5_list.csv) - 1))
    if command -v ufw >/dev/null 2>&1; then
        ufw allow ${START_PORT}:${END_PORT}/tcp || true
    fi
    if command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port=${START_PORT}-${END_PORT}/tcp || true
        firewall-cmd --reload || true
    fi
    iptables -I INPUT -p tcp -m multiport --dports ${START_PORT}-${END_PORT} -j ACCEPT
}

firewall_status() {
    ufw status || firewall-cmd --list-all || iptables -S
}

#!/usr/bin/env bash

uninstall_pool() {
    rm -f /usr/local/3proxy/data/3proxy.cfg
    rm -f /usr/local/3proxy/data/socks5_list.*
    systemctl restart 3proxy
    echo "代理池已删除"
}

uninstall_project() {
    systemctl stop 3proxy
    systemctl disable 3proxy
    rm -rf /usr/local/3proxy
    rm -f /etc/systemd/system/3proxy.service
    rm -f /usr/local/bin/pm
    systemctl daemon-reload
    echo "项目已卸载"
}

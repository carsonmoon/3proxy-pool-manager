#!/usr/bin/env bash

CFG_FILE="/usr/local/3proxy/data/3proxy.cfg"
CSV_FILE="/usr/local/3proxy/data/socks5_list.csv"
TXT_FILE="/usr/local/3proxy/data/socks5_list.txt"

generate_proxy_pool() {
    echo "=== 获取公网 IPv4 ==="
    IP_LIST=($(ip -4 addr show scope global | grep -vE '127|10\.|192\.168|172\.(1[6-9]|2[0-9]|3[0-1])' | grep -oP '(?<=inet\s)\d+(\.\d+){3}'))
    if [ ${#IP_LIST[@]} -eq 0 ]; then
        echo "没有检测到公网 IP"
        exit 1
    fi

    read -p "起始端口 [10000]: " START_PORT
    START_PORT=${START_PORT:-10000}

    read -p "用户名生成方式 [1=统一, 2=随机, 默认1]: " USER_TYPE
    USER_TYPE=${USER_TYPE:-1}
    if [ "$USER_TYPE" = "1" ]; then
        read -p "统一用户名 [admin]: " USERNAME
        USERNAME=${USERNAME:-admin}
        read -s -p "统一密码 [123456]: " PASSWORD
        echo
        PASSWORD=${PASSWORD:-123456}
    fi

    > "$CFG_FILE"
    cat >> "$CFG_FILE" <<EOF
nserver 8.8.8.8
nserver 1.1.1.1
timeouts 1 5 30 60 180 1800 15 60
auth strong
EOF

    > "$CSV_FILE"
    > "$TXT_FILE"

    PORT=$START_PORT
    for IP in "${IP_LIST[@]}"; do
        if [ "$USER_TYPE" = "1" ]; then
            U=$USERNAME
            P=$PASSWORD
        else
            U="user$((RANDOM%10000))"
            P="pass$((RANDOM%100000))"
        fi
        echo "users ${U}:CL:${P}" >> "$CFG_FILE"
        echo "allow ${U}" >> "$CFG_FILE"
        echo "socks -p${PORT} -e${IP}" >> "$CFG_FILE"

        echo "${IP},${PORT},${U},${P}" >> "$CSV_FILE"
        echo "socks5://${U}:${P}@${IP}:${PORT}" >> "$TXT_FILE"

        PORT=$((PORT+1))
    done

    echo "flush" >> "$CFG_FILE"
    echo "生成完成"
}

proxy_test() {
    head -n 5 "$TXT_FILE" | while IFS= read -r line; do
        echo -n "$line -> "
        curl --max-time 5 -x "$line" https://api.ipify.org 2>/dev/null && echo "√" || echo "×"
    done
}

#!/usr/bin/env bash
source /usr/local/3proxy/lib/proxy.sh
source /usr/local/3proxy/lib/status.sh
source /usr/local/3proxy/lib/firewall.sh
source /usr/local/3proxy/lib/uninstall.sh

while true; do
cat <<EOF

=========================================
      3Proxy Pool Manager v1.0
=========================================

 1. 查看运行状态
 2. 状态检查
 3. 查看代理列表
 4. 查看配置文件
 5. 测试代理池
 6. 创建代理池
 7. 重建代理池
 8. 删除指定代理（暂未实现）
 9. 启动3Proxy
10. 停止3Proxy
11. 重启3Proxy
12. 查看运行日志
13. 防火墙状态
14. 卸载代理池
15. 卸载整个项目
 0. 退出

=========================================
EOF

read -p "请选择: " choice
case $choice in
  1) proxy_status ;;
  2) proxy_status_detailed ;;
  3) cat /usr/local/3proxy/data/socks5_list.csv ;;
  4) cat /usr/local/3proxy/data/3proxy.cfg ;;
  5) proxy_test ;;
  6) generate_proxy_pool; open_ports; systemctl restart 3proxy ;;
  7) generate_proxy_pool; open_ports; systemctl restart 3proxy ;;
  8) echo "暂未实现" ;;
  9) systemctl start 3proxy ;;
  10) systemctl stop 3proxy ;;
  11) systemctl restart 3proxy ;;
  12) journalctl -u 3proxy -n 50 ;;
  13) firewall_status ;;
  14) uninstall_pool ;;
  15) uninstall_project ;;
  0) exit 0 ;;
  *) echo "无效选项" ;;
esac
done

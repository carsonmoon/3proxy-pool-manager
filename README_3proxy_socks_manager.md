# 3proxy SOCKS5 一键管理器

适用于 Debian 11-13 和 Ubuntu 22.04+ 的交互式 Bash 安装与管理脚本。

## 功能说明

- 检查系统版本和 root 权限
- 安装源码编译所需依赖
- 从官方仓库源码编译 3proxy
- 创建 `systemd` 模板服务
- 自动发现服务器上的 IPv4 地址
- 支持按网卡名称筛选 IP
- 支持按 CIDR/IP 段过滤后批量生成 SOCKS5 节点
- 支持从 IP 文件导入后批量生成节点
- 每个 IP 对应一个独立端口，端口递增
- 支持统一账号或每节点随机账号
- 自动检查并放行常见防火墙端口
- 支持 `nftables` 持久化同步
- 支持导出代理清单为 `ip:port:user:pass`

## 主菜单

1. 安装 / 升级 3proxy
2. 批量生成节点（全量/网卡/CIDR/文件）
3. 手动新增单个节点
4. 删除节点
5. 查看节点列表
6. 用户管理
7. 重启全部节点
8. 查看节点状态
9. 导出代理清单
10. 查看节点日志
11. 卸载本工具创建的所有内容
12. 从 IP 文件导入并批量生成节点

## 文件位置

- 配置根目录：`/etc/3proxy`
- 节点配置：`/etc/3proxy/nodes`
- 手动账号：`/etc/3proxy/users.manual.passwd`
- 生效账号：`/etc/3proxy/users.passwd`
- 节点索引：`/etc/3proxy/nodes.tsv`
- 日志目录：`/var/log/3proxy`
- 服务模板：`/etc/systemd/system/3proxy@.service`

## 说明

- 该脚本采用源码编译，不依赖发行版仓库里的 3proxy 包。
- 当前版本按 IPv4 设计，适合常见站群公网 IP 场景。
- 批量生成时可以直接留空，自动使用服务器上全部发现到的 IPv4。
- 批量生成时也可以选择按网卡名称筛选、按 CIDR/IP 段筛选，或者直接导入 IP 文件。
- IP 文件建议每行一个 IP，也支持用空格或逗号分隔，`#` 后面的内容会被忽略。
- 生成代理清单后可直接用于下游程序，格式为 `ip:port:user:pass`。
- 如果系统使用的是 UFW、firewalld 或 iptables，脚本会尽量自动放行端口。
- 如果检测到 `nftables`，脚本会创建独立的同步服务，保证重启后规则仍然保留。

apt update -y && apt install -y wget curl sudo && wget -O 3proxy.sh https://raw.githubusercontent.com/carsonmoon/3proxy-pool-manager/main/3proxy_socks5_oneclick.sh && chmod +x 3proxy.sh && sudo bash 3proxy.sh

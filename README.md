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
- 节点列表里可直接按 IP 删除相关节点
- 状态页会显示 3proxy 二进制、进程概览和节点列表，并可按序号查看对应节点的 `systemctl status`
- 自动检查并放行常见防火墙端口
- 支持 `nftables` 持久化同步
- 支持导出代理清单为 `ip:port:user:pass`
- 脚本首次运行后即可直接使用 `sk5` 打开菜单

## 主菜单

1. 安装 / 升级 3proxy
2. 批量生成节点（全量/网卡/CIDR/文件）
3. 查看节点列表 / 按 IP 删除
4. 重启全部节点
5. 查看节点状态
6. 导出代理清单
7. 卸载本工具创建的所有内容
8. 从 IP 文件导入并批量生成节点

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
- 如果节点起不来，优先检查 IP 是否真的已经绑定到本机网卡上。
- 节点服务使用 systemd 模板方式托管，由 systemd 直接管理前台进程。
- `systemctl status 3proxy` 看到的通常是旧的 `3proxy.service`，真正的节点实例是 `3proxy@节点标识.service`，建议用菜单 5 或 `systemctl status '3proxy@xxx'` 查看。
- 卸载时会尽量清理脚本、3proxy 二进制、systemd 单元、辅助 launcher、用户组和相关目录。

建议在 Debian 13 上用 root 执行：
bash <(curl -fsSL https://raw.githubusercontent.com/carsonmoon/3proxy-pool-manager/main/3proxy_socks_manager.sh)
执行完以后，直接输入：
sk5
就能再打开菜单。

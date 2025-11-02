#!/bin/bash
echo "--- hysteria 端口重定向脚本（Debian 系专用） ---"

# ===== 系统检查 =====
if [ -f /etc/os-release ]; then
    . /etc/os-release
    case "$ID" in
        debian|ubuntu|linuxmint|raspbian)
            echo "检测到系统为 $NAME，继续执行..."
            ;;
        *)
            echo "本脚本仅支持 Debian 系系统（Debian/Ubuntu/Mint/Raspbian）"
            exit 1
            ;;
    esac
else
    echo "无法检测系统类型，本脚本仅支持 Debian 系系统"
    exit 1
fi

# ===== 检查 root 权限 =====
if [[ $EUID -ne 0 ]]; then
    echo "请使用 root 权限运行此脚本"
    exit 1
fi

# ===== 安装依赖 =====
install_pkg() {
    sudo apt update -y
    sudo apt install -y "$@"
}

for cmd in sudo systemctl iptables ip6tables; do
    if ! command -v $cmd >/dev/null 2>&1; then
        echo "未检测到 $cmd，正在安装..."
        install_pkg "$cmd"
    fi
done

# ===== 自动获取物理网卡 =====
get_iface() {
    mapfile -t ifaces < <(ip -o link show | awk -F': ' '{print $2}' | grep -vE '^(lo|docker|veth|br-|tun|tap)')
    if (( ${#ifaces[@]} == 0 )); then
        read -p "未检测到物理网卡，请手动输入网卡名称: " iface
    elif (( ${#ifaces[@]} == 1 )); then
        iface="${ifaces[0]}"
        echo "检测到物理网卡: $iface"
    else
        echo "检测到多个物理网卡："
        select i in "${ifaces[@]}"; do
            iface="$i"
            break
        done
    fi
}
get_iface

# ===== 输入端口 =====
while true; do
    read -p "起始端口: " start_port
    if [[ "$start_port" =~ ^[0-9]+$ ]] && (( start_port >= 1 && start_port <= 65535 )); then
        break
    else
        echo "错误！请输入 1-65535 范围内的数字"
    fi
done

while true; do
    read -p "结束端口: " end_port
    if [[ "$end_port" =~ ^[0-9]+$ ]] && (( end_port >= start_port && end_port <= 65535 )); then
        break
    else
        echo "错误！请输入大于等于起始端口且 ≤65535 的数字"
    fi
done

while true; do
    read -p "监听端口: " local_port
    if [[ "$local_port" =~ ^[0-9]+$ ]] && (( local_port >= 1 && local_port <= 65535 )); then
        break
    else
        echo "错误！请输入 1-65535 范围内的数字"
    fi
done

# ===== IPv6 转发选择 =====
while true; do
    read -p "是否开启 IPv6 转发并添加 IPv6 规则? (y/n): " enable_ipv6
    if [[ "$enable_ipv6" == "y" || "$enable_ipv6" == "n" ]]; then
        break
    else
        echo "错误：请输入 y 或 n"
    fi
done

# ===== 清理旧规则 =====
sudo iptables -t nat -D PREROUTING -i "$iface" -p udp --dport ${start_port}:${end_port} -j REDIRECT --to-ports ${local_port} 2>/dev/null
sudo ip6tables -t nat -D PREROUTING -i "$iface" -p udp --dport ${start_port}:${end_port} -j REDIRECT --to-ports ${local_port} 2>/dev/null

# ===== 添加新规则 =====
sudo iptables -t nat -A PREROUTING -i "$iface" -p udp --dport ${start_port}:${end_port} -j REDIRECT --to-ports ${local_port}

if [[ "$enable_ipv6" == "y" ]]; then
    sed -i '/^net.ipv6.conf.all.forwarding/d' /etc/sysctl.conf
    echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf
    sysctl -p >/dev/null
    sudo ip6tables -t nat -A PREROUTING -i "$iface" -p udp --dport ${start_port}:${end_port} -j REDIRECT --to-ports ${local_port}
fi

# ===== 保存执行脚本 =====
mkdir -p /root/start
cat > /root/start/hysteria_port.sh << EOF
#!/bin/bash
for i in {1..10}; do
    ip link show "$iface" >/dev/null 2>&1 && break
    echo "等待网络接口 $iface 启动..."
    sleep 3
done
sudo iptables -t nat -A PREROUTING -i "$iface" -p udp --dport ${start_port}:${end_port} -j REDIRECT --to-ports ${local_port}
EOF

if [[ "$enable_ipv6" == "y" ]]; then
cat >> /root/start/hysteria_port.sh << EOF
sudo ip6tables -t nat -A PREROUTING -i "$iface" -p udp --dport ${start_port}:${end_port} -j REDIRECT --to-ports ${local_port}
EOF
fi
chmod +x /root/start/hysteria_port.sh

# ===== 创建 systemd 服务 =====
cat > /etc/systemd/system/hysteria_port.service << EOF
[Unit]
Description=Hysteria Port Redirect Service
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/root/start/hysteria_port.sh
RemainAfterExit=yes
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable hysteria_port
systemctl restart hysteria_port

# ===== 保存 iptables 规则 =====
install_pkg iptables-persistent
netfilter-persistent save

echo "脚本运行成功，端口 ${start_port}-${end_port} 已重定向到 ${local_port} (网卡: $iface)"
if [[ "$enable_ipv6" == "y" ]]; then
    echo "IPv6 转发已开启，并添加了 IPv6 重定向规则"
fi

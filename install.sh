#!/usr/bin/env bash
set -euo pipefail

# =================================================================
# Xray 一键安装脚本 (vFinal-fix - 直达菜单 & 完全自定义)
#
# 特性:
# - [修复] 如果 iptables 未安装则自动跳过, 避免报错
# - VLess 协议: 仅支持 WebSocket + TLS (高兼容性)
# - VMess 协议: 支持 WebSocket + TLS 和 TCP + TLS (HTTP 伪装)
# - WebSocket 模式支持自定义伪装 Host
# - 自动检测域名解析, 等待生效
# =================================================================


# ========================
# 配置参数
# ========================
XRAY_PORT=443
XRAY_USER="root"
XRAY_BIN_DIR="/usr/local/bin"
XRAY_CONFIG_DIR="/usr/local/etc/xray"
SYSTEMD_SERVICE="/etc/systemd/system/xray.service"
SSL_DIR="/etc/ssl/xray_tls"
XRAY_LOG_DIR="/var/log/xray"
ACME_DIR="$HOME/.acme.sh"

# ========================
# 函数定义
# ========================

# 开放端口并清空防火墙
open_ports() {
    echo "=== 正在配置防火墙... ==="
    if command -v iptables >/dev/null 2>&1; then
        echo "检测到 iptables, 正在清空规则并放通所有端口..."
        iptables -P INPUT ACCEPT
        iptables -P FORWARD ACCEPT
        iptables -P OUTPUT ACCEPT
        iptables -F
        if command -v netfilter-persistent >/dev/null 2>&1; then
            netfilter-persistent save
            echo "防火墙规则已清空并保存。"
        else
            echo "未安装 netfilter-persistent, 跳过保存规则。"
        fi
    else
        echo "未检测到 iptables 命令, 跳过防火墙配置。"
        echo "请注意: 您需要手动确保云服务商的安全组或您服务器上的其他防火墙(如 ufw)已放行 TCP 443 和 80 端口。"
    fi
}

# 检测端口占用
check_port() {
    if ss -ltnp | grep -q ":$1"; then
        echo "错误：端口 $1 已被占用，请先释放该端口再运行脚本。"
        exit 1
    fi
}

# 检测域名解析是否正确
check_dns() {
    local domain=$1
    local attempt=1
    local max_attempts=10

    echo "=== 正在检测域名解析，请确保域名已指向本服务器 IP ==="

    local server_ipv4=$(curl -s4 https://api.ipify.org || curl -s4 https://ipinfo.io/ip || echo "")
    local server_ipv6=$(curl -s6 https://api.ipify.org || curl -s6 https://ipinfo.io/ip || echo "")

    if [ -z "$server_ipv4" ] && [ -z "$server_ipv6" ]; then
        echo "错误：无法获取服务器的公网 IP 地址。请检查网络连接。"
        exit 1
    fi

    echo "服务器 IPv4 地址: ${server_ipv4:-N/A}"
    echo "服务器 IPv6 地址: ${server_ipv6:-N/A}"

    while [ $attempt -le $max_attempts ]; do
        echo "--- 第 $attempt / $max_attempts 次尝试 ---"

        local resolved_ipv4=$(dig +short A "$domain" | tail -n1)
        local resolved_ipv6=$(dig +short AAAA "$domain" | tail -n1)

        echo "域名 $domain 解析到 IPv4: ${resolved_ipv4:-N/A}"
        echo "域名 $domain 解析到 IPv6: ${resolved_ipv6:-N/A}"

        local matched=false

        if [ -n "$server_ipv4" ] && [ "$resolved_ipv4" == "$server_ipv4" ]; then
            echo "IPv4 解析正确。"
            matched=true
        fi

        if [ -n "$server_ipv6" ] && [ "$resolved_ipv6" == "$server_ipv6" ]; then
            echo "IPv6 解析正确。"
            matched=true
        fi

        if $matched; then
            echo "=== 域名解析检测通过！ ==="
            return 0
        fi

        echo "域名解析不匹配或尚未生效。"
        if [ $attempt -lt $max_attempts ]; then
            echo "将在 30 秒后重试..."
            sleep 30
        else
            echo "错误：域名解析检测失败。"
            echo "请将域名 $domain 的 A 记录(IPv4) 或 AAAA 记录(IPv6) 指向您的服务器 IP。"
            exit 1
        fi
        ((attempt++))
    done
}

# 申请并安装证书
apply_certificate() {
    local domain=$1
    local attempt=1
    local max_attempts=3

    while [ $attempt -le $max_attempts ]; do
        echo "=== 正在尝试申请 SSL 证书 (第 $attempt / $max_attempts 次)... ==="
        "$ACME_DIR/acme.sh" --issue -d "$domain" --standalone --keylength ec-256 --force

        if [ $? -eq 0 ]; then
            echo "=== 证书申请成功！ ==="
            "$ACME_DIR/acme.sh" --install-cert -d "$domain" --ecc \
                --key-file "$SSL_DIR/$domain.key" \
                --fullchain-file "$SSL_DIR/$domain.crt" \
                --reloadcmd "systemctl restart xray"

            if [ $? -eq 0 ]; then
                echo "=== 证书安装成功！ ==="
                return 0
            else
                echo "错误：证书安装失败！"
                return 1
            fi
        else
            echo "错误：证书申请失败 (第 $attempt 次尝试)。"
            if [ $attempt -lt $max_attempts ]; then
                echo "将在 5 秒后重试..."
                sleep 5
            else
                echo "错误：已达到最大重试次数，证书申请失败。请检查 80 端口是否被占用或被防火墙阻挡。"
                return 1
            fi
        fi
        ((attempt++))
    done
}


install_xray() {
    # 接收从主菜单传递的参数
    local PROTOCOL=$1
    local TRANSPORT_NETWORK=$2

    echo "--- 您选择了安装: ${PROTOCOL} + ${TRANSPORT_NETWORK} + TLS ---"
    open_ports

    [ -d "$ACME_DIR" ] && rm -rf "$ACME_DIR"

    read -rp "请输入 TLS 使用的域名（例如 xxx.com）： " DOMAIN
    [ -z "$DOMAIN" ] && { echo "域名不能为空"; exit 1; }

    read -rp "请输入用于证书注册的邮箱： " EMAIL
    [ -z "$EMAIL" ] && { echo "邮箱不能为空"; exit 1; }

    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl unzip uuid-runtime openssl socat jq cron python3 dnsutils
    systemctl enable --now cron

    check_dns "$DOMAIN"

    local HTTP_PATH=""
    local WS_HOST=""
    local HTTP_HOST_HEADER=""
    local HTTP_USER_AGENT=""

    if [ "$TRANSPORT_NETWORK" = "ws" ]; then
        read -rp "请输入 WebSocket 路径 [/]: " -e -i "/" HTTP_PATH
        read -rp "请输入 WebSocket 伪装域名 (Host) [${DOMAIN}]: " -e -i "${DOMAIN}" WS_HOST
    else # tcp
        echo "--- 开始自定义 HTTP 伪装头 ---"
        read -rp "请输入 HTTP 伪装路径 [/]: " -e -i "/" HTTP_PATH
        read -rp "请输入 HTTP Host 伪装头 [${DOMAIN}]: " -e -i "${DOMAIN}" HTTP_HOST_HEADER
        read -rp "请输入 HTTP User-Agent 伪装头 [Chrome UA]: " -e -i "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/108.0.0.0 Safari/537.36" HTTP_USER_AGENT
    fi

    check_port 80
    check_port $XRAY_PORT

    curl https://get.acme.sh | sh -s email=$EMAIL --force
    chmod +x "$ACME_DIR/acme.sh"

    if ! command -v xray >/dev/null 2>&1; then
        COUNTRY=$(curl -fsS --max-time 8 https://ipinfo.io/country 2>/dev/null || true)
        COUNTRY=$(echo -n "$COUNTRY" | tr -d '\r\n' | tr '[:lower:]' '[:upper:]')
        MIRROR_PREFIX=""
        [ "$COUNTRY" = "CN" ] && MIRROR_PREFIX="https://gh.llkk.cc/https://"
        RELATIVE_URL="github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip"
        XURL="${MIRROR_PREFIX}${RELATIVE_URL}"
        TMP_ZIP="/tmp/xray.zip"
        echo "正在下载 Xray 核心..."
        curl -L -o "$TMP_ZIP" "$XURL"
        unzip -o "$TMP_ZIP" -d /tmp/xray_unpack >/dev/null
        install -m 755 /tmp/xray_unpack/xray "$XRAY_BIN_DIR/xray"
        rm -rf /tmp/xray_unpack "$TMP_ZIP"
    fi

    mkdir -p "$XRAY_CONFIG_DIR" "$SSL_DIR" "$XRAY_LOG_DIR"

    UUID=$(uuidgen)
    echo "生成 UUID: $UUID"

    local STREAM_SETTINGS_JSON=""
    if [ "$TRANSPORT_NETWORK" = "ws" ]; then
        STREAM_SETTINGS_JSON=$(cat <<EOF
    "streamSettings": {
        "network": "ws", "security": "tls",
        "tlsSettings": { "certificates": [{"certificateFile": "${SSL_DIR}/${DOMAIN}.crt","keyFile": "${SSL_DIR}/${DOMAIN}.key"}], "serverName": "${DOMAIN}" },
        "wsSettings": {"path": "${HTTP_PATH}","headers":{ "Host": "${WS_HOST}" }}
    }
EOF
)
    else # tcp with http camouflage
        STREAM_SETTINGS_JSON=$(cat <<EOF
    "streamSettings": {
        "network": "tcp", "security": "tls",
        "tlsSettings": { "certificates": [{"certificateFile": "${SSL_DIR}/${DOMAIN}.crt","keyFile": "${SSL_DIR}/${DOMAIN}.key"}], "serverName": "${DOMAIN}" },
        "tcpSettings": {
            "header": {
                "type": "http",
                "request": {
                    "path": ["${HTTP_PATH}"],
                    "headers": {
                        "Host": ["${HTTP_HOST_HEADER}"],
                        "User-Agent": ["${HTTP_USER_AGENT}"],
                        "Accept-Encoding": ["gzip, deflate"],
                        "Connection": ["keep-alive"]
                    }
                }
            }
        }
    }
EOF
)
    fi

    XRAY_CONF="$XRAY_CONFIG_DIR/config.json"
    cat >"$XRAY_CONF" <<EOF
{
    "log": { "access": "${XRAY_LOG_DIR}/access.log", "error": "${XRAY_LOG_DIR}/error.log", "loglevel": "warning" },
    "inbounds": [
        {
            "port": ${XRAY_PORT}, "listen": "0.0.0.0", "protocol": "${PROTOCOL}",
            "settings": { "clients": [{"id": "${UUID}"}], "decryption": "none" },
            ${STREAM_SETTINGS_JSON}
        }
    ],
    "outbounds":[{"protocol":"freedom","settings":{}},{"protocol":"blackhole","tag":"blocked","settings":{}}]
}
EOF

    cat >"$SYSTEMD_SERVICE" <<EOF
[Unit]
Description=Xray Service
After=network.target
[Service]
User=${XRAY_USER}
ExecStart=${XRAY_BIN_DIR}/xray -config ${XRAY_CONF}
Restart=on-failure
RestartSec=3s
[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable xray.service

    if ! apply_certificate "$DOMAIN"; then
        echo "安装过程中断，因为证书申请失败。"
        exit 1
    fi

    systemctl restart xray.service

    echo "==================== 安装完成 ===================="
    echo "协议 (Protocol)  : $PROTOCOL"
    echo "传输 (Transport) : $TRANSPORT_NETWORK"
    echo "域名 (Domain)    : $DOMAIN"
    echo "端口 (Port)      : $XRAY_PORT"
    echo "UUID             : $UUID"
    if [ "$TRANSPORT_NETWORK" = "ws" ]; then
        echo "WebSocket 路径   : $HTTP_PATH"
        echo "WebSocket 主机   : $WS_HOST"
    else
        echo "--- HTTP 伪装配置 (仅VMess) ---"
        echo "伪装路径 (Path)  : $HTTP_PATH"
        echo "伪装主机 (Host)  : $HTTP_HOST_HEADER"
        echo "伪装UA (User-Agent): $HTTP_USER_AGENT"
    fi
    echo "--------------------------------------------------"

    local CLIENT_LINK=""
    if [ "$PROTOCOL" = "vless" ]; then
        # VLess 协议在此脚本中只生成 ws 链接
        CLIENT_LINK="vless://${UUID}@${DOMAIN}:${XRAY_PORT}?type=ws&host=${WS_HOST}&path=${HTTP_PATH}&security=tls&sni=${DOMAIN}&encryption=none#${DOMAIN}-vless-ws"
    else # vmess
        local VMESS_JSON=""
        local ps_name="${DOMAIN}-${TRANSPORT_NETWORK}"
        if [ "$TRANSPORT_NETWORK" = "ws" ]; then
            VMESS_JSON=$(jq -n --arg ps "$ps_name" --arg add "$DOMAIN" --arg port "$XRAY_PORT" --arg id "$UUID" --arg host "$WS_HOST" --arg path "$HTTP_PATH" --arg sni "$DOMAIN" \
                '{v:"2",ps:$ps,add:$add,port:$port,id:$id,aid:0,net:"ws",type:"none",host:$host,path:$path,tls:"tls",sni:$sni}')
        else # tcp with http camouflage
            VMESS_JSON=$(jq -n --arg ps "$ps_name" --arg add "$DOMAIN" --arg port "$XRAY_PORT" --arg id "$UUID" --arg host "$HTTP_HOST_HEADER" --arg path "$HTTP_PATH" --arg sni "$DOMAIN" \
                '{v:"2",ps:$ps,add:$add,port:$port,id:$id,aid:0,net:"tcp",type:"http",host:$host,path:$path,tls:"tls",sni:$sni}')
        fi
        CLIENT_LINK="vmess://$(echo -n "$VMESS_JSON" | base64 -w 0)"
    fi

    echo "客户端导入链接:"
    echo "$CLIENT_LINK"
    echo "=================================================="
    echo "常用命令："
    echo "查看 Xray 日志: journalctl -u xray -f"
    echo "重启 Xray 服务: systemctl restart xray"
}

uninstall_xray() {
    read -rp "您确定要卸载 Xray 吗？[y/N]: " confirm
    [[ ! "$confirm" =~ ^[yY]$ ]] && { echo "操作已取消"; exit 0; }

    systemctl stop xray.service || true
    systemctl disable xray.service || true

    if [ -d "$ACME_DIR" ]; then
        "$ACME_DIR/acme.sh" --uninstall >/dev/null 2>&1 || true
        rm -rf "$ACME_DIR"
    fi

    rm -f "$SYSTEMD_SERVICE" "$XRAY_BIN_DIR/xray"
    rm -rf "$XRAY_CONFIG_DIR" "$SSL_DIR" "$XRAY_LOG_DIR"

    systemctl daemon-reload
    echo "==================== 卸载完成 ===================="
}

main() {
    [ "$(id -u)" -ne 0 ] && { echo "错误：请以 root 或 sudo 权限运行此脚本。"; exit 1; }

    clear
    echo "======================================================="
    echo "  Xray 一键安装脚本 (vFinal-fix)"
    echo "======================================================="
    echo "--- 安装选项 ---"
    echo " 1) 安装 VLESS + WebSocket + TLS"
    echo " 2) 安装 VMess + WebSocket + TLS"
    echo "-------------------------------------------------------"
    echo "--- 管理选项 ---"
    echo " 4) 卸载 Xray"
    echo " 5) 查看 Xray 日志"
    echo " 6) 重启 Xray 服务"
    echo "======================================================="
    read -rp "请输入选项 [1-6]: " choice

    case $choice in
        1) install_xray "vless" "ws" ;;
        2) install_xray "vmess" "ws" ;;
        4) uninstall_xray ;;
        5) journalctl -u xray -f ;;
        6) systemctl restart xray.service && echo "Xray 已重启" ;;
        *) echo "错误：无效选项"; exit 1 ;;
    esac
}

main

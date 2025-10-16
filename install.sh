#!/usr/bin/env bash
set -euo pipefail

# =================================================================
# Xray 一键安装脚本 (vFinal-fix - 国内 ZeroSSL 加速)
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
        echo "请确保安全组或其他防火墙已放行 TCP 443 和 80 端口。"
    fi
}

# 检测端口占用
check_port() {
    if ss -ltnp | grep -q ":$1"; then
        echo "错误：端口 $1 已被占用，请先释放该端口再运行脚本。"
        exit 1
    fi
}

# 检测域名解析
check_dns() {
    local domain=$1
    local attempt=1
    local max_attempts=10
    echo "=== 正在检测域名解析，请确保域名已指向本服务器 IP ==="
    local server_ipv4=$(curl -s4 https://api.ipify.org || curl -s4 https://ipinfo.io/ip || echo "")
    local server_ipv6=$(curl -s6 https://api.ipify.org || curl -s6 https://ipinfo.io/ip || echo "")

    if [ -z "$server_ipv4" ] && [ -z "$server_ipv6" ]; then
        echo "错误：无法获取服务器公网 IP。"
        exit 1
    fi

    echo "服务器 IPv4: ${server_ipv4:-N/A}"
    echo "服务器 IPv6: ${server_ipv6:-N/A}"

    while [ $attempt -le $max_attempts ]; do
        echo "--- 第 $attempt / $max_attempts 次尝试 ---"
        local resolved_ipv4=$(dig +short A "$domain" | tail -n1)
        local resolved_ipv6=$(dig +short AAAA "$domain" | tail -n1)
        echo "域名 $domain 解析到 IPv4: ${resolved_ipv4:-N/A}"
        echo "域名 $domain 解析到 IPv6: ${resolved_ipv6:-N/A}"

        local matched=false
        if [ -n "$server_ipv4" ] && [ "$resolved_ipv4" == "$server_ipv4" ]; then matched=true; fi
        if [ -n "$server_ipv6" ] && [ "$resolved_ipv6" == "$server_ipv6" ]; then matched=true; fi

        if $matched; then
            echo "=== 域名解析检测通过 ==="
            return 0
        fi

        echo "域名解析不匹配或尚未生效。"
        if [ $attempt -lt $max_attempts ]; then
            sleep 30
        else
            echo "错误：域名解析检测失败，请确认域名 A/AAAA 记录指向本机 IP。"
            exit 1
        fi
        ((attempt++))
    done
}

# 申请并安装证书（国内 ZeroSSL）
apply_certificate() {
    local domain=$1
    echo "=== 安装 acme.sh ==="
    curl https://get.acme.sh | sh
    chmod +x "$ACME_DIR/acme.sh"
    "$ACME_DIR/acme.sh" --set-default-ca --server zerossl

    local attempt=1
    local max_attempts=3
    while [ $attempt -le $max_attempts ]; do
        echo "=== 第 $attempt 次尝试申请证书 ==="
        "$ACME_DIR/acme.sh" --issue -d "$domain" --standalone --keylength ec-256 --force
        if [ $? -eq 0 ]; then
            mkdir -p "$SSL_DIR"
            "$ACME_DIR/acme.sh" --install-cert -d "$domain" --ecc \
                --key-file "$SSL_DIR/$domain.key" \
                --fullchain-file "$SSL_DIR/$domain.crt" \
                --reloadcmd "systemctl restart xray"
            echo "=== 证书安装成功 ==="
            return 0
        else
            echo "证书申请失败，第 $attempt 次尝试。"
            ((attempt++))
            sleep 5
        fi
    done
    echo "错误：证书申请失败，请检查 80 端口是否可用。"
    exit 1
}

# 安装 Xray
install_xray() {
    local PROTOCOL=$1
    local TRANSPORT_NETWORK=$2

    echo "--- 安装: ${PROTOCOL} + ${TRANSPORT_NETWORK} + TLS ---"
    open_ports

    read -rp "请输入 TLS 域名: " DOMAIN
    [ -z "$DOMAIN" ] && { echo "域名不能为空"; exit 1; }

    read -rp "请输入注册邮箱: " EMAIL
    [ -z "$EMAIL" ] && { echo "邮箱不能为空"; exit 1; }

    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl unzip uuid-runtime openssl socat jq cron python3 dnsutils
    systemctl enable --now cron

    check_dns "$DOMAIN"

    local HTTP_PATH="" WS_HOST="" HTTP_HOST_HEADER="" HTTP_USER_AGENT=""
    if [ "$TRANSPORT_NETWORK" = "ws" ]; then
        read -rp "请输入 WebSocket 路径 [/]: " -e -i "/" HTTP_PATH
        read -rp "请输入 WebSocket Host [${DOMAIN}]: " -e -i "${DOMAIN}" WS_HOST
    else
        read -rp "HTTP 伪装路径 [/]: " -e -i "/" HTTP_PATH
        read -rp "HTTP Host 伪装头 [${DOMAIN}]: " -e -i "${DOMAIN}" HTTP_HOST_HEADER
        read -rp "HTTP User-Agent [Chrome UA]: " -e -i "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/108.0.0.0 Safari/537.36" HTTP_USER_AGENT
    fi

    check_port 80
    check_port $XRAY_PORT

    if ! command -v xray >/dev/null 2>&1; then
        COUNTRY=$(curl -fsS --max-time 8 https://ipinfo.io/country 2>/dev/null || true)
        COUNTRY=$(echo -n "$COUNTRY" | tr -d '\r\n' | tr '[:lower:]' '[:upper:]')
        MIRROR_PREFIX=""
        [ "$COUNTRY" = "CN" ] && MIRROR_PREFIX="https://gh.llkk.cc/https://"
        RELATIVE_URL="github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip"
        XURL="${MIRROR_PREFIX}${RELATIVE_URL}"
        TMP_ZIP="/tmp/xray.zip"
        curl -L -o "$TMP_ZIP" "$XURL"
        unzip -o "$TMP_ZIP" -d /tmp/xray_unpack >/dev/null
        install -m 755 /tmp/xray_unpack/xray "$XRAY_BIN_DIR/xray"
        rm -rf /tmp/xray_unpack "$TMP_ZIP"
    fi

    mkdir -p "$XRAY_CONFIG_DIR" "$SSL_DIR" "$XRAY_LOG_DIR"
    UUID=$(uuidgen)

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
    else
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

    apply_certificate "$DOMAIN"
    systemctl restart xray.service

    # 输出信息
    echo "==================== 安装完成 ===================="
    echo "协议: $PROTOCOL"
    echo "传输: $TRANSPORT_NETWORK"
    echo "域名: $DOMAIN"
    echo "端口: $XRAY_PORT"
    echo "UUID: $UUID"

    local CLIENT_LINK=""
    if [ "$PROTOCOL" = "vless" ]; then
        CLIENT_LINK="vless://${UUID}@${DOMAIN}:${XRAY_PORT}?type=ws&host=${WS_HOST}&path=${HTTP_PATH}&security=tls&sni=${DOMAIN}&encryption=none#${DOMAIN}-vless-ws"
    else
        local VMESS_JSON=""
        local ps_name="${DOMAIN}-${TRANSPORT_NETWORK}"
        if [ "$TRANSPORT_NETWORK" = "ws" ]; then
            VMESS_JSON=$(jq -n --arg ps "$ps_name" --arg add "$DOMAIN" --arg port "$XRAY_PORT" --arg id "$UUID" --arg host "$WS_HOST" --arg path "$HTTP_PATH" --arg sni "$DOMAIN" \
                '{v:"2",ps:$ps,add:$add,port:$port,id:$id,aid:0,net:"ws",type:"none",host:$host,path:$path,tls:"tls",sni:$sni}')
        else
            VMESS_JSON=$(jq -n --arg ps "$ps_name" --arg add "$DOMAIN" --arg port "$XRAY_PORT" --arg id "$UUID" --arg host "$HTTP_HOST_HEADER" --arg path "$HTTP_PATH" --arg sni "$DOMAIN" \
                '{v:"2",ps:$ps,add:$add,port:$port,id:$id,aid:0,net:"tcp",type:"http",host:$host,path:$path,tls:"tls",sni:$sni}')
        fi
        CLIENT_LINK="vmess://$(echo -n "$VMESS_JSON" | base64 -w 0)"
    fi

    echo "客户端导入链接:"
    echo "$CLIENT_LINK"
    echo "=================================================="
}

# 卸载 Xray
uninstall_xray() {
    read -rp "确定卸载 Xray? [y/N]: " confirm
    [[ ! "$confirm" =~ ^[yY]$ ]] && { echo "取消操作"; exit 0; }
    systemctl stop xray.service || true
    systemctl disable xray.service || true
    [ -d "$ACME_DIR" ] && "$ACME_DIR/acme.sh" --uninstall >/dev/null 2>&1 || true
    rm -rf "$ACME_DIR" "$SYSTEMD_SERVICE" "$XRAY_BIN_DIR/xray" "$XRAY_CONFIG_DIR" "$SSL_DIR" "$XRAY_LOG_DIR"
    systemctl daemon-reload
    echo "==================== 卸载完成 ===================="
}

# 主菜单
main() {
    [ "$(id -u)" -ne 0 ] && { echo "请以 root 权限运行"; exit 1; }
    clear
    echo "======================================================="
    echo "  Xray 一键安装脚本 (国内 ZeroSSL 加速)"
    echo "======================================================="
    echo " 1) 安装 VLESS + WebSocket + TLS"
    echo " 2) 安装 VMess + WebSocket + TLS"
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

#!/usr/bin/env bash
set -euo pipefail

# =================================================================
# Xray 一键安装脚本 (vFinal-fix - Git acme.sh + 国内加速 + ZeroSSL)
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
        echo "请确保安全组或服务器防火墙已放行 TCP 443 和 80 端口。"
    fi
}

check_port() {
    if ss -ltnp | grep -q ":$1"; then
        echo "错误：端口 $1 已被占用，请先释放该端口再运行脚本。"
        exit 1
    fi
}

check_dns() {
    local domain=$1
    local attempt=1
    local max_attempts=10
    echo "=== 检测域名解析 ==="
    local server_ipv4=$(curl -s4 https://api.ipify.org || curl -s4 https://ipinfo.io/ip || echo "")
    local server_ipv6=$(curl -s6 https://api.ipify.org || curl -s6 https://ipinfo.io/ip || echo "")
    echo "服务器 IPv4: ${server_ipv4:-N/A}, IPv6: ${server_ipv6:-N/A}"

    while [ $attempt -le $max_attempts ]; do
        local resolved_ipv4=$(dig +short A "$domain" | tail -n1)
        local resolved_ipv6=$(dig +short AAAA "$domain" | tail -n1)
        echo "--- 尝试 $attempt / $max_attempts ---"
        echo "解析 IPv4: ${resolved_ipv4:-N/A}, IPv6: ${resolved_ipv6:-N/A}"

        local matched=false
        [ -n "$server_ipv4" ] && [ "$resolved_ipv4" == "$server_ipv4" ] && matched=true
        [ -n "$server_ipv6" ] && [ "$resolved_ipv6" == "$server_ipv6" ] && matched=true

        $matched && { echo "域名解析正确"; return 0; }
        echo "域名解析不匹配，30秒后重试..."
        sleep 30
        ((attempt++))
    done
    echo "错误：域名解析失败"
    exit 1
}

install_acme_sh() {
    local EMAIL=$1
    echo "=== 安装 acme.sh (Git 克隆) ==="
    COUNTRY=$(curl -fsS --max-time 8 https://ipinfo.io/country 2>/dev/null || true)
    COUNTRY=$(echo -n "$COUNTRY" | tr -d '\r\n' | tr '[:lower:]' '[:upper:]')
    MIRROR_PREFIX=""
    [ "$COUNTRY" = "CN" ] && MIRROR_PREFIX="https://gh.llkk.cc/https://"

    git clone "${MIRROR_PREFIX}github.com/acmesh-official/acme.sh.git" "$HOME/acme.sh" --depth 1
    cd "$HOME/acme.sh"
    ./acme.sh --install -m "$EMAIL" --force
    chmod +x "$HOME/.acme.sh/acme.sh"
    "$HOME/.acme.sh/acme.sh" --set-default-ca --server zerossl
}

apply_certificate() {
    local DOMAIN=$1
    echo "=== 申请 ZeroSSL 证书 ==="
    install_acme_sh "$EMAIL"
    mkdir -p "$SSL_DIR"
    local attempt=1
    local max_attempts=3
    while [ $attempt -le $max_attempts ]; do
        "$HOME/.acme.sh/acme.sh" --issue -d "$DOMAIN" --standalone --keylength ec-256 --force && break
        echo "申请失败，重试..."
        ((attempt++))
        sleep 5
    done
    [ $attempt -gt $max_attempts ] && { echo "证书申请失败"; exit 1; }
    "$HOME/.acme.sh/acme.sh" --install-cert -d "$DOMAIN" --ecc \
        --key-file "$SSL_DIR/$DOMAIN.key" \
        --fullchain-file "$SSL_DIR/$DOMAIN.crt" \
        --reloadcmd "systemctl restart xray"
    echo "证书安装成功"
}

install_xray() {
    local PROTOCOL=$1
    local TRANSPORT_NETWORK=$2
    echo "--- 安装: $PROTOCOL + $TRANSPORT_NETWORK + TLS ---"
    open_ports
    [ -d "$ACME_DIR" ] && rm -rf "$ACME_DIR"

    read -rp "请输入 TLS 域名: " DOMAIN
    [ -z "$DOMAIN" ] && { echo "域名不能为空"; exit 1; }
    read -rp "请输入邮箱: " EMAIL
    [ -z "$EMAIL" ] && { echo "邮箱不能为空"; exit 1; }

    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl unzip uuid-runtime openssl socat jq cron python3 dnsutils
    systemctl enable --now cron

    check_dns "$DOMAIN"

    local HTTP_PATH="" WS_HOST="" HTTP_HOST_HEADER="" HTTP_USER_AGENT=""
    if [ "$TRANSPORT_NETWORK" = "ws" ]; then
        read -rp "WebSocket 路径 [/]: " -e -i "/" HTTP_PATH
        read -rp "WebSocket Host [${DOMAIN}]: " -e -i "${DOMAIN}" WS_HOST
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
        echo "下载 Xray 核心..."
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

    echo "==================== 安装完成 ===================="
    echo "协议 : $PROTOCOL"
    echo "传输 : $TRANSPORT_NETWORK"
    echo "域名 : $DOMAIN"
    echo "端口 : $XRAY_PORT"
    echo "UUID  : $UUID"
}

uninstall_xray() {
    read -rp "确认卸载 Xray ? [y/N]: " confirm
    [[ ! "$confirm" =~ ^[yY]$ ]] && exit 0
    systemctl stop xray.service || true
    systemctl disable xray.service || true
    [ -d "$ACME_DIR" ] && "$ACME_DIR/acme.sh" --uninstall >/dev/null 2>&1
    rm -f "$SYSTEMD_SERVICE" "$XRAY_BIN_DIR/xray"
    rm -rf "$XRAY_CONFIG_DIR" "$SSL_DIR" "$XRAY_LOG_DIR"
    systemctl daemon-reload
    echo "卸载完成"
}

main() {
    [ "$(id -u)" -ne 0 ] && { echo "请使用 root 执行"; exit 1; }
    clear
    echo "Xray 一键安装脚本 (Git acme.sh + 国内加速)"
    echo "1) 安装 VLESS + WS + TLS"
    echo "2) 安装 VMess + WS + TLS"
    echo "4) 卸载 Xray"
    echo "5) 查看日志"
    echo "6) 重启服务"
    read -rp "请输入选项 [1-6]: " choice

    case $choice in
        1) install_xray "vless" "ws" ;;
        2) install_xray "vmess" "ws" ;;
        4) uninstall_xray ;;
        5) journalctl -u xray -f ;;
        6) systemctl restart xray.service && echo "Xray 已重启" ;;
        *) echo "无效选项"; exit 1 ;;
    esac
}

main

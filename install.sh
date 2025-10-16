#!/usr/bin/env bash
set -euo pipefail

# =================================================================
# Xray 一键安装脚本 (vFinal-fix - 支持多 CA 轮询 & 国内加速)
# =================================================================


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
    echo "=== 配置防火墙... ==="
    if command -v iptables >/dev/null 2>&1; then
        iptables -P INPUT ACCEPT
        iptables -P FORWARD ACCEPT
        iptables -P OUTPUT ACCEPT
        iptables -F
        if command -v netfilter-persistent >/dev/null 2>&1; then
            netfilter-persistent save
        fi
    else
        echo "未检测到 iptables，请确保安全组/防火墙允许 80/443 端口"
    fi
}

check_port() {
    if ss -ltnp | grep -q ":$1"; then
        echo "错误：端口 $1 已被占用"
        exit 1
    fi
}

check_dns() {
    local domain=$1
    local attempt=1
    local max_attempts=10

    local server_ipv4=$(curl -s4 https://api.ipify.org || curl -s4 https://ipinfo.io/ip || echo "")
    local server_ipv6=$(curl -s6 https://api.ipify.org || curl -s6 https://ipinfo.io/ip || echo "")

    if [ -z "$server_ipv4" ] && [ -z "$server_ipv6" ]; then
        echo "无法获取服务器公网 IP"
        exit 1
    fi

    while [ $attempt -le $max_attempts ]; do
        local resolved_ipv4=$(dig +short A "$domain" | tail -n1)
        local resolved_ipv6=$(dig +short AAAA "$domain" | tail -n1)

        local matched=false
        [ -n "$server_ipv4" ] && [ "$resolved_ipv4" == "$server_ipv4" ] && matched=true
        [ -n "$server_ipv6" ] && [ "$resolved_ipv6" == "$server_ipv6" ] && matched=true

        if $matched; then
            echo "域名解析正确"
            return 0
        fi

        echo "域名解析未生效，30 秒后重试..."
        sleep 30
        ((attempt++))
    done

    echo "域名解析检测失败"
    exit 1
}

install_acme_sh() {
    local EMAIL=$1
    local MIRROR_PREFIX=""
    # 如果在中国大陆使用国内镜像
    COUNTRY=$(curl -fsS --max-time 8 https://ipinfo.io/country 2>/dev/null || true)
    COUNTRY=$(echo -n "$COUNTRY" | tr -d '\r\n' | tr '[:lower:]' '[:upper:]')
    [ "$COUNTRY" = "CN" ] && MIRROR_PREFIX="https://gh.llkk.cc/"

    # 删除旧目录（防止冲突）
    if [ -d "$ACME_DIR" ]; then
        echo "$ACME_DIR 已存在，尝试更新..."
        cd "$ACME_DIR" && git pull || { echo "更新失败，请手动处理"; exit 1; }
    else
        git clone "${MIRROR_PREFIX}https://github.com/acmesh-official/acme.sh.git" "$ACME_DIR"
    fi

    cd "$ACME_DIR"
    ./acme.sh --install -m "$EMAIL" --force
    chmod +x "$ACME_DIR/acme.sh"
}




apply_certificate() {
    local DOMAIN=$1
    local EMAIL=$2
    echo "=== 申请 SSL 证书 ==="
    install_acme_sh "$EMAIL"
    mkdir -p "$SSL_DIR"

    local CA_LIST=("zerossl" "letsencrypt" "ssl.com" "actalis" "pebble")
    local CA_NAME
    for CA_NAME in "${CA_LIST[@]}"; do
        echo "尝试使用 CA: $CA_NAME"
        for attempt in {1..3}; do
            if "$ACME_DIR/acme.sh" --issue -d "$DOMAIN" --standalone --keylength ec-256 --server "$CA_NAME" --force; then
                echo "证书申请成功 (CA: $CA_NAME)"
                "$ACME_DIR/acme.sh" --install-cert -d "$DOMAIN" --ecc \
                    --key-file "$SSL_DIR/$DOMAIN.key" \
                    --fullchain-file "$SSL_DIR/$DOMAIN.crt" \
                    --reloadcmd "systemctl restart xray"
                return 0
            else
                echo "申请失败 (第 $attempt 次)，重试..."
                sleep 5
            fi
        done
        echo "使用 CA $CA_NAME 申请失败，尝试下一个 CA..."
    done

    echo "错误：所有 CA 均申请失败，请检查 80 端口或网络是否可访问"
    exit 1
}

install_xray() {
    local PROTOCOL=$1
    local TRANSPORT=$2

    echo "--- 安装: $PROTOCOL + $TRANSPORT + TLS ---"
    open_ports

    read -rp "请输入域名: " DOMAIN
    [ -z "$DOMAIN" ] && { echo "域名不能为空"; exit 1; }
    read -rp "请输入邮箱: " EMAIL
    [ -z "$EMAIL" ] && { echo "邮箱不能为空"; exit 1; }

    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl unzip uuid-runtime openssl socat jq cron python3 dnsutils
    systemctl enable --now cron

    check_dns "$DOMAIN"

    local HTTP_PATH="/" WS_HOST="$DOMAIN" HTTP_HOST_HEADER="$DOMAIN" HTTP_USER_AGENT="Mozilla/5.0"
    if [ "$TRANSPORT" = "ws" ]; then
        read -rp "WebSocket 路径 [/]: " -e -i "/" HTTP_PATH
        read -rp "WebSocket Host [${DOMAIN}]: " -e -i "${DOMAIN}" WS_HOST
    else
        read -rp "HTTP 伪装路径 [/]: " -e -i "/" HTTP_PATH
        read -rp "HTTP Host 伪装头 [${DOMAIN}]: " -e -i "${DOMAIN}" HTTP_HOST_HEADER
        read -rp "HTTP User-Agent [默认Chrome UA]: " -e -i "$HTTP_USER_AGENT" HTTP_USER_AGENT
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
    local UUID=$(uuidgen)
    echo "生成 UUID: $UUID"

    local STREAM_SETTINGS=""
    if [ "$TRANSPORT" = "ws" ]; then
        STREAM_SETTINGS=$(cat <<EOF
"streamSettings": {
    "network": "ws", "security": "tls",
    "tlsSettings": { "certificates": [{"certificateFile": "${SSL_DIR}/${DOMAIN}.crt","keyFile": "${SSL_DIR}/${DOMAIN}.key"}], "serverName": "${DOMAIN}" },
    "wsSettings": {"path": "${HTTP_PATH}","headers":{ "Host": "${WS_HOST}" }}
}
EOF
)
    else
        STREAM_SETTINGS=$(cat <<EOF
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

    cat >"$XRAY_CONFIG_DIR/config.json" <<EOF
{
"log": { "access": "${XRAY_LOG_DIR}/access.log", "error": "${XRAY_LOG_DIR}/error.log", "loglevel": "warning" },
"inbounds": [
    {
        "port": ${XRAY_PORT}, "listen": "0.0.0.0", "protocol": "${PROTOCOL}",
        "settings": { "clients": [{"id": "${UUID}"}], "decryption": "none" },
        ${STREAM_SETTINGS}
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
ExecStart=${XRAY_BIN_DIR}/xray -config ${XRAY_CONFIG_DIR}/config.json
Restart=on-failure
RestartSec=3s
[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable xray.service

    apply_certificate "$DOMAIN" "$EMAIL"
    systemctl restart xray.service

    echo "安装完成！"
    echo "UUID: $UUID"
    echo "域名: $DOMAIN"
    echo "端口: $XRAY_PORT"
    echo "WebSocket路径: $HTTP_PATH"
    echo "客户端链接: "
    if [ "$PROTOCOL" = "vless" ]; then
        echo "vless://${UUID}@${DOMAIN}:${XRAY_PORT}?type=ws&host=${WS_HOST}&path=${HTTP_PATH}&security=tls&sni=${DOMAIN}&encryption=none#${DOMAIN}-vless-ws"
    else
        local VMESS_JSON=$(jq -n --arg ps "${DOMAIN}-${TRANSPORT}" --arg add "$DOMAIN" --arg port "$XRAY_PORT" --arg id "$UUID" --arg host "$WS_HOST" --arg path "$HTTP_PATH" --arg sni "$DOMAIN" \
            '{v:"2",ps:$ps,add:$add,port:$port,id:$id,aid:0,net:"ws",type:"none",host:$host,path:$path,tls:"tls",sni:$sni}')
        echo "vmess://$(echo -n "$VMESS_JSON" | base64 -w 0)"
    fi
}

uninstall_xray() {
    read -rp "确定卸载 Xray? [y/N]: " confirm
    [[ ! "$confirm" =~ ^[yY]$ ]] && { echo "取消"; exit 0; }
    systemctl stop xray.service || true
    systemctl disable xray.service || true
    [ -d "$ACME_DIR" ] && "$ACME_DIR/acme.sh" --uninstall >/dev/null 2>&1 || true
    rm -rf "$ACME_DIR" "$SYSTEMD_SERVICE" "$XRAY_BIN_DIR/xray" "$XRAY_CONFIG_DIR" "$SSL_DIR" "$XRAY_LOG_DIR"
    systemctl daemon-reload
    echo "卸载完成"
}

main() {
    [ "$(id -u)" -ne 0 ] && { echo "请使用 root"; exit 1; }

    clear
    echo "=== Xray 一键安装脚本 ==="
    echo "1) 安装 VLESS + WS + TLS"
    echo "2) 安装 VMess + WS + TLS"
    echo "4) 卸载 Xray"
    echo "5) 查看日志"
    echo "6) 重启服务"
    read -rp "请选择 [1-6]: " choice

    case $choice in
        1) install_xray "vless" "ws" ;;
        2) install_xray "vmess" "ws" ;;
        4) uninstall_xray ;;
        5) journalctl -u xray -f ;;
        6) systemctl restart xray.service && echo "已重启" ;;
        *) echo "无效"; exit 1 ;;
    esac
}

main

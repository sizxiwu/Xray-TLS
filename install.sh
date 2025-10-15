#!/usr/bin/env bash
set -euo pipefail

# =================================================================
# Xray 一键安装脚本 (直达菜单版)
#
# 特性:
# - 主菜单直接选择安装组合, 无需二次选择
# - VLESS/VMess: 均支持 WebSocket+TLS 和 TCP+HTTP伪装
# - VLESS+TCP 模式强制 ALPN 为 http/1.1
# - 自动流程: 智能检测域名, 自动管理证书
# - 高度自定义: TCP模式支持自定义HTTP伪装头
# =================================================================


# ========================
# 配置参数
# ========================
XRAY_PORT=443
WS_HOST="yunpanlive.chinaunicomvideo.cn"
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
    echo "=== 放通所有端口，清空防火墙规则 ==="
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -P OUTPUT ACCEPT
    iptables -F
    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save
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
    echo "=== 正在检测域名解析，请确保域名已指向本服务器 IP ==="
    local server_ip=$(curl -s4 https://api.ipify.org || curl -s4 https://ipinfo.io/ip)
    echo "服务器 IPv4 地址: ${server_ip:-N/A}"
    local attempt=1
    while [ $attempt -le 10 ]; do
        local resolved_ip=$(dig +short A "$domain" | tail -n1)
        echo "--- 第 $attempt/10 次尝试: $domain 解析到 ${resolved_ip:-N/A} ---"
        if [ "$resolved_ip" == "$server_ip" ]; then
            echo "=== 域名解析检测通过！ ==="
            return 0
        fi
        [ $attempt -lt 10 ] && sleep 30 || { echo "错误：域名解析检测失败。"; exit 1; }
        ((attempt++))
    done
}

# 申请并安装证书
apply_certificate() {
    local domain=$1
    local email=$2
    
    # 安装 acme.sh
    [ -d "$ACME_DIR" ] && rm -rf "$ACME_DIR"
    curl https://get.acme.sh | sh -s email=$email --force
    chmod +x "$ACME_DIR/acme.sh"

    local attempt=1
    while [ $attempt -le 3 ]; do
        echo "=== 正在尝试申请 SSL 证书 (第 $attempt/3 次)... ==="
        if "$ACME_DIR/acme.sh" --issue -d "$domain" --standalone --keylength ec-256 --force; then
            echo "=== 证书申请成功！ ==="
            if "$ACME_DIR/acme.sh" --install-cert -d "$domain" --ecc --key-file "$SSL_DIR/$domain.key" --fullchain-file "$SSL_DIR/$domain.crt" --reloadcmd "systemctl restart xray"; then
                echo "=== 证书安装成功！ ==="
                return 0
            fi
        fi
        echo "错误：证书操作失败 (第 $attempt 次)。"
        [ $attempt -lt 3 ] && sleep 5 || { echo "错误：已达到最大重试次数。"; return 1; }
        ((attempt++))
    done
}


install_xray() {
    local PROTOCOL=$1
    local TRANSPORT_NETWORK=$2

    echo "--- 您选择了安装: ${PROTOCOL} + ${TRANSPORT_NETWORK} ---"
    open_ports

    # --- 基础信息收集 ---
    read -rp "请输入 TLS 使用的域名: " DOMAIN
    [ -z "$DOMAIN" ] && { echo "域名不能为空"; exit 1; }
    read -rp "请输入用于证书注册的邮箱: " EMAIL
    [ -z "$EMAIL" ] && { echo "邮箱不能为空"; exit 1; }

    # --- 环境准备 ---
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl unzip uuid-runtime openssl socat jq cron python3 dnsutils
    systemctl enable --now cron

    if ! command -v xray >/dev/null 2>&1; then
        echo "正在下载 Xray 核心..."
        COUNTRY=$(curl -fsS --max-time 8 https://ipinfo.io/country 2>/dev/null || true | tr -d '\r\n' | tr '[:lower:]' '[:upper:]')
        MIRROR_PREFIX=""
        [ "$COUNTRY" = "CN" ] && MIRROR_PREFIX="https://gh.llkk.cc/https://"
        XURL="${MIRROR_PREFIX}github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip"
        TMP_ZIP="/tmp/xray.zip"
        curl -L -o "$TMP_ZIP" "$XURL"
        unzip -o "$TMP_ZIP" -d /tmp/xray_unpack >/dev/null
        install -m 755 /tmp/xray_unpack/xray "$XRAY_BIN_DIR/xray"
        rm -rf /tmp/xray_unpack "$TMP_ZIP"
    fi
    
    check_dns "$DOMAIN"
    check_port 80
    check_port $XRAY_PORT
    mkdir -p "$XRAY_CONFIG_DIR" "$SSL_DIR" "$XRAY_LOG_DIR"

    # --- 配置生成 ---
    UUID=$(uuidgen)
    HTTP_PATH=""
    HTTP_HOST_HEADER=""
    HTTP_USER_AGENT=""
    STREAM_SETTINGS_JSON=""

    # 根据协议和传输方式，决定 ALPN 设置
    local ALPN_JSON='"alpn": ["h2","http/1.1"]' # 默认值
    if [ "$PROTOCOL" = "vless" ] && [ "$TRANSPORT_NETWORK" = "tcp" ]; then
        echo "--- VLESS+TCP 模式已强制 ALPN 为 http/1.1 ---"
        ALPN_JSON='"alpn": ["http/1.1"]'
    fi

    if [ "$TRANSPORT_NETWORK" = "ws" ]; then
        read -rp "请输入 WebSocket 路径 [/]: " -e -i "/" HTTP_PATH
        STREAM_SETTINGS_JSON=$(cat <<EOF
    "streamSettings": { "network": "ws", "security": "tls", "tlsSettings": { ${ALPN_JSON}, "certificates": [{"certificateFile": "${SSL_DIR}/${DOMAIN}.crt","keyFile": "${SSL_DIR}/${DOMAIN}.key"}], "serverName": "${DOMAIN}" }, "wsSettings": {"path": "${HTTP_PATH}","headers":{ "Host": "${WS_HOST}" }}}
EOF
)
    else # tcp
        read -rp "请输入 HTTP 伪装路径 [/]: " -e -i "/" HTTP_PATH
        read -rp "请输入 HTTP Host 伪装头 [${DOMAIN}]: " -e -i "${DOMAIN}" HTTP_HOST_HEADER
        read -rp "请输入 HTTP User-Agent 伪装头 [Chrome UA]: " -e -i "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/108.0.0.0 Safari/537.36" HTTP_USER_AGENT
        STREAM_SETTINGS_JSON=$(cat <<EOF
    "streamSettings": { "network": "tcp", "security": "tls", "tlsSettings": { ${ALPN_JSON}, "certificates": [{"certificateFile": "${SSL_DIR}/${DOMAIN}.crt","keyFile": "${SSL_DIR}/${DOMAIN}.key"}], "serverName": "${DOMAIN}" }, "tcpSettings": { "header": { "type": "http", "request": { "path": ["${HTTP_PATH}"], "headers": { "Host": ["${HTTP_HOST_HEADER}"], "User-Agent": ["${HTTP_USER_AGENT}"] }}}}}
EOF
)
    fi

    XRAY_CONF="$XRAY_CONFIG_DIR/config.json"
    cat >"$XRAY_CONF" <<EOF
{
    "log": { "access": "${XRAY_LOG_DIR}/access.log", "error": "${XRAY_LOG_DIR}/error.log", "loglevel": "warning" },
    "inbounds": [ { "port": ${XRAY_PORT}, "listen": "0.0.0.0", "protocol": "${PROTOCOL}", "settings": { "clients": [{"id": "${UUID}"}], "decryption": "none" }, ${STREAM_SETTINGS_JSON} } ],
    "outbounds":[{"protocol":"freedom","settings":{}},{"protocol":"blackhole","tag":"blocked","settings":{}}]
}
EOF

    # --- 申请证书并启动服务 ---
    if ! apply_certificate "$DOMAIN" "$EMAIL"; then echo "安装因证书申请失败而中断。"; exit 1; fi
    
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
    systemctl restart xray.service

    # --- 显示安装结果 ---
    echo "==================== 安装完成 ===================="
    echo "协议 (Protocol)  : $PROTOCOL"
    echo "传输 (Transport) : $TRANSPORT_NETWORK + TLS"
    echo "域名 (Domain)    : $DOMAIN"
    echo "端口 (Port)      : $XRAY_PORT"
    echo "UUID             : $UUID"
    
    CLIENT_LINK=""
    if [ "$PROTOCOL" = "vless" ]; then
        if [ "$TRANSPORT_NETWORK" = "ws" ]; then
            CLIENT_LINK="vless://${UUID}@${DOMAIN}:${XRAY_PORT}?type=ws&host=${WS_HOST}&path=${HTTP_PATH}&security=tls&sni=${DOMAIN}&encryption=none#${DOMAIN}-vless-ws"
        else # tcp
            CLIENT_LINK="vless://${UUID}@${DOMAIN}:${XRAY_PORT}?security=tls&sni=${DOMAIN}&encryption=none&type=http&host=${HTTP_HOST_HEADER}&path=${HTTP_PATH}#${DOMAIN}-vless-tcp-http1"
        fi
    else # VMess
        ps_name="${DOMAIN}-${TRANSPORT_NETWORK}"
        if [ "$TRANSPORT_NETWORK" = "ws" ]; then
            vmess_json=$(jq -n --arg ps "$ps_name" --arg add "$DOMAIN" --arg port "$XRAY_PORT" --arg id "$UUID" --arg host "$WS_HOST" --arg path "$HTTP_PATH" --arg sni "$DOMAIN" '{v:"2",ps:$ps,add:$add,port:$port,id:$id,aid:0,net:"ws",type:"none",host:$host,path:$path,tls:"tls",sni:$sni}')
        else # tcp
            vmess_json=$(jq -n --arg ps "$ps_name" --arg add "$DOMAIN" --arg port "$XRAY_PORT" --arg id "$UUID" --arg host "$HTTP_HOST_HEADER" --arg path "$HTTP_PATH" --arg sni "$DOMAIN" '{v:"2",ps:$ps,add:$add,port:$port,id:$id,aid:0,net:"tcp",type:"http",host:$host,path:$path,tls:"tls",sni:$sni}')
        fi
        CLIENT_LINK="vmess://$(echo -n "$vmess_json" | base64 -w 0)"
    fi
    echo "--------------------------------------------------"
    echo "客户端导入链接:"
    echo "$CLIENT_LINK"
    echo "=================================================="
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
    echo "  Xray 一键安装脚本 (直达菜单版)"
    echo "======================================================="
    echo "--- VLESS 安装选项 ---"
    echo " 1) 安装 VLESS + WebSocket + TLS"
    echo " 2) 安装 VLESS + TCP + HTTP伪装 (强制HTTP/1.1)"
    echo "--- VMess 安装选项 ---"
    echo " 3) 安装 VMess + WebSocket + TLS"
    echo " 4) 安装 VMess + TCP + HTTP伪装"
    echo "-------------------------------------------------------"
    echo "--- 管理选项 ---"
    echo " 5) 卸载 Xray"
    echo " 6) 查看 Xray 日志"
    echo " 7) 重启 Xray 服务"
    echo "======================================================="
    read -rp "请输入选项 [1-7]: " choice
    case $choice in
        1) install_xray "vless" "ws" ;;
        2) install_xray "vless" "tcp" ;;
        3) install_xray "vmess" "ws" ;;
        4) install_xray "vmess" "tcp" ;;
        5) uninstall_xray ;;
        6) journalctl -u xray -f ;;
        7) systemctl restart xray.service && echo "Xray 已重启" ;;
        *) echo "错误：无效选项"; exit 1 ;;
    esac
}

main

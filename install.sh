#!/usr/bin/env bash
set -euo pipefail

# ========================
# 配置参数
# ========================
XRAY_PORT=443
WS_PATH="/"
WS_HOST="yunpanlive.chinaunicomvideo.cn"
XRAY_USER="root"
XRAY_BIN_DIR="/usr/local/bin"
XRAY_CONFIG_DIR="/usr/local/etc/xray"
SYSTEMD_SERVICE="/etc/systemd/system/xray.service"
SSL_DIR="/etc/ssl/vmess_tls"
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
    else
        echo "未安装 netfilter-persistent，跳过保存规则"
    fi
}

# 检测端口占用
check_port() {
    if ss -ltnp | grep -q ":$1"; then
        echo "错误：端口 $1 已被占用，请先释放该端口再运行脚本。"
        exit 1
    fi
}

install_xray() {
    echo "开始执行 Xray 安装流程..."
    open_ports

    # 清理旧 acme.sh
    [ -d "$ACME_DIR" ] && rm -rf "$ACME_DIR"

    # 输入域名和邮箱
    read -rp "请输入 TLS 使用的域名（例如 xxx.com）： " DOMAIN
    [ -z "$DOMAIN" ] && { echo "域名不能为空"; exit 1; }

    read -rp "请输入用于证书注册的邮箱： " EMAIL
    [ -z "$EMAIL" ] && { echo "邮箱不能为空"; exit 1; }

    # 选择协议
    echo "请选择协议类型:"
    echo "1) VMess"
    echo "2) VLess"
    read -rp "请输入选项 [1-2]: " PROTO_CHOICE
    case $PROTO_CHOICE in
        1) PROTOCOL="vmess" ;;
        2) PROTOCOL="vless" ;;
        *) echo "错误：无效选项"; exit 1;;
    esac

    # 安装依赖
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl unzip uuid-runtime openssl socat jq cron python3
    systemctl enable cron && systemctl start cron

    # 检测端口 80/443
    check_port 80
    check_port $XRAY_PORT

    # 安装 acme.sh（使用正确的参数格式）
    if ! curl -fsSL https://get.acme.sh | /bin/sh -s -- --force; then
        echo "警告：acme.sh 安装失败，将尝试使用 certbot 回退。"
    fi
    chmod +x "$ACME_DIR/acme.sh" 2>/dev/null || true

    # 下载并安装 Xray
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

    # 创建目录
    mkdir -p "$XRAY_CONFIG_DIR" "$SSL_DIR" "$XRAY_LOG_DIR"

    UUID=$(uuidgen)
    echo "生成 UUID: $UUID"

    # 写 Xray 配置
    XRAY_CONF="$XRAY_CONFIG_DIR/config.json"
    cat >"$XRAY_CONF" <<EOF
{
  "log": {
    "access": "${XRAY_LOG_DIR}/access.log",
    "error": "${XRAY_LOG_DIR}/error.log",
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": ${XRAY_PORT},
      "listen": "0.0.0.0",
      "protocol": "${PROTOCOL}",
      "settings": {
        "clients": [{"id": "${UUID}","flow":""}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {
          "certificates": [{"certificateFile": "${SSL_DIR}/${DOMAIN}.crt","keyFile": "${SSL_DIR}/${DOMAIN}.key"}],
          "serverName": "${DOMAIN}"
        },
        "wsSettings": {"path": "${WS_PATH}","headers":{}}
      }
    }
  ],
  "outbounds":[{"protocol":"freedom","settings":{}},{"protocol":"blackhole","tag":"blocked","settings":{}}]
}
EOF

    # systemd 服务
    cat >"$SYSTEMD_SERVICE" <<EOF
[Unit]
Description=Xray Service
After=network.target
[Service]
User=$XRAY_USER
ExecStart=$XRAY_BIN_DIR/xray -config $XRAY_CONF
Restart=on-failure
RestartSec=3s
[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable xray.service

    # 申请证书并重启 Xray（优先 acme.sh，否则回退到 certbot）
    if [ -x "$ACME_DIR/acme.sh" ]; then
        "$ACME_DIR/acme.sh" --issue -d "$DOMAIN" --standalone --keylength ec-256 --force || true
        "$ACME_DIR/acme.sh" --install-cert -d "$DOMAIN" \
            --key-file "$SSL_DIR/$DOMAIN.key" \
            --fullchain-file "$SSL_DIR/$DOMAIN.crt" \
            --reloadcmd "systemctl restart xray" || true
    fi

    # 如果上面的 acme.sh 没成功（或未安装），尝试 certbot（并确保复制到 SSL_DIR）
    if [ ! -f "$SSL_DIR/$DOMAIN.crt" ] || [ ! -f "$SSL_DIR/$DOMAIN.key" ]; then
        if certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos --email "$EMAIL" --force-renewal; then
            mkdir -p "$SSL_DIR"
            cp -L "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" "$SSL_DIR/$DOMAIN.crt" || true
            cp -L "/etc/letsencrypt/live/$DOMAIN/privkey.pem" "$SSL_DIR/$DOMAIN.key" || true
            chmod 644 "$SSL_DIR/$DOMAIN.crt" || true
            chmod 600 "$SSL_DIR/$DOMAIN.key" || true
            systemctl restart xray.service || true
        fi
    else
        # 如果 acme.sh 已放好证书，重启 xray 生效
        systemctl restart xray.service || true
    fi

    # 输出客户端可导入链接
    if [ "$PROTOCOL" = "vless" ]; then
        CLIENT_LINK="vless://${UUID}@${DOMAIN}:443?type=ws&host=${WS_HOST}&path=${WS_PATH}&security=tls&sni=${DOMAIN}&encryption=none#vless-ws-tls"
    else
        CLIENT_JSON=$(cat <<EOF
{"v":"2","ps":"vmess-ws-tls","add":"$DOMAIN","port":"443","id":"$UUID","aid":"0","net":"ws","type":"none","host":"$WS_HOST","path":"$WS_PATH","tls":"tls","sni":"$DOMAIN","allowInsecure":false}
EOF
)
        CLIENT_LINK="vmess://$(echo -n "$CLIENT_JSON" | base64 -w 0)"
    fi

    echo "==================== 安装完成 ===================="
    echo "${PROTOCOL} 链接："
    echo "$CLIENT_LINK"
    echo "查看 Xray 日志：journalctl -u xray -f"
}

uninstall_xray() {
    read -rp "您确定要卸载 Xray 吗？这将删除所有相关文件、证书和配置。[y/N]: " confirm
    [[ ! "$confirm" =~ ^[yY]$ ]] && { echo "操作已取消"; exit 0; }

    systemctl stop xray.service || true
    systemctl disable xray.service || true
    [ -d "$ACME_DIR" ] && "$ACME_DIR/acme.sh" --uninstall && rm -rf "$ACME_DIR"
    rm -f "$SYSTEMD_SERVICE" "$XRAY_BIN_DIR/xray"
    rm -rf "$XRAY_CONFIG_DIR" "$SSL_DIR" "$XRAY_LOG_DIR"
    systemctl daemon-reload
    echo "==================== 卸载完成 ===================="
}

main() {
    [ "$(id -u)" -ne 0 ] && { echo "请以 root 或 sudo 权限运行此脚本。"; exit 1; }

    echo "=========================================="
    echo " Xray 一键安装/卸载/重启/日志脚本（VMess/VLess）"
    echo "=========================================="
    echo "1) 安装 Xray (VMess/VLess)"
    echo "2) 卸载 Xray"
    echo "3) 查看 Xray 日志"
    echo "4) 重启 Xray 服务"
    echo "=========================================="
    read -rp "请输入选项 [1-4]: " choice

    case $choice in
        1) install_xray ;;
        2) uninstall_xray ;;
        3) journalctl -u xray -f ;;
        4) systemctl restart xray.service && echo "Xray 已重启完成" ;;
        *) echo "错误：无效选项"; exit 1 ;;
    esac
}

main

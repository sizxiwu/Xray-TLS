#!/usr/bin/env bash
set -euo pipefail

# ========================
# 配置参数
# ========================
XRAY_PORT=443
WS_PATH="/"
# WebSocket (ws) 模式下伪装的 Host，可自行修改
WS_HOST="yunpanlive.chinaunicomvideo.cn"
# 按要求，使用 root 用户运行
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

# 开放端口并清空防火墙 (恢复为原始版本，不进行询问)
open_ports() {
    echo "=== 放通所有端口，清空防火墙规则 ==="
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -P OUTPUT ACCEPT
    iptables -F
    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save
        echo "防火墙规则已清空并保存。"
    else
        echo "未安装 netfilter-persistent，跳过保存规则。"
    fi
}


# 检测端口占用
check_port() {
    if ss -ltnp | grep -q ":$1"; then
        echo "错误：端口 $1 已被占用，请先释放该端口再运行脚本。"
        exit 1
    fi
}

# 申请并安装证书，带重试逻辑
apply_certificate() {
    local domain=$1
    local attempt=1
    local max_attempts=3
    
    while [ $attempt -le $max_attempts ]; do
        echo "=== 正在尝试申请 SSL 证书 (第 $attempt / $max_attempts 次)... ==="
        # 使用 --standalone 模式申请证书，它会自动监听 80 端口
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
                echo "错误：证书安装失败！请检查 $SSL_DIR 目录权限。"
                return 1
            fi
        else
            echo "错误：证书申请失败 (第 $attempt 次尝试)。"
            if [ $attempt -lt $max_attempts ]; then
                echo "将在 5 秒后重试..."
                sleep 5
            else
                echo "错误：已达到最大重试次数，证书申请失败。"
                echo "请检查："
                echo "1. 您的域名 ($domain) 是否正确解析到了本服务器的 IP 地址。"
                echo "2. 服务器防火墙是否已放行 80 端口。"
                echo "3. 是否有其他程序（如 nginx, apache）占用了 80 端口。"
                return 1
            fi
        fi
        ((attempt++))
    done
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
    echo "请选择代理协议:"
    echo "1) VMess"
    echo "2) VLess"
    read -rp "请输入选项 [1-2]: " PROTO_CHOICE
    case $PROTO_CHOICE in
        1) PROTOCOL="vmess";;
        2) PROTOCOL="vless";;
        *) echo "错误：无效选项"; exit 1;;
    esac

    # 选择传输协议
    echo "请选择传输协议:"
    echo "1) WebSocket + TLS (ws)"
    echo "2) TCP + TLS (tcp)"
    read -rp "请输入选项 [1-2]: " TRANSPORT_CHOICE
    TRANSPORT_NETWORK=""
    XRAY_FLOW="" # 仅用于 VLESS + TCP
    case $TRANSPORT_CHOICE in
        1) TRANSPORT_NETWORK="ws";;
        2) TRANSPORT_NETWORK="tcp";;
        *) echo "错误：无效选项"; exit 1;;
    esac

    # 如果是 VLESS + TCP, 默认启用 XTLS-Vision
    if [ "$PROTOCOL" = "vless" ] && [ "$TRANSPORT_NETWORK" = "tcp" ]; then
        XRAY_FLOW="xtls-rprx-vision"
    fi

    # 安装依赖
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl unzip uuid-runtime openssl socat jq cron python3
    systemctl enable --now cron

    # 检测端口 80/443
    check_port 80
    check_port $XRAY_PORT

    # 安装 acme.sh
    curl https://get.acme.sh | sh -s email=$EMAIL --force
    chmod +x "$ACME_DIR/acme.sh"

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

    # 根据传输协议生成 streamSettings
    STREAM_SETTINGS_JSON=""
    if [ "$TRANSPORT_NETWORK" = "ws" ]; then
        STREAM_SETTINGS_JSON=$(cat <<EOF
    "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {
            "certificates": [{"certificateFile": "${SSL_DIR}/${DOMAIN}.crt","keyFile": "${SSL_DIR}/${DOMAIN}.key"}],
            "serverName": "${DOMAIN}"
        },
        "wsSettings": {"path": "${WS_PATH}","headers":{ "Host": "${WS_HOST}" }}
    }
EOF
)
    else # tcp
        STREAM_SETTINGS_JSON=$(cat <<EOF
    "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
            "certificates": [{"certificateFile": "${SSL_DIR}/${DOMAIN}.crt","keyFile": "${SSL_DIR}/${DOMAIN}.key"}],
            "serverName": "${DOMAIN}"
        }
    }
EOF
)
    fi

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
                "clients": [{"id": "${UUID}"${XRAY_FLOW:+, "flow": "$XRAY_FLOW"}}],
                "decryption": "none"
            },
            ${STREAM_SETTINGS_JSON}
        }
    ],
    "outbounds":[{"protocol":"freedom","settings":{}},{"protocol":"blackhole","tag":"blocked","settings":{}}]
}
EOF

    # systemd 服务 (使用 root 用户)
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

    # 申请并安装证书
    if ! apply_certificate "$DOMAIN"; then
        echo "安装过程中断，因为证书申请失败。"
        exit 1
    fi

    systemctl restart xray.service

    # 输出客户端配置
    echo "==================== 安装完成 ===================="
    echo "协议 (Protocol)  : $PROTOCOL"
    echo "传输 (Transport) : $TRANSPORT_NETWORK"
    echo "域名 (Domain)    : $DOMAIN"
    echo "端口 (Port)      : $XRAY_PORT"
    echo "UUID             : $UUID"
    if [ "$TRANSPORT_NETWORK" = "ws" ]; then
        echo "WebSocket 路径   : $WS_PATH"
        echo "WebSocket 主机   : $WS_HOST"
    fi
    if [ -n "$XRAY_FLOW" ]; then
        echo "流控 (Flow)      : $XRAY_FLOW"
    fi
    echo "--------------------------------------------------"

    CLIENT_LINK=""
    if [ "$PROTOCOL" = "vless" ]; then
        if [ "$TRANSPORT_NETWORK" = "ws" ]; then
            CLIENT_LINK="vless://${UUID}@${DOMAIN}:${XRAY_PORT}?type=ws&host=${WS_HOST}&path=${WS_PATH}&security=tls&sni=${DOMAIN}&encryption=none#${DOMAIN}-vless-ws"
        else # tcp
            CLIENT_LINK="vless://${UUID}@${DOMAIN}:${XRAY_PORT}?security=tls&sni=${DOMAIN}&flow=${XRAY_FLOW}&encryption=none#${DOMAIN}-vless-tcp"
        fi
    else # vmess
        VMESS_JSON=""
        local ps_name="${DOMAIN}-${TRANSPORT_NETWORK}"
        if [ "$TRANSPORT_NETWORK" = "ws" ]; then
            VMESS_JSON=$(jq -n \
                --arg ps "$ps_name" \
                --arg add "$DOMAIN" \
                --arg port "$XRAY_PORT" \
                --arg id "$UUID" \
                --arg host "$WS_HOST" \
                --arg path "$WS_PATH" \
                --arg sni "$DOMAIN" \
                '{v:"2",ps:$ps,add:$add,port:$port,id:$id,aid:0,net:"ws",type:"none",host:$host,path:$path,tls:"tls",sni:$sni,allowInsecure:false}')
        else # tcp
            VMESS_JSON=$(jq -n \
                --arg ps "$ps_name" \
                --arg add "$DOMAIN" \
                --arg port "$XRAY_PORT" \
                --arg id "$UUID" \
                --arg sni "$DOMAIN" \
                '{v:"2",ps:$ps,add:$add,port:$port,id:$id,aid:0,net:"tcp",type:"none",host:"",path:"",tls:"tls",sni:$sni,allowInsecure:false}')
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
    read -rp "您确定要卸载 Xray 吗？这将删除所有相关文件、证书和配置。[y/N]: " confirm
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

    echo "=========================================="
    echo "  Xray 一键脚本 (VMess/VLess | ws/tcp)"
    echo "=========================================="
    echo "1) 安装 Xray"
    echo "2) 卸载 Xray"
    echo "3) 查看 Xray 日志"
    echo "4) 重启 Xray 服务"
    echo "=========================================="
    read -rp "请输入选项 [1-4]: " choice

    case $choice in
        1) install_xray ;;
        2) uninstall_xray ;;
        3) journalctl -u xray -f ;;
        4) systemctl restart xray.service && echo "Xray 已重启" ;;
        *) echo "错误：无效选项"; exit 1 ;;
    esac
}

main

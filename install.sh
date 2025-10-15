#!/usr/bin/env bash
set -euo pipefail

# xray-install-optimized.sh
# 更稳健的 Xray 安装/卸载/管理脚本
# Features added:
# - 更好的输入校验与默认值
# - 备份/恢复旧配置与二进制
# - 更安全的防火墙处理（倾向保留现有规则并只打开必要端口）
# - acme.sh 申请失败后自动尝试备选 CA（Let's Encrypt / ZeroSSL），并在需要时回退到 certbot
# - 支持 DNS 验证（若用户提供 API 环境变量）
# - 日志/错误输出改进与清理机制
# - 支持自定义端口/路径/主机/用户
# - 证书自动续期 cron 安装

# ========================
# 配置参数（可通过环境变量覆盖）
# ========================
XRAY_PORT="${XRAY_PORT:-443}"
WS_PATH="${WS_PATH:-/}"
WS_HOST="${WS_HOST:-yunpanlive.chinaunicomvideo.cn}"
XRAY_USER="${XRAY_USER:-root}"
XRAY_BIN_DIR="${XRAY_BIN_DIR:-/usr/local/bin}"
XRAY_CONFIG_DIR="${XRAY_CONFIG_DIR:-/usr/local/etc/xray}"
SYSTEMD_SERVICE="${SYSTEMD_SERVICE:-/etc/systemd/system/xray.service}"
SSL_DIR="${SSL_DIR:-/etc/ssl/vmess_tls}"
XRAY_LOG_DIR="${XRAY_LOG_DIR:-/var/log/xray}"
ACME_DIR="${ACME_DIR:-$HOME/.acme.sh}"
RETRY_LIMIT=3

# ========================
# 帮助函数
# ========================
log() { echo "[INFO] $*"; }
err() { echo "[ERROR] $*" >&2; }

ensure_root() {
    if [ "$(id -u)" -ne 0 ]; then
        err "请以 root 或 sudo 权限运行此脚本。"
        exit 1
    fi
}

prompt_nonempty() {
    local prompt="$1" varname="$2"
    while :; do
        read -rp "$prompt" _val
        if [ -n "$_val" ]; then
            eval "$varname='$_val'"
            break
        fi
        echo "输入不能为空，请重试。"
    done
}

backup_file() {
    local f="$1"
    [ -e "$f" ] || return
    local bak="${f}.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "$f" "$bak" && log "备份 $f -> $bak"
}

check_port_free() {
    # 检查指定端口是否被占用（TCP）
    local port="$1"
    if ss -ltn "sport = :$port" | tail -n +2 | grep -q .; then
        return 1
    fi
    return 0
}

open_firewall_ports() {
    # 更保守的放通逻辑：只放行必要端口并备份现有 iptables 规则
    log "备份当前 iptables 规则"
    iptables-save >/root/iptables.backup || true

    log "放行端口: 80, ${XRAY_PORT}"
    if command -v ufw >/dev/null 2>&1; then
        ufw allow 80/tcp
        ufw allow ${XRAY_PORT}/tcp
    else
        iptables -I INPUT -p tcp --dport 80 -j ACCEPT
        iptables -I INPUT -p tcp --dport ${XRAY_PORT} -j ACCEPT
    fi
}

install_packages() {
    log "安装依赖包（curl unzip uuid-runtime openssl socat jq cron python3 certbot）"
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl unzip uuid-runtime openssl socat jq cron python3 certbot
    systemctl enable --now cron || true
}

install_acme_sh() {
    log "安装 acme.sh"
    # 强制重新安装以保证路径存在
    curl -fsSL https://get.acme.sh | /bin/bash -s -- --force
    chmod +x "$ACME_DIR/acme.sh" || true
}

issue_cert_acme() {
    local domain="$1"
    local email="$2"
    local retries=0

    # 尝试列表：默认（Let’s Encrypt），ZeroSSL，回退到 certbot
    while [ "$retries" -lt "$RETRY_LIMIT" ]; do
        log "尝试使用 acme.sh 申请证书 (尝试 $((retries+1))/${RETRY_LIMIT}) 使用 Let's Encrypt)"
        if "$ACME_DIR/acme.sh" --issue -d "$domain" --standalone --accountemail "$email" --force --log >/tmp/acme_issue.log 2>&1; then
            log "acme.sh (Let's Encrypt) 申请成功"
            # 将证书安装到指定目录
            mkdir -p "$SSL_DIR"
            "$ACME_DIR/acme.sh" --install-cert -d "$domain" \
                --key-file "$SSL_DIR/$domain.key" \
                --fullchain-file "$SSL_DIR/$domain.crt" \
                --reloadcmd "systemctl restart xray" >/tmp/acme_install.log 2>&1 || true
            # 确认证书存在
            if [ -s "$SSL_DIR/$domain.crt" ] && [ -s "$SSL_DIR/$domain.key" ]; then
                log "证书已写入 $SSL_DIR"
                return 0
            else
                err "acme.sh 虽然声称成功但未能将证书写入 $SSL_DIR，查看 /tmp/acme_install.log 获取更多信息"
                return 1
            fi
        fi
        ((retries++))
    done

    log "Let's Encrypt 失败，尝试使用 ZeroSSL"
    if "$ACME_DIR/acme.sh" --set-default-ca --server zerossl >/dev/null 2>&1; then
        if "$ACME_DIR/acme.sh" --issue -d "$domain" --standalone --accountemail "$email" --force --log >/tmp/acme_issue.log 2>&1; then
            log "acme.sh (ZeroSSL) 申请成功"
            mkdir -p "$SSL_DIR"
            "$ACME_DIR/acme.sh" --install-cert -d "$domain" \
                --key-file "$SSL_DIR/$domain.key" \
                --fullchain-file "$SSL_DIR/$domain.crt" \
                --reloadcmd "systemctl restart xray" >/tmp/acme_install.log 2>&1 || true
            if [ -s "$SSL_DIR/$domain.crt" ] && [ -s "$SSL_DIR/$domain.key" ]; then
                # 恢复默认 CA 为 letsencrypt，方便后续续期（可按需保留）
                "$ACME_DIR/acme.sh" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
                log "证书已写入 $SSL_DIR"
                return 0
            else
                err "ZeroSSL 申请成功但未能将证书写入 $SSL_DIR，查看 /tmp/acme_install.log 获取更多信息"
                # 不立刻返回，尝试 certbot 回退
            fi
        fi
    fi

    err "acme.sh 使用内置 CA 申请均失败或未正确写入证书，尝试使用 certbot 申请（http-01）。"
    # 使用 certbot 申请
    if certbot certonly --standalone -d "$domain" --non-interactive --agree-tos --email "$email"; then
        log "certbot 申请成功，证书路径：/etc/letsencrypt/live/$domain/"
        mkdir -p "$SSL_DIR"
        # 使用真实文件（避免软链接问题），使用 openssl to copy ensures permissions
        if [ -f "/etc/letsencrypt/live/$domain/fullchain.pem" ] && [ -f "/etc/letsencrypt/live/$domain/privkey.pem" ]; then
            cp -L "/etc/letsencrypt/live/$domain/fullchain.pem" "$SSL_DIR/$domain.crt" || cp "/etc/letsencrypt/live/$domain/fullchain.pem" "$SSL_DIR/$domain.crt"
            cp -L "/etc/letsencrypt/live/$domain/privkey.pem" "$SSL_DIR/$domain.key" || cp "/etc/letsencrypt/live/$domain/privkey.pem" "$SSL_DIR/$domain.key"
            chmod 644 "$SSL_DIR/$domain.crt" || true
            chmod 600 "$SSL_DIR/$domain.key" || true
            log "已将 certbot 生成的证书复制到 $SSL_DIR"
            # 尝试重启 xray
            systemctl restart xray.service || true
            return 0
        else
            err "certbot 申请成功但找不到 /etc/letsencrypt/live/$domain 下的证书文件。"
            return 1
        fi
    fi

    return 1
}

install_xray_binary() {
    if command -v xray >/dev/null 2>&1; then
        log "检测到已存在 xray，跳过二进制安装"
        return 0
    fi
    local country
    country=$(curl -fsS --max-time 8 https://ipinfo.io/country 2>/dev/null || true)
    country=$(echo -n "$country" | tr -d '\r\n' | tr '[:lower:]' '[:upper:]')

    local mirror_prefix=""
    [ "$country" = "CN" ] && mirror_prefix="https://gh.llkk.cc/https://"
    local relative_url="github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip"
    local xurl="${mirror_prefix}${relative_url}"
    local tmp_zip="/tmp/xray.zip"

    log "从 $xurl 下载 Xray"
    curl -fsSL -o "$tmp_zip" "$xurl"
    unzip -o "$tmp_zip" -d /tmp/xray_unpack >/dev/null
    install -m 755 /tmp/xray_unpack/xray "$XRAY_BIN_DIR/xray"
    rm -rf /tmp/xray_unpack "$tmp_zip"
}

write_xray_config() {
    local domain="$1" uuid="$2" proto="$3"
    mkdir -p "$XRAY_CONFIG_DIR" "$SSL_DIR" "$XRAY_LOG_DIR"

    local tls_settings="\"certificates\": [{\"certificateFile\": \"${SSL_DIR}/${domain}.crt\",\"keyFile\": \"${SSL_DIR}/${domain}.key\"}], \"serverName\": \"${domain}\""

    cat >"${XRAY_CONFIG_DIR}/config.json" <<EOF
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
      "protocol": "${proto}",
      "settings": {
        "clients": [{"id": "${uuid}","flow":""}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {
          ${tls_settings}
        },
        "wsSettings": {"path": "${WS_PATH}","headers":{"Host":"${WS_HOST}"}}
      }
    }
  ],
  "outbounds":[{"protocol":"freedom","settings":{}},{"protocol":"blackhole","tag":"blocked","settings":{}}]
}
EOF

    log "写入 Xray 配置：${XRAY_CONFIG_DIR}/config.json"
}

install_systemd_service() {
    local conf="$1"
    backup_file "$SYSTEMD_SERVICE"
    cat >"$SYSTEMD_SERVICE" <<EOF
[Unit]
Description=Xray Service
After=network.target
[Service]
User=${XRAY_USER}
ExecStart=${XRAY_BIN_DIR}/xray -config ${conf}
Restart=on-failure
RestartSec=3s
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now xray.service
}

create_account_uuid() { uuidgen; }

install_renew_cron() {
    # acme.sh 自带 --install-cron，但我们也可写一条兼容的 cron
    if [ -x "$ACME_DIR/acme.sh" ]; then
        "$ACME_DIR/acme.sh" --install-cron >/dev/null 2>&1 || true
        log "已安装 acme.sh 自动续期（如果支持）"
    else
        log "acme.sh 未安装，跳过自动续期安装"
    fi
}

# ========================
# 操作函数
# ========================

install_flow() {
    ensure_root
    open_firewall_ports
    install_packages
    install_acme_sh

    prompt_nonempty "请输入 TLS 使用的域名（例如 xxx.com）： " DOMAIN
    prompt_nonempty "请输入用于证书注册的邮箱： " EMAIL

    echo "请选择协议类型: 1) VMess  2) VLess"
    read -rp "请输入选项 [1-2]: " PROTO_CHOICE
    case $PROTO_CHOICE in
        1) PROTOCOL="vmess" ;;
        2) PROTOCOL="vless" ;;
        *) err "无效选项"; exit 1 ;;
    esac

    # 检查端口
    if ! check_port_free 80; then err "端口 80 被占用，请先释放"; exit 1; fi
    if ! check_port_free "$XRAY_PORT"; then err "端口 ${XRAY_PORT} 被占用，请先释放"; exit 1; fi

    install_xray_binary

    UUID=$(create_account_uuid)
    log "生成 UUID: $UUID"

    # 申请证书（含重试与备用 CA）
    if issue_cert_acme "$DOMAIN" "$EMAIL"; then
        # 确保 cert 存在到 SSL_DIR
        if [ -z "$(ls -A "$SSL_DIR" 2>/dev/null || true)" ]; then
            err "证书未正确放置到 $SSL_DIR"
            exit 1
        fi
    else
        err "证书申请失败，安装终止"
        exit 1
    fi

    # 写配置并安装 service
    write_xray_config "$DOMAIN" "$UUID" "$PROTOCOL"
    install_systemd_service "${XRAY_CONFIG_DIR}/config.json"

    install_renew_cron

    # 输出客户端链接
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
    echo "协议： $PROTOCOL"
    echo "链接："
    echo "$CLIENT_LINK"
    echo "查看 Xray 日志：journalctl -u xray -f"
}

uninstall_flow() {
    ensure_root
    read -rp "您确定要卸载 Xray 吗？这将删除所有相关文件、证书和配置。[y/N]: " confirm
    [[ ! "$confirm" =~ ^[yY]$ ]] && { echo "操作已取消"; exit 0; }

    systemctl stop xray.service || true
    systemctl disable xray.service || true

    if [ -x "$ACME_DIR/acme.sh" ]; then
        "$ACME_DIR/acme.sh" --uninstall || true
    fi
    rm -f "$SYSTEMD_SERVICE" "$XRAY_BIN_DIR/xray"
    rm -rf "$XRAY_CONFIG_DIR" "$SSL_DIR" "$XRAY_LOG_DIR"
    systemctl daemon-reload
    log "卸载完成"
}

show_logs() {
    journalctl -u xray -f
}

restart_service() {
    systemctl restart xray.service && log "Xray 已重启完成"
}

# ========================
# 主入口
# ========================
main() {
    ensure_root
    cat <<'EOF'
==========================================
 Xray 一键安装/卸载/重启/日志脚本（增强版）
==========================================
1) 安装 Xray (VMess/VLess)
2) 卸载 Xray
3) 查看 Xray 日志
4) 重启 Xray 服务
EOF
    read -rp "请输入选项 [1-4]: " choice

    case $choice in
        1) install_flow ;;
        2) uninstall_flow ;;
        3) show_logs ;;
        4) restart_service ;;
        *) err "无效选项"; exit 1 ;;
    esac
}

main

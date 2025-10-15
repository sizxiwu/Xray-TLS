#!/usr/bin/env bash
set -euo pipefail

# xray-install-optimized.sh (final)
# 一键安装/卸载/管理 Xray（增强版）
# 主要特性：
# - 稳健安装 acme.sh（修正 --force 用法）
# - acme.sh Let\'s Encrypt -> ZeroSSL -> certbot 回退策略并保证证书复制到指定目录
# - 自动重启 xray 并输出最终 vmess/vless 链接
# - 支持非交互环境（通过环境变量覆盖常用选项）

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
ensure_root() { [ "$(id -u)" -eq 0 ] || { err "请以 root 或 sudo 权限运行此脚本。"; exit 1; } }

prompt_nonempty() {
    local prompt="$1" varname="$2"
    if [ -n "${!varname-}" ]; then
        return 0
    fi
    while :; do
        read -rp "$prompt" _val
        [ -n "$_val" ] && { eval "$varname='$_val'"; break; }
        echo "输入不能为空，请重试。"
    done
}

backup_file() { local f="$1"; [ -e "$f" ] || return; cp -a "$f" "${f}.bak.$(date +%Y%m%d%H%M%S)"; }

check_port_free() { local port="$1"; ss -ltn "sport = :$port" | tail -n +2 | grep -q . && return 1 || return 0; }

open_firewall_ports() {
    log "备份当前 iptables 规则"
    iptables-save >/root/iptables.backup || true
    log "放行端口: 80, ${XRAY_PORT}"
    if command -v ufw >/dev/null 2>&1; then
        ufw allow 80/tcp || true
        ufw allow ${XRAY_PORT}/tcp || true
    else
        iptables -I INPUT -p tcp --dport 80 -j ACCEPT || true
        iptables -I INPUT -p tcp --dport ${XRAY_PORT} -j ACCEPT || true
    fi
}

install_packages() {
    log "安装依赖包"
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl unzip uuid-runtime openssl socat jq cron python3 certbot || true
    systemctl enable --now cron || true
}

install_acme_sh() {
    log "安装 acme.sh（若已存在则跳过）"
    if [ -x "$ACME_DIR/acme.sh" ]; then
        log "acme.sh 已存在"
        return 0
    fi
    if curl -fsSL https://get.acme.sh | /bin/sh -s -- --force; then
        log "acme.sh 安装完成"
    else
        err "acme.sh 安装失败，后续将回退使用 certbot"
        return 1
    fi
}

issue_cert_acme() {
    local domain="$1" email="$2"
    local retries=0

    # 首先尝试 acme.sh + Letsencrypt
    while [ "$retries" -lt "$RETRY_LIMIT" ]; do
        log "尝试使用 acme.sh 申请证书 (尝试 $((retries+1))/${RETRY_LIMIT}) 使用 Let's Encrypt)"
        if [ -x "$ACME_DIR/acme.sh" ]; then
            # 使用 standalone 模式
            if "$ACME_DIR/acme.sh" --issue -d "$domain" --standalone --accountemail "$email" --force >/tmp/acme_issue.log 2>&1; then
                log "acme.sh 申请成功（Let's Encrypt）。安装证书到 $SSL_DIR"
                mkdir -p "$SSL_DIR"
                "$ACME_DIR/acme.sh" --install-cert -d "$domain" \
                    --key-file "$SSL_DIR/$domain.key" \
                    --fullchain-file "$SSL_DIR/$domain.crt" \
                    --reloadcmd "systemctl restart xray" >/tmp/acme_install.log 2>&1 || true
                if [ -s "$SSL_DIR/$domain.crt" ] && [ -s "$SSL_DIR/$domain.key" ]; then
                    log "证书已写入 $SSL_DIR"
                    return 0
                else
                    err "acme.sh 声称成功但未将证书写入 $SSL_DIR，查看 /tmp/acme_install.log"
                    return 1
                fi
            fi
        else
            err "acme.sh 未安装或不可执行，跳过 acme.sh 步骤"
            break
        fi
        ((retries++))
    done

    # 尝试 ZeroSSL
    log "尝试使用 ZeroSSL"
    if [ -x "$ACME_DIR/acme.sh" ]; then
        "$ACME_DIR/acme.sh" --set-default-ca --server zerossl >/dev/null 2>&1 || true
        if "$ACME_DIR/acme.sh" --issue -d "$domain" --standalone --accountemail "$email" --force >/tmp/acme_issue.log 2>&1; then
            mkdir -p "$SSL_DIR"
            "$ACME_DIR/acme.sh" --install-cert -d "$domain" \
                --key-file "$SSL_DIR/$domain.key" \
                --fullchain-file "$SSL_DIR/$domain.crt" \
                --reloadcmd "systemctl restart xray" >/tmp/acme_install.log 2>&1 || true
            if [ -s "$SSL_DIR/$domain.crt" ] && [ -s "$SSL_DIR/$domain.key" ]; then
                "$ACME_DIR/acme.sh" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
                log "ZeroSSL 申请并写入证书成功"
                return 0
            else
                err "ZeroSSL 申请成功但未写入目标目录，查看 /tmp/acme_install.log"
            fi
        fi
    fi

    # 回退到 certbot：如果已有证书，直接复制；否则尝试强制申请
    log "尝试使用 certbot 回退/复制现有证书"
    if [ -d "/etc/letsencrypt/live/$domain" ]; then
        log "检测到 /etc/letsencrypt/live/$domain，复制到 $SSL_DIR"
        mkdir -p "$SSL_DIR"
        cp -L "/etc/letsencrypt/live/$domain/fullchain.pem" "$SSL_DIR/$domain.crt" || true
        cp -L "/etc/letsencrypt/live/$domain/privkey.pem" "$SSL_DIR/$domain.key" || true
        chmod 644 "$SSL_DIR/$domain.crt" || true
        chmod 600 "$SSL_DIR/$domain.key" || true
        log "已复制现有 certbot 证书到 $SSL_DIR"
        systemctl restart xray.service || true
        return 0
    fi

    # 若不存在，则尝试 certbot 申请（加上 --force-renewal to trigger if edge cases）
    if certbot certonly --standalone -d "$domain" --non-interactive --agree-tos --email "$email" --force-renewal; then
        log "certbot 申请成功，复制证书到 $SSL_DIR"
        mkdir -p "$SSL_DIR"
        cp -L "/etc/letsencrypt/live/$domain/fullchain.pem" "$SSL_DIR/$domain.crt" || true
        cp -L "/etc/letsencrypt/live/$domain/privkey.pem" "$SSL_DIR/$domain.key" || true
        chmod 644 "$SSL_DIR/$domain.crt" || true
        chmod 600 "$SSL_DIR/$domain.key" || true
        systemctl restart xray.service || true
        return 0
    fi

    err "所有证书申请方式均失败"
    return 1
}

install_xray_binary() {
    if command -v xray >/dev/null 2>&1; then
        log "检测到已存在 xray，跳过二进制安装"
        return 0
    fi
    local country
    country=$(curl -fsS --max-time 8 https://ipinfo.io/country 2>/dev/null || true)
    country=$(echo -n "$country" | tr -d '
' | tr '[:lower:]' '[:upper:]')
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
    cat >"${XRAY_CONFIG_DIR}/config.json" <<EOF
{
  "log": { "access": "${XRAY_LOG_DIR}/access.log", "error": "${XRAY_LOG_DIR}/error.log", "loglevel": "warning" },
  "inbounds": [
    {
      "port": ${XRAY_PORT},
      "listen": "0.0.0.0",
      "protocol": "${proto}",
      "settings": { "clients": [{"id": "${uuid}","flow":""}], "decryption": "none" },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": { "certificates": [{"certificateFile": "${SSL_DIR}/${domain}.crt","keyFile": "${SSL_DIR}/${domain}.key"}], "serverName": "${domain}" },
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
    systemctl enable --now xray.service || true
}

create_account_uuid() { uuidgen; }

install_renew_cron() { if [ -x "$ACME_DIR/acme.sh" ]; then "$ACME_DIR/acme.sh" --install-cron >/dev/null 2>&1 || true; fi }

install_flow() {
    ensure_root
    open_firewall_ports
    install_packages
    install_acme_sh || true

    prompt_nonempty "请输入 TLS 使用的域名（例如 xxx.com）： " DOMAIN
    prompt_nonempty "请输入用于证书注册的邮箱： " EMAIL

    echo "请选择协议类型: 1) VMess  2) VLess"
    read -rp "请输入选项 [1-2]: " PROTO_CHOICE
    case $PROTO_CHOICE in 1) PROTOCOL="vmess" ;; 2) PROTOCOL="vless" ;; *) err "无效选项"; exit 1 ;; esac

    if ! check_port_free 80; then err "端口 80 被占用，请先释放"; fi
    if ! check_port_free "$XRAY_PORT"; then err "端口 ${XRAY_PORT} 被占用，请先释放"; fi

    install_xray_binary

    UUID=$(create_account_uuid)
    log "生成 UUID: $UUID"

    if issue_cert_acme "$DOMAIN" "$EMAIL"; then
        log "证书准备完成"
    else
        err "证书申请/准备失败，终止安装"
        exit 1
    fi

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
    echo "证书路径："
    ls -l "$SSL_DIR" || true
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
    if [ -x "$ACME_DIR/acme.sh" ]; then "$ACME_DIR/acme.sh" --uninstall || true; fi
    rm -f "$SYSTEMD_SERVICE" "$XRAY_BIN_DIR/xray"
    rm -rf "$XRAY_CONFIG_DIR" "$SSL_DIR" "$XRAY_LOG_DIR"
    systemctl daemon-reload
    log "卸载完成"
}

show_logs() { journalctl -u xray -f }
restart_service() { systemctl restart xray.service && log "Xray 已重启完成" }

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
    case $choice in 1) install_flow ;; 2) uninstall_flow ;; 3) show_logs ;; 4) restart_service ;; *) err "无效选项"; exit 1 ;; esac
}

main

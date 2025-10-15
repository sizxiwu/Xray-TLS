#!/usr/bin/env bash
# Xray 一键安装脚本 (支持 TCP+TLS / WS+TLS, VMess/VLess, 自动回退 HTTP)
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

CONFIG_DIR="/usr/local/etc/xray"
BIN_DIR="/usr/local/bin"
LOG_DIR="/var/log/xray"
SYSTEMD_SERVICE="/etc/systemd/system/xray.service"
ACME_SH="$HOME/.acme.sh/acme.sh"

mkdir -p "$CONFIG_DIR" "$LOG_DIR"

gen_uuid() {
    command -v uuidgen >/dev/null 2>&1 && uuidgen || cat /proc/sys/kernel/random/uuid
}

install_xray_core() {
    if ! command -v xray >/dev/null 2>&1; then
        echo -e "${GREEN}安装 Xray 核心...${NC}"
        bash -c "$(curl -sL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    fi
}

install_acme() {
    if [ ! -f "$ACME_SH" ]; then
        echo -e "${GREEN}安装 acme.sh...${NC}"
        curl -sS https://get.acme.sh | sh
        source ~/.bashrc || true
    fi
}

issue_certificate() {
    local domain="$1"
    local max_retries=5
    local i
    for i in $(seq 1 $max_retries); do
        echo -e "${GREEN}尝试申请证书 (Let's Encrypt) 第 $i 次...${NC}"
        if "$ACME_SH" --issue --standalone -d "$domain" --keylength ec-256 --force; then
            return 0
        fi
        sleep 5
    done
    return 1
}

install_certificate() {
    local domain="$1"
    "$ACME_SH" --install-cert -d "$domain" \
        --cert-file "$CONFIG_DIR/$domain.crt" \
        --key-file "$CONFIG_DIR/$domain.key" \
        --fullchain-file "$CONFIG_DIR/$domain.fullchain.crt" \
        --reloadcmd "systemctl restart xray"
}

generate_config() {
    local protocol="$1"
    local uuid="$2"
    local port="$3"
    local domain="$4"
    local path="$5"
    local net="$6"   # tcp / ws
    local tls="$7"   # yes/no

    local cert_crt="$CONFIG_DIR/$domain.crt"
    local cert_key="$CONFIG_DIR/$domain.key"

    cat > "$CONFIG_DIR/config.json" <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "$LOG_DIR/access.log",
    "error": "$LOG_DIR/error.log"
  },
  "inbounds": [
    {
      "port": $port,
      "protocol": "$protocol",
      "settings": {
        "clients": [
          {
            "id": "$uuid",
            "email": "user",
            "alterId": 0
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "$net",
        $( [ "$tls" == "yes" ] && echo "\"security\":\"tls\"," || echo "\"security\":\"none\"," )
        $( [ "$tls" == "yes" ] && echo "\"tlsSettings\":{\"certificates\":[{\"certificateFile\":\"$cert_crt\",\"keyFile\":\"$cert_key\"}]}," || echo "" )
        $( [ "$net" == "ws" ] && echo "\"wsSettings\":{\"path\":\"/$path\",\"headers\":{\"Host\":\"$domain\"}}," || echo "" )
        "tcpSettings": {}
      }
    }
  ],
  "outbounds": [{"protocol":"freedom","settings":{}}]
}
EOF
}

print_link() {
    local protocol="$1"
    local uuid="$2"
    local domain="$3"
    local port="$4"
    local path="$5"
    local net="$6"
    local tls="$7"

    local tls_param
    tls_param=$( [ "$tls" == "yes" ] && echo "tls" || echo "none" )

    if [ "$protocol" == "vless" ]; then
        echo -e "${GREEN}VLESS 链接:${NC}"
        echo "vless://${uuid}@${domain}:${port}?encryption=none&security=${tls_param}&type=${net}&host=${domain}&path=/${path}#xray"
    else
        echo -e "${GREEN}VMess 链接:${NC}"
        local json="{\"v\":\"2\",\"ps\":\"Xray\",\"add\":\"$domain\",\"port\":\"$port\",\"id\":\"$uuid\",\"aid\":0,\"net\":\"$net\",\"type\":\"none\",\"host\":\"$domain\",\"path\":\"/$path\",\"tls\":\"$tls_param\"}"
        echo "vmess://$(echo -n "$json" | base64 | tr -d '\n')"
    fi
}

install_mode_tls() {
    read -rp "请输入域名： " domain
    [ -z "$domain" ] && echo -e "${RED}域名不能为空${NC}" && return

    echo "选择协议: 1)VLESS 2)VMess"
    read -rp "选择协议 [1-2]:" choice
    case "$choice" in 1) protocol="vless";; 2) protocol="vmess";; *) echo "无效"; return;; esac

    echo "选择传输方式: 1)TCP+TLS 2)WS+TLS"
    read -rp "选择传输方式 [1-2]:" t_choice
    case "$t_choice" in 1) net="tcp"; port=443; path="";; 2) net="ws"; port=443; path="xray";; *) echo "无效"; return;; esac

    uuid=$(gen_uuid)
    install_acme

    if issue_certificate "$domain"; then
        echo -e "${GREEN}证书申请成功${NC}"
        install_certificate "$domain"
        generate_config "$protocol" "$uuid" "$port" "$domain" "$path" "$net" "yes"
        systemctl enable xray
        systemctl restart xray
        print_link "$protocol" "$uuid" "$domain" "$port" "$path" "$net" "yes"
    else
        echo -e "${YELLOW}证书申请失败，回退 HTTP 模式${NC}"
        install_mode_http
    fi
}

install_mode_http() {
    read -rp "请输入域名或 IP： " domain
    [ -z "$domain" ] && echo -e "${RED}不能为空${NC}" && return
    echo "选择协议: 1)VLESS 2)VMess"
    read -rp "选择协议 [1-2]:" choice
    case "$choice" in 1) protocol="vless";; 2) protocol="vmess";; *) echo "无效"; return;; esac
    echo "选择传输方式: 1)TCP 2)WS"
    read -rp "选择传输方式 [1-2]:" t_choice
    case "$t_choice" in 1) net="tcp"; port=80; path="";; 2) net="ws"; port=80; path="xray";; *) echo "无效"; return;; esac

    uuid=$(gen_uuid)
    generate_config "$protocol" "$uuid" "$port" "$domain" "$path" "$net" "no"
    systemctl enable xray
    systemctl restart xray
    print_link "$protocol" "$uuid" "$domain" "$port" "$path" "$net" "no"
}

uninstall_xray() {
    read -rp "确认卸载 Xray？(y/n): " yn
    case "$yn" in
        [Yy]*) 
            systemctl stop xray || true
            systemctl disable xray || true
            rm -f "$BIN_DIR/xray" "$SYSTEMD_SERVICE"
            rm -rf "$CONFIG_DIR" "$LOG_DIR" "$HOME/.acme.sh"
            systemctl daemon-reload
            echo -e "${GREEN}卸载完成${NC}";;
        *) echo "取消";;
    esac
}

restart_xray() {
    systemctl restart xray && echo -e "${GREEN}重启完成${NC}"
}

view_logs() {
    [ -f "$LOG_DIR/access.log" ] && tail -n 20 "$LOG_DIR/access.log"
    [ -f "$LOG_DIR/error.log" ] && tail -n 20 "$LOG_DIR/error.log"
}

# 主菜单
while true; do
    echo
    echo "===== Xray 安装脚本 ====="
    echo "1) 安装 Xray (TLS)"
    echo "2) 安装 Xray (HTTP)"
    echo "3) 卸载 Xray"
    echo "4) 重启 Xray"
    echo "5) 查看日志"
    echo "6) 退出"
    read -rp "请选择 [1-6]:" menu
    case "$menu" in
        1) install_xray_core; install_mode_tls ;;
        2) install_xray_core; install_mode_http ;;
        3) uninstall_xray ;;
        4) restart_xray ;;
        5) view_logs ;;
        6) exit 0 ;;
        *) echo "无效选项";;
    esac
done

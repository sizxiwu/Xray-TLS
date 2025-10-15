#!/usr/bin/env bash
# Xray 一键安装脚本 (支持 VMess/VLESS, TLS/HTTP 模式)
# 要求: 以 root 用户运行，使用 acme.sh 独立模式申请证书

set -e

# 彩色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # 无色

# 检查是否 root 用户
if [[ "$EUID" -ne 0 ]]; then
    echo -e "${RED}错误：请使用 root 用户运行此脚本！${NC}"
    exit 1
fi

# 生成随机 UUID
gen_uuid() {
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen
    else
        cat /proc/sys/kernel/random/uuid
    fi
}

# 安装 Xray 核心（使用官方安装脚本）
install_xray() {
    echo -e "${GREEN}正在安装 Xray...${NC}"
    bash -c "$(curl -sL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    echo -e "${GREEN}Xray 安装完成！${NC}"
}

# 配置目录和日志
CONFIG_DIR="/usr/local/etc/xray"
mkdir -p "$CONFIG_DIR"
LOG_DIR="/var/log/xray"
mkdir -p "$LOG_DIR"

# 使用 acme.sh 申请证书
issue_certificate() {
    local domain="$1"
    # 安装 acme.sh（若未安装）
    if [ ! -f "$HOME/.acme.sh/acme.sh" ]; then
        curl -sS https://get.acme.sh | sh
        source ~/.bashrc
    fi
    # 默认尝试 Let's Encrypt (ECC)
    acme.sh --issue --standalone -d "$domain" --keylength ec-256 --force
}

install_certificate() {
    local domain="$1"
    local cert_dir="$CONFIG_DIR"
    # 安装证书到指定路径
    ~/.acme.sh/acme.sh --install-cert -d "$domain" \
        --cert-file "$cert_dir/$domain.crt" \
        --key-file  "$cert_dir/$domain.key" \
        --fullchain-file "$cert_dir/$domain.fullchain.crt" \
        --ecc --reloadcmd "systemctl restart xray"
}

# 生成 Xray 配置文件
generate_config() {
    local protocol="$1"  # vless 或 vmess
    local uuid="$2"
    local port="$3"
    local domain="$4"
    local path="$5"
    local tls_enabled="$6"  # yes/no
    local cert_key_file cert_crt_file
    if [ "$tls_enabled" == "yes" ]; then
        cert_crt_file="$CONFIG_DIR/$domain.crt"
        cert_key_file="$CONFIG_DIR/$domain.key"
    fi

    # 日志路径配置
    local log_access="$LOG_DIR/access.log"
    local log_error="$LOG_DIR/error.log"

    if [ "$protocol" == "vless" ]; then
        cat > "$CONFIG_DIR/config.json" <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "$log_access",
    "error": "$log_error"
  },
  "inbounds": [
    {
      "port": $port,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$uuid",
            "flow": "xtls-rprx-direct",
            "email": "user"
          }
        ],
        "decryption": "none",
        "fallbacks": []
      },
      "streamSettings": {
        "network": "ws",
        "security": "$( [ "$tls_enabled" == "yes" ] && echo "tls" || echo "none" )",
        $( [ "$tls_enabled" == "yes" ] && echo "\"tlsSettings\": { \"certificates\": [{ \"certificateFile\": \"$cert_crt_file\", \"keyFile\": \"$cert_key_file\" }] }," || echo "" )
        "wsSettings": {
          "path": "/$path",
          "headers": {
            "Host": "$domain"
          }
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {}
    }
  ]
}
EOF
    else
        # VMess 配置
        cat > "$CONFIG_DIR/config.json" <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "$log_access",
    "error": "$log_error"
  },
  "inbounds": [
    {
      "port": $port,
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "$uuid",
            "alterId": 0,
            "email": "user"
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "security": "$( [ "$tls_enabled" == "yes" ] && echo "tls" || echo "none" )",
        $( [ "$tls_enabled" == "yes" ] && echo "\"tlsSettings\": { \"certificates\": [{ \"certificateFile\": \"$cert_crt_file\", \"keyFile\": \"$cert_key_file\" }] }," || echo "" )
        "wsSettings": {
          "path": "/$path",
          "headers": {
            "Host": "$domain"
          }
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {}
    }
  ]
}
EOF
    fi
}

# 输出客户端配置链接
print_links() {
    local protocol="$1"
    local uuid="$2"
    local domain="$3"
    local port="$4"
    local path="$5"
    local tls_enabled="$6"
    local tls_param tls_flag
    if [ "$tls_enabled" == "yes" ]; then
        tls_param="tls"
    else
        tls_param="none"
    fi
    echo -e "${GREEN}配置完成！以下为客户端链接：${NC}"
    if [ "$protocol" == "vless" ]; then
        # VLESS 链接
        # 注意：path 需要 URL 编码
        local url_path
        url_path=$(echo -n "/$path" | sed 's/\//%2F/g')
        echo "  VLESS: vless://${uuid}@${domain}:${port}?encryption=none&security=${tls_param}&type=ws&host=${domain}&path=/${path}#xray"
    else
        # VMess 链接
        local json="{\"v\":\"2\",\"ps\":\"Xray-VMess\",\"add\":\"$domain\",\"port\":\"$port\",\"id\":\"$uuid\",\"aid\":\"0\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"\",\"path\":\"/$path\",\"tls\":\"${tls_param}\"}"
        local vmess_link
        vmess_link=$(echo -n "$json" | base64 | tr -d '\n')
        echo "  VMess: vmess://${vmess_link}"
    fi
}

# 安装流程 (含 TLS 模式申请及回退)
install_mode_tls() {
    read -rp "请输入你的域名 (Host): " domain
    if [ -z "$domain" ]; then
        echo -e "${RED}错误：域名不能为空！${NC}"; return
    fi
    # 随机路径
    path="xray"
    read -rp "请选择协议 (1) VLESS  (2) VMess ：" choice_proto
    case "$choice_proto" in
        1) protocol="vless" ;;
        2) protocol="vmess" ;;
        *) echo -e "${RED}无效选项${NC}"; return ;;
    esac
    uuid=$(gen_uuid)
    port=443
    echo -e "${GREEN}正在申请证书（可能需要几秒）...${NC}"
    # 初次尝试 Let's Encrypt
    if issue_certificate "$domain"; then
        echo -e "${GREEN}Let's Encrypt 证书申请成功！${NC}"
    else
        echo -e "${YELLOW}Let's Encrypt 申请失败，尝试备用 CA (Buypass)...${NC}"
        if ~/.acme.sh/acme.sh --issue --standalone -d "$domain" --server https://api.buypass.com/acme/directory --keylength ec-256 --force; then
            echo -e "${GREEN}Buypass 证书申请成功！${NC}"
        else
            echo -e "${RED}备用 CA 申请失败，切换至 HTTP 模式！${NC}"
            install_mode_http  # 回退到 HTTP 模式
            return
        fi
    fi
    # 安装证书
    install_certificate "$domain"
    # 生成配置并启动 Xray
    generate_config "$protocol" "$uuid" "$port" "$domain" "$path" "yes"
    systemctl enable xray
    systemctl restart xray
    # 输出链接
    print_links "$protocol" "$uuid" "$domain" "$port" "$path" "yes"
}

# 安装流程 (HTTP 模式，无 TLS)
install_mode_http() {
    read -rp "请输入你的域名 (Host)： " domain
    [ -z "$domain" ] && echo -e "${RED}错误：域名不能为空！${NC}" && return
    read -rp "请选择协议 (1) VLESS  (2) VMess ：" choice_proto
    case "$choice_proto" in
        1) protocol="vless" ;;
        2) protocol="vmess" ;;
        *) echo -e "${RED}无效选项${NC}"; return ;;
    esac
    uuid=$(gen_uuid)
    port=80
    path="xray"
    # 直接生成 HTTP 配置并启动
    generate_config "$protocol" "$uuid" "$port" "$domain" "$path" "no"
    systemctl enable xray
    systemctl restart xray
    print_links "$protocol" "$uuid" "$domain" "$port" "$path" "no"
}

# 卸载 Xray
uninstall_xray() {
    read -rp "确认卸载 Xray？(y/n)： " yn
    case "$yn" in
        [Yy]* )
            echo -e "${GREEN}正在卸载 Xray...${NC}"
            systemctl stop xray || true
            systemctl disable xray || true
            rm -f /etc/systemd/system/xray.service
            rm -f /etc/systemd/system/xray@.service
            rm -f /usr/local/bin/xray
            rm -rf /usr/local/etc/xray
            rm -rf /usr/local/share/xray
            rm -rf "$LOG_DIR"
            systemctl daemon-reload
            echo -e "${GREEN}Xray 已卸载完成！${NC}"
            ;;
        * ) echo "已取消卸载。";;
    esac
}

# 重启 Xray 服务
restart_xray() {
    if systemctl is-active --quiet xray; then
        systemctl restart xray
        echo -e "${GREEN}Xray 服务已重启！${NC}"
    else
        echo -e "${YELLOW}Xray 服务未安装或未运行。${NC}"
    fi
}

# 查看日志
view_logs() {
    if [ ! -f "$LOG_DIR/access.log" ] && [ ! -f "$LOG_DIR/error.log" ]; then
        echo -e "${YELLOW}日志文件不存在，请先安装并运行 Xray。${NC}"
        return
    fi
    echo -e "${GREEN}=== Access Log (最新 20 行) ===${NC}"
    tail -n 20 "$LOG_DIR/access.log"
    echo -e "${GREEN}=== Error Log (最新 20 行) ===${NC}"
    tail -n 20 "$LOG_DIR/error.log"
}

# 主菜单
while true; do
    echo
    echo "===== Xray 一键安装脚本 ====="
    echo "1) 安装 Xray (TLS 模式，含证书申请回退)"
    echo "2) 安装 Xray (始终 HTTP 模式，无 TLS)"
    echo "3) 卸载 Xray"
    echo "4) 重启 Xray 服务"
    echo "5) 查看 Xray 日志"
    echo "6) 退出"
    read -rp "请选择 [1-6]：" menu
    case "$menu" in
        1) install_xray; install_mode_tls ;;
        2) install_xray; install_mode_http ;;
        3) uninstall_xray ;;
        4) restart_xray ;;
        5) view_logs ;;
        6) echo "退出脚本。"; exit 0 ;;
        *) echo -e "${RED}无效选项！${NC}" ;;
    esac
done

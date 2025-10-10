#!/usr/bin/env bash
set -euo pipefail

# ========================
# 配置参数
# ========================
# 这些变量会被安装和卸载功能共同使用
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

# ==================================================
# ==================================================
# 函数定义
# ==================================================
# ==================================================

# ------------------------
# 安装函数
# ------------------------
install_xray() {
  echo "开始执行 Xray 安装流程..."

  # ========================
  # 清理旧 acme.sh 账号
  # ========================
  if [ -d "$ACME_DIR" ]; then
    echo "检测到旧 acme.sh 账号，正在删除..."
    rm -rf "$ACME_DIR"
  fi

  # ========================
  # 输入 TLS 域名和邮箱
  # ========================
  read -rp "请输入 TLS 使用的域名（例如 xxx.com）： " DOMAIN
  [ -z "$DOMAIN" ] && { echo "域名不能为空"; exit 1; }

  read -rp "请输入用于证书注册的邮箱（必须是真实可用邮箱）： " EMAIL
  [ -z "$EMAIL" ] && { echo "邮箱不能为空"; exit 1; }

  # ========================
  # 安装依赖
  # ========================
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y curl unzip uuid-runtime openssl socat jq cron

  # 启动 cron 服务
  systemctl enable cron
  systemctl start cron

  # ========================
  # 安装 acme.sh
  # ========================
  echo "安装 acme.sh..."
  curl https://get.acme.sh | sh -s email=$EMAIL --force
  chmod +x "$ACME_DIR/acme.sh"

  # ========================
  # 检测服务器国家决定 Xray 下载加速
  # ========================
  COUNTRY=$(curl -fsS --max-time 8 https://ipinfo.io/country 2>/dev/null || true)
  COUNTRY=$(echo -n "$COUNTRY" | tr -d '\r\n' | tr '[:lower:]' '[:upper:]')

  MIRROR_PREFIX=""
  if [ "$COUNTRY" = "CN" ]; then
    echo "服务器在中国，启用 gh.llkk.cc 加速下载 Xray"
    MIRROR_PREFIX="https://gh.llkk.cc/https://"
  else
    echo "服务器不在中国，使用官方 GitHub 直链"
  fi

  # ========================
  # 下载并安装 Xray
  # ========================
  if ! command -v xray >/dev/null 2>&1; then
    echo "下载 Xray..."
    RELATIVE_URL="github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip"
    XURL="${MIRROR_PREFIX}${RELATIVE_URL}"
    TMP_ZIP="/tmp/xray.zip"
    curl -L -o "$TMP_ZIP" "$XURL"
    unzip -o "$TMP_ZIP" -d /tmp/xray_unpack >/dev/null
    install -m 755 /tmp/xray_unpack/xray "$XRAY_BIN_DIR/xray"
    rm -rf /tmp/xray_unpack "$TMP_ZIP"
  fi

  # ========================
  # 创建目录
  # ========================
  mkdir -p "$XRAY_CONFIG_DIR" "$SSL_DIR"

  UUID=$(uuidgen)
  echo "生成 UUID: $UUID"

  # ========================
  # 使用 Let's Encrypt standalone 申请证书
  # ========================
  "$ACME_DIR/acme.sh" --server https://acme-v02.api.letsencrypt.org/directory \
    --issue -d "$DOMAIN" --standalone --keylength ec-256

  "$ACME_DIR/acme.sh" --install-cert -d "$DOMAIN" \
    --key-file "$SSL_DIR/$DOMAIN.key" \
    --fullchain-file "$SSL_DIR/$DOMAIN.crt" \
    --reloadcmd "systemctl restart xray || true"

  # ========================
  # 写 Xray 配置
  # ========================
  mkdir -p $XRAY_LOG_DIR
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
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "alterId": 0
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {
          "certificates": [
            {
              "certificateFile": "${SSL_DIR}/${DOMAIN}.crt",
              "keyFile": "${SSL_DIR}/${DOMAIN}.key"
            }
          ]
        },
        "wsSettings": {
          "path": "${WS_PATH}",
          "headers": {
            "Host": "${WS_HOST}"
          }
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {}
    },
    {
      "protocol": "blackhole",
      "tag": "blocked",
      "settings": {}
    }
  ]
}
EOF

  # ========================
  # systemd 服务
  # ========================
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
  systemctl enable --now xray.service

  # ========================
  # 输出 vmess 链接
  # ========================
  CLIENT_JSON=$(cat <<EOF
{"v": "2","ps": "vmess-ws-tls-yunpanlive","add": "$DOMAIN","port": "443","id": "$UUID","aid": "0","net": "ws","type": "none","host": "$WS_HOST","path": "$WS_PATH","tls": "tls","sni": "$DOMAIN","allowInsecure": false}
EOF
)

  VMESS_BASE64=$(echo -n "$CLIENT_JSON" | base64 -w 0)
  echo "==================== 安装完成 ===================="
  echo "vmess 链接："
  echo "vmess://$VMESS_BASE64"
}

# ------------------------
# 卸载函数
# ------------------------
uninstall_xray() {
  read -rp "您确定要卸载 Xray 吗？这将删除所有相关文件、证书和配置。[y/N]: " confirm
  if [[ ! "$confirm" =~ ^[yY]$ ]]; then
    echo "操作已取消。"
    exit 0
  fi

  echo "开始执行 Xray 卸载流程..."
  
  # 停止并禁用服务
  systemctl stop xray.service || true
  systemctl disable xray.service || true
  echo "Xray 服务已停止并禁用。"

  # 卸载 acme.sh
  if [ -d "$ACME_DIR" ]; then
    "$ACME_DIR/acme.sh" --uninstall
    rm -rf "$ACME_DIR"
    echo "acme.sh 已卸载。"
  fi

  # 删除文件和目录
  rm -f "$SYSTEMD_SERVICE"
  rm -f "$XRAY_BIN_DIR/xray"
  rm -rf "$XRAY_CONFIG_DIR"
  rm -rf "$SSL_DIR"
  rm -rf "$XRAY_LOG_DIR"
  echo "Xray 相关文件和目录已删除。"

  # 重新加载 systemd
  systemctl daemon-reload
  
  echo "==================== 卸载完成 ===================="
}

# ==================================================
# ==================================================
# 脚本主逻辑
# ==================================================
# ==================================================
main() {
  # 检查 root 权限
  if [ "$(id -u)" -ne 0 ]; then
    echo "请以 root 或 sudo 权限运行此脚本。"
    exit 1
  fi

  # 主菜单
  echo "=========================================="
  echo " Xray 一键安装/卸载脚本"
  echo "=========================================="
  echo "请选择要执行的操作:"
  echo "1) 安装 Xray"
  echo "2) 卸载 Xray"
  echo "=========================================="
  read -rp "请输入选项 [1-2]: " choice

  case $choice in
    1)
      install_xray
      ;;
    2)
      uninstall_xray
      ;;
    *)
      echo "错误：无效的选项，脚本退出。"
      exit 1
      ;;
  esac
}

# 执行主函数
main

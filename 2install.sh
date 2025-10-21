#!/usr/bin/env bash
# Komari Agent Cross-Platform Installer (with gh.llkk.cc enforced for GitHub)
# 支持：Linux(systemd/OpenRC/procd)、macOS(launchd)、FreeBSD；可选安装指定版本
# 重点：所有 GitHub 相关 URL 统一通过 https://gh.llkk.cc 加速

set -Eeuo pipefail
IFS=$'\n\t'

# =============== Colors ===============
RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[0;33m'
BLUE='\033[0;34m' PURPLE='\033[0;35m' CYAN='\033[0;36m'
WHITE='\033[1;37m' NC='\033[0m'

# =============== Logging ===============
log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warning() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()    { echo -e "${PURPLE}[STEP]${NC} $*"; }
log_config()  { echo -e "${CYAN}[CONFIG]${NC} $*"; }

# =============== Global Config ===============
service_name="komari-agent"
target_dir="/opt/komari"
install_version=""        # e.g. v1.2.3；留空=latest
need_vnstat=false
komari_args=""

# 统一 GitHub 加速前缀（只用于 *.github.com / raw.githubusercontent.com）
GH_ACCEL="https://gh.llkk.cc"

gh_wrap() {
  # 仅当 URL 属于 GitHub 相关域名时加速
  case "$1" in
    https://github.com/*|https://raw.githubusercontent.com/*|https://api.github.com/*)
      echo "${GH_ACCEL}/$1"
      ;;
    *)
      echo "$1"
      ;;
  esac
}

# =============== OS Detect ===============
os_type="$(uname -s || true)"
case "$os_type" in
  Darwin) os_name="darwin"; target_dir="/usr/local/komari";
          if [ ! -w "/usr/local" ] && [ "${EUID:-0}" -ne 0 ]; then
            target_dir="$HOME/.komari"
            log_info "无 /usr/local 写权限，使用用户目录: $target_dir"
          fi ;;
  Linux)  os_name="linux" ;;
  FreeBSD) os_name="freebsd" ;;
  MINGW*|MSYS*|CYGWIN*) os_name="windows"; target_dir="/c/komari" ;;
  *) log_error "Unsupported OS: $os_type"; exit 1 ;;
esac

# =============== Args Parse ===============
while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-dir) target_dir="$2"; shift 2 ;;
    --install-service-name) service_name="$2"; shift 2 ;;
    --install-version) install_version="$2"; shift 2 ;;
    --month-rotate) need_vnstat=true; komari_args+=" $1"; shift ;;
    --install*) log_warning "Unknown install parameter: $1"; shift ;;
    *) komari_args+=" $1"; shift ;;
  esac
done
komari_args="${komari_args# }"

# =============== Root Requirement ===============
require_root_for_deps=true
if [ "$os_name" = "darwin" ] && command -v brew >/dev/null 2>&1; then
  require_root_for_deps=false
fi
if [ "${EUID:-0}" -ne 0 ] && [ "$require_root_for_deps" = true ]; then
  log_error "请以 root 运行（或使用 sudo）"
  exit 1
fi

echo -e "${WHITE}===========================================${NC}"
echo -e "${WHITE}    Komari Agent Installation Script     ${NC}"
echo -e "${WHITE}===========================================${NC}\n"
log_config "Service name: ${service_name}"
log_config "Install dir:  ${target_dir}"
log_config "Binary args:  ${komari_args:-"(none)"}"
if [ -n "$install_version" ]; then
  log_config "Agent version: $install_version"
else
  log_config "Agent version: Latest"
fi
log_config "vnstat need:  $([ "$need_vnstat" = true ] && echo Required || echo Not\ required)"
echo ""

komari_agent_path="${target_dir}/agent"

# =============== Uninstall Previous ===============
uninstall_previous() {
  log_step "检查旧版本/服务..."
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl list-unit-files | grep -q "^${service_name}.service"; then
      log_info "停止并禁用 systemd 服务..."
      systemctl stop "${service_name}.service" || true
      systemctl disable "${service_name}.service" || true
      rm -f "/etc/systemd/system/${service_name}.service"
      systemctl daemon-reload || true
    fi
  fi

  if command -v rc-service >/dev/null 2>&1 && [ -f "/etc/init.d/${service_name}" ]; then
    log_info "停止并删除 OpenRC 服务..."
    rc-service "${service_name}" stop || true
    rc-update del "${service_name}" default || true
    rm -f "/etc/init.d/${service_name}"
  fi

  if command -v uci >/dev/null 2>&1 && [ -f "/etc/init.d/${service_name}" ]; then
    log_info "停止并删除 procd 服务..."
    /etc/init.d/${service_name} stop || true
    /etc/init.d/${service_name} disable || true
    rm -f "/etc/init.d/${service_name}"
  fi

  if [ "$os_name" = "darwin" ] && command -v launchctl >/dev/null 2>&1; then
    system_plist="/Library/LaunchDaemons/com.komari.${service_name}.plist"
    user_plist="$HOME/Library/LaunchAgents/com.komari.${service_name}.plist"
    if [ -f "$system_plist" ]; then
      log_info "移除系统级 launchd..."
      launchctl bootout system "$system_plist" 2>/dev/null || true
      rm -f "$system_plist"
    fi
    if [ -f "$user_plist" ]; then
      log_info "移除用户级 launchd..."
      launchctl bootout "gui/$(id -u)" "$user_plist" 2>/dev/null || true
      rm -f "$user_plist"
    fi
  fi

  if [ -f "$komari_agent_path" ]; then
    log_info "移除旧二进制..."
    rm -f "$komari_agent_path"
  fi
}
uninstall_previous

# =============== Dependencies ===============
install_dependencies() {
  log_step "检查并安装依赖..."
  local deps="curl"
  local missing=""
  for c in $deps; do command -v "$c" >/dev/null 2>&1 || missing+=" $c"; done
  if [ -n "$missing" ]; then
    if command -v apt >/dev/null 2>&1; then
      log_info "apt 安装:${missing}"
      apt update -y && apt install -y $missing
    elif command -v dnf >/dev/null 2>&1; then
      log_info "dnf 安装:${missing}"
      dnf install -y $missing
    elif command -v yum >/dev/null 2>&1; then
      log_info "yum 安装:${missing}"
      yum install -y $missing
    elif command -v apk >/dev/null 2>&1; then
      log_info "apk 安装:${missing}"
      apk add --no-cache $missing
    elif command -v pacman >/dev/null 2>&1; then
      log_info "pacman 安装:${missing}"
      pacman -Sy --noconfirm $missing
    elif command -v brew >/dev/null 2>&1; then
      log_info "brew 安装:${missing}"
      brew install $missing
    else
      log_error "未找到可用包管理器（apt/dnf/yum/apk/pacman/brew）"
      exit 1
    fi
    for c in $missing; do command -v "$c" >/dev/null 2>&1 || { log_error "安装失败: $c"; exit 1; }; done
    log_success "依赖已就绪"
  else
    log_success "依赖已满足"
  fi
}
install_dependencies

# =============== vnstat (optional) ===============
install_vnstat() {
  [ "$need_vnstat" = true ] || return 0
  log_step "为 --month-rotate 检查/安装 vnstat..."
  if command -v vnstat >/dev/null 2>&1; then
    log_success "vnstat 已存在"
    return 0
  fi
  if command -v apt >/dev/null 2>&1; then
    apt update -y && apt install -y vnstat
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y vnstat
  elif command -v yum >/dev/null 2>&1; then
    yum install -y vnstat
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache vnstat
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm vnstat
  elif command -v brew >/dev/null 2>&1; then
    brew install vnstat
  else
    log_error "无法安装 vnstat，请手动安装后重试"
    exit 1
  fi
  if command -v vnstat >/dev/null 2>&1; then
    log_success "vnstat 安装成功"
    if command -v systemctl >/dev/null 2>&1; then
      systemctl enable vnstat 2>/dev/null || systemctl enable vnstatd 2>/dev/null || true
      systemctl start  vnstat 2>/dev/null || systemctl start  vnstatd 2>/dev/null || true
    fi
  fi
}
install_vnstat

# =============== Arch Detect ===============
arch="$(uname -m || true)"
case "$arch" in
  x86_64|amd64) arch="amd64" ;;
  aarch64|arm64) arch="arm64" ;;
  i386|i686) case "$os_name" in freebsd|linux|windows) arch="386";; *) log_error "32位 x86 不支持在 $os_name"; exit 1;; esac ;;
  armv7*|armv6*) case "$os_name" in freebsd|linux) arch="arm";; *) log_error "32位 ARM 不支持在 $os_name"; exit 1;; esac ;;
  *) log_error "Unsupported arch: $arch on $os_name"; exit 1 ;;
esac
log_info "Detected OS: ${os_name}, Arch: ${arch}"

# Windows 可选 .exe 后缀
bin_ext=""
[ "$os_name" = "windows" ] && bin_ext=".exe"

# =============== Version Resolve (via gh.llkk.cc) ===============
resolve_latest_tag() {
  # 1) GitHub API（加速）
  local api_url api_wrapped
  api_url="https://api.github.com/repos/komari-monitor/komari-agent/releases/latest"
  api_wrapped="$(gh_wrap "$api_url")"
  if curl -fsSL -H "Accept: application/vnd.github+json" "$api_wrapped" \
     | grep -oE '"tag_name"\s*:\s*"[^"]+"' | head -n1 | cut -d'"' -f4; then
    return 0
  fi
  # 2) 302 跳转解析（加速）
  local latest_url latest_wrapped loc
  latest_url="https://github.com/komari-monitor/komari-agent/releases/latest"
  latest_wrapped="$(gh_wrap "$latest_url")"
  loc="$(curl -fsSIL -o /dev/null -w '%{redirect_url}' "$latest_wrapped" || true)"
  echo "${loc##*/}"
}

if [ -z "$install_version" ] || [ "$install_version" = "latest" ]; then
  tag="$(resolve_latest_tag)"
  if [ -z "$tag" ]; then
    log_error "无法解析最新版本 tag；请稍后重试或手动指定 --install-version vX.Y.Z"
    exit 1
  fi
  version_to_install="$tag"
else
  version_to_install="$install_version"
fi
log_info "将安装版本：${version_to_install}"

# =============== Build Candidates & Download (via gh.llkk.cc) ===============
file_base="komari-agent-${os_name}-${arch}${bin_ext}"
candidates=(
  "${file_base}"                   # 裸二进制
  "komari-agent-${os_name}-${arch}.tar.gz"  # 压缩包备选
)

base_release_url="https://github.com/komari-monitor/komari-agent/releases/download/${version_to_install}"

log_step "创建安装目录: $target_dir"
mkdir -p "$target_dir"
[ -w "$target_dir" ] || { log_error "目录不可写: $target_dir"; exit 1; }

tmp_file="$(mktemp "${target_dir}/.agent.XXXXXX")"
cleanup() { rm -f "$tmp_file" 2>/dev/null || true; }
trap cleanup EXIT

extract_if_needed() {
  local name="$1"
  if [[ "$name" == *.tar.gz ]]; then
    local tmpdir; tmpdir="$(mktemp -d)"
    tar -xzf "$komari_agent_path" -C "$tmpdir"
    # 尝试找到真正可执行文件
    local bin_found
    bin_found="$(find "$tmpdir" -maxdepth 2 -type f -perm -u=x \
                 \( -name 'agent' -o -name 'komari-agent' -o -name "${file_base}" \) | head -n1)"
    if [ -z "$bin_found" ]; then
      log_error "压缩包内未找到可执行文件"
      rm -rf "$tmpdir" "$komari_agent_path"
      return 1
    fi
    mv -f "$bin_found" "$komari_agent_path"
    rm -rf "$tmpdir"
  fi
  chmod +x "$komari_agent_path"
  return 0
}

download_success=false
for name in "${candidates[@]}"; do
  url="${base_release_url}/${name}"
  url_wrapped="$(gh_wrap "$url")"
  log_step "下载二进制: ${name}"
  log_info "URL: ${url_wrapped}"
  if curl -fSL --retry 3 -o "$tmp_file" "$url_wrapped"; then
    mv -f "$tmp_file" "$komari_agent_path"
    if extract_if_needed "$name"; then
      download_success=true
      break
    fi
  fi
done

if [ "$download_success" = false ]; then
  log_error "所有候选文件名均下载失败。请检查版本号(${version_to_install})或稍后重试。"
  exit 1
fi

log_success "Komari-agent 安装到: ${komari_agent_path}"

# =============== Init Detect ===============
detect_init_system() {
  [ -f /etc/NIXOS ] && { echo "nixos"; return; }
  if [ -f /etc/alpine-release ]; then
    if command -v rc-service >/dev/null 2>&1 || [ -f /sbin/openrc-run ]; then
      echo "openrc"; return
    fi
  fi
  local pid1; pid1="$(ps -p 1 -o comm= 2>/dev/null | tr -d ' ' || true)"
  if { [ "$pid1" = "systemd" ] || [ -d /run/systemd/system ]; } && command -v systemctl >/dev/null 2>&1; then
    systemctl list-units >/dev/null 2>&1 && { echo "systemd"; return; }
  fi
  [ "$pid1" = "openrc-init" ] && command -v rc-service >/dev/null 2>&1 && { echo "openrc"; return; }
  if [ "$pid1" = "init" ] && [ ! -f /etc/alpine-release ]; then
    [ -d /run/openrc ] && command -v rc-service >/dev/null 2>&1 && { echo "openrc"; return; }
    [ -f /sbin/openrc ] && command -v rc-service >/dev/null 2>&1 && { echo "openrc"; return; }
  fi
  command -v uci >/dev/null 2>&1 && [ -f /etc/rc.common ] && { echo "procd"; return; }
  [ "$os_name" = "darwin" ] && command -v launchctl >/dev/null 2>&1 && { echo "launchd"; return; }
  command -v systemctl >/dev/null 2>&1 && systemctl list-units >/dev/null 2>&1 && { echo "systemd"; return; }
  command -v rc-service >/dev/null 2>&1 && [ -d /etc/init.d ] && { echo "openrc"; return; }
  echo "unknown"
}

log_step "配置系统服务..."
init_system="$(detect_init_system)"
log_info "Detected init: $init_system"

# =============== Service per init ===============
if [ "$init_system" = "nixos" ]; then
  log_warning "NixOS 需 declarative 配置，请在 configuration.nix 中加入："
  cat <<NIX

systemd.services.${service_name} = {
  description = "Komari Agent Service";
  after = [ "network.target" ];
  wantedBy = [ "multi-user.target" ];
  serviceConfig = {
    Type = "simple";
    ExecStart = "${komari_agent_path} ${komari_args}";
    WorkingDirectory = "${target_dir}";
    Restart = "always";
    User = "root";
  };
};
NIX
  log_info "然后执行: sudo nixos-rebuild switch"

elif [ "$init_system" = "openrc" ]; then
  service_file="/etc/init.d/${service_name}"
  cat > "$service_file" <<'EOF'
#!/sbin/openrc-run
name="Komari Agent Service"
description="Komari monitoring agent"

command=""
command_args=""
command_user="root"
directory=""
pidfile="/run/komari-agent.pid"
retry="SIGTERM/30"
supervisor=supervise-daemon

depend() { need net after network; }
EOF
  sed -i "s|^command=.*$|command=\"${komari_agent_path}\"|g" "$service_file"
  sed -i "s|^command_args=.*$|command_args=\"${komari_args}\"|g" "$service_file"
  sed -i "s|^directory=.*$|directory=\"${target_dir}\"|g" "$service_file"

  chmod +x "$service_file"
  rc-update add "${service_name}" default
  rc-service "${service_name}" start
  log_success "OpenRC 服务已配置并启动"

elif [ "$init_system" = "systemd" ]; then
  service_file="/etc/systemd/system/${service_name}.service"
  cat > "$service_file" <<EOF
[Unit]
Description=Komari Agent Service
After=network.target

[Service]
Type=simple
ExecStart=${komari_agent_path} ${komari_args}
WorkingDirectory=${target_dir}
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "${service_name}.service"
  systemctl start  "${service_name}.service"
  log_success "systemd 服务已配置并启动"

elif [ "$init_system" = "procd" ]; then
  service_file="/etc/init.d/${service_name}"
  cat > "$service_file" <<'EOF'
#!/bin/sh /etc/rc.common
START=99
STOP=10
USE_PROCD=1

PROG=""
ARGS=""

start_service() {
  procd_open_instance
  procd_set_param command $PROG $ARGS
  procd_set_param respawn
  procd_set_param stdout 1
  procd_set_param stderr 1
  procd_set_param user root
  procd_close_instance
}

stop_service() {
  killall $(basename "$PROG") 2>/dev/null || true
}

reload_service() { stop; start; }
EOF
  sed -i "s|^PROG=.*$|PROG=\"${komari_agent_path}\"|g" "$service_file"
  sed -i "s|^ARGS=.*$|ARGS=\"${komari_args}\"|g" "$service_file"

  chmod +x "$service_file"
  /etc/init.d/${service_name} enable
  /etc/init.d/${service_name} start
  log_success "procd 服务已配置并启动"

elif [ "$init_system" = "launchd" ]; then
  if [[ "$target_dir" =~ ^/Users/.* ]] || [ "${EUID:-0}" -ne 0 ]; then
    plist_dir="$HOME/Library/LaunchAgents"
    plist_file="$plist_dir/com.komari.${service_name}.plist"
    service_user="$(whoami)"
    log_dir="$HOME/Library/Logs"
    scope="gui/$(id -u)"
  else
    plist_dir="/Library/LaunchDaemons"
    plist_file="$plist_dir/com.komari.${service_name}.plist"
    service_user="root"
    log_dir="/var/log"
    scope="system"
  fi
  mkdir -p "$plist_dir"
  {
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.komari.${service_name}</string>
<key>ProgramArguments</key><array>
<string>${komari_agent_path}</string>
EOF
    for a in $komari_args; do printf "  <string>%s</string>\n" "$a"; done
    cat <<EOF
</array>
<key>WorkingDirectory</key><string>${target_dir}</string>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>UserName</key><string>${service_user}</string>
<key>StandardOutPath</key><string>${log_dir}/${service_name}.log</string>
<key>StandardErrorPath</key><string>${log_dir}/${service_name}.log</string>
</dict></plist>
EOF
  } > "$plist_file"

  if launchctl bootstrap "$scope" "$plist_file"; then
    log_success "launchd 服务已配置并启动"
  else
    log_error "加载 launchd 失败"
    exit 1
  fi

else
  log_error "未知或不受支持的 init: $init_system （支持: systemd/openrc/procd/launchd）"
  exit 1
fi

echo
echo -e "${WHITE}===========================================${NC}"
if [ -f /etc/NIXOS ]; then
  log_success "Komari-agent 二进制已安装！"
  log_warning "NixOS 请按提示 declarative 配置后 rebuild。"
else
  log_success "Komari-agent 安装完成！"
fi
log_config "Service:   $service_name"
log_config "Arguments: ${komari_args:-"(none)"}"
echo -e "${WHITE}===========================================${NC}"

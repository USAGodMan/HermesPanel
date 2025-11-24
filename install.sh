#!/bin/bash

# ==============================================================================
# 🚀 Hermes Agent 一键安装与管理脚本 [旗舰版 v4.0]
#
# 功能特性:
# 1. [双模式] 支持 CLI 静默安装 (CI/CD友好) 与 交互式菜单管理
# 2. [全自动] 自动安装依赖: Gost v3 + Hermes Agent
# 3. [迁移] 自动清理旧版 hermes-agent 服务
# 4. [兼容] 适配 Systemd, 自动识别架构 (amd64/arm64)
# ==============================================================================

set -e

# --- 样式定义 ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;36m'; NC='\033[0m'

# --- 核心配置 ---
GITHUB_REPO="USAGodMan/HermesPanel"
# 【更名】统一改为 hermes
AGENT_BINARY_NAME="hermes"
SERVICE_NAME="hermes"

# 依赖版本
GOST_VERSION="v3.2.6"

# 路径配置
INSTALL_PATH="/usr/local/bin"
CONFIG_DIR="/etc/hermes"
CONFIG_FILE="${CONFIG_DIR}/agent-config.json"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

# 依赖列表
DEPS="curl jq systemd tar gzip"

# 参数默认值
USE_PLAINTEXT="false"
INSECURE_SKIP_VERIFY="false"
TLS_CERT_FILE=""
TLS_KEY_FILE=""
REPORT_INTERVAL="3"
NON_INTERACTIVE="false"

# --- 基础工具函数 ---
log_info() { echo -e "${GREEN}[INFO]${NC} ✨ $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} ⚠️ $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} ❌ $1"; exit 1; }

command_exists() { command -v "$1" >/dev/null 2>&1; }

init_sudo() { 
  SUDO=""
  if [ "$(id -u)" -ne 0 ]; then 
    if ! command_exists sudo; then log_error "此脚本需要 root 或 sudo 权限。"; fi
    SUDO="sudo"
  fi 
}

# --- 菜单 UI ---
show_banner() {
  clear
  echo -e "${BLUE}"
  echo "  _   _                                "
  echo " | | | | ___ _ __ _ __ ___   ___  ___  "
  echo " | |_| |/ _ \ '__| '_ \` _ \ / _ \/ __| "
  echo " |  _  |  __/ |  | | | | | |  __/\__ \ "
  echo " |_| |_|\___|_|  |_| |_| |_|\___||___/ "
  echo -e "${NC}"
  echo -e "  🚀 Hermes Agent 管理脚本 ${YELLOW}[v4.0]${NC}"
  echo -e "  🔗 GitHub: https://github.com/${GITHUB_REPO}"
  echo "------------------------------------------------"
}

show_menu() {
  show_banner
  # 获取状态
  if systemctl is-active --quiet "${SERVICE_NAME}"; then
    STATUS="${GREEN}运行中${NC}"
  else
    if command_exists "${AGENT_BINARY_NAME}"; then
      STATUS="${RED}已停止${NC}"
    else
      STATUS="${YELLOW}未安装${NC}"
    fi
  fi
  
  echo -e "当前状态: ${STATUS}"
  echo ""
  echo -e "${GREEN}1.${NC} 安装 / 更新 Agent"
  echo -e "${GREEN}2.${NC} 卸载 Agent"
  echo -e "${GREEN}3.${NC} 查看运行状态"
  echo -e "${GREEN}4.${NC} 查看实时日志 (Ctrl+C 退出)"
  echo -e "${GREEN}5.${NC} 重启服务"
  echo -e "${GREEN}6.${NC} 修改配置文件"
  echo -e "${GREEN}0.${NC} 退出"
  echo "------------------------------------------------"
  read -p "请输入数字 [0-6]: " num
  
  case "$num" in
    1) do_install_or_update ;;
    2) do_uninstall ;;
    3) $SUDO systemctl status "${SERVICE_NAME}" -l ;;
    4) $SUDO journalctl -u "${SERVICE_NAME}" -f -n 50 ;;
    5) 
      log_info "正在重启服务..."
      $SUDO systemctl restart "${SERVICE_NAME}"
      start_and_enable_service 
      ;;
    6)
      if [ -f "$CONFIG_FILE" ]; then
        if command_exists nano; then $SUDO nano "$CONFIG_FILE"; 
        elif command_exists vi; then $SUDO vi "$CONFIG_FILE";
        else log_error "未找到编辑器 (nano/vi)，请手动修改: $CONFIG_FILE"; fi
        log_info "配置已修改，正在重启服务..."
        $SUDO systemctl restart "${SERVICE_NAME}"
      else
        log_error "配置文件不存在，请先安装。"
      fi
      ;;
    0) exit 0 ;;
    *) log_error "请输入正确的数字。" ;;
  esac
}

# --- 安装逻辑 ---

install_dependencies() {
  local m=""
  if command_exists apt-get; then m="apt-get"; elif command_exists yum; then m="yum"; elif command_exists dnf; then m="dnf"; else log_error "无法检测到包管理器。请手动安装: ${DEPS}"; fi
  
  # 仅在非 root 且无 sudo 缓存时尝试 update，避免太慢
  # $SUDO "$m" update -y >/dev/null 2>&1 
  
  for dep in $DEPS; do 
    if ! command_exists "$dep"; then 
      log_info "正在安装依赖: $dep..."
      $SUDO "$m" install -y "$dep" >/dev/null
    fi
  done
  log_info "📦 基础依赖检查完成。"
}

detect_arch() {
  ARCH=$(uname -m)
  case $ARCH in
    x86_64) ARCH="amd64";;
    aarch64) ARCH="arm64";;
    armv7l) ARCH="armv7";;
    *) log_error "不支持的架构: $ARCH";;
  esac
  # log_info "💻 系统架构: ${ARCH}"
}

get_latest_agent_version() {
  log_info "📡 正在获取最新 Agent 版本..."
  LATEST_VERSION=$(curl -s "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" | jq -r '.tag_name')
  if [ -z "$LATEST_VERSION" ] || [ "$LATEST_VERSION" = "null" ]; then log_error "无法获取最新版本，请检查网络或指定 --version"; fi
  log_info "🎯 最新 Agent 版本: ${LATEST_VERSION}"
}

# 安装 Gost 核心组件
install_gost() {
  if command_exists gost; then
    CURRENT_GOST=$(gost -V 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    TARGET_VER_NUM="${GOST_VERSION#v}"
    if [ "$CURRENT_GOST" == "$TARGET_VER_NUM" ]; then
      log_info "🔍 Gost 已安装且版本一致 ($CURRENT_GOST)，跳过。"
      return
    fi
    log_warn "🔍 Gost 版本不匹配 ($CURRENT_GOST -> $TARGET_VER_NUM)，准备更新..."
  fi

  log_info "📥 正在安装 Gost (${GOST_VERSION})..."
  CLEAN_VERSION="${GOST_VERSION#v}"
  GOST_FILENAME="gost_${CLEAN_VERSION}_linux_${ARCH}.tar.gz"
  GOST_URL="https://github.com/go-gost/gost/releases/download/${GOST_VERSION}/${GOST_FILENAME}"
  
  TMP_DIR=$(mktemp -d)
  if ! curl -Lfs -o "${TMP_DIR}/gost.tar.gz" "$GOST_URL"; then
    rm -rf "$TMP_DIR"
    log_error "Gost 下载失败！"
  fi

  tar -xzf "${TMP_DIR}/gost.tar.gz" -C "$TMP_DIR"
  $SUDO install -m 0755 "${TMP_DIR}/gost" "${INSTALL_PATH}/gost"
  rm -rf "$TMP_DIR"
  log_info "✅ Gost 安装完成。"
}

# 迁移清理旧版 hermes-agent
cleanup_legacy_service() {
  if systemctl is-active --quiet hermes-agent || systemctl is-enabled --quiet hermes-agent; then
    log_warn "检测到旧版服务 'hermes-agent'，正在迁移..."
    $SUDO systemctl stop hermes-agent || true
    $SUDO systemctl disable hermes-agent || true
    $SUDO rm -f /etc/systemd/system/hermes-agent.service
    $SUDO rm -f "${INSTALL_PATH}/hermes-agent"
    $SUDO systemctl daemon-reload
    log_info "🗑️ 旧版服务已清理。"
  fi
}

download_and_install_agent() {
  local version=$1
  # 注意：这里下载的文件名不带 -agent 后缀，需确保 GitHub Release 文件名为 hermes-linux-amd64
  local file="${AGENT_BINARY_NAME}-linux-${ARCH}" 
  local url="https://github.com/${GITHUB_REPO}/releases/download/${version}/${file}"
  
  log_info "📥 正在下载 Agent: ${url}"
  TMP_FILE=$(mktemp)
  if ! curl -Lfs -o "$TMP_FILE" "$url"; then rm -f "$TMP_FILE"; log_error "Agent 下载失败，请检查版本号或网络。"; fi
  
  log_info "🔧 安装二进制文件..."
  $SUDO install -m 0755 "$TMP_FILE" "${INSTALL_PATH}/${AGENT_BINARY_NAME}"
  rm -f "$TMP_FILE"
}

create_config() {
  if [ -f "$CONFIG_FILE" ]; then 
    log_warn "配置文件已存在，跳过创建。"
    # 如果是交互式且用户想修改，其实可以加逻辑，这里保持简单，保留旧配置
    return
  fi

  if [ "$NON_INTERACTIVE" = "true" ]; then
    if [ -z "$BACKEND_ADDRESS" ] || [ -z "$SECRET_KEY" ]; then log_error "非交互模式下，必须提供 --key 和 --server 参数。"; fi
  else
    # 交互式向导
    echo ""
    log_info "--- 配置向导 ---"
    read -p "🤔 请输入后端 gRPC 地址 (例如 demo.com:443): " BACKEND_ADDRESS
    read -p "🤔 请输入节点密钥 (Secret Key): " SECRET_KEY
    read -p "🤔 是否使用明文 gRPC? (y/N, 默认 No): " USE_PLAINTEXT_IN
    if [[ "$USE_PLAINTEXT_IN" =~ ^[Yy]$ ]]; then USE_PLAINTEXT="true"; fi
  fi
  
  if [ -z "$BACKEND_ADDRESS" ] || [ -z "$SECRET_KEY" ]; then log_error "配置无效：后端地址与密钥为必填项。"; fi

  log_info "📝 写入配置文件: ${CONFIG_FILE}"
  $SUDO mkdir -p "$CONFIG_DIR"; $SUDO chmod 755 "$CONFIG_DIR"
  $SUDO tee "$CONFIG_FILE" >/dev/null <<EOF
{
  "backend_address": "${BACKEND_ADDRESS}",
  "secret_key": "${SECRET_KEY}",
  "insecure_skip_verify": ${INSECURE_SKIP_VERIFY},
  "tls_cert_file": "${TLS_CERT_FILE}",
  "tls_key_file": "${TLS_KEY_FILE}",
  "use_plaintext": ${USE_PLAINTEXT},
  "report_interval": ${REPORT_INTERVAL},
  "log_level": "info",
  "log_format": "json"
}
EOF
  $SUDO chmod 644 "$CONFIG_FILE"
}

create_systemd_service() {
  log_info "⚙️  创建 Systemd 服务..."
  # 关键: Environment PATH 确保能找到 gost
  $SUDO tee "$SERVICE_FILE" >/dev/null <<EOF
[Unit]
Description=Hermes Agent Service
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
Environment="PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
ExecStart=${INSTALL_PATH}/${AGENT_BINARY_NAME} --config ${CONFIG_FILE}
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
  $SUDO chmod 644 "$SERVICE_FILE"
}

start_and_enable_service() {
  log_info "▶️  启动服务..."
  $SUDO systemctl daemon-reload
  $SUDO systemctl enable "${SERVICE_NAME}"
  $SUDO systemctl start "${SERVICE_NAME}" || true
  sleep 2
  if $SUDO systemctl is-active --quiet "${SERVICE_NAME}"; then
    log_info "✅ 服务启动成功！"
    log_info "   查看状态: systemctl status ${SERVICE_NAME}"
    log_info "   查看日志: journalctl -u ${SERVICE_NAME} -f"
  else
    log_error "服务启动失败。请检查日志: journalctl -u ${SERVICE_NAME} -n 20 --no-pager"
  fi
}

do_install_or_update() {
  install_dependencies
  detect_arch
  
  if [ -z "$AGENT_VERSION" ]; then get_latest_agent_version; AGENT_VERSION=$LATEST_VERSION; fi

  # 1. 迁移旧服务
  cleanup_legacy_service

  # 2. 停止当前服务
  $SUDO systemctl stop "${SERVICE_NAME}" || true

  # 3. 安装组件
  install_gost
  download_and_install_agent "$AGENT_VERSION"

  # 4. 配置与服务
  create_config
  create_systemd_service

  if [ "$NO_START" = "true" ]; then
    log_info "🟢 安装完成 (未启动)。"
  else
    start_and_enable_service
  fi
  
  if [ "$NON_INTERACTIVE" = "false" ]; then
      read -p "按回车键返回菜单..."
      show_menu
  fi
}

do_uninstall() {
  echo ""
  log_warn "⚠️  警告：您即将卸载 Hermes Agent"
  if [ "$NON_INTERACTIVE" = "false" ]; then
    read -p "确认继续吗? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then log_info "已取消。"; show_menu; return; fi
  fi

  $SUDO systemctl stop "${SERVICE_NAME}" || true
  $SUDO systemctl disable "${SERVICE_NAME}" || true
  
  log_info "🗑️ 删除文件..."
  $SUDO rm -f "$SERVICE_FILE"
  $SUDO rm -f "${INSTALL_PATH}/${AGENT_BINARY_NAME}"
  
  # 询问删除 Gost
  if command_exists gost; then
    if [ "$NON_INTERACTIVE" = "false" ]; then
        read -p "🤔 是否一并删除 Gost 转发核心? (y/N): " del_gost
        if [[ "$del_gost" =~ ^[Yy]$ ]]; then
            $SUDO rm -f "${INSTALL_PATH}/gost"
            log_info "🗑️ Gost 已删除。"
        fi
    else
        # 非交互模式下保留 Gost，以免误删其他程序依赖
        log_info "保留 Gost (非交互模式)。"
    fi
  fi

  if [ -d "$CONFIG_DIR" ]; then
    if [ "$NON_INTERACTIVE" = "false" ]; then
        read -p "🤔 是否删除配置文件? (y/N): " del_conf
        if [[ "$del_conf" =~ ^[Yy]$ ]]; then $SUDO rm -rf "$CONFIG_DIR"; log_info "🗑️ 配置已清空。"; fi
    else
        $SUDO rm -rf "$CONFIG_DIR"
    fi
  fi
  
  $SUDO systemctl daemon-reload
  log_info "✅ 卸载完毕。"
  
  if [ "$NON_INTERACTIVE" = "false" ]; then exit 0; fi
}

usage() {
  echo -e "📋 用法: $0 [选项]"
  echo "  无参数运行进入交互式菜单。"
  echo "  选项:"
  echo "    --key <密钥>                 节点密钥"
  echo "    --server <地址>              后端 gRPC 地址"
  echo "    --version <版本>             指定版本"
  echo "    --no-start                   安装后不启动"
  echo "    --non-interactive            非交互模式 (CI/CD用)"
  echo "    --help                       显示帮助"
  exit 0
}

main() {
  init_sudo

  # 如果有参数，进入 CLI 模式
  if [ "$#" -gt 0 ]; then
    # 简单参数解析器
    while [ "$#" -gt 0 ]; do
      case "$1" in
        install) shift;; # 兼容旧习惯
        --key) SECRET_KEY="$2"; shift 2;;
        --server) BACKEND_ADDRESS="$2"; shift 2;;
        --version) AGENT_VERSION="$2"; shift 2;;
        --use-plaintext) USE_PLAINTEXT="$2"; shift 2;;
        --insecure-skip-verify) INSECURE_SKIP_VERIFY="$2"; shift 2;;
        --tls-cert-file) TLS_CERT_FILE="$2"; shift 2;;
        --tls-key-file) TLS_KEY_FILE="$2"; shift 2;;
        --report-interval) REPORT_INTERVAL="$2"; shift 2;;
        --no-start) NO_START="true"; shift 1;;
        --non-interactive) NON_INTERACTIVE="true"; shift 1;;
        -h|--help) usage;;
        *) 
           # 如果是 uninstall/version 等子命令
           if [[ "$1" == "uninstall" ]]; then do_uninstall; exit 0; fi
           if [[ "$1" == "version" ]]; then ${INSTALL_PATH}/${AGENT_BINARY_NAME} --version; exit 0; fi
           log_error "未知参数: $1"
           ;;
      esac
    done
    
    # 标记为非交互模式 (除非用户只敲了 install 没带参数，这里简单处理)
    if [ -n "$SECRET_KEY" ]; then NON_INTERACTIVE="true"; fi
    
    do_install_or_update
  else
    # 无参数，进入菜单模式
    show_menu
  fi
}

main "$@"

#!/bin/bash

# ==============================================================================
# 🚀 Hermes Agent 一键安装与管理脚本 (v2.5 - 稳定隧道版)
#
# 核心变更:
# - [移除] 移除了所有与 H2 隧道和 MUX (复用) 相关的功能、参数和配置项。
# - [聚焦] 脚本现在只支持基础的 TLS/WS 隧道，专注于稳定性和兼容性。
# ==============================================================================

# --- 全局变量和默认值 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

set -e

GITHUB_REPO="USAGodMan/HermesPanel"
AGENT_BINARY_NAME="hermes-agent"
INSTALL_PATH="/usr/local/bin"
CONFIG_DIR="/etc/hermes"
CONFIG_FILE="${CONFIG_DIR}/agent-config.json"
SERVICE_NAME="hermes-agent"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
DEPS="curl jq systemd" 

# --- 【核心修改 1】: 移除所有 H2 和 MUX 相关的默认值 ---
TUNNEL_WS_PORT="0" # 只保留 WS 端口配置

# --- 工具函数 (已添加 Emoji) ---
log_info() { echo -e "${GREEN}[INFO]${NC} ✨ $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} ⚠️ $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} ❌ $1"; exit 1; }
command_exists() { command -v "$1" >/dev/null 2>&1; }
init_sudo() { SUDO=""; if [ "$(id -u)" -ne 0 ]; then if ! command_exists sudo; then log_error "此脚本需要 root 或 sudo 权限。"; fi; SUDO="sudo"; fi; }

# --- 核心功能函数 ---
usage() {
    echo -e "📋 用法: $0 [命令] [选项]"
    echo "   命令: install (默认), uninstall, version"
    # --- 【核心修改 2】: 大幅简化选项说明 ---
    echo "   选项: --key <密钥>, --server <地址>, --version <版本>"
    echo "         --no-start, --non-interactive, --help"
    echo "   高级: --tunnel-ws-port <端口>"
    exit 0
}

install_dependencies() {
    local pkg_manager=""
    if command_exists apt-get; then pkg_manager="apt-get"; elif command_exists yum; then pkg_manager="yum"; elif command_exists dnf; then pkg_manager="dnf"; else log_error "无法检测到包管理器。请手动安装: ${DEPS}"; fi
    if [ "$pkg_manager" == "apt-get" ]; then $SUDO apt-get update; fi
    for dep in $DEPS; do if ! command_exists "$dep"; then log_info "正在安装依赖: $dep..."; $SUDO "$pkg_manager" install -y "$dep" > /dev/null; fi; done
    log_info "📦 依赖检查与安装完成。"
}

detect_arch() { ARCH=$(uname -m); case $ARCH in x86_64) ARCH="amd64";; aarch64) ARCH="arm64";; *) log_error "不支持的架构: $ARCH";; esac; log_info "💻 系统架构: ${ARCH}"; }
get_latest_version() { log_info "📡 正在从 GitHub 获取最新版本号..."; LATEST_VERSION=$(curl -s "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" | jq -r '.tag_name'); if [ -z "$LATEST_VERSION" ] || [ "$LATEST_VERSION" == "null" ]; then log_error "无法获取最新版本。"; fi; log_info "🎯 最新版本: ${LATEST_VERSION}"; }

download_and_install() {
    local version_to_install=$1; local download_file="${AGENT_BINARY_NAME}-linux-${ARCH}"; local download_url="https://github.com/${GITHUB_REPO}/releases/download/${version_to_install}/${download_file}"
    log_info "📥 正在下载 Agent: ${download_url}"; TMP_FILE=$(mktemp); if ! curl -Lfs -o "$TMP_FILE" "$download_url"; then rm -f "$TMP_FILE"; log_error "下载失败。"; fi
    log_info "🔧 正在安装二进制文件..."; $SUDO install -m 755 "$TMP_FILE" "${INSTALL_PATH}/${AGENT_BINARY_NAME}"; rm -f "$TMP_FILE";
}

create_config() {
    if [ -f "$CONFIG_FILE" ]; then log_warn "配置文件 ${CONFIG_FILE} 已存在，跳过创建。"; return; fi
    if [ "$NON_INTERACTIVE" = "true" ]; then if [ -z "$BACKEND_ADDRESS" ] || [ -z "$SECRET_KEY" ]; then log_error "非交互式模式下必须提供 --key 和 --server。"; fi; else read -p "🤔 请输入后端 gRPC 地址 (例如: my.domain:443): " BACKEND_ADDRESS; read -p "🤔 请输入节点密钥: " SECRET_KEY; fi
    if [ -z "$BACKEND_ADDRESS" ] || [ -z "$SECRET_KEY" ]; then log_error "后端地址和密钥是必填项。"; fi
    log_info "📝 正在创建配置文件: ${CONFIG_FILE}"; $SUDO mkdir -p "$CONFIG_DIR"; $SUDO chmod 755 "$CONFIG_DIR"
    
    # --- 【核心修改 3】: 生成简化的配置文件 ---
    $SUDO tee "$CONFIG_FILE" > /dev/null << EOF
{
  "backend_address": "${BACKEND_ADDRESS}",
  "secret_key": "${SECRET_KEY}",
  "report_interval": 3,
  "log_level": "info",
  "log_format": "json",
  "insecure_skip_verify": false,
  "tunnel_ws_port": ${TUNNEL_WS_PORT}
}
EOF
    $SUDO chmod 644 "$CONFIG_FILE";
}

create_systemd_service() {
    log_info "⚙️  正在创建 systemd 服务..."; $SUDO tee "$SERVICE_FILE" > /dev/null << EOF
[Unit]
Description=Hermes Agent
After=network.target nss-lookup.target
[Service]
Type=simple
User=root
ExecStart=${INSTALL_PATH}/${AGENT_BINARY_NAME} --config ${CONFIG_FILE}
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
EOF
    $SUDO chmod 644 "$SERVICE_FILE";
}

start_and_enable_service() {
    log_info "▶️  重载 systemd 并启动服务..."; $SUDO systemctl daemon-reload; $SUDO systemctl enable "${SERVICE_NAME}"; $SUDO systemctl start "${SERVICE_NAME}"
    sleep 3; if $SUDO systemctl is-active --quiet "${SERVICE_NAME}"; then log_info "✅ ${SERVICE_NAME} 服务启动成功并已设为开机自启。"; else log_error "${SERVICE_NAME} 启动失败，请使用 'sudo journalctl -u ${SERVICE_NAME} -n 100 --no-pager' 查看日志。"; fi
}

do_install_or_update() {
    if command_exists "${AGENT_BINARY_NAME}"; then log_info "🔍 检测到已安装 Agent，准备执行更新..."; is_update=true; else log_info "🚀 准备开始全新安装 Agent..."; is_update=false; fi
    install_dependencies; detect_arch; if [ -z "$AGENT_VERSION" ]; then get_latest_version; AGENT_VERSION=$LATEST_VERSION; fi
    if [ "$is_update" = true ]; then CURRENT_VERSION=$(${INSTALL_PATH}/${AGENT_BINARY_NAME} --version 2>/dev/null || echo "v0.0.0"); if [ "$CURRENT_VERSION" == "$AGENT_VERSION" ]; then log_info "🎉 当前已是最新版本 (${CURRENT_VERSION})，无需任何操作。"; exit 0; fi; log_info "🔄 正在从 ${CURRENT_VERSION} 更新至 ${AGENT_VERSION}..."; $SUDO systemctl stop "${SERVICE_NAME}" || true; fi
    download_and_install "$AGENT_VERSION"
    if [ "$is_update" = false ]; then create_config; create_systemd_service; fi
    if [ "$NO_START" = "true" ]; then log_info "🟢 安装完成，根据指令未启动服务。"; else start_and_enable_service; fi
    log_info "🎉 恭喜！Hermes Agent 已成功安装/更新至版本 ${AGENT_VERSION}。"
}

do_uninstall() {
    log_warn "即将开始卸载 Agent..."; $SUDO systemctl stop "${SERVICE_NAME}" || true; $SUDO systemctl disable "${SERVICE_NAME}" || true;
    log_info "🗑️ 正在删除服务文件和二进制文件..."; $SUDO rm -f "$SERVICE_FILE"; $SUDO rm -f "${INSTALL_PATH}/${AGENT_BINARY_NAME}";
    if [ -d "$CONFIG_DIR" ]; then read -p "🤔 是否删除配置目录 ${CONFIG_DIR}? (y/N): " choice; if [[ "$choice" =~ ^[Yy]$ ]]; then $SUDO rm -rf "$CONFIG_DIR"; log_info "🗑️ 配置目录已删除。"; fi; fi
    $SUDO systemctl daemon-reload; log_info "✅ 卸载完成。";
}

# --- 主逻辑 ---
main() {
    init_sudo; COMMAND="install"; if [[ "$1" == "uninstall" || "$1" == "version" ]]; then COMMAND=$1; shift; fi
    
    # --- 【核心修改 4】: 大幅简化参数解析循环 ---
    while [ "$#" -gt 0 ]; do 
        case "$1" in 
            --key) SECRET_KEY="$2"; shift 2;; 
            --server) BACKEND_ADDRESS="$2"; shift 2;; 
            --version) AGENT_VERSION="$2"; shift 2;; 
            --no-start) NO_START="true"; shift 1;; 
            --non-interactive) NON_INTERACTIVE="true"; shift 1;;
            --tunnel-ws-port) TUNNEL_WS_PORT="$2"; shift 2;;
            -h|--help) usage;; 
            *) log_error "未知参数: $1";; 
        esac; 
    done
    
    case "$COMMAND" in 
        install) do_install_or_update;; 
        uninstall) do_uninstall;; 
        version) ${INSTALL_PATH}/${AGENT_BINARY_NAME} --version;; 
        *) usage;; 
    esac
}

main "$@"

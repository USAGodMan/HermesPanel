#!/bin/bash

# ==============================================================================
# Hermes Agent 一键安装与管理脚本 (v2.4 - 标准化信任模型)
#
# 核心变更:
# - [移除] 不再处理或安装任何 CA 证书。Agent 将依赖其操作系统的系统信任库。
# - [移除] 生成的 agent-config.json 中不再包含 'ca_cert_path' 字段。
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
# [修正] 移除 ca-certificates 作为硬性依赖，因为 curl 通常已处理好
DEPS="curl jq systemd" 

# --- 工具函数 (保持不变) ---
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
command_exists() { command -v "$1" >/dev/null 2>&1; }
init_sudo() { SUDO=""; if [ "$(id -u)" -ne 0 ]; then if ! command_exists sudo; then log_error "此脚本需要 root 或 sudo 权限。"; fi; SUDO="sudo"; fi; }

# --- 核心功能函数 ---
usage() {
    echo "用法: $0 [命令] [选项]"
    echo "命令: install (默认), uninstall, version"
    # [修正] 移除 CA 相关选项
    echo "选项: --key, --server, --version, --non-interactive, --help"
    exit 0
}

install_dependencies() {
    local pkg_manager=""
    if command_exists apt-get; then pkg_manager="apt-get"; elif command_exists yum; then pkg_manager="yum"; elif command_exists dnf; then pkg_manager="dnf"; else log_error "无法检测到包管理器。请手动安装: ${DEPS}"; fi
    if [ "$pkg_manager" == "apt-get" ]; then $SUDO apt-get update; fi
    for dep in $DEPS; do if ! command_exists "$dep"; then log_info "正在安装依赖: $dep..."; $SUDO "$pkg_manager" install -y "$dep"; fi; done
}

detect_arch() { ARCH=$(uname -m); case $ARCH in x86_64) ARCH="amd64";; aarch64) ARCH="arm64";; *) log_error "不支持的架构: $ARCH";; esac; }
get_latest_version() { LATEST_VERSION=$(curl -s "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" | jq -r '.tag_name'); if [ -z "$LATEST_VERSION" ] || [ "$LATEST_VERSION" == "null" ]; then log_error "无法获取最新版本。"; fi; }

download_and_install() {
    local version_to_install=$1; local download_file="${AGENT_BINARY_NAME}-linux-${ARCH}"; local download_url="https://github.com/${GITHUB_REPO}/releases/download/${version_to_install}/${download_file}"
    log_info "正在下载 Agent: ${download_url}"; TMP_FILE=$(mktemp); if ! curl -Lfs -o "$TMP_FILE" "$download_url"; then rm -f "$TMP_FILE"; log_error "下载失败。"; fi
    $SUDO install -m 755 "$TMP_FILE" "${INSTALL_PATH}/${AGENT_BINARY_NAME}"; rm -f "$TMP_FILE";
}

# [已移除] place_ca_certificate 函数已被完全移除，因为它不再被需要。

# create_config 函数
create_config() {
    if [ -f "$CONFIG_FILE" ]; then log_warn "配置文件 ${CONFIG_FILE} 已存在，跳过。"; return; fi
    if [ "$NON_INTERACTIVE" = "true" ]; then if [ -z "$BACKEND_ADDRESS" ] || [ -z "$SECRET_KEY" ]; then log_error "非交互式模式下必须提供 --key 和 --server。"; fi; else read -p "请输入后端 gRPC 地址: " BACKEND_ADDRESS; read -p "请输入节点密钥: " SECRET_KEY; fi
    if [ -z "$BACKEND_ADDRESS" ] || [ -z "$SECRET_KEY" ]; then log_error "后端地址和密钥是必填项。"; fi
    log_info "正在创建配置文件: ${CONFIG_FILE}"; $SUDO mkdir -p "$CONFIG_DIR"; $SUDO chmod 755 "$CONFIG_DIR"
    
    # [核心修正] 生成的 JSON 中不再包含 "ca_cert_path" 字段
    $SUDO tee "$CONFIG_FILE" > /dev/null << EOF
{
  "backend_address": "${BACKEND_ADDRESS}",
  "secret_key": "${SECRET_KEY}",
  "report_interval": 3,
  "log_level": "info",
  "log_format": "json",
  "insecure_skip_verify": false
}
EOF
    $SUDO chmod 644 "$CONFIG_FILE";
}

create_systemd_service() {
    log_info "正在创建 systemd 服务..."; $SUDO tee "$SERVICE_FILE" > /dev/null << EOF
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
    log_info "重载 systemd 并启动服务..."; $SUDO systemctl daemon-reload; $SUDO systemctl enable "${SERVICE_NAME}"; $SUDO systemctl start "${SERVICE_NAME}"
    sleep 3; if $SUDO systemctl is-active --quiet "${SERVICE_NAME}"; then log_info "${SERVICE_NAME} 服务启动成功。"; else log_error "${SERVICE_NAME} 启动失败，请检查日志。"; fi
}

do_install_or_update() {
    if command_exists "${AGENT_BINARY_NAME}"; then log_info "检测到已安装 Agent，执行更新..."; is_update=true; else log_info "开始安装 Agent..."; is_update=false; fi
    install_dependencies; detect_arch; if [ -z "$AGENT_VERSION" ]; then get_latest_version; AGENT_VERSION=$LATEST_VERSION; fi
    if [ "$is_update" = true ]; then CURRENT_VERSION=$(${INSTALL_PATH}/${AGENT_BINARY_NAME} --version 2>/dev/null || echo "v0.0.0"); if [ "$CURRENT_VERSION" == "$AGENT_VERSION" ]; then log_info "已是最新版本。"; exit 0; fi; $SUDO systemctl stop "${SERVICE_NAME}" || true; fi
    download_and_install "$AGENT_VERSION"
    # [核心修正] 移除对 place_ca_certificate 的调用
    if [ "$is_update" = false ]; then create_config; create_systemd_service; fi
    if [ "$NO_START" = "true" ]; then log_info "安装完成，未启动服务。"; else start_and_enable_service; fi
}

do_uninstall() {
    log_info "开始卸载 Agent..."; $SUDO systemctl stop "${SERVICE_NAME}" || true; $SUDO systemctl disable "${SERVICE_NAME}" || true; $SUDO rm -f "$SERVICE_FILE"; $SUDO rm -f "${INSTALL_PATH}/${AGENT_BINARY_NAME}";
    if [ -d "$CONFIG_DIR" ]; then read -p "是否删除配置目录 ${CONFIG_DIR}? (y/N): " choice; if [[ "$choice" =~ ^[Yy]$ ]]; then $SUDO rm -rf "$CONFIG_DIR"; fi; fi
    # [已移除] 不再需要清理系统信任库中的证书
    $SUDO systemctl daemon-reload; log_info "卸载完成。";
}

# --- 主逻辑 ---
main() {
    init_sudo; COMMAND="install"; if [[ "$1" == "uninstall" || "$1" == "version" ]]; then COMMAND=$1; shift; fi
    # [核心修正] 移除对 --ca-cert 和 --ca-cert-path 参数的解析
    while [ "$#" -gt 0 ]; do case "$1" in --key) SECRET_KEY="$2"; shift 2;; --server) BACKEND_ADDRESS="$2"; shift 2;; --version) AGENT_VERSION="$2"; shift 2;; --no-start) NO_START="true"; shift 1;; --non-interactive) NON_INTERACTIVE="true"; shift 1;; -h|--help) usage;; *) log_error "未知参数: $1";; esac; done
    case "$COMMAND" in install) do_install_or_update;; uninstall) do_uninstall;; version) ${INSTALL_PATH}/${AGENT_BINARY_NAME} --version;; *) usage;; esac
}

main "$@"

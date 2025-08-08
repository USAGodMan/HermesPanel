#!/bin/bash

# ==============================================================================
# HermesPanel - 一键安装与管理脚本
#
# 功能:
#   - 自动检查并安装依赖 (Docker, Docker Compose, Git, Certbot)
#   - 引导用户配置域名和邮箱
#   - 自动申请 SSL 证书
#   - 启动并管理 HermesPanel 服务
# ==============================================================================

# --- 变量与常量 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

GITHUB_REPO_URL="https://github.com/USAGodMan/HermesPanel.git"
PROJECT_DIR="HermesPanel"

# --- 工具函数 ---
log_info() { echo -e "${GREEN}✅ [信息]${NC} $1"; }
log_warn() { echo -e "${YELLOW}⚠️ [警告]${NC} $1"; }
log_error() { echo -e "${RED}❌ [错误]${NC} $1"; exit 1; }
command_exists() { command -v "$1" >/dev/null 2&
; }

# --- 核心功能函数 ---

# 1. 欢迎与环境检查
function welcome_and_check() {
    echo -e "${BLUE}=======================================================${NC}"
    echo -e "${BLUE}      欢迎使用 HermesPanel 🚀 一键安装脚本         ${NC}"
    echo -e "${BLUE}=======================================================${NC}"
    
    if [ "$(id -u)" -ne 0 ]; then
        log_error "此脚本需要以 root 用户权限运行。请尝试使用 'sudo bash $0'。"
    fi

    if ! command_exists curl; then
        log_warn "curl 未安装，正在尝试安装..."
        apt-get update && apt-get install -y curl || yum install -y curl
    fi
}

# 2. 安装核心依赖
function install_dependencies() {
    log_info "正在检查并安装核心依赖..."
    
    # 安装 Docker
    if ! command_exists docker; then
        log_info "🐋 Docker 未安装，正在为您安装..."
        curl -fsSL https://get.docker.com -o get-docker.sh
        sh get-docker.sh
        rm get-docker.sh
        systemctl enable --now docker
    else
        log_info "🐋 Docker 已安装。"
    fi

    # 安装 Docker Compose
    if ! command_exists docker-compose; then
        log_info "🧩 Docker Compose 未安装，正在为您安装..."
        DOCKER_COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep -oP '"tag_name": "\K(.*)(?=")')
        curl -L "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
    else
        log_info "🧩 Docker Compose 已安装。"
    fi

    # 安装 Git 和 Certbot
    if command_exists apt-get; then
        apt-get update
        apt-get install -y git certbot
    elif command_exists yum; then
        yum install -y git certbot
    else
        log_warn "无法自动安装 git 和 certbot。请手动安装它们后重试。"
    fi
    log_info "✅ 所有核心依赖已准备就绪。"
}

# 3. 下载项目文件
function download_project() {
    if [ -d "$PROJECT_DIR" ]; then
        log_warn "项目目录 '$PROJECT_DIR' 已存在。将进入该目录并尝试更新。"
        cd "$PROJECT_DIR"
        git pull
    else
        log_info "📂 正在从 GitHub 克隆项目..."
        git clone "$GITHUB_REPO_URL"
        cd "$PROJECT_DIR"
    fi
}

# 4. 用户交互式配置
function configure_env() {
    log_info "📝 让我们来配置您的 HermesPanel 环境。"
    
    if [ -f ".env" ]; then
        echo -en "${YELLOW}检测到已存在的 .env 文件。是否要覆盖并重新配置？(y/N): ${NC}"
        read -r choice
        if [[ ! "$choice" =~ ^[Yy]$ ]]; then
            log_info "保留现有配置。如果您想修改，请手动编辑 .env 文件。"
            return
        fi
    fi

    cp .env.example .env

    echo -en "${BLUE}请输入您的主域名 (例如: hermes.example.com): ${NC}"
    read -r NGINX_HOST
    while [ -z "$NGINX_HOST" ]; do
        echo -en "${RED}域名不能为空，请重新输入: ${NC}"
        read -r NGINX_HOST
    done

    echo -en "${BLUE}请输入您的邮箱 (用于申请SSL证书): ${NC}"
    read -r EMAIL
    while [ -z "$EMAIL" ]; do
        echo -en "${RED}邮箱不能为空，请重新输入: ${NC}"
        read -r EMAIL
    done

    log_info "🔐 正在为您生成安全的数据库密码和密钥..."
    MYSQL_ROOT_PASSWORD=$(openssl rand -base64 32)
    MYSQL_PASSWORD=$(openssl rand -base64 32)
    JWT_SECRET_KEY=$(openssl rand -base64 32)
    AES_ENCRYPTION_KEY=$(openssl rand -base64 32)

    sed -i "s|NGINX_HOST=|NGINX_HOST=${NGINX_HOST}|" .env
    sed -i "s|JWT_SECRET_KEY=.*|JWT_SECRET_KEY=${JWT_SECRET_KEY}|" .env
    sed -i "s|AES_ENCRYPTION_KEY=.*|AES_ENCRYPTION_KEY=${AES_ENCRYPTION_KEY}|" .env
    sed -i "s|MYSQL_ROOT_PASSWORD=.*|MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}|" .env
    sed -i "s|MYSQL_PASSWORD=.*|MYSQL_PASSWORD=${MYSQL_PASSWORD}|" .env
    # 确保 DB_TYPE 正确
    sed -i "s/DB_TYPE=.*/DB_TYPE=mysql/" .env


    log_info "✅ .env 文件配置完成！"
    export NGINX_HOST
    export EMAIL
}

# 5. 申请 SSL 证书
function obtain_certificate() {
    log_info "📜 正在为 ${NGINX_HOST} 和 grpc.${NGINX_HOST} 申请 SSL 证书..."
    
    # 尝试停止可能占用80端口的服务
    systemctl stop nginx apache2 2>/dev/null
    
    certbot certonly --standalone \
        -d "${NGINX_HOST}" \
        -d "grpc.${NGINX_HOST}" \
        --email "${EMAIL}" \
        --agree-tos -n \
        --post-hook "echo '证书申请成功，服务将继续...'"
    
    if [ ! -f "/etc/letsencrypt/live/${NGINX_HOST}/fullchain.pem" ]; then
        log_error "证书申请失败。请检查您的域名是否正确解析到了本服务器的 IP 地址。"
    fi
    log_info "✅ SSL 证书已成功获取！"
}

# 6. 启动服务
function start_services() {
    log_info "🚀 正在构建并启动所有服务... (这可能需要几分钟)"
    
    docker-compose up -d --build
    
    if [ $? -eq 0 ]; then
        log_info "🎉 HermesPanel 已成功启动！"
        echo -e "${BLUE}=======================================================${NC}"
        echo -e "您现在可以通过浏览器访问: ${GREEN}https://${NGINX_HOST}${NC}"
        echo -e "初始管理员账户信息将在后台日志中打印，请稍后查看:"
        echo -e "${YELLOW}docker-compose logs backend${NC}"
        echo -e "${BLUE}=======================================================${NC}"
    else
        log_error "服务启动失败。请运行 'docker-compose logs' 查看详细错误信息。"
    fi
}

# --- 主逻辑 ---
function main() {
    welcome_and_check
    install_dependencies
    download_project
    configure_env
    obtain_certificate
    start_services
}

main

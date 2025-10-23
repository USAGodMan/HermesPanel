#!/bin/bash

# ==============================================================================
# HermesPanel - 一键安装与管理脚本
#
# 功能:
#   - 自动检查并安装依赖 (Docker, Docker Compose, Git, Certbot, OpenSSL)
#   - 引导用户配置域名和邮箱
#   - 自动申请 SSL 证书（仅当证书不存在时）
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
command_exists() { command -v "$1" >/dev/null 2>&1; }

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
        if command_exists apt-get; then
            apt-get update && apt-get install -y curl
        elif command_exists yum; then
            yum install -y curl
        else
            log_error "不支持的包管理器，无法安装 curl。"
        fi
    fi
}

# 2. 安装核心依赖
function install_dependencies() {
    log_info "正在检查并安装核心依赖..."
    
    # 安装 Docker
    if ! command_exists docker; then
        log_info "🐋 Docker 未安装，正在为您安装..."
        if curl -fsSL https://get.docker.com -o get-docker.sh; then
            sh get-docker.sh
            rm get-docker.sh
            # 等待 Docker 服务启动
            sleep 5
            if systemctl is-active --quiet docker; then
                systemctl enable --now docker
                log_info "🐋 Docker 安装并启动成功。"
            else
                log_error "Docker 安装失败。请手动检查日志: journalctl -u docker。"
            fi
        else
            log_error "无法下载 Docker 安装脚本。请检查网络连接。"
        fi
    else
        log_info "🐋 Docker 已安装。"
    fi

    # 安装 Docker Compose
    if ! command_exists docker-compose; then
        log_info "🧩 Docker Compose 未安装，正在为您安装..."
        # 增强版本获取：添加重试和 fallback
        DOCKER_COMPOSE_VERSION=""
        for attempt in {1..3}; do
            DOCKER_COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep -oP 'tag_name": "\K(.*)(?=")' 2>/dev/null || echo "v2.24.7")  # fallback 到稳定版
            if [[ "$DOCKER_COMPOSE_VERSION" =~ ^v[0-9] ]]; then
                break
            fi
            sleep 2
        done
        
        if curl -L "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose; then
            chmod +x /usr/local/bin/docker-compose
            if command_exists docker-compose; then
                log_info "🧩 Docker Compose 安装成功 (版本: $DOCKER_COMPOSE_VERSION)。"
            else
                log_error "Docker Compose 下载成功但未可执行。请检查权限。"
            fi
        else
            log_error "无法下载 Docker Compose。请检查网络或手动安装。"
        fi
    else
        log_info "🧩 Docker Compose 已安装。"
    fi

    # 安装 Git、Certbot 和 OpenSSL
    if command_exists apt-get; then
        apt-get update
        apt-get install -y git certbot openssl
    elif command_exists yum; then
        yum install -y git
        yum install -y epel-release  # Certbot 和 OpenSSL 依赖 EPEL
        yum install -y certbot openssl
    else
        log_warn "无法自动安装 git、certbot 和 openssl。请手动安装它们后重试。"
    fi
    log_info "✅ 所有核心依赖已准备就绪。"
}

# 3. 下载项目文件
function download_project() {
    if [ -d "$PROJECT_DIR" ]; then
        log_warn "项目目录 '$PROJECT_DIR' 已存在。将进入该目录并尝试更新。"
        cd "$PROJECT_DIR" || log_error "无法进入项目目录。"
        if command_exists git; then
            git pull
        else
            log_error "Git 未安装，无法更新项目。"
        fi
    else
        log_info "📂 正在从 GitHub 克隆项目..."
        if git clone "$GITHUB_REPO_URL" "$PROJECT_DIR"; then
            cd "$PROJECT_DIR" || log_error "克隆成功但无法进入目录。"
        else
            log_error "Git 克隆失败。请检查网络或 GitHub 访问。"
        fi
    fi
}

# 4. 用户交互式配置
function configure_env() {
    log_info "📝 让我们来配置您的 HermesPanel 环境。"
    
    choice=""
    if [ -f ".env" ]; then
        echo -en "${YELLOW}检测到已存在的 .env 文件。是否要覆盖并重新配置？(y/N): ${NC}"
        read -r choice
        if [[ ! "$choice" =~ ^[Yy]$ ]]; then
            log_info "保留现有配置。"
            # 从现有 .env 加载关键变量
            if source .env 2>/dev/null; then
                if [ -n "$NGINX_HOST" ] && [ -n "$EMAIL" ]; then
                    export NGINX_HOST
                    export EMAIL
                    log_info "从现有 .env 加载配置 (域名: $NGINX_HOST)。"
                else
                    log_warn "现有 .env 文件缺少 NGINX_HOST 或 EMAIL，请选择覆盖 (y) 或手动编辑。"
                    choice="y"
                fi
            else
                log_warn ".env 文件无效，请选择覆盖。"
                choice="y"
            fi
        fi
    fi

    if [[ "$choice" =~ ^[Yy]$ ]] || [ ! -f ".env" ]; then
        if [ ! -f ".env.example" ]; then
            log_error ".env.example 文件不存在。请确保项目已正确下载。"
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
        # 使用 OpenSSL 生成（匹配 Go 代码期望：精确 32/50 字符字符串）
        # AES: openssl rand -base64 24 生成正好 32 字符
        AES_ENCRYPTION_KEY=$(openssl rand -base64 24 | tr -d '\n')
        # JWT: openssl rand -base64 38 生成 52 字符，截取前 50
        JWT_SECRET_KEY=$(openssl rand -base64 38 | cut -c1-50 | tr -d '\n')
        # MySQL: 同 AES，32 字符
        MYSQL_ROOT_PASSWORD=$(openssl rand -base64 24 | tr -d '\n')
        MYSQL_PASSWORD=$(openssl rand -base64 24 | tr -d '\n')
        log_info "使用 OpenSSL 生成密钥。"

        sed -i "s|NGINX_HOST=|NGINX_HOST=${NGINX_HOST}|" .env
        sed -i "s|JWT_SECRET_KEY=.*|JWT_SECRET_KEY=${JWT_SECRET_KEY}|" .env
        sed -i "s|AES_ENCRYPTION_KEY=.*|AES_ENCRYPTION_KEY=${AES_ENCRYPTION_KEY}|" .env
        sed -i "s|MYSQL_ROOT_PASSWORD=.*|MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}|" .env
        sed -i "s|MYSQL_PASSWORD=.*|MYSQL_PASSWORD=${MYSQL_PASSWORD}|" .env
        # 确保 DB_TYPE 正确
        sed -i "s/DB_TYPE=.*/DB_TYPE=mysql/" .env
        # 确保数据库名和用户名正确（基于您的修改）
        sed -i "s|MYSQL_DATABASE=.*|MYSQL_DATABASE=hermes_db|" .env
        sed -i "s|MYSQL_USER=.*|MYSQL_USER=hermes_user|" .env

        log_info "✅ .env 文件配置完成！"
        export NGINX_HOST
        export EMAIL
    fi
}

# 5. 申请 SSL 证书（仅当不存在时）
function obtain_certificate() {
    if [ -z "$NGINX_HOST" ]; then
        log_error "NGINX_HOST 未设置。请先运行 configure_env。"
    fi
    
    CERT_PATH="/etc/letsencrypt/live/${NGINX_HOST}/fullchain.pem"
    if [ -f "$CERT_PATH" ]; then
        log_info "📜 SSL 证书已存在 (域名: ${NGINX_HOST})，跳过申请。"
        return
    fi
    
    log_info "📜 正在为 ${NGINX_HOST} 和 grpc.${NGINX_HOST} 申请 SSL 证书..."
    
    # 尝试停止可能占用80端口的服务
    systemctl stop nginx apache2 2>/dev/null
    
    # 检查端口是否空闲
    if command_exists netstat && netstat -tuln 2>/dev/null | grep -q ":80 "; then
        log_warn "80 端口仍被占用，请手动停止相关服务后重试。"
    fi
    
    certbot certonly --standalone \
        -d "${NGINX_HOST}" \
        -d "grpc.${NGINX_HOST}" \
        --email "${EMAIL}" \
        --agree-tos -n \
        --post-hook "echo '证书申请成功，服务将继续...'"
    
    if [ ! -f "$CERT_PATH" ]; then
        log_error "证书申请失败。请检查您的域名是否正确解析到了本服务器的 IP 地址，并确保 80 端口空闲。"
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
        echo -e "${BLUE}=======================================================${NC}"
        
        # 等待后端初始化完成
        log_info "⏳ 等待后端初始化... (约 15 秒)"
        sleep 15
        
        # 自动提取并显示初始管理员账户信息
        echo -e "${YELLOW}🔍 正在从后端日志提取初始管理员账户信息...${NC}"
        ADMIN_INFO=$(docker-compose logs --tail=100 backend 2>&1 | grep -iE "(admin|initial|default|账户|password|用户名|credential|login)" | tail -10)
        if [ -n "$ADMIN_INFO" ]; then
            echo -e "${GREEN}📋 初始管理员账户信息:${NC}"
            echo "$ADMIN_INFO"
        else
            log_warn "未找到明确的管理员账户信息。请运行 'docker-compose logs backend' 查看完整日志。"
        fi
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

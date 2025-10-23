#!/bin/bash
set -e

# 解决 macOS 下 tr 可能出现的非法字节序列问题
export LANG=en_US.UTF-8
export LC_ALL=C

# 全局下载地址配置（HermesPanel GitHub）
GITHUB_REPO_URL="https://github.com/USAGodMan/HermesPanel.git"

# 中国镜像（ghfast.top）
COUNTRY=$(curl -s --connect-timeout 5 https://ipinfo.io/country || echo "US")
if [ "$COUNTRY" = "CN" ]; then
    GITHUB_REPO_URL="https://ghfast.top/https://github.com/USAGodMan/HermesPanel.git"
fi

PROJECT_DIR="HermesPanel"

# 工具函数
log_info() { echo -e "\033[0;32m✅ [信息] $1\033[0m"; }
log_warn() { echo -e "\033[1;33m⚠️ [警告] $1\033[0m"; }
log_error() { echo -e "\033[0;31m❌ [错误] $1\033[0m"; exit 1; }
command_exists() { command -v "$1" >/dev/null 2>&1; }

# 检查 Docker
check_docker() {
    if command -v docker-compose >/dev/null 2>&1; then
        DOCKER_CMD="docker-compose"
    elif command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        DOCKER_CMD="docker compose"
    else
        log_error "未检测到 Docker。请先安装。"
    fi
    log_info "检测到 Docker 命令：$DOCKER_CMD"
}

# 检测 IPv6 支持
check_ipv6_support() {
    log_info "🔍 检测 IPv6 支持..."
    if ip -6 addr show | grep -v "scope link" | grep -q "inet6" 2>/dev/null || ifconfig 2>/dev/null | grep -v "fe80:" | grep -q "inet6"; then
        log_info "✅ 支持 IPv6"
        return 0
    else
        log_warn "⚠️ 未支持 IPv6"
        return 1
    fi
}

# 配置 Docker IPv6
configure_docker_ipv6() {
    log_info "🔧 配置 Docker IPv6..."
    OS_TYPE=$(uname -s)
    if [[ "$OS_TYPE" == "Darwin" ]]; then
        log_info "✅ macOS 默认支持 IPv6"
        return 0
    fi
    DOCKER_CONFIG="/etc/docker/daemon.json"
    SUDO_CMD=$( [ $EUID -ne 0 ] && echo "sudo" || echo "" )
    if [ -f "$DOCKER_CONFIG" ] && grep -q '"ipv6"' "$DOCKER_CONFIG"; then
        log_info "✅ 已配置 IPv6"
        return 0
    fi
    $SUDO_CMD mkdir -p /etc/docker
    if command -v jq >/dev/null 2>&1; then
        echo '{}' | jq '. + {"ipv6": true, "fixed-cidr-v6": "fd00::/80"}' | $SUDO_CMD tee "$DOCKER_CONFIG" >/dev/null
    else
        echo '{"ipv6": true, "fixed-cidr-v6": "fd00::/80"}' | $SUDO_CMD tee "$DOCKER_CONFIG" >/dev/null
    fi
    if command -v systemctl >/dev/null 2>&1; then
        $SUDO_CMD systemctl restart docker
    fi
    sleep 5
}

# 等待健康检查
wait_for_health() {
    local container=$1
    local timeout=$2
    local i=1
    while [ $i -le $timeout ]; do
        if docker ps --format "{{.Names}}" | grep -q "^$container$"; then
            HEALTH=$(docker inspect -f '{{.State.Health.Status}}' "$container" 2>/dev/null || echo "unknown")
            if [[ "$HEALTH" == "healthy" ]]; then
                log_info "$container 服务健康"
                return 0
            fi
        fi
        if [ $((i % 15)) -eq 1 ]; then
            log_warn "等待 $container ... ($i/$timeout) 状态：$HEALTH"
        fi
        sleep 1
        ((i++))
    done
    log_error "$container 启动超时 ($timeout s)"
}

# 获取 DB 配置
get_db_config() {
    if [ -f ".env" ]; then
        source .env
    fi
    DB_NAME=${MYSQL_DATABASE:-hermes_db}
    DB_USER=${MYSQL_USER:-hermes_user}
    DB_PASSWORD=${MYSQL_PASSWORD}
    DB_HOST=${MYSQL_HOST:-mysql}
    DB_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}
    if [[ -z "$DB_PASSWORD" || -z "$DB_USER" || -z "$DB_NAME" ]]; then
        log_error "DB 配置不完整"
    fi
}

# 生成随机密钥
generate_random() { LC_ALL=C tr -dc 'A-Za-z0-9!@#$%^&*()_+-=[]{}|;:,.<>?`~' </dev/urandom | head -c $1; }

# 显示菜单
show_menu() {
    echo -e "\n\033[0;34m=======================================================${NC}"
    echo -e "\033[0;34m      HermesPanel 🚀 交互式管理脚本                 ${NC}"
    echo -e "\033[0;34m=======================================================${NC}"
    echo "1. 安装面板"
    echo "2. 更新面板"
    echo "3. 卸载面板"
    echo "4. 导出数据库备份"
    echo "5. 配置 SSL 证书"
    echo "6. 退出"
    echo -e "\033[0;34m=======================================================${NC}"
}

# 删除脚本自身
delete_self() {
    log_info "🗑️ 清理脚本文件..."
    SCRIPT_PATH=$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")
    sleep 1
    rm -f "$SCRIPT_PATH" && log_info "✅ 脚本已删除" || log_warn "⚠️ 删除失败"
}

# 安装
install_panel() {
    log_info "🚀 开始安装..."
    check_docker
    if check_ipv6_support; then configure_docker_ipv6; fi

    # 交互配置
    read -p "主域名 (默认: panel.example.com): " NGINX_HOST
    NGINX_HOST=${NGINX_HOST:-panel.example.com}
    read -p "邮箱 (SSL 用，默认: admin@example.com): " EMAIL
    EMAIL=${EMAIL:-admin@example.com}
    read -p "HTTP 端口 (默认: 8080): " HTTP_PORT
    HTTP_PORT=${HTTP_PORT:-8080}
    read -p "gRPC 端口 (默认: 50051): " GRPC_PORT
    GRPC_PORT=${GRPC_PORT:-50051}

    # 生成密钥
    JWT_SECRET_KEY=$(generate_random 50)
    AES_ENCRYPTION_KEY=$(generate_random 32)
    MYSQL_ROOT_PASSWORD=$(generate_random 32)
    MYSQL_PASSWORD=$(generate_random 32)

    # 下载项目
    if [ -d "$PROJECT_DIR" ]; then
        cd "$PROJECT_DIR" && git pull || log_error "更新失败"
    else
        git clone "$GITHUB_REPO_URL" "$PROJECT_DIR" || log_error "克隆失败"
        cd "$PROJECT_DIR"
    fi

    # 配置 .env
    cp .env.example .env
    sed -i "s|NGINX_HOST=.*|NGINX_HOST=$NGINX_HOST|" .env
    sed -i "s|EMAIL=.*|EMAIL=$EMAIL|" .env  # 假设 .env 有 EMAIL
    sed -i "s|HTTP_PORT=.*|HTTP_PORT=$HTTP_PORT|" .env
    sed -i "s|GRPC_PORT=.*|GRPC_PORT=$GRPC_PORT|" .env
    sed -i "s|JWT_SECRET_KEY=.*|JWT_SECRET_KEY=$JWT_SECRET_KEY|" .env
    sed -i "s|AES_ENCRYPTION_KEY=.*|AES_ENCRYPTION_KEY=$AES_ENCRYPTION_KEY|" .env
    sed -i "s|MYSQL_ROOT_PASSWORD=.*|MYSQL_ROOT_PASSWORD=$MYSQL_ROOT_PASSWORD|" .env
    sed -i "s|MYSQL_PASSWORD=.*|MYSQL_PASSWORD=$MYSQL_PASSWORD|" .env
    sed -i "s|DB_TYPE=.*|DB_TYPE=mysql|" .env
    sed -i "s|MYSQL_DATABASE=.*|MYSQL_DATABASE=hermes_db|" .env
    sed -i "s|MYSQL_USER=.*|MYSQL_USER=hermes_user|" .env

    # 启动
    $DOCKER_CMD up -d --build
    wait_for_health backend 90
    wait_for_health mysql 60  # 假设容器名为 mysql

    # SSL
    obtain_certificate

    # 显示 admin
    sleep 15
    ADMIN_INFO=$( $DOCKER_CMD logs --tail=100 backend | grep -iE "(admin|initial|default|账户|password|用户名|credential|login)" | tail -10 )
    echo -e "\n${GREEN}🎉 安装完成！访问: https://${NGINX_HOST}${NC}"
    if [ -n "$ADMIN_INFO" ]; then
        echo -e "${YELLOW}📋 初始管理员账户:${NC}"
        echo "$ADMIN_INFO"
    else
        log_warn "未找到账户信息，请运行 '$DOCKER_CMD logs backend'"
    fi
}

# 更新
update_panel() {
    log_info "🔄 开始更新..."
    check_docker
    if [ ! -d "$PROJECT_DIR" ]; then log_error "项目未安装"; fi
    cd "$PROJECT_DIR"
    git pull || log_error "Git pull 失败"
    $DOCKER_CMD down
    $DOCKER_CMD pull
    $DOCKER_CMD up -d --build
    wait_for_health backend 90
    wait_for_health mysql 60
    log_info "✅ 更新完成"
}

# 卸载
uninstall_panel() {
    read -p "确认卸载？删除所有数据 (y/N): " confirm
    if [[ $confirm =~ ^[Yy]$ ]]; then
        cd "$PROJECT_DIR" 2>/dev/null || true
        $DOCKER_CMD down --rmi all -v --remove-orphans
        cd .. && rm -rf "$PROJECT_DIR"
        log_info "✅ 卸载完成"
    fi
}

# 备份
export_backup() {
    log_info "📄 导出备份..."
    get_db_config
    cd "$PROJECT_DIR"
    SQL_FILE="hermes_backup_$(date +%Y%m%d_%H%M%S).sql"
    if docker exec -i mysql mysqldump -u "$DB_USER" -p"$DB_PASSWORD" --single-transaction --routines --triggers "$DB_NAME" > "../$SQL_FILE"; then
        log_info "✅ 备份: ../$SQL_FILE ($(du -h "../$SQL_FILE" | cut -f1))"
    else
        log_error "备份失败"
    fi
    # 备份 .env
    cp .env "../hermes_env_$(date +%Y%m%d_%H%M%S).backup"
    log_info "✅ .env 已备份"
}

# SSL 配置
obtain_certificate() {
    get_db_config  # 仅需 NGINX_HOST/EMAIL，从 .env source
    CERT_PATH="/etc/letsencrypt/live/${NGINX_HOST}/fullchain.pem"
    if [ -f "$CERT_PATH" ]; then
        log_info "✅ SSL 已存在"
        return
    fi
    systemctl stop nginx apache2 2>/dev/null
    if command -v certbot >/dev/null 2>&1; then
        certbot certonly --standalone -d "${NGINX_HOST}" -d "grpc.${NGINX_HOST}" --email "$EMAIL" --agree-tos -n
        if [ -f "$CERT_PATH" ]; then
            log_info "✅ SSL 获取成功"
            $DOCKER_CMD restart  # 重启以加载证书
        else
            log_error "SSL 失败"
        fi
    else
        log_error "Certbot 未安装"
    fi
}

# 主逻辑
main() {
    while true; do
        show_menu
        read -p "选项 (1-6): " choice
        case $choice in
            1) install_panel ;;
            2) update_panel ;;
            3) uninstall_panel ;;
            4) export_backup ;;
            5) obtain_certificate ;;
            6) delete_self; exit 0 ;;
            *) log_warn "无效选项" ;;
        esac
    done
}

main

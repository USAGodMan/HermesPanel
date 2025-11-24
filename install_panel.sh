#!/bin/bash
set -e

# ==============================================================================
# 🚀 HermesPanel 一键安装与管理脚本 [旗舰版 v2.1]
#
# 修复日志:
# - [修复] 修复了在更新/备份模式下 DOCKER_CMD 变量未初始化的问题
# - [优化] 将 Docker 检测逻辑提前，确保全流程可用
# ==============================================================================

# --- 全局变量 ---
PROJECT_DIR="/opt/HermesPanel"
GITHUB_REPO_URL="https://github.com/USAGodMan/HermesPanel.git"
ENV_FILE="${PROJECT_DIR}/.env"

# 颜色定义
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# 全局 Docker 命令变量 (初始化为空)
DOCKER_CMD=""

# --- 基础工具函数 ---
log_info() { echo -e "${GREEN}[INFO]${NC} ✨ $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} ⚠️ $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} ❌ $1"; exit 1; }
command_exists() { command -v "$1" >/dev/null 2>&1; }

# --- 核心检查 ---

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "此脚本需要 root 权限运行。"
    fi
}

check_dependencies() {
    local deps="curl git grep sed awk openssl"
    local missing=""
    for dep in $deps; do
        if ! command_exists "$dep"; then missing="$missing $dep"; fi
    done
    
    if [ -n "$missing" ]; then
        log_warn "缺少依赖: $missing，尝试自动安装..."
        if command_exists apt-get; then
            apt-get update && apt-get install -y $missing
        elif command_exists yum; then
            yum install -y $missing
        else
            log_error "请手动安装依赖: $missing"
        fi
    fi
}

# 【核心修复】不仅检测，还负责初始化 DOCKER_CMD 变量
ensure_docker_ready() {
    # 如果变量已有值，直接返回，避免重复检测
    if [ -n "$DOCKER_CMD" ]; then return; fi

    # 1. 检测 Docker 引擎
    if ! command_exists docker; then
        log_info "正在安装 Docker..."
        curl -fsSL https://get.docker.com | bash
        systemctl enable docker
        systemctl start docker
    fi

    # 2. 检测 Docker Compose 并赋值变量
    if docker compose version >/dev/null 2>&1; then
        DOCKER_CMD="docker compose"
    elif command_exists docker-compose; then
        DOCKER_CMD="docker-compose"
    else
        log_info "正在安装 Docker Compose..."
        curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
        DOCKER_CMD="docker-compose"
    fi
    
    # log_info "Docker 环境就绪: $DOCKER_CMD"
}

check_ipv6_support() {
    if [ -f /proc/net/if_inet6 ]; then
        # 检查 Docker daemon.json 是否开启 IPv6
        if [ ! -f /etc/docker/daemon.json ]; then
            log_info "检测到 IPv6 环境，正在配置 Docker 支持..."
            # 确保目录存在
            mkdir -p /etc/docker
            echo '{"ipv6": true, "fixed-cidr-v6": "fd00::/80"}' > /etc/docker/daemon.json
            systemctl reload docker
        fi
    fi
}

# --- 业务逻辑 ---

generate_password() {
    openssl rand -base64 24 | tr -d '/+=' | head -c "$1"
}

# 安全写入 .env
write_env() {
    local key=$1
    local val=$2
    if grep -q "^${key}=" "$ENV_FILE"; then
        sed -i "s|^${key}=.*|${key}=${val}|" "$ENV_FILE"
    else
        echo "${key}=${val}" >> "$ENV_FILE"
    fi
}

install_panel() {
    log_info "🚀 开始安装 HermesPanel..."
    check_root
    check_dependencies
    ensure_docker_ready # 确保 Docker 可用
    check_ipv6_support

    # 1. 交互式配置
    echo ""
    echo -e "${BLUE}--- 配置向导 ---${NC}"
    read -p "请输入面板域名 (例如 panel.example.com): " NGINX_HOST
    [ -z "$NGINX_HOST" ] && log_error "域名不能为空"
    
    read -p "请输入管理员邮箱 (用于 SSL 申请): " EMAIL
    [ -z "$EMAIL" ] && EMAIL="admin@localhost"

    read -p "HTTP 端口 (默认 8080): " HTTP_PORT
    [ -z "$HTTP_PORT" ] && HTTP_PORT=8080

    read -p "gRPC 端口 (默认 50051): " GRPC_PORT
    [ -z "$GRPC_PORT" ] && GRPC_PORT=50051

    # 2. 下载代码
    if [ -d "$PROJECT_DIR" ]; then
        log_warn "目录 $PROJECT_DIR 已存在，正在更新代码..."
        cd "$PROJECT_DIR"
        git pull
    else
        git clone "$GITHUB_REPO_URL" "$PROJECT_DIR"
        cd "$PROJECT_DIR"
    fi

    # 3. 生成配置
    if [ ! -f "$ENV_FILE" ]; then
        cp .env.example "$ENV_FILE" 2>/dev/null || touch "$ENV_FILE"
    fi

    # 生成随机密钥
    JWT_SECRET=$(generate_password 32)
    AES_KEY=$(generate_password 32)
    DB_ROOT_PWD=$(generate_password 24)
    DB_PWD=$(generate_password 24)

    # 写入配置
    log_info "📝 生成配置文件..."
    write_env "NGINX_HOST" "$NGINX_HOST"
    write_env "EMAIL" "$EMAIL"
    write_env "HTTP_PORT" "$HTTP_PORT"
    write_env "GRPC_PORT" "$GRPC_PORT"
    write_env "JWT_SECRET_KEY" "$JWT_SECRET"
    write_env "AES_ENCRYPTION_KEY" "$AES_KEY"
    write_env "MYSQL_ROOT_PASSWORD" "$DB_ROOT_PWD"
    write_env "MYSQL_PASSWORD" "$DB_PWD"
    write_env "MYSQL_DATABASE" "hermes_db"
    write_env "MYSQL_USER" "hermes_user"

    # 4. 启动服务
    log_info "🐳 启动 Docker 容器..."
    $DOCKER_CMD up -d --build --remove-orphans

    # 5. SSL 申请 (尝试)
    log_info "🔒 正在尝试申请 SSL 证书..."
    if command_exists certbot; then
        $DOCKER_CMD stop nginx 2>/dev/null || true
        if certbot certonly --standalone -d "$NGINX_HOST" -d "grpc.$NGINX_HOST" --email "$EMAIL" --agree-tos --non-interactive; then
            log_info "✅ SSL 证书获取成功！"
        else
            log_warn "SSL 申请失败。请检查域名解析是否正确，或防火墙是否开放 80 端口。"
        fi
        $DOCKER_CMD start nginx 2>/dev/null || true
    else
        log_warn "未检测到 Certbot，跳过自动 SSL 申请。"
    fi

    # 6. 完成提示
    log_info "🎉 安装完成！"
    echo -e "   🏠 面板地址: http://${NGINX_HOST}:${HTTP_PORT}"
    echo -e "   🔑 初始账号信息请查看后台日志: $DOCKER_CMD logs backend"
}

update_panel() {
    if [ ! -d "$PROJECT_DIR" ]; then log_error "未找到安装目录，无法更新。"; fi
    
    ensure_docker_ready # 【修复】更新前确保拿到 Docker 命令
    
    cd "$PROJECT_DIR"
    log_info "🔄 拉取最新代码..."
    git pull
    
    log_info "🐳 重建容器..."
    $DOCKER_CMD down
    $DOCKER_CMD pull
    $DOCKER_CMD up -d --build --remove-orphans
    $DOCKER_CMD image prune -f
    
    log_info "✅ 更新完毕。"
}

uninstall_panel() {
    echo -e "${RED}⚠️  警告: 此操作将删除所有数据，包括数据库！${NC}"
    read -p "确认卸载? (输入 'yes' 确认): " confirm
    if [ "$confirm" != "yes" ]; then exit 0; fi

    if [ -d "$PROJECT_DIR" ]; then
        cd "$PROJECT_DIR"
        ensure_docker_ready # 【修复】卸载前也要确保拿到命令
        $DOCKER_CMD down -v 2>/dev/null || true
        cd ..
        rm -rf "$PROJECT_DIR"
        log_info "✅ 卸载完成。"
    else
        log_error "未找到安装目录。"
    fi
}

backup_data() {
    if [ ! -d "$PROJECT_DIR" ]; then log_error "未安装。"; fi
    
    ensure_docker_ready # 【修复】备份前确保拿到命令
    
    cd "$PROJECT_DIR"
    source "$ENV_FILE"
    BACKUP_FILE="../hermes_backup_$(date +%Y%m%d_%H%M%S).sql"
    
    # 智能查找 MySQL 容器名
    CONTAINER_NAME=$($DOCKER_CMD ps -q --filter "name=mysql" | head -n 1)
    if [ -z "$CONTAINER_NAME" ]; then
        CONTAINER_NAME=$(docker ps --format '{{.Names}}' | grep -i "mysql" | head -n 1)
    fi

    if [ -z "$CONTAINER_NAME" ]; then log_error "未找到运行中的 MySQL 容器。"; fi

    log_info "📦 正在导出数据库从容器: $CONTAINER_NAME ..."
    docker exec "$CONTAINER_NAME" mysqldump -u root -p"$MYSQL_ROOT_PASSWORD" --all-databases > "$BACKUP_FILE"
    
    if [ $? -eq 0 ]; then
        log_info "✅ 备份成功: $BACKUP_FILE"
    else
        log_error "备份失败，请检查容器日志。"
    fi
}

show_menu() {
    clear
    echo -e "${BLUE}"
    echo "  _   _                                ____                  _ "
    echo " | | | | ___ _ __ _ __ ___   ___  ___ |  _ \ __ _ _ __   ___| |"
    echo " | |_| |/ _ \ '__| '_ \` _ \ / _ \/ __|| |_) / _\` | '_ \ / _ \ |"
    echo " |  _  |  __/ |  | | | | | |  __/\__ \|  __/ (_| | | | |  __/ |"
    echo " |_| |_|\___|_|  |_| |_| |_|\___||___/|_|   \__,_|_| |_|\___|_|"
    echo -e "${NC}"
    echo -e "  HermesPanel 管理脚本 ${YELLOW}[v2.1]${NC}"
    echo "----------------------------------------"
    echo " 1. 安装面板"
    echo " 2. 更新面板"
    echo " 3. 卸载面板"
    echo " 4. 备份数据库"
    echo " 5. 查看日志"
    echo " 0. 退出"
    echo "----------------------------------------"
    read -p "请输入选项: " choice
    case $choice in
        1) install_panel ;;
        2) update_panel ;;
        3) uninstall_panel ;;
        4) backup_data ;;
        5) 
           ensure_docker_ready # 【修复】看日志也要命令
           cd "$PROJECT_DIR"
           $DOCKER_CMD logs -f --tail 100 backend 
           ;;
        0) exit 0 ;;
        *) log_warn "无效选项" ;;
    esac
}

# --- 入口 ---
main() {
    check_root
    # CLI 模式
    if [ "$1" == "install" ]; then install_panel; exit 0; fi
    if [ "$1" == "update" ]; then update_panel; exit 0; fi
    
    # 菜单模式
    while true; do
        show_menu
        read -p "按回车键继续..."
    done
}

main "$@"

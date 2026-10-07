#!/bin/bash

# ==============================================================================
# 重启备份容器脚本
# ==============================================================================

if [ -z "$BASH_VERSION" ]; then
    echo "⚠️  切换到 Bash..."
    exec bash "$0" "$@"
fi

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# 加载环境变量
if [ ! -f .env ]; then
    log_error ".env 文件不存在"
    exit 1
fi
set -a
source .env
set +a

# 变量检查
: ${PROJECT_NAME:?"PROJECT_NAME 未设置"}

CONTAINER_DB="db_${PROJECT_NAME}"
CONTAINER_TUNNEL="tunnel_${PROJECT_NAME}"

echo ""
echo "========================================================"
echo "    重启备份容器"
echo "========================================================"
echo "项目:      $PROJECT_NAME"
echo "数据库:    $CONTAINER_DB"
echo "隧道:      $CONTAINER_TUNNEL"
echo "========================================================"

# 检测 docker compose 命令
if docker compose version &>/dev/null; then
    COMPOSE_CMD="docker compose"
elif docker-compose version &>/dev/null; then
    COMPOSE_CMD="docker-compose"
else
    log_error "未找到 docker compose 或 docker-compose 命令"
    exit 1
fi

log_info "使用命令: $COMPOSE_CMD"

# 步骤1: 优雅停止 Slave（保护 relay log 状态）
log_info "[1/4] 正在优雅停止 Slave..."
if docker ps --filter "name=${CONTAINER_DB}" --format "{{.Names}}" 2>/dev/null | grep -q "${CONTAINER_DB}"; then
    # 先停止 IO 线程，等待 SQL 线程应用完当前 relay log
    docker exec -e MYSQL_PWD="${MYSQL_ROOT_PASSWORD}" "$CONTAINER_DB" \
        mysql -u root -e "STOP SLAVE IO_THREAD;" 2>/dev/null || true

    # 等待 SQL 线程应用完剩余的 relay log
    sleep 2

    # 然后停止 SQL 线程
    docker exec -e MYSQL_PWD="${MYSQL_ROOT_PASSWORD}" "$CONTAINER_DB" \
        mysql -u root -e "STOP SLAVE SQL_THREAD;" 2>/dev/null || true

    # 最后完全停止 slave
    docker exec -e MYSQL_PWD="${MYSQL_ROOT_PASSWORD}" "$CONTAINER_DB" \
        mysql -u root -e "STOP SLAVE;" 2>/dev/null || true

    log_info "      Slave 已优雅停止"
else
    log_warn "      数据库容器未运行，跳过停止 Slave"
fi

# 步骤2: 停止容器
log_info "[2/4] 正在停止容器..."
if $COMPOSE_CMD down 2>/dev/null; then
    log_info "      容器已停止"
else
    log_warn "      停止时出现警告（可能容器未运行）"
fi

# 步骤3: 启动容器
log_info "[3/4] 正在启动容器..."
if $COMPOSE_CMD up -d; then
    log_info "      容器已启动"
else
    log_error "容器启动失败"
    exit 1
fi

# 步骤4: 健康检查
log_info "[4/4] 正在检查容器状态..."
sleep 3

# 检查 tunnel 容器
TUNNEL_STATUS=$(docker ps --filter "name=${CONTAINER_TUNNEL}" --format "{{.Status}}" 2>/dev/null)
if [ -n "$TUNNEL_STATUS" ]; then
    log_info "      隧道容器: $TUNNEL_STATUS"
else
    log_warn "      隧道容器: 未运行"
fi

# 检查 db 容器
DB_STATUS=$(docker ps --filter "name=${CONTAINER_DB}" --format "{{.Status}}" 2>/dev/null)
if [ -n "$DB_STATUS" ]; then
    log_info "      数据库容器: $DB_STATUS"
else
    log_error "      数据库容器: 未运行"
    exit 1
fi

echo ""
echo "========================================================"
docker ps --filter "name=${PROJECT_NAME}" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
echo "========================================================"

log_info "🎉 重启完成！"

#!/bin/bash

# ==============================================================================
# 启动 pgAdmin 容器脚本
# ==============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

if [ ! -f .env ]; then
    log_error ".env 文件不存在"
    exit 1
fi
set -a
source .env
set +a

: ${PROJECT_NAME:?"PROJECT_NAME 未设置"}

PMA_CONTAINER="pma_${PROJECT_NAME}"

echo ""
echo "========================================================"
echo "    启动 pgAdmin 容器"
echo "========================================================"
echo "项目:      $PROJECT_NAME"
echo "容器:      $PMA_CONTAINER"
echo "端口:      ${PMA_WEB_PORT:-8080}"
echo "========================================================"

if docker compose version &>/dev/null; then
    COMPOSE_CMD="docker compose"
elif docker-compose version &>/dev/null; then
    COMPOSE_CMD="docker-compose"
else
    log_error "未找到 docker compose 或 docker-compose 命令"
    exit 1
fi

log_info "使用命令: $COMPOSE_CMD"

CURRENT_STATUS=$(docker ps -a --filter "name=${PMA_CONTAINER}" --format "{{.Status}}" 2>/dev/null)

if echo "$CURRENT_STATUS" | grep -q "Up"; then
    log_info "✅ pgAdmin 容器已在运行中: $CURRENT_STATUS"
    echo ""
    log_info "🎉 访问地址: http://服务器IP:${PMA_WEB_PORT:-8080}"
    exit 0
elif [ -n "$CURRENT_STATUS" ]; then
    log_info "容器已存在但未运行，正在启动..."
fi

log_info "正在启动 pgAdmin 容器..."
if $COMPOSE_CMD up -d pma 2>&1; then
    log_info "等待容器就绪..."
    sleep 3

    STATUS=$(docker ps --filter "name=${PMA_CONTAINER}" --format "{{.Status}}" 2>/dev/null)
    if [ -n "$STATUS" ]; then
        log_info "✅ pgAdmin 容器已启动: $STATUS"
        echo ""
        log_info "🎉 启动完成！"
        log_info "访问地址: http://服务器IP:${PMA_WEB_PORT:-8080}"
        log_info "默认账号: admin@burncloud.com"
        log_info "默认密码: 见 .env 中 POSTGRES_PASSWORD"
    else
        log_warn "容器可能仍在启动中，请稍后检查"
    fi
else
    log_error "pgAdmin 容器启动失败"
    log_info "请检查 docker-compose.yml 中是否定义了 pma 服务"
    exit 1
fi

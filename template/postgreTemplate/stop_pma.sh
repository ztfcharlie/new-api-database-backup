#!/bin/bash

# ==============================================================================
# 停止 pgAdmin 容器脚本
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
echo "    停止 pgAdmin 容器"
echo "========================================================"
echo "项目:      $PROJECT_NAME"
echo "容器:      $PMA_CONTAINER"
echo "========================================================"

CONTAINER_EXISTS=$(docker ps -a --filter "name=${PMA_CONTAINER}" --format "{{.Names}}" 2>/dev/null)

if [ -z "$CONTAINER_EXISTS" ]; then
    log_warn "容器不存在，无需停止"
    exit 0
fi

IS_RUNNING=$(docker ps --filter "name=${PMA_CONTAINER}" --format "{{.Names}}" 2>/dev/null)

if [ -z "$IS_RUNNING" ]; then
    log_info "容器已处于停止状态"
    exit 0
fi

if docker compose version &>/dev/null; then
    COMPOSE_CMD="docker compose"
elif docker-compose version &>/dev/null; then
    COMPOSE_CMD="docker-compose"
else
    log_info "使用 docker stop 停止容器..."
    if docker stop "$PMA_CONTAINER" 2>/dev/null; then
        log_info "✅ pgAdmin 容器已停止"
    else
        log_error "停止容器失败"
        exit 1
    fi
    exit 0
fi

log_info "使用命令: $COMPOSE_CMD"

log_info "正在停止 pgAdmin 容器..."
if $COMPOSE_CMD stop pma 2>/dev/null; then
    log_info "✅ pgAdmin 容器已停止"
else
    log_warn "compose stop 失败，尝试 docker stop..."
    if docker stop "$PMA_CONTAINER" 2>/dev/null; then
        log_info "✅ pgAdmin 容器已停止"
    else
        log_error "停止容器失败"
        exit 1
    fi
fi

echo ""
log_info "🎉 停止完成！"


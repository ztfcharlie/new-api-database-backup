#!/bin/bash

# ==============================================================================
# 停止备份容器脚本
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

echo ""
echo "========================================================"
echo "    停止备份容器"
echo "========================================================"
echo "项目:      $PROJECT_NAME"
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

# 停止并移除容器
log_info "正在停止并移除容器..."
if $COMPOSE_CMD down; then
    log_info "✅ 容器已停止并移除"
else
    log_error "容器停止失败"
    exit 1
fi

echo ""
log_info "🎉 停止完成！"

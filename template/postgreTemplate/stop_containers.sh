#!/bin/bash

# ==============================================================================
# 停止备份容器脚本 (PostgreSQL)
# ==============================================================================

if [ -z "$BASH_VERSION" ]; then
    echo "⚠️  切换到 Bash..."
    exec bash "$0" "$@"
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ========================================
# 参数解析
# ========================================
REMOVE_VOLUMES=false
for arg in "$@"; do
    case "$arg" in
        --rm-data)
            REMOVE_VOLUMES=true
            ;;
        *)
            log_warn "未知参数: $arg（已忽略）"
            ;;
    esac
done

if [ ! -f .env ]; then
    log_error ".env 文件不存在"
    exit 1
fi
set -a
source .env
set +a

: ${PROJECT_NAME:?"PROJECT_NAME 未设置"}

echo ""
echo "========================================================"
echo "    停止备份容器 (PostgreSQL)"
echo "========================================================"
echo "项目:      $PROJECT_NAME"
echo "移除数据:  $REMOVE_VOLUMES"
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

# ========================================
# 停止并移除容器
# ========================================
log_info "正在停止并移除容器..."

if [ "$REMOVE_VOLUMES" = true ]; then
    log_warn "  --rm-data：将同时移除数据卷（pg-data 和 dump-cache）"
    if $COMPOSE_CMD down -v; then
        log_info "✅ 容器和数据卷已移除"
        # 额外清理宿主机目录
        rm -rf pg-data dump-cache
        log_info "  宿主机目录 pg-data/ 和 dump-cache/ 已清理"
    else
        log_error "容器停止失败"
        exit 1
    fi
else
    if $COMPOSE_CMD down; then
        log_info "✅ 容器已停止并移除（数据卷保留）"
    else
        log_error "容器停止失败"
        exit 1
    fi
fi

# ========================================
# 检查残留容器
# ========================================
sleep 2
REMAINING=$(docker ps -a --filter "name=${PROJECT_NAME}" --format "{{.Names}}" | tr '\n' ' ')
if [ -n "$REMAINING" ]; then
    log_warn "发现残留容器: $REMAINING"
    log_warn "如需强制清理: docker rm -f $REMAINING"
else
    log_info "无残留容器"
fi

echo ""
log_info "🎉 停止完成！"


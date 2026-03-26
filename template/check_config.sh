#!/bin/bash

# ==============================================================================
# 配置验证脚本 - 检查 .env 配置是否正确
# ==============================================================================

if [ -z "$BASH_VERSION" ]; then
    exec bash "$0" "$@"
fi

echo "========================================================"
echo "🔍 MySQL 备份配置验证"
echo "========================================================"

# 加载 .env
if [ -f .env ]; then
  set -a
  source .env
  set +a
else
  echo "❌ 错误: 未找到 .env 文件"
  exit 1
fi

ERRORS=0
WARNINGS=0

# 检查必填项
echo ""
echo "📋 检查必填配置..."

check_required() {
    local var_name=$1
    local var_value=${!var_name}
    if [ -z "$var_value" ]; then
        echo "  ❌ $var_name: 未设置"
        ERRORS=$((ERRORS + 1))
    else
        echo "  ✅ $var_name: $var_value"
    fi
}

check_required "PROJECT_NAME"
check_required "SSH_HOST"
check_required "REMOTE_DB_PORT"
check_required "TARGET_DB_NAME"
check_required "MASTER_PASSWORD"
check_required "MYSQL_ROOT_PASSWORD"

# 检查 SERVER_ID
echo ""
echo "🔢 检查 Server ID..."
SERVER_ID="${SERVER_ID:-100}"
echo "  SERVER_ID: $SERVER_ID"

if [ "$SERVER_ID" = "1" ]; then
    echo "  ❌ 错误: SERVER_ID=1 是 Master 的 ID，Slave 不能使用!"
    ERRORS=$((ERRORS + 1))
elif [ "$SERVER_ID" -lt 2 ] || [ "$SERVER_ID" -gt 4294967295 ]; then
    echo "  ❌ 错误: SERVER_ID 必须在 2-4294967295 之间"
    ERRORS=$((ERRORS + 1))
else
    echo "  ✅ SERVER_ID 格式正确"
fi

# 检查端口配置
echo ""
echo "🔌 检查端口配置..."
echo "  PMA_WEB_PORT: ${PMA_WEB_PORT:-8888}"
echo "  NEW_API_PORT: ${NEW_API_PORT:-3000}"

# 检查 SSH 配置
echo ""
echo "🔑 检查 SSH 配置..."
echo "  SSH_HOST: ${SSH_HOST}"
echo "  SSH_PORT: ${SSH_PORT:-22}"
echo "  SSH_USER: ${SSH_USER:-root}"

if [ -n "$SSH_PASSWORD" ]; then
    echo "  认证方式: 密码"
elif [ -f "../id_rsa/id_rsa_backup" ]; then
    echo "  认证方式: 密钥 (../id_rsa/id_rsa_backup)"
else
    echo "  ⚠️  警告: 未配置 SSH_PASSWORD 且找不到密钥文件"
    WARNINGS=$((WARNINGS + 1))
fi

# 检查容器状态
echo ""
echo "🐳 检查容器状态..."
CONTAINER_DB="backup_${PROJECT_NAME}"
CONTAINER_TUNNEL="tunnel_${PROJECT_NAME}"

if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_DB}$"; then
    echo "  ✅ 数据库容器运行中: $CONTAINER_DB"

    # 获取实际运行的 server-id
    ACTUAL_SERVER_ID=$(docker exec -e MYSQL_PWD="${MYSQL_ROOT_PASSWORD}" "$CONTAINER_DB" mysql -u root -N -e "SELECT @@server_id;" 2>/dev/null)
    if [ -n "$ACTUAL_SERVER_ID" ]; then
        echo "     实际 server-id: $ACTUAL_SERVER_ID"
        if [ "$ACTUAL_SERVER_ID" != "$SERVER_ID" ]; then
            echo "     ⚠️  警告: 配置 SERVER_ID ($SERVER_ID) 与实际运行值 ($ACTUAL_SERVER_ID) 不同"
            echo "        可能需要重启容器: docker-compose restart"
            WARNINGS=$((WARNINGS + 1))
        fi
    fi
else
    echo "  ⚠️  数据库容器未运行: $CONTAINER_DB"
    echo "     请先执行: docker-compose up -d"
    WARNINGS=$((WARNINGS + 1))
fi

if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_TUNNEL}$"; then
    echo "  ✅ 隧道容器运行中: $CONTAINER_TUNNEL"
else
    echo "  ⚠️  隧道容器未运行: $CONTAINER_TUNNEL"
    WARNINGS=$((WARNINGS + 1))
fi

# 检查 data 目录
echo ""
echo "📁 检查数据目录..."
if [ -d "./data" ]; then
    DATA_SIZE=$(du -sh ./data 2>/dev/null | awk '{print $1}')
    echo "  ✅ 数据目录存在: ./data ($DATA_SIZE)"
else
    echo "  ℹ️  数据目录不存在: ./data (首次同步时会自动创建)"
fi

# 总结
echo ""
echo "========================================================"
echo "📊 验证结果"
echo "========================================================"
echo "  错误: $ERRORS"
echo "  警告: $WARNINGS"
echo ""

if [ $ERRORS -gt 0 ]; then
    echo "❌ 配置存在问题，请修复后重试"
    exit 1
elif [ $WARNINGS -gt 0 ]; then
    echo "⚠️  配置有警告，建议检查"
    exit 0
else
    echo "✅ 配置验证通过"
    echo ""
    echo "下一步:"
    echo "  1. 启动容器: docker-compose up -d"
    echo "  2. 执行同步: ./quick_start_sync.sh"
    echo "  3. 检查状态: ./check_sync_status.sh"
    exit 0
fi

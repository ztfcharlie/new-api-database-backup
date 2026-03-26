#!/bin/bash

# ==============================================================================
# 将 Slave 提升为 Master 脚本
# 执行后此数据库将变为独立的主库，不再同步
# ==============================================================================

if [ -z "$BASH_VERSION" ]; then
    exec bash "$0" "$@"
fi

# 加载环境变量
if [ -f .env ]; then
    set -a
    source .env
    set +a
else
    echo "错误: 未找到 .env 文件"
    exit 1
fi

CONTAINER_DB="backup_${PROJECT_NAME}"

echo "========================================================"
echo "    Slave 提升为 Master"
echo "========================================================"
echo "容器: $CONTAINER_DB"
echo "========================================================"

# 检查容器
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_DB}$"; then
    echo "错误: 容器未运行"
    exit 1
fi

# 检查当前同步状态
echo ""
echo "当前同步状态:"
STATUS=$(docker exec -e MYSQL_PWD="${MYSQL_ROOT_PASSWORD}" "$CONTAINER_DB" mysql -u root -e "SHOW SLAVE STATUS\G" 2>/dev/null)
IO_RUNNING=$(echo "$STATUS" | grep "Slave_IO_Running:" | awk '{print $2}' | tr -d '\r')
SQL_RUNNING=$(echo "$STATUS" | grep "Slave_SQL_Running:" | awk '{print $2}' | tr -d '\r')
SECONDS_BEHIND=$(echo "$STATUS" | grep "Seconds_Behind_Master:" | awk '{print $2}' | tr -d '\r')

echo "  IO 线程:  $IO_RUNNING"
echo "  SQL 线程: $SQL_RUNNING"
echo "  延迟:     ${SECONDS_BEHIND:-N/A} 秒"

# 警告检查
if [ "$IO_RUNNING" = "Yes" ] && [ "$SQL_RUNNING" = "Yes" ] && [ "$SECONDS_BEHIND" != "0" ]; then
    echo ""
    echo "⚠️  警告: 还有 ${SECONDS_BEHIND} 秒的延迟"
    read -p "确定要提升为 Master 吗? (y/n): " CONFIRM
    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
        echo "已取消"
        exit 0
    fi
fi

echo ""
echo "开始执行..."

# 执行提升
docker exec -e MYSQL_PWD="${MYSQL_ROOT_PASSWORD}" "$CONTAINER_DB" mysql -u root << 'EOF'
-- 停止并清除 Slave 配置
STOP SLAVE;
RESET SLAVE ALL;

-- 关闭只读模式
SET GLOBAL read_only = OFF;
SET GLOBAL super_read_only = OFF;

SELECT 'Done' AS Status;
EOF

if [ $? -eq 0 ]; then
    echo ""
    echo "========================================================"
    echo "✅ 提升成功!"
    echo "========================================================"
    echo ""
    echo "当前状态:"
    READ_ONLY=$(docker exec -e MYSQL_PWD="${MYSQL_ROOT_PASSWORD}" "$CONTAINER_DB" mysql -u root -N -e "SHOW VARIABLES LIKE 'read_only';" 2>/dev/null | awk '{print $2}')
    echo "  read_only: $READ_ONLY"

    SLAVE_STATUS=$(docker exec -e MYSQL_PWD="${MYSQL_ROOT_PASSWORD}" "$CONTAINER_DB" mysql -u root -e "SHOW SLAVE STATUS\G" 2>/dev/null)
    if [ -z "$SLAVE_STATUS" ]; then
        echo "  Slave 状态: 已清除"
    fi

    echo ""
    echo "此数据库现在是独立的 Master，可以正常读写。"
    echo "========================================================"
else
    echo ""
    echo "❌ 提升失败，请检查错误信息"
    exit 1
fi

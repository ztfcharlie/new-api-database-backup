#!/bin/bash

# ==============================================================================
# MySQL 同步状态检查脚本 v4.0
# ==============================================================================

# 加载环境变量
if [ -f .env ]; then
    set -a
    source .env
    set +a
else
    echo "错误: .env 文件不存在"
    exit 1
fi

CONTAINER_NAME="db_${PROJECT_NAME}"
TUNNEL_NAME="tunnel_${PROJECT_NAME}"

echo ""
echo "========================================================"
echo "    MySQL 同步状态检查"
echo "========================================================"
echo "项目: $PROJECT_NAME"
echo "容器: $CONTAINER_NAME"
echo "========================================================"

# 检查容器
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "❌ 数据库容器未运行"
    exit 1
fi

if ! docker ps --format '{{.Names}}' | grep -q "^${TUNNEL_NAME}$"; then
    echo "⚠️  隧道容器未运行"
else
    echo "✅ 隧道容器运行中"
fi

# 获取 Slave 状态
STATUS=$(docker exec -e MYSQL_PWD="${MYSQL_ROOT_PASSWORD}" "$CONTAINER_NAME" \
    mysql -u root -e "SHOW SLAVE STATUS\G" 2>/dev/null)

if [ -z "$STATUS" ]; then
    echo "⚠️  Slave 未配置"
    echo ""
    echo "请运行: ./quick_start_sync.sh"
    exit 0
fi

# 提取状态
IO_RUNNING=$(echo "$STATUS" | grep "Slave_IO_Running:" | awk '{print $2}')
SQL_RUNNING=$(echo "$STATUS" | grep "Slave_SQL_Running:" | awk '{print $2}')
SECONDS_BEHIND=$(echo "$STATUS" | grep "Seconds_Behind_Master:" | awk '{print $2}')
LAST_IO_ERRNO=$(echo "$STATUS" | grep "Last_IO_Errno:" | awk '{print $2}')
LAST_IO_ERROR=$(echo "$STATUS" | grep "Last_IO_Error:" | cut -d: -f2- | sed 's/^ *//')
LAST_SQL_ERROR=$(echo "$STATUS" | grep "Last_SQL_Error:" | cut -d: -f2- | sed 's/^ *//')

# GTID 信息
LOCAL_GTID=$(docker exec -e MYSQL_PWD="${MYSQL_ROOT_PASSWORD}" "$CONTAINER_NAME" \
    mysql -u root -N -e "SELECT @@GLOBAL.GTID_EXECUTED;" 2>/dev/null)

echo ""
echo "--------------------------------------------------------"
echo "状态"
echo "--------------------------------------------------------"
echo "IO 线程:   $IO_RUNNING"
echo "SQL 线程:  $SQL_RUNNING"
echo "延迟:      ${SECONDS_BEHIND:-NULL} 秒"
echo "本地 GTID: ${LOCAL_GTID:-空}"
echo "--------------------------------------------------------"

# 判断状态
if [ "$IO_RUNNING" = "Yes" ] && [ "$SQL_RUNNING" = "Yes" ]; then
    echo "✅ 状态: 正常"
    exit 0

elif [ "$IO_RUNNING" = "Connecting" ]; then
    echo "⚠️  状态: 正在连接"
    echo ""
    echo "检查: docker logs $TUNNEL_NAME"
    exit 1

else
    echo "❌ 状态: 异常"

    if [ -n "$LAST_IO_ERROR" ] && [ "$LAST_IO_ERROR" != "0" ]; then
        echo ""
        echo "IO 错误 ($LAST_IO_ERRNO): $LAST_IO_ERROR"
    fi

    if [ -n "$LAST_SQL_ERROR" ]; then
        echo ""
        echo "SQL 错误: $LAST_SQL_ERROR"
    fi

    echo ""
    echo "建议: ./quick_start_sync.sh --force-clean"
    exit 1
fi

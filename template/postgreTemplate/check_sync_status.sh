#!/bin/bash

# ==============================================================================
# PostgreSQL 复制状态检查脚本 v1.0
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

CONTAINER_DB="db_${PROJECT_NAME}"
CONTAINER_TUNNEL="tunnel_${PROJECT_NAME}"

echo ""
echo "========================================================"
echo "    PostgreSQL 复制状态检查"
echo "========================================================"
echo "项目: $PROJECT_NAME"
echo "容器: $CONTAINER_DB"
echo "========================================================"

# 检查容器
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_DB}$"; then
    echo "❌ 数据库容器未运行"
    exit 1
fi

if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_TUNNEL}$"; then
    echo "⚠️  隧道容器未运行"
else
    echo "✅ 隧道容器运行中"
fi

echo ""
echo "--------------------------------------------------------"
echo "备库状态"
echo "--------------------------------------------------------"

# 是否处于恢复模式
IS_IN_RECOVERY=$(docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "$CONTAINER_DB" \
    psql -U "$POSTGRES_USER" -d postgres -t -c \
    "SELECT pg_is_in_recovery();" 2>/dev/null | tr -d ' \n')
echo "是否处于恢复:     ${IS_IN_RECOVERY:-未知}"

# WAL receiver 状态
WAL_STATUS=$(docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "$CONTAINER_DB" \
    psql -U "$POSTGRES_USER" -d postgres -t -c \
    "SELECT status FROM pg_stat_wal_receiver;" 2>/dev/null | tr -d ' \n')
echo "WAL Receiver:     ${WAL_STATUS:-未启动}"

# 复制延迟
LAG=$(docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "$CONTAINER_DB" \
    psql -U "$POSTGRES_USER" -d postgres -t -c \
    "SELECT COALESCE(EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp()))::int, -1);" 2>/dev/null | tr -d ' \n')
echo "复制延迟:         ${LAG:-未知} 秒"

# 最后接收的 LSN
LAST_LSN=$(docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "$CONTAINER_DB" \
    psql -U "$POSTGRES_USER" -d postgres -t -c \
    "SELECT pg_last_wal_receive_lsn();" 2>/dev/null | tr -d ' \n')
echo "最后接收 LSN:     ${LAST_LSN:-未知}"

# 最后重放的 LSN
REPLAY_LSN=$(docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "$CONTAINER_DB" \
    psql -U "$POSTGRES_USER" -d postgres -t -c \
    "SELECT pg_last_wal_replay_lsn();" 2>/dev/null | tr -d ' \n')
echo "最后重放 LSN:     ${REPLAY_LSN:-未知}"

# 只读状态
READ_ONLY=$(docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "$CONTAINER_DB" \
    psql -U "$POSTGRES_USER" -d postgres -t -c \
    "SHOW transaction_read_only;" 2>/dev/null | tr -d ' \n')
echo "只读模式:         ${READ_ONLY:-未知}"

echo "--------------------------------------------------------"

# 判断状态
if [ "$WAL_STATUS" = "streaming" ]; then
    echo "✅ 状态: 正常（流复制运行中）"
    exit 0
elif [ -z "$WAL_STATUS" ]; then
    echo "⚠️  状态: WAL Receiver 未启动"
    echo ""
    echo "检查: docker logs $CONTAINER_DB"
    echo "检查: docker exec $CONTAINER_DB tail -50 /var/log/slave_monitor.log"
    exit 1
else
    echo "❌ 状态: 异常（$WAL_STATUS）"
    echo ""
    echo "检查: docker logs $CONTAINER_DB"
    echo "建议: ./quick_start_sync.sh --clean-cache"
    exit 1
fi


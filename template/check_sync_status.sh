#!/bin/bash

# ==============================================================================
# MySQL 同步状态检查脚本 v3.0
# 添加 GTID 状态显示和更详细的诊断信息
# ==============================================================================

# 0. 强制使用 Bash
if [ -z "$BASH_VERSION" ]; then
    echo "⚠️  Detected non-Bash shell. Switching to Bash..."
    exec bash "$0" "$@"
fi

# Load environment variables
if [ -f .env ]; then
  set -a
  source .env
  set +a
else
  echo "Error: .env file not found in current directory."
  exit 1
fi

CONTAINER_NAME="backup_${PROJECT_NAME}"

echo "========================================================"
echo "📊 MySQL 同步状态检查 v3.0"
echo "项目: $PROJECT_NAME"
echo "容器: $CONTAINER_NAME"
echo "Server ID: ${SERVER_ID:-100}"
echo "========================================================"

# Check if container is running
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
  echo "❌ 错误: 容器 '$CONTAINER_NAME' 未运行"
  echo "请先执行 docker-compose up -d"
  exit 1
fi

# 检查 tunnel 容器
TUNNEL_NAME="tunnel_${PROJECT_NAME}"
if docker ps --format '{{.Names}}' | grep -q "^${TUNNEL_NAME}$"; then
  echo "✅ Tunnel 容器运行中"
else
  echo "⚠️  Tunnel 容器未运行"
fi

echo ""
echo "--------------------------------------------------------"
echo "🔧 GTID 状态"
echo "--------------------------------------------------------"

# 获取本地 GTID
LOCAL_GTID=$(docker exec -e MYSQL_PWD="${MYSQL_ROOT_PASSWORD}" "$CONTAINER_NAME" mysql -u root -N -e "SHOW GLOBAL VARIABLES LIKE 'gtid_executed';" 2>/dev/null | awk '{print $2}')
echo "本地 GTID: ${LOCAL_GTID:-空}"

# 尝试获取 Master GTID
MASTER_GTID=$(docker exec -e MYSQL_PWD="${MASTER_PASSWORD}" "$CONTAINER_NAME" mysql -h tunnel -u "${MASTER_USER:-root}" -N -e "SHOW GLOBAL VARIABLES LIKE 'gtid_executed';" 2>/dev/null | awk '{print $2}')
if [ -n "$MASTER_GTID" ]; then
  echo "Master GTID: $MASTER_GTID"
else
  echo "Master GTID: (无法获取)"
fi

echo ""
echo "--------------------------------------------------------"
echo "📡 同步状态"
echo "--------------------------------------------------------"

# 获取 Slave 状态
STATUS=$(docker exec -e MYSQL_PWD="${MYSQL_ROOT_PASSWORD}" "$CONTAINER_NAME" mysql -u root -e "SHOW SLAVE STATUS\G" 2>/dev/null)

if [ -z "$STATUS" ]; then
  echo "⚠️  Slave 未配置"
  echo ""
  echo "请运行 ./quick_start_sync.sh 进行初始同步"
  exit 0
fi

# 提取关键字段
IO_RUNNING=$(echo "$STATUS" | grep "Slave_IO_Running:" | awk '{print $2}')
SQL_RUNNING=$(echo "$STATUS" | grep "Slave_SQL_Running:" | awk '{print $2}')
SECONDS_BEHIND=$(echo "$STATUS" | grep "Seconds_Behind_Master:" | awk '{print $2}')
MASTER_HOST=$(echo "$STATUS" | grep "Master_Host:" | awk '{print $2}')
MASTER_PORT=$(echo "$STATUS" | grep "Master_Port:" | awk '{print $2}')
AUTO_POSITION=$(echo "$STATUS" | grep "Auto_Position:" | awk '{print $2}')
RETRIEVED_GTID=$(echo "$STATUS" | grep "Retrieved_Gtid_Set:" | sed 's/.*Retrieved_Gtid_Set: //')
EXECUTED_GTID=$(echo "$STATUS" | grep "Executed_Gtid_Set:" | sed 's/.*Executed_Gtid_Set: //')
LAST_IO_ERROR=$(echo "$STATUS" | grep "Last_IO_Error:" | sed 's/.*Last_IO_Error: //')
LAST_SQL_ERROR=$(echo "$STATUS" | grep "Last_SQL_Error:" | sed 's/.*Last_SQL_Error: //')
LAST_IO_ERRNO=$(echo "$STATUS" | grep "Last_IO_Errno:" | awk '{print $2}')
LAST_SQL_ERRNO=$(echo "$STATUS" | grep "Last_SQL_Errno:" | awk '{print $2}')

# 显示状态
echo "Master: $MASTER_HOST:$MASTER_PORT"
echo "Auto_Position: $AUTO_POSITION"
echo ""
echo "IO 线程:   $IO_RUNNING"
echo "SQL 线程:  $SQL_RUNNING"
echo "延迟:      ${SECONDS_BEHIND:-NULL} 秒"
echo ""

# 显示 GTID 详情
if [ -n "$RETRIEVED_GTID" ]; then
  echo "已接收 GTID: $RETRIEVED_GTID"
fi
if [ -n "$EXECUTED_GTID" ]; then
  echo "已执行 GTID: $EXECUTED_GTID"
fi

echo ""
echo "--------------------------------------------------------"

# 状态判断
if [ "$IO_RUNNING" = "Yes" ] && [ "$SQL_RUNNING" = "Yes" ]; then
  echo "🎉 状态: 正常运行"

  if [ "$SECONDS_BEHIND" = "0" ]; then
    echo "   完全同步，无延迟"
  elif [ -n "$SECONDS_BEHIND" ] && [ "$SECONDS_BEHIND" -gt 0 ]; then
    echo "   有延迟，正在追赶..."
  fi
  exit 0

elif [ "$IO_RUNNING" = "Connecting" ]; then
  echo "⚠️  状态: IO 线程正在连接..."
  echo ""
  echo "可能原因:"
  echo "1. 网络不稳定"
  echo "2. Master 认证失败"
  echo "3. Tunnel 未建立"
  exit 1

elif [ "$IO_RUNNING" != "Yes" ] || [ "$SQL_RUNNING" != "Yes" ]; then
  echo "❌ 状态: 异常"
  echo ""

  # 显示错误信息
  if [ -n "$LAST_IO_ERROR" ] && [ "$LAST_IO_ERROR" != "0" ]; then
    echo "IO 错误 ($LAST_IO_ERRNO): $LAST_IO_ERROR"
  fi
  if [ -n "$LAST_SQL_ERROR" ] && [ "$LAST_SQL_ERROR" != "0" ]; then
    echo "SQL 错误 ($LAST_SQL_ERRNO): $LAST_SQL_ERROR"
  fi

  echo ""
  echo "常见错误代码:"
  echo "  1045 - 认证失败，检查 MASTER_PASSWORD"
  echo "  2003 - 连接失败，检查 Tunnel 状态"
  echo "  1236 - Binlog 错误，可能需要重新同步"
  echo "  1872 - Repository 错误，需要 RESET SLAVE"

  echo ""
  echo "建议操作:"
  echo "  1. 检查 tunnel 日志: docker logs tunnel_${PROJECT_NAME}"
  echo "  2. 重新同步: ./quick_start_sync.sh"
  exit 1
fi

echo "========================================================"

#!/bin/bash

# ==============================================================================
# 🚀 快速初始化同步脚本 (适用于新主库/空主库)
# 功能：自动连接生产库 -> 获取 File/Position -> 配置本地从库 -> 开启同步
# 注意：仅在首次搭建时使用。如果主库已有大量数据，请使用 restore_slave.sh
# ==============================================================================

# 1. 检查并加载环境变量
if [ ! -f .env ]; then
  echo "❌ 错误: 当前目录下未找到 .env 文件。"
  echo "请先复制模板: cp .env.example .env 并完成配置。"
  exit 1
fi

# 导出环境变量以便脚本使用
export $(grep -v '^#' .env | xargs)

# 检查必要的变量
if [ -z "$PROJECT_NAME" ] || [ -z "$MYSQL_ROOT_PASSWORD" ]; then
  echo "❌ 错误: .env 文件配置不完整 (缺少 PROJECT_NAME 或 MYSQL_ROOT_PASSWORD)"
  exit 1
fi

CONTAINER_DB="backup_${PROJECT_NAME}"
CONTAINER_TUNNEL="tunnel_${PROJECT_NAME}"

echo "--------------------------------------------------------"
echo "🔄 MySQL 主从同步快速初始化向导"
echo "--------------------------------------------------------"
echo "项目名称: $PROJECT_NAME"
echo "数据库容器: $CONTAINER_DB"
echo "--------------------------------------------------------"

# 2. 检查容器运行状态
if ! docker ps | grep -q "$CONTAINER_DB"; then
  echo "❌ 错误: 数据库容器 '$CONTAINER_DB' 未运行。"
  echo "请先执行: docker-compose up -d"
  exit 1
fi

# 3. 获取生产库权限 (需要 Root 权限来执行 SHOW MASTER STATUS)
echo "我们需要连接到生产数据库获取当前的 Binlog 坐标。"
echo "请提供生产数据库的 ROOT 密码 (密码不会被保存):"
read -s -p "生产库 Root 密码: " PROD_DB_PASSWORD
echo ""

# 4. 尝试通过隧道连接生产库获取状态
echo "📡 正在通过 SSH 隧道连接生产库..."

# 在 db 容器内执行 mysql 客户端连接 tunnel host
# 使用 awk 提取 File 和 Position
MASTER_STATUS=$(docker exec -i "$CONTAINER_DB" mysql -h tunnel -u root -p"$PROD_DB_PASSWORD" -e "SHOW MASTER STATUS\G" 2>/dev/null)

if [ -z "$MASTER_STATUS" ]; then
  echo "❌ 连接生产库失败！"
  echo "可能原因:"
  echo "1. 密码错误"
  echo "2. SSH 隧道未建立 (检查 tunnel 容器日志)"
  echo "3. 生产库未开启 Binlog (log-bin)"
  exit 1
fi

LOG_FILE=$(echo "$MASTER_STATUS" | grep "File:" | awk '{print $2}')
LOG_POS=$(echo "$MASTER_STATUS" | grep "Position:" | awk '{print $2}')

if [ -z "$LOG_FILE" ] || [ -z "$LOG_POS" ]; then
  echo "❌ 获取坐标失败。请检查主库是否开启了 Binlog。"
  echo "调试信息:"
  echo "$MASTER_STATUS"
  exit 1
fi

echo "✅ 成功获取生产库坐标!"
echo "📄 File: $LOG_FILE"
echo "📍 Position: $LOG_POS"
echo "--------------------------------------------------------"

# 5. 配置本地从库
echo "⚙️  正在配置本地从库..."

# 拼接 SQL 语句
# 注意: MASTER_HOST='tunnel' 是 Docker 内部网络的主机名
SQL_CMD="STOP SLAVE;
CHANGE MASTER TO 
  MASTER_HOST='tunnel', 
  MASTER_USER='$MASTER_USER', 
  MASTER_PASSWORD='$MASTER_PASSWORD', 
  MASTER_LOG_FILE='$LOG_FILE', 
  MASTER_LOG_POS=$LOG_POS;
START SLAVE;
SHOW SLAVE STATUS\G"

# 执行 SQL
SLAVE_STATUS=$(docker exec -i "$CONTAINER_DB" mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "$SQL_CMD" 2>/dev/null)

# 6. 验证结果
IO_RUNNING=$(echo "$SLAVE_STATUS" | grep "Slave_IO_Running:" | awk '{print $2}')
SQL_RUNNING=$(echo "$SLAVE_STATUS" | grep "Slave_SQL_Running:" | awk '{print $2}')

echo "--------------------------------------------------------"
if [ "$IO_RUNNING" == "Yes" ] && [ "$SQL_RUNNING" == "Yes" ]; then
  echo "🎉 同步启动成功！"
  echo "Slave_IO_Running: $IO_RUNNING"
  echo "Slave_SQL_Running: $SQL_RUNNING"
  echo "提示: 初始数据将从现在开始实时同步。"
else
  echo "⚠️  同步启动可能遇到问题，请检查状态："
  echo "Slave_IO_Running: $IO_RUNNING"
  echo "Slave_SQL_Running: $SQL_RUNNING"
  echo "详细错误信息:"
  echo "$SLAVE_STATUS" | grep "Last_.*_Error"
fi
echo "--------------------------------------------------------"

#!/bin/bash

# ==============================================================================
# 🚀 真正的一键全自动同步脚本 (Auto-Sync) v2.1
# 修复: 兼容性问题、进程查杀逻辑 (解决 ERROR 3021)、去除冗余 Start Slave
# ==============================================================================

# 0. 强制使用 Bash (解决 sh read -s / [[ ]] 报错)
if [ -z "$BASH_VERSION" ]; then
    echo "⚠️  检测到当前 Shell 不是 Bash，正在切换到 Bash..."
    exec bash "$0" "$@"
fi

# 1. 检查并加载环境变量
if [ ! -f .env ]; then
  echo "❌ 错误: 当前目录下未找到 .env 文件。"
  exit 1
fi
set -a
source .env
set +a

# 检查必要的变量
if [ -z "$PROJECT_NAME" ] || [ -z "$MYSQL_ROOT_PASSWORD" ] || [ -z "$TARGET_DB_NAME" ]; then
  echo "❌ 错误: .env 配置不完整 (缺少 PROJECT_NAME / ROOT密码 / 目标库名)"
  exit 1
fi

CONTAINER_DB="backup_${PROJECT_NAME}"

echo "--------------------------------------------------------"
echo "🔄 MySQL 一键全自动同步向导 v2.1"
echo "--------------------------------------------------------"
echo "项目: $PROJECT_NAME"
echo "目标库: $TARGET_DB_NAME"
echo "容器: $CONTAINER_DB"
echo "--------------------------------------------------------"

# 2. 检查容器
if ! docker ps | grep -q "$CONTAINER_DB"; then
  echo "❌ 错误: 数据库容器未运行。请先执行 docker-compose up -d"
  exit 1
fi

# 3. 询问生产库密码
echo "请输入生产库(Master)的 Root 密码，用于拉取初始数据:"
read -s -p "密码: " PROD_DB_PASSWORD
echo ""

# 4. 检测本地是否存在数据库
echo "🔍 正在检查本地数据库状态..."
DB_EXISTS=$(docker exec "$CONTAINER_DB" mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "SHOW DATABASES LIKE '$TARGET_DB_NAME';" 2>/dev/null)

if [[ "$DB_EXISTS" == *"$TARGET_DB_NAME"* ]]; then
  echo "⚠️  警告: 本地已经存在 '$TARGET_DB_NAME' 数据库。"
  echo "可能会导致同步冲突。建议手动删除该库后重试，或者继续尝试覆盖..."
else
  echo "✅ 本地干净，准备开始..."
fi

echo "🚀 准备开始【全量拉取 + 同步】..."

# === 核心逻辑: 管道传输 ===

# 关键修复: 使用 ps + awk 手动查找并杀掉 init-slave.sh，不依赖 pkill/killall
# 这一步至关重要，防止 ERROR 3021
echo "🔫 [1/4] 正在强制暂停后台守护进程..."
docker exec "$CONTAINER_DB" sh -c "ps -ef | grep init-slave.sh | grep -v grep | awk '{print \$1}' | xargs -r kill" || true

echo "⚙️  [2/4] 正在重置本地 Slave 状态..."
# 停止 Slave 并清除状态，防止 mysqldump 写入时冲突
docker exec -i "$CONTAINER_DB" mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "STOP SLAVE; RESET SLAVE ALL; RESET MASTER;"

echo "🚀 [3/4] 正在传输数据 (这可能需要几分钟)..."
# 使用 set -o pipefail 确保管道任意一环出错都能被捕获
docker exec -i "$CONTAINER_DB" sh -c "
  export MYSQL_PWD=\"$MYSQL_ROOT_PASSWORD\"
  export PROD_PWD=\"$PROD_DB_PASSWORD\"
  
  # 开始管道传输
  # --add-drop-database 确保如果库存在则先删除，避免残留问题
  mysqldump -h tunnel -u root -p\"$PROD_PWD\" \
    --databases $TARGET_DB_NAME \
    --add-drop-database \
    --single-transaction \
    --master-data=1 \
    --set-gtid-purged=AUTO \
    | mysql -u root
"

# 检查上一步的执行结果
if [ $? -eq 0 ]; then
  echo "✅ 数据拉取及导入成功！"
  
  echo "🔄 [4/4] 正在重启容器以应用同步配置..."
  # 重启容器，让 init-slave.sh 自动接管后续的连接工作
  docker restart "$CONTAINER_DB"
  
else
  echo "❌ 导入失败！请检查上方错误日志。"
  echo "提示: 可能原因包括密码错误、网络中断或权限不足。"
  # 即使失败也尝试重启容器恢复环境
  docker restart "$CONTAINER_DB"
  exit 1
fi

# 5. 验证结果 (重启后需要等待一下)
echo "⏳ 等待数据库启动..."
until docker exec "$CONTAINER_DB" mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "SELECT 1" > /dev/null 2>&1; do
    echo -n "."
    sleep 2
done
echo ""

echo "--------------------------------------------------------"
echo "📊 正在检查同步状态..."
# 给 init-slave.sh 一点时间去执行 CHANGE MASTER
sleep 5 

STATUS=$(docker exec "$CONTAINER_DB" mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "SHOW SLAVE STATUS\G")
IO_RUNNING=$(echo "$STATUS" | grep "Slave_IO_Running:" | awk '{print $2}')
SQL_RUNNING=$(echo "$STATUS" | grep "Slave_SQL_Running:" | awk '{print $2}')

if [ "$IO_RUNNING" = "Yes" ] && [ "$SQL_RUNNING" = "Yes" ]; then
  echo "🎉 完美！同步已启动并且运行正常。"
  echo "状态: IO=$IO_RUNNING / SQL=$SQL_RUNNING"
else
  echo "⚠️  同步启动后状态异常，请检查:"
  echo "$STATUS" | grep "Last_.*_Error"
fi
echo "--------------------------------------------------------"
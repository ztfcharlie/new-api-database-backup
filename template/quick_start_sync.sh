#!/bin/bash

# ==============================================================================
# 🚀 真正的一键全自动同步脚本 (Auto-Sync) v2.0
# 修复: 增加杀掉后台守护进程的逻辑，防止争抢控制权
# ==============================================================================

# 1. 检查并加载环境变量
if [ ! -f .env ]; then
  echo "❌ 错误: 当前目录下未找到 .env 文件。"
  exit 1
fi
export $(grep -v '^#' .env | xargs)

# 检查必要的变量
if [ -z "$PROJECT_NAME" ] || [ -z "$MYSQL_ROOT_PASSWORD" ] || [ -z "$TARGET_DB_NAME" ]; then
  echo "❌ 错误: .env 配置不完整 (缺少 PROJECT_NAME / ROOT密码 / 目标库名)"
  exit 1
fi

CONTAINER_DB="backup_${PROJECT_NAME}"

echo "--------------------------------------------------------"
echo "🔄 MySQL 一键全自动同步向导 v2.0"
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
  echo "跳过数据拉取，仅检查状态..."
else
  echo "✅ 本地为空，准备开始【全量拉取 + 同步】..."
  
  # === 核心逻辑: 管道传输 ===
  
  # 关键修复: 先杀掉容器内的守护进程 init-slave.sh
  # 使用 || true 防止因为找不到进程而报错退出
  echo "🔫 [1/4] 正在暂停后台守护进程..."
  docker exec "$CONTAINER_DB" sh -c "pkill -f init-slave.sh || killall init-slave.sh || true"
  
  echo "⚙️  [2/4] 正在重置本地 Slave 状态..."
  docker exec -i "$CONTAINER_DB" mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "STOP SLAVE; RESET MASTER; CHANGE MASTER TO MASTER_AUTO_POSITION = 0;"
  
  echo "🚀 [3/4] 正在传输数据 (这可能需要几分钟)..."
  # 使用 set -o pipefail 确保管道任意一环出错都能被捕获
  # 注意：这里我们让 mysqldump 的 stderr 重定向到 stdout 或者 /dev/null 防止密码泄露，或者保留以便调试
  # 这里的 export PROD_PWD 是为了传递给内部的 sh
  docker exec -i "$CONTAINER_DB" sh -c "
    export MYSQL_PWD=\"$MYSQL_ROOT_PASSWORD\"
    export PROD_PWD=\"$PROD_DB_PASSWORD\"
    
    # 开始管道传输
    mysqldump -h tunnel -u root -p\"$PROD_PWD\" \
      --databases $TARGET_DB_NAME \
      --single-transaction \
      --master-data=1 \
      --set-gtid-purged=AUTO \
      | mysql -u root
  "
  
  # 检查上一步的执行结果
  if [ $? -eq 0 ]; then
    echo "✅ 数据拉取及导入成功！"
    
    echo "🔄 [4/4] 恢复同步并重启守护进程..."
    # 切换回 GTID 模式并启动
    docker exec -i "$CONTAINER_DB" mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "CHANGE MASTER TO MASTER_AUTO_POSITION = 1; START SLAVE;"
    
    # 重启容器以恢复 init-slave.sh 守护进程
    # 注意: 重启容器比较慢，也可以选择在后台重新运行脚本，但重启容器最稳
    echo "♻️  正在重启容器以恢复守护进程..."
    docker restart "$CONTAINER_DB"
    
  else
    echo "❌ 导入失败！请检查上方错误日志。"
    echo "提示: 可能原因包括密码错误、网络中断或权限不足。"
    # 即使失败也尝试重启容器恢复环境
    docker restart "$CONTAINER_DB"
    exit 1
  fi
fi

# 5. 验证结果 (重启后需要等待一下)
echo "⏳ 等待数据库启动..."
sleep 10

echo "--------------------------------------------------------"
echo "📊 正在检查同步状态..."
STATUS=$(docker exec "$CONTAINER_DB" mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "SHOW SLAVE STATUS\G")
IO_RUNNING=$(echo "$STATUS" | grep "Slave_IO_Running:" | awk '{print $2}')
SQL_RUNNING=$(echo "$STATUS" | grep "Slave_SQL_Running:" | awk '{print $2}')

if [ "$IO_RUNNING" == "Yes" ] && [ "$SQL_RUNNING" == "Yes" ]; then
  echo "🎉 完美！同步已启动并且运行正常。"
  echo "状态: IO=$IO_RUNNING / SQL=$SQL_RUNNING"
else
  echo "⚠️  同步启动后状态异常，请检查:"
  echo "$STATUS" | grep "Last_.*_Error"
fi
echo "--------------------------------------------------------"

#!/bin/bash

# ==============================================================================
# 🚀 真正的一键全自动同步脚本 (Auto-Sync)
# 功能：
# 1. 自动检测本地是否为空库
# 2. 如果为空，自动从主库(通过隧道)拉取全量数据 (mysqldump)
# 3. 自动利用 Dump 包里的坐标开启主从同步
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
echo "🔄 MySQL 一键全自动同步向导"
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
  echo "跳过数据拉取，仅尝试修复同步连接..."
  # 这里可以加个分支逻辑，但为了安全，先不覆盖现有数据
else
  echo "✅ 本地为空，准备开始【全量拉取 + 同步】..."
  
  # === 核心逻辑: 管道传输 ===
  # 步骤: 停止同步 -> 清空残留 -> 管道传输(mysqldump -> mysql) -> 自动恢复
  
  echo "🚀 [1/3] 正在从主库拉取数据并导入 (这可能需要几分钟)..."
  
  # 构造复杂的管道命令
  # 1. 远程导出: --master-data=1 (关键! 包含同步坐标), --single-transaction (不锁表)
  # 2. 本地导入: 先把 Auto_Position 关了，避免 GTID 冲突
  
  docker exec -i "$CONTAINER_DB" sh -c "
    export MYSQL_PWD=\"$MYSQL_ROOT_PASSWORD\"
    
    # 1. 先把环境清理干净
    echo '>> 正在重置本地 Slave 状态...'
    mysql -u root -e 'STOP SLAVE; RESET MASTER; CHANGE MASTER TO MASTER_AUTO_POSITION = 0;'
    
    # 2. 开始管道传输
    echo '>> 正在传输数据...'
    # 注意: 这里在容器内调用 mysqldump 连接 tunnel
    export PROD_PWD=\"$
PROD_DB_PASSWORD\"
    mysqldump -h tunnel -u root -p"$PROD_PWD" \
      --databases $TARGET_DB_NAME \
      --single-transaction \
      --master-data=1 \
      --set-gtid-purged=AUTO \
      | mysql -u root
      
    # 3. 启动同步
    echo '>> 数据导入完成，正在启动同步...'
    mysql -u root -e 'START SLAVE;'
  "
  
  if [ $? -eq 0 ]; then
    echo "✅ 数据拉取及导入成功！"
  else
    echo "❌ 导入过程中出现错误，请检查密码或网络。"
    exit 1
  fi
fi

# 5. 验证结果
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
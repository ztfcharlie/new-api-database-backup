#!/bin/bash
set -e

# 标记文件
if [ -f "/var/lib/mysql/slave_configured" ]; then
    echo ">>> Slave 已经配置过，跳过初始化..."
    exit 0
fi

echo ">>> 等待 Tunnel 和 MySQL 启动 (15s)..."
sleep 15

echo ">>> 开始配置 Slave 连接到 ${MASTER_HOST}:${MASTER_PORT}..."

# 循环尝试连接，直到 Tunnel 建立成功
for i in {1..30}; do
    if mysql -h "${MASTER_HOST}" -P "${MASTER_PORT}" -u "${MASTER_USER}" -p"${MASTER_PASSWORD}" -e "SELECT 1" > /dev/null 2>&1; then
        echo ">>> 连接生产库成功！"
        break
    fi
    echo ">>> 等待隧道连通... ($i/30)"
    sleep 2
done

mysql -u root -p"${MYSQL_ROOT_PASSWORD}" <<EOF
    STOP SLAVE;
    RESET SLAVE ALL;
    
    CHANGE MASTER TO 
      MASTER_HOST='${MASTER_HOST}',
      MASTER_PORT=${MASTER_PORT},
      MASTER_USER='${MASTER_USER}',
      MASTER_PASSWORD='${MASTER_PASSWORD}',
      MASTER_AUTO_POSITION=1; 
      
    START SLAVE;
    SHOW SLAVE STATUS\G;
EOF

touch /var/lib/mysql/slave_configured
echo ">>> Slave 配置脚本执行完毕！"
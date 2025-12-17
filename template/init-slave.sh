#!/bin/bash
set -e

# === 智能守护脚本 ===
# 功能：
# 1. 首次启动时自动配置 Master-Slave 连接
# 2. 容器重启时自动检查并恢复同步状态
# 3. 遇到 1872 等致命错误时自动重置并重新连接

echo ">>> [Init] MySQL Backup Slave 守护进程启动..."

# 等待 MySQL 服务完全就绪
echo ">>> [Init] 等待本地 MySQL 启动..."
until mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "SELECT 1" > /dev/null 2>&1; do
    sleep 2
done

# 定义重连函数
reconnect_master() {
    echo ">>> [Fix] 检测到同步异常或未配置，开始执行(重新)连接 Master..."
    
    # 1. 尝试连接 Tunnel，确保网络通畅
    echo ">>> [Check] 正在尝试连接 Tunnel (15s timeout)..."
    for i in {1..15}; do
        if mysql -h "${MASTER_HOST}" -P "${MASTER_PORT}" -u "${MASTER_USER}" -p"${MASTER_PASSWORD}" -e "SELECT 1" > /dev/null 2>&1; then
            echo ">>> [Check] 成功连接到生产库！"
            break
        fi
        if [ $i -eq 15 ]; then
            echo ">>> [Error] 无法连接到 Tunnel/Master，请检查网络或 SSH 隧道状态。跳过本次修复。"
            return 1
        fi
        sleep 2
    done

    # 2. 执行重置与连接逻辑
    mysql -u root -p"${MYSQL_ROOT_PASSWORD}" <<EOF
        STOP SLAVE;
        RESET SLAVE ALL; -- 彻底清除旧状态，解决 1872 错误
        
        CHANGE MASTER TO 
          MASTER_HOST='${MASTER_HOST}',
          MASTER_PORT=${MASTER_PORT},
          MASTER_USER='${MASTER_USER}',
          MASTER_PASSWORD='${MASTER_PASSWORD}',
          MASTER_AUTO_POSITION=1; 
          
        START SLAVE;
EOF
    echo ">>> [Fix] 配置指令已下发。"
}

# === 主循环 ===
# 每 60 秒检查一次状态，如果挂了就修
while true; do
    # 获取 Slave 状态的关键字段
    # Slave_IO_Running, Slave_SQL_Running, Last_IO_Error_Timestamp, Last_Errno
    STATUS=$(mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "SHOW SLAVE STATUS\G")
    
    IO_RUNNING=$(echo "$STATUS" | grep "Slave_IO_Running:" | awk '{print $2}')
    SQL_RUNNING=$(echo "$STATUS" | grep "Slave_SQL_Running:" | awk '{print $2}')
    LAST_ERRNO=$(echo "$STATUS" | grep "Last_IO_Errno:" | awk '{print $2}')

    echo ">>> [Monitor] $(date): IO=$IO_RUNNING, SQL=$SQL_RUNNING"

    # 情况 A: 正常运行中
    if [ "$IO_RUNNING" == "Yes" ] && [ "$SQL_RUNNING" == "Yes" ]; then
        # 一切正常，睡觉
        sleep 60
        continue
    fi

    # 情况 B: 未配置 (空状态)
    if [ -z "$IO_RUNNING" ]; then
        echo ">>> [Status] Slave 未配置。"
        reconnect_master
        sleep 10
        continue
    fi

    # 情况 C: 出现致命错误 (如 1872 Repository Error, 或 1200 Not Configured)
    # 或者处于 Connecting 状态太久(可以通过重试次数判断，这里简化处理，如果是非 Yes 状态就尝试修复)
    # 这里的策略是：只要不是 Yes，且 Tunnel 是通的，就尝试重置。
    
    echo ">>> [Status] 同步服务未运行 (IO: $IO_RUNNING, SQL: $SQL_RUNNING)。尝试自动修复..."
    reconnect_master
    
    # 修复后等待一段时间，避免死循环频繁重启
    sleep 30
done

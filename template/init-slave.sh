#!/bin/bash

# ==============================================================================
# MySQL Slave 守护进程 v4.0
# 功能: 监控同步状态，自动修复常见问题
# ==============================================================================

# 使用 MYSQL_PWD 避免命令行密码警告
export MYSQL_PWD="${MYSQL_ROOT_PASSWORD}"

LOG_PREFIX="[Monitor]"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $LOG_PREFIX $1"
}

log "守护进程启动 v4.0"
log "Master: ${MASTER_HOST}:${MASTER_PORT}"

# 等待 MySQL 就绪
log "等待 MySQL 启动..."
for i in {1..60}; do
    if mysql -u root -e "SELECT 1" >/dev/null 2>&1; then
        log "MySQL 已就绪"
        break
    fi
    if [ $i -eq 60 ]; then
        log "错误: MySQL 启动超时"
        exit 1
    fi
    sleep 2
done

# ========================================
# 函数: 检查 Master 连接
# ========================================
check_master_connection() {
    local max_retry=10
    local retry=0

    while [ $retry -lt $max_retry ]; do
        retry=$((retry + 1))

        if MYSQL_PWD="${MASTER_PASSWORD}" mysql -h "${MASTER_HOST}" -P "${MASTER_PORT}" \
            -u "${MASTER_USER}" --connect-timeout=5 -e "SELECT 1" >/dev/null 2>&1; then
            return 0
        fi

        sleep 2
    done

    return 1
}

# ========================================
# 函数: 配置 Slave
# ========================================
configure_slave() {
    log "开始配置 Slave..."

    # 1. 停止并重置
    mysql -u root -e "STOP SLAVE;" 2>/dev/null || true
    mysql -u root -e "RESET SLAVE ALL;" 2>/dev/null || true

    # 2. 配置 Master
    # 使用变量拼接避免 heredoc 的变量展开问题
    local change_master_sql="CHANGE MASTER TO MASTER_HOST='${MASTER_HOST}', MASTER_PORT=${MASTER_PORT}, MASTER_USER='${MASTER_USER}', MASTER_PASSWORD='${MASTER_PASSWORD}', MASTER_AUTO_POSITION=1"

    if ! mysql -u root -e "$change_master_sql;" 2>/dev/null; then
        log "错误: CHANGE MASTER 失败"
        return 1
    fi

    # 3. 启动 Slave
    if ! mysql -u root -e "START SLAVE;" 2>/dev/null; then
        log "错误: START SLAVE 失败"
        return 1
    fi

    log "Slave 配置完成"
    return 0
}

# ========================================
# 函数: 获取 Slave 状态
# ========================================
get_slave_status() {
    local status
    status=$(mysql -u root -e "SHOW SLAVE STATUS\G" 2>/dev/null)

    IO_RUNNING=$(echo "$status" | grep "Slave_IO_Running:" | awk '{print $2}' | tr -d '\r')
    SQL_RUNNING=$(echo "$status" | grep "Slave_SQL_Running:" | awk '{print $2}' | tr -d '\r')
    LAST_IO_ERRNO=$(echo "$status" | grep "Last_IO_Errno:" | awk '{print $2}' | tr -d '\r')
    LAST_SQL_ERRNO=$(echo "$status" | grep "Last_SQL_Errno:" | awk '{print $2}' | tr -d '\r')
    SECONDS_BEHIND=$(echo "$status" | grep "Seconds_Behind_Master:" | awk '{print $2}' | tr -d '\r')
    LAST_IO_ERROR=$(echo "$status" | grep "Last_IO_Error:" | sed 's/.*Last_IO_Error: //' | tr -d '\r')
}

# ========================================
# 函数: 检查 GTID UUID 是否匹配
# ========================================
check_gtid_uuid() {
    local local_gtid master_uuid local_uuid

    # 获取本地 GTID
    local_gtid=$(mysql -u root -N -e "SHOW GLOBAL VARIABLES LIKE 'gtid_executed';" 2>/dev/null | awk '{print $2}')

    if [ -z "$local_gtid" ] || [ "$local_gtid" = "" ]; then
        # 本地 GTID 为空，可以配置
        return 0
    fi

    # 获取本地 GTID 的 UUID
    local_uuid=$(echo "$local_gtid" | cut -d':' -f1)

    # 获取 Master UUID
    master_uuid=$(MYSQL_PWD="${MASTER_PASSWORD}" mysql -h "${MASTER_HOST}" -P "${MASTER_PORT}" \
        -u "${MASTER_USER}" -N -e "SHOW GLOBAL VARIABLES LIKE 'server_uuid';" 2>/dev/null | awk '{print $2}')

    if [ -z "$master_uuid" ]; then
        log "警告: 无法获取 Master UUID"
        return 0
    fi

    # 检查是否有多个 UUID（表示有来自多个 Master 的事务）
    if echo "$local_gtid" | grep -q ","; then
        log "警告: 本地 GTID 包含多个 UUID，可能需要重新同步"
        log "本地 GTID: $local_gtid"
        log "Master UUID: $master_uuid"
        return 2
    fi

    # 比较 UUID
    if [ "$local_uuid" != "$master_uuid" ]; then
        log "警告: UUID 不匹配"
        log "本地 UUID: $local_uuid"
        log "Master UUID: $master_uuid"
        log "这通常意味着需要重新全量同步"
        return 2
    fi

    return 0
}

# ========================================
# 主循环
# ========================================
log "进入监控循环..."

CONSECUTIVE_FAILURES=0
ERROR_1236_DETECTED=false

while true; do
    get_slave_status

    # 状态 1: 完全正常
    if [ "$IO_RUNNING" = "Yes" ] && [ "$SQL_RUNNING" = "Yes" ]; then
        log "正常运行 | IO=Yes SQL=Yes | 延迟=${SECONDS_BEHIND}s"
        CONSECUTIVE_FAILURES=0
        ERROR_1236_DETECTED=false
        sleep 60
        continue
    fi

    # 状态 2: 未配置
    if [ -z "$IO_RUNNING" ]; then
        log "Slave 未配置"

        # 检查 Master 连接
        if check_master_connection; then
            log "Master 连接正常，尝试配置..."
            configure_slave
        else
            log "Master 连接失败，等待重试"
        fi

        CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
        sleep 10
        continue
    fi

    # 状态 3: 正在连接
    if [ "$IO_RUNNING" = "Connecting" ]; then
        log "IO 线程正在连接..."
        sleep 10
        continue
    fi

    # 状态 4: 错误 1236 (GTID 不匹配)
    if [ "$LAST_IO_ERRNO" = "1236" ]; then
        if [ "$ERROR_1236_DETECTED" = false ]; then
            ERROR_1236_DETECTED=true
            log "=========================================="
            log "错误 1236: GTID/Binlog 不匹配"
            log "原因: 本地 GTID 与 Master 不一致"
            log "解决: 运行 ./quick_start_sync.sh 重新同步"
            log "=========================================="
            log "错误详情: $LAST_IO_ERROR"
        fi
        sleep 300
        continue
    fi

    # 状态 5: 其他错误
    CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
    log "同步异常 | IO=$IO_RUNNING SQL=$SQL_RUNNING | 失败次数=$CONSECUTIVE_FAILURES"

    if [ -n "$LAST_IO_ERRNO" ] && [ "$LAST_IO_ERRNO" != "0" ]; then
        log "IO 错误 ($LAST_IO_ERRNO): $LAST_IO_ERROR"
    fi

    # 尝试修复
    if [ $CONSECUTIVE_FAILURES -ge 3 ]; then
        log "连续失败 $CONSECUTIVE_FAILURES 次，尝试重新配置..."

        if check_master_connection; then
            # 检查 GTID UUID
            check_gtid_uuid
            uuid_check=$?

            if [ $uuid_check -eq 2 ]; then
                log "UUID 不匹配，需要手动重新同步"
                CONSECUTIVE_FAILURES=0
                sleep 300
                continue
            fi

            configure_slave
        fi

        CONSECUTIVE_FAILURES=0
    else
        # 简单重启 Slave
        log "尝试重启 Slave..."
        mysql -u root -e "STOP SLAVE; START SLAVE;" 2>/dev/null || true
    fi

    sleep 30
done

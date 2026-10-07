#!/bin/bash

# ==============================================================================
# MySQL Slave 守护进程 v6.0
#
# 功能:
# 1. 容器启动后等待 MySQL 就绪
# 2. 智能检测 slave 配置状态，避免误清除已有配置
# 3. 自动配置 Slave 复制（仅在未配置时）
# 4. 监控复制状态，自动修复常见问题
# 5. 与 quick_start_sync.sh 协作，检测同步锁
# ==============================================================================

export MYSQL_PWD="${MYSQL_ROOT_PASSWORD}"
export TARGET_DB_NAME="${TARGET_DB_NAME}"

LOG_FILE="/var/log/slave_monitor.log"

log() {
    local msg="$(date '+%Y-%m-%d %H:%M:%S') [Monitor] $1"
    echo "$msg" | tee -a "$LOG_FILE"
}

# ========================================
# 初始化检查
# ========================================

# 检查同步锁，如果存在则等待
log "检查同步锁..."
SYNC_LOCK="/var/run/sync.lock"
while [ -f "$SYNC_LOCK" ]; do
    log "检测到同步锁，等待同步完成..."
    sleep 5
done

log "守护进程启动 v6.0"
log "Master: ${MASTER_HOST}:${MASTER_PORT}"
log "目标库: ${TARGET_DB_NAME}"

# 等待 MySQL 就绪
log "等待 MySQL 启动..."
for i in {1..120}; do
    if mysql -u root -e "SELECT 1" >/dev/null 2>&1; then
        log "MySQL 已就绪"
        break
    fi
    if [ $i -eq 120 ]; then
        log "错误: MySQL 启动超时"
        exit 1
    fi
    sleep 2
done

# ========================================
# 函数定义
# ========================================

check_master_connection() {
    local max_retry=5
    for ((i=1; i<=max_retry; i++)); do
        if MYSQL_PWD="${MASTER_PASSWORD}" mysql -h "${MASTER_HOST}" -P "${MASTER_PORT}" \
            -u "${MASTER_USER}" --connect-timeout=5 -e "SELECT 1" >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done
    return 1
}

# 检查 slave 是否已配置（不依赖线程状态）
is_slave_configured() {
    local status=$(mysql -u root -e "SHOW SLAVE STATUS\G" 2>/dev/null)
    # 如果有任何输出（不管线程是否运行），说明已配置
    if [ -n "$status" ]; then
        return 0  # 已配置
    fi
    return 1  # 未配置
}

# 获取 slave 状态信息
get_slave_status() {
    local status=$(mysql -u root -e "SHOW SLAVE STATUS\G" 2>/dev/null)

    IO_RUNNING=$(echo "$status" | grep "Slave_IO_Running:" | awk '{print $2}' | tr -d '\r\n')
    SQL_RUNNING=$(echo "$status" | grep "Slave_SQL_Running:" | awk '{print $2}' | tr -d '\r\n')
    SECONDS_BEHIND=$(echo "$status" | grep "Seconds_Behind_Master:" | awk '{print $2}' | tr -d '\r\n')
    LAST_IO_ERRNO=$(echo "$status" | grep "Last_IO_Errno:" | awk '{print $2}' | tr -d '\r\n')
    LAST_IO_ERROR=$(echo "$status" | grep "Last_IO_Error:" | cut -d: -f2- | sed 's/^ *//')
    MASTER_HOST_CONFIG=$(echo "$status" | grep "Master_Host:" | awk '{print $2}' | tr -d '\r\n')
}

# 首次配置 slave（仅在未配置时调用）
initial_configure_slave() {
    log "首次配置 Slave..."

    # 注意：这里不执行 RESET SLAVE ALL，因为是首次配置
    # 配置 Master
    mysql -u root -e "CHANGE MASTER TO
        MASTER_HOST='${MASTER_HOST}',
        MASTER_PORT=${MASTER_PORT},
        MASTER_USER='${MASTER_USER}',
        MASTER_PASSWORD='${MASTER_PASSWORD}',
        MASTER_AUTO_POSITION=1;" 2>/dev/null

    if [ $? -ne 0 ]; then
        log "错误: CHANGE MASTER 失败"
        return 1
    fi

    # 启动 Slave
    mysql -u root -e "START SLAVE;" 2>/dev/null

    if [ $? -ne 0 ]; then
        log "错误: START SLAVE 失败"
        return 1
    fi

    log "Slave 首次配置完成"
    return 0
}

# 尝试启动已配置的 slave
try_start_slave() {
    log "尝试启动已配置的 Slave..."

    # 先检查状态
    get_slave_status

    if [ "$IO_RUNNING" = "Yes" ] && [ "$SQL_RUNNING" = "Yes" ]; then
        log "Slave 已在运行中"
        return 0
    fi

    # 尝试启动
    mysql -u root -e "START SLAVE;" 2>/dev/null

    if [ $? -eq 0 ]; then
        log "START SLAVE 执行成功"
        sleep 3
        get_slave_status
        if [ "$IO_RUNNING" = "Yes" ] && [ "$SQL_RUNNING" = "Yes" ]; then
            log "Slave 启动成功"
            return 0
        fi
    fi

    log "START SLAVE 失败或线程未启动"
    return 1
}

# 重建 slave 配置（仅在必要时调用，如 GTID 不匹配）
rebuild_slave() {
    log "重建 Slave 配置..."

    # 停止并重置
    mysql -u root -e "STOP SLAVE;" 2>/dev/null || true
    mysql -u root -e "RESET SLAVE ALL;" 2>/dev/null || true

    # 重新配置
    mysql -u root -e "CHANGE MASTER TO
        MASTER_HOST='${MASTER_HOST}',
        MASTER_PORT=${MASTER_PORT},
        MASTER_USER='${MASTER_USER}',
        MASTER_PASSWORD='${MASTER_PASSWORD}',
        MASTER_AUTO_POSITION=1;" 2>/dev/null

    if [ $? -ne 0 ]; then
        log "错误: CHANGE MASTER 失败"
        return 1
    fi

    # 启动 Slave
    mysql -u root -e "START SLAVE;" 2>/dev/null

    if [ $? -ne 0 ]; then
        log "错误: START SLAVE 失败"
        return 1
    fi

    log "Slave 重建完成"
    return 0
}

# ========================================
# 初始化配置阶段（只执行一次）
# ========================================

INIT_DONE="/var/run/slave_init.done"

if [ ! -f "$INIT_DONE" ]; then
    log "=== 初始化配置阶段 ==="

    if is_slave_configured; then
        log "检测到已有 Slave 配置，尝试启动..."
        if try_start_slave; then
            log "Slave 启动成功"
        else
            log "Slave 启动失败，等待监控循环处理"
        fi
    else
        log "Slave 未配置，检查 Master 连接..."
        if check_master_connection; then
            if initial_configure_slave; then
                log "Slave 配置成功"
            else
                log "Slave 配置失败，等待监控循环重试"
            fi
        else
            log "Master 连接失败，等待监控循环重试"
        fi
    fi

    touch "$INIT_DONE"
    log "=== 初始化配置阶段完成 ==="
fi

# ========================================
# 主循环（监控与自动修复）
# ========================================

log "进入监控循环..."

CONSECUTIVE_ERRORS=0
LAST_ERROR_TIME=0

while true; do
    # 检查同步锁
    if [ -f "$SYNC_LOCK" ]; then
        log "检测到同步锁，暂停监控..."
        sleep 10
        continue
    fi

    get_slave_status

    # 状态 1: 完全正常
    if [ "$IO_RUNNING" = "Yes" ] && [ "$SQL_RUNNING" = "Yes" ]; then
        if [ $CONSECUTIVE_ERRORS -gt 0 ]; then
            log "恢复正常 | 延迟=${SECONDS_BEHIND}s"
            CONSECUTIVE_ERRORS=0
        fi
        sleep 60
        continue
    fi

    # 状态 2: 未配置（SHOW SLAVE STATUS 返回空）
    if [ -z "$IO_RUNNING" ]; then
        log "Slave 未配置"

        if check_master_connection; then
            initial_configure_slave
        else
            log "Master 连接失败"
        fi

        CONSECUTIVE_ERRORS=$((CONSECUTIVE_ERRORS + 1))
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
        log "=========================================="
        log "错误 1236: GTID/Binlog 不匹配"
        log "需要运行: ./quick_start_sync.sh --force-clean"
        log "=========================================="
        sleep 300
        continue
    fi

    # 状态 5: 错误 13124 (Relay log metadata 损坏)
    if [ "$LAST_SQL_ERRNO" = "13124" ]; then
        log "=========================================="
        log "错误 13124: Relay log metadata 损坏"
        log "正在自动修复..."
        # 停止并重置
        mysql -u root -e "STOP SLAVE;" 2>/dev/null || true
        mysql -u root -e "RESET SLAVE ALL;" 2>/dev/null || true
        # 重新配置
        if check_master_connection; then
            mysql -u root -e "CHANGE MASTER TO
                MASTER_HOST='${MASTER_HOST}',
                MASTER_PORT=${MASTER_PORT},
                MASTER_USER='${MASTER_USER}',
                MASTER_PASSWORD='${MASTER_PASSWORD}',
                MASTER_AUTO_POSITION=1;" 2>/dev/null
            mysql -u root -e "START SLAVE;" 2>/dev/null
            log "自动修复完成，等待验证..."
        else
            log "Master 连接失败，无法自动修复"
        fi
        log "=========================================="
        CONSECUTIVE_ERRORS=0
        sleep 30
        continue
    fi

    if [ -n "$LAST_IO_ERRNO" ] && [ "$LAST_IO_ERRNO" != "0" ]; then
        log "IO 错误 ($LAST_IO_ERRNO): $LAST_IO_ERROR"
    fi

    # 尝试重启 Slave
    log "尝试重启 Slave..."
    mysql -u root -e "STOP SLAVE; START SLAVE;" 2>/dev/null || true

    # 连续失败超过阈值时重置计数器（避免日志刷屏）
    if [ $CONSECUTIVE_ERRORS -ge 10 ]; then
        log "连续失败超过 10 次，已尝试自动修复，如问题持续请检查网络或运行 ./quick_start_sync.sh"
        CONSECUTIVE_ERRORS=0
    fi

    sleep 30
done

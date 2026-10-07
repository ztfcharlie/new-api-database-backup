#!/bin/bash

# ==============================================================================
# MySQL 一键全自动同步脚本 v8.1
# 基于 v8.0 修改：
#   1. 【新增】--fresh-dump 强制重新导出
#   2. 【新增】--force-clean 删本地库 + 删缓存 dump
#   3. 【新增】dump 缓存复用：/var/lib/mysql-sync/dump.sql 存在则跳过导出
#   4. 【修改】dump 路径从 /tmp 改为 /var/lib/mysql-sync/（持久化）
#   5. 【修改】导入后不再删除 dump，供下次复用
#   6. 【新增】导出时写 .tmp 再 mv，避免半截文件被误用
# ==============================================================================

if [ -z "$BASH_VERSION" ]; then
    echo "⚠️  切换到 Bash..."
    exec bash "$0" "$@"
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ========================================
# 参数解析
# ========================================
FRESH_DUMP=false
FORCE_CLEAN=false

for arg in "$@"; do
    case "$arg" in
        --fresh-dump)
            FRESH_DUMP=true
            ;;
        --force-clean)
            FORCE_CLEAN=true
            FRESH_DUMP=true   # force-clean 隐含 fresh-dump
            ;;
        *)
            log_warn "未知参数: $arg（已忽略）"
            ;;
    esac
done

if [ ! -f .env ]; then
    log_error ".env 文件不存在"
    exit 1
fi
set -a
source .env
set +a

: ${PROJECT_NAME:?"PROJECT_NAME 未设置"}
: ${MYSQL_ROOT_PASSWORD:?"MYSQL_ROOT_PASSWORD 未设置"}
: ${TARGET_DB_NAME:?"TARGET_DB_NAME 未设置"}
: ${MASTER_PASSWORD:?"MASTER_PASSWORD 未设置"}

MASTER_USER="${MASTER_USER:-root}"
CONTAINER_DB="db_${PROJECT_NAME}"
CONTAINER_TUNNEL="tunnel_${PROJECT_NAME}"

# dump 持久化路径（容器内，需在 docker-compose.yml 挂载到宿主机 ./dump-cache）
DUMP_DIR="/var/lib/mysql-sync"
DUMP_FILE="${DUMP_DIR}/dump.sql"
DUMP_META="${DUMP_DIR}/dump.gtid"

GTID_PURGED_MODE="${GTID_PURGED_MODE:-ON}"
if [ "$GTID_PURGED_MODE" != "ON" ]; then
    log_warn "GTID_PURGED_MODE=$GTID_PURGED_MODE，本脚本要求 ON，已强制为 ON"
    GTID_PURGED_MODE="ON"
fi

echo ""
echo "========================================================"
echo "    MySQL 一键全自动同步 v8.1"
echo "========================================================"
echo "项目:      $PROJECT_NAME"
echo "目标库:    $TARGET_DB_NAME"
echo "容器:      $CONTAINER_DB"
echo "GTID模式:  $GTID_PURGED_MODE"
echo "dump路径:  $DUMP_FILE"
echo "参数:      --fresh-dump=$FRESH_DUMP  --force-clean=$FORCE_CLEAN"
echo "========================================================"

# ========================================
# 辅助函数
# ========================================
wait_mysql_ready() {
    local max_retry=${1:-30}
    local retry=0
    log_info "  等待 MySQL 可用..."
    while [ $retry -lt $max_retry ]; do
        retry=$((retry + 1))
        if docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$CONTAINER_DB" \
            mysql -u root -e "SELECT 1" >/dev/null 2>&1; then
            log_info "  MySQL 已可用 (第 $retry 次探测)"
            return 0
        fi
        sleep 1
    done
    log_error "  MySQL 在 ${max_retry} 秒内未恢复"
    return 1
}

wait_replica_stopped() {
    local max_retry=${1:-30}
    local retry=0
    while [ $retry -lt $max_retry ]; do
        local state
        state=$(docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$CONTAINER_DB" \
            mysql -u root -N -e "SHOW REPLICA STATUS\G" 2>/dev/null \
            | grep -E "Replica_(IO|SQL)_Running:" | awk '{print $2}' | tr '\n' ' ')
        if [ "$state" = "No No " ] || [ -z "$state" ]; then
            return 0
        fi
        retry=$((retry + 1))
        log_warn "  等待复制停止... (${retry}s) 状态: $state"
        sleep 1
    done
    return 1
}

stop_init_slave() {
    docker exec "$CONTAINER_DB" sh -c '
        for pid in /proc/[0-9]*; do
            cmd=$(cat $pid/cmdline 2>/dev/null | tr "\0" " ")
            case "$cmd" in
                *init-slave*) kill -9 $(basename $pid) 2>/dev/null ;;
            esac
        done
    ' 2>/dev/null || true
}

check_init_slave_running() {
    docker exec "$CONTAINER_DB" sh -c '
        found=0
        for pid in /proc/[0-9]*; do
            cmd=$(cat $pid/cmdline 2>/dev/null | tr "\0" " ")
            case "$cmd" in
                *init-slave*) found=1; break ;;
            esac
        done
        echo $found
    ' 2>/dev/null || echo "0"
}

restart_monitor() {
    log_info "重新启动 Slave 监控守护进程..."
    docker exec "$CONTAINER_DB" sh -c "rm -f /var/run/slave_init.done 2>/dev/null || true"
    docker exec "$CONTAINER_DB" sh -c "
        if [ -f /scripts/init-slave.sh ]; then
            nohup bash /scripts/init-slave.sh >> /var/log/slave_monitor.log 2>&1 &
            echo '守护进程已启动'
        else
            echo '警告：/scripts/init-slave.sh 不存在'
        fi
    " 2>/dev/null || log_warn "启动守护进程失败"
}

# ========================================
# 步骤1: 检查容器状态
# ========================================
log_info "[1/7] 检查容器状态..."

if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_DB}$"; then
    log_error "数据库容器未运行: $CONTAINER_DB"
    log_info "请先执行: docker-compose up -d"
    exit 1
fi

if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_TUNNEL}$"; then
    log_warn "隧道容器未运行，尝试启动..."
    docker start "$CONTAINER_TUNNEL" 2>/dev/null || true
    sleep 3
fi

# >>> 新增：确认 dump 持久化目录已挂载
if ! docker exec "$CONTAINER_DB" sh -c "test -d '$DUMP_DIR'" 2>/dev/null; then
    log_warn "  $DUMP_DIR 不存在，尝试创建..."
    docker exec "$CONTAINER_DB" sh -c "mkdir -p '$DUMP_DIR'" 2>/dev/null || true
    if ! docker exec "$CONTAINER_DB" sh -c "test -d '$DUMP_DIR'" 2>/dev/null; then
        log_error "  无法创建 $DUMP_DIR，请检查 docker-compose.yml 是否挂载了 ./dump-cache:/var/lib/mysql-sync"
        exit 1
    fi
fi

log_info "容器状态正常"

# ========================================
# 步骤2: 测试 Master 连接
# ========================================
log_info "[2/7] 测试 Master 连接..."

MAX_RETRY=15
RETRY=0
CONNECTED=false

while [ $RETRY -lt $MAX_RETRY ]; do
    RETRY=$((RETRY + 1))
    if docker exec -e MYSQL_PWD="$MASTER_PASSWORD" "$CONTAINER_DB" \
        mysql -h tunnel -P 3306 -u root --connect-timeout=5 \
        -e "SELECT 1" >/dev/null 2>&1; then
        CONNECTED=true
        break
    fi
    log_info "等待隧道建立... ($RETRY/$MAX_RETRY)"
    sleep 2
done

if [ "$CONNECTED" = false ]; then
    log_error "无法连接到 Master"
    echo ""
    echo "排查步骤:"
    echo "1. 检查 tunnel 日志: docker logs $CONTAINER_TUNNEL"
    echo "2. 检查 SSH 配置: SSH_HOST=$SSH_HOST"
    echo "3. 检查密码是否正确"
    exit 1
fi

log_info "Master 连接成功"

# ========================================
# 步骤3: 检查 Master GTID 配置
# ========================================
log_info "[3/7] 检查 Master GTID 配置..."

GTID_MODE=$(docker exec -e MYSQL_PWD="$MASTER_PASSWORD" "$CONTAINER_DB" \
    mysql -h tunnel -P 3306 -u root -N -e "SHOW VARIABLES LIKE 'gtid_mode';" 2>/dev/null | awk '{print $2}')

if [ "$GTID_MODE" != "ON" ]; then
    log_error "Master 未开启 GTID 模式 (当前: $GTID_MODE)"
    exit 1
fi

log_info "GTID 模式已开启"

# ========================================
# 步骤4: 检查目标数据库
# ========================================
log_info "[4/7] 检查目标数据库..."

DB_EXISTS=$(docker exec -e MYSQL_PWD="$MASTER_PASSWORD" "$CONTAINER_DB" \
    mysql -h tunnel -P 3306 -u root -N -e "SHOW DATABASES LIKE '$TARGET_DB_NAME';" 2>/dev/null)

if [ -z "$DB_EXISTS" ]; then
    log_error "Master 上不存在数据库: $TARGET_DB_NAME"
    exit 1
fi

log_info "目标数据库存在"

# ========================================
# 步骤5: 准备本地环境
# ========================================
log_info "[5/7] 准备本地环境..."

wait_mysql_ready 30 || exit 1

# >>> 【关键】创建同步锁，暂停 init-slave.sh
log_info "  创建同步锁（暂停守护进程）..."
docker exec "$CONTAINER_DB" touch /var/run/sync.lock

log_info "  等待守护进程暂停..."
sleep 12

MONITOR_TAIL=$(docker exec "$CONTAINER_DB" tail -5 /var/log/slave_monitor.log 2>/dev/null || echo "")
if echo "$MONITOR_TAIL" | grep -q "检测到同步锁\|暂停监控"; then
    log_info "  守护进程已暂停"
else
    log_warn "  未在日志中看到暂停提示，继续执行"
    echo "$MONITOR_TAIL" | tail -3
fi

log_info "  清理残留守护进程..."
stop_init_slave
sleep 2

INIT_STILL=$(check_init_slave_running)
if [ "$INIT_STILL" = "1" ]; then
    log_warn "  仍有 init-slave 进程，再次清理..."
    stop_init_slave
    sleep 2
fi

wait_mysql_ready 30 || exit 1

# 停止复制
log_info "  停止复制..."
docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$CONTAINER_DB" \
    mysql -u root -e "STOP REPLICA FOR CHANNEL '';" 2>&1 | grep -v "^mysql:" || true

if ! wait_replica_stopped 30; then
    log_error "  复制 30 秒内未能停止，可能有长事务卡住"
    log_error "  请执行 SHOW PROCESSLIST 检查 Time 很大的 Query，必要时 KILL"
    exit 1
fi
log_info "  复制已停止"

docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$CONTAINER_DB" \
    mysql -u root -e "RESET REPLICA ALL FOR CHANNEL '';" 2>&1 | grep -v "^mysql:" || true

# >>> --force-clean：额外清理缓存的 dump
if [ "$FORCE_CLEAN" = true ]; then
    log_warn "  --force-clean：清理缓存的 dump 文件..."
    docker exec "$CONTAINER_DB" sh -c "rm -f '$DUMP_FILE' '$DUMP_FILE.tmp' '$DUMP_META'" 2>/dev/null || true
fi

# 删除本地数据库
log_info "  检查本地数据库..."
DB_EXISTS_LOCAL=$(docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$CONTAINER_DB" \
    mysql -u root -N -e "SHOW DATABASES LIKE '$TARGET_DB_NAME';" 2>/dev/null)

if [ -n "$DB_EXISTS_LOCAL" ]; then
    log_warn "  删除本地数据库..."
    docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$CONTAINER_DB" \
        mysql -u root -e "DROP DATABASE IF EXISTS \`$TARGET_DB_NAME\`;" 2>/dev/null || true
    sleep 2
fi

# RESET MASTER（带重试）
log_info "  重置 GTID..."
RESET_SUCCESS=false
for i in 1 2 3 4 5; do
    if docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$CONTAINER_DB" \
        mysql -u root -e "RESET MASTER;" 2>/dev/null; then
        RESET_SUCCESS=true
        log_info "  RESET MASTER 成功 (第 $i 次尝试)"
        break
    fi
    log_warn "  RESET MASTER 失败，重试 ($i/5)..."
    wait_mysql_ready 10 || true
done

if [ "$RESET_SUCCESS" = false ]; then
    log_error "  RESET MASTER 最终失败，请手动检查 MySQL 状态"
    exit 1
fi

CLEANED_GTID=$(docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$CONTAINER_DB" \
    mysql -u root -N -e "SELECT @@GLOBAL.gtid_executed;" 2>/dev/null)
log_info "  当前本地 gtid_executed: ${CLEANED_GTID:-空}"

if [ -n "$CLEANED_GTID" ]; then
    log_error "  RESET MASTER 后 gtid_executed 仍非空，异常退出"
    exit 1
fi

log_info "本地环境准备完成"

# ========================================
# 步骤6: 数据传输
# ========================================
log_info "[6/7] 开始数据传输..."

DB_SIZE=$(docker exec -e MYSQL_PWD="$MASTER_PASSWORD" "$CONTAINER_DB" \
    mysql -h tunnel -P 3306 -u root -N -e \
    "SELECT ROUND(SUM(data_length + index_length) / 1024 / 1024, 2) FROM information_schema.tables WHERE table_schema = '$TARGET_DB_NAME';" 2>/dev/null)
log_info "数据库大小约: ${DB_SIZE:-未知} MB"

# ----------------------------------------
# 步骤 6a: 导出（可复用缓存）
# ----------------------------------------
DUMP_EXISTS=false
if docker exec "$CONTAINER_DB" sh -c "test -s '$DUMP_FILE'" 2>/dev/null; then
    DUMP_EXISTS=true
fi

NEED_DUMP=false
if [ "$FRESH_DUMP" = true ]; then
    log_info "步骤 6a: --fresh-dump 已指定，强制重新导出..."
    NEED_DUMP=true
elif [ "$DUMP_EXISTS" = true ]; then
    CACHED_SIZE_MB=$(docker exec "$CONTAINER_DB" sh -c "stat -c%s '$DUMP_FILE' 2>/dev/null || echo 0" | awk '{print int($1/1024/1024)}')
    CACHED_TIME=$(docker exec "$CONTAINER_DB" sh -c "stat -c%y '$DUMP_FILE' 2>/dev/null || echo 未知")
    log_warn "步骤 6a: 发现缓存的 dump 文件，跳过导出"
    log_warn "  大小: ${CACHED_SIZE_MB} MB"
    log_warn "  时间: $CACHED_TIME"
    log_warn "  如需重新导出，请加参数: --fresh-dump"
    NEED_DUMP=false
else
    log_info "步骤 6a: 未发现可用 dump，开始导出..."
    NEED_DUMP=true
fi

if [ "$NEED_DUMP" = true ]; then
    docker exec "$CONTAINER_DB" bash -c '
    PROD_PWD="'"$MASTER_PASSWORD"'"
    TARGET_DB="'"$TARGET_DB_NAME"'"
    GTID_MODE="'"$GTID_PURGED_MODE"'"
    DUMP_FILE="'"$DUMP_FILE"'"

    echo "开始导出: $(date)"
    echo "GTID_PURGED 模式: $GTID_MODE"

    mkdir -p "$(dirname "$DUMP_FILE")"

    # 先写 .tmp，导出成功后再 mv，避免半截文件被下次误用
    MYSQL_PWD="$PROD_PWD" mysqldump -h tunnel -P 3306 -u root \
        --databases "$TARGET_DB" \
        --single-transaction \
        --quick \
        --lock-tables=false \
        --source-data=2 \
        --set-gtid-purged="$GTID_MODE" \
        --triggers \
        --routines \
        --events \
        --add-drop-database \
        > "$DUMP_FILE.tmp" 2>/tmp/dump_error.log &

    DUMP_PID=$!

    while kill -0 $DUMP_PID 2>/dev/null; do
        if [ -f "$DUMP_FILE.tmp" ]; then
            SIZE=$(stat -c%s "$DUMP_FILE.tmp" 2>/dev/null || echo "0")
            SIZE_MB=$((SIZE / 1024 / 1024))
            echo "  已导出: ${SIZE_MB} MB..."
        fi
        sleep 5
    done

    wait $DUMP_PID
    DUMP_EXIT=$?

    echo "结束导出: $(date)"
    echo "导出退出码: $DUMP_EXIT"

    if [ $DUMP_EXIT -ne 0 ]; then
        echo "=== mysqldump 错误 ==="
        cat /tmp/dump_error.log 2>/dev/null
        rm -f "$DUMP_FILE.tmp"
        exit $DUMP_EXIT
    fi

    # 原子替换
    mv "$DUMP_FILE.tmp" "$DUMP_FILE"

    DUMP_SIZE=$(stat -c%s "$DUMP_FILE" 2>/dev/null || echo "0")
    DUMP_SIZE_MB=$((DUMP_SIZE / 1024 / 1024))
    echo "导出完成，大小: ${DUMP_SIZE_MB} MB"
    '

    DUMP_EXIT=$?
    if [ $DUMP_EXIT -ne 0 ]; then
        log_error "数据导出失败"
        exit 1
    fi

    log_info "数据导出成功"

    # 记录导出时刻 Master 的 GTID，供下次判断
    MASTER_GTID_NOW=$(docker exec -e MYSQL_PWD="$MASTER_PASSWORD" "$CONTAINER_DB" \
        mysql -h tunnel -P 3306 -u root -N -e "SELECT @@GLOBAL.gtid_executed;" 2>/dev/null)
    docker exec "$CONTAINER_DB" sh -c "echo '$MASTER_GTID_NOW' > '$DUMP_META'" 2>/dev/null || true
    log_info "  dump 对应的 Master GTID 起点已记录到 $DUMP_META"
else
    log_info "步骤 6a: 复用缓存 dump"
fi

GTID_LINE=$(docker exec "$CONTAINER_DB" sh -c "grep -m1 'GTID_PURGED' '$DUMP_FILE' 2>/dev/null" || true)
if [ -n "$GTID_LINE" ]; then
    log_info "  dump 中包含 GTID 起点信息"
    echo "  $GTID_LINE" | head -c 200
    echo ""
else
    log_warn "  dump 中未找到 GTID_PURGED，可能影响复制对齐"
fi

# >>> 导入前二次校验 gtid_executed 仍为空
GTID_BEFORE_IMPORT=$(docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$CONTAINER_DB" \
    mysql -u root -N -e "SELECT @@GLOBAL.gtid_executed;" 2>/dev/null)
if [ -n "$GTID_BEFORE_IMPORT" ]; then
    log_error "  导入前 gtid_executed 非空: $GTID_BEFORE_IMPORT"
    log_error "  有东西在持续写入 GTID，请检查 init-slave.sh"
    exit 1
fi
log_info "  导入前 gtid_executed 确认为空"

# ----------------------------------------
# 步骤 6b: 导入（不删除 dump）
# ----------------------------------------
log_info "步骤 6b: 导入数据到本地..."

docker exec "$CONTAINER_DB" bash -c '
LOCAL_PWD="'"$MYSQL_ROOT_PASSWORD"'"
DUMP_FILE="'"$DUMP_FILE"'"
export MYSQL_PWD="$LOCAL_PWD"

echo "开始导入: $(date)"

mysql -u root < "$DUMP_FILE" 2>/tmp/import_error.log &

IMPORT_PID=$!

while kill -0 $IMPORT_PID 2>/dev/null; do
    echo "  正在导入..."
    sleep 5
done

wait $IMPORT_PID
IMPORT_EXIT=$?

echo "结束导入: $(date)"
echo "导入退出码: $IMPORT_EXIT"

if [ $IMPORT_EXIT -ne 0 ]; then
    echo "=== mysql 导入错误 ==="
    cat /tmp/import_error.log 2>/dev/null
    exit $IMPORT_EXIT
fi

# 保留 dump 文件，供下次复用
echo "导入完成（dump 文件已保留：$DUMP_FILE）"
exit $IMPORT_EXIT
'

IMPORT_EXIT=$?
if [ $IMPORT_EXIT -ne 0 ]; then
    log_error "数据导入失败"
    exit 1
fi

log_info "数据传输成功"

IMPORTED_GTID=$(docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$CONTAINER_DB" \
    mysql -u root -N -e "SELECT @@GLOBAL.gtid_executed;" 2>/dev/null)
log_info "导入后本地 gtid_executed: ${IMPORTED_GTID:-空}"

if [ -z "$IMPORTED_GTID" ]; then
    log_warn "  导入后 gtid_executed 为空，可能 dump 未带 GTID 信息"
fi

# ========================================
# 步骤7: 配置并启动复制
# ========================================
log_info "[7/7] 配置复制同步..."

wait_mysql_ready 30 || exit 1

CHANGE_REPLICA_SQL=$(printf "STOP REPLICA; RESET REPLICA ALL; CHANGE REPLICATION SOURCE TO SOURCE_HOST='tunnel', SOURCE_PORT=3306, SOURCE_USER='%s', SOURCE_PASSWORD='%s', SOURCE_AUTO_POSITION=1; START REPLICA;" "$MASTER_USER" "$MASTER_PASSWORD")

docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$CONTAINER_DB" mysql -u root -e "$CHANGE_REPLICA_SQL" 2>/dev/null

if [ $? -ne 0 ]; then
    log_error "复制配置失败"
    exit 1
fi

log_info "复制配置完成"

log_info "  删除同步锁，恢复守护进程..."
docker exec "$CONTAINER_DB" rm -f /var/run/sync.lock

sleep 3

# ========================================
# 验证同步状态
# ========================================
echo ""
log_info "等待同步建立..."
sleep 5

STATUS=$(docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$CONTAINER_DB" mysql -u root -e "SHOW REPLICA STATUS\G" 2>/dev/null)

IO_RUNNING=$(echo "$STATUS" | grep -E "Replica_IO_Running:" | awk '{print $2}' | tr -d '\r')
SQL_RUNNING=$(echo "$STATUS" | grep -E "Replica_SQL_Running:" | awk '{print $2}' | tr -d '\r')
SECONDS_BEHIND=$(echo "$STATUS" | grep "Seconds_Behind_Source:" | awk '{print $2}' | tr -d '\r')
LAST_IO_ERRNO=$(echo "$STATUS" | grep "Last_IO_Errno:" | awk '{print $2}' | tr -d '\r')
LAST_IO_ERROR=$(echo "$STATUS" | grep "Last_IO_Error:" | sed 's/.*Last_IO_Error: //' | tr -d '\r')
LAST_SQL_ERRNO=$(echo "$STATUS" | grep "Last_SQL_Errno:" | awk '{print $2}' | tr -d '\r')
LAST_SQL_ERROR=$(echo "$STATUS" | grep "Last_SQL_Error:" | sed 's/.*Last_SQL_Error: //' | tr -d '\r')

if [ -z "$IO_RUNNING" ]; then
    IO_RUNNING=$(echo "$STATUS" | grep "Slave_IO_Running:" | awk '{print $2}' | tr -d '\r')
fi
if [ -z "$SQL_RUNNING" ]; then
    SQL_RUNNING=$(echo "$STATUS" | grep "Slave_SQL_Running:" | awk '{print $2}' | tr -d '\r')
fi
if [ -z "$SECONDS_BEHIND" ]; then
    SECONDS_BEHIND=$(echo "$STATUS" | grep "Seconds_Behind_Master:" | awk '{print $2}' | tr -d '\r')
fi

SLAVE_GTID=$(docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$CONTAINER_DB" mysql -u root -N -e "SHOW GLOBAL VARIABLES LIKE 'gtid_executed';" 2>/dev/null | awk '{print $2}')

echo ""
echo "========================================================"
echo "    同步状态报告"
echo "========================================================"
echo "IO 线程:      $IO_RUNNING"
echo "SQL 线程:     $SQL_RUNNING"
echo "延迟秒数:     ${SECONDS_BEHIND:-N/A}"
echo "本地 GTID:    ${SLAVE_GTID:-空}"
echo "========================================================"

if [ "$IO_RUNNING" = "Yes" ] && [ "$SQL_RUNNING" = "Yes" ]; then
    echo ""
    log_info "🎉 同步成功！"
    if [ "$SECONDS_BEHIND" = "0" ]; then
        log_info "完全同步，无延迟"
    fi
    exit 0

elif [ "$IO_RUNNING" = "Connecting" ]; then
    log_warn "IO 线程正在连接..."
    log_info "请等待几秒后运行: ./check_sync_status.sh"
    exit 0

else
    log_error "同步异常！"
    if [ -n "$LAST_IO_ERRNO" ] && [ "$LAST_IO_ERRNO" != "0" ]; then
        echo "IO 错误 ($LAST_IO_ERRNO): $LAST_IO_ERROR"
    fi
    if [ -n "$LAST_SQL_ERRNO" ] && [ "$LAST_SQL_ERRNO" != "0" ]; then
        echo "SQL 错误 ($LAST_SQL_ERRNO): $LAST_SQL_ERROR"
    fi
    echo ""
    echo "错误码说明:"
    echo "  1045 - 认证失败"
    echo "  1236 - GTID 不匹配"
    echo "  2003 - 连接失败"
    echo "  1032 - 从库找不到记录"
    echo "  1062 - 主键冲突"
    exit 1
fi


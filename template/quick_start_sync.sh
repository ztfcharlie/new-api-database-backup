#!/bin/bash

# ==============================================================================
# 真正的一键全自动同步脚本 v4.0
# 彻底重写，解决所有已知问题
# ==============================================================================

# 强制使用 Bash
if [ -z "$BASH_VERSION" ]; then
    echo "⚠️  检测到当前 Shell 不是 Bash，正在切换到 Bash..."
    exec bash "$0" "$@"
fi

# 不要 set -e，我们要手动处理错误

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# 1. 加载环境变量
if [ ! -f .env ]; then
    log_error "当前目录下未找到 .env 文件"
    exit 1
fi
set -a
source .env
set +a

# 检查必要变量
MISSING_VARS=""
[ -z "$PROJECT_NAME" ] && MISSING_VARS="$MISSING_VARS PROJECT_NAME"
[ -z "$MYSQL_ROOT_PASSWORD" ] && MISSING_VARS="$MISSING_VARS MYSQL_ROOT_PASSWORD"
[ -z "$TARGET_DB_NAME" ] && MISSING_VARS="$MISSING_VARS TARGET_DB_NAME"

if [ -n "$MISSING_VARS" ]; then
    log_error ".env 配置不完整，缺少:$MISSING_VARS"
    exit 1
fi

# 设置默认值
MASTER_USER="${MASTER_USER:-root}"
MASTER_HOST="${MASTER_HOST:-tunnel}"
MASTER_PORT="${MASTER_PORT:-3306}"
SERVER_ID="${SERVER_ID:-100}"

CONTAINER_DB="backup_${PROJECT_NAME}"
CONTAINER_TUNNEL="tunnel_${PROJECT_NAME}"

echo "========================================================"
echo "    MySQL 一键全自动同步 v4.0"
echo "========================================================"
echo "项目:      $PROJECT_NAME"
echo "目标库:    $TARGET_DB_NAME"
echo "容器:      $CONTAINER_DB"
echo "Server ID: $SERVER_ID"
echo "========================================================"
echo ""

# ========================================
# 步骤1: 检查容器状态
# ========================================
log_info "[1/8] 检查容器状态..."

if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_DB}$"; then
    log_error "数据库容器未运行: $CONTAINER_DB"
    log_info "请先执行: docker-compose up -d"
    exit 1
fi

if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_TUNNEL}$"; then
    log_warn "隧道容器未运行: $CONTAINER_TUNNEL"
    log_info "尝试启动..."
    docker start "$CONTAINER_TUNNEL" 2>/dev/null || true
    sleep 3
fi

log_info "容器状态正常"

# ========================================
# 步骤2: 获取 Master 密码
# ========================================
log_info "[2/8] 获取 Master 密码..."

# 完全自动化：只要 .env 中配置了 MASTER_PASSWORD 就直接使用
if [ -n "$MASTER_PASSWORD" ]; then
    PROD_DB_PASSWORD="$MASTER_PASSWORD"
    log_info "使用 .env 中配置的 MASTER_PASSWORD"
else
    echo ""
    echo "请输入生产库(Master)的密码:"
    read -s -p "密码: " PROD_DB_PASSWORD
    echo ""
    if [ -z "$PROD_DB_PASSWORD" ]; then
        log_error "密码不能为空"
        exit 1
    fi
fi

# ========================================
# 步骤3: 测试 Master 连接
# ========================================
log_info "[3/8] 测试 Master 连接..."

# 等待隧道建立
MAX_RETRY=15
RETRY=0
CONNECTED=false

while [ $RETRY -lt $MAX_RETRY ]; do
    RETRY=$((RETRY + 1))

    # 使用 mysql 直接测试连接
    if docker exec -e MYSQL_PWD="$PROD_DB_PASSWORD" "$CONTAINER_DB" \
        mysql -h tunnel -P 3306 -u root --connect-timeout=5 \
        -e "SELECT 1" >/dev/null 2>&1; then
        CONNECTED=true
        break
    fi

    log_info "等待隧道建立... ($RETRY/$MAX_RETRY)"
    sleep 2
done

if [ "$CONNECTED" = false ]; then
    log_error "无法连接到 Master 数据库"
    echo ""
    echo "排查步骤:"
    echo "1. 检查 tunnel 日志: docker logs $CONTAINER_TUNNEL"
    echo "2. 检查 SSH 配置: SSH_HOST=$SSH_HOST, SSH_PORT=$SSH_PORT"
    echo "3. 检查密码是否正确"
    echo "4. 检查远程端口: REMOTE_DB_PORT=$REMOTE_DB_PORT"
    exit 1
fi

log_info "Master 连接成功"

# ========================================
# 步骤4: 检查 Master 是否开启 GTID
# ========================================
log_info "[4/8] 检查 Master GTID 配置..."

GTID_MODE=$(docker exec -e MYSQL_PWD="$PROD_DB_PASSWORD" "$CONTAINER_DB" \
    mysql -h tunnel -P 3306 -u root -N -e "SHOW GLOBAL VARIABLES LIKE 'gtid_mode';" 2>/dev/null | awk '{print $2}')

if [ "$GTID_MODE" != "ON" ]; then
    log_error "Master 未开启 GTID 模式 (当前: $GTID_MODE)"
    log_error "请在 Master 的 my.cnf 中添加:"
    echo "  gtid-mode=ON"
    echo "  enforce-gtid-consistency=ON"
    exit 1
fi

log_info "GTID 模式已开启"

# ========================================
# 步骤5: 检查目标数据库是否存在
# ========================================
log_info "[5/8] 检查目标数据库..."

DB_EXISTS_ON_MASTER=$(docker exec -e MYSQL_PWD="$PROD_DB_PASSWORD" "$CONTAINER_DB" \
    mysql -h tunnel -P 3306 -u root -N -e "SHOW DATABASES LIKE '$TARGET_DB_NAME';" 2>/dev/null)

if [ -z "$DB_EXISTS_ON_MASTER" ]; then
    log_error "Master 上不存在数据库: $TARGET_DB_NAME"
    log_info "请确认数据库名称是否正确"
    exit 1
fi

log_info "目标数据库存在: $TARGET_DB_NAME"

# ========================================
# 步骤6: 停止守护进程并重置本地状态
# ========================================
log_info "[6/8] 准备本地环境..."

# 停止守护进程
docker exec "$CONTAINER_DB" sh -c "pkill -9 -f init-slave.sh 2>/dev/null || true" 2>/dev/null

# 停止 Slave
docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$CONTAINER_DB" \
    mysql -u root -e "STOP SLAVE;" 2>/dev/null || true

# 重置 Slave
docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$CONTAINER_DB" \
    mysql -u root -e "RESET SLAVE ALL;" 2>/dev/null || true

# 检查本地是否已有数据库
DB_EXISTS_LOCAL=$(docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$CONTAINER_DB" \
    mysql -u root -N -e "SHOW DATABASES LIKE '$TARGET_DB_NAME';" 2>/dev/null)

if [ -n "$DB_EXISTS_LOCAL" ]; then
    log_warn "本地已存在数据库: $TARGET_DB_NAME"
    echo ""
    read -p "是否删除并重新同步? (y/n): " CONFIRM
    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
        log_error "用户取消操作"
        exit 1
    fi

    log_info "删除本地数据库..."
    docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$CONTAINER_DB" \
        mysql -u root -e "DROP DATABASE IF EXISTS \`$TARGET_DB_NAME\`;" 2>/dev/null
fi

# 重置本地 GTID
log_info "重置本地 GTID..."
docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$CONTAINER_DB" \
    mysql -u root -e "RESET MASTER;" 2>/dev/null || true

log_info "本地环境准备完成"

# ========================================
# 步骤7: 数据传输 (核心步骤) - 分两步执行更可靠
# ========================================
log_info "[7/8] 开始数据传输 (可能需要几分钟)..."

# 步骤 7a: 导出数据到容器内的临时文件
log_info "步骤 7a: 从 Master 导出数据..."

docker exec "$CONTAINER_DB" bash -c '
PROD_PWD="'"$PROD_DB_PASSWORD"'"
TARGET_DB="'"$TARGET_DB_NAME"'"

echo "开始导出: $(date)"

# 导出到临时文件
MYSQL_PWD="$PROD_PWD" mysqldump -h tunnel -P 3306 -u root \
    --databases "$TARGET_DB" \
    --single-transaction \
    --master-data=2 \
    --set-gtid-purged=AUTO \
    --triggers \
    --routines \
    --events \
    --add-drop-database \
    > /tmp/dump.sql 2>/tmp/mysqldump_error.log

DUMP_EXIT=$?
echo "结束导出: $(date)"
echo "导出退出码: $DUMP_EXIT"

if [ $DUMP_EXIT -ne 0 ]; then
    echo "=== mysqldump 错误 ==="
    cat /tmp/mysqldump_error.log
    exit $DUMP_EXIT
fi

# 检查文件大小
DUMP_SIZE=$(stat -c%s /tmp/dump.sql 2>/dev/null || echo "unknown")
echo "导出文件大小: $DUMP_SIZE bytes"

exit $DUMP_EXIT
'

DUMP_EXIT=$?

if [ $DUMP_EXIT -ne 0 ]; then
    log_error "数据导出失败"
    docker exec "$CONTAINER_DB" cat /tmp/mysqldump_error.log 2>/dev/null
    exit 1
fi

log_info "数据导出成功"

# 步骤 7b: 导入数据
log_info "步骤 7b: 导入数据到本地..."

docker exec "$CONTAINER_DB" bash -c '
MYSQL_PWD="'"$MYSQL_ROOT_PASSWORD"'"
export MYSQL_PWD

echo "开始导入: $(date)"

mysql -u root < /tmp/dump.sql 2>/tmp/mysql_import_error.log

IMPORT_EXIT=$?
echo "结束导入: $(date)"
echo "导入退出码: $IMPORT_EXIT"

if [ $IMPORT_EXIT -ne 0 ]; then
    echo "=== mysql 导入错误 ==="
    cat /tmp/mysql_import_error.log
    exit $IMPORT_EXIT
fi

# 清理临时文件
rm -f /tmp/dump.sql

exit $IMPORT_EXIT
'

IMPORT_EXIT=$?

if [ $IMPORT_EXIT -ne 0 ]; then
    log_error "数据导入失败"
    docker exec "$CONTAINER_DB" cat /tmp/mysql_import_error.log 2>/dev/null
    exit 1
fi

log_info "数据传输成功"

# ========================================
# 步骤8: 配置并启动 Slave
# ========================================
log_info "[8/8] 配置 Slave 同步..."

# 使用单引号 heredoc 避免变量展开问题
# 注意: 这里不能用变量，必须硬编码或使用其他方式传递密码
docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$CONTAINER_DB" mysql -u root << 'SQLEOF'
STOP SLAVE;
RESET SLAVE ALL;
SQLEOF

# 单独执行 CHANGE MASTER，使用环境变量传递密码
docker exec \
    -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" \
    -e MASTER_USER="$MASTER_USER" \
    -e MASTER_PASSWORD="$MASTER_PASSWORD" \
    "$CONTAINER_DB" mysql -u root << 'SQLEOF'
SET @master_user = IFNULL(@@SESSION.sysvar_statement_truncate_len, 'root');
SET @master_pass = '';
SQLEOF

# 使用 printf 避免 heredoc 的变量展开问题
CHANGE_MASTER_SQL=$(printf "STOP SLAVE; RESET SLAVE ALL; CHANGE MASTER TO MASTER_HOST='tunnel', MASTER_PORT=3306, MASTER_USER='%s', MASTER_PASSWORD='%s', MASTER_AUTO_POSITION=1; START SLAVE;" "$MASTER_USER" "$MASTER_PASSWORD")

docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$CONTAINER_DB" mysql -u root -e "$CHANGE_MASTER_SQL" 2>/dev/null

if [ $? -ne 0 ]; then
    log_error "Slave 配置失败"
    docker restart "$CONTAINER_DB"
    exit 1
fi

log_info "Slave 配置完成"

# ========================================
# 验证同步状态
# ========================================
echo ""
log_info "等待同步建立..."
sleep 5

# 获取状态
STATUS=$(docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$CONTAINER_DB" mysql -u root -e "SHOW SLAVE STATUS\G" 2>/dev/null)

IO_RUNNING=$(echo "$STATUS" | grep "Slave_IO_Running:" | awk '{print $2}' | tr -d '\r')
SQL_RUNNING=$(echo "$STATUS" | grep "Slave_SQL_Running:" | awk '{print $2}' | tr -d '\r')
SECONDS_BEHIND=$(echo "$STATUS" | grep "Seconds_Behind_Master:" | awk '{print $2}' | tr -d '\r')
LAST_IO_ERRNO=$(echo "$STATUS" | grep "Last_IO_Errno:" | awk '{print $2}' | tr -d '\r')
LAST_IO_ERROR=$(echo "$STATUS" | grep "Last_IO_Error:" | sed 's/.*Last_IO_Error: //' | tr -d '\r')
LAST_SQL_ERROR=$(echo "$STATUS" | grep "Last_SQL_Error:" | sed 's/.*Last_SQL_Error: //' | tr -d '\r')

# 获取 GTID 信息
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
    log_info "🎉 同步成功！IO 和 SQL 线程都在运行"

    if [ "$SECONDS_BEHIND" = "0" ]; then
        log_info "完全同步，无延迟"
    else
        log_info "有延迟 (${SECONDS_BEHIND}秒)，Slave 正在追赶"
    fi

elif [ "$IO_RUNNING" = "Connecting" ]; then
    echo ""
    log_warn "IO 线程正在连接中..."
    log_info "请等待几秒后运行: ./check_sync_status.sh"

else
    echo ""
    log_error "同步异常！"

    if [ -n "$LAST_IO_ERRNO" ] && [ "$LAST_IO_ERRNO" != "0" ]; then
        echo ""
        echo "IO 错误 ($LAST_IO_ERRNO):"
        echo "  $LAST_IO_ERROR"
    fi

    if [ -n "$LAST_SQL_ERROR" ]; then
        echo ""
        echo "SQL 错误:"
        echo "  $LAST_SQL_ERROR"
    fi

    echo ""
    echo "错误码说明:"
    echo "  1045 - 认证失败，检查 MASTER_PASSWORD"
    echo "  1236 - GTID/Binlog 不匹配，需要重新全量同步"
    echo "  2003 - 连接失败，检查 tunnel 容器"
    echo "  1872 - Repository 错误，需要 RESET SLAVE ALL"
fi

echo ""
echo "========================================================"
echo "后续操作:"
echo "  查看状态: ./check_sync_status.sh"
echo "  查看日志: docker exec $CONTAINER_DB cat /var/log/slave_monitor.log"
echo "  重启容器: docker restart $CONTAINER_DB (自动恢复同步)"
echo "========================================================"

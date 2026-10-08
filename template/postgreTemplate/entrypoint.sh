#!/bin/bash

set -e

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [entrypoint] $1"; }

: ${MASTER_USER:?"MASTER_USER 未设置"}
: ${MASTER_PASSWORD:?"MASTER_PASSWORD 未设置"}
: ${POSTGRES_USER:?"POSTGRES_USER 未设置"}
: ${POSTGRES_PASSWORD:?"POSTGRES_PASSWORD 未设置"}
: ${REPL_USER:?"REPL_USER 未设置"}
: ${REPL_PASSWORD:?"REPL_PASSWORD 未设置"}
: ${PRIMARY_HOST:?"PRIMARY_HOST 未设置"}
: ${PRIMARY_PORT:?"PRIMARY_PORT 未设置"}

DATA_DIR="/var/lib/postgresql/data"

log "========================================"
log "PostgreSQL 备库启动"
log "主库: ${PRIMARY_HOST}:${PRIMARY_PORT}"
log "主库用户: ${MASTER_USER}"
log "复制用户: ${REPL_USER}"
log "备库用户: ${POSTGRES_USER}"
log "========================================"

mkdir -p "$DATA_DIR"
chown -R postgres:postgres "$DATA_DIR"
chmod 700 "$DATA_DIR"

# ========================================
# 数据目录为空 → 从主库拉一份基础备份
# ========================================
if [ ! -f "$DATA_DIR/PG_VERSION" ]; then
    log "数据目录为空，等待主库就绪..."

    RETRY=0
    MAX_RETRY=150
    until PGPASSWORD="$MASTER_PASSWORD" psql -h "$PRIMARY_HOST" -p "$PRIMARY_PORT" \
        -U "$MASTER_USER" -d postgres -c "SELECT 1" >/dev/null 2>&1; do
        RETRY=$((RETRY + 1))
        if [ $RETRY -ge $MAX_RETRY ]; then
            log "错误：主库 $((MAX_RETRY * 2)) 秒内未就绪"
            log "最后一次错误："
            PGPASSWORD="$MASTER_PASSWORD" psql -h "$PRIMARY_HOST" -p "$PRIMARY_PORT" \
                -U "$MASTER_USER" -d postgres -c "SELECT 1" 2>&1 | tail -5
            exit 1
        fi
        if [ $((RETRY % 10)) -eq 0 ]; then
            log "  等待主库... ($RETRY/$MAX_RETRY)"
        fi
        sleep 2
    done
    log "主库已就绪"

    log "创建复制用户和复制槽..."

    PGPASSWORD="$MASTER_PASSWORD" psql -h "$PRIMARY_HOST" -p "$PRIMARY_PORT" \
        -U "$MASTER_USER" -d postgres <<-EOSQL
        DO \$\$
        BEGIN
            IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${REPL_USER}') THEN
                CREATE ROLE ${REPL_USER} WITH REPLICATION LOGIN PASSWORD '${REPL_PASSWORD}';
            END IF;
        END
        \$\$;
EOSQL

    PGPASSWORD="$MASTER_PASSWORD" psql -h "$PRIMARY_HOST" -p "$PRIMARY_PORT" \
        -U "$MASTER_USER" -d postgres <<-EOSQL
        SELECT pg_create_physical_replication_slot('replica1_slot')
        WHERE NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name = 'replica1_slot');
EOSQL

    log "执行 pg_basebackup..."

    rm -rf "${DATA_DIR:?}"/*

    PGPASSWORD="$REPL_PASSWORD" pg_basebackup \
        -h "$PRIMARY_HOST" \
        -p "$PRIMARY_PORT" \
        -U "$REPL_USER" \
        -D "$DATA_DIR" \
        -Fp -Xs -P -R -S replica1_slot

    log "pg_basebackup 完成"

    chown -R postgres:postgres "$DATA_DIR"
else
    log "数据目录已存在，跳过 basebackup"
fi

# ========================================
# 启动 PostgreSQL
# ========================================
log "启动 PostgreSQL..."

exec su postgres -c "postgres -D $DATA_DIR"


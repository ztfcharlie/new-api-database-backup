#!/bin/bash

# ==============================================================================
# MySQL 从库恢复脚本 (配合 backup_physical.sh 使用)
# 功能：解压(xbstream) -> 解密(Decompress) -> 准备数据(Prepare) -> 修正权限 -> 输出同步坐标
# ==============================================================================

# --- 配置区域 ---
# XtraBackup 镜像版本 (保持与备份时一致)
XB_IMAGE="percona/percona-xtrabackup:8.0"
# ----------------

# 检查参数
if [ $# -lt 2 ]; then
  echo "用法: $0 [备份包路径] [目标数据目录]"
  echo "示例: $0 ./backups/mysql_full.xbstream.gz /www/mysql_slave_data"
  exit 1
fi

BACKUP_FILE="$1"
TARGET_DIR="$2"

# 绝对路径转换 (为了 Docker 挂载)
BACKUP_FILE_ABS=$(realpath "$BACKUP_FILE")
TARGET_DIR_ABS=$(realpath "$TARGET_DIR")

# 1. 安全确认
echo "--------------------------------------------------------"
echo "⚠️  警告: 即将执行恢复操作"
echo "备份文件: $BACKUP_FILE_ABS"
echo "目标目录: $TARGET_DIR_ABS"
echo "⚠️  注意: 目标目录内的【所有现有数据】将被永久删除！"
echo "--------------------------------------------------------"
read -p "确认继续吗? (输入 yes 继续): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
  echo "已取消。"
  exit 0
fi

# 2. 清理并解压
echo "[1/5] 正在清理目标目录..."
# 确保目录存在
mkdir -p "$TARGET_DIR_ABS"
# 清空目录
rm -rf "$TARGET_DIR_ABS"/*

echo "[2/5] 正在解压备份包 (xbstream)..."
# 关键修改：宿主机 gunzip -> 管道 -> 容器内 xbstream -x
# 这样可以处理 .gz 压缩的 xbstream 流
zcat "$BACKUP_FILE_ABS" | docker run --rm \
  -i \
  -v "$TARGET_DIR_ABS":/target \
  "$XB_IMAGE" \
  xbstream -x -C /target

if [ $? -ne 0 ]; then
  echo "❌ 解包失败，请检查备份包是否完整。"
  exit 1
fi

# 3. 数据处理 (Decompress + Prepare)
echo "[3/5] 正在通过 Docker 处理数据 (解压内部压缩 + 应用日志)..."
# 注意：备份时用了 --compress，所以这里必须先 --decompress
docker run --rm \
  -v "$TARGET_DIR_ABS":/backup \
  "$XB_IMAGE" \
  /bin/bash -c "
    echo '>> 开始去除 qpress 压缩...' && \
    xtrabackup --decompress --target-dir=/backup --remove-original && \
    echo '>> 开始 Prepare (回放事务日志)...' && \
    xtrabackup --prepare --target-dir=/backup
  "

if [ $? -ne 0 ]; then
  echo "❌ XtraBackup 处理失败！"
  exit 1
fi

# 4. 修正权限
echo "[4/5] 修正文件权限 (User: 999)..."
# 999 是官方 MySQL 容器内的 mysql 用户 ID
sudo chown -R 999:999 "$TARGET_DIR_ABS"

# 5. 提取同步坐标
echo "[5/5] 读取同步坐标..."
INFO_FILE="$TARGET_DIR_ABS/xtrabackup_binlog_info"

if [ -f "$INFO_FILE" ]; then
  # 读取文件内容
  CONTENT=$(cat "$INFO_FILE")
  LOG_FILE=$(echo $CONTENT | awk '{print $1}')
  LOG_POS=$(echo $CONTENT | awk '{print $2}')
  
  echo "--------------------------------------------------------"
  echo "✅ 恢复完成！"
  echo "数据已就绪: $TARGET_DIR_ABS"
  echo "--------------------------------------------------------"
  echo "请启动从库容器，并执行以下 SQL 建立主从关系："
  echo ""
  echo "CHANGE MASTER TO"
  echo "  MASTER_HOST='tunnel',"
  echo "  MASTER_USER='<同步账号>',"
  echo "  MASTER_PASSWORD='<同步密码>',"
  echo "  MASTER_LOG_FILE='$LOG_FILE',"
  echo "  MASTER_LOG_POS=$LOG_POS;"
  echo ""
  echo "START SLAVE;"
  echo "--------------------------------------------------------"
else
  echo "⚠️  警告: 未找到 xtrabackup_binlog_info 文件，无法自动获取同步点。"
fi
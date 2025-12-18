#!/bin/bash

# ==============================================================================
# MySQL 物理备份脚本 (Percona XtraBackup) - Docker 版
# 功能：对指定的 MySQL 容器进行物理热备，并打包成压缩包
# 适用：生产环境 (Linux)
# ==============================================================================

# --- 配置区域 ---
# 备份文件存放目录 (默认为当前目录下的 backups)
BACKUP_ROOT="./backups"
# XtraBackup 镜像版本 (这里用 8.0 即可，配合 --no-server-version-check 使用)
XB_IMAGE="percona/percona-xtrabackup:8.0"
# ----------------

# 检查参数
if [ -z "$1" ]; then
  echo "用法: $0 [容器名称] [MySQL密码]"
  echo "示例: $0 prod_mysql my_secure_password"
  exit 1
fi

CONTAINER_NAME="$1"
DB_PASSWORD="$2"

# 如果没有提供密码，尝试交互式输入
if [ -z "$DB_PASSWORD" ]; then
  read -s -p "请输入 MySQL root 密码: " DB_PASSWORD
  echo ""
fi

# 检查容器是否存在
if ! docker ps | grep -q "$CONTAINER_NAME"; then
  echo "错误: 找不到运行中的容器 '$CONTAINER_NAME'"
  exit 1
fi

# 创建备份目录
mkdir -p "$BACKUP_ROOT"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
# 注意：虽然是 xbstream 格式，但为了方便识别，我们依然打包成 .gz
FILENAME="${CONTAINER_NAME}_full_${TIMESTAMP}.xbstream.gz"
TARGET_FILE="${BACKUP_ROOT}/${FILENAME}"

echo "--------------------------------------------------------"
echo "开始物理备份..."
echo "目标容器: $CONTAINER_NAME"
echo "备份文件: $TARGET_FILE"
echo "工具镜像: $XB_IMAGE"
echo "--------------------------------------------------------"

# 执行备份
# 关键修改：
# 1. --no-server-version-check: 强制忽略 MySQL 8.2 版本不匹配报错
# 2. --stream=xbstream: 8.0 版本必须用 xbstream，不能用 tar
docker run --rm \
  --volumes-from "$CONTAINER_NAME" \
  --network "container:$CONTAINER_NAME" \
  "$XB_IMAGE" \
  xtrabackup --backup \
    --stream=xbstream \
    --compress \
    --user=root \
    --password="$DB_PASSWORD" \
    --host=127.0.0.1 \
    --target-dir=/tmp \
  | gzip > "$TARGET_FILE"

# 检查执行结果
if [ $? -eq 0 ]; then
  FILESIZE=$(du -h "$TARGET_FILE" | cut -f1)
  echo "--------------------------------------------------------"
  echo "✅ 备份成功!"
  echo "文件位置: $TARGET_FILE"
  echo "文件大小: $FILESIZE"
  echo ""
  echo "⚠️  注意: 这是一个 xbstream 流式压缩包。"
  echo "恢复时请务必使用配套的 restore_slave.sh 脚本。"
  echo "--------------------------------------------------------"
else
  echo "--------------------------------------------------------"
  echo "❌ 备份失败，请检查上面的错误日志。"
  echo "--------------------------------------------------------"
  rm -f "$TARGET_FILE" # 删除可能损坏的文件
  exit 1
fi
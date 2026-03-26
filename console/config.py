"""
控制台配置文件
"""

# === 基础配置 ===
CONSOLE_PORT = 8980
CONSOLE_HOST = "0.0.0.0"

# === 目录配置 ===
# 备份机工作目录（控制台部署在备份机上）
BACKUP_BASE_DIR = "/data/burncloud/burncloud-aiapi-database-backup"
# SSH密钥路径
SSH_KEY_PATH = f"{BACKUP_BASE_DIR}/id_rsa/id_rsa_backup"
# 模板目录
TEMPLATE_DIR = f"{BACKUP_BASE_DIR}/template"
# 应用机new-api模板目录
NEW_API_TEMPLATE_DIR = f"{BACKUP_BASE_DIR}/new-api-close"
# 数据目录
DATA_DIR = "/data/burncloud-aiapi-database-backup-console/data"

# === 端口配置 ===
# phpMyAdmin端口起始值
PMA_PORT_START = 8900
PMA_PORT_END = 9000
# 应用机SSH端口默认值
SSH_PORT_DEFAULT = 22
# 应用机SSH用户默认值
SSH_USER_DEFAULT = "core"

# === Docker配置 ===
# 控制台容器名称
CONSOLE_CONTAINER_NAME = "burncloud-deploy-console"

# === 邮件告警配置 ===
# SMTP服务器配置
SMTP_HOST = "smtp.exmail.qq.com"
SMTP_PORT = 465
SMTP_USER = "zhengtianfeng@burncloud.cn"
SMTP_PASSWORD = "EgHtQFE36EbTF25g"
SMTP_USE_SSL = True

# 告警配置
ALERT_CHECK_INTERVAL = 3600  # 扫描间隔：1小时（秒）
ALERT_DELAY_THRESHOLD = 3600  # 延迟告警阈值：1小时（秒）

# 告警收件人
ALERT_RECIPIENTS = ["858377817@qq.com"]

# === 应用配置 ===
# 应用机部署目录前缀
APP_DIR_PREFIX = "new-api-"
# new-api镜像名称
NEW_API_IMAGE = "calciumion/new-api-horizon:latest"
# MySQL默认密码
MYSQL_ROOT_PASSWORD = "burncloud123456!qwf"
# 数据库名称
DB_NAME = "new-api"

# === 备份配置 ===
# 备份容器server-id（固定100）
BACKUP_SERVER_ID = 100

# New-API 部署控制台

## 功能说明

控制台部署在备份机上，通过Web界面管理应用机上的new-api应用和备份机上的备份实例。

### 核心功能
- 应用机管理：添加/编辑/删除应用机，SSH连接测试
- 应用部署：一键部署new-api应用到应用机，同时创建备份配置
- 旧节点纳管：导入已有的备份节点进行监控管理
- 状态监控：查看应用容器状态和备份同步状态
- 邮件告警：每小时扫描备份状态，异常时自动发送邮件通知

## 目录结构

```
console/
├── app.py              # FastAPI 主应用
├── config.py           # 配置文件
├── database.py         # SQLite 数据库操作
├── models.py           # 数据模型
├── schemas.py          # Pydantic 模型
├── ssh_deployer.py     # SSH 部署逻辑
├── backup_manager.py   # 备份管理逻辑
├── alert_system.py     # 邮件告警系统
├── static/
│   └── css/
│       └── style.css   # 样式文件
├── templates/
│   ├── base.html       # 基础模板
│   ├── index.html      # 首页
│   ├── servers.html    # 应用机管理
│   ├── apps.html       # 应用管理
│   └── alerts.html     # 告警历史
├── requirements.txt    # Python 依赖
├── Dockerfile          # Docker 镜像构建
├── docker-compose.yml  # Docker Compose 部署
└── data/
    └── console.db      # SQLite 数据库
```

## 配置说明

配置文件 `config.py` 包含：
- 控制台端口：8980
- 备份机工作目录：/data/burncloud/burncloud-aiapi-database-backup
- SSH密钥路径：/data/burncloud/burncloud-aiapi-database-backup/id_rsa/id_rsa_backup
- 应用机部署目录前缀：new-api-
- phpMyAdmin端口范围：8900-9000
- 邮件告警配置（SMTP、发件人、收件人）

## 部署步骤

1. 将 `console/` 目录上传到备份机
2. 在备份机上执行：`docker-compose up -d`
3. 访问控制台：`http://备份机IP:8980`

## 数据库表结构

### servers (应用机表)
- id: 主键
- name: 备注
- ip: IP地址
- ssh_port: SSH端口
- ssh_user: SSH用户
- created_at: 创建时间

### apps (应用表)
- id: 主键
- server_id: 应用机ID
- app_name: 应用名称
- app_port: 应用端口
- mysql_port: MySQL端口
- backup_dir: 备份目录名
- pma_port: phpMyAdmin端口
- status: 状态 (pending/deploying/running/stopped/error)
- backup_status: 备份状态 (none/syncing/ok/error)
- install_confirmed: 是否已安装
- email_notification_enabled: 邮件通知开关
- created_at: 创建时间
- updated_at: 更新时间

### alerts (告警历史表)
- id: 主键
- app_id: 应用ID
- alert_type: 告警类型 (io_error/sql_error/delay)
- message: 告警消息
- is_sent: 是否已发送邮件
- created_at: 创建时间

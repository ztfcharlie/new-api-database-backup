# New-API 部署控制台 - 部署指南

## 功能说明

控制台部署在备份机上，通过Web界面管理：
- 应用机上的 new-api 应用部署
- 备份机上的备份实例管理
- 备份状态监控和告警

## 部署步骤

### 1. 上传文件到备份机

将 `console/` 目录上传到备份机的 `/data/burncloud/burncloud-aiapi-database-backup/` 目录下。

目录结构应该是：
```
/data/burncloud/burncloud-aiapi-database-backup/
├── console/
│   ├── app.py
│   ├── config.py
│   ├── database.py
│   ├── ...
│   └── docker-compose.yml
├── template/
├── new-api-close/
└── id_rsa/
```

### 2. 启动控制台

```bash
cd /data/burncloud/burncloud-aiapi-database-backup/console
docker-compose up -d
```

### 3. 访问控制台

控制台绑定在 `127.0.0.1:8980`，需要通过SSH隧道访问：

```bash
# 在本地执行
ssh -L 8980:127.0.0.1:8980 root@备份机IP
```

然后浏览器访问：`http://localhost:8980`

## 使用流程

### 首次使用

1. **添加应用机**
   - 进入「应用机管理」页面
   - 点击「添加应用机」
   - 填写应用机IP、SSH端口、SSH用户
   - 点击「测试连接」验证

2. **部署新应用**
   - 进入「部署新应用」页面
   - 选择应用机，填写应用名称、端口等信息
   - 点击「开始部署」
   - 等待部署完成

3. **完成应用安装**
   - 应用部署完成后，访问 `http://应用机IP:端口` 完成new-api初始化
   - 回到控制台首页，点击「确认安装」
   - 系统将启动备份容器并开始同步数据

### 导入已有节点

如果已有备份节点，可以导入管理：

1. 进入「导入已有节点」页面
2. 选择备份目录和应用机
3. 填写应用信息
4. 点击「导入」

### 监控备份状态

- 首页显示所有应用的状态
- 点击「刷新」按钮获取最新状态
- 开启邮件通知后，异常时会自动发送邮件

### 告警通知

- 每小时自动扫描备份状态
- IO错误、SQL错误或同步延迟超过1小时时会发送邮件
- 进入「告警历史」查看告警记录
- 点击「发送测试邮件」测试邮件配置

## 常见问题

### 端口冲突

phpMyAdmin端口自动分配范围是 8900-9000。如果端口不够用，修改 `config.py` 中的 `PMA_PORT_START` 和 `PMA_PORT_END`。

### SSH连接失败

1. 检查SSH密钥文件是否存在：`/data/burncloud/burncloud-aiapi-database-backup/id_rsa/id_rsa_backup`
2. 检查密钥权限：`chmod 600 id_rsa/id_rsa_backup`
3. 检查应用机SSH服务是否正常运行

### 备份同步异常

1. 检查隧道容器状态：`docker logs tunnel_{备份目录名}`
2. 检查备份容器状态：`docker logs backup_{备份目录名}`
3. 点击「重置」按钮重启同步

## 邮件配置

邮件配置在 `config.py` 中：

```python
SMTP_HOST = "smtp.exmail.qq.com"
SMTP_PORT = 465
SMTP_USER = "zhengtianfeng@burncloud.cn"
SMTP_PASSWORD = "EgHtQFE36EbTF25g"
SMTP_USE_SSL = True

ALERT_RECIPIENTS = ["838377817@qq.com"]
```

修改后需要重启控制台：

```bash
docker-compose restart
```

## 目录结构

```
console/
├── app.py              # FastAPI 主应用
├── config.py           # 配置文件
├── database.py         # SQLite 数据库操作
├── ssh_deployer.py     # SSH 部署逻辑
├── backup_manager.py   # 备份管理逻辑
├── alert_system.py     # 邮件告警系统
├── schemas.py          # Pydantic 模型
├── templates/          # HTML 模板
│   ├── base.html
│   ├── index.html
│   ├── servers.html
│   ├── apps.html
│   ├── deploy.html
│   ├── import.html
│   └── alerts.html
├── static/
│   └── css/
│       └── style.css
├── requirements.txt    # Python 依赖
├── Dockerfile
├── docker-compose.yml
└── data/
    └── console.db      # SQLite 数据库
```

## 技术栈

| 组件 | 技术 |
|------|------|
| 后端 | Python + FastAPI |
| 前端 | HTML + CSS + JavaScript |
| 数据存储 | SQLite |
| SSH | paramiko |
| 定时任务 | APScheduler |
| 邮件 | smtplib |
| 容器化 | Docker |

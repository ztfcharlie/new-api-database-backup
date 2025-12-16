# Dockerized MySQL SSH Replication Kit
# 基于 Docker 和 SSH 隧道的 MySQL 多实例安全备份方案

[![Docker](https://img.shields.io/badge/Docker-Enabled-blue.svg)](https://www.docker.com/)
[![MySQL](https://img.shields.io/badge/MySQL-8.0%2F5.7-orange.svg)](https://www.mysql.com/)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](./LICENSE)

这是一个专为**高并发、多实例**环境设计的 MySQL 实时备份解决方案。它利用 **Docker 容器化隔离** 和 **SSH 隧道技术**，在不暴露生产数据库公网端口的前提下，实现安全、低侵入的实时主从复制（Master-Slave Replication）。

---

## 🌟 核心特性 (Features)

*   **🔒 极致安全**: 生产数据库无需开放 `3306` 端口到公网，所有流量经过 SSH 加密隧道传输。
*   **🚀 零侵入备份**: 备份操作（压缩、打包、IO写入）完全在备份服务器进行，生产服务器仅传输 Binlog，对业务性能影响极低。
*   **📦 容器化隔离**: 每一个备份实例都是独立的 Docker 容器，互不干扰。无论是 1 个还是 100 个项目，都能独立管理。
*   **👁️ 可视化管理**: 每个实例自带独立的 **phpMyAdmin**，随时查看备份数据状态。
*   **📉 资源限制**: 可通过 Docker 限制每个备份实例的 CPU 和内存占用，防止备份任务拖垮服务器。

---

## 🏗️ 架构原理 (Architecture)

```mermaid
graph LR
    subgraph Production_Server [生产服务器 (Master)]
        A[MySQL Master] -- 127.0.0.1:3306 --> B(SSHD Service)
    end

    subgraph Backup_Server [备份服务器 (Slave)]
        C(Docker Tunnel) -- SSH Connection --> B
        D[Docker MySQL Slave] -- Link --> C
        E[phpMyAdmin] -- Link --> D
    end

    style A fill:#ff9900,stroke:#333,stroke-width:2px
    style D fill:#42b883,stroke:#333,stroke-width:2px
```

**数据流向：**
1.  **Tunnel 容器** 通过 SSH 登录生产服务器，建立端口转发。
2.  **Backup 容器** 连接 Tunnel 容器的映射端口。
3.  **Production MySQL** 将数据通过加密隧道实时推送给 Backup 容器。

---

## 🛠️ 快速开始 (Quick Start)

### 第一阶段：生产环境配置 (Master)

在您的**生产服务器**上，需要进行一次性配置以开启复制功能。

1.  **修改 MySQL 配置** (`my.cnf` 或 `docker-compose` 挂载配置)：
    ```ini
    [mysqld]
    # 唯一ID (每个项目必须不同，如 1, 2, 3...)
    server-id = 1
    # 开启 Binlog
    log-bin = mysql-bin
    binlog_format = ROW
    # 开启 GTID (强烈推荐，实现自动断点续传)
    gtid_mode = ON
    enforce_gtid_consistency = ON
    ```

2.  **安全端口映射** (Docker Compose):
    *请确保生产库端口仅监听本地，不要暴露给公网！*
    ```yaml
    ports:
      - "127.0.0.1:3306:3306"  # ✅ 正确：仅允许本机(及SSH隧道)访问
      # - "0.0.0.0:3306:3306"  # ❌ 错误：极其危险
    ```

3.  **创建复制账号**:
    ```sql
    CREATE USER 'repl_user'@'%' IDENTIFIED BY 'your_secure_password';
    GRANT REPLICATION SLAVE ON *.* TO 'repl_user'@'%';
    FLUSH PRIVILEGES;
    ```

---

### 第二阶段：部署备份实例 (Slave)

在**备份服务器**上，只需复制模板并启动。

#### 1. 复制项目模板
```bash
cp -r template my_backup_project
cd my_backup_project
```

#### 2. 配置环境变量
复制或编辑 `.env` 文件，填入生产服务器信息。

```ini
# .env 示例

# === 基础配置 ===
PROJECT_NAME=shop_prod    # 项目名称
SSH_HOST=1.2.3.4          # 生产服务器 IP
SSH_USER=root             # 生产服务器 SSH 用户

# === 数据库连接 ===
REMOTE_DB_PORT=3306       # 生产服务器 MySQL 映射在宿主机的端口
MASTER_USER=repl_user     # 刚才创建的复制账号
MASTER_PASSWORD=xxxxxx

# === 本地端口规划 (避免冲突) ===
LOCAL_PORT=13306          # 本机访问备份库的端口
PMA_PORT=8888             # phpMyAdmin 访问端口
```

#### 3. 放入 SSH 私钥 (推荐)
将生产服务器的私钥 (`id_rsa`) 放入当前目录。
*(如果没有私钥，也可以在 .env 中配置 SSH_PASSWORD，但不推荐)*

#### 4. 一键启动
```bash
docker-compose up -d
```

---

## 📊 验证与管理

### 访问数据库
*   **地址**: `localhost` (或备份服务器IP)
*   **端口**: `.env` 中配置的 `LOCAL_PORT` (如 13306)

### 访问 phpMyAdmin
*   打开浏览器访问: `http://localhost:8888` (对应 `PMA_PORT`)
*   登录查看数据同步情况。

### 检查同步状态
进入 phpMyAdmin 或命令行执行：
```sql
SHOW SLAVE STATUS\G;
```
如果看到以下两行，代表同步正常运行：
*   `Slave_IO_Running: Yes`
*   `Slave_SQL_Running: Yes`

---

## ❓ 常见问题 (Q&A)

**Q: 生产数据量已经很大(如 100GB)，可以直接启动吗？**
A: **不可以**。初次同步建议先在生产端做一次全量导出 (`mysqldump`)，将 SQL 文件放入备份项目的 `data/` 目录中，让 Docker 在首次启动时自动导入，然后再开启同步。

**Q: 为什么提示连接不上生产库？**
A: 请检查：
1. 生产服务器是否安装了 `openssh-server`。
2. 生产 MySQL 的端口映射是否绑定了 `127.0.0.1`。
3. SSH 私钥权限是否正确。

**Q: 多个项目如何管理？**
A: 简单的复制 `template` 目录为不同名称（如 `backup_shop`, `backup_blog`），修改 `.env` 中的端口号（`LOCAL_PORT`, `PMA_PORT`），互不冲突。

---

## 📄 License

MIT License.

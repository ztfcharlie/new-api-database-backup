"""
SQLite 数据库操作
"""
import sqlite3
import os
from datetime import datetime
from typing import List, Dict, Optional, Any
from contextlib import contextmanager

import config


# 数据库文件路径
DB_PATH = os.path.join(config.DATA_DIR, "console.db")


@contextmanager
def get_db():
    """获取数据库连接上下文"""
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def init_db():
    """初始化数据库表"""
    os.makedirs(config.DATA_DIR, exist_ok=True)

    with get_db() as conn:
        cursor = conn.cursor()

        # 应用机表
        cursor.execute("""
            CREATE TABLE IF NOT EXISTS servers (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                ip TEXT NOT NULL,
                ssh_port INTEGER DEFAULT 22,
                ssh_user TEXT DEFAULT 'core',
                created_at TEXT DEFAULT CURRENT_TIMESTAMP
            )
        """)

        # 应用表
        cursor.execute("""
            CREATE TABLE IF NOT EXISTS apps (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                server_id INTEGER NOT NULL,
                app_name TEXT NOT NULL,
                app_port INTEGER NOT NULL,
                mysql_port INTEGER NOT NULL,
                backup_dir TEXT NOT NULL,
                pma_port INTEGER NOT NULL,
                status TEXT DEFAULT 'pending',
                backup_status TEXT DEFAULT 'none',
                install_confirmed INTEGER DEFAULT 0,
                email_notification_enabled INTEGER DEFAULT 1,
                created_at TEXT DEFAULT CURRENT_TIMESTAMP,
                updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
                FOREIGN KEY (server_id) REFERENCES servers(id)
            )
        """)

        # 告警历史表
        cursor.execute("""
            CREATE TABLE IF NOT EXISTS alerts (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                app_id INTEGER NOT NULL,
                alert_type TEXT NOT NULL,
                message TEXT,
                is_sent INTEGER DEFAULT 0,
                created_at TEXT DEFAULT CURRENT_TIMESTAMP,
                FOREIGN KEY (app_id) REFERENCES apps(id)
            )
        """)

        # 创建索引
        cursor.execute("CREATE INDEX IF NOT EXISTS idx_apps_server_id ON apps(server_id)")
        cursor.execute("CREATE INDEX IF NOT EXISTS idx_alerts_app_id ON alerts(app_id)")
        cursor.execute("CREATE INDEX IF NOT EXISTS idx_alerts_created ON alerts(created_at)")


# ============ 应用机操作 ============

def create_server(name: str, ip: str, ssh_port: int = 22, ssh_user: str = "core") -> int:
    """创建应用机"""
    with get_db() as conn:
        cursor = conn.cursor()
        cursor.execute(
            "INSERT INTO servers (name, ip, ssh_port, ssh_user) VALUES (?, ?, ?, ?)",
            (name, ip, ssh_port, ssh_user)
        )
        return cursor.lastrowid


def get_servers() -> List[Dict[str, Any]]:
    """获取所有应用机"""
    with get_db() as conn:
        cursor = conn.cursor()
        cursor.execute("SELECT * FROM servers ORDER BY created_at DESC")
        return [dict(row) for row in cursor.fetchall()]


def get_server(server_id: int) -> Optional[Dict[str, Any]]:
    """获取单个应用机"""
    with get_db() as conn:
        cursor = conn.cursor()
        cursor.execute("SELECT * FROM servers WHERE id = ?", (server_id,))
        row = cursor.fetchone()
        return dict(row) if row else None


def update_server(server_id: int, name: str = None, ip: str = None,
                  ssh_port: int = None, ssh_user: str = None) -> bool:
    """更新应用机"""
    updates = []
    params = []
    if name is not None:
        updates.append("name = ?")
        params.append(name)
    if ip is not None:
        updates.append("ip = ?")
        params.append(ip)
    if ssh_port is not None:
        updates.append("ssh_port = ?")
        params.append(ssh_port)
    if ssh_user is not None:
        updates.append("ssh_user = ?")
        params.append(ssh_user)

    if not updates:
        return False

    params.append(server_id)
    with get_db() as conn:
        cursor = conn.cursor()
        cursor.execute(f"UPDATE servers SET {', '.join(updates)} WHERE id = ?", params)
        return cursor.rowcount > 0


def delete_server(server_id: int) -> bool:
    """删除应用机"""
    with get_db() as conn:
        cursor = conn.cursor()
        # 先检查是否有应用在使用
        cursor.execute("SELECT COUNT(*) as cnt FROM apps WHERE server_id = ?", (server_id,))
        if cursor.fetchone()["cnt"] > 0:
            return False
        cursor.execute("DELETE FROM servers WHERE id = ?", (server_id,))
        return cursor.rowcount > 0


# ============ 应用操作 ============

def create_app(server_id: int, app_name: str, app_port: int,
              mysql_port: int, backup_dir: str, pma_port: int) -> int:
    """创建应用"""
    with get_db() as conn:
        cursor = conn.cursor()
        cursor.execute(
            """INSERT INTO apps
               (server_id, app_name, app_port, mysql_port, backup_dir, pma_port)
               VALUES (?, ?, ?, ?, ?, ?)""",
            (server_id, app_name, app_port, mysql_port, backup_dir, pma_port)
        )
        return cursor.lastrowid


def get_apps(include_server: bool = True) -> List[Dict[str, Any]]:
    """获取所有应用"""
    with get_db() as conn:
        cursor = conn.cursor()
        if include_server:
            cursor.execute("""
                SELECT a.*, s.name as server_name, s.ip as server_ip,
                       s.ssh_port, s.ssh_user
                FROM apps a
                LEFT JOIN servers s ON a.server_id = s.id
                ORDER BY a.created_at DESC
            """)
        else:
            cursor.execute("SELECT * FROM apps ORDER BY created_at DESC")
        return [dict(row) for row in cursor.fetchall()]


def get_app(app_id: int) -> Optional[Dict[str, Any]]:
    """获取单个应用"""
    with get_db() as conn:
        cursor = conn.cursor()
        cursor.execute("""
            SELECT a.*, s.name as server_name, s.ip as server_ip,
                   s.ssh_port, s.ssh_user
            FROM apps a
            LEFT JOIN servers s ON a.server_id = s.id
            WHERE a.id = ?
        """, (app_id,))
        row = cursor.fetchone()
        return dict(row) if row else None


def get_apps_by_server(server_id: int) -> List[Dict[str, Any]]:
    """获取指定应用机的所有应用"""
    with get_db() as conn:
        cursor = conn.cursor()
        cursor.execute(
            "SELECT * FROM apps WHERE server_id = ? ORDER BY created_at DESC",
            (server_id,)
        )
        return [dict(row) for row in cursor.fetchall()]


def update_app_status(app_id: int, status: str = None,
                     backup_status: str = None) -> bool:
    """更新应用状态"""
    updates = []
    params = []
    if status is not None:
        updates.append("status = ?")
        params.append(status)
    if backup_status is not None:
        updates.append("backup_status = ?")
        params.append(backup_status)

    updates.append("updated_at = ?")
    params.append(datetime.now().isoformat())
    params.append(app_id)

    with get_db() as conn:
        cursor = conn.cursor()
        cursor.execute(
            f"UPDATE apps SET {', '.join(updates)} WHERE id = ?",
            params
        )
        return cursor.rowcount > 0


def confirm_install(app_id: int) -> bool:
    """确认应用已安装"""
    with get_db() as conn:
        cursor = conn.cursor()
        cursor.execute(
            "UPDATE apps SET install_confirmed = 1, updated_at = ? WHERE id = ?",
            (datetime.now().isoformat(), app_id)
        )
        return cursor.rowcount > 0


def toggle_email_notification(app_id: int, enabled: bool) -> bool:
    """切换邮件通知开关"""
    with get_db() as conn:
        cursor = conn.cursor()
        cursor.execute(
            "UPDATE apps SET email_notification_enabled = ?, updated_at = ? WHERE id = ?",
            (1 if enabled else 0, datetime.now().isoformat(), app_id)
        )
        return cursor.rowcount > 0


def import_existing_app(server_id: int, app_name: str, app_port: int,
                       mysql_port: int, backup_dir: str, pma_port: int,
                       install_confirmed: bool = True) -> int:
    """导入已有应用"""
    with get_db() as conn:
        cursor = conn.cursor()
        cursor.execute(
            """INSERT INTO apps
               (server_id, app_name, app_port, mysql_port, backup_dir,
                pma_port, status, backup_status, install_confirmed)
               VALUES (?, ?, ?, ?, ?, ?, 'running', 'ok', ?)""",
            (server_id, app_name, app_port, mysql_port, backup_dir,
             pma_port, 1 if install_confirmed else 0)
        )
        return cursor.lastrowid


# ============ 告警操作 ============

def create_alert(app_id: int, alert_type: str, message: str) -> int:
    """创建告警"""
    with get_db() as conn:
        cursor = conn.cursor()
        cursor.execute(
            "INSERT INTO alerts (app_id, alert_type, message) VALUES (?, ?, ?)",
            (app_id, alert_type, message)
        )
        return cursor.lastrowid


def get_alerts(limit: int = 100) -> List[Dict[str, Any]]:
    """获取告警历史"""
    with get_db() as conn:
        cursor = conn.cursor()
        cursor.execute("""
            SELECT a.*, ap.app_name, s.name as server_name
            FROM alerts a
            LEFT JOIN apps ap ON a.app_id = ap.id
            LEFT JOIN servers s ON ap.server_id = s.id
            ORDER BY a.created_at DESC
            LIMIT ?
        """, (limit,))
        return [dict(row) for row in cursor.fetchall()]


def get_alerts_by_app(app_id: int, limit: int = 50) -> List[Dict[str, Any]]:
    """获取指定应用的告警"""
    with get_db() as conn:
        cursor = conn.cursor()
        cursor.execute("""
            SELECT * FROM alerts
            WHERE app_id = ?
            ORDER BY created_at DESC
            LIMIT ?
        """, (app_id, limit))
        return [dict(row) for row in cursor.fetchall()]


def mark_alert_sent(alert_id: int) -> bool:
    """标记告警已发送"""
    with get_db() as conn:
        cursor = conn.cursor()
        cursor.execute("UPDATE alerts SET is_sent = 1 WHERE id = ?", (alert_id,))
        return cursor.rowcount > 0


def get_unsent_alerts() -> List[Dict[str, Any]]:
    """获取未发送的告警"""
    with get_db() as conn:
        cursor = conn.cursor()
        cursor.execute("""
            SELECT a.*, ap.app_name, s.name as server_name
            FROM alerts a
            LEFT JOIN apps ap ON a.app_id = ap.id
            LEFT JOIN servers s ON ap.server_id = s.id
            WHERE a.is_sent = 0 AND a.email_notification_enabled = 1
            ORDER BY a.created_at ASC
        """)
        return [dict(row) for row in cursor.fetchall()]


def get_apps_with_email_enabled() -> List[Dict[str, Any]]:
    """获取开启邮件通知的应用"""
    with get_db() as conn:
        cursor = conn.cursor()
        cursor.execute("""
            SELECT a.*, s.name as server_name, s.ip as server_ip
            FROM apps a
            LEFT JOIN servers s ON a.server_id = s.id
            WHERE a.email_notification_enabled = 1
            AND a.install_confirmed = 1
        """)
        return [dict(row) for row in cursor.fetchall()]


def cleanup_old_alerts(days: int = 30) -> int:
    """清理旧告警记录"""
    with get_db() as conn:
        cursor = conn.cursor()
        cursor.execute(
            "DELETE FROM alerts WHERE created_at < datetime('now', '-' || ? || ' days')",
            (days,)
        )
        return cursor.rowcount


# 初始化数据库
init_db()

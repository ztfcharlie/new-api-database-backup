"""
备份管理逻辑 - 在备份机上创建和管理备份容器
"""
import os
import subprocess
import time
from typing import Dict, Any, List

import config


def generate_backup_env(server: Dict[str, Any], app: Dict[str, Any]) -> str:
    """生成备份目录的.env配置文件内容"""
    # 从模板读取
    template_path = f"{config.TEMPLATE_DIR}/.env.example"
    try:
        with open(template_path, 'r') as f:
            template_content = f.read()
    except Exception as e:
        raise Exception(f"读取模板文件失败: {str(e)}")

    # 替换变量
    content = template_content

    # 项目名（使用备份目录名）
    content = content.replace("PROJECT_NAME=demo_project", f"PROJECT_NAME={app['backup_dir']}")

    # SSH连接信息
    content = content.replace("SSH_HOST=1.2.3.4", f"SSH_HOST={server['ip']}")
    content = content.replace("SSH_PORT=22", f"SSH_PORT={server['ssh_port']}")
    content = content.replace("SSH_USER=core", f"SSH_USER={server['ssh_user']}")
    # SSH密码留空，使用密钥认证
    content = content.replace("SSH_PASSWORD=", "SSH_PASSWORD=")

    # 远程数据库端口
    content = content.replace("REMOTE_DB_PORT=3306", f"REMOTE_DB_PORT={app['mysql_port']}")

    # phpMyAdmin端口
    content = content.replace("PMA_WEB_PORT=8888", f"PMA_WEB_PORT={app['pma_port']}")

    # 应用端口（备份机不需要，但保留配置）
    content = content.replace("NEW_API_PORT=3000", f"NEW_API_PORT={app['app_port']}")

    # 数据库名称
    content = content.replace("TARGET_DB_NAME=new-api", f"TARGET_DB_NAME={config.DB_NAME}")

    # 密码配置
    content = content.replace(
        "MASTER_PASSWORD=burncloud123456!qwf",
        f"MASTER_PASSWORD={config.MYSQL_ROOT_PASSWORD}"
    ).replace(
        "MYSQL_ROOT_PASSWORD=burncloud123456!qwf",
        f"MYSQL_ROOT_PASSWORD={config.MYSQL_ROOT_PASSWORD}"
    )

    return content


def create_backup_directory(app_config: Dict[str, Any]) -> Dict[str, Any]:
    """创建备份目录和相关文件"""
    result = {
        "success": False,
        "message": "",
        "backup_dir": app_config.get('backup_dir', ''),
        "pma_port": app_config.get('pma_port', '')
    }

    backup_dir = os.path.join(config.BACKUP_BASE_DIR, app_config['backup_dir'])

    # 检查目录是否已存在
    if os.path.exists(backup_dir):
        result["message"] = f"备份目录 {backup_dir} 已存在"
        return result

    try:
        # 创建目录
        os.makedirs(backup_dir, exist_ok=True)
        os.makedirs(f"{backup_dir}/data", exist_ok=True)

        # 生成.env文件
        env_content = generate_backup_env(app_config['server'], app_config)
        with open(f"{backup_dir}/.env", 'w') as f:
            f.write(env_content)

        # 复制docker-compose.yml（使用不含new-api的版本）
        compose_src = f"{config.TEMPLATE_DIR}/docker-compose.yml"
        compose_dst = f"{backup_dir}/docker-compose.yml"
        with open(compose_src, 'r') as src, open(compose_dst, 'w') as dst:
            dst.write(src.read())

        # 复制脚本文件
        scripts = ['init-slave.sh', 'quick_start_sync.sh', 'check_sync_status.sh']
        for script in scripts:
            src_script = f"{config.TEMPLATE_DIR}/{script}"
            dst_script = f"{backup_dir}/{script}"
            if os.path.exists(src_script):
                with open(src_script, 'r') as src, open(dst_script, 'w') as dst:
                    dst.write(src.read())
                # 添加执行权限
                os.chmod(dst_script, 0o755)

        result["success"] = True
        result["message"] = "备份目录创建成功"
        result["backup_dir_path"] = backup_dir

    except Exception as e:
        result["message"] = f"创建备份目录失败: {str(e)}"

    return result


def get_available_pma_port() -> int:
    """获取可用的phpMyAdmin端口"""
    # 扫描现有备份目录，找出已使用的端口
    used_ports = set()

    if os.path.exists(config.BACKUP_BASE_DIR):
        for entry in os.listdir(config.BACKUP_BASE_DIR):
            backup_dir = os.path.join(config.BACKUP_BASE_DIR, entry)
            env_file = os.path.join(backup_dir, '.env')
            if os.path.isdir(backup_dir) and os.path.exists(env_file):
                try:
                    with open(env_file, 'r') as f:
                        for line in f:
                            if line.startswith('PMA_WEB_PORT='):
                                port = int(line.split('=')[1].strip())
                                used_ports.add(port)
                                break
                except:
                    pass

    # 从起始端口开始寻找可用端口
    for port in range(config.PMA_PORT_START, config.PMA_PORT_END):
        if port not in used_ports:
            return port

    raise Exception("没有可用的phpMyAdmin端口")


def start_backup_container(backup_dir: str) -> Dict[str, Any]:
    """启动备份容器"""
    result = {
        "success": False,
        "message": "",
        "container_name": f"backup_{backup_dir}",
        "tunnel_name": f"tunnel_{backup_dir}"
    }

    backup_dir_path = os.path.join(config.BACKUP_BASE_DIR, backup_dir)

    if not os.path.exists(backup_dir_path):
        result["message"] = f"备份目录不存在: {backup_dir_path}"
        return result

    try:
        # 停止已存在的容器
        subprocess.run(
            f"cd {backup_dir_path} && docker-compose down 2>/dev/null",
            shell=True,
            timeout=30
        )

        # 启动容器
        process = subprocess.run(
            f"cd {backup_dir_path} && docker-compose up -d",
            shell=True,
            capture_output=True,
            text=True,
            timeout=120
        )

        if process.returncode == 0:
            # 等待容器启动
            time.sleep(5)

            # 检查容器状态
            status_check = subprocess.run(
                f"docker ps --filter name={result['container_name']} --format '{{{{.Status}}}}'",
                shell=True,
                capture_output=True,
                text=True
            )

            if status_check.returncode == 0 and status_check.stdout.strip():
                result["success"] = True
                result["message"] = "备份容器启动成功"
                result["container_status"] = status_check.stdout.strip()
            else:
                result["message"] = "容器启动但状态检查失败"
                result["stderr"] = process.stderr
        else:
            result["message"] = f"启动容器失败: {process.stderr}"

    except subprocess.TimeoutExpired:
        result["message"] = "启动容器超时"
    except Exception as e:
        result["message"] = f"启动容器时出错: {str(e)}"

    return result


def stop_backup_container(backup_dir: str) -> Dict[str, Any]:
    """停止备份容器"""
    result = {"success": False, "message": ""}

    backup_dir_path = os.path.join(config.BACKUP_BASE_DIR, backup_dir)

    if not os.path.exists(backup_dir_path):
        result["message"] = f"备份目录不存在: {backup_dir_path}"
        return result

    try:
        process = subprocess.run(
            f"cd {backup_dir_path} && docker-compose down",
            shell=True,
            capture_output=True,
            text=True,
            timeout=60
        )

        if process.returncode == 0:
            result["success"] = True
            result["message"] = "备份容器停止成功"
        else:
            result["message"] = f"停止容器失败: {process.stderr}"

    except subprocess.TimeoutExpired:
        result["message"] = "停止容器超时"
    except Exception as e:
        result["message"] = f"停止容器时出错: {str(e)}"

    return result


def get_backup_container_status(backup_dir: str) -> Dict[str, Any]:
    """获取备份容器状态"""
    result = {
        "container_name": f"backup_{backup_dir}",
        "tunnel_name": f"tunnel_{backup_dir}",
        "container_running": False,
        "tunnel_running": False
    }

    try:
        # 检查备份容器状态
        status_check = subprocess.run(
            f"docker ps --filter name={result['container_name']} --format '{{{{.Status}}}}'",
            shell=True,
            capture_output=True,
            text=True
        )
        if status_check.returncode == 0 and status_check.stdout.strip():
            result["container_running"] = True
            result["container_status"] = status_check.stdout.strip()

        # 检查隧道容器状态
        tunnel_check = subprocess.run(
            f"docker ps --filter name={result['tunnel_name']} --format '{{{{.Status}}}}'",
            shell=True,
            capture_output=True,
            text=True
        )
        if tunnel_check.returncode == 0 and tunnel_check.stdout.strip():
            result["tunnel_running"] = True
            result["tunnel_status"] = tunnel_check.stdout.strip()

    except Exception as e:
        result["error"] = str(e)

    return result


def get_slave_status(backup_dir: str) -> Dict[str, Any]:
    """获取MySQL从库同步状态"""
    container_name = f"backup_{backup_dir}"
    result = {
        "io_running": None,
        "sql_running": None,
        "seconds_behind": None,
        "last_io_error": "",
        "last_sql_error": "",
        "error": None
    }

    try:
        # 执行SHOW SLAVE STATUS
        command = (
            f"docker exec {container_name} mysql -u root -p{config.MYSQL_ROOT_PASSWORD} "
            f"-e \"SHOW SLAVE STATUS\\G\" 2>/dev/null"
        )

        process = subprocess.run(
            command,
            shell=True,
            capture_output=True,
            text=True,
            timeout=10
        )

        if process.returncode == 0:
            output = process.stdout

            # 解析状态
            for line in output.split('\n'):
                line = line.strip()
                if line.startswith('Slave_IO_Running:'):
                    result["io_running"] = line.split(':')[1].strip()
                elif line.startswith('Slave_SQL_Running:'):
                    result["sql_running"] = line.split(':')[1].strip()
                elif line.startswith('Seconds_Behind_Master:'):
                    value = line.split(':')[1].strip()
                    try:
                        result["seconds_behind"] = int(value) if value != 'NULL' else None
                    except ValueError:
                        result["seconds_behind"] = None
                elif line.startswith('Last_IO_Error:'):
                    result["last_io_error"] = line.split(':', 1)[1].strip()
                elif line.startswith('Last_SQL_Error:'):
                    result["last_sql_error"] = line.split(':', 1)[1].strip()
        else:
            result["error"] = "无法获取从库状态"

    except subprocess.TimeoutExpired:
        result["error"] = "查询超时"
    except Exception as e:
        result["error"] = str(e)

    return result


def check_sync_health(backup_dir: str) -> Dict[str, Any]:
    """检查同步健康状态"""
    result = {
        "status": "unknown",
        "issues": []
    }

    status = get_slave_status(backup_dir)

    io_running = status.get("io_running")
    sql_running = status.get("sql_running")
    seconds_behind = status.get("seconds_behind")

    # 检查IO状态
    if io_running != "Yes":
        result["issues"].append({
            "type": "io_error",
            "message": f"Slave_IO_Running: {io_running}",
            "detail": status.get("last_io_error", "")
        })
        result["status"] = "error"

    # 检查SQL状态
    if sql_running != "Yes":
        result["issues"].append({
            "type": "sql_error",
            "message": f"Slave_SQL_Running: {sql_running}",
            "detail": status.get("last_sql_error", "")
        })
        result["status"] = "error"

    # 检查延迟
    if seconds_behind is not None and seconds_behind > config.ALERT_DELAY_THRESHOLD:
        result["issues"].append({
            "type": "delay",
            "message": f"同步延迟 {seconds_behind} 秒",
            "detail": ""
        })
        if result["status"] != "error":
            result["status"] = "warning"

    if result["status"] == "unknown" and not result["issues"]:
        result["status"] = "ok"

    return result


def get_all_backup_dirs() -> List[str]:
    """获取所有备份目录"""
    backup_dirs = []

    if os.path.exists(config.BACKUP_BASE_DIR):
        for entry in os.listdir(config.BACKUP_BASE_DIR):
            backup_dir = os.path.join(config.BACKUP_BASE_DIR, entry)
            # 跳过.git、template、id_rsa等目录
            if os.path.isdir(backup_dir) and not entry.startswith('.'):
                # 检查是否有.env文件（备份目录特征）
                if os.path.exists(os.path.join(backup_dir, '.env')):
                    backup_dirs.append(entry)

    return backup_dirs


def restart_sync(backup_dir: str) -> Dict[str, Any]:
    """重启同步（执行START SLAVE）"""
    container_name = f"backup_{backup_dir}"
    result = {"success": False, "message": ""}

    try:
        command = (
            f"docker exec {container_name} mysql -u root -p{config.MYSQL_ROOT_PASSWORD} "
            f"-e \"START SLAVE;\""
        )

        process = subprocess.run(
            command,
            shell=True,
            capture_output=True,
            text=True,
            timeout=10
        )

        if process.returncode == 0:
            result["success"] = True
            result["message"] = "同步已重启"
        else:
            result["message"] = f"重启同步失败: {process.stderr}"

    except Exception as e:
        result["message"] = f"重启同步时出错: {str(e)}"

    return result

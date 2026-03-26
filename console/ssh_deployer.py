"""
SSH 部署逻辑 - 远程操作应用机
"""
import os
import time
import paramiko
from typing import Optional, Tuple, Dict, Any

import config


class SSHDeployer:
    """SSH 部署器"""

    def __init__(self, ip: str, ssh_port: int, ssh_user: str):
        self.ip = ip
        self.ssh_port = ssh_port
        self.ssh_user = ssh_user
        self.ssh_client = None
        self.sftp_client = None

    def connect(self) -> bool:
        """连接SSH"""
        try:
            self.ssh_client = paramiko.SSHClient()
            self.ssh_client.set_missing_host_key_policy(paramiko.AutoAddPolicy())

            # 使用密钥认证
            key_path = config.SSH_KEY_PATH
            if os.path.exists(key_path):
                private_key = paramiko.RSAKey.from_private_key_file(key_path)
                self.ssh_client.connect(
                    hostname=self.ip,
                    port=self.ssh_port,
                    username=self.ssh_user,
                    pkey=private_key,
                    timeout=10
                )
            else:
                # 如果密钥不存在，返回错误（暂不支持密码认证）
                raise Exception("SSH key file not found")

            self.sftp_client = self.ssh_client.open_sftp()
            return True
        except Exception as e:
            self.disconnect()
            return False

    def disconnect(self):
        """断开连接"""
        if self.sftp_client:
            self.sftp_client.close()
            self.sftp_client = None
        if self.ssh_client:
            self.ssh_client.close()
            self.ssh_client = None

    def execute_command(self, command: str, timeout: int = 30) -> Tuple[int, str, str]:
        """执行远程命令"""
        if not self.ssh_client:
            raise Exception("SSH client not connected")

        stdin, stdout, stderr = self.ssh_client.exec_command(command, timeout=timeout)
        exit_code = stdout.channel.recv_exit_status()
        output = stdout.read().decode('utf-8', errors='ignore')
        error = stderr.read().decode('utf-8', errors='ignore')
        return exit_code, output, error

    def upload_file(self, local_path: str, remote_path: str) -> bool:
        """上传文件"""
        if not self.sftp_client:
            raise Exception("SFTP client not connected")

        try:
            # 确保远程目录存在
            remote_dir = os.path.dirname(remote_path)
            try:
                self.sftp_client.mkdir(remote_dir)
            except IOError:
                pass  # 目录可能已存在

            self.sftp_client.put(local_path, remote_path)
            return True
        except Exception as e:
            return False

    def upload_content(self, content: str, remote_path: str) -> bool:
        """上传内容到远程文件"""
        if not self.sftp_client:
            raise Exception("SFTP client not connected")

        try:
            # 确保远程目录存在
            remote_dir = os.path.dirname(remote_path)
            try:
                self.sftp_client.mkdir(remote_dir)
            except IOError:
                pass  # 目录可能已存在

            with self.sftp_client.file(remote_path, 'w') as f:
                f.write(content)
            return True
        except Exception as e:
            return False

    def file_exists(self, remote_path: str) -> bool:
        """检查远程文件是否存在"""
        if not self.sftp_client:
            return False
        try:
            self.sftp_client.stat(remote_path)
            return True
        except IOError:
            return False

    def __enter__(self):
        self.connect()
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.disconnect()


def test_ssh_connection(ip: str, ssh_port: int = 22, ssh_user: str = "core") -> Dict[str, Any]:
    """测试SSH连接"""
    result = {
        "success": False,
        "message": "",
        "details": {}
    }

    with SSHDeployer(ip, ssh_port, ssh_user) as deployer:
        if not deployer.ssh_client:
            result["message"] = "SSH连接失败，请检查IP、端口和SSH密钥"
            return result

        # 测试执行简单命令
        try:
            exit_code, output, error = deployer.execute_command("whoami", timeout=10)
            if exit_code == 0:
                result["success"] = True
                result["message"] = "SSH连接成功"
                result["details"] = {
                    "remote_user": output.strip(),
                    "ssh_port": ssh_port,
                    "ssh_user": ssh_user
                }
            else:
                result["message"] = f"命令执行失败: {error}"
        except Exception as e:
            result["message"] = f"执行命令时出错: {str(e)}"

    return result


def deploy_app_to_remote(app_config: Dict[str, Any]) -> Dict[str, Any]:
    """部署应用到远程应用机

    Args:
        app_config: 应用配置，包含:
            - server_ip: 应用机IP
            - ssh_port: SSH端口
            - ssh_user: SSH用户
            - app_name: 应用名称
            - app_port: 应用端口
            - mysql_port: MySQL端口
    """
    result = {
        "success": False,
        "message": "",
        "steps": []
    }

    app_dir = f"{config.APP_DIR_PREFIX}{app_config['app_port']}"
    app_name = app_config['app_name']

    # 读取模板文件
    try:
        with open(f"{config.NEW_API_TEMPLATE_DIR}/.env.example", 'r') as f:
            env_template = f.read()
        with open(f"{config.NEW_API_TEMPLATE_DIR}/docker-compose.yml", 'r') as f:
            compose_template = f.read()
    except Exception as e:
        result["message"] = f"读取模板文件失败: {str(e)}"
        return result

    # 生成应用配置
    env_content = env_template.replace(
        "SQL_DSN=root:burncloud123456!qwf@tcp(burncloud-aiapi-mysql:3306)/new-api?parseTime=true",
        f"SQL_DSN=root:{config.MYSQL_ROOT_PASSWORD}@tcp(burncloud-aiapi-mysql:3306)/{config.DB_NAME}?parseTime=true"
    ).replace(
        "PORT=3000",
        f"PORT={app_config['app_port']}"
    ).replace(
        "MYSQL_PORT=53306",
        f"MYSQL_PORT={app_config['mysql_port']}"
    ).replace(
        "REDIS_CONN_STRING=redis://burncloud-aiapi-redis:6379",
        f"REDIS_CONN_STRING=redis://{app_name}-redis:6379"
    )

    # 修改docker-compose.yml中的容器名，使其唯一
    compose_content = compose_template.replace(
        "burncloud-aiapi",
        f"{app_name}"
    ).replace(
        "burncloud-aiapi-redis",
        f"{app_name}-redis"
    ).replace(
        "burncloud-aiapi-mysql",
        f"{app_name}-mysql"
    )

    # SSH连接并部署
    with SSHDeployer(
        app_config['server_ip'],
        app_config['ssh_port'],
        app_config['ssh_user']
    ) as deployer:
        if not deployer.ssh_client:
            result["message"] = "SSH连接失败"
            result["steps"].append({"step": "SSH连接", "status": "failed"})
            return result

        result["steps"].append({"step": "SSH连接", "status": "success"})

        # 检查目录是否已存在
        if deployer.file_exists(app_dir):
            result["message"] = f"应用目录 {app_dir} 已存在"
            result["steps"].append({"step": "检查目录", "status": "failed"})
            return result

        result["steps"].append({"step": "检查目录", "status": "success"})

        # 创建目录
        exit_code, _, error = deployer.execute_command(f"mkdir -p {app_dir}/logs {app_dir}/public/static {app_dir}/public/uploads {app_dir}/mysql_data {app_dir}/redis_data")
        if exit_code != 0:
            result["message"] = f"创建目录失败: {error}"
            result["steps"].append({"step": "创建目录", "status": "failed"})
            return result

        result["steps"].append({"step": "创建目录", "status": "success"})

        # 上传文件
        if not deployer.upload_content(env_content, f"{app_dir}/.env"):
            result["message"] = "上传.env文件失败"
            result["steps"].append({"step": "上传.env", "status": "failed"})
            return result

        result["steps"].append({"step": "上传.env", "status": "success"})

        if not deployer.upload_content(compose_content, f"{app_dir}/docker-compose.yml"):
            result["message"] = "上传docker-compose.yml文件失败"
            result["steps"].append({"step": "上传docker-compose.yml", "status": "failed"})
            return result

        result["steps"].append({"step": "上传docker-compose.yml", "status": "success"})

        # 启动容器
        exit_code, output, error = deployer.execute_command(f"cd {app_dir} && docker-compose up -d", timeout=120)
        if exit_code != 0:
            result["message"] = f"启动容器失败: {error}"
            result["steps"].append({"step": "启动容器", "status": "failed"})
            return result

        result["steps"].append({"step": "启动容器", "status": "success"})

        # 等待容器启动
        time.sleep(3)

        # 检查容器状态
        container_name = f"{app_name}"
        exit_code, output, error = deployer.execute_command(f"docker ps --filter name={container_name} --format '{{{{.Status}}}}'")

        if exit_code == 0 and output:
            result["success"] = True
            result["message"] = "部署成功"
            result["container_status"] = output.strip()
            result["steps"].append({"step": "验证容器", "status": "success"})
        else:
            result["message"] = "容器启动后未检测到运行状态"
            result["steps"].append({"step": "验证容器", "status": "warning"})

    return result


def check_remote_app_status(ip: str, ssh_port: int, ssh_user: str, app_name: str) -> Dict[str, Any]:
    """检查远程应用容器状态"""
    result = {
        "container_status": None,
        "container_running": False
    }

    try:
        with SSHDeployer(ip, ssh_port, ssh_user) as deployer:
            if deployer.ssh_client:
                exit_code, output, error = deployer.execute_command(
                    f"docker ps --filter name={app_name} --format '{{{{.Status}}}}'"
                )
                if exit_code == 0 and output:
                    result["container_status"] = output.strip()
                    result["container_running"] = "Up" in output

                # 获取容器健康状态
                exit_code, output, error = deployer.execute_command(
                    f"docker inspect --format='{{{{.State.Health.Status}}}}' {app_name} 2>/dev/null || echo 'N/A'"
                )
                if exit_code == 0:
                    result["health_status"] = output.strip()
    except Exception as e:
        result["error"] = str(e)

    return result

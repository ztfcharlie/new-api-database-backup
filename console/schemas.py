"""
Pydantic 模型 - API 请求和响应
"""
from pydantic import BaseModel, Field, validator
from typing import Optional, List


# ============ 应用机相关 ============

class ServerCreate(BaseModel):
    """创建应用机请求"""
    name: str = Field(..., min_length=1, max_length=100, description="备注名称")
    ip: str = Field(..., description="IP地址")
    ssh_port: int = Field(22, ge=1, le=65535, description="SSH端口")
    ssh_user: str = Field("core", description="SSH用户名")


class ServerUpdate(BaseModel):
    """更新应用机请求"""
    name: Optional[str] = None
    ip: Optional[str] = None
    ssh_port: Optional[int] = None
    ssh_user: Optional[str] = None


class ServerResponse(BaseModel):
    """应用机响应"""
    id: int
    name: str
    ip: str
    ssh_port: int
    ssh_user: str
    created_at: str

    class Config:
        from_attributes = True


class ServerTestRequest(BaseModel):
    """测试SSH连接请求"""
    ip: str
    ssh_port: int = 22
    ssh_user: str = "core"


# ============ 应用相关 ============

class AppCreate(BaseModel):
    """创建应用请求"""
    server_id: int = Field(..., gt=0, description="应用机ID")
    app_name: str = Field(..., min_length=1, max_length=100, description="应用名称")
    app_port: int = Field(..., ge=1024, le=65535, description="应用端口")
    mysql_port: int = Field(..., ge=1024, le=65535, description="MySQL端口")


class AppImportRequest(BaseModel):
    """导入已有应用请求"""
    server_id: int = Field(..., gt=0, description="应用机ID")
    app_name: str = Field(..., min_length=1, max_length=100, description="应用名称")
    app_port: int = Field(..., ge=1024, le=65535, description="应用端口")
    mysql_port: int = Field(..., ge=1024, le=65535, description="MySQL端口")
    backup_dir: str = Field(..., description="备份目录名")
    pma_port: int = Field(..., ge=1024, le=65535, description="phpMyAdmin端口")


class AppResponse(BaseModel):
    """应用响应"""
    id: int
    server_id: int
    app_name: str
    app_port: int
    mysql_port: int
    backup_dir: str
    pma_port: int
    status: str  # pending/deploying/running/stopped/error
    backup_status: str  # none/syncing/ok/error
    install_confirmed: bool
    email_notification_enabled: bool
    created_at: str
    updated_at: str
    server_name: Optional[str] = None
    server_ip: Optional[str] = None
    ssh_port: Optional[int] = None
    ssh_user: Optional[str] = None

    class Config:
        from_attributes = True


class AppStatusResponse(AppResponse):
    """应用状态响应（扩展）"""
    app_url: Optional[str] = None
    pma_url: Optional[str] = None
    container_status: Optional[str] = None
    backup_container_status: Optional[str] = None
    slave_io_running: Optional[str] = None
    slave_sql_running: Optional[str] = None
    seconds_behind_master: Optional[int] = None


# ============ 告警相关 ============

class AlertResponse(BaseModel):
    """告警响应"""
    id: int
    app_id: int
    alert_type: str  # io_error/sql_error/delay
    message: Optional[str]
    is_sent: bool
    created_at: str
    app_name: Optional[str] = None
    server_name: Optional[str] = None

    class Config:
        from_attributes = True


# ============ 通用响应 ============

class ApiResponse(BaseModel):
    """API通用响应"""
    code: int = 0
    message: str = "success"
    data: Optional[dict] = None


class HealthResponse(BaseModel):
    """健康检查响应"""
    status: str
    version: str
    timestamp: str


# ============ 部署相关 ============

class DeployStatusResponse(BaseModel):
    """部署状态响应"""
    app_id: int
    status: str
    message: str
    app_container_status: Optional[str] = None
    backup_container_status: Optional[str] = None


# ============ 端口管理 ============

class PortAllocationResponse(BaseModel):
    """端口分配响应"""
    pma_port: int
    available: bool

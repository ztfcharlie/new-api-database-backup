"""
New-API 部署控制台 - FastAPI 主应用
"""
import os
import asyncio
import subprocess
from datetime import datetime
from typing import List, Optional

from fastapi import FastAPI, Request, Response, Form, HTTPException, BackgroundTasks
from fastapi.responses import HTMLResponse, RedirectResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from apscheduler.schedulers.background import BackgroundScheduler

import config
import database
from ssh_deployer import test_ssh_connection, deploy_app_to_remote, check_remote_app_status
from backup_manager import (
    create_backup_directory, get_available_pma_port,
    start_backup_container, stop_backup_container,
    get_backup_container_status, get_slave_status,
    check_sync_health, get_all_backup_dirs, restart_sync
)
from alert_system import send_test_email

# 创建FastAPI应用
app = FastAPI(
    title="New-API 部署控制台",
    description="管理应用机上的new-api应用和备份机上的备份实例",
    version="1.0.0"
)

# 挂载静态文件
app.mount("/static", StaticFiles(directory="static"), name="static")

# 后台任务调度器
scheduler = BackgroundScheduler()


def check_alerts_job():
    """定时检查告警任务"""
    try:
        from alert_system import check_all_apps_health
        result = check_all_apps_health()
        print(f"[{datetime.now()}] 告警检查完成: 检查{result['checked']}个, 告警{result['alerted']}个")
        if result['errors']:
            for err in result['errors']:
                print(f"  错误: {err}")
    except Exception as e:
        print(f"[{datetime.now()}] 告警检查出错: {str(e)}")


# 启动时添加定时任务
@app.on_event("startup")
def startup_event():
    """应用启动时执行"""
    # 初始化数据库
    database.init_db()

    # 添加定时告警检查任务
    scheduler.add_job(
        check_alerts_job,
        'interval',
        seconds=config.ALERT_CHECK_INTERVAL,
        id='alert_check_job'
    )
    scheduler.start()
    print(f"控制台已启动，告警检查间隔: {config.ALERT_CHECK_INTERVAL}秒")


@app.on_event("shutdown")
def shutdown_event():
    """应用关闭时执行"""
    scheduler.shutdown()


# ============ 页面路由 ============

@app.get("/", response_class=HTMLResponse)
async def index(request: Request):
    """首页"""
    apps = database.get_apps()
    servers = database.get_servers()

    # 获取每个应用的实时状态
    for app_item in apps:
        # 应用容器状态
        app_container_status = None
        if app_item.get('server_ip'):
            remote_status = check_remote_app_status(
                app_item['server_ip'],
                app_item['ssh_port'],
                app_item['ssh_user'],
                app_item['app_name']
            )
            app_container_status = remote_status.get('container_status')
            app_item['container_running'] = remote_status.get('container_running', False)

        # 备份容器状态
        backup_status = get_backup_container_status(app_item['backup_dir'])
        app_item['backup_container_running'] = backup_status['container_running']

        # 从库同步状态
        if backup_status['container_running']:
            slave_status = get_slave_status(app_item['backup_dir'])
            app_item['slave_io_running'] = slave_status['io_running']
            app_item['slave_sql_running'] = slave_status['sql_running']
            app_item['seconds_behind_master'] = slave_status['seconds_behind']
        else:
            app_item['slave_io_running'] = None
            app_item['slave_sql_running'] = None
            app_item['seconds_behind_master'] = None

        # 生成访问URL
        if app_item.get('server_ip') and app_item.get('app_port'):
            app_item['app_url'] = f"http://{app_item['server_ip']}:{app_item['app_port']}"
        app_item['pma_url'] = f"ssh -L {app_item['pma_port']}:127.0.0.1:{app_item['pma_port']} root@备份机IP"

    return app.TemplateResponse("index.html", {
        "request": request,
        "apps": apps,
        "servers": servers
    })


@app.get("/servers", response_class=HTMLResponse)
async def servers_page(request: Request):
    """应用机管理页面"""
    servers = database.get_servers()
    # 获取每台应用机的应用数量
    for server in servers:
        apps = database.get_apps_by_server(server['id'])
        server['app_count'] = len(apps)

    return app.TemplateResponse("servers.html", {
        "request": request,
        "servers": servers
    })


@app.get("/apps", response_class=HTMLResponse)
async def apps_page(request: Request):
    """应用管理页面"""
    apps = database.get_apps()
    servers = database.get_servers()

    return app.TemplateResponse("apps.html", {
        "request": request,
        "apps": apps,
        "servers": servers
    })


@app.get("/alerts", response_class=HTMLResponse)
async def alerts_page(request: Request):
    """告警历史页面"""
    alerts = database.get_alerts(limit=200)
    return app.TemplateResponse("alerts.html", {
        "request": request,
        "alerts": alerts
    })


@app.get("/deploy", response_class=HTMLResponse)
async def deploy_page(request: Request):
    """部署新应用页面"""
    servers = database.get_servers()
    return app.TemplateResponse("deploy.html", {
        "request": request,
        "servers": servers
    })


@app.get("/import", response_class=HTMLResponse)
async def import_page(request: Request):
    """导入已有节点页面"""
    servers = database.get_servers()
    # 获取所有已有备份目录
    backup_dirs = get_all_backup_dirs()
    return app.TemplateResponse("import.html", {
        "request": request,
        "servers": servers,
        "backup_dirs": backup_dirs
    })


# ============ API 路由 ============

@app.get("/api/health")
async def health_check():
    """健康检查"""
    return {
        "status": "ok",
        "version": "1.0.0",
        "timestamp": datetime.now().isoformat()
    }


# ============ 应用机 API ============

@app.post("/api/servers")
async def create_server(
    request: Request,
    name: str = Form(...),
    ip: str = Form(...),
    ssh_port: int = Form(22),
    ssh_user: str = Form("core")
):
    """创建应用机"""
    server_id = database.create_server(name, ip, ssh_port, ssh_user)
    return JSONResponse({
        "code": 0,
        "message": "应用机添加成功",
        "data": {"id": server_id}
    })


@app.post("/api/servers/{server_id}/update")
async def update_server(
    server_id: int,
    name: str = Form(None),
    ip: str = Form(None),
    ssh_port: int = Form(None),
    ssh_user: str = Form(None)
):
    """更新应用机"""
    success = database.update_server(server_id, name, ip, ssh_port, ssh_user)
    if success:
        return JSONResponse({"code": 0, "message": "更新成功"})
    return JSONResponse({"code": -1, "message": "更新失败"})


@app.post("/api/servers/{server_id}/delete")
async def delete_server(server_id: int):
    """删除应用机"""
    success = database.delete_server(server_id)
    if success:
        return JSONResponse({"code": 0, "message": "删除成功"})
    return JSONResponse({"code": -1, "message": "删除失败，该应用机下还有应用"})


@app.post("/api/servers/test")
async def test_ssh_connection_api(
    ip: str = Form(...),
    ssh_port: int = Form(22),
    ssh_user: str = Form("core")
):
    """测试SSH连接"""
    result = test_ssh_connection(ip, ssh_port, ssh_user)
    return JSONResponse(result)


# ============ 应用 API ============

@app.post("/api/apps")
async def create_app(
    background_tasks: BackgroundTasks,
    server_id: int = Form(...),
    app_name: str = Form(...),
    app_port: int = Form(...),
    mysql_port: int = Form(...),
    auto_deploy: bool = Form(True)
):
    """创建新应用"""
    # 获取应用机信息
    server = database.get_server(server_id)
    if not server:
        return JSONResponse({"code": -1, "message": "应用机不存在"})

    # 生成备份目录名
    backup_dir = f"{server['ip']}-{app_port}"
    # 替换IP中的点为横杠（与现有目录格式一致）
    backup_dir = backup_dir.replace('.', '-')

    # 分配phpMyAdmin端口
    try:
        pma_port = get_available_pma_port()
    except Exception as e:
        return JSONResponse({"code": -1, "message": f"分配端口失败: {str(e)}"})

    # 创建数据库记录
    app_id = database.create_app(server_id, app_name, app_port, mysql_port, backup_dir, pma_port)

    # 创建备份目录和配置
    app_config = {
        'server': server,
        'app_name': app_name,
        'app_port': app_port,
        'mysql_port': mysql_port,
        'backup_dir': backup_dir,
        'pma_port': pma_port
    }

    backup_result = create_backup_directory(app_config)
    if not backup_result['success']:
        return JSONResponse({"code": -1, "message": f"创建备份目录失败: {backup_result['message']}"})

    # 更新状态为部署中
    database.update_app_status(app_id, status="deploying")

    # 如果自动部署，后台执行部署
    if auto_deploy:
        background_tasks.add_task(
            deploy_app_task,
            app_id,
            server,
            app_name,
            app_port,
            mysql_port,
            backup_dir
        )

    return JSONResponse({
        "code": 0,
        "message": "应用创建成功，正在部署中...",
        "data": {"app_id": app_id, "backup_dir": backup_dir, "pma_port": pma_port}
    })


async def deploy_app_task(
    app_id: int,
    server: dict,
    app_name: str,
    app_port: int,
    mysql_port: int,
    backup_dir: str
):
    """后台部署任务"""
    try:
        # 部署到应用机
        deploy_config = {
            'server_ip': server['ip'],
            'ssh_port': server['ssh_port'],
            'ssh_user': server['ssh_user'],
            'app_name': app_name,
            'app_port': app_port,
            'mysql_port': mysql_port
        }

        result = deploy_app_to_remote(deploy_config)

        if result['success']:
            database.update_app_status(app_id, status="running")
        else:
            database.update_app_status(app_id, status="error")
    except Exception as e:
        database.update_app_status(app_id, status="error")
        print(f"部署任务失败: {str(e)}")


@app.post("/api/apps/{app_id}/status")
async def refresh_app_status(app_id: int):
    """刷新应用状态"""
    app = database.get_app(app_id)
    if not app:
        return JSONResponse({"code": -1, "message": "应用不存在"})

    # 应用容器状态
    result = {}
    if app.get('server_ip'):
        remote_status = check_remote_app_status(
            app['server_ip'],
            app['ssh_port'],
            app['ssh_user'],
            app['app_name']
        )
        result['container_status'] = remote_status.get('container_status')
        result['container_running'] = remote_status.get('container_running', False)

    # 备份容器状态
    backup_status = get_backup_container_status(app['backup_dir'])
    result['backup_container_running'] = backup_status['container_running']

    # 从库同步状态
    if backup_status['container_running']:
        slave_status = get_slave_status(app['backup_dir'])
        result['slave_io_running'] = slave_status['io_running']
        result['slave_sql_running'] = slave_status['sql_running']
        result['seconds_behind_master'] = slave_status['seconds_behind']

    # 更新数据库状态
    if backup_status['container_running']:
        health = check_sync_health(app['backup_dir'])
        backup_status_str = health['status']
        database.update_app_status(app_id, backup_status=backup_status_str)
    else:
        database.update_app_status(app_id, backup_status="none")

    return JSONResponse({
        "code": 0,
        "message": "状态刷新成功",
        "data": result
    })


@app.post("/api/apps/{app_id}/confirm")
async def confirm_app_install(app_id: int):
    """确认应用已安装，启动备份"""
    app = database.get_app(app_id)
    if not app:
        return JSONResponse({"code": -1, "message": "应用不存在"})

    # 启动备份容器
    backup_result = start_backup_container(app['backup_dir'])

    if backup_result['success']:
        # 执行数据初始化同步（使用quick_start_sync.sh）
        try:
            backup_dir_path = f"{config.BACKUP_BASE_DIR}/{app['backup_dir']}"
            script_path = f"{backup_dir_path}/quick_start_sync.sh"

            # 确保脚本有执行权限
            os.chmod(script_path, 0o755)

            # 执行同步脚本（需要输入密码）
            # 这里使用环境变量方式传递密码
            env = os.environ.copy()
            env['MYSQL_PWD'] = config.MYSQL_ROOT_PASSWORD

            # 执行同步
            subprocess.run(
                f"echo {config.MYSQL_ROOT_PASSWORD} | {script_path}",
                shell=True,
                env=env,
                timeout=300,
                capture_output=True
            )
        except Exception as e:
            # 同步失败不影响容器启动
            print(f"同步脚本执行出错: {str(e)}")

        database.confirm_install(app_id)
        database.update_app_status(app_id, backup_status="syncing")

        return JSONResponse({
            "code": 0,
            "message": "备份容器已启动，正在同步数据...",
            "data": backup_result
        })
    else:
        return JSONResponse({
            "code": -1,
            "message": f"启动备份容器失败: {backup_result['message']}"
        })


@app.post("/api/apps/{app_id}/restart-sync")
async def restart_app_sync(app_id: int):
    """重启同步"""
    app = database.get_app(app_id)
    if not app:
        return JSONResponse({"code": -1, "message": "应用不存在"})

    result = restart_sync(app['backup_dir'])
    return JSONResponse({
        "code": 0 if result['success'] else -1,
        "message": result['message']
    })


@app.post("/api/apps/{app_id}/toggle-notification")
async def toggle_app_notification(app_id: int):
    """切换邮件通知开关"""
    app = database.get_app(app_id)
    if not app:
        return JSONResponse({"code": -1, "message": "应用不存在"})

    new_state = not app['email_notification_enabled']
    database.toggle_email_notification(app_id, new_state)

    return JSONResponse({
        "code": 0,
        "message": f"邮件通知已{'开启' if new_state else '关闭'}",
        "data": {"enabled": new_state}
    })


@app.post("/api/apps/import")
async def import_existing_app(
    server_id: int = Form(...),
    app_name: str = Form(...),
    app_port: int = Form(...),
    mysql_port: int = Form(...),
    backup_dir: str = Form(...),
    pma_port: int = Form(...)
):
    """导入已有应用"""
    server = database.get_server(server_id)
    if not server:
        return JSONResponse({"code": -1, "message": "应用机不存在"})

    # 检查备份目录是否存在
    backup_dir_path = f"{config.BACKUP_BASE_DIR}/{backup_dir}"
    if not os.path.exists(backup_dir_path):
        return JSONResponse({"code": -1, "message": "备份目录不存在"})

    # 导入到数据库
    app_id = database.import_existing_app(
        server_id, app_name, app_port, mysql_port,
        backup_dir, pma_port, install_confirmed=True
    )

    return JSONResponse({
        "code": 0,
        "message": "导入成功",
        "data": {"app_id": app_id}
    })


# ============ 告警 API ============

@app.get("/api/alerts")
async def get_alerts_api(limit: int = 100):
    """获取告警列表"""
    alerts = database.get_alerts(limit=limit)
    return JSONResponse({
        "code": 0,
        "data": alerts
    })


@app.post("/api/alerts/test-email")
async def send_test_email_api():
    """发送测试邮件"""
    success = send_test_email()
    if success:
        return JSONResponse({"code": 0, "message": "测试邮件发送成功"})
    return JSONResponse({"code": -1, "message": "测试邮件发送失败"})


# ============ 系统API ============

@app.get("/api/system/info")
async def get_system_info():
    """获取系统信息"""
    apps = database.get_apps()
    servers = database.get_servers()

    # 统计信息
    total_apps = len(apps)
    running_apps = len([a for a in apps if a['status'] == 'running'])
    backup_ok = len([a for a in apps if a['backup_status'] == 'ok'])
    backup_error = len([a for a in apps if a['backup_status'] == 'error'])

    return JSONResponse({
        "code": 0,
        "data": {
            "total_servers": len(servers),
            "total_apps": total_apps,
            "running_apps": running_apps,
            "backup_ok": backup_ok,
            "backup_error": backup_error
        }
    })


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host=config.CONSOLE_HOST, port=config.CONSOLE_PORT)

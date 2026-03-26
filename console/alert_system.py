"""
邮件告警系统
"""
import smtplib
import ssl
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
from email.header import Header
from typing import List, Dict, Any

import config
from database import (
    get_apps_with_email_enabled,
    create_alert,
    get_alerts_by_app,
    mark_alert_sent
)
from backup_manager import check_sync_health


def send_email(recipients: List[str], subject: str, body: str) -> bool:
    """发送邮件"""
    try:
        msg = MIMEMultipart()
        msg['From'] = config.SMTP_USER
        msg['Subject'] = Header(subject, 'utf-8').encode()

        # 添加收件人
        for recipient in recipients:
            msg['To'] = recipient

        msg.attach(MIMEText(body, 'plain', 'utf-8'))

        if config.SMTP_USE_SSL:
            # 使用SSL连接（465端口）
            context = ssl.create_default_context()
            with smtplib.SMTP_SSL(
                config.SMTP_HOST,
                config.SMTP_PORT,
                context=context
            ) as server:
                server.login(config.SMTP_USER, config.SMTP_PASSWORD)
                server.sendmail(config.SMTP_USER, recipients, msg.as_string())
        else:
            # 使用TLS连接（587端口）
            with smtplib.SMTP(config.SMTP_HOST, config.SMTP_PORT) as server:
                server.starttls()
                server.login(config.SMTP_USER, config.SMTP_PASSWORD)
                server.sendmail(config.SMTP_USER, recipients, msg.as_string())

        return True
    except Exception as e:
        print(f"发送邮件失败: {str(e)}")
        return False


def send_alert_email(app: Dict[str, Any], issues: List[Dict[str, Any]]) -> bool:
    """发送告警邮件"""
    subject = f"[告警] New-API备份异常 - {app['app_name']} ({app['server_name']})"

    body = f"""
应用备份状态异常通知
====================================

应用信息:
  应用名称: {app['app_name']}
  应用机: {app['server_name']} ({app['server_ip']})
  应用端口: {app['app_port']}
  备份目录: {app['backup_dir']}

异常详情:
"""

    for issue in issues:
        issue_type = issue['type']
        if issue_type == 'io_error':
            body += f"\n  [IO错误] {issue['message']}"
        elif issue_type == 'sql_error':
            body += f"\n  [SQL错误] {issue['message']}"
        elif issue_type == 'delay':
            body += f"\n  [延迟] {issue['message']}"

        if issue.get('detail'):
            body += f"\n         详情: {issue['detail']}\n"

    body += f"""
====================================

请及时检查备份状态。
phpMyAdmin访问: ssh -L {app['pma_port']}:127.0.0.1:{app['pma_port']} root@备份机IP
然后访问: http://localhost:{app['pma_port']}
"""

    return send_email(config.ALERT_RECIPIENTS, subject, body)


def check_all_apps_health() -> Dict[str, Any]:
    """检查所有开启邮件通知的应用的健康状态"""
    result = {
        "total": 0,
        "checked": 0,
        "alerted": 0,
        "errors": []
    }

    apps = get_apps_with_email_enabled()
    result["total"] = len(apps)

    for app in apps:
        result["checked"] += 1

        try:
            # 检查同步健康
            health = check_sync_health(app['backup_dir'])

            if health['issues']:
                # 检查最近是否有相同类型的告警已发送
                # 避免重复发送（1小时内相同类型只发一次）
                recent_alerts = get_alerts_by_app(app['id'], limit=10)

                # 获取最近告警的类型
                recent_types = {
                    a['alert_type'] for a in recent_alerts
                }

                for issue in health['issues']:
                    issue_type = issue['type']

                    # 检查是否需要发送新告警
                    need_alert = True
                    for alert in recent_alerts:
                        if (alert['alert_type'] == issue_type and
                            alert['is_sent']):
                            need_alert = False
                            break

                    if need_alert:
                        # 创建告警记录
                        alert_id = create_alert(
                            app['id'],
                            issue_type,
                            issue['message']
                        )

                        # 发送邮件
                        issues_list = [issue]
                        if send_alert_email(app, issues_list):
                            mark_alert_sent(alert_id)
                            result["alerted"] += 1

        except Exception as e:
            error_msg = f"检查应用 {app['app_name']} 时出错: {str(e)}"
            result["errors"].append(error_msg)
            print(error_msg)

    return result


def send_test_email() -> bool:
    """发送测试邮件"""
    subject = "[测试] New-API部署控制台邮件通知"
    body = """这是一封测试邮件。

如果收到此邮件，说明邮件配置正确。
"""

    return send_email(config.ALERT_RECIPIENTS, subject, body)


if __name__ == "__main__":
    # 测试邮件发送
    print("测试邮件发送...")
    if send_test_email():
        print("测试邮件发送成功！")
    else:
        print("测试邮件发送失败！")

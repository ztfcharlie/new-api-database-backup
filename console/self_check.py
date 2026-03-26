"""
控制台代码自检脚本
检查代码中可能存在的问题
"""
import os
import re
import ast

def check_file_exists(filepath, description):
    """检查文件是否存在"""
    if os.path.exists(filepath):
        print(f"[OK] {description}: {filepath}")
        return True
    else:
        print(f"[ERROR] {description}: {filepath} 不存在")
        return False


def check_imports(filepath):
    """检查Python文件中的导入语句"""
    print(f"\n检查 {filepath} 的导入...")
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            content = f.read()
            tree = ast.parse(content, filepath)

        imports = []
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                for alias in node.names:
                    imports.append(alias.name)
            elif isinstance(node, ast.ImportFrom):
                module = node.module or ''
                for alias in node.names:
                    imports.append(f"{module}.{alias.name}")

        print(f"  找到 {len(imports)} 个导入:")
        for imp in imports[:10]:  # 只显示前10个
            print(f"    - {imp}")
        if len(imports) > 10:
            print(f"    ... 还有 {len(imports) - 10} 个")
        return True
    except Exception as e:
        print(f"  [ERROR] 解析失败: {e}")
        return False


def check_config_values():
    """检查配置文件的值是否合理"""
    print("\n检查 config.py 的配置值...")
    try:
        with open('config.py', 'r', encoding='utf-8') as f:
            content = f.read()

        checks = [
            ('CONSOLE_PORT', r'CONSOLE_PORT\s*=\s*(\d+)'),
            ('PMA_PORT_START', r'PMA_PORT_START\s*=\s*(\d+)'),
            ('PMA_PORT_END', r'PMA_PORT_END\s*=\s*(\d+)'),
            ('ALERT_CHECK_INTERVAL', r'ALERT_CHECK_INTERVAL\s*=\s*(\d+)'),
            ('SMTP_HOST', r'SMTP_HOST\s*=\s*["\']([^"\']+)["\']'),
        ]

        for name, pattern in checks:
            match = re.search(pattern, content)
            if match:
                value = match.group(1)
                print(f"  [OK] {name} = {value}")
            else:
                print(f"  [WARNING] {name} 未找到或格式不正确")

        # 检查端口范围
        start_match = re.search(r'PMA_PORT_START\s*=\s*(\d+)', content)
        end_match = re.search(r'PMA_PORT_END\s*=\s*(\d+)', content)
        if start_match and end_match:
            start = int(start_match.group(1))
            end = int(end_match.group(1))
            if start < end:
                print(f"  [OK] 端口范围 {start}-{end} 合理")
            else:
                print(f"  [ERROR] 端口范围 {start}-{end} 不合理")

        return True
    except Exception as e:
        print(f"  [ERROR] 检查失败: {e}")
        return False


def check_html_templates():
    """检查HTML模板文件"""
    print("\n检查HTML模板文件...")
    template_dir = 'templates'
    if not os.path.exists(template_dir):
        print(f"  [ERROR] templates 目录不存在")
        return False

    required_files = [
        'base.html',
        'index.html',
        'servers.html',
        'apps.html',
        'deploy.html',
        'import.html',
        'alerts.html'
    ]

    for filename in required_files:
        filepath = os.path.join(template_dir, filename)
        if os.path.exists(filepath):
            print(f"  [OK] {filename}")
        else:
            print(f"  [ERROR] {filename} 不存在")

    return True


def check_static_files():
    """检查静态文件"""
    print("\n检查静态文件...")
    static_dir = 'static/css'
    if not os.path.exists(static_dir):
        print(f"  [ERROR] static/css 目录不存在")
        return False

    if os.path.exists('static/css/style.css'):
        print(f"  [OK] static/css/style.css")
    else:
        print(f"  [ERROR] static/css/style.css 不存在")

    return True


def check_syntax(filepath):
    """检查Python语法"""
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            compile(f.read(), filepath, 'exec')
        print(f"[OK] {filepath} 语法正确")
        return True
    except SyntaxError as e:
        print(f"[ERROR] {filepath} 语法错误: {e}")
        return False


def check_docker_files():
    """检查Docker相关文件"""
    print("\n检查Docker相关文件...")
    files = [
        ('Dockerfile', 'Dockerfile'),
        ('requirements.txt', 'requirements.txt'),
        ('docker-compose.yml', 'docker-compose.yml')
    ]

    for name, filename in files:
        if os.path.exists(filename):
            print(f"  [OK] {filename}")
            # 检查关键内容
            if filename == 'Dockerfile':
                with open(filename, 'r', encoding='utf-8') as f:
                    content = f.read()
                    if 'EXPOSE 8980' in content:
                        print(f"    - 暴露端口正确")
            elif filename == 'docker-compose.yml':
                with open(filename, 'r', encoding='utf-8') as f:
                    content = f.read()
                    if '8980:8980' in content:
                        print(f"    - 端口映射正确")
                    if 'network_mode: host' in content:
                        print(f"    - 网络模式正确")
        else:
            print(f"  [ERROR] {filename} 不存在")


def check_missing_imports():
    """检查是否有缺失的导入"""
    print("\n检查潜在缺失的导入...")

    python_files = [
        'app.py',
        'config.py',
        'database.py',
        'ssh_deployer.py',
        'backup_manager.py',
        'alert_system.py'
    ]

    imports_needed = {
        'app.py': ['fastapi', 'uvicorn', 'asyncio', 'config', 'database'],
        'ssh_deployer.py': ['paramiko', 'config'],
        'backup_manager.py': ['subprocess', 'config'],
        'alert_system.py': ['smtplib', 'config', 'database', 'backup_manager'],
        'database.py': ['sqlite3', 'os', 'datetime', 'config'],
        'config.py': []  # config.py 不需要导入其他模块
    }

    for filename, needed_modules in imports_needed.items():
        filepath = filename
        if not os.path.exists(filepath):
            continue

        with open(filepath, 'r', encoding='utf-8') as f:
            content = f.read()

        for module in needed_modules:
            if module in content:
                pass  # 模块被引用
            else:
                # 可能使用的是 from ... import
                from_pattern = re.search(rf'from\s+{re.escape(module)}\s+import', content)
                if from_pattern:
                    pass
                else:
                    # 如果模块名作为配置变量使用，也是正常的
                    if module == 'config' and re.search(r'config\.', content):
                        pass
                    else:
                        print(f"  [WARNING] {filename} 可能缺少 {module} 的引用")


def check_sqlite_usage():
    """检查SQLite数据库初始化"""
    print("\n检查数据库相关...")
    try:
        with open('database.py', 'r', encoding='utf-8') as f:
            content = f.read()

        if 'init_db()' in content:
            print(f"  [OK] 数据库初始化函数存在")

        if 'CREATE TABLE IF NOT EXISTS' in content:
            print(f"  [OK] 表创建语句存在")

        # 检查表是否都创建了
        tables = ['servers', 'apps', 'alerts']
        for table in tables:
            if f'CREATE TABLE IF NOT EXISTS {table}' in content:
                print(f"  [OK] {table} 表创建语句存在")

        return True
    except Exception as e:
        print(f"  [ERROR] 检查失败: {e}")
        return False


def check_template_syntax():
    """检查HTML模板语法"""
    print("\n检查HTML模板语法...")
    template_dir = 'templates'
    if not os.path.exists(template_dir):
        return False

    for filename in os.listdir(template_dir):
        if not filename.endswith('.html'):
            continue

        filepath = os.path.join(template_dir, filename)
        try:
            with open(filepath, 'r', encoding='utf-8') as f:
                content = f.read()

            # 检查Jinja2标签
            if '{% extends' not in content and filename != 'base.html':
                if filename != 'base.html':
                    print(f"  [WARNING] {filename} 可能缺少 {{% extends %}} 语句")

            print(f"  [OK] {filename}")
        except Exception as e:
            print(f"  [ERROR] {filename} 检查失败: {e}")


def run_all_checks():
    """运行所有检查"""
    print("=" * 60)
    print("New-API 部署控制台 - 代码自检")
    print("=" * 60)

    # 切换到console目录
    script_dir = os.path.dirname(os.path.abspath(__file__))
    os.chdir(script_dir)

    results = []

    # 1. 检查核心Python文件
    print("\n【1. 检查核心Python文件】")
    results.append(check_file_exists('app.py', '主应用文件'))
    results.append(check_file_exists('config.py', '配置文件'))
    results.append(check_file_exists('database.py', '数据库文件'))
    results.append(check_file_exists('ssh_deployer.py', 'SSH部署文件'))
    results.append(check_file_exists('backup_manager.py', '备份管理文件'))
    results.append(check_file_exists('alert_system.py', '告警系统文件'))
    results.append(check_file_exists('schemas.py', '数据模型文件'))

    # 2. 检查Python语法
    print("\n【2. 检查Python语法】")
    results.append(check_syntax('app.py'))
    results.append(check_syntax('config.py'))
    results.append(check_syntax('database.py'))
    results.append(check_syntax('ssh_deployer.py'))
    results.append(check_syntax('backup_manager.py'))
    results.append(check_syntax('alert_system.py'))
    results.append(check_syntax('schemas.py'))

    # 3. 检查配置
    print("\n【3. 检查配置文件】")
    results.append(check_config_values())

    # 4. 检查HTML模板
    print("\n【4. 检查HTML模板】")
    results.append(check_html_templates())

    # 5. 检查静态文件
    print("\n【5. 检查静态文件】")
    results.append(check_static_files())

    # 6. 检查Docker文件
    print("\n【6. 检查Docker相关文件】")
    check_docker_files()

    # 7. 检查数据库
    print("\n【7. 检查数据库相关】")
    results.append(check_sqlite_usage())

    # 8. 检查模板语法
    print("\n【8. 检查HTML模板语法】")
    check_template_syntax()

    # 总结
    print("\n" + "=" * 60)
    ok_count = sum(1 for r in results if r)
    total_count = len(results)
    print(f"自检完成: {ok_count}/{total_count} 项通过")

    if ok_count == total_count:
        print("\n[SUCCESS] 所有检查通过！代码可以部署。")
    else:
        print(f"\n[WARNING] 有 {total_count - ok_count} 项检查失败，请修复后再部署。")
    print("=" * 60)

    return ok_count == total_count


if __name__ == "__main__":
    run_all_checks()

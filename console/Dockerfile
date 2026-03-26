FROM python:3.11-slim

LABEL maintainer="burncloud"
LABEL description="New-API 部署控制台"

# 安装系统依赖
RUN apt-get update && apt-get install -y \
    openssh-client \
    docker.io \
    docker-compose \
    && rm -rf /var/lib/apt/lists/*

# 设置工作目录
WORKDIR /app

# 复制依赖文件
COPY requirements.txt .

# 安装Python依赖
RUN pip install --no-cache-dir -r requirements.txt

# 复制应用代码
COPY . .

# 创建数据目录
RUN mkdir -p /data

# 暴露端口
EXPOSE 8980

# 启动命令
CMD ["python", "app.py"]

# Kindler Web GUI Backend Dockerfile (Multi-Mirror Strategy)
FROM python:3.11-slim

# Configure APT mirrors - use traditional sources.list format with multiple mirrors
RUN rm -f /etc/apt/sources.list.d/debian.sources && \
    cat > /etc/apt/sources.list << 'EOF'
# Aliyun mirror (primary)
deb https://mirrors.aliyun.com/debian trixie main contrib non-free non-free-firmware
deb https://mirrors.aliyun.com/debian trixie-updates main contrib non-free non-free-firmware

# USTC mirror (backup)
deb https://mirrors.ustc.edu.cn/debian trixie main contrib non-free non-free-firmware
deb https://mirrors.ustc.edu.cn/debian trixie-updates main contrib non-free non-free-firmware

# Official Debian mirror (fallback)
deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware
deb http://deb.debian.org/debian trixie-updates main contrib non-free non-free-firmware
EOF

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install kubectl - use Aliyun mirror for faster download in China
RUN KUBECTL_VERSION=$(curl -L -s https://dl.k8s.io/release/stable.txt) && \
    curl -LO "https://mirrors.aliyun.com/kubernetes/kubectl/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" || \
    curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" && \
    chmod +x kubectl && \
    mv kubectl /usr/local/bin/

# Note: docker CLI is NOT installed - we use docker socket from host via volume mount
# This reduces image size and build time significantly

# Set working directory
WORKDIR /app

# Copy requirements and install dependencies with mirror fallback
COPY requirements.txt .
RUN pip install --no-cache-dir -i https://mirrors.aliyun.com/pypi/simple/ \
        --trusted-host mirrors.aliyun.com -r requirements.txt || \
    pip install --no-cache-dir -i https://pypi.tuna.tsinghua.edu.cn/simple \
        --trusted-host pypi.tuna.tsinghua.edu.cn -r requirements.txt || \
    pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY app ./app

# Expose port
EXPOSE 8000

# Run application
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]

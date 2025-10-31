# Kindler Web GUI Backend Dockerfile
FROM python:3.11-slim

# Configure apt to use Chinese mirror (default, not fallback)
# Detect Debian version and configure sources accordingly
RUN DEB_VERSION=$(cat /etc/debian_version | cut -d. -f1) && \
    if [ -f /etc/os-release ]; then \
        DEB_CODENAME=$(grep VERSION_CODENAME= /etc/os-release | cut -d= -f2); \
    else \
        case $DEB_VERSION in \
            11) DEB_CODENAME=bullseye ;; \
            12) DEB_CODENAME=bookworm ;; \
            *) DEB_CODENAME=trixie ;; \
        esac; \
    fi && \
    if [ -f /etc/apt/sources.list.d/debian.sources ]; then \
        sed -i 's|http://deb.debian.org|https://mirrors.tuna.tsinghua.edu.cn|g' /etc/apt/sources.list.d/debian.sources && \
        sed -i 's|http://security.debian.org|https://mirrors.tuna.tsinghua.edu.cn/debian-security|g' /etc/apt/sources.list.d/debian.sources; \
    else \
        if [ -f /etc/apt/sources.list ]; then \
            sed -i 's|http://deb.debian.org|https://mirrors.tuna.tsinghua.edu.cn|g' /etc/apt/sources.list && \
            sed -i 's|http://security.debian.org|https://mirrors.tuna.tsinghua.edu.cn/debian-security|g' /etc/apt/sources.list; \
        else \
            echo "deb https://mirrors.tuna.tsinghua.edu.cn/debian/ ${DEB_CODENAME} main contrib non-free non-free-firmware" > /etc/apt/sources.list && \
            echo "deb https://mirrors.tuna.tsinghua.edu.cn/debian/ ${DEB_CODENAME}-updates main contrib non-free non-free-firmware" >> /etc/apt/sources.list && \
            echo "deb https://mirrors.tuna.tsinghua.edu.cn/debian-security ${DEB_CODENAME}-security main contrib non-free non-free-firmware" >> /etc/apt/sources.list; \
        fi; \
    fi

# Install system dependencies with retry and non-interactive
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get clean && \
    apt-get update -o Acquire::Retries=3 && \
    apt-get install -y --no-install-recommends \
        curl \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install kubectl (using Chinese mirror for faster download)
RUN KUBECTL_VERSION=$(curl -L -s https://dl.k8s.io/release/stable.txt) && \
    curl -LO "https://mirrors.aliyun.com/kubernetes-release/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" || \
    curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" && \
    chmod +x kubectl && \
    mv kubectl /usr/local/bin/

# Install docker CLI (for docker ps, docker exec, etc.)
RUN curl -fsSL https://get.docker.com -o get-docker.sh \
    && sh get-docker.sh --dry-run \
    && rm get-docker.sh \
    || (apt-get update -o Acquire::Retries=3 && apt-get install -y docker.io && rm -rf /var/lib/apt/lists/*)

# Set working directory
WORKDIR /app

# Copy requirements and install dependencies
COPY requirements.txt .
RUN pip config set global.index-url https://pypi.tuna.tsinghua.edu.cn/simple && \
    pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY app ./app

# Expose port
EXPOSE 8000

# Run application
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]

